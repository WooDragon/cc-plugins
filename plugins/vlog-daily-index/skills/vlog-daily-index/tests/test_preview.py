"""Trusted DIT Log mappings and reproducible preview extraction; no vendor LUTs."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from vlog_index import media


def cube(path, inverse=False):
    lines = ['TITLE "Synthetic test only"', 'LUT_3D_SIZE 2', 'DOMAIN_MIN 0 0 0', 'DOMAIN_MAX 1 1 1']
    for blue in (0, 1):
        for green in (0, 1):
            for red in (0, 1):
                values = (red, green, blue)
                lines.append(' '.join(str(1-v if inverse else v) for v in values))
    path.write_text('\n'.join(lines) + '\n', encoding='ascii')


class PreviewBoundaries(unittest.TestCase):
    def test_trusted_device_mode_mapping_no_and_missing_match(self):
        with tempfile.TemporaryDirectory() as td:
            lut = Path(td) / 'synthetic.cube'; cube(lut)
            mapping = {'ZVE1:SLOG3CINE': str(lut), 'OA5P:DLOGM': str(lut)}
            sony = media.preview_spec({'relative_path': 'ZVE1_4K50P_R_10b_SLOG3CINE_01.MP4'}, mapping)
            self.assertTrue(sony['applied']); self.assertTrue(sony['normalized'])
            self.assertEqual(sony['device'], 'ZVE1'); self.assertEqual(sony['log_token'], 'SLOG3CINE')
            action = media.preview_spec({'relative_path': 'OA5P_4K50P_R_10b_DLOGM_01.MP4'}, mapping)
            self.assertTrue(action['applied'])
            ordinary = media.preview_spec({'relative_path': 'ZVE1_4K50P_R_10b_NO_01.MP4'}, mapping)
            self.assertFalse(ordinary['applied']); self.assertIsNone(ordinary['filter'])
            missing = media.preview_spec({'relative_path': 'A3S_4K50P_R_10b_DLOGM_01.MP4'}, mapping)
            self.assertFalse(missing['applied']); self.assertFalse(missing['normalized']); self.assertTrue(missing['warning'])
            # An unrelated mode's LUT must never be guessed from the camera model.
            different = media.preview_spec({'relative_path': 'ZVE1_4K50P_R_10b_DLOGM_01.MP4'}, mapping)
            self.assertFalse(different['applied'])

    def test_lut_content_changes_cache_but_path_only_changes_do_not(self):
        with tempfile.TemporaryDirectory() as td:
            first = Path(td) / 'one.cube'; second = Path(td) / 'two.cube'; cube(first); cube(second)
            source = {'id': 'source', 'relative_path': 'ZVE1_SLOG3CINE_01.MP4'}
            block = {'index': 0, 'start': 0, 'end': 2, 'samples': [0, 1]}
            plain = media.extraction_key(source, block)
            a = media.preview_spec(source, {'ZVE1:SLOG3CINE': str(first)})
            b = media.preview_spec(source, {'ZVE1:SLOG3CINE': str(second)})
            self.assertNotEqual(media.extraction_key(source, block, a), plain)
            self.assertEqual(media.extraction_key(source, block, a), media.extraction_key(source, block, b))
            cube(first, inverse=True)
            changed = media.preview_spec(source, {'ZVE1:SLOG3CINE': str(first)})
            self.assertNotEqual(a['lut_sha256'], changed['lut_sha256'])
            self.assertNotEqual(media.extraction_key(source, block, a), media.extraction_key(source, block, changed))


@unittest.skipUnless(os.environ.get('VLOG_TEST_FFMPEG') and os.environ.get('VLOG_TEST_FFPROBE'),
                     'Set media tools for synthetic LUT integration')
class SyntheticPreview(unittest.TestCase):
    def test_synthetic_lut_changes_preview_without_changing_pts(self):
        from PIL import Image, ImageStat
        ffmpeg = os.environ['VLOG_TEST_FFMPEG']; ffprobe = os.environ['VLOG_TEST_FFPROBE']
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); source_path = root / 'ZVE1_SLOG3CINE_01.MP4'; lut = root / 'inverse test.cube'; cube(lut, True)
            media.command([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=64x48:r=4:d=2',
                           '-c:v', 'mpeg4', '-q:v', '3', '-output_ts_offset', '7', '-an', '-y', source_path])
            source = media.probe(source_path, ffprobe, root); block = source['blocks'][0]
            transform = media.preview_spec(source, {'ZVE1:SLOG3CINE': str(lut)})
            plain = media.extract_block(ffmpeg, source, block, root / 'plain', {'backend': 'cpu'})
            preview = media.extract_block(ffmpeg, source, block, root / 'preview', {'backend': 'cpu'}, preview=transform)
            self.assertEqual([f['pts'] for f in plain], [f['pts'] for f in preview])
            with Image.open(plain[0]['path']) as image: old = ImageStat.Stat(image.convert('RGB')).mean
            with Image.open(preview[0]['path']) as image: new = ImageStat.Stat(image.convert('RGB')).mean
            self.assertGreater(old[0], old[1] + 100)
            self.assertGreater(new[1], new[0] + 100)
            self.assertGreater(new[2], new[0] + 100)
            self.assertEqual(preview[0]['preview']['lut_sha256'], transform['lut_sha256'])


if __name__ == '__main__': unittest.main()
