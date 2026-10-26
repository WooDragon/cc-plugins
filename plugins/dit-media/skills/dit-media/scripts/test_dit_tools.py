import copy
import csv
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import dit_tools as d


class BookkeepingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dit-tool-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.media = self.root / '素材[1].MP4'
        self.media.write_bytes(b'example')
        self.index = self.root / '素材.csv'
        self.index.write_bytes(d.csv_bytes([]))
        self.row = dict.fromkeys(d.FIELDS, '')
        self.row.update({'路径': self.media.name, '原名': 'original.MP4', '来源': '卡:DCIM/original.MP4',
                         '大小': '7', '状态': '已归档', '校验': '仅长度核对'})

    def test_append_apply_and_idempotent(self):
        plan = d.make_plan(self.root, self.index, [{'before': None, 'after': self.row}])
        self.assertEqual(d.apply_plan(plan)['total_rows'], 1)
        self.assertTrue(d.apply_plan(plan)['already_applied'])
        self.assertTrue(self.index.read_bytes().startswith(b'\xef\xbb\xbf'))
        again = d.make_plan(self.root, self.index, [{'before': None, 'after': self.row}])
        self.assertEqual(again['affected_rows'], 0)

    def test_published_csv_can_be_read_without_tool_specific_metadata(self):
        subtitle = self.root / '字幕,中文.SRT'
        subtitle.write_text('synthetic subtitle', encoding='utf-8')
        archived = dict(self.row, 配套=subtitle.name, 备注='含逗号,引号"与换行\n第二行')
        removed = dict(self.row, 路径='', 原名='removed.MP4', 状态='已移除',
                       来源='卡:DCIM/removed.MP4', 大小='', 备注='历史记录')
        d.apply_plan(d.make_plan(self.root, self.index, [
            {'before': None, 'after': archived}, {'before': None, 'after': removed}]))
        raw = self.index.read_bytes()
        self.assertTrue(raw.startswith(b'\xef\xbb\xbf'))
        reader = csv.DictReader(io.StringIO(raw.decode('utf-8-sig'), newline=''))
        self.assertEqual(reader.fieldnames,
                         ['路径', '原名', '来源', '大小', 'SHA256', '校验', '状态', '配套', '关联', '备注'])
        self.assertEqual(list(reader), [archived, removed])
        self.assertEqual(d.read_csv(raw), [archived, removed])

    def test_rejects_csv_schema_changes_without_migration(self):
        canonical = d.csv_bytes([self.row]).decode('utf-8-sig')
        for changed in (canonical.replace('路径,原名', '原名,路径', 1),
                        canonical.replace('路径,原名', '路径,素材ID,原名', 1)):
            with self.subTest(header=changed.splitlines()[0]):
                with self.assertRaisesRegex(ValueError, 'Unsupported index schema'):
                    d.read_csv(changed.encode('utf-8-sig'))

    def test_concurrent_index_change_not_overwritten(self):
        plan = d.make_plan(self.root, self.index, [{'before': None, 'after': self.row}])
        old = self.index.read_bytes() + b'\r\n'
        self.index.write_bytes(old)
        with self.assertRaisesRegex(ValueError, 'changed since planning'):
            d.apply_plan(plan)
        self.assertEqual(self.index.read_bytes(), old)
        self.assertFalse(list(self.root.glob('*.dit-lock')))

    def test_missing_file_after_plan_does_not_publish(self):
        plan = d.make_plan(self.root, self.index, [{'before': None, 'after': self.row}])
        old = self.index.read_bytes()
        self.media.unlink()
        with self.assertRaises(ValueError): d.apply_plan(plan)
        self.assertEqual(self.index.read_bytes(), old)

    def test_duplicate_and_escape_and_trailing_dot(self):
        bad = dict(self.row, 原名='another.MP4')
        with self.assertRaisesRegex(ValueError, 'Duplicate indexed'):
            d.make_plan(self.root, self.index, [{'before': None, 'after': self.row}, {'before': None, 'after': bad}])
        for path in ('../outside.MP4', 'C:/video.MP4', '/root/a', 'folder./a', 'folder//a', 'folder\\a'):
            with self.subTest(path=path), self.assertRaises(ValueError): d.relative(self.root, path)

    def test_rename_updates_reference_preserves_origin(self):
        other_file = self.root / 'repair.MP4'; other_file.write_bytes(b'example')
        other = dict(self.row, 路径=other_file.name, 原名='repair.MP4', 关联=self.row['路径'])
        self.index.write_bytes(d.csv_bytes([self.row, other]))
        renamed = self.root / 'renamed.MP4'; self.media.rename(renamed)
        after = dict(self.row, 路径=renamed.name)
        plan = d.make_plan(self.root, self.index, [{'before': self.row, 'after': after}])
        d.apply_plan(plan)
        rows = d.read_csv(self.index.read_bytes())
        self.assertEqual(rows[1]['关联'], renamed.name)
        self.assertEqual(rows[0]['来源'], self.row['来源'])
        bad = dict(after, 来源='卡:invented.MP4')
        with self.assertRaisesRegex(ValueError, 'Historical'):
            d.make_plan(self.root, self.index, [{'before': after, 'after': bad}])

    def test_removal_retains_row_and_clears_reference(self):
        other = self.root / 'other.MP4'; other.write_bytes(b'example')
        linked = dict(self.row, 路径=other.name, 原名=other.name, 关联=self.row['路径'])
        self.index.write_bytes(d.csv_bytes([self.row, linked]))
        self.media.unlink()
        after = dict(self.row, 路径='', 状态='已按用户要求移除')
        d.apply_plan(d.make_plan(self.root, self.index, [{'before': self.row, 'after': after}]))
        rows = d.read_csv(self.index.read_bytes())
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1]['关联'], '')

    def test_snapshot_detects_same_size_change_and_new_file(self):
        # Manifest must be outside the snapshotted source.
        source = self.root / 'card'; source.mkdir()
        file = source / 'a'; file.write_bytes(b'abc')
        path = self.root / 'snapshot.json'; d.save_json(path, d.snapshot(source))
        d.verify_snapshot(path)
        import os
        stat = file.stat(); os.utime(file, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
        with self.assertRaises(ValueError): d.verify_snapshot(path)
        os.utime(file, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        (source / 'new').write_bytes(b'x')
        with self.assertRaises(ValueError): d.verify_snapshot(path)

    def test_snapshot_does_not_ignore_unreadable_source(self):
        with self.assertRaises(ValueError): d.snapshot(self.media)
        def inaccessible(*args, **kwargs):
            kwargs['onerror'](PermissionError('unreadable source directory'))
        with patch.object(d.os, 'walk', side_effect=inaccessible):
            with self.assertRaises(PermissionError): d.snapshot(self.root)

    def log(self, sha='A' * 64, error='0', count='1'):
        return ('fcp(ver4.2.1) start at test\n<Command> Diff (No overwrite) (with Verify)\n'
                f'+ {self.media}   <20261024-120000 7 sha256={sha}>\n'
                f'VerifyFiles= {count}\nResult : (ErrFiles : {error} / ErrDirs : 0)\n')

    def test_fastcopy_complete_and_fail_closed(self):
        log = self.root / 'transfer.log'
        manifest = [{'path': str(self.media), 'size': 7}]
        log.write_text(self.log(), encoding='utf-8')
        receipt = d.verify_fastcopy(log, manifest, 0)
        self.assertEqual(receipt['files'][0]['sha256'], 'A' * 64)
        for text in (self.log(error='1'), self.log(count='0'), self.log().replace('sha256=', 'xxhash='),
                     self.log() + self.log(), self.log().split('Result')[0]):
            log.write_text(text, encoding='utf-8')
            with self.subTest(text=text), self.assertRaises(ValueError): d.verify_fastcopy(log, manifest, 0)
        log.write_text(self.log(), encoding='utf-8')
        with self.assertRaises(ValueError): d.verify_fastcopy(log, manifest, 1)

    def test_fastcopy_grouped_verify_count(self):
        log = self.root / 'grouped.log'
        manifest = []
        lines = ['fcp(ver4.2.1) start at test', '<Command> (with Verify)']
        for number in range(1000):
            media = self.root / f'file{number}.MP4'
            media.write_bytes(b'x')
            manifest.append({'path': str(media), 'size': 1})
            lines.append(f'+ {media}   <20261024-120000 1 sha256={"A" * 64}>')
        lines.extend(['VerifyFiles= 1,000', 'Result : (ErrFiles : 0 / ErrDirs : 0)'])
        text = '\n'.join(lines) + '\n'
        log.write_text(text, encoding='utf-8')
        self.assertEqual(len(d.verify_fastcopy(log, manifest, 0)['files']), 1000)
        for count in ('10,00', '1,001', '1,,000'):
            log.write_text(text.replace('1,000', count), encoding='utf-8')
            with self.subTest(count=count), self.assertRaises(ValueError):
                d.verify_fastcopy(log, manifest, 0)

    def test_hash_claim_requires_evidence(self):
        after = dict(self.row, SHA256='A' * 64, 校验='源与目标SHA256一致')
        with self.assertRaisesRegex(ValueError, 'receipt'):
            d.make_plan(self.root, self.index, [{'before': None, 'after': after}])
        log = self.root / 'log'; log.write_text(self.log(), encoding='utf-8')
        proof = self.root / 'receipt.json'
        d.save_json(proof, d.verify_fastcopy(log, [{'path': str(self.media), 'size': 7}], 0))
        change = {'before': None, 'after': after, 'evidence': {'receipt': str(proof), 'path': str(self.media)}}
        d.apply_plan(d.make_plan(self.root, self.index, [change]))
        self.assertEqual(d.read_csv(self.index.read_bytes())[0]['SHA256'], 'A' * 64)

    def test_unrelated_rows_preserved(self):
        historical = dict(self.row, 路径='', 原名='old.MP4', 状态='历史移除', 备注='保留逗号,引号"和换行\n原文')
        self.index.write_bytes(d.csv_bytes([historical]))
        d.apply_plan(d.make_plan(self.root, self.index, [{'before': None, 'after': self.row}]))
        self.assertEqual(d.read_csv(self.index.read_bytes())[0], historical)

    def test_relocation_repeat_and_conflict(self):
        dest = self.root / 'new folder' / '新文件.MP4'
        plan = d.relocation_plan(self.root, [{'source': str(self.media), 'destination': str(dest)}])
        task = self.root / 'move.json'
        self.assertEqual(d.apply_relocation(plan, task)['moved'], 1)
        self.assertEqual(d.apply_relocation(plan, task)['moved'], 0)
        self.assertEqual(dest.read_bytes(), b'example')
        dest.write_bytes(b'changed-size')
        with self.assertRaises(ValueError): d.apply_relocation(plan, task)

    def test_relocation_full_preflight_no_partial_move(self):
        second = self.root / 'second.MP4'; second.write_bytes(b'example')
        dest1, dest2 = self.root / 'one.MP4', self.root / 'two.MP4'
        plan = d.relocation_plan(self.root, [{'source': str(self.media), 'destination': str(dest1)},
                                           {'source': str(second), 'destination': str(dest2)}])
        dest2.write_bytes(b'existing')
        with self.assertRaises(ValueError): d.apply_relocation(plan, self.root / 'move.json')
        self.assertTrue(self.media.exists())
        self.assertFalse(dest1.exists())
        self.assertEqual(dest2.read_bytes(), b'existing')

    def test_relocation_duplicate_rejected(self):
        item = {'source': str(self.media), 'destination': str(self.root / 'dest.MP4')}
        with self.assertRaises(ValueError): d.relocation_plan(self.root, [item, item])


if __name__ == '__main__':
    unittest.main()
