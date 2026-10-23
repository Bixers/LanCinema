"""Persistent desktop settings, protected with the current Windows user's DPAPI key."""
import base64
import ctypes
import json
import os
from pathlib import Path
import secrets
import sys
import winreg
from urllib.parse import urlencode, quote

RUN_KEY = r'Software\Microsoft\Windows\CurrentVersion\Run'


class Blob(ctypes.Structure):
    _fields_ = [('size', ctypes.c_ulong), ('data', ctypes.POINTER(ctypes.c_ubyte))]


def crypt(data, decrypt=False):
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = Blob()
    if decrypt:
        ok = ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        ok = ctypes.windll.crypt32.CryptProtectData(ctypes.byref(source), 'LanCinema', None, None, None, 1, ctypes.byref(target))
    if not ok:
        raise ctypes.WinError()
    try:
        return ctypes.string_at(target.data, target.size)
    finally:
        ctypes.windll.kernel32.LocalFree(target.data)


def config_path():
    return Path(os.environ['LOCALAPPDATA']) / 'LanCinema' / 'settings.json'


def load_settings(path=None):
    path = path or config_path()
    if not path.exists():
        return {'root': r'G:\123', 'password': secrets.token_urlsafe(9), 'autostart': True}
    raw = json.loads(path.read_text(encoding='utf-8'))
    raw['password'] = crypt(base64.b64decode(raw.pop('protected_password')), decrypt=True).decode('utf-8')
    return raw


def validate(settings):
    root = Path(settings['root']).resolve(strict=True)
    if not root.is_dir():
        raise ValueError('请选择一个文件夹。')
    if not 8 <= len(settings['password']) <= 128:
        raise ValueError('连接密码需要 8～128 个字符。')
    return dict(settings, root=str(root))


def save_settings(settings, path=None):
    path = path or config_path()
    raw = dict(settings)
    raw['protected_password'] = base64.b64encode(crypt(raw.pop('password').encode('utf-8'))).decode('ascii')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)


def set_autostart(enabled, executable=None):
    executable = executable or sys.executable
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
        if enabled:
            winreg.SetValueEx(key, 'LanCinema', 0, winreg.REG_SZ, '"' + executable + '" --background')
        else:
            try:
                winreg.DeleteValue(key, 'LanCinema')
            except FileNotFoundError:
                pass


def connection_qr(host, password):
    return 'lancinema://connect?' + urlencode({'v': '1', 'host': host, 'port': '8123', 'password': password}, quote_via=quote)
