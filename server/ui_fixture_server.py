from pathlib import Path
import shutil
from server import MediaServer

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
    MediaServer(('127.0.0.1', 8123), root, 'ui-test-access-code').serve_forever()
