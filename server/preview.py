"""On-demand audio-activity ranking; no semantic classification or video encoding."""
from collections import OrderedDict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

ALGORITHM = 'audio-activity-v1'


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


def score_segments(duration, levels):
    """Rank 30-second windows using 0.5-second RMS dBFS bins.

    Clip loud outliers to the 95th percentile; require sustained usable sound.
    Scores are within-file activity, not popularity, meaning, or a quality label.
    """
    count = int(math.ceil(duration*2))
    if duration < 36 or count > 43200:
        return []
    bins = [-90.] * count
    for timestamp, level in levels:
        if not math.isfinite(timestamp) or not math.isfinite(level):
            continue
        index = int(round(timestamp*2))
        if 0 <= index < count:
            bins[index] = max(-90., min(0., level))
    audible = sorted(value for value in bins if value > -55)
    if len(audible) < min(30, count*.2):
        return []
    low = max(-65., sorted(bins)[int((count-1)*.1)])
    high = audible[int((len(audible)-1)*.95)]
    if high-low < 4:
        return []  # Uniform audio has no defensible ranking.
    energy = [max(0., min(1., (value-low)/(high-low))) for value in bins]
    activity = [float(value > -55) for value in bins]
    # Ignore silence edges when measuring variation, otherwise one burst wins.
    variation = [0.] + [min(1., abs(bins[i]-bins[i-1])/18.) if activity[i] and activity[i-1] else 0. for i in range(1, count)]
    sums = []
    for values in (energy, activity, variation):
        prefix = [0.]
        for value in values: prefix.append(prefix[-1]+value)
        sums.append(prefix)
    candidates = []
    for begin in range(0, max(1, count-60+1), 2):
        end = min(count, begin+60)
        means = [(prefix[end]-prefix[begin])/(end-begin) for prefix in sums]
        if means[1] < .35: continue
        score = 100*(.6*means[0] + .25*means[1] + .15*means[2])
        candidates.append((score, begin*.5))
    chosen = []
    # Prefer disjoint samples; allow limited overlap on shorter videos so the
    # alternate action remains useful. Never return near-identical starts.
    for separation in (30., 15.):
        for score, start in sorted(candidates, key=lambda pair: (-pair[0], pair[1])):
            if all(abs(start-clip['start']) >= separation for clip in chosen):
                chosen.append({'start': start, 'end': min(duration, start+30), 'score': round(score, 1)})
                if len(chosen) == 3: return chosen
    return chosen


def parse_levels(output):
    timestamp = None
    for line in output.decode('ascii', errors='ignore').splitlines():
        match = re.search(r'pts_time:([-\d.e+]+)', line)
        if match: timestamp = float(match[1])
        if timestamp is not None and line.startswith('lavfi.astats.Overall.RMS_level='):
            try: yield timestamp, float(line.partition('=')[2])
            except ValueError: pass


class PreviewCache:
    def __init__(self, directory=None):
        self.lock = threading.Lock()
        self.results = OrderedDict()
        self.active = None
        self.closed = False
        self.process = None
        self.cancelled_key = None
        base = Path(os.environ.get('LOCALAPPDATA', tempfile.gettempdir()))
        self.directory = Path(directory) if directory else base/'LanCinema'/'preview-cache'

    def key(self, path):
        stat = path.stat()
        return hashlib.sha256(f'{ALGORITHM}:{path.resolve()}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()

    def _run(self, command, timeout):
        with self.lock:
            if self.closed or self.cancelled_key == self.active: raise OSError('cancelled')
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       creationflags=0x08004000 if os.name == 'nt' else 0)
            self.process = process
        try:
            out, err = process.communicate(timeout=timeout)
            return process.returncode, out, err
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate(); raise
        finally:
            with self.lock:
                if self.process is process: self.process = None

    def _read(self, key):
        try:
            path = self.directory/(key+'.json')
            if path.stat().st_size > 8192: return None
            result = json.loads(path.read_text(encoding='utf-8'))
            duration = result['duration']
            clips = result['clips']
            if result.get('algorithm') != ALGORITHM or result.get('state') != 'ready' or not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0: return None
            if not isinstance(clips, list) or not 1 <= len(clips) <= 3: return None
            for clip in clips:
                start, end = clip['start'], clip['end']
                if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (start, end)): return None
                if not 0 <= start < end <= duration or end-start > 35: return None
            return result
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _write(self, key, result):
        if result.get('state') != 'ready': return
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            path = self.directory/(key+'.json')
            # Unique temp names allow separate desktop instances to share cache.
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=self.directory, suffix='.tmp', delete=False) as stream:
                temporary = Path(stream.name); json.dump(result, stream, ensure_ascii=False)
            try: temporary.replace(path)
            finally: temporary.unlink(missing_ok=True)
            files = sorted(self.directory.glob('*.json'), key=lambda p:p.stat().st_mtime, reverse=True)
            for old in files[1000:]: old.unlink(missing_ok=True)
        except OSError:
            pass  # A full/read-only cache disk must not prevent preview playback.

    def prepare(self, path, identity=None):
        # Remux-cache mtime is also its LRU access time. Fingerprint the original
        # source so polling a prepared TS does not invalidate every analysis.
        identity = identity or path
        key = self.key(identity)
        with self.lock:
            if key in self.results:
                self.results.move_to_end(key)
                return self.results[key]
            if self.closed:
                return {'state': 'error', 'error': '电脑服务正在关闭'}
            saved = self._read(key)
            if saved:
                self.results[key] = saved
                while len(self.results) > 256: self.results.popitem(last=False)
                return saved
            if self.active is not None:
                return {'state': 'preparing' if self.active == key else 'waiting', 'phase': 'analysis'}
            self.active = key
            threading.Thread(target=self._probe, args=(path, key, identity), daemon=True).start()
            return {'state': 'preparing', 'phase': 'analysis'}

    def _probe(self, path, key, identity):
        result = {'state': 'error', 'error': '无法识别视频时长，可换一部或直接看全片'}
        try:
            import imageio_ffmpeg
            command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-nostdin', '-threads', '1',
                       '-i', str(path), '-map', '0:v:0', '-c', 'copy', '-t', '0', '-f', 'null', '-']
            code, _, log = self._run(command, 10)
            match = re.search(r'Duration: (\d+):(\d+):([\d.]+)', log.decode('utf-8', errors='replace'))
            if code == 0 and match:
                duration = int(match[1])*3600 + int(match[2])*60 + float(match[3])
                clips = sample_segments(duration)
                if clips:
                    result = {'state': 'ready', 'duration': duration, 'clips': clips, 'method': 'time-sampling', 'algorithm': ALGORITHM}
                    if 36 <= duration <= 21600 and b'Audio:' in log:
                        command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'error', '-nostdin',
                                   '-threads', '1', '-copyts', '-start_at_zero', '-i', str(path), '-map', '0:a:0', '-vn', '-sn', '-dn',
                                   '-t', str(duration), '-filter_threads', '1', '-af',
                                   'aformat=channel_layouts=mono,aresample=8000,asetnsamples=n=4000:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=-',
                                   '-f', 'null', '-']
                        code, output, _ = self._run(command, 45)
                        if code == 0:
                            ranked = score_segments(duration, parse_levels(output))
                            if ranked: result.update(clips=ranked, method='audio-activity')
        except (OSError, ValueError, ImportError, subprocess.TimeoutExpired):
            pass
        finally:
            with self.lock:
                cancelled = self.closed or self.cancelled_key == key
            try:
                if cancelled: pass
                elif self.key(identity) == key: self._write(key, result)
                else: result = {'state': 'error', 'error': '视频已改变，请重新打开'}
            except OSError:
                result = {'state': 'error', 'error': '视频已移动或删除，请换一部'}
            with self.lock:
                if not cancelled: self.results[key] = result
                while len(self.results) > 256:
                    self.results.popitem(last=False)
                self.active = None
                if self.cancelled_key == key: self.cancelled_key = None

    def cancel(self, identity):
        key = self.key(identity)
        with self.lock:
            if self.active != key: return
            self.cancelled_key = key
            process = self.process
        if process:
            try: process.kill()
            except OSError: pass

    def close(self):
        with self.lock:
            self.closed = True
            process = self.process
        if process:
            try: process.kill()
            except OSError: pass
