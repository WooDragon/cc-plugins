"""Itinerary and geography provenance boundaries; no external map requests."""
# All dates, routes and coordinates in this module are synthetic fixtures.
import copy
import argparse
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from vlog_index import analysis
from vlog_index import media, asr, report
from vlog_index.store import digest, dump, read
from fixture_helpers import final_context

spec = importlib.util.spec_from_file_location('geo_cli', Path(__file__).resolve().parents[1] / 'scripts' / 'vlog_daily_index.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


def itinerary():
    return {'title': 'Synthetic trip', 'source_refs': [
        {'id': 'source1', 'kind': 'chat', 'reference': 'synthetic-chat-reference', 'excerpt': 'Travel to the lake area'}],
        'entries': [{'id': 'route1', 'date': '2030-01-02', 'place': 'Synthetic lake region',
                     'notes': 'Planned route; not proof of arrival', 'source_refs': ['source1']}]}


def map_record():
    return {'id': 'map1', 'provider': 'local-http-mock', 'query_type': 'reverse_geocode',
            'coordinates': {'latitude': 1, 'longitude': 2, 'crs': 'EPSG:4326'},
            'request_sanitized': {'location': '2,1'}, 'response': {'address': 'Synthetic region'},
            'queried_at': '2030-01-02T00:00:00Z', 'candidates': ['Synthetic region'], 'precision': 'nearby_area',
            'related_gps_ids': ['gps1'], 'itinerary_refs': ['route1']}


def finding(evidence='fa', source='a'):
    return {'title': 'Lake view', 'type': 'view', 'reason': 'Visible lake', 'confidence': 'high',
            'priority': 'medium', 'needs_review': False, 'location': None,
            'clips': [{'source_id': source, 'start': 0, 'end': 30, 'precision': 'sampled_frames', 'evidence_ids': [evidence]}]}


def geography_fixture():
    first = finding(); second = finding('fb', 'b')
    key1 = analysis.finding_key('events', 0, first); key2 = analysis.finding_key('interest_points', 0, second)
    package = {'package_id': 'fixture-package', 'itinerary': itinerary(), 'map_evidence': [map_record()],
               'findings': [{'finding_key': key1, 'finding': first}, {'finding_key': key2, 'finding': second}],
               'gps_records': [{'id': 'gps1', 'source_id': 'a', 'frame_id': 'fa', 'latitude': 1, 'longitude': 2}]}
    result = {'package_id': package['package_id'], 'associations': [
        {'finding_key': key1, 'status': 'approximate', 'region': 'Synthetic lake region', 'place_name': None,
         'subject_kind': 'recording_camera', 'confidence': 'medium', 'reason': 'Route and recorded position agree; exact shore uncertain',
         'evidence_ids': ['fa'], 'itinerary_refs': ['route1'], 'gps_refs': ['gps1'], 'map_evidence_ids': ['map1'],
         'alternatives': ['Other shore in the same region']},
        {'finding_key': key2, 'status': 'unresolved', 'region': None, 'place_name': None,
         'subject_kind': 'visible_subject', 'confidence': 'low', 'reason': 'Distant subject cannot be named from camera position',
         'evidence_ids': ['fb'], 'itinerary_refs': [], 'gps_refs': [], 'map_evidence_ids': [], 'alternatives': []}]}
    return package, result


class GeographyBoundaries(unittest.TestCase):
    def test_same_source_nested_clip_locations_do_not_leak_between_ranges(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'; output = state / 'final'
            manifest = {'run_id': 'clip-locations', 'sources': [{'id': 'a', 'status': 'ready', 'relative_path': 'same-camera.mp4',
                         'duration': 240, 'sample_times': [150], 'metadata': {}}],
                        'frames': [{'id': 'fa', 'source_id': 'a', 'time': 150}],
                        'packages': [{'id': 'visual', 'status': 'success', 'core_frame_ids': ['fa']}],
                        'transcription': {'a': {'status': 'success', 'segments': [{'id': 'speech', 'source_id': 'a', 'start': 0, 'end': 31, 'text': 'Early speech'}]}},
                        'config': {'asr_model': 'mock', 'date': '2030-01-02', 'timezone': 'UTC'}}
            final_context(manifest, state)
            event = finding()
            event['clips'] = [{'source_id': 'a', 'start': 0, 'end': 200, 'precision': 'sampled_frames', 'evidence_ids': ['fa']},
                              {'source_id': 'a', 'start': 0, 'end': 31, 'precision': 'chunk', 'evidence_ids': ['speech']}]
            daily = {'summary': 'Synthetic ranges', 'summary_evidence_ids': ['fa'], 'events': [event], 'interest_points': []}
            association = {'finding_key': analysis.finding_key('event', 1, event), 'status': 'approximate',
                           'region': 'General route area', 'place_name': None, 'subject_kind': 'recording_camera', 'confidence': 'low',
                           'reason': 'Different intervals have different GPS coverage', 'evidence_ids': ['fa', 'speech'],
                           'itinerary_refs': ['r'], 'gps_refs': [], 'map_evidence_ids': [], 'alternatives': [],
                           'clip_associations': [
                               {'source_id': 'a', 'start': 0, 'end': 200, 'region': 'Visual-range-only-location', 'place_name': None, 'reason': 'Later visual GPS evidence'},
                               {'source_id': 'a', 'start': 0, 'end': 31, 'region': None, 'place_name': None, 'reason': 'Early-speech-no-GPS'}]}
            package = {'package_id': 'clip-package', 'findings': [{'finding_key': association['finding_key'], 'finding': event}],
                       'itinerary': manifest['itinerary']['data'], 'gps_records': [], 'map_evidence': []}
            data = analysis.validate_geography({'package_id': 'clip-package', 'associations': [association]}, package)
            manifest['geography_package'] = {'package_id': 'clip-package'}
            manifest['geography'] = {'package_id': 'clip-package', 'data': data, 'sha256': digest(data),
                                     'input_digests': analysis.geography_bindings(manifest, daily)}
            report.render(manifest, [], output, daily=daily)
            markdown = (output / report.NAMES[2]).read_text(encoding='utf-8')
            self.assertEqual(markdown.count('Visual-range-only-location'), 1)
            self.assertEqual(markdown.count('Early-speech-no-GPS'), 1)
            visual = markdown.split('原片 00:00:00–00:03:20', 1)[1].split('原片 00:00:00–00:00:31', 1)[0]
            speech = markdown.split('原片 00:00:00–00:00:31', 1)[1]
            self.assertIn('Visual-range-only-location', visual); self.assertNotIn('Early-speech-no-GPS', visual)
            self.assertIn('Early-speech-no-GPS', speech); self.assertNotIn('Visual-range-only-location', speech)

    def test_targeted_geography_pipeline_preserves_prior_media_and_renders_inference(self):
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / 'state'; daily_path = Path(td) / 'daily.json'
            frames = [{'id': 'fa', 'source_id': 'a', 'time': 10}]
            packages = [{'id': 'visual1', 'status': 'success', 'core_frame_ids': ['fa']}]
            transcription = {'a': {'status': 'success', 'segments': []}}
            manifest = {'run_id': 'geo-fixture', 'state_dir': str(state), 'sources': [
                {'id': 'a', 'status': 'ready', 'relative_path': 'camera.mp4', 'duration': 30, 'sample_times': [10], 'metadata': {}}],
                'frames': frames, 'packages': packages, 'transcription': transcription, 'published_verified': True,
                'config': {'asr_model': 'mock-model', 'date': '2030-01-02', 'timezone': 'UTC'},
                'gps_association': {'frame_locations': [{'frame_id': 'fa', 'source_id': 'a', 'latitude': 1, 'longitude': 2,
                                                       'crs': 'EPSG:4326', 'source': 'garmin_fit'}]}}
            daily = {'summary': 'A lake was visible.', 'summary_evidence_ids': ['fa'], 'events': [finding()], 'interest_points': []}
            dump(state / 'manifest.json', manifest); dump(state / 'analysis' / 'visual1.json', {'events': [], 'interest_points': []})
            dump(daily_path, daily); itinerary_path = Path(td) / 'itinerary.json'; dump(itinerary_path, itinerary())
            maps_path = Path(td) / 'map-cache.json'; dump(maps_path, [map_record()])
            with patch.object(media, 'command', side_effect=AssertionError('Geography must not read media')), \
                 patch.object(asr.ASRClient, 'transcribe', side_effect=AssertionError('Geography must not submit ASR')):
                cli.attach_itinerary(argparse.Namespace(state=str(state), itinerary=str(itinerary_path), map_evidence=str(maps_path)))
                metadata = cli.geography_package(argparse.Namespace(state=str(state), daily=str(daily_path)))
                package = read(metadata['path']); item = package['findings'][0]
                template = state / 'geography.template.json'
                self.assertEqual(len(read(template)['associations']), len(package['findings']))
                with self.assertRaises(ValueError): cli.import_geography(argparse.Namespace(state=str(state), result=str(template)))
                targets_template = Path(td) / 'targets-template.json'
                cli.subject_targets(argparse.Namespace(state=str(state), template=str(targets_template), targets=None))
                self.assertIn(item['finding_key'], read(targets_template)['available_finding_keys'])
                target_file = Path(td) / 'targets.json'
                dump(target_file, {'targets': [{'target_id': 'lake-main', 'subject': 'Island in the lake', 'finding_keys': ['unknown-finding']}]})
                with self.assertRaises(ValueError): cli.subject_targets(argparse.Namespace(state=str(state), template=None, targets=str(target_file)))
                dump(target_file, {'targets': [{'target_id': 'lake-main', 'subject': 'Island in the lake', 'finding_keys': [item['finding_key']]}]})
                cli.subject_targets(argparse.Namespace(state=str(state), template=None, targets=str(target_file)))
                metadata = cli.geography_package(argparse.Namespace(state=str(state), daily=str(daily_path)))
                package = read(metadata['path']); item = package['findings'][0]
                result = {'package_id': package['package_id'], 'associations': [{
                    'finding_key': item['finding_key'], 'status': 'approximate', 'region': 'Synthetic lake region',
                    'place_name': None, 'subject_kind': 'recording_camera', 'confidence': 'medium',
                    'reason': 'Route and GPS agree; precise shoreline uncertain', 'evidence_ids': ['fa'],
                    'itinerary_refs': ['route1'], 'gps_refs': ['gps:fa'], 'map_evidence_ids': ['map1'],
                    'alternatives': ['Other shore in same region']}]}
                result_path = Path(td) / 'geography.json'; dump(result_path, result)
                with self.assertRaises(ValueError): cli.import_geography(argparse.Namespace(state=str(state), result=str(result_path)))
                result['associations'][0]['subject_landmarks'] = [{
                    'target_id': 'lake-main', 'subject': 'Island in the lake', 'identity_status': 'unresolved',
                    'reason': 'Camera position and a nearby map label do not identify the visible island',
                    'evidence_ids': ['fa'], 'camera_position_refs': ['gps:fa'], 'map_refs': ['map1'],
                    'missing_evidence': ['Reliable camera heading or distinctive terrain match']}]
                dump(result_path, result)
                cli.import_geography(argparse.Namespace(state=str(state), result=str(result_path)))
            updated = read(state / 'manifest.json')
            self.assertEqual(updated['frames'], frames); self.assertEqual(updated['packages'], packages)
            self.assertEqual(updated['transcription'], transcription); self.assertEqual(read(daily_path), daily)
            self.assertFalse(updated['published_verified'])
            rendered = report.render(updated, [], Path(td) / 'final', daily=read(state / 'daily.validated.json'))
            self.assertEqual(rendered['status'], 'complete')
            index = read(Path(td) / 'final' / report.NAMES[1])
            self.assertEqual(index['events'], daily['events'])
            self.assertEqual(index['events'][0]['location'], None)
            self.assertEqual(index['geography']['associations'][0]['region'], 'Synthetic lake region')
            markdown = (Path(td) / 'final' / report.NAMES[2]).read_text(encoding='utf-8')
            self.assertIn('Synthetic lake region', markdown)
            self.assertIn('Other shore in same region', markdown)
            self.assertIn('Island in the lake', markdown)
            self.assertIn('Reliable camera heading or distinctive terrain match', markdown)
            self.assertNotIn("['Reliable camera heading", markdown)

    def test_itinerary_requires_real_provenance_and_references(self):
        value = itinerary(); self.assertEqual(analysis.validate_itinerary(value), value)
        for mutate in (lambda x: x.update(source_refs=[]),
                       lambda x: x['source_refs'][0].update(excerpt=''),
                       lambda x: x['entries'][0].update(source_refs=['unknown']),
                       lambda x: x['entries'][0].update(date='not-a-date')):
            changed = copy.deepcopy(value); mutate(changed)
            with self.assertRaises(ValueError): analysis.validate_itinerary(changed)

    def test_map_cache_requires_crs_conversion_provenance_and_redacted_credentials(self):
        record = map_record(); analysis.validate_map_evidence([record])
        converted = copy.deepcopy(record)
        converted['original_coordinates'] = dict(record['coordinates'])
        converted['coordinates']['crs'] = 'GCJ-02'
        with self.assertRaises(ValueError): analysis.validate_map_evidence([converted])
        converted['conversion_provenance'] = {'method': 'mock official coordinate conversion', 'query_id': 'conversion1'}
        analysis.validate_map_evidence([converted])
        for field in ('key', 'token', 'api_key', 'authorization'):
            changed = copy.deepcopy(record); changed['request_sanitized'][field] = 'should-never-be-stored'
            with self.subTest(field=field), self.assertRaises(ValueError): analysis.validate_map_evidence([changed])
        changed = copy.deepcopy(record); changed['request_sanitized'] = 'https://maps.example.invalid/regeo?key=secret'
        with self.assertRaises(ValueError): analysis.validate_map_evidence([changed])

    def test_all_findings_need_an_association_including_unknown(self):
        package, result = geography_fixture()
        validated = analysis.validate_geography(result, package)
        self.assertEqual(validated['associations'][0]['status'], 'approximate')
        self.assertEqual(validated['associations'][0]['alternatives'], ['Other shore in the same region'])
        self.assertEqual(validated['associations'][1]['subject_kind'], 'visible_subject')
        for changed in (dict(result, associations=result['associations'][:1]),
                        dict(result, associations=result['associations'] + result['associations'][:1]),
                        dict(result, package_id='stale-package')):
            with self.assertRaises(ValueError): analysis.validate_geography(changed, package)

    def test_geography_rejects_cross_finding_or_unearned_place_claims(self):
        package, result = geography_fixture()
        changes = [lambda x: x['associations'][0].update(evidence_ids=['fb']),
                   lambda x: x['associations'][1].update(gps_refs=['gps1']),
                   lambda x: x['associations'][0].update(itinerary_refs=['unknown-route']),
                   lambda x: x['associations'][0].update(map_evidence_ids=['unknown-query']),
                   lambda x: x['associations'][0].update(status='resolved', map_evidence_ids=[]),
                   lambda x: x['associations'][1].update(place_name='Unsupported mountain')]
        for mutate in changes:
            changed = copy.deepcopy(result); mutate(changed)
            with self.assertRaises(ValueError): analysis.validate_geography(changed, package)
        unrelated = copy.deepcopy(package)
        unrelated['map_evidence'][0].update(related_gps_ids=['another-gps'], itinerary_refs=['another-route'])
        with self.assertRaises(ValueError): analysis.validate_geography(result, unrelated)

    def test_geography_is_invalid_after_any_bound_input_changes(self):
        package, result = geography_fixture(); daily = {'summary': 'Day', 'events': [finding()], 'interest_points': []}
        data = itinerary(); maps = [map_record()]
        manifest = {'itinerary': {'data': data, 'sha256': digest(data)},
                    'map_evidence': {'records': maps, 'sha256': digest(maps)}, 'gps_association': {'frame_locations': []},
                    'geography_package': {'package_id': package['package_id']}}
        manifest['geography'] = {'package_id': package['package_id'], 'data': result, 'sha256': digest(result),
                                 'input_digests': analysis.geography_bindings(manifest, daily)}
        analysis.require_geography(manifest, daily)
        for name in ('daily', 'itinerary', 'maps', 'gps', 'result'):
            changed = copy.deepcopy(manifest); changed_daily = copy.deepcopy(daily)
            if name == 'daily': changed_daily['summary'] = 'Changed semantic result'
            if name == 'itinerary':
                changed['itinerary']['data']['entries'][0]['place'] = 'Changed route'
                changed['itinerary']['sha256'] = digest(changed['itinerary']['data'])
            if name == 'maps':
                changed['map_evidence']['records'][0]['response']['address'] = 'Changed response'
                changed['map_evidence']['sha256'] = digest(changed['map_evidence']['records'])
            if name == 'gps': changed['gps_association']['frame_locations'].append({'frame_id': 'new'})
            if name == 'result': changed['geography']['data']['associations'][0]['region'] = 'Changed after import'
            with self.subTest(input=name), self.assertRaises(ValueError): analysis.require_geography(changed, changed_daily)


if __name__ == '__main__': unittest.main()
