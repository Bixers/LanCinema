"""Map independent filesystem roots to a read-only virtual library."""
import os
from pathlib import Path


def normalize_roots(values):
    if isinstance(values, (str, os.PathLike)):
        values = [values]
    if not isinstance(values, (list, tuple)) or not values:
        raise ValueError('请至少添加一个共享文件夹。')
    roots = []
    for value in values:
        if not isinstance(value, (str, os.PathLike)) or not str(value).strip():
            raise ValueError('共享文件夹路径不能为空。')
        path = Path(value).resolve(strict=True)
        if not path.is_dir():
            raise ValueError(f'不是文件夹：{value}')
        if path not in roots:
            roots.append(path)
    return roots


def mount_names(roots):
    """Readable names, deterministic across reordering, including drive roots."""
    mounts = {}
    for root in sorted(roots, key=lambda path: str(path).casefold()):
        drive = root.drive.rstrip(':').replace('\\', ' ').strip()
        base = root.name or (drive + '盘' if drive else '文件夹')
        if root.name and drive:
            base += f'（{drive}）'
        name, suffix = base, 2
        while name.casefold() in {key.casefold() for key in mounts}:
            name = f'{base} ({suffix})'
            suffix += 1
        mounts[name] = root
    return mounts
