import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.parse import urlencode

from server import MediaServer


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name) / 'root'
        cls.root.mkdir()
        cls.folder = cls.root / '中文 空格 # & %'
        cls.folder.mkdir()
        (cls.folder / 'clip.mkv').write_bytes(bytes(range(256)) * 4)
        (cls.root / 'zero.mp4').touch()
        (cls.root / 'caption.srt').write_text('subtitle', encoding='utf-8')
        (Path(cls.temp.name) / 'secret.txt').write_text('outside')
        cls.server = MediaServer(('127.0.0.1', 0), cls.root, 'test-access-code')
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def request(self, endpoint='/media', path='中文 空格 # & %/clip.mkv', method='GET', headers=None, token='test-access-code', query=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        conn.request(method, endpoint + '?' + urlencode({'path': path, 'token': token, **(query or {})}), headers=headers or {})
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        conn.close()
        return result

    def test_nested_unicode_listing(self):
        status, _, body = self.request('/api/list', '中文 空格 # & %')
        self.assertEqual(status, 200)
        item = json.loads(body)['items'][0]
        self.assertEqual(item['path'], '中文 空格 # & %/clip.mkv')
        self.assertTrue(item['video'])
        self.assertEqual(item['size'], 1024)
        self.assertAlmostEqual(item['modified'], (self.folder / 'clip.mkv').stat().st_mtime, places=3)

    def test_search_returns_modification_time(self):
        status, _, body = self.request('/api/search', '', query={'q': 'clip'})
        self.assertEqual(status, 200)
        item = json.loads(body)['items'][0]
        self.assertAlmostEqual(item['modified'], (self.folder / 'clip.mkv').stat().st_mtime, places=3)

    def test_directories_first(self):
        _, _, body = self.request('/api/list', '')
        self.assertTrue(json.loads(body)['items'][0]['directory'])

    def test_full_stream(self):
        status, headers, body = self.request()
        self.assertEqual((status, len(body)), (200, 1024))
        self.assertEqual(body, bytes(range(256)) * 4)

    def test_seek_ranges(self):
        for requested, expected, content in [
            ('bytes=10-19', bytes(range(10, 20)), 'bytes 10-19/1024'),
            ('bytes=1020-', bytes(range(252, 256)), 'bytes 1020-1023/1024'),
            ('bytes=-4', bytes(range(252, 256)), 'bytes 1020-1023/1024'),
            ('bytes=1020-9999', bytes(range(252, 256)), 'bytes 1020-1023/1024'),
        ]:
            with self.subTest(requested=requested):
                status, headers, body = self.request(headers={'Range': requested})
                self.assertEqual(status, 206)
                self.assertEqual(headers['Content-Range'], content)
                self.assertEqual(body, expected)

    def test_invalid_ranges(self):
        for requested in ['bytes=2048-', 'bytes=20-10', 'bytes=-0', 'bytes=-', 'bytes=0-1,3-4', 'foo']:
            with self.subTest(requested=requested):
                status, headers, _ = self.request(headers={'Range': requested})
                self.assertEqual(status, 416)
                self.assertEqual(headers['Content-Range'], 'bytes */1024')

    def test_head(self):
        status, headers, body = self.request(method='HEAD', headers={'Range': 'bytes=0-9'})
        self.assertEqual((status, headers['Content-Length'], body), (206, '10', b''))

    def test_authentication(self):
        for token in ['', 'wrong']:
            self.assertEqual(self.request(token=token)[0], 401)

    def test_path_escape_denied(self):
        for path in ['../secret.txt', '/secret.txt', 'C:/Windows/win.ini', 'a/../../secret.txt', '..\\secret.txt', 'zero.mp4:stream']:
            with self.subTest(path=path):
                self.assertEqual(self.request(path=path)[0], 403)

    def test_empty_file(self):
        self.assertEqual(self.request(path='zero.mp4')[2], b'')
        self.assertEqual(self.request(path='zero.mp4', headers={'Range': 'bytes=0-'})[0], 416)

    def test_missing_file(self):
        self.assertEqual(self.request(path='missing.mp4')[0], 404)

    def test_no_writes(self):
        self.assertEqual(self.request(method='POST')[0], 501)
        self.assertEqual(self.request(method='DELETE')[0], 501)

    def test_search_includes_nested_files(self):
        status, _, body = self.request('/api/search', '', query={'q': 'CLIP'})
        self.assertEqual(status, 200)
        self.assertEqual([x['path'] for x in json.loads(body)['items']], ['中文 空格 # & %/clip.mkv'])

    def test_search_restricts_to_current_subtree(self):
        status, _, body = self.request('/api/search', '中文 空格 # & %', query={'q': 'caption'})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['items'], [])

    def test_search_chinese_and_non_video_files(self):
        _, _, folders = self.request('/api/search', '', query={'q': '中文'})
        self.assertTrue(json.loads(folders)['items'][0]['directory'])
        _, _, subtitles = self.request('/api/search', '', query={'q': '.srt'})
        self.assertEqual(json.loads(subtitles)['items'][0]['name'], 'caption.srt')

    def test_search_current_and_deep_duplicates(self):
        deep = self.folder / 'level2' / 'level3'
        deep.mkdir(parents=True, exist_ok=True)
        (deep / 'clip.mkv').write_bytes(b'deep')
        try:
            _, _, body = self.request('/api/search', '中文 空格 # & %', query={'q': 'clip'})
            paths = {item['path'] for item in json.loads(body)['items']}
            self.assertEqual(paths, {'中文 空格 # & %/clip.mkv', '中文 空格 # & %/level2/level3/clip.mkv'})
        finally:
            (deep / 'clip.mkv').unlink()
            deep.rmdir()
            deep.parent.rmdir()

    def test_search_empty_and_outside_scope(self):
        self.assertEqual(self.request('/api/search', '', query={'q': '  '})[0], 400)
        self.assertEqual(self.request('/api/search', '../', query={'q': 'secret'})[0], 403)
        self.assertEqual(self.request('/api/search', '', token='wrong', query={'q': 'clip'})[0], 401)

    def test_search_symlink_escape_and_cycle(self):
        link = self.folder / 'escape'
        cycle = self.folder / 'cycle'
        try:
            try:
                link.symlink_to(Path(self.temp.name), target_is_directory=True)
                cycle.symlink_to(self.folder, target_is_directory=True)
            except OSError:
                self.skipTest('Creating symlinks requires OS permission')
            _, _, body = self.request('/api/search', '中文 空格 # & %', query={'q': 'secret'})
            self.assertEqual(json.loads(body)['items'], [])
            _, _, body = self.request('/api/search', '中文 空格 # & %', query={'q': 'clip'})
            self.assertEqual(len(json.loads(body)['items']), 1)
        finally:
            if link.is_symlink():
                link.unlink()
            if cycle.is_symlink():
                cycle.unlink()


if __name__ == '__main__':
    unittest.main()
