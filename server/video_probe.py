"""Conservative local black-border detection. No media leaves the computer."""
from collections import OrderedDict
import os
import re
import subprocess
import threading

_cache = OrderedDict()
_lock = threading.Lock()


def detect_crop(path):
    stat = path.stat()
    key = (str(path), stat.st_size, stat.st_mtime_ns)
    with _lock:
        if key in _cache:
            return _cache[key]
        result = {}
        try:
            import imageio_ffmpeg
            command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-nostdin', '-threads', '2',
                       '-i', str(path), '-t', '10', '-an', '-sn', '-vf',
                       'fps=2,cropdetect=limit=20:round=2:reset=0', '-f', 'null', '-']
            run = subprocess.run(command, capture_output=True, timeout=18,
                                 creationflags=0x08000000 if os.name == 'nt' else 0)
            log = run.stderr.decode('utf-8', errors='replace')
            sizes = re.findall(r'Video:.*? (\d{2,5})x(\d{2,5})', log)
            crops = [tuple(map(int, m)) for m in re.findall(r'crop=(\d+):(\d+):(\d+):(\d+)', log)]
            if sizes and len(crops) >= 6:
                width, height = map(int, sizes[0])
                # Union of all valid samples avoids cropping to a single dark scene.
                valid = [(w, h, x, y) for w, h, x, y in crops if w > 0 and h > 0 and x+w <= width and y+h <= height]
                if len(valid) >= 6:
                    left = min(c[2] for c in valid)
                    top = min(c[3] for c in valid)
                    right = max(c[2]+c[0] for c in valid)
                    bottom = max(c[3]+c[1] for c in valid)
                    # Retain a small margin; do not infer a tiny subject as the whole frame.
                    left, top = max(0, left-4), max(0, top-4)
                    right, bottom = min(width, right+4), min(height, bottom+4)
                    if right-left >= width*.15 and bottom-top >= height*.15:
                        result = {'width': width, 'height': height, 'x': left, 'y': top,
                                  'w': right-left, 'h': bottom-top}
        except (OSError, subprocess.TimeoutExpired, ImportError):
            pass
        _cache[key] = result
        while len(_cache) > 128:
            _cache.popitem(last=False)
        return result
