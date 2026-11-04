"""Small local video previews, independent of playback/remux caches."""
from collections import OrderedDict
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time


class ThumbnailCache:
    def __init__(self, directory=None):
        base = Path(os.environ.get('LOCALAPPDATA', tempfile.gettempdir()))
        self.directory = Path(directory) if directory else base / 'LanCinema' / 'thumbnails'
        self.lock = threading.Lock()
        self.workers = threading.BoundedSemaphore(2)
        self.active = set()
        self.failures = OrderedDict()

    def key(self, source):
        stat = source.stat()
        return hashlib.sha256(f'preview-v1:{source.resolve()}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()

    def _render(self, source):
        import imageio_ffmpeg
        # A representative frame shortly after the opening. Short clips fall
        # back to the start; bounded decoding also works on unindexed TS files.
        for start in (3, 0):
            command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'error',
                       '-nostdin', '-threads', '1', '-ss', str(start), '-i', str(source),
                       '-map', '0:v:0', '-an', '-sn', '-dn', '-filter_threads', '1',
                       '-vf', "thumbnail=24,scale=w='min(320,180*dar)':h='min(180,320/dar)',setsar=1",
                       '-frames:v', '1', '-threads', '1', '-q:v', '4', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-']
            result = subprocess.run(command, capture_output=True, timeout=8,
                                    creationflags=0x08000000 if os.name == 'nt' else 0)
            data = result.stdout
            if result.returncode == 0 and data.startswith(b'\xff\xd8') and data.endswith(b'\xff\xd9') and len(data) <= 256 * 1024:
                return data
        return None

    def _prune(self):
        # Called under the cache lock after a new image, not for every hit.
        files = sorted(self.directory.glob('*.jpg'), key=lambda p: p.stat().st_mtime, reverse=True)
        total = 0
        for index, path in enumerate(files):
            total += path.stat().st_size
            if index >= 2000 or total > 128 * 1024**2:
                path.unlink(missing_ok=True)

    def get(self, source):
        key = self.key(source)
        cached = self.directory / (key + '.jpg')
        with self.lock:
            try:
                data = cached.read_bytes()
                if data.startswith(b'\xff\xd8') and data.endswith(b'\xff\xd9'):
                    os.utime(cached, None)
                    return 200, data
            except OSError:
                pass
            if self.failures.get(key, 0) > time.monotonic():
                return 204, b''
            if key in self.active or not self.workers.acquire(blocking=False):
                return 503, b''
            self.active.add(key)
        try:
            try:
                data = self._render(source)
            except (OSError, ValueError, subprocess.TimeoutExpired, ImportError):
                data = None
            with self.lock:
                if data:
                    # An edit during extraction must not publish a stale cover.
                    if self.key(source) != key:
                        return 503, b''
                    try:
                        self.directory.mkdir(parents=True, exist_ok=True)
                        temporary = cached.with_suffix('.tmp')
                        temporary.write_bytes(data)
                        temporary.replace(cached)
                        self._prune()
                    except OSError:
                        pass  # Preview still works if the cache disk is full.
                    return 200, data
                self.failures[key] = time.monotonic() + 300
                self.failures.move_to_end(key)
                while len(self.failures) > 512:
                    self.failures.popitem(last=False)
                return 204, b''
        finally:
            with self.lock:
                self.active.discard(key)
                self.workers.release()
