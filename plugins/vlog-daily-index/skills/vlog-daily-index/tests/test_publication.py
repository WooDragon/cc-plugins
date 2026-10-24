"""Release regressions with invented routes, coordinates and dates; no external services."""
import argparse
import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from vlog_index import analysis, asr, media
from vlog_index.store import dump, read
from test_geography import finding, itinerary
from test_fixed_workflow import invoke

spec = importlib.util.spec_from_file_location('publication_cli', Path(__file__).resolve().parents[1] / 'scripts' / 'vlog_daily_index.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


class PublicationRegressions(unittest.TestCase):
    def test_prompt_upgrade_preserves_legacy_cache_until_explicit_refresh(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); state = root / 'state'; temporary = root / 'temp'; temporary.mkdir()
            frame = {'id': 'legacy-frame', 'source_id': 'camera', 'time': 10, 'path': str(temporary / 'synthetic.jpg')}
            source = {'id': 'camera', 'status': 'ready', 'path': str(root / 'synthetic.mp4'), 'relative_path': 'synthetic.mp4',
                      'role': 'camera', 'duration': 30, 'metadata': {}}
            old_path = state / 'legacy.package.json'
            dump(old_path, {'package_id': 'synthetic-legacy', 'prompt_version': '1', 'core_frame_ids': [frame['id']], 'frames': [frame]})
            old_bytes = old_path.read_bytes()
            old_package = {'id': 'synthetic-legacy', 'path': str(old_path), 'result_path': str(state / 'legacy.result.json'),
                           'source_id': 'camera', 'status': 'success', 'core_frame_ids': [frame['id']]}
            manifest = {'run_id': 'synthetic-legacy-run', 'state_dir': str(state), 'temp_dir': str(temporary), 'sources': [source],
                        'frames': [frame], 'packages': [old_package], 'transcription': {}, 'temporary_artifacts': [],
                        'config': {'prompt_version': '1'}, 'geography': {'synthetic_previous_result': True},
                        'root_final_review': {'approved': True}, 'published_verified': True}
            dump(state / 'manifest.json', manifest)
            self.assertEqual(invoke('packages', '--state', state), [])
            unchanged = read(state / 'manifest.json')
            self.assertEqual(unchanged['packages'], [old_package]); self.assertTrue(unchanged['root_final_review']['approved'])
            self.assertEqual(old_path.read_bytes(), old_bytes)
            refreshed = invoke('packages', '--state', state, '--refresh')
            self.assertEqual(len(refreshed), 1); self.assertNotEqual(refreshed[0]['id'], old_package['id'])
            new_payload = read(refreshed[0]['path'])
            self.assertEqual(new_payload['prompt_version'], analysis.PROMPT_VERSION); self.assertTrue(new_payload['instructions'].strip())
            updated = read(state / 'manifest.json')
            self.assertFalse(updated['published_verified']); self.assertNotIn('geography', updated); self.assertNotIn('root_final_review', updated)
            self.assertEqual(old_path.read_bytes(), old_bytes, 'Prompt refresh must retain historical package evidence')

    def test_first_geography_uses_supplied_gps_without_revision_or_reprocessing(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); state = root / 'state'; temporary = root / 'temp'; temporary.mkdir()
            frame_id = 'camera-b000-f000'; image = temporary / 'synthetic.jpg'; image.write_bytes(b'synthetic frame fixture')
            source = {'id': 'camera', 'path': str(root / 'synthetic-camera.mp4'), 'relative_path': 'synthetic-camera.mp4',
                      'status': 'ready', 'role': 'camera', 'audio': False, 'duration': 60, 'sample_times': [30],
                      'blocks': [{'index': 0, 'start': 0, 'end': 60, 'samples': [30]}],
                      'metadata': {'captured_at_utc': '2030-01-02T00:00:00+00:00', 'time_verified': True,
                                   'playback_rate_verified': True, 'location_points': []}}
            manifest = {'run_id': 'synthetic-first-geography', 'state_dir': str(state), 'temp_dir': str(temporary),
                        'revision': 1, 'sources': [source], 'frames': [{'id': frame_id, 'source_id': 'camera', 'time': 30,
                                                                   'path': str(image), 'precision': 'decoded_frame_pts'}],
                        'packages': [], 'transcription': {'camera': {'status': 'no_audio', 'segments': []}},
                        'temporary_artifacts': [], 'config': {'date': '2030-01-02', 'timezone': 'UTC', 'asr_model': 'mock',
                                                            'visual_package_mode': 'block_visual_v1'}}
            gps = {'points': [{'timestamp_utc': '2030-01-02T00:00:00Z', 'latitude': 1, 'longitude': 2,
                               'source_file': 'synthetic.fit', 'segment_id': 'synthetic:0'},
                              {'timestamp_utc': '2030-01-02T00:01:00Z', 'latitude': 1, 'longitude': 2.001,
                               'source_file': 'synthetic.fit', 'segment_id': 'synthetic:0'}],
                   'quality': {'coverage_windows': [{'start_utc': '2030-01-02T00:00:00Z', 'end_utc': '2030-01-02T00:01:00Z'}]},
                   'gaps': [], 'stops': [{'stop_id': 'synthetic-stop', 'start_utc': '2030-01-02T00:00:00Z',
                                         'end_utc': '2030-01-02T00:01:00Z', 'latitude': 1, 'longitude': 2,
                                         'source': 'garmin_fit', 'source_file': 'synthetic.fit'}]}
            gps_path = root / 'gps.json'; dump(gps_path, gps); dump(state / 'manifest.json', manifest)
            itinerary_path = root / 'itinerary.json'; dump(itinerary_path, itinerary())
            with patch.object(media, 'command', side_effect=AssertionError('First geography read media')), \
                 patch.object(asr.ASRClient, 'transcribe', side_effect=AssertionError('First geography submitted ASR')):
                cli.attach_itinerary(argparse.Namespace(state=str(state), itinerary=str(itinerary_path), map_evidence=None))
                cli.packages(argparse.Namespace(state=str(state), gps=str(gps_path), source_id=None, garmin_companion=None))
                package_meta = read(state / 'manifest.json')['packages'][0]; package = read(package_meta['path'])
                self.assertTrue(package['instructions'].strip())
                self.assertEqual(package['prompt_version'], analysis.PROMPT_VERSION)
                self.assertTrue(all(key in package for key in ('source', 'frames', 'result_schema', 'result_path')))
                event = finding(frame_id, 'camera'); event['location'] = package['gps'][0]
                dump(package['result_path'], {'package_id': package['package_id'], 'analysed_frame_ids': [frame_id],
                     'observations': [{'source_id': 'camera', 'start': 0, 'end': 60, 'description': 'Synthetic visible scene',
                                       'evidence_ids': [frame_id]}], 'events': [event], 'interest_points': [],
                     'supplemental_requests': [], 'summary': 'Synthetic visible scene'})
                imported = cli.import_results(argparse.Namespace(state=str(state), source_id=None, refresh=False))
                self.assertEqual(imported['errors'], [])
                before = read(state / 'manifest.json'); self.assertNotIn('gps_association', before)
                daily_path = root / 'daily.json'
                dump(daily_path, {'summary': 'Synthetic day', 'summary_evidence_ids': [frame_id], 'events': [event], 'interest_points': []})
                metadata = cli.geography_package(argparse.Namespace(state=str(state), daily=str(daily_path)))
            after = read(state / 'manifest.json'); geo = read(metadata['path'])
            self.assertEqual(after['revision'], 1); self.assertNotIn('publication_history', after)
            for key in ('frames', 'packages', 'transcription'): self.assertEqual(after[key], before[key])
            self.assertTrue(any(point.get('frame_id') == frame_id for point in geo['gps_records']))
            self.assertEqual(geo['gps_coverage']['summary']['located_frames'], 1)
            self.assertEqual(geo['gps_coverage']['summary']['matched_stops'], 1)

    def test_asr_only_cannot_invent_frame_precision_or_narrow_chunk_but_mixed_and_service_evidence_remain_valid(self):
        manifest = {'sources': [{'id': 'a', 'duration': 60}],
                    'frames': [{'id': 'frame', 'source_id': 'a', 'time': 12.15}],
                    'packages': [{'status': 'success', 'core_frame_ids': ['frame']}],
                    'transcription': {'a': {'segments': [{'id': 'speech', 'source_id': 'a', 'start': 0, 'end': 30,
                                                        'text': 'Synthetic speech', 'precision': 'chunk'}]}}}
        event = finding('speech', 'a'); event['clips'][0].update(start=0, end=30, precision='chunk')
        daily = {'summary': 'Synthetic speech', 'summary_evidence_ids': ['speech'], 'events': [event], 'interest_points': []}
        analysis.validate_daily(daily, manifest, [])
        for precision, start, end in [('decoded_frame_pts', 12.1, 12.2), ('sampled_frames', 0, 30),
                                      ('chunk', 12.1, 12.2), ('service_segment', 0, 30)]:
            invalid = copy.deepcopy(daily); invalid['events'][0]['clips'][0].update(precision=precision, start=start, end=end)
            with self.subTest(precision=precision, interval=(start, end)), self.assertRaises(ValueError):
                analysis.validate_daily(invalid, manifest, [])
        mixed = copy.deepcopy(daily)
        mixed['events'][0]['clips'][0].update(start=12.1, end=12.2, precision='decoded_frame_pts', evidence_ids=['frame', 'speech'])
        analysis.validate_daily(mixed, manifest, [])
        service_manifest = copy.deepcopy(manifest)
        service_manifest['transcription']['a']['segments'][0].update(start=12.1, end=12.2, precision='service_segment')
        service_daily = copy.deepcopy(daily); service_daily['events'][0]['clips'][0].update(start=12.1, end=12.2, precision='service_segment')
        analysis.validate_daily(service_daily, service_manifest, [])
