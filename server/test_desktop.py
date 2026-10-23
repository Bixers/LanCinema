import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit, parse_qs
from desktop_core import load_settings, save_settings, validate, set_autostart, connection_qr
from desktop import Window, QApplication
from server import MediaServer
from PySide6.QtTest import QTest
from PySide6.QtCore import Qt


class DesktopTests(unittest.TestCase):
    def test_encrypted_settings_survive_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            file = Path(temp)/'settings.json'
            settings = validate({'root': temp, 'password': '密码 & long+password', 'autostart': False})
            save_settings(settings, file)
            self.assertEqual(load_settings(file), settings)
            self.assertNotIn(settings['password'], file.read_text(encoding='utf-8'))
            settings['autostart'] = True
            settings['password'] = 'changed-password'
            save_settings(settings, file)
            self.assertEqual(load_settings(file), settings)

    def test_invalid_settings_do_not_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                validate({'root': temp, 'password': 'short', 'autostart': False})
            with self.assertRaises(FileNotFoundError):
                validate({'root': str(Path(temp)/'absent'), 'password': 'password123', 'autostart': False})

    def test_qr_roundtrips_unicode_and_reserved_characters(self):
        code = connection_qr('192.168.1.7', '中文 &+?#=password')
        parsed = urlsplit(code)
        self.assertEqual((parsed.scheme, parsed.netloc), ('lancinema', 'connect'))
        self.assertEqual(parse_qs(parsed.query)['password'], ['中文 &+?#=password'])

    def test_startup_quotes_executable(self):
        with patch('desktop_core.winreg') as registry:
            set_autostart(True, r'C:\Program Files\局域影院.exe')
            self.assertEqual(registry.SetValueEx.call_args.args[-1], '"C:\\Program Files\\局域影院.exe" --background')
            set_autostart(False)
            registry.DeleteValue.assert_called_once()

    def test_widgets_persist_selected_root_and_password(self):
        app = QApplication.instance() or QApplication([])
        with tempfile.TemporaryDirectory() as temp:
            settings = {'root': temp, 'password': 'old-password', 'autostart': False}
            window = Window(settings, preview=True)
            window.show()
            window.password.selectAll()
            QTest.keyClicks(window.password, 'new-password')
            QTest.mouseClick(window.autostart, Qt.LeftButton)
            window.folder.setText(temp)
            with patch('desktop.save_settings') as save, patch('desktop.MediaServer', side_effect=lambda addr, root, token: MediaServer(('127.0.0.1', 0), root, token)):
                window.apply()
                for _ in range(200):
                    QTest.qWait(50)
                    if window.save.isEnabled():
                        break
                self.assertTrue(window.save.isEnabled())
                self.assertEqual(save.call_args.args[0]['password'], 'new-password')
                self.assertTrue(save.call_args.args[0]['autostart'])
                self.assertEqual(window.service.http.root, Path(temp).resolve())
            window.service.stop()
            window.close()


if __name__ == '__main__':
    unittest.main()
