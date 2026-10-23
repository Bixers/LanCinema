# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_data_files
import os
import sys
from pathlib import Path
import PySide6

# Dependency scanning must not pick ICU/UCRT DLLs from unrelated tools on PATH.
os.environ['PATH'] = os.pathsep.join([
    str(Path(PySide6.__file__).parent), str(Path(sys.executable).parent),
    str(Path(os.environ['SystemRoot']) / 'System32'), os.environ['SystemRoot']])

datas = [('server/app.ico', '.')]
datas += collect_data_files('imageio_ffmpeg')


a = Analysis(
    ['server/desktop.py'],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=['zeroconf._utils.ipaddress'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
# Windows 10/11 provide UCRT. Do not bundle a stale copy discovered on PATH
# (for example from an unrelated image tool): it breaks Qt DLL loading.
a.binaries = [item for item in a.binaries
              if item[0].replace('\\', '/').split('/')[-1].lower() != 'ucrtbase.dll'
              and not item[0].replace('\\', '/').split('/')[-1].lower().startswith('api-ms-win-crt-')]
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='LanCinema-PC',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['server/app.ico'],
)
