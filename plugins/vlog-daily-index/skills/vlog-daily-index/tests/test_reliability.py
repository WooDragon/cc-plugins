"""Observable failure/recovery boundaries; synthetic files and HTTP mocks only."""
# All dates, routes and coordinates in this module are synthetic fixtures.
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
import wave
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import httpx
from vlog_index import analysis, asr, media, report, store
from vlog_index.store import State, ServiceLock, digest, dump, read, cleanup_registered
from fixture_helpers import final_context, root_review

spec = importlib.util.spec_from_file_location('vlog_cli', Path(__file__).resolve().parents[1] / 'scripts' / 'vlog_daily_index.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
PROTOCOL = {'terminal_field': 'is_final', 'terminal_value': True,
            'text_field': 'text', 'text_mode': 'deltas_before_final', 'precision': 'chunk'}


def wav_file(path, seconds, value=0):
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
        output.writeframes(int(value).to_bytes(2, 'little', signed=True) * round(seconds * 16000))


class Stream(httpx.SyncByteStream):
    def __init__(self, chunks): self.chunks = chunks; self.consumed = 0; self.closed = False
    def __iter__(self):
        for chunk in self.chunks:
            self.consumed += 1
            yield chunk
    def close(self): self.closed = True


class Reliability(unittest.TestCase):
    def test_gps_revision_reuses_ids_and_never_reads_media_or_submits_asr(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'
            base = '2030-01-02T00:00:00+00:00'
            metadata = {'captured_at_utc': base, 'time_verified': True,
                        'playback_rate_verified': True, 'location_points': []}
            sources = [{'id': 'camera', 'relative_path': 'camera.mp4', 'status': 'ready', 'duration': 240,
                        'role': 'camera', 'sample_times': [30, 180], 'metadata': copy.deepcopy(metadata)},
                       {'id': 'uncertain', 'relative_path': 'uncertain.mp4', 'status': 'ready', 'duration': 60,
                        'role': 'camera', 'sample_times': [30], 'metadata': {**metadata, 'playback_rate_verified': False}},
                       {'id': 'drone', 'relative_path': 'drone.mp4', 'status': 'ready', 'duration': 60,
                        'role': 'drone', 'sample_times': [30], 'metadata': {**metadata, 'location_points': [
                            {'start_seconds': 0, 'end_seconds': 60, 'latitude': 3, 'longitude': 4,
                             'trusted': True, 'crs': 'EPSG:4326', 'source_file': 'drone.srt'}]}}]
            frames = [{'id': sid + str(t), 'source_id': sid, 'time': t} for sid, times in
                      [('camera', [30, 180]), ('uncertain', [30]), ('drone', [30])] for t in times]
            packages = [{'id': sid, 'status': 'success', 'core_frame_ids': [f['id'] for f in frames if f['source_id'] == sid]}
                        for sid in ('camera', 'uncertain', 'drone')]
            manifest = {'run_id': 'fixture', 'state_dir': str(state), 'sources': sources, 'frames': frames,
                        'packages': packages, 'published_verified': True, 'transcription': {
                            'camera': {'status': 'success'}, 'uncertain': {'status': 'success'}, 'drone': {'status': 'skipped_drone'}}}
            dump(state / 'manifest.json', manifest); dump(state / 'daily.validated.json', {'summary': 'prior'})
            for package in packages: dump(state / 'analysis' / (package['id'] + '.json'), {'events': [], 'interest_points': []})
            gps = {'points': [{'timestamp_utc': '2030-01-02T00:00:00Z', 'latitude': 1, 'longitude': 2, 'source_file': 'track.fit', 'segment_id': '0'},
                              {'timestamp_utc': '2030-01-02T00:02:00Z', 'latitude': 1, 'longitude': 2.001, 'source_file': 'track.fit', 'segment_id': '0'},
                              {'timestamp_utc': '2030-01-02T00:05:01Z', 'latitude': 1, 'longitude': 2, 'source_file': 'track.fit', 'segment_id': '0'}],
                   'quality': {'coverage_windows': [{'start_utc': base, 'end_utc': '2030-01-02T00:02:00Z'}]},
                   'gaps': [{'start_utc': '2030-01-02T00:02:00Z', 'end_utc': '2030-01-02T00:05:01Z', 'source_file': 'track.fit'}],
                   'stops': [{'stop_id': 'stop1', 'start_utc': base, 'end_utc': '2030-01-02T00:02:00Z',
                              'latitude': 1, 'longitude': 2, 'source': 'garmin_fit', 'source_file': 'track.fit'}]}
            gps_path = Path(td) / 'gps.json'; dump(gps_path, gps)
            with patch.object(media, 'command', side_effect=AssertionError('GPS revision read media')), \
                 patch.object(asr.ASRClient, 'transcribe', side_effect=AssertionError('GPS revision submitted ASR')):
                cli.gps_review_package(argparse.Namespace(state=str(state), gps=str(gps_path), reason='User supplied this trip GPS'))
            updated = read(state / 'manifest.json')
            self.assertEqual(updated['packages'], packages); self.assertEqual(updated['frames'], frames)
            association = updated['gps_association']
            self.assertEqual(association['summary']['located_frames'], 2)
            self.assertEqual(association['summary']['matched_stops'], 1)
            self.assertEqual({p['frame_id'] for p in association['frame_locations']}, {'camera30', 'drone30'})
            self.assertFalse(updated['published_verified'])

    def test_daily_location_requires_its_frame_and_supports_legacy_location_shape(self):
        frames = [{'id': 'fa', 'source_id': 'a', 'time': 10}, {'id': 'fb', 'source_id': 'a', 'time': 20}]
        manifest = {'sources': [{'id': 'a', 'duration': 30}], 'frames': frames,
                    'packages': [{'status': 'success', 'core_frame_ids': ['fa', 'fb']}], 'transcription': {}}
        location = {'frame_id': 'fb', 'latitude': 1, 'longitude': 2, 'source': 'drone_srt'}
        finding = {'title': 'view', 'type': 'view', 'reason': 'visible', 'confidence': 'high', 'priority': 'medium',
                   'needs_review': False, 'location': location,
                   'clips': [{'source_id': 'a', 'start': 0, 'end': 30, 'precision': 'sampled_frames', 'evidence_ids': ['fa']}]}
        daily = {'summary': 'day', 'summary_evidence_ids': ['fa'], 'events': [finding], 'interest_points': []}
        records = [{'events': [finding], 'interest_points': []}]
        with self.assertRaises(ValueError): analysis.validate_daily(daily, manifest, records)
        finding['clips'][0]['evidence_ids'].append('fb')
        analysis.validate_daily(daily, manifest, records)

    def test_cli_help_uses_venv_not_implicit_legacy_user_dependencies(self):
        with tempfile.TemporaryDirectory() as td:
            legacy = Path(td) / 'VlogIndex' / 'deps'; legacy.mkdir(parents=True)
            (legacy / 'typing_extensions.py').write_text("raise RuntimeError('legacy deps must not shadow venv')\n", encoding='utf-8')
            environment = dict(os.environ); environment['LOCALAPPDATA'] = td
            environment.pop('VLOG_INDEX_DEPS', None)
            for arguments in (['--help'], ['init', '--help']):
                with self.subTest(arguments=arguments):
                    result = subprocess.run([sys.executable, '-X', 'utf8', str(Path(cli.__file__)), *arguments],
                                            capture_output=True, text=True, env=environment, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('usage:', result.stdout)
                    self.assertNotIn('Traceback', result.stderr)

    def test_custom_asr_model_is_used_by_preflight_and_upload(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': td}):
            wav = Path(td) / 'sample.wav'; wav_file(wav, 0.1); requests = []
            def respond(request):
                requests.append(request)
                if request.method == 'GET': return httpx.Response(200, json={'data': [{'id': 'custom/model'}]})
                self.assertIn(b'custom/model', request.read())
                return httpx.Response(200, json={'text': 'ok'})
            client = asr.ASRClient('http://movable.invalid', model='custom/model')
            client.client = httpx.Client(transport=httpx.MockTransport(respond))
            client.preflight(); client.transcribe(wav, Path(td) / 'raw.json', stream=False)
            self.assertEqual(len(requests), 2)

    def test_init_uses_configured_paths_date_service_and_model(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); source = root / '素材 source'; source.mkdir()
            configuration = root / 'configuration'; configuration.mkdir()
            (configuration / 'preview.cube').write_text('synthetic path fixture', encoding='ascii')
            lut_map = configuration / 'lut-map.json'; dump(lut_map, {'ZVE1:SLOG3CINE': 'preview.cube'})
            for number in (1, 2):
                args = argparse.Namespace(source=str(source), state=str(root / f'state{number}'),
                    temp=str(root / 'temporary'), run_id=f'portable{number}', date='2030-02-03',
                    ffmpeg='custom-ffmpeg', ffprobe='custom-ffprobe', service='http://movable.invalid',
                    asr_model='custom/model', vision_concurrency=3, preview_lut_map=str(lut_map))
                cli.init(args)
                manifest = read(Path(args.state) / 'manifest.json')
                self.assertEqual(manifest['config']['source_root'], str(source.resolve()))
                self.assertEqual(manifest['config']['asr_model'], 'custom/model')
                self.assertEqual(manifest['config']['asr_service'], args.service)
                self.assertEqual(manifest['config']['date'], args.date)
                self.assertEqual(manifest['config']['ffmpeg'], 'custom-ffmpeg')
                self.assertEqual(manifest['config']['preview_luts']['ZVE1:SLOG3CINE'], str((configuration / 'preview.cube').resolve()))

    def test_host_data_root_prefers_localappdata_then_home_fallback(self):
        with patch.dict(os.environ, {'LOCALAPPDATA': 'synthetic-root'}):
            self.assertEqual(store.host_data_root(), Path('synthetic-root') / 'VlogIndex')
        environment = dict(os.environ); environment.pop('LOCALAPPDATA', None)
        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(store.host_data_root(), Path.home() / '.local/share' / 'VlogIndex')

    def test_asr_client_and_adapters_do_not_require_windows_environment(self):
        environment = dict(os.environ); environment.pop('LOCALAPPDATA', None)
        with patch.dict(os.environ, environment, clear=True):
            client = asr.ASRClient('http://movable.invalid')
            self.assertEqual(client.root, Path.home() / '.local/share' / 'VlogIndex' / 'services')
        with patch('os.name', 'posix'):
            self.assertEqual(media.enumerate_adapters(), [])

    def test_init_host_selects_model_roles_and_default_stays_codex(self):
        codex_roles = {'vision': 'Luna', 'semantic': 'gpt-6.1-sol', 'semantic_reasoning_effort': 'high',
                       'final_review': 'ROOT_current_flagship', 'supplement_decision': 'ROOT'}
        claude_roles = {'vision': 'vlog-daily-index:vlog-vision', 'semantic': 'vlog-daily-index:vlog-semantic',
                        'geography': 'vlog-daily-index:vlog-geography', 'semantic_reasoning_effort': 'high', 'final_review': 'ROOT', 'supplement_decision': 'ROOT'}
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); source = root / 'source'; source.mkdir()
            for name, host, expected in (('default', None, codex_roles), ('claude', 'claude-code', claude_roles)):
                args = argparse.Namespace(source=str(source), state=str(root / name), temp=str(root / 'temporary'),
                    run_id=name, date='2030-02-03', ffmpeg='ffmpeg', ffprobe='ffprobe',
                    service='http://movable.invalid', vision_concurrency=3)
                if host: args.host = host
                cli.init(args)
                config = read(Path(args.state) / 'manifest.json')['config']
                self.assertEqual(config['model_roles'], expected)
                self.assertEqual(config['host'], host or 'codex')

    def test_root_review_is_required_and_bound_to_unchanged_final_files(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); source = root / 'source'; source.mkdir(); final = root / 'final'
            manifest = {'run_id': 'fixture', 'sources': [], 'frames': [], 'packages': [], 'transcription': {},
                'config': {'source_root': str(source), 'asr_model': 'fixture/model', 'date': '2030-02-03'}}
            daily = final_context(manifest, root/'state')
            manifest['status'] = report.render(manifest, [], final, daily=daily)['status']
            with self.assertRaises(ValueError): report.publish(manifest, final, source)
            with self.assertRaises(ValueError): report.approve_final(manifest, final, 'Luna', 'looks good')
            report.approve_final(manifest, final, 'ROOT', 'Evidence review passed', root_review(manifest, daily))
            with (final / report.NAMES[2]).open('a', encoding='utf-8') as output: output.write('\nchanged after review\n')
            report.validate_group(final)  # Group hashes alone do not bind Markdown content.
            with self.assertRaises(ValueError): report.publish(manifest, final, source)
            self.assertEqual(list(source.iterdir()), [])
            manifest['status'] = 'partial'
            with self.assertRaises(ValueError): report.approve_final(manifest, final, 'ROOT', 'partial must fail', root_review(manifest, daily))

    def test_publication_refuses_unknown_existing_file_before_writing(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); source = root / 'source'; source.mkdir(); final = root / 'final'
            manifest = {'run_id': 'fixture', 'sources': [], 'frames': [], 'packages': [], 'transcription': {},
                'config': {'source_root': str(source), 'asr_model': 'fixture/model', 'date': '2030-02-03'}}
            daily = final_context(manifest, root/'state')
            manifest['status'] = report.render(manifest, [], final, daily=daily)['status']
            report.approve_final(manifest, final, 'ROOT', 'Fixture review passed', root_review(manifest, daily))
            conflict = source / report.NAMES[2]; conflict.write_text('user document', encoding='utf-8')
            with self.assertRaises(ValueError): report.publish(manifest, final, source)
            self.assertEqual(conflict.read_text(encoding='utf-8'), 'user document')
            self.assertEqual(len(list(source.iterdir())), 1)

    def test_supplement_is_decided_per_interval_and_only_one_round(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'
            first = {'source_id': 's', 'start': 20, 'end': 22, 'reason': 'visible ambiguity'}
            second = {'source_id': 's', 'start': 80, 'end': 82, 'reason': 'possible speech mismatch'}
            manifest = {'state_dir': str(state), 'supplemental_pending': [first, second], 'sources': []}
            dump(state / 'manifest.json', manifest)
            with patch.object(media, 'extract_block', side_effect=AssertionError('Undecided extraction')):
                result = cli.supplement(argparse.Namespace(state=str(state), source_id=None, list_requests=False))
            self.assertEqual(result['awaiting_root_decision'], 2)
            with self.assertRaises(ValueError): analysis.record_supplement_decision(manifest, digest(first), 'accept', 'Sol', 'candidate')
            analysis.record_supplement_decision(manifest, digest(first), 'accept', 'ROOT', 'Observed evidence warrants interval')
            self.assertEqual(len(manifest['supplemental_pending']), 2)
            manifest['supplemental_round'] = {'number': 1, 'request_ids': [digest(first)]}
            with self.assertRaises(ValueError): analysis.record_supplement_decision(manifest, digest(second), 'accept', 'ROOT', 'second round forbidden')
            analysis.record_supplement_decision(manifest, digest(second), 'reject', 'ROOT', 'Existing evidence is sufficient')
            self.assertEqual(manifest['supplemental_pending'], [first])
            self.assertEqual(manifest['supplemental_decisions'][digest(second)]['request'], second)
            self.assertEqual(analysis.merge_intervals([first], 100), [[5, 52]])

    def test_distribution_is_reproducible_and_excludes_user_data(self):
        release_spec = importlib.util.spec_from_file_location('release_tool', Path(__file__).resolve().parents[1] / 'tools' / 'build_release.py')
        release_tool = importlib.util.module_from_spec(release_spec); release_spec.loader.exec_module(release_tool)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / 'vlog-daily-index'; root.mkdir()
            for name in ('SKILL.md', 'requirements.lock', 'requirements-dev.txt'):
                (root / name).write_text('fixture', encoding='utf-8')
            (root / 'VERSION').write_text('0.1.0', encoding='ascii')
            (root / 'scripts').mkdir(); (root / 'scripts' / 'entry.py').write_text('pass', encoding='utf-8')
            (root / 'runs').mkdir(); (root / 'runs' / 'manifest.json').write_text('{"private":true}', encoding='utf-8')
            (root / 'scripts' / 'secret.mp4').write_bytes(b'private-media')
            first = release_tool.build(root, Path(td) / 'dist-a')
            second = release_tool.build(root, Path(td) / 'dist-b')
            self.assertEqual(first['sha256'], second['sha256'])
            with zipfile.ZipFile(first['archive']) as archive:
                self.assertFalse(any('runs/' in name or name.endswith('.mp4') for name in archive.namelist()))
                manifest = json.loads(archive.read('vlog-daily-index/release-manifest.json'))
                import hashlib
                for name, identity in manifest['files'].items():
                    self.assertEqual(hashlib.sha256(archive.read('vlog-daily-index/' + name)).hexdigest(), identity['sha256'])
            verify_spec = importlib.util.spec_from_file_location('verify_tool', Path(__file__).resolve().parents[1] / 'tools' / 'verify_release.py')
            verify_tool = importlib.util.module_from_spec(verify_spec); verify_spec.loader.exec_module(verify_tool)
            verify_tool.verify_archive(first['archive'])
            damaged = Path(td) / 'damaged.zip'
            with zipfile.ZipFile(first['archive']) as original, zipfile.ZipFile(damaged, 'w') as target:
                for entry in original.infolist():
                    target.writestr(entry, b'fail' if entry.filename.endswith('/entry.py') else original.read(entry.filename))
            Path(str(damaged) + '.sha256').write_text(hashlib.sha256(damaged.read_bytes()).hexdigest() + '\n', encoding='ascii')
            with self.assertRaises(ValueError): verify_tool.verify_archive(damaged)

    def test_ndjson_final_empty_text_requires_complete_consumption(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': td}):
            wav = Path(td) / 'sample.wav'; wav_file(wav, 0.1)
            incoming = Stream([b'{"text":"one ","is_final":false}\n',
                               b'{"text":"two","is_final":false}\n',
                               b'{"text":"","is_final":true}\n', b'\n'])
            client = asr.ASRClient('http://test.invalid', protocol=PROTOCOL)
            client.client = httpx.Client(transport=httpx.MockTransport(
                lambda req: httpx.Response(200, headers={'content-type': 'application/x-ndjson'}, stream=incoming)))
            result = client.transcribe(wav, Path(td) / 'raw.json')
            self.assertEqual(result['text'], 'one two')
            self.assertEqual(incoming.consumed, 4); self.assertTrue(incoming.closed)
            self.assertTrue(read(Path(td) / 'raw.json')['complete'])
            self.assertEqual(read(client.gate)['status'], 'idle')

    def test_single_json_short_sample_and_discovery_remains_gated(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': td}):
            wav = Path(td) / 'sample.wav'; wav_file(wav, 0.1)
            calls = []
            def response(req):
                calls.append(req)
                if len(calls) == 1: return httpx.Response(200, json={'text': 'verified sample'})
                return httpx.Response(200, headers={'content-type': 'application/x-ndjson'},
                                      content=b'{"text":"","is_final":true}\n')
            client = asr.ASRClient('http://test.invalid', protocol=PROTOCOL)
            client.client = httpx.Client(transport=httpx.MockTransport(response))
            self.assertEqual(client.transcribe(wav, Path(td) / 'json.json', stream=False)['text'], 'verified sample')
            self.assertTrue(client.transcribe(wav, Path(td) / 'discovery.json', discover=True)['discovery'])
            with self.assertRaises(asr.UnknownServerState): client.transcribe(wav, Path(td) / 'never.json')
            self.assertEqual(len(calls), 2)

    def test_normalized_service_lock_excludes_another_client(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': td}):
            wav = Path(td) / 'sample.wav'; wav_file(wav, 0.1)
            client = asr.ASRClient('HTTP://TEST.INVALID:80', protocol=PROTOCOL)
            with ServiceLock(td, 'http://test.invalid'):
                with self.assertRaises(RuntimeError): client.transcribe(wav, Path(td) / 'never.json')
            self.assertFalse((Path(td) / 'never.json').exists())

    def test_audio_cut_spans_blocks_and_refuses_gap(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); a = root / 'a.wav'; b = root / 'b.wav'; out = root / 'out.wav'
            wav_file(a, 2, 100); wav_file(b, 2, 200)
            blocks = [{'path': str(a), 'start': 0, 'end': 2}, {'path': str(b), 'start': 2, 'end': 4}]
            self.assertTrue(media.cut_audio_blocks(blocks, 1, 3, out))
            with wave.open(str(out), 'rb') as result:
                self.assertEqual(result.getnframes(), 32000)
                self.assertEqual(result.readframes(1), (100).to_bytes(2, 'little', signed=True))
                result.setpos(16000)
                self.assertEqual(result.readframes(1), (200).to_bytes(2, 'little', signed=True))
            blocks[1]['start'] = 2.1
            self.assertFalse(media.cut_audio_blocks(blocks, 1, 3, root / 'gap.wav'))
            self.assertFalse((root / 'gap.wav').exists())

    def test_resume_reuses_completed_media_without_extractor(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); state_dir = root / 'state'; temp = root / 'temp'
            image = root / 'cached.jpg'; image.write_bytes(b'cached-image')
            block = {'index': 0, 'start': 0, 'end': 2, 'samples': [0]}
            frame = {'id': 's-b000-f000', 'source_id': 's', 'path': str(image), 'time': 0}
            source = {'id': 's', 'status': 'ready', 'role': 'drone', 'audio': False, 'blocks': [block]}
            manifest = {'state_dir': str(state_dir), 'temp_dir': str(temp), 'sources': [source],
                        'frames': [], 'transcription': {}, 'config': {}, 'hardware': {}, 'temporary_artifacts': []}
            from test_geography import itinerary
            manifest['itinerary'] = {'data': itinerary()}
            dump(state_dir / 'manifest.json', manifest)
            cache = State(state_dir)
            key = digest({'source': 's', 'block': block, 'extract': {'interval': 10, 'max_edge': 960, 'version': 2}})
            cache.put(key, 'media', 'success', {'frames': [frame]}); cache.close()
            with patch.object(media, 'extract_block', side_effect=AssertionError('cached block re-extracted')):
                cli.prepare(argparse.Namespace(state=str(state_dir), source_id=None, blocks=None))
                cli.prepare(argparse.Namespace(state=str(state_dir), source_id=None, blocks=None))
            self.assertEqual(read(state_dir / 'manifest.json')['frames'], [frame])

    def test_package_core_coverage_and_context_accounting(self):
        with tempfile.TemporaryDirectory() as td:
            source = {'id': 's', 'path': 'video.mp4', 'relative_path': 'video.mp4', 'duration': 125,
                      'role': 'camera', 'metadata': {}}
            frames = [{'id': f'f{i}', 'source_id': 's', 'time': i * 10, 'path': f'{i}.jpg'} for i in range(13)]
            packages = analysis.make_packages(source, frames, [], td)
            core_ids = [fid for package in packages for fid in package['core_frame_ids']]
            self.assertEqual(core_ids, [f['id'] for f in frames])
            package = read(packages[-1]['path'])
            self.assertGreater(len(package['frames']), len(package['core_frame_ids']))
            result = {'package_id': package['package_id'], 'analysed_frame_ids': package['core_frame_ids'],
                      'observations': [{'source_id': 's', 'start': 0, 'end': 125, 'description': 'No event',
                                        'evidence_ids': package['core_frame_ids']}],
                      'events': [], 'interest_points': [], 'supplemental_requests': [], 'summary': 'No event'}
            with self.assertRaises(ValueError): analysis.validate_result(package, result)
            result['analysed_frame_ids'] = [f['id'] for f in package['frames']]
            analysis.validate_result(package, result)

    def test_daily_rejects_transcript_from_another_source(self):
        manifest = {'sources': [{'id': 'a', 'duration': 60}, {'id': 'b', 'duration': 60}],
                    'frames': [{'id': 'fa', 'source_id': 'a', 'time': 10}],
                    'packages': [{'status': 'success', 'core_frame_ids': ['fa']}],
                    'transcription': {'b': {'segments': [{'id': 'tb', 'source_id': 'b', 'start': 0, 'end': 30}]}}}
        finding = {'title': 'Speech', 'type': 'speech', 'reason': 'Said in clip', 'confidence': 'high',
                   'priority': 'medium', 'needs_review': False, 'location': None,
                   'clips': [{'source_id': 'a', 'start': 0, 'end': 30, 'precision': 'chunk', 'evidence_ids': ['tb']}]}
        daily = {'summary': 'Day', 'summary_evidence_ids': ['fa'], 'events': [finding], 'interest_points': []}
        with self.assertRaises(ValueError): analysis.validate_daily(daily, manifest, [])
        finding['clips'][0]['source_id'] = 'b'
        analysis.validate_daily(daily, manifest, [])

    def test_partial_and_failed_sources_are_distinct(self):
        manifest = {'sources': [{'id': 'bad', 'relative_path': 'broken.mp4', 'status': 'failed', 'error': 'moov missing'}],
                    'frames': [], 'packages': [], 'transcription': {}}
        self.assertTrue(report.coverage(manifest)['readable_complete'])
        self.assertFalse(report.coverage(manifest)['complete'])
        manifest['supplemental_pending'] = [{'source_id': 'bad', 'start': 0, 'end': 1}]
        self.assertFalse(report.coverage(manifest)['readable_complete'])
        self.assertTrue(report.coverage(manifest)['analysis_ready'])
        request = manifest['supplemental_pending'][0]
        analysis.record_supplement_decision(manifest, digest(request), 'accept', 'ROOT', 'Synthetic accepted interval must finish before further analysis')
        self.assertFalse(report.coverage(manifest)['analysis_ready'])

    def test_cleanup_does_not_delete_unregistered_or_unpublished(self):
        with tempfile.TemporaryDirectory() as td:
            run = Path(td) / 'run'; run.mkdir(); keep = run / 'keep.wav'; keep.write_bytes(b'keep')
            registered = run / 'registered.wav'; registered.write_bytes(b'temp')
            manifest = {'run_id': 'run', 'published_verified': False, 'status': 'complete',
                        'temporary_artifacts': [str(registered)]}
            with self.assertRaises(ValueError): cleanup_registered(run, manifest)
            self.assertTrue(registered.exists())
            manifest['published_verified'] = True
            cleanup_registered(run, manifest)
            self.assertTrue(keep.exists()); self.assertFalse(registered.exists())


@unittest.skipUnless(os.environ.get('VLOG_TEST_FFMPEG') and os.environ.get('VLOG_TEST_FFPROBE'),
                     'Set VLOG_TEST_FFMPEG and VLOG_TEST_FFPROBE for synthetic actual-PTS integration')
class SyntheticMedia(unittest.TestCase):
    def test_nonzero_pts_and_later_block_preserve_endpoints(self):
        ffmpeg = os.environ['VLOG_TEST_FFMPEG']; ffprobe = os.environ['VLOG_TEST_FFPROBE']
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); video = root / 'synthetic.mp4'
            media.command([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=64x48:r=4:d=12',
                           '-c:v', 'mpeg4', '-q:v', '5', '-output_ts_offset', '7', '-an', '-y', video])
            source = media.probe(video, ffprobe, root)
            self.assertEqual(source['status'], 'ready'); self.assertGreater(source['start_pts'], 0)
            blocks = media.blocks_for(source['sample_times'], source['duration'], seconds=5)
            self.assertGreater(blocks[-1]['start'], 0)
            frames = []
            for block in blocks:
                frames += media.extract_block(ffmpeg, source, block, root / f'b{block["index"]}', {'backend': 'cpu'})
            self.assertEqual(len(frames), len(source['sample_times']))
            self.assertAlmostEqual(frames[0]['time'], 0)
            self.assertAlmostEqual(frames[-1]['time'], source['duration'] - 1/source['fps'], places=3)
            self.assertGreater(frames[-1]['pts'], frames[-1]['time'])


if __name__ == '__main__': unittest.main()
