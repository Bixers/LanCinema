"""Local, lossless TS remuxing into indexed Matroska. Never alters source media."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

TRANSPORT_STREAMS = {'.ts', '.mts', '.m2ts'}


class PlaybackCache:
    def __init__(self, directory=None):
        base = Path(os.environ.get('LOCALAPPDATA', tempfile.gettempdir()))
        self.directory = Path(directory) if directory else base / 'LanCinema' / 'playback-cache'
        self.lock = threading.Lock()
        self.active = None
        self.process = None
        self.worker = None
        self.closed = False
        self.failures = {}

    def key(self, source):
        stat = source.stat()
        value = f'indexed-v1:{source.resolve()}:{stat.st_size}:{stat.st_mtime_ns}'
        return hashlib.sha256(value.encode()).hexdigest()

    def ready_path(self, source):
        path = self.directory / (self.key(source) + '.mkv')
        if path.is_file():
            os.utime(path, None)
            return path
        return None

    def prepare(self, source):
        key = self.key(source)
        ready = self.ready_path(source)
        if ready:
            try:
                info = json.loads(ready.with_suffix('.json').read_text())
            except (OSError, ValueError):
                info = {}
            return {'state': 'ready', 'subtitleFallback': bool(info.get('subtitleFallback'))}
        with self.lock:
            if self.closed:
                return {'state': 'error', 'error': '文件服务已停止'}
            if key in self.failures:
                return {'state': 'error', 'error': self.failures[key]}
            if self.active is None:
                self.active = key
                self.worker = threading.Thread(target=self._build, args=(source, key), daemon=True)
                self.worker.start()
            return {'state': 'preparing' if self.active == key else 'waiting'}

    def _space(self, source):
        self.directory.mkdir(parents=True, exist_ok=True)
        # Recently read caches remain available for later HTTP range requests.
        files = sorted(self.directory.glob('*.mkv'), key=lambda p: p.stat().st_mtime)
        total = sum(p.stat().st_size for p in files)
        for path in files:
            if total <= 8 * 1024**3 or time.time() - path.stat().st_mtime < 6 * 3600:
                break
            try:
                size = path.stat().st_size
                path.unlink()
                path.with_suffix('.json').unlink(missing_ok=True)
                total -= size
            except OSError:
                continue
        if shutil.disk_usage(self.directory).free < source.stat().st_size * 1.1 + 128 * 1024**2:
            raise RuntimeError('电脑缓存磁盘空间不足，请释放空间后重启文件服务')

    def _remux(self, source, destination, subtitles):
        import imageio_ffmpeg
        command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
                   '-fflags', '+genpts', '-i', str(source), '-map', '0:v?', '-map', '0:a?']
        if subtitles:
            command += ['-map', '0:s?']
        command += ['-c', 'copy', '-avoid_negative_ts', 'make_zero', '-f', 'matroska', str(destination)]
        with self.lock:
            if self.closed:
                raise RuntimeError('文件服务已停止')
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       creationflags=0x08000000 if os.name == 'nt' else 0)
            self.process = process
        try:
            return process.wait(timeout=900) == 0
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError('准备视频超时，请检查文件或电脑磁盘') from None
        finally:
            with self.lock:
                self.process = None

    def _build(self, source, key):
        temporary = self.directory / (key + f'.{os.getpid()}.{id(self):x}.partial')
        try:
            self._space(source)
            fallback = False
            if not self._remux(source, temporary, subtitles=True):
                # Some broadcast subtitle codecs cannot be stored in Matroska.
                fallback = True
                if not self._remux(source, temporary, subtitles=False):
                    raise RuntimeError('无法准备该 TS 视频，请检查文件是否完整或加密')
            if self.closed:
                raise RuntimeError('文件服务已停止')
            if self.key(source) != key or not temporary.stat().st_size:
                raise RuntimeError('视频在准备期间发生变化，请重新打开')
            destination = self.directory / (key + '.mkv')
            destination.with_suffix('.json').write_text(json.dumps({'subtitleFallback': fallback}))
            os.replace(temporary, destination)
        except (OSError, RuntimeError, ImportError) as error:
            message = str(error) if isinstance(error, RuntimeError) else '无法建立视频缓存，请检查电脑磁盘和文件服务'
            with self.lock:
                self.failures[key] = message
                if len(self.failures) > 32:
                    self.failures.pop(next(iter(self.failures)))
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            with self.lock:
                self.active = None

    def close(self):
        with self.lock:
            self.closed = True
            if self.process and self.process.poll() is None:
                self.process.terminate()
            worker = self.worker
        if worker:
            worker.join(timeout=5)
