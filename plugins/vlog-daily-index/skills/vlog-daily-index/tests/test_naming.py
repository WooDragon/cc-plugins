"""Controlled naming and recovery against local synthetic directories only."""
import csv
import io
import contextlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from vlog_index import store, report
from fixture_helpers import final_context, root_review

spec = importlib.util.spec_from_file_location('naming_cli', Path(__file__).resolve().parents[1] / 'scripts' / 'vlog_daily_index.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


def invoke(*args):
    output = io.StringIO()
    with patch.object(sys, 'argv', ['vlog_daily_index.py', *map(str, args)]), contextlib.redirect_stdout(output):
        cli.main()
    return json.loads(output.getvalue())


def fixture(root):
    library = root / 'library'; library.mkdir()
    old = library / '20300102_旧目录'; old.mkdir()
    media = old / 'camera.bin'; media.write_bytes(b'synthetic source bytes')
    side = old / 'camera.xml'; side.write_bytes(b'<synthetic/>')
    external = root / 'external.fit'; external.write_bytes(b'external source')
    unrelated = library / 'another-day'; unrelated.mkdir(); (unrelated / 'track.fit').write_bytes(b'other index reference')
    state = root / 'state'; state.mkdir()
    source = {'id': 'stable-source', 'relative_path': media.name, 'path': str(media), 'size': media.stat().st_size,
              'mtime_ns': media.stat().st_mtime_ns, 'status': 'failed', 'error': 'Synthetic fixture; no decoder needed',
              'sidecars': [{'path': str(side), 'sha256': store.file_hash(side), 'size': side.stat().st_size, 'mtime_ns': side.stat().st_mtime_ns}],
              'metadata': {'location_points': [{'source_file': str(side)}], 'external_reference': str(external)}}
    manifest = {'run_id': 'naming-fixture', 'state_dir': str(state), 'config': {'source_root': str(old), 'date': '2030-01-02', 'asr_model': 'mock', 'timezone': 'UTC'},
                'status': 'terminal_with_gaps', 'revision': 2, 'sources': [source], 'frames': [{'id': 'stable-frame', 'source_id': source['id']}],
                'packages': [{'id': 'stable-package', 'status': 'success', 'core_frame_ids': ['stable-frame']}],
                'transcription': {'stable-source': {'status': 'success', 'segments': [{'text': 'Synthetic text'}]}},
                'gps_association': {'fixture': 'unchanged'}, 'geography': {'fixture': 'unchanged'},
                'root_final_review': {'approved': True}, 'published_verified': True}
    store.dump(state / 'manifest.json', manifest)
    history = state / 'historical-package.json'; store.dump(history, {'source': {'path': str(media)}})
    index = library / 'index.csv'
    with index.open('w', encoding='utf-8-sig', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=store.NAMING_INDEX_COLUMNS); writer.writeheader()
        writer.writerow({'路径': media.relative_to(library).as_posix(), '原名': 'camera.bin', '来源': str(old), '大小': str(media.stat().st_size),
                         'SHA256': store.file_hash(media), '校验': 'verified', '状态': 'archived', '配套': side.relative_to(library).as_posix(),
                         '关联': 'another-day/track.fit', '备注': 'literal old directory reference: ' + str(old)})
    config = {'date': '2030-01-02', 'main_region': '示例大区域', 'themes': ['峡谷', '雪山', '徒步'],
              'reviewer': 'ROOT', 'reason': 'Themes checked against reviewed synthetic daily evidence'}
    return manifest, config, library, index, state, old, history


def plan_for(values):
    manifest, config, library, index, state, *_ = values
    store.naming_plan(manifest, config, library, index, state)
    plans = list((state / 'naming').glob('*.json'))
    return next(path for path in plans if not any(token in path.name for token in ('review', 'journal')))


class Naming(unittest.TestCase):
    def test_dry_run_keeps_fixed_region_and_does_not_touch_library(self):
        with tempfile.TemporaryDirectory() as td:
            values = fixture(Path(td)); m, config, library, index, state, old, _ = values
            original_index = index.read_bytes(); original_manifest = (state / 'manifest.json').read_bytes()
            plan = plan_for(values)
            self.assertIn('20300102_示例大区域_峡谷-雪山-徒步', plan.read_text(encoding='utf-8'))
            self.assertTrue(old.is_dir()); self.assertFalse((library / '20300102_示例大区域_峡谷-雪山-徒步').exists())
            self.assertEqual(index.read_bytes(), original_index)
            self.assertEqual((state / 'manifest.json').read_bytes(), original_manifest)
            for themes in (['峡谷'], ['峡谷', '雪山', '徒步', '湖泊']):
                with self.subTest(themes=themes), self.assertRaises(ValueError):
                    store.naming_plan(m, {**config, 'themes': themes}, library, index, state)
            for region in ('', '../escape', 'bad/name'):
                with self.subTest(region=region), self.assertRaises(ValueError):
                    store.naming_plan(m, {**config, 'main_region': region}, library, index, state)

    def test_authorized_local_migration_rebinds_paths_but_preserves_evidence_and_cache_identity(self):
        with tempfile.TemporaryDirectory() as td:
            values = fixture(Path(td)); m, _, library, index, state, old, history = values
            plan = plan_for(values); historical_bytes = history.read_bytes()
            store.naming_review(plan, 'ROOT', 'Reviewed the current synthetic naming plan')
            store.naming_apply(plan)
            new = library / '20300102_示例大区域_峡谷-雪山-徒步'
            updated = store.read(state / 'manifest.json')
            self.assertFalse(old.exists()); self.assertTrue(new.is_dir())
            self.assertEqual(updated['config']['source_root'], str(new))
            for key in ('frames', 'packages', 'transcription', 'gps_association', 'geography'):
                self.assertEqual(updated[key], m[key], key)
            self.assertEqual(updated['sources'][0]['id'], m['sources'][0]['id'])
            self.assertEqual(updated['sources'][0]['path'], str(new / 'camera.bin'))
            self.assertEqual(updated['sources'][0]['sidecars'][0]['path'], str(new / 'camera.xml'))
            self.assertEqual(updated['sources'][0]['metadata']['location_points'][0]['source_file'], str(new / 'camera.xml'))
            self.assertEqual(updated['sources'][0]['metadata']['external_reference'], m['sources'][0]['metadata']['external_reference'])
            self.assertEqual(history.read_bytes(), historical_bytes)
            self.assertEqual((new / 'camera.bin').read_bytes(), b'synthetic source bytes')
            self.assertFalse(updated.get('published_verified')); self.assertFalse(updated.get('root_final_review', {}).get('approved'))
            self.assertEqual(updated['revision'], m['revision'] + 1); self.assertTrue(updated['path_rebindings'])
            with index.open(encoding='utf-8-sig', newline='') as handle: row = next(csv.DictReader(handle))
            self.assertEqual(row['路径'], (new / 'camera.bin').relative_to(library).as_posix()); self.assertEqual(row['配套'], (new / 'camera.xml').relative_to(library).as_posix())
            self.assertEqual(row['关联'], 'another-day/track.fit')
            self.assertEqual(row['来源'], str(old)); self.assertEqual(row['备注'], 'literal old directory reference: ' + str(old))
            before_repeat = (state / 'manifest.json').read_bytes()
            store.naming_apply(plan)
            self.assertEqual((state / 'manifest.json').read_bytes(), before_repeat)

    def test_unreviewed_or_tampered_plan_is_rejected_without_moving_source(self):
        with tempfile.TemporaryDirectory() as td:
            values = fixture(Path(td)); old = values[5]; plan = plan_for(values)
            with self.assertRaises(ValueError): store.naming_apply(plan)
            with self.assertRaises(ValueError): store.naming_review(plan, 'Luna', 'Not ROOT')
            store.naming_review(plan, 'ROOT', 'Reviewed original plan')
            data = store.read(plan); data['tampered_after_review'] = True; store.dump(plan, data)
            with self.assertRaises(ValueError): store.naming_apply(plan)
            self.assertTrue(old.is_dir())

    def test_changed_index_or_existing_target_never_gets_overwritten(self):
        for conflict in ('index', 'target', 'source'):
            with self.subTest(conflict=conflict), tempfile.TemporaryDirectory() as td:
                values = fixture(Path(td)); _, _, library, index, _, old, _ = values
                plan = plan_for(values); store.naming_review(plan, 'ROOT', 'Reviewed original plan')
                if conflict == 'index': index.write_bytes(index.read_bytes() + b'changed externally\n')
                elif conflict == 'target':
                    target = library / '20300102_示例大区域_峡谷-雪山-徒步'; target.mkdir(); (target / 'unrelated.txt').write_text('keep')
                else: (old / 'camera.bin').write_bytes(b'changed source after plan')
                protected = index.read_bytes()
                with self.assertRaises((ValueError, RuntimeError, FileExistsError)): store.naming_apply(plan)
                self.assertEqual(index.read_bytes(), protected); self.assertTrue(old.is_dir())

    def test_wrong_root_and_unknown_index_schema_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            values = fixture(Path(td)); m, config, _, index, state, old, _ = values
            outside = Path(td) / 'other-root'; outside.mkdir()
            with self.assertRaises(ValueError): store.naming_plan(m, config, outside, index, state)
            index.write_text('unknown,header\none,two\n', encoding='utf-8')
            with self.assertRaises(ValueError): store.naming_plan(m, config, old.parent, index, state)
            self.assertTrue(old.is_dir())

    def test_fixed_cli_migration_requires_new_review_then_publishes_to_current_root(self):
        with tempfile.TemporaryDirectory() as td:
            values = fixture(Path(td)); m, config, library, index, state, old, _ = values
            m.update(sources=[], frames=[], packages=[], transcription={}, status='complete')
            daily = final_context(m, state); final = state / 'final'
            m['final'] = report.render(m, [], final, daily=daily)
            report.approve_final(m, final, 'ROOT', 'Synthetic pre-migration review', root_review(m, daily))
            store.dump(state / 'manifest.json', m); store.dump(state / 'daily.validated.json', daily)
            config_file = Path(td) / 'naming-config.json'; store.dump(config_file, config)
            invoke('naming-plan', '--state', state, '--config', config_file, '--library-root', library, '--index', index)
            plan = next(p for p in (state / 'naming').glob('*.json') if not any(t in p.name for t in ('review', 'journal')))
            invoke('naming-review', '--state', state, '--plan', plan, '--reviewer', 'ROOT', '--reason', 'Current itinerary region and daily themes reviewed')
            invoke('naming-apply', '--state', state, '--plan', plan)
            updated = store.read(state / 'manifest.json'); new = Path(updated['config']['source_root'])
            with self.assertRaises(ValueError): report.publish(updated, final, new)
            updated['final'] = report.render(updated, [], final, daily=daily)
            updated['status'] = updated['final']['status']
            report.approve_final(updated, final, 'ROOT', 'Synthetic post-migration review', root_review(updated, daily))
            report.publish(updated, final, new)
            self.assertTrue(updated['published_verified']); self.assertFalse(old.exists())
            self.assertEqual(updated['publication']['target'], str(new))
            self.assertEqual({p.name for p in new.glob('AI_*')}, set(report.NAMES))

    def test_interrupted_rename_or_index_commit_recovers_with_original_plan(self):
        for interruption in ('rename_ack_lost', 'index_commit'):
            with self.subTest(interruption=interruption), tempfile.TemporaryDirectory() as td:
                values = fixture(Path(td)); _, _, library, index, state, old, _ = values
                plan = plan_for(values); store.naming_review(plan, 'ROOT', 'Reviewed original plan')
                real_rename = store.os.rename; real_replace = store.os.replace
                def interrupted_rename(source, destination):
                    real_rename(source, destination)
                    raise OSError('Synthetic interruption after successful directory rename')
                def interrupted_replace(source, destination):
                    if Path(destination) == index:
                        raise OSError('Synthetic interruption after index temp write, before commit')
                    return real_replace(source, destination)
                operation = 'rename' if interruption == 'rename_ack_lost' else 'replace'
                replacement = interrupted_rename if operation == 'rename' else interrupted_replace
                with patch.object(store.os, operation, replacement), self.assertRaises(OSError):
                    store.naming_apply(plan)
                self.assertFalse(old.exists())
                result = store.naming_apply(plan)
                self.assertEqual(result['phase'], 'complete')
                updated = store.read(state / 'manifest.json')
                self.assertEqual(updated['revision'], 3)
                self.assertEqual(len(updated['path_rebindings']), 1)
                self.assertTrue(Path(updated['config']['source_root']).is_dir())
