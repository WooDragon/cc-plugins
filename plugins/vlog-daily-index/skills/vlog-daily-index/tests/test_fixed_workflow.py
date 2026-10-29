"""Fixed command paths for new work and cached recovery; HTTP mock only."""
# All dates, routes and coordinates in this module are synthetic fixtures.
import argparse
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import httpx
from vlog_index import analysis
from vlog_index import media, report
from vlog_index.store import dump, read
from fixture_helpers import final_context

spec = importlib.util.spec_from_file_location('fixed_cli', Path(__file__).resolve().parents[1] / 'scripts' / 'vlog_daily_index.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


def invoke(*arguments):
    output = io.StringIO()
    with patch.object(sys, 'argv', ['vlog_daily_index.py', *map(str, arguments)]), contextlib.redirect_stdout(output):
        cli.main()
    return json.loads(output.getvalue())


class FixedWorkflow(unittest.TestCase):
    def test_final_review_command_blocks_unreviewed_issues_and_changed_evidence(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); source = root / 'source'; source.mkdir(); state = root / 'state'; final = state / 'final'
            manifest = {'run_id': 'review-fixture', 'state_dir': str(state), 'sources': [], 'frames': [], 'packages': [],
                        'transcription': {}, 'config': {'source_root': str(source), 'asr_model': 'mock', 'date': '2030-01-02'}}
            daily = final_context(manifest, state)
            manifest['final'] = report.render(manifest, [], final, daily=daily)
            manifest['status'] = manifest['final']['status']
            dump(state / 'manifest.json', manifest); dump(state / 'daily.validated.json', daily)
            with self.assertRaises(ValueError): report.approve_final(manifest, final, 'ROOT', 'No substantive review yet')
            metadata = invoke('final-review-package', '--state', state)
            template = read(metadata['result_template']); result_path = root / 'review.result.json'
            dump(result_path, template)
            with self.assertRaises(ValueError): invoke('approve-final', '--state', state, '--reviewer', 'ROOT', '--reason', 'Unfilled template must fail', '--review-result', result_path)
            template.update(conclusion='approved', reason='Synthetic fixture checked across all required dimensions',
                            checked_dimensions=sorted(analysis.REVIEW_DIMENSIONS), blocking_remaining=0,
                            issues=[{'id': 'conflict', 'blocking': True, 'status': 'open', 'disposition': 'Still contradictory'}])
            dump(result_path, template)
            with self.assertRaises(ValueError): invoke('approve-final', '--state', state, '--reviewer', 'ROOT', '--reason', 'Open blocking conflict must fail', '--review-result', result_path)
            template['issues'][0].update(status='resolved', disposition='Synthetic route evidence reconciled; remaining uncertainty explicitly recorded')
            dump(result_path, template)
            approved = invoke('approve-final', '--state', state, '--reviewer', 'ROOT', '--reason', 'Synthetic comprehensive review complete', '--review-result', result_path)
            self.assertTrue(approved['approved'])
            baseline = read(state / 'manifest.json')
            for evidence in ('transcription', 'all_stops', 'review_context'):
                changed = copy.deepcopy(baseline)
                if evidence == 'transcription': changed['transcription']['changed-after-review'] = {'segments': [{'text': 'New evidence'}]}
                if evidence == 'all_stops': changed['gps'] = {'stops': [{'stop_id': 'new-stop'}]}
                if evidence == 'review_context': changed['final_review_context'] = {'public_notes': ['Changed route interpretation']}
                dump(state / 'manifest.json', changed)
                with self.subTest(evidence=evidence), self.assertRaises(ValueError): invoke('publish', '--state', state)
                self.assertEqual(list(source.iterdir()), [])

    def test_json_asr_sample_recovers_and_adopts_without_duplicate_upload(self):
        from test_geography import itinerary
        from test_reliability import wav_file, PROTOCOL
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': td}):
            root = Path(td); state = root / 'state'; temp = root / 'temp'
            manifest = {'run_id': 'asr-fixture', 'state_dir': str(state), 'temp_dir': str(temp), 'temporary_artifacts': [],
                        'sources': [{'id': 'camera', 'status': 'ready', 'relative_path': 'camera.mp4', 'role': 'camera', 'audio': True, 'duration': 2}],
                        'frames': [], 'packages': [], 'transcription': {},
                        'itinerary': {'data': itinerary()}, 'config': {'asr_service': 'http://asr.invalid', 'asr_model': 'mock/model', 'ffmpeg': 'unused'}}
            dump(state / 'manifest.json', manifest)
            calls = []
            def respond(request):
                calls.append(request)
                if request.method == 'GET': return httpx.Response(200, json={'data': [{'id': 'mock/model'}]})
                self.assertIn(b'false', request.read())
                return httpx.Response(200, json={'text': 'Synthetic complete sample'})
            real_client = httpx.Client
            def client_factory(*args, **kwargs): return real_client(transport=httpx.MockTransport(respond))
            def extract_audio(ffmpeg, source, start, end, output): wav_file(output, end-start)
            with patch.object(httpx, 'Client', side_effect=client_factory), patch.object(media, 'extract_audio', side_effect=extract_audio):
                invoke('asr-json-sample', '--state', state, '--source-id', 'camera')
                resumed = invoke('asr-json-sample', '--state', state, '--source-id', 'camera')
            self.assertTrue(resumed['reused']); self.assertEqual(sum(r.method == 'POST' for r in calls), 1)
            protocol_path = root / 'protocol.json'; dump(protocol_path, PROTOCOL)
            with patch.object(httpx, 'Client', side_effect=AssertionError('Adoption must not create an HTTP client')):
                first = invoke('adopt-json-sample', '--state', state, '--protocol', protocol_path, '--reason', 'Synthetic stream terminal verified separately')
                second = invoke('adopt-json-sample', '--state', state, '--protocol', protocol_path, '--reason', 'Resume adoption')
            self.assertEqual(first['adopted'], second['adopted'])
            self.assertEqual(len(read(state / 'manifest.json')['transcription']['camera']['segments']), 1)

    def test_source_configuration_uses_fixed_command_and_invalidates_only_downstream(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'
            source = {'id': 'camera', 'status': 'ready', 'relative_path': 'camera.mp4', 'role': 'unknown',
                      'metadata': {'time_verified': False, 'playback_rate_verified': False}}
            manifest = {'state_dir': str(state), 'sources': [source], 'frames': [{'id': 'frame'}],
                        'packages': [{'id': 'visual'}], 'transcription': {'camera': {'segments': []}},
                        'published_verified': True, 'geography': {'old': True}}
            dump(state / 'manifest.json', manifest)
            with self.assertRaises(ValueError):
                invoke('configure-source', '--state', state, '--source-id', 'camera', '--capture-time', '2030-01-02T08:00:00', '--reason', 'unverified timezone must fail')
            self.assertEqual(read(state / 'manifest.json'), manifest)
            invoke('configure-source', '--state', state, '--source-id', 'camera', '--role', 'camera',
                   '--capture-time', '2030-01-02T08:00:00+08:00', '--normal-speed', '--reason', 'Synthetic source metadata verified')
            updated = read(state / 'manifest.json')
            self.assertEqual(updated['sources'][0]['metadata']['captured_at_utc'], '2030-01-02T00:00:00+00:00')
            self.assertTrue(updated['sources'][0]['metadata']['playback_rate_verified'])
            self.assertEqual(updated['frames'], manifest['frames']); self.assertEqual(updated['packages'], manifest['packages'])
            self.assertEqual(updated['transcription'], manifest['transcription'])
            self.assertFalse(updated['published_verified']); self.assertNotIn('geography', updated)

    def test_new_task_map_command_then_resume_uses_cached_query(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': td}):
            root = Path(td); source = root / 'source'; source.mkdir(); state = root / 'state'
            invoke('init', '--source', source, '--state', state, '--temp', root / 'temporary',
                   '--date', '2030-01-02', '--ffmpeg', 'unused-fixture', '--ffprobe', 'unused-fixture',
                   '--service', 'http://unused.invalid')
            queries = root / 'requests.json'; output = root / 'map-evidence.json'
            dump(queries, [{'coordinates': {'latitude': 1, 'longitude': 2, 'crs': 'EPSG:4326'}}])
            calls = []
            def respond(request):
                calls.append(request)
                return httpx.Response(200, json={'features': [{'geometry': {'type': 'Point', 'coordinates': [2.001, 1]},
                                                              'properties': {'name': 'Synthetic lake label'}}]})
            real_client = httpx.Client
            def client_factory(*args, **kwargs): return real_client(transport=httpx.MockTransport(respond))
            with patch.object(httpx, 'Client', side_effect=client_factory):
                first = invoke('map-lookup', '--state', state, '--requests', queries, '--provider', 'photon', '--output', output)
                initial = read(output)
                second = invoke('map-lookup', '--state', state, '--requests', queries, '--provider', 'photon', '--output', output)
            self.assertEqual(len(calls), 1)
            self.assertEqual(first['records'], 1); self.assertEqual(second['failed'], 0)
            self.assertEqual(read(output), initial)
            self.assertEqual(initial[0]['status'], 'success')
            self.assertGreater(initial[0]['candidates'][0]['label_distance_m'], 0)
            self.assertIn('not shoreline', initial[0]['candidates'][0]['distance_meaning'])

    def test_empty_and_failed_map_queries_are_cached_until_explicit_retry(self):
        with tempfile.TemporaryDirectory() as td:
            query = [{'coordinates': {'latitude': 1, 'longitude': 2, 'crs': 'EPSG:4326'}}]
            calls = []
            def respond(request):
                calls.append(request)
                if len(calls) == 1: return httpx.Response(503)
                return httpx.Response(200, json={'features': []})
            with httpx.Client(transport=httpx.MockTransport(respond)) as client:
                failed = analysis.map_lookup(query, 'photon', td, client=client)
                self.assertEqual(failed[0]['status'], 'failed')
                self.assertEqual(analysis.map_lookup(query, 'photon', td, client=client), failed)
                self.assertEqual(len(calls), 1)
                empty = analysis.map_lookup(query, 'photon', td, client=client, retry_failed=True)
                self.assertEqual(empty[0]['status'], 'empty')
                self.assertEqual(analysis.map_lookup(query, 'photon', td, client=client), empty)
                self.assertEqual(len(calls), 2)


if __name__ == '__main__': unittest.main()
