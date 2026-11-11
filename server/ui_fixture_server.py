from pathlib import Path
import shutil
import tempfile
from server import MediaServer, Handler
from user_state import UserState
import uuid


class FixtureHandler(Handler):
    def sync_store(self):
        scope = str(uuid.UUID(self.headers['X-LC-Test-Scope']))
        return UserState(self.server.fixture_states / (scope + '.sqlite3'))

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1] / 'UITests' / 'Fixtures'
    # Reuse synthetic media to exercise real Foundation-to-Python URL handling.
    special = root / '符号+ &%# 测试'
    special.mkdir(exist_ok=True)
    for original, name in [('测试视频.mkv', '视频+ &%# 测试.mkv'),
                           ('测试视频.mkv', '视频 空格.mkv'),
                           ('时间戳偏移测试.ts', '视频+ &%# 测试.ts')]:
        shutil.copyfile(root / '演示文件夹' / original, special / name)
    # Identical names in distinct parents must be distinguishable in icon search.
    for name in ('A', 'B'):
        parent = special / name
        parent.mkdir(exist_ok=True)
        shutil.copyfile(root / '演示文件夹' / '测试视频.mkv', parent / '重复名称.mkv')
    covers = special / '封面预览'
    covers.mkdir(exist_ok=True)
    shutil.copyfile(root / '演示文件夹' / '测试视频.mkv', covers / '横屏视频.mkv')
    shutil.copyfile(root / '演示文件夹' / '时间戳偏移测试.ts', covers / '长名称视频完整换行与封面同时显示.ts')
    (covers / '无法取帧.mp4').write_bytes(b'not a video')
    (covers / '字幕.srt').write_text('1\n00:00:00,000 --> 00:00:02,000\nSynthetic subtitle', encoding='utf-8')
    with tempfile.TemporaryDirectory() as states:
        server = MediaServer(('127.0.0.1', 8123), root, 'ui-test-access-code', state_path=Path(states) / 'unused.sqlite3')
        server.fixture_states = Path(states)
        server.RequestHandlerClass = FixtureHandler
        server.serve_forever()
