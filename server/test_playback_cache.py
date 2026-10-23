import hashlib
import http.client
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import imageio_ffmpeg
from playback_cache import PlaybackCache
from server import MediaServer


FIXTURE = Path(__file__).parents[1] / 'UITests/Fixtures/演示文件夹/时间戳偏移测试.ts'


class PlaybackCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'root'
        self.root.mkdir()
        self.source = self.root / 'sample.ts'
        shutil.copyfile(FIXTURE, self.source)
        self.cache = PlaybackCache(Path(self.temp.name) / 'cache')

    def tearDown(self):
        self.cache.close()
        self.temp.cleanup()

    def ready(self):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            result = self.cache.prepare(self.source)
            self.assertNotEqual(result['state'], 'error', result)
            if result['state'] == 'ready':
                return self.cache.ready_path(self.source)
            time.sleep(.05)
        self.fail('Cache preparation timed out')

    def frame(self, media, second, fast):
        seek = ['-ss', str(second)]
        command = [imageio_ffmpeg.get_ffmpeg_exe(), '-v', 'error']
        command += seek + ['-i', str(media)] if fast else ['-i', str(media)] + seek
        command += ['-map', '0:v:0', '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-']
        result = subprocess.run(command, capture_output=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout), 320*180*3)
        return result.stdout

    def test_indexed_seek_matches_sequential_decoding_and_preserves_source(self):
        original = hashlib.sha256(self.source.read_bytes()).hexdigest()
        cached = self.ready()
        self.assertEqual(cached.suffix, '.mkv')
        for second in (39, 12, 23):
            with self.subTest(second=second):
                self.assertEqual(self.frame(cached, second, True), self.frame(cached, second, False))
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), original)
        # Reopening the service can immediately reuse the persisted index.
        other = PlaybackCache(self.cache.directory)
        try:
            self.assertEqual(other.prepare(self.source)['state'], 'ready')
        finally:
            other.close()
        with self.source.open('ab') as stream:
            stream.write(b'changed')
        self.assertIsNone(self.cache.ready_path(self.source))

    def test_single_worker_and_close_during_preparation(self):
        entered, release = threading.Event(), threading.Event()
        def remux(*args, **kwargs):
            entered.set()
            release.wait(3)
            return False
        second = self.root / 'other.ts'
        shutil.copyfile(self.source, second)
        with patch.object(self.cache, '_remux', side_effect=remux):
            self.assertEqual(self.cache.prepare(self.source)['state'], 'preparing')
            self.assertTrue(entered.wait(3))
            self.assertEqual(self.cache.prepare(second)['state'], 'waiting')
            self.assertEqual(self.cache.prepare(self.source)['state'], 'preparing')
            release.set()
            self.cache.close()
        self.assertIsNone(self.cache.active)
        self.assertIsNone(self.cache.ready_path(self.source))
        self.assertEqual(list(self.cache.directory.glob('*.partial')), [])
        self.assertEqual(self.cache.prepare(second)['state'], 'error')

    def test_subtitle_fallback_is_reported(self):
        def remux(source, destination, subtitles):
            if subtitles:
                return False
            destination.write_bytes(b'synthetic-cache-for-state-test')
            return True
        with patch.object(self.cache, '_remux', side_effect=remux):
            self.ready()
        self.assertTrue(self.cache.prepare(self.source)['subtitleFallback'])

    def test_authenticated_preparation_and_cached_ranges(self):
        server = MediaServer(('127.0.0.1', 0), self.root, 'test-code')
        server.playback_cache.close()
        server.playback_cache = self.cache
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(endpoint, path='sample.ts', token='test-code', prepared=None, method='GET', headers=None):
            query = {'path': path, 'token': token}
            if prepared:
                query['prepared'] = prepared
            conn = http.client.HTTPConnection(*server.server_address, timeout=5)
            conn.request(method, endpoint + '?' + urlencode(query), headers=headers or {})
            response = conn.getresponse()
            result = response.status, dict(response.getheaders()), response.read()
            conn.close()
            return result
        try:
            self.assertEqual(request('/api/playback', token='wrong')[0], 401)
            self.assertEqual(request('/api/playback', path='../outside.ts')[0], 403)
            self.assertEqual(request('/media', prepared='1')[0], 425)
            status, _, body = request('/api/playback')
            self.assertEqual(status, 200)
            self.assertIn(json.loads(body)['state'], ('preparing', 'ready'))
            cached = self.ready().read_bytes()
            status, headers, body = request('/media', prepared='1', headers={'Range': 'bytes=31-127'})
            self.assertEqual(status, 206)
            self.assertEqual(body, cached[31:128])
            self.assertEqual(headers['Content-Range'], f'bytes 31-127/{len(cached)}')
            self.assertEqual(request('/media', prepared='1', token='wrong')[0], 401)
            status, headers, body = request('/media', prepared='1', method='HEAD')
            self.assertEqual((status, int(headers['Content-Length']), body), (200, len(cached), b''))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main()
