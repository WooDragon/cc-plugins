"""Numerical safeguards and frozen-input hints, without private media or models."""
import copy, sys, tempfile, unittest
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from vlog_index import pixel_cues as cues
from vlog_index.store import file_hash, digest


class PixelCues(unittest.TestCase):
    def test_numeric_controls_do_not_claim_causes_or_classify_comparability(self):
        rng = np.random.default_rng(777); a = rng.integers(40, 180, size=(90, 160)).astype(float)
        self.assertEqual(cues.compare(a, a), [0, 0])
        self.assertEqual(cues.compare(a, a+20), [20, 0])
        self.assertEqual(cues.compare(a, (a-110)*1.2+110)[1], 0)
        self.assertGreater(cues.compare(a, rng.integers(40, 180, size=a.shape)+20)[1], 10)
        self.assertGreater(cues.compare(a, np.roll(a, 5, axis=1))[1], 10)
        self.assertEqual(cues.compare(np.full_like(a, 100), np.full_like(a, 120)), [20, None])
        # A gradient shift can be indistinguishable from a brightness offset.
        gradient = np.tile(np.arange(160)*0.5, (90, 1))
        self.assertEqual(cues.compare(gradient, gradient+2.5), [2.5, 0])
        for b in (np.zeros((4, 5)), np.full_like(a, float('nan'))):
            with self.assertRaises(ValueError): cues.compare(a, b)

    def test_exact_frame_binding_all_pairs_and_fail_closed_image_identity(self):
        with tempfile.TemporaryDirectory() as td:
            frames = []
            for n in range(3):
                p = Path(td)/f'{n}.jpg'; Image.new('L', (32, 24), 80+n*10).save(p)
                frames.append({'id':f'f{n}', 'source_id':'s', 'time':n/2, 'pts':n/2+10,
                               'path':str(p), 'sha256':file_hash(p)})
            identity = {'source':{'id':'s'}, 'interval':{'start':0,'end':1.1}, 'frames':frames,
                        'preview':{'status':'unspecified'}}
            block = cues.build(identity)
            self.assertEqual(block['adjacent_rows'], [[2, 10, None], [3, 10, None]])
            self.assertEqual(block['binding']['visual_input_digest'], digest(identity))
            self.assertEqual(cues.brief(block)['adjacent_rows'], block['adjacent_rows'])
            self.assertEqual(block, cues.build(identity))
            self.assertNotIn('binding', cues.brief(block))
            for field, value in [('source_id','other'), ('sha256','0'*64), ('preview',{'status':'changed'})]:
                changed = copy.deepcopy(identity); changed['frames'][1][field] = value
                with self.assertRaises(ValueError): cues.build(changed)
            changed = copy.deepcopy(identity); changed['frames'][1]['time'] = 0
            with self.assertRaises(ValueError): cues.build(changed)


if __name__ == '__main__': unittest.main()
