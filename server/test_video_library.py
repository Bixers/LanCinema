import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from server import MediaServer
import test_server
from preview import PreviewCache, sample_segments


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
        cache = PreviewCache()
        self.assertEqual(cache.prepare(source)['state'], 'preparing')
        deadline = time.monotonic()+15
        while cache.active and time.monotonic() < deadline: time.sleep(.02)
        result = cache.prepare(source)
        self.assertEqual(result['state'], 'ready')
        self.assertGreater(result['duration'], 0)
        self.assertGreater(len(result['clips']), 0)
        with patch.object(cache, '_probe', side_effect=AssertionError('cache miss')):
            self.assertEqual(cache.prepare(source), result)
        cache.close()

    def test_preview_endpoint_preserves_indexing(self):
        name = next(name for name, root in self.server.mounts.items() if root == self.roots[0])
        path = name + '/nested/Demo Video.mp4'
        with patch('server.requires_indexed_playback', return_value=True), \
             patch.object(self.server.playback_cache, 'prepare', return_value={'state':'preparing'}):
            data = json.loads(self.request('/api/preview', path)[2])
            self.assertEqual(data['state'], 'preparing'); self.assertTrue(data['indexed'])


class SegmentTests(unittest.TestCase):
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
