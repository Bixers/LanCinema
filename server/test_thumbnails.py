import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

from server import MediaServer
from thumbnails import ThumbnailCache


class ThumbnailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / '共享 + &%#'
        self.root.mkdir()
        self.fixture = Path(__file__).resolve().parents[1] / 'UITests/Fixtures'
        self.source = self.root / '测试+视频.mkv'
        shutil.copyfile(self.fixture / '演示文件夹/测试视频.mkv', self.source)
        self.cache = ThumbnailCache(self.base / 'cache')

    def tearDown(self):
        self.temp.cleanup()

    def pixels(self, jpeg):
        import imageio_ffmpeg
        result = subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-v', 'error', '-f', 'image2pipe',
                                 '-i', '-', '-vf', 'scale=32:32', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                                input=jpeg, capture_output=True, timeout=10,
                                creationflags=0x08000000 if os.name == 'nt' else 0)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), 32*32*3)
        return result.stdout

    def test_actual_mkv_and_unindexed_ts_frames_without_remux(self):
        before = hashlib.sha256(self.source.read_bytes()).hexdigest()
        for path in (self.source, self.fixture / '演示文件夹/时间戳偏移测试.ts'):
            status, jpeg = self.cache.get(path)
            self.assertEqual(status, 200)
            rgb = self.pixels(jpeg)
            for channel in range(3):
                colored = sum(rgb[i+channel] > 130 and rgb[i+channel] > rgb[i+(channel+1)%3] + 40
                              for i in range(0, len(rgb), 3))
                self.assertGreater(colored, 30, 'Preview must contain actual multicolor video pixels')
        self.assertEqual(before, hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_disk_cache_survives_restart_and_file_change_invalidates(self):
        first = self.cache.get(self.source)
        self.assertEqual(first[0], 200)
        restart = ThumbnailCache(self.cache.directory)
        with patch.object(restart, '_render', side_effect=AssertionError('cache miss')):
            self.assertEqual(restart.get(self.source), first)
        old_key = self.cache.key(self.source)
        shutil.copyfile(self.fixture / '黑边竖屏测试.mkv', self.source)
        self.assertNotEqual(self.cache.key(self.source), old_key)
        updated = restart.get(self.source)
        self.assertEqual(updated[0], 200)
        self.assertNotEqual(updated[1], first[1])

    def test_short_clip_fallback_and_display_aspect(self):
        import imageio_ffmpeg
        short = self.root / 'short.mp4'
        subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-v', 'error', '-f', 'lavfi',
                        '-i', 'testsrc2=size=120x240:rate=10', '-t', '0.5', '-c:v', 'mpeg4', str(short)],
                       check=True, capture_output=True, timeout=10,
                       creationflags=0x08000000 if os.name == 'nt' else 0)
        status, jpeg = self.cache.get(short)
        self.assertEqual(status, 200)
        self.pixels(jpeg)
        # JPEG SOF dimensions: portrait remains portrait, bounded by 320x180.
        for marker in (b'\xff\xc0', b'\xff\xc1', b'\xff\xc2'):
            index = jpeg.find(marker)
            if index >= 0:
                height = int.from_bytes(jpeg[index+5:index+7], 'big')
                width = int.from_bytes(jpeg[index+7:index+9], 'big')
                self.assertEqual((width, height), (90, 180))
                break
        else:
            self.fail('No JPEG dimensions')

    def test_invalid_file_negative_cache_and_busy_limit(self):
        broken = self.root / 'bad.mp4'
        broken.write_bytes(b'not a video')
        self.assertEqual(self.cache.get(broken), (204, b''))
        with patch.object(self.cache, '_render', side_effect=AssertionError('negative cache miss')):
            self.assertEqual(self.cache.get(broken), (204, b''))
        self.cache.workers.acquire(); self.cache.workers.acquire()
        try:
            self.assertEqual(self.cache.get(self.source), (503, b''))
        finally:
            self.cache.workers.release(); self.cache.workers.release()
        self.assertEqual(self.cache.get(self.source)[0], 200)

    def test_http_auth_scope_multi_root_and_cache_revision(self):
        other = self.base / 'other'
        other.mkdir()
        shutil.copyfile(self.source, other / self.source.name)
        server = MediaServer(('127.0.0.1', 0), [self.root, other], 'test-token')
        server.thumbnail_cache = self.cache
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(path, token='test-token', endpoint='/api/thumbnail'):
            conn = http.client.HTTPConnection(*server.server_address, timeout=25)
            conn.request('GET', endpoint+'?'+urlencode({'path': path, 'token': token}))
            response = conn.getresponse()
            result = response.status, dict(response.getheaders()), response.read()
            conn.close()
            return result
        try:
            mounts = sorted(server.mounts, key=lambda name: server.mounts[name] != self.root)
            path = mounts[0] + '/' + self.source.name
            self.assertEqual(request(path, token='wrong')[0], 401)
            for unsafe in ('../secret.mkv', mounts[0]+'/../other/'+self.source.name, 'C:/private.mp4'):
                self.assertEqual(request(unsafe)[0], 403)
            self.assertEqual(request(mounts[0])[0], 400)
            for name in mounts:
                status, headers, body = request(name+'/'+self.source.name)
                self.assertEqual(status, 200)
                self.assertEqual(headers['Content-Type'], 'image/jpeg')
                self.pixels(body)
            body = request(mounts[0], endpoint='/api/list')[2]
            version = json.loads(body)['items'][0]['thumbnailVersion']
            os.utime(self.source, ns=(self.source.stat().st_atime_ns, self.source.stat().st_mtime_ns+1000000000))
            updated = json.loads(request(mounts[0], endpoint='/api/list')[2])['items'][0]['thumbnailVersion']
            self.assertNotEqual(version, updated)
            # Deleting the original revokes even a previously cached cover.
            self.source.unlink()
            self.assertEqual(request(path)[0], 404)
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__':
    unittest.main()
