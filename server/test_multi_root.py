import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from server import MediaServer
import test_server


class MultiRootTests(unittest.TestCase):
    request = test_server.ServerTests.request

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.roots = [base / 'first' / '同名文件夹', base / 'second' / '同名文件夹']
        for index, root in enumerate(self.roots):
            (root / '子目录').mkdir(parents=True)
            (root / '子目录' / 'clip.ts').write_bytes(bytes([index]) * 1024)
            (root / '子目录' / 'clip.srt').write_text('中文字幕', encoding='utf-8')
        (base / 'secret.txt').write_text('outside')
        self.server = MediaServer(('127.0.0.1', 0), self.roots, 'test-access-code')
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.names = list(self.server.mounts)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def test_virtual_library_lists_distinct_mounts_and_nested_files(self):
        status, _, body = self.request('/api/list', '')
        self.assertEqual(status, 200)
        items = json.loads(body)['items']
        self.assertEqual(len(items), 2)
        self.assertEqual(len({x['path'] for x in items}), 2)
        for item in items:
            self.assertTrue(item['directory'])
            status, _, body = self.request('/api/list', item['path'])
            self.assertEqual(status, 200)
            nested = json.loads(body)['items'][0]
            self.assertEqual(nested['name'], '子目录')
            status, _, body = self.request('/api/list', nested['path'])
            self.assertEqual(status, 200)
            self.assertEqual({x['name'] for x in json.loads(body)['items']}, {'clip.ts', 'clip.srt'})

    def test_search_all_mounts_and_limit_subtree(self):
        status, _, body = self.request('/api/search', '', query={'q': 'CLIP'})
        self.assertEqual(status, 200)
        items = json.loads(body)['items']
        self.assertEqual(len(items), 4)
        self.assertEqual(len({x['path'] for x in items}), 4)
        for name in self.names:
            _, _, body = self.request('/api/search', name + '/子目录', query={'q': 'clip'})
            self.assertEqual(len(json.loads(body)['items']), 2)
            self.assertTrue(all(x['path'].startswith(name + '/') for x in json.loads(body)['items']))
        _, _, body = self.request('/api/search', '', query={'q': '同名文件夹'})
        self.assertEqual(len(json.loads(body)['items']), 2)
        self.assertEqual(self.request('/api/search', '', query={'q': ' '})[0], 400)

    def test_media_ranges_subtitles_and_probe_resolve_correct_root(self):
        for index, name in enumerate(self.names):
            relative = name + '/子目录/clip.ts'
            status, headers, body = self.request(path=relative, headers={'Range': 'bytes=8-11'})
            self.assertEqual((status, body), (206, bytes([index]) * 4))
            self.assertEqual(headers['Content-Range'], 'bytes 8-11/1024')
            self.assertEqual(self.request(path=name + '/子目录/clip.srt')[2].decode(), '中文字幕')
            with patch.object(self.server.playback_cache, 'prepare', return_value={'status': 'preparing'}) as prepare:
                self.assertEqual(self.request('/api/playback', relative)[0], 200)
                prepare.assert_called_once_with(self.roots[index] / '子目录' / 'clip.ts')
            with patch('video_probe.detect_crop', return_value={}) as crop:
                self.assertEqual(self.request('/api/crop', relative)[0], 200)
                crop.assert_called_once_with(self.roots[index] / '子目录' / 'clip.ts')

    def test_authentication_and_escape_are_still_blocked(self):
        self.assertEqual(self.request('/api/list', '', token='bad')[0], 401)
        for value in ['../secret.txt', '/secret.txt', self.names[0] + '/../secret.txt',
                      self.names[0] + '/C:/Windows/win.ini', self.names[0] + '/clip.ts:stream',
                      self.names[0] + '/..\\secret.txt']:
            self.assertEqual(self.request(path=value)[0], 403, value)
        self.assertEqual(self.request('/api/list', 'unknown-mount')[0], 404)
        self.assertEqual(self.request(path='')[0], 400)

    def test_disconnected_mount_does_not_hide_other_mounts(self):
        moved = self.roots[0].with_name('temporarily-unavailable')
        self.roots[0].rename(moved)
        try:
            self.assertEqual(self.request('/api/list', '')[0], 200)
            self.assertEqual(self.request('/api/list', self.names[0])[0], 404)
            _, _, body = self.request('/api/search', '', query={'q': 'clip'})
            payload = json.loads(body)
            self.assertEqual(len(payload['items']), 2)
            self.assertGreater(payload['skipped'], 0)
        finally:
            moved.rename(self.roots[0])

    def test_names_and_library_identity_survive_reordering(self):
        other = MediaServer(('127.0.0.1', 0), list(reversed(self.roots)), 'password')
        try:
            self.assertEqual(other.mounts, self.server.mounts)
            self.assertEqual(other.library_id, self.server.library_id)
        finally:
            other.server_close()

    @unittest.skipUnless(os.name == 'nt' and Path('G:/').is_dir(), 'Requires Windows G: test volume')
    def test_actual_cross_drive_streaming(self):
        # Synthetic temporary data only; no existing shared files are accessed.
        with tempfile.TemporaryDirectory(prefix='lancinema-test-', dir='G:/') as other_drive:
            second = Path(other_drive)
            if second.drive.casefold() == self.roots[0].drive.casefold():
                self.skipTest('Temporary directories must be on different drives')
            (second / 'cross.mp4').write_bytes(b'cross-drive')
            server = MediaServer(('127.0.0.1', 0), [self.roots[0], second], 'test-access-code')
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            original = self.server
            try:
                self.server = server
                name = next(name for name, root in server.mounts.items() if root == second)
                self.assertEqual(self.request(path=name + '/cross.mp4')[2], b'cross-drive')
                self.assertEqual(self.request('/api/list', '')[0], 200)
            finally:
                self.server = original
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    unittest.main()
