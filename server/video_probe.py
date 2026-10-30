"""Bounded, conservative multi-position black-border analysis; local only."""
from collections import OrderedDict
import os
import re
import subprocess
import threading
import time

_cache = OrderedDict()
_lock = threading.Lock()
_worker = threading.Semaphore(1)


def _sample(executable, path, start, timeout):
    command = [executable, '-hide_banner', '-nostdin', '-threads', '2',
               '-ss', str(start), '-i', str(path), '-map', '0:v:0',
               '-t', '3', '-an', '-sn', '-filter_threads', '1', '-vf',
               'fps=4,cropdetect=limit=20:round=2:reset=1', '-f', 'null', '-']
    run = subprocess.run(command, capture_output=True, timeout=timeout,
                         creationflags=0x08000000 if os.name == 'nt' else 0)
    return run.stderr.decode('utf-8', errors='replace') if run.returncode == 0 else ''


def _rectangles(log, width, height):
    crops = [tuple(map(int, m)) for m in re.findall(r'crop=(\d+):(\d+):(\d+):(\d+)', log)]
    return [(w, h, x, y) for w, h, x, y in crops
            if w >= width*.15 and h >= height*.15 and x >= 0 and y >= 0
            and x+w <= width and y+h <= height]


def _analyze(executable, path):
    deadline = time.monotonic() + 20
    first = _sample(executable, path, 0, min(8, deadline-time.monotonic()))
    sizes = re.findall(r'Video:.*? (\d{2,5})x(\d{2,5})', first)
    duration = re.search(r'Duration: (\d+):(\d+):([\d.]+)', first)
    # FFmpeg autorotates while VLC crop coordinates are decoded pixels. Until
    # a rotated-source mapping is available, leave these files uncropped.
    rotation = re.search(r'rotation of ([\d.+-]+) degrees', first)
    if not sizes or not duration or (rotation and abs(float(rotation[1])) > .1):
        return {}
    width, height = map(int, sizes[0])
    seconds = int(duration[1])*3600 + int(duration[2])*60 + float(duration[3])
    if seconds < 9:
        return {}  # Too short to establish independent sampling windows.
    windows = [_rectangles(first, width, height)]
    for position in (.35, .7):
        remaining = deadline-time.monotonic()
        if remaining <= 0:
            return {}
        log = _sample(executable, path, min(seconds-3, seconds*position), min(8, remaining))
        if not log:
            return {}
        windows.append(_rectangles(log, width, height))
    # Ignore an entirely black opening, but require sustained evidence in at
    # least two independent windows. Union ALL valid samples, including brief
    # wider shots, to avoid sacrificing content to a majority of dark scenes.
    if sum(len(window) >= 6 for window in windows) < 2:
        return {}
    valid = [crop for window in windows for crop in window]
    left = max(0, min(c[2] for c in valid)-4)
    top = max(0, min(c[3] for c in valid)-4)
    right = min(width, max(c[2]+c[0] for c in valid)+4)
    bottom = min(height, max(c[3]+c[1] for c in valid)+4)
    return {'width': width, 'height': height, 'x': left, 'y': top,
            'w': right-left, 'h': bottom-top}


def detect_crop(path):
    stat = path.stat()
    key = (str(path), stat.st_size, stat.st_mtime_ns)
    with _lock:
        if key in _cache:
            _cache.move_to_end(key)
            return _cache[key]
    # Do not queue many slow probes behind playback. A busy computer safely
    # leaves the next video uncropped; another opening can try again.
    if not _worker.acquire(timeout=.1):
        return {}
    try:
        with _lock:
            if key in _cache:
                return _cache[key]
        try:
            import imageio_ffmpeg
            result = _analyze(imageio_ffmpeg.get_ffmpeg_exe(), path)
        except (OSError, ValueError, subprocess.TimeoutExpired, ImportError):
            result = {}
        with _lock:
            _cache[key] = result
            while len(_cache) > 128:
                _cache.popitem(last=False)
        return result
    finally:
        _worker.release()
