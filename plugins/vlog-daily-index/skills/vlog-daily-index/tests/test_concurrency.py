"""Threaded local scheduling evidence; no GPU, NAS, model or real ASR calls."""
import argparse
import collections
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from vlog_index import media, store
from test_geography import itinerary

spec = importlib.util.spec_from_file_location('concurrent_cli', Path(__file__).resolve().parents[1] / 'scripts' / 'vlog_daily_index.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


def invoke(*args):
    output = io.StringIO()
    with patch.object(sys, 'argv', ['vlog_daily_index.py', *map(str, args)]), contextlib.redirect_stdout(output): cli.main()
    return json.loads(output.getvalue())


def native_capabilities(root):
    path = Path(root) / 'native-capabilities.json'
    store.dump(path, {'schema': 'native_vision_capabilities_v1',
        'source': {'kind': 'current_session_native_tool', 'session_id': 'synthetic-session',
                   'tool': 'collaboration.spawn_agent', 'evidence': 'Synthetic native model enum and image-capable worker fixture'},
        'parameters': {'model': ['gpt-6-luna'], 'reasoning_effort': ['medium'], 'fork_turns': ['none', 'all']},
        'models': [{'id': 'gpt-6-luna', 'family': 'luna', 'native_model': 'gpt-6-luna',
                    'image_input': True, 'reasoning_efforts': ['medium']}]})
    return path


def fixture(root, count=4, slots=3, audio=False):
    state = root / 'state'; temp = root / 'temp'; temp.mkdir()
    raw = root / 'source.bin'; raw.write_bytes(b'Synthetic readonly source')
    length = 30 if audio else 10
    blocks = [{'index': i, 'start': i * length, 'end': (i + 1) * length, 'samples': [i * length]} for i in range(count)]
    source = {'id': 's', 'path': str(raw), 'relative_path': raw.name, 'status': 'ready', 'role': 'camera',
              'audio': audio, 'duration': count * length, 'fps': 1, 'start_pts': 0, 'blocks': blocks,
              'sample_times': [b['samples'][0] for b in blocks], 'metadata': {}, 'size': raw.stat().st_size,
              'mtime_ns': raw.stat().st_mtime_ns, 'sidecars': []}
    cpu = {'backend': 'cpu', 'adapter': None}
    m = {'run_id': 'concurrency-fixture', 'state_dir': str(state), 'temp_dir': str(temp), 'status': 'running',
         'sources': [source], 'frames': [], 'packages': [], 'transcription': {}, 'temporary_artifacts': [],
         'itinerary': {'data': itinerary()}, 'hardware': {'selected': cpu, 'adapters': []},
         'config': {'source_root': str(root), 'date': '2030-01-02', 'asr_service': 'http://asr.invalid',
                    'asr_model': 'mock', 'ffmpeg': 'mock', 'visual_package_mode': 'block_visual_v1', 'extraction_pipeline': 'select_first_v3',
                    'media_slots': [cpu] * slots, 'vision_concurrency': 6, 'ready_package_limit': 99,
                    'temp_limit_bytes': 1024**3, 'min_free_bytes': 0}}
    store.dump(state / 'manifest.json', m); protocol = root / 'protocol.json'; store.dump(protocol, {})
    args = argparse.Namespace(state=str(state), protocol=str(protocol), gps=None, source_id=None, garmin_companion=None)
    return m, state, args


def extract(ffmpeg, source, block, directory, candidate, audio_output=None, preview=None, diagnostics=None, select_before_download=False):
    directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
    image = directory / '0001.jpg'; image.write_bytes(b'synthetic image')
    if audio_output:
        with wave.open(str(audio_output), 'wb') as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
            wav.writeframes(b'\0\0' * round((block['end'] - block['start']) * 16000))
    frame = {'id': f's-b{block["index"]:03}-f000', 'source_id': 's', 'path': str(image),
             'time': block['samples'][0], 'pts': block['samples'][0], 'precision': 'decoded_frame_pts'}
    if select_before_download: frame['extraction_pipeline'] = 'select_first_v3'
    return [frame]


class MockASR:
    active = peak = calls = 0
    lock = threading.Lock()
    def __init__(self, *args, **kwargs):
        if kwargs.get('concurrency') != 1: raise AssertionError('ASR must remain one request')
    def preflight(self): pass
    def transcribe(self, wav, raw):
        with self.lock:
            type(self).active += 1; type(self).calls += 1; type(self).peak = max(type(self).peak, type(self).active)
        try:
            time.sleep(0.01)
            return {'text': 'Synthetic complete transcript'}
        finally:
            with self.lock: type(self).active -= 1


class Concurrency(unittest.TestCase):
    def setUp(self): MockASR.active = MockASR.peak = MockASR.calls = 0

    def test_fixed_configuration_requires_matching_hardware_and_preserves_legacy_mode(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'LOCALAPPDATA': str(Path(td) / 'host-profile')}):
            root = Path(td); m, state, _ = fixture(root)
            m['config'].pop('visual_package_mode'); m['config'].pop('extraction_pipeline'); store.dump(state / 'manifest.json', m)
            source = m['sources'][0]; block = source['blocks'][0]
            legacy_key = media.extraction_key(source, block)
            self.assertEqual(legacy_key, store.digest({'source': source['id'], 'block': block, 'extract': {'interval': 10, 'max_edge': 960, 'version': 2}}))
            self.assertNotEqual(legacy_key, media.extraction_key(source, block, pipeline='select_first_v3'))
            with self.assertRaises(ValueError): invoke('configure-concurrency', '--state', state, '--media-slots', 4)
            adapter = {'index': 0, 'name': 'Synthetic Arc A380', 'vendor_id': 0x8086, 'device_id': 1}
            igpu = {'index': 1, 'name': 'Synthetic Intel UHD', 'vendor_id': 0x8086, 'device_id': 2}
            report_path = root / 'hardware-report.json'
            store.dump(report_path, {'validated_slots': [{'backend': 'qsv', 'adapter': adapter}] * 2 + [{'backend': 'qsv', 'adapter': igpu}] * 2})
            with patch.object(media, 'enumerate_adapters', return_value=[adapter, igpu]):
                configured = invoke('configure-concurrency', '--state', state, '--media-slots', 4, '--hardware-report', report_path)
            self.assertEqual(len(configured['media_slots']), 4); self.assertEqual(configured['asr_concurrency'], 1)
            self.assertEqual(configured['visual_package_mode'], 'legacy')
            default_profile = Path(os.environ['LOCALAPPDATA']) / 'VlogIndex' / 'hardware-profile.json'
            store.dump(default_profile, store.read(report_path))
            other_cwd = root / 'another-project'; other_cwd.mkdir()
            with contextlib.chdir(other_cwd), patch.object(media, 'enumerate_adapters', return_value=[adapter, igpu]):
                reused = invoke('configure-concurrency', '--state', state, '--media-slots', 4)
            self.assertEqual(len(reused['media_slots']), 4, 'Host profile must not depend on the current project directory')
            baseline = (state / 'manifest.json').read_bytes()
            with patch.object(media, 'enumerate_adapters', return_value=[]), self.assertRaises(ValueError):
                invoke('configure-concurrency', '--state', state, '--media-slots', 4)
            self.assertEqual((state / 'manifest.json').read_bytes(), baseline)

    def test_verified_media_slots_overlap_but_state_writes_stay_on_coordinator_and_resume_is_cached(self):
        for slots in (3, 4):
            with self.subTest(slots=slots), tempfile.TemporaryDirectory() as td:
                m, state, args = fixture(Path(td), count=slots + 1, slots=slots); barrier = threading.Barrier(slots, timeout=5)
                main = threading.get_ident(); workers = set(); writes = []; calls = []; lock = threading.Lock()
                real_put = store.State.put; real_save = cli.save
                def worker(*pos, **kw):
                    block = pos[2]
                    with lock: workers.add(threading.get_ident()); calls.append(block['index'])
                    if block['index'] < slots: barrier.wait()
                    return extract(*pos, **kw)
                def put(obj, *pos, **kw): writes.append(threading.get_ident()); return real_put(obj, *pos, **kw)
                def save(value): writes.append(threading.get_ident()); return real_save(value)
                with patch.object(cli.asr, 'ASRClient', MockASR), patch.object(media, 'extract_block', worker), patch.object(store.State, 'put', put), patch.object(cli, 'save', save):
                    cli.continue_day(args)
                updated = store.read(state / 'manifest.json')
                self.assertEqual(len(workers), slots); self.assertNotIn(main, workers); self.assertEqual(set(writes), {main})
                self.assertEqual(collections.Counter(calls), collections.Counter(range(slots + 1)))
                self.assertEqual(len({f['id'] for f in updated['frames']}), slots + 1)
                self.assertTrue(all(f['extraction_pipeline'] == 'select_first_v3' for f in updated['frames']))
                self.assertEqual(len(updated['packages']), slots + 1)
                with patch.object(cli.asr, 'ASRClient', MockASR), patch.object(media, 'extract_block', side_effect=AssertionError('successful block repeated')):
                    cli.continue_day(args)
                resumed = store.read(state / 'manifest.json')
                self.assertEqual(resumed['frames'], updated['frames']); self.assertEqual(resumed['packages'], updated['packages'])

    def test_single_asr_drains_all_chunks_and_does_not_delay_stable_visual_packages(self):
        with tempfile.TemporaryDirectory() as td:
            _, state, args = fixture(Path(td), count=4, slots=4, audio=True)
            seen_before_asr = []; release_first_block = threading.Event()
            original = MockASR.transcribe
            def transcribe(client, wav, raw):
                seen_before_asr.append(len(store.read(state / 'manifest.json')['packages']))
                release_first_block.set()
                return original(client, wav, raw)
            def out_of_order_blocks(*pos, **kw):
                if pos[2]['index'] == 0 and not release_first_block.wait(5):
                    raise AssertionError('Later local audio never reached the ASR worker')
                return extract(*pos, **kw)
            with patch.object(cli.asr, 'ASRClient', MockASR), patch.object(media, 'extract_block', out_of_order_blocks), patch.object(MockASR, 'transcribe', transcribe):
                cli.continue_day(args)
            updated = store.read(state / 'manifest.json')
            self.assertEqual(MockASR.peak, 1); self.assertEqual(MockASR.calls, 4)
            self.assertTrue(any(seen_before_asr)); self.assertEqual(len(updated['transcription']['s']['segments']), 4)
            starts = [segment['start'] for segment in updated['transcription']['s']['segments']]
            self.assertEqual(starts, sorted(starts), 'Committed full transcripts must remain chronological despite out-of-order blocks')
            for package in updated['packages']: self.assertEqual(store.read(package['path'])['transcripts'], [])

    def test_pause_and_queue_backpressure_stop_new_work_then_resume_without_duplicate_blocks(self):
        for mode in ('explicit_pause', 'queue_pressure', 'disk_pressure'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as td:
                m, state, args = fixture(Path(td), slots=1); calls = []
                if mode == 'queue_pressure': m['config']['ready_package_limit'] = 1
                if mode == 'disk_pressure':
                    sentinel = Path(m['temp_dir']) / 'unpublished.bin'; sentinel.write_bytes(b'keep me')
                    m['temporary_artifacts'].append(str(sentinel)); m['config']['temp_limit_bytes'] = 1
                store.dump(state / 'manifest.json', m)
                def worker(*pos, **kw):
                    calls.append(pos[2]['index'])
                    if mode == 'explicit_pause': (state / 'pause-media.request').touch()
                    return extract(*pos, **kw)
                with patch.object(cli.asr, 'ASRClient', MockASR), patch.object(media, 'extract_block', worker): result = cli.continue_day(args)
                self.assertEqual(calls, [] if mode == 'disk_pressure' else [0])
                self.assertEqual(result['status'], 'paused' if mode == 'explicit_pause' else 'paused_backpressure')
                if mode == 'disk_pressure': self.assertEqual(sentinel.read_bytes(), b'keep me')
                (state / 'pause-media.request').unlink(missing_ok=True)
                invoke('configure-concurrency', '--state', state, '--media-slots', 1, '--ready-package-limit', 99, '--temp-limit-gib', 1, '--min-free-gib', 0)
                with patch.object(cli.asr, 'ASRClient', MockASR), patch.object(media, 'extract_block', extract): cli.continue_day(args)
                updated = store.read(state / 'manifest.json')
                self.assertEqual(len(updated['frames']), 4); self.assertEqual(len({f['id'] for f in updated['frames']}), 4)

    def test_failed_device_falls_back_once_without_duplicate_frame_registration(self):
        with tempfile.TemporaryDirectory() as td:
            m, state, args = fixture(Path(td), count=2, slots=1)
            adapter = {'index': 0, 'name': 'Synthetic Intel', 'vendor_id': 0x8086, 'device_id': 1}
            m['config']['media_slots'] = [{'backend': 'qsv', 'adapter': adapter}]; store.dump(state / 'manifest.json', m)
            calls = []
            def worker(*pos, **kw):
                calls.append((pos[2]['index'], pos[4]['backend']))
                if pos[4]['backend'] == 'qsv': raise RuntimeError('Synthetic device failure')
                return extract(*pos, **kw)
            with patch.object(cli.asr, 'ASRClient', MockASR), patch.object(media, 'enumerate_adapters', return_value=[adapter]), patch.object(media, 'extract_block', worker): cli.continue_day(args)
            updated = store.read(state / 'manifest.json')
            self.assertEqual(calls, [(0, 'qsv'), (0, 'd3d11va'), (1, 'qsv'), (1, 'd3d11va')])
            self.assertEqual(len(updated['frames']), 2); self.assertEqual(len({f['id'] for f in updated['frames']}), 2)
            self.assertEqual(len(updated['media_errors']), 2)

    def test_visual_claims_are_dynamic_unique_capped_and_do_not_wait_for_main_run_lock(self):
        with tempfile.TemporaryDirectory() as td:
            m, state, _ = fixture(Path(td))
            m['packages'] = [{'id': f'p{i}', 'status': 'waiting_ai', 'core_frame_ids': [],
                              'result_path': str(Path(td) / f'p{i}.result.json')} for i in range(8)]
            store.dump(state / 'manifest.json', m); before = (state / 'manifest.json').read_bytes()
            with store.RunLock(state):
                small = invoke('vision-queue', '--state', state, '--available-workers', 2)
                self.assertEqual(small['recommended_vision_workers'], 1)
                arguments = ['vision-queue', '--state', state, '--available-workers', 7, '--native-capabilities', native_capabilities(Path(td))]
                for i in range(6): arguments += ['--claim-worker', f'worker{i}']
                first = invoke(*arguments)
            self.assertEqual(len({p['id'] for p in first['assigned']}), 6)
            full = invoke('vision-queue', '--state', state, '--available-workers', 3)
            self.assertEqual(full['recommended_vision_workers'], 0)
            with self.assertRaises(ValueError): invoke('vision-queue', '--state', state, '--available-workers', 3, '--claim-worker', 'seventh', '--native-capabilities', native_capabilities(Path(td)))
            # A finished worker's file awaits the coordinator; release must not rerun its model.
            store.dump(first['assigned'][0]['result_path'], {'awaiting_coordinator_validation': True})
            released = invoke('vision-queue', '--state', state, '--available-workers', 2, '--release', first['assigned'][0]['id'], '--claim-worker', 'replacement', '--native-capabilities', native_capabilities(Path(td)))
            self.assertEqual(len(released['assigned']), 1)
            self.assertNotEqual(released['assigned'][0]['id'], first['assigned'][0]['id'])
            self.assertEqual((state / 'manifest.json').read_bytes(), before)

    def test_completed_blocks_keep_package_identity_when_frames_arrive_out_of_order_and_asr_arrives_later(self):
        with tempfile.TemporaryDirectory() as td:
            m, state, _ = fixture(Path(td), count=2)
            source = m['sources'][0]
            for block in reversed(source['blocks']):
                m['frames'] += extract('mock', source, block, Path(m['temp_dir']) / str(block['index']), {'backend': 'cpu'})
                cli.stable_block_packages(m, source, block, None)
            before = {p['id']: store.file_hash(p['path']) for p in m['packages']}
            m['transcription']['s'] = {'status': 'success', 'segments': [{'id': 'later-asr', 'start': 0, 'end': 20, 'text': 'Later transcript'}]}
            store.dump(state / 'manifest.json', m)
            cli.packages(argparse.Namespace(state=str(state), source_id=None, gps=None, garmin_companion=None))
            updated = store.read(state / 'manifest.json')
            self.assertEqual({p['id']: store.file_hash(p['path']) for p in updated['packages']}, before)
            self.assertEqual(collections.Counter(f for p in updated['packages'] for f in p['core_frame_ids']), collections.Counter(f['id'] for f in m['frames']))

    def test_invalid_visual_result_has_one_explicit_archived_correction_and_no_background_retry(self):
        with tempfile.TemporaryDirectory() as td:
            m, state, _ = fixture(Path(td), count=1); source = m['sources'][0]; block = source['blocks'][0]
            m['frames'] = extract('mock', source, block, Path(m['temp_dir']) / 'frames', {'backend': 'cpu'})
            package = cli.stable_block_packages(m, source, block, None)[0]
            invoke('vision-queue', '--state', state, '--available-workers', 2, '--claim-worker', 'synthetic-worker', '--native-capabilities', native_capabilities(Path(td)))
            result_path = Path(package['result_path']); store.dump(result_path, {})
            original = result_path.read_bytes()
            self.assertEqual(len(invoke('import-results', '--state', state)['errors']), 1)
            with patch.object(cli.analysis, 'validate_result', side_effect=AssertionError('invalid result retried in background')):
                self.assertEqual(invoke('import-results', '--state', state)['errors'], [])
            store.dump(result_path, {'a_new_result': 'must not be discarded'})
            with self.assertRaises(ValueError): invoke('retry-visual', '--state', state, '--package-id', package['id'], '--reason', 'Synthetic correction')
            self.assertEqual(store.read(result_path)['a_new_result'], 'must not be discarded')
            result_path.write_bytes(original)
            correction = invoke('retry-visual', '--state', state, '--package-id', package['id'], '--reason', 'ROOT observed a synthetic missing-field error')
            self.assertEqual(Path(correction['archive']).read_bytes(), original); self.assertFalse(result_path.exists())
            self.assertNotIn(package['id'], store.read(state / 'vision-dispatch' / 'claims.json'))
            store.dump(result_path, {})
            invoke('import-results', '--state', state)
            with self.assertRaises(ValueError): invoke('retry-visual', '--state', state, '--package-id', package['id'], '--reason', 'Second correction is forbidden')
            self.assertEqual(Path(correction['archive']).read_bytes(), original)
