import hashlib
import http.client
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import threading
import unittest

from legacy_backup import read_backup, save_archive, import_archive
from user_state import UserState

LIBRARY = '0123456789abcdef'


def operation(seq=1, kind='favorite', deleted=False, base=0, mode='edit'):
    value = {'item': {'path': 'folder/movie.mkv', 'name': 'movie.mkv', 'video': True, 'directory': False}, 'updated': 100}
    if kind == 'history':
        value.update(position=50, duration=100)
    return {'id': str(seq), 'seq': seq, 'base': base, 'kind': kind, 'key': 'folder/movie.mkv',
            'mode': mode, 'deleted': deleted, 'value': value}


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'state.sqlite3'
        self.state = UserState(self.path)

    def exchange(self, ops, device='a', **extra):
        return self.state.exchange(LIBRARY, dict(protocol=1, libraryID=LIBRARY, deviceID=device, operations=ops, **extra))

    def test_restart_retry_and_tombstone(self):
        first = self.exchange([operation()])
        self.state = UserState(self.path)
        retry = self.exchange([operation()])
        self.assertEqual(first['revision'], retry['revision'])
        removed = self.exchange([operation(2, deleted=True, base=first['revision'])])
        restored = self.exchange([operation(mode='seed')], 'old-backup')
        self.assertEqual(removed['records'], restored['records'])
        self.assertTrue(restored['records'][0]['deleted'])

    def test_concurrent_edit_conflicts_and_newer_same_device(self):
        first = self.exchange([operation()])
        stale = self.exchange([operation()], 'b')
        self.assertEqual(len(stale['conflicts']), 1)
        self.assertEqual(first['revision'], stale['revision'])
        newer = self.exchange([operation(2)])
        self.assertGreater(newer['revision'], first['revision'])

    def test_all_batch_validated_before_writing(self):
        bad = operation(2)
        bad['value']['item']['path'] = '../outside'
        with self.assertRaises(ValueError):
            self.exchange([operation(), bad])
        self.assertEqual(self.exchange([])['records'], [])

    def test_library_and_identity_isolation(self):
        first = self.exchange([operation()])
        other = self.state.exchange('other', dict(protocol=1, libraryID='other', deviceID='a', operations=[]))
        self.assertEqual(other['records'], [])
        rejected = self.exchange([operation(2, deleted=True)], serverID='not-this-pc')
        self.assertTrue(rejected['identityChanged'])
        self.assertEqual(first['records'], self.exchange([])['records'])

    def test_preference_allowlist(self):
        op = operation()
        op.update(kind='preference', key='videoDisplayMode', value='full')
        self.assertEqual(self.exchange([op])['records'][0]['value'], 'full')
        for key in ('password', [], None):
            op.update(seq=2, id='2', key=key)
            with self.assertRaises(ValueError):
                self.exchange([op])


class BackupTests(unittest.TestCase):
    setUp = SyncTests.setUp
    exchange = SyncTests.exchange
    def backup(self, encrypted=False, finished=True):
        folder = Path(self.tmp.name) / 'apple-backup'
        folder.mkdir()
        domain = 'AppDomain-local.bixer.LanCinema'
        relative = 'Library/Preferences/local.bixer.LanCinema.plist'
        file_id = hashlib.sha1(f'{domain}-{relative}'.encode()).hexdigest()
        with sqlite3.connect(folder / 'Manifest.db') as db:
            db.execute('CREATE TABLE Files(fileID,domain,relativePath,flags)')
            db.execute('INSERT INTO Files VALUES(?,?,?,1)', (file_id, domain, relative))
        for name, data in [('Manifest.plist', {'IsEncrypted': encrypted}),
                           ('Status.plist', {'SnapshotState': 'finished' if finished else 'running'})]:
            (folder / name).write_bytes(plistlib.dumps(data))
        (folder / file_id[:2]).mkdir()
        favorite = operation()['value']
        favorite.update(host='pc', library=LIBRARY)
        prefs = {'favoritesV1': [favorite], 'playbackRate': 1.5, 'password': 'DO-NOT-EXPORT',
                 f'progress:pc:{LIBRARY}:folder/movie.ts:ts-indexed-v1': 72}
        (folder / file_id[:2] / file_id).write_bytes(plistlib.dumps(prefs))
        return folder

    def test_extract_safety_copy_import_and_retry(self):
        folder = self.backup()
        source = {p: p.read_bytes() for p in folder.rglob('*') if p.is_file()}
        archive = read_backup(folder)
        self.assertNotIn('password', archive['preferences'])
        path = Path(self.tmp.name) / 'safe.plist'
        save_archive(archive, path)
        with self.assertRaises(FileExistsError):
            save_archive(archive, path)
        counts = import_archive(plistlib.loads(path.read_bytes()), self.state)
        self.assertEqual((counts['favorite'], counts['history'], counts['skipped']), (1, 1, 0))
        first = self.exchange([])
        import_archive(archive, self.state)
        self.assertEqual(first['revision'], self.exchange([])['revision'])
        for path, data in source.items():
            self.assertEqual(data, path.read_bytes())

    def test_encrypted_backup_refused(self):
        with self.assertRaisesRegex(ValueError, '加密'):
            read_backup(self.backup(encrypted=True))

    def test_unfinished_backup_refused(self):
        with self.assertRaisesRegex(ValueError, '尚未完成'):
            read_backup(self.backup(finished=False))

    def test_missing_app_is_not_reported_as_safe(self):
        folder = self.backup()
        with sqlite3.connect(folder / 'Manifest.db') as db:
            db.execute('DELETE FROM Files')
        with self.assertRaisesRegex(ValueError, '未找到'):
            read_backup(folder)


class SyncHTTPTests(unittest.TestCase):
    def setUp(self):
        from server import MediaServer
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name) / 'media'
        root.mkdir()
        self.path = Path(self.temp.name) / 'records.sqlite3'
        self.server = MediaServer(('127.0.0.1', 0), root, 'test-token', state_path=self.path)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def post(self, token='test-token', library=None, operations=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        body = json.dumps({'protocol': 1, 'deviceID': 'test-phone', 'libraryID': library or self.server.library_id, 'operations': operations or []})
        connection.request('POST', '/api/sync?token=' + token, body=body, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        status, payload = response.status, response.read()
        connection.close()
        return status, json.loads(payload)

    def test_requires_auth_and_correct_library_before_writing(self):
        self.assertEqual(self.post(token='wrong')[0], 401)
        self.assertEqual(self.post(library='wrong')[0], 409)
        self.assertFalse(self.path.exists())
        status, result = self.post(operations=[operation()])
        self.assertEqual(status, 200)
        self.assertEqual(len(result['records']), 1)
        self.assertEqual(list(self.server.root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
