"""Deterministic display-pixel hints; no tracking, scene labels or model calls."""
from pathlib import Path
from .store import digest, file_hash

VERSION = 'pixel-cues-1'
CONFIG = {'size': [160, 90], 'grid': [4, 4], 'gray': 'Pillow-L',
          'resize': 'BOX', 'normalization': 'median/p90-p10', 'decimals': 5}
DEFINITION = ('每行[to_frame_1based,dB,R]比较frames表中前一帧与该帧。'
              'dB为固定4×4格均值差的中位数，正为显示灰度增大；'
              'R为各帧减全图中位数、除P90−P10后绝对差均值，再乘两帧平均对比差；'
              '两者单位为8位显示灰度代理，R无法归一化时为null。'
              '固定坐标不跟踪物体；数字不能区分取景、自然光或曝光原因，也不表示运镜方向、连续性或可用性。'
              '逐对回原图核对可追踪部位并引用帧ID；R大不能屏蔽dB，数字不是新增图像证据。')


def signature():
    """Only new jobs use the current implementation; frozen jobs never call this."""
    import numpy as np
    from PIL import __version__ as pillow_version
    return {'version': VERSION, 'config': CONFIG, 'implementation_sha256': file_hash(__file__),
            'dependencies': {'numpy': np.__version__, 'pillow': pillow_version}}


def compare(a, b):
    import numpy as np
    if a.ndim != 2 or a.shape != b.shape or min(a.shape) < 4 or not np.isfinite(a).all() or not np.isfinite(b).all():
        raise ValueError('Pixel arrays need equal finite two-dimensional shapes >=4x4')
    a = np.asarray(a, dtype=np.float64); b = np.asarray(b, dtype=np.float64)
    grid = lambda x: np.array([c.mean() for row in np.array_split(x, 4, axis=0) for c in np.array_split(row, 4, axis=1)])
    pa = np.percentile(a, [10, 50, 90]); pb = np.percentile(b, [10, 50, 90])
    ca, cb = pa[2] - pa[0], pb[2] - pb[0]
    residual = None
    if min(ca, cb) > np.finfo(np.float64).eps:
        residual = float(np.abs((b-pb[1])/cb - (a-pa[1])/ca).mean() * (ca+cb)/2)
    return [round(float(np.median(grid(b)-grid(a))), 5), None if residual is None else round(residual, 5)]


def build(identity):
    """Read already selected JPEGs only; bind original metadata without rounding PTS."""
    import numpy as np
    from PIL import Image
    frames = identity['frames']; times = [f['time'] for f in frames]
    if len(frames) < 2 or times != sorted(set(times)):
        raise ValueError('Pixel cues require strictly increasing actual frame times')
    arrays = []; shape = None
    for frame in frames:
        if frame['source_id'] != identity['source']['id'] or file_hash(frame['path']) != frame['sha256']:
            raise ValueError('Pixel cue source/image identity mismatch')
        if frame.get('preview', identity['preview']) != identity['preview']:
            raise ValueError('Pixel cue preview changed inside sequence')
        with Image.open(frame['path']) as im:
            current = (im.size, im.mode)
            if shape is not None and current != shape:
                raise ValueError('Pixel cue image size/mode changed inside sequence')
            shape = current
            arrays.append(np.asarray(im.convert('L').resize(tuple(CONFIG['size']), Image.Resampling.BOX), dtype=np.float64))
    binding = {**signature(), 'visual_input_digest': digest({k: v for k, v in identity.items() if k != 'program_pixel_cues'})}
    return {'version': VERSION, 'binding': binding, 'binding_digest': digest(binding),
            'definition': DEFINITION, 'columns': ['to_frame_1based', 'dB', 'R'],
            'adjacent_rows': [[n+2, *compare(a, b)] for n, (a, b) in enumerate(zip(arrays, arrays[1:]))]}


def brief(block):
    """Retain frozen values/definition, with full provenance in the full task."""
    return {k: block[k] for k in ('version', 'binding_digest', 'definition', 'columns', 'adjacent_rows')}
