"""Metadata-only preview sampling: no semantic scoring or media re-encoding."""
from collections import OrderedDict
import math
import os
import re
import subprocess
import threading


def sample_segments(duration):
    if not math.isfinite(duration) or duration <= 0:
        return []
    length = min(30., duration)
    if duration <= 35:
        return [{'start': 0., 'end': duration}]
    starts = []
    # Spread samples across the whole work; avoid very near-duplicate windows.
    for fraction in (.2, .5, .8):
        start = round((duration - length) * fraction, 3)
        if not starts or start - starts[-1] >= min(length, (duration-length)/2):
            starts.append(start)
    return [{'start': start, 'end': min(duration, start+length)} for start in starts]


class PreviewCache:
    def __init__(self):
        self.lock = threading.Lock()
        self.results = OrderedDict()
        self.active = None
        self.closed = False

    def prepare(self, path):
        stat = path.stat()
        key = (str(path), stat.st_size, stat.st_mtime_ns)
        with self.lock:
            if key in self.results:
                self.results.move_to_end(key)
                return self.results[key]
            if self.closed:
                return {'state': 'error', 'error': '电脑服务正在关闭'}
            if self.active is not None:
                return {'state': 'preparing' if self.active == key else 'waiting'}
            self.active = key
            threading.Thread(target=self._probe, args=(path, key), daemon=True).start()
            return {'state': 'preparing'}

    def _probe(self, path, key):
        result = {'state': 'error', 'error': '无法识别视频时长，可换一部或直接看全片'}
        try:
            import imageio_ffmpeg
            command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-nostdin', '-threads', '1',
                       '-i', str(path), '-map', '0:v:0', '-c', 'copy', '-t', '0', '-f', 'null', '-']
            run = subprocess.run(command, capture_output=True, timeout=10,
                                 creationflags=0x08004000 if os.name == 'nt' else 0)
            match = re.search(r'Duration: (\d+):(\d+):([\d.]+)', run.stderr.decode('utf-8', errors='replace'))
            if run.returncode == 0 and match:
                duration = int(match[1])*3600 + int(match[2])*60 + float(match[3])
                clips = sample_segments(duration)
                if clips:
                    result = {'state': 'ready', 'duration': duration, 'clips': clips}
        except (OSError, ValueError, ImportError, subprocess.TimeoutExpired):
            pass
        finally:
            with self.lock:
                self.results[key] = result
                while len(self.results) > 256:
                    self.results.popitem(last=False)
                self.active = None

    def close(self):
        with self.lock:
            self.closed = True
