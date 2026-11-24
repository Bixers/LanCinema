import json
from pathlib import Path
import tempfile
import subprocess
import shutil
import sys
import threading
import time
import unittest
from unittest.mock import patch
from server import MediaServer
import test_server
from preview import PreviewCache, sample_segments, score_segments, parse_levels


class VideoLibraryTests(unittest.TestCase):
    request = test_server.ServerTests.request

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name).resolve()
        self.roots = [base/'first', base/'second']
        for root in self.roots:
            (root/'nested').mkdir(parents=True)
            (root/'nested'/'Demo Video.mp4').write_bytes(b'fixture')
            (root/'zero.mp4').touch()
            (root/'caption.srt').write_text('subtitle')
        self.server = MediaServer(('127.0.0.1', 0), self.roots, 'test-access-code', base/'state.sqlite3')
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.temp.cleanup()

    def ready(self):
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            status, _, data = self.request('/api/library', '')
            self.assertEqual(status, 200)
            result = json.loads(data)
            if result['state'] == 'ready' and not result['refreshing']:
                return result
            time.sleep(.01)
        self.fail('library did not finish')

    def test_all_roots_search_refresh_and_auth(self):
        self.assertEqual(self.request('/api/library', '', token='bad')[0], 401)
        items = self.ready()['items']
        self.assertEqual(len(items), 2)
        self.assertEqual(len({x['path'] for x in items}), 2)
        self.assertTrue(all(x['video'] and x['size'] > 0 for x in items))
        data = json.loads(self.request('/api/search', '', query={'q':'FIRST nested DEMO'})[2])
        self.assertEqual(len(data['items']), 1)
        self.assertIn('first', data['items'][0]['path'].split('/')[0])
        (self.roots[0]/'nested'/'Demo Video.mp4').unlink()
        self.request('/api/library', '', query={'refresh':'1'})
        self.assertEqual(len(self.ready()['items']), 1)
        self.assertEqual(self.request('/api/preview', '../outside.mp4')[0], 403)

    def test_symlink_escape_cycle_and_overlapping_root_deduplication(self):
        outside = Path(self.temp.name)/'secret.mp4'; outside.write_bytes(b'private')
        try:
            (self.roots[0]/'escape.mp4').symlink_to(outside)
            (self.roots[0]/'nested'/'loop').symlink_to(self.roots[0], target_is_directory=True)
        except OSError:
            self.skipTest('symlink creation unavailable')
        self.assertEqual(len(self.ready()['items']), 2)
        from video_library import VideoLibrary
        inventory = VideoLibrary(self.roots, {'all':self.roots[0], 'nested':self.roots[0]/'nested'}, {'.mp4'})
        inventory._scan()
        self.assertEqual(len(inventory.result['items']), 1)
        inventory.close()

    def test_preview_metadata_probe_and_cache(self):
        source = Path(__file__).resolve().parents[1]/'UITests/Fixtures/演示文件夹/测试视频.mkv'
        if not source.exists(): self.skipTest('synthetic fixture absent')
        cache = PreviewCache(Path(self.temp.name)/'preview-cache')
        self.assertEqual(cache.prepare(source)['state'], 'preparing')
        deadline = time.monotonic()+15
        while cache.active and time.monotonic() < deadline: time.sleep(.02)
        result = cache.prepare(source)
        self.assertEqual(result['state'], 'ready')
        self.assertGreater(result['duration'], 0)
        self.assertGreater(len(result['clips']), 0)
        with patch.object(cache, '_probe', side_effect=AssertionError('cache miss')):
            self.assertEqual(cache.prepare(source), result)
        other = PreviewCache(cache.directory)
        with patch.object(other, '_probe', side_effect=AssertionError('disk cache miss')):
            self.assertEqual(other.prepare(source), result)
        other.close()
        cache.close()

    def test_preview_endpoint_preserves_indexing(self):
        name = next(name for name, root in self.server.mounts.items() if root == self.roots[0])
        path = name + '/nested/Demo Video.mp4'
        with patch('server.requires_indexed_playback', return_value=True), \
             patch.object(self.server.playback_cache, 'prepare', return_value={'state':'preparing'}):
            data = json.loads(self.request('/api/preview', path)[2])
            self.assertEqual(data['state'], 'preparing'); self.assertTrue(data['indexed'])

    def test_real_audio_analysis_selects_sustained_active_interval(self):
        import imageio_ffmpeg
        source = Path(self.temp.name)/'scoring.mp4'
        subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'error',
                        '-f', 'lavfi', '-i', 'color=s=64x64:r=1:d=90', '-f', 'lavfi', '-i',
                        r'aevalsrc=(0.0002+0.2*between(t\,30\,65))*sin(2*PI*440*t):s=8000:d=90',
                        '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-shortest', str(source)],
                       check=True, capture_output=True, timeout=20,
                       creationflags=0x08000000 if __import__('os').name == 'nt' else 0)
        cache = PreviewCache(Path(self.temp.name)/'scoring-cache')
        cache.prepare(source)
        deadline = time.monotonic()+20
        while cache.active and time.monotonic() < deadline: time.sleep(.02)
        result = cache.prepare(source)
        self.assertEqual(result['state'], 'ready')
        self.assertEqual(result['method'], 'audio-activity')
        self.assertGreaterEqual(result['clips'][0]['start'], 29)
        self.assertLessEqual(result['clips'][0]['start'], 36)
        cache.close()

    def test_ts_preview_survives_remux_lru_touches(self):
        source = Path(__file__).resolve().parents[1]/'UITests/Fixtures/演示文件夹/时间戳偏移测试.ts'
        target = self.roots[0]/'nested'/'Preview.ts'; shutil.copyfile(source, target)
        name = next(name for name, root in self.server.mounts.items() if root == self.roots[0])
        relative = name+'/nested/Preview.ts'
        deadline = time.monotonic()+20
        result = {}
        while time.monotonic() < deadline:
            status, _, body = self.request('/api/preview', relative)
            self.assertEqual(status, 200); result = json.loads(body)
            if result['state'] == 'ready': break
            self.assertIn(result['state'], ('preparing', 'waiting')); time.sleep(.05)
        self.assertEqual(result['state'], 'ready'); self.assertTrue(result['indexed'])
        self.assertEqual(json.loads(self.request('/api/preview', relative)[2]), result)

    def test_cancellation_stops_only_selected_analysis_and_does_not_cache_failure(self):
        source = self.roots[0]/'nested'/'Demo Video.mp4'
        cache = PreviewCache(Path(self.temp.name)/'cancel-cache')
        original_run = cache._run
        with patch.object(cache, '_run', side_effect=lambda command, timeout: original_run([sys.executable, '-c', 'import time; time.sleep(20)'], timeout)):
            cache.prepare(source)
            deadline = time.monotonic()+3
            while cache.process is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertIsNotNone(cache.process)
            cache.cancel(self.roots[1]/'nested'/'Demo Video.mp4')
            self.assertIsNone(cache.process.poll())
            cache.cancel(source)
            deadline = time.monotonic()+3
            while cache.active and time.monotonic() < deadline: time.sleep(.01)
            self.assertIsNone(cache.active); self.assertEqual(len(cache.results), 0)
            self.assertEqual(list(cache.directory.glob('*.json')), [])
        self.assertEqual(self.request('/api/preview-cancel', '', method='POST', token='bad')[0], 401)
        self.assertEqual(self.request('/api/preview-cancel', '../outside.mp4', method='POST')[0], 403)
        cache.close()


class SegmentTests(unittest.TestCase):
    def test_sustained_sound_beats_impulse_and_candidates_are_separated(self):
        levels = [(i*.5, -65.) for i in range(600)]
        for i in range(120, 200): levels[i] = (i*.5, -14 if i%4 else -22)
        for i in range(320, 400): levels[i] = (i*.5, -20 if i%4 else -30)
        levels[20] = (10., 0.)  # A loud isolated bang must not win.
        clips = score_segments(300, levels)
        self.assertGreaterEqual(len(clips), 2)
        self.assertGreaterEqual(clips[0]['start'], 55)
        self.assertLessEqual(clips[0]['start'], 75)
        for clip in clips:
            self.assertGreaterEqual(clip['score'], 0); self.assertLessEqual(clip['score'], 100)
        for first, second in zip(clips, clips[1:]): self.assertGreaterEqual(abs(first['start']-second['start']), 15)

    def test_silence_uniform_audio_and_sparse_bangs_fall_back(self):
        self.assertEqual(score_segments(120, []), [])
        self.assertEqual(score_segments(120, [(i*.5, -12) for i in range(240)]), [])
        self.assertEqual(score_segments(120, [(i*10., 0) for i in range(12)]), [])
        self.assertEqual(score_segments(10, [(0, 0)]), [])

    def test_ffmpeg_rms_timestamps_parse_without_private_content(self):
        data = b'frame:0 pts:0 pts_time:0\nlavfi.astats.Overall.RMS_level=-inf\nframe:1 pts:4000 pts_time:0.5\nlavfi.astats.Overall.RMS_level=-12.5\n'
        parsed = list(parse_levels(data))
        self.assertEqual(parsed[1], (.5, -12.5)); self.assertEqual(parsed[0][0], 0)

    def test_sampling_bounds_short_long_and_invalid(self):
        for duration in (0, -1, float('nan'), float('inf')): self.assertEqual(sample_segments(duration), [])
        self.assertEqual(sample_segments(12), [{'start':0, 'end':12}])
        for duration in (36, 60, 300, 10800):
            clips = sample_segments(duration)
            self.assertGreaterEqual(len(clips), 2)
            self.assertLessEqual(len(clips), 3)
            for clip in clips:
                self.assertGreaterEqual(clip['start'], 0); self.assertLessEqual(clip['end'], duration)
                self.assertAlmostEqual(clip['end']-clip['start'], 30)


if __name__ == '__main__': unittest.main()
