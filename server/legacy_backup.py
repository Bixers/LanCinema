"""Read only LanCinema preferences from a completed, unencrypted Apple backup.

No phone writes and no changes to the source backup. Export is deliberately
limited to favorites/history/preferences; connection secrets are excluded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import time
import uuid

from user_state import PREFERENCES, UserState, number, validate_operation


def read_backup(folder, domain=None):
    folder = Path(folder).resolve(strict=True)
    with (folder / 'Manifest.plist').open('rb') as stream:
        manifest = plistlib.load(stream)
    if manifest.get('IsEncrypted'):
        raise ValueError('这是加密的 iPhone 备份。请先使用支持密码解密的工具导出局域影院的偏好设置；本工具不会修改备份或关闭加密。')
    with (folder / 'Status.plist').open('rb') as stream:
        status = plistlib.load(stream)
    if status.get('SnapshotState') != 'finished':
        raise ValueError('iPhone 备份尚未完成，请等待备份完成后再导入。')
    uri = (folder / 'Manifest.db').as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True) as db:
        candidates = db.execute("SELECT fileID,domain,relativePath FROM Files WHERE flags=1 AND domain LIKE 'AppDomain-%' AND relativePath LIKE 'Library/Preferences/%.plist'").fetchall()
    matches = []
    for file_id, app_domain, relative in candidates:
        bundle = app_domain.removeprefix('AppDomain-')
        if domain and app_domain != domain:
            continue
        if not domain and 'lancinema' not in bundle.lower():
            continue
        if relative != f'Library/Preferences/{bundle}.plist':
            continue
        if not re.fullmatch(r'[0-9a-f]{40}', file_id):
            raise ValueError('备份索引中的文件编号无效。')
        expected = hashlib.sha1(f'{app_domain}-{relative}'.encode()).hexdigest()
        if expected != file_id:
            raise ValueError('备份索引与文件编号不一致。')
        path = folder / file_id[:2] / file_id
        if not path.exists():
            path = folder / file_id  # Older Apple backup layout.
        if path.stat().st_size > 32 * 1024 * 1024:
            raise ValueError('偏好设置文件异常过大。')
        with path.open('rb') as stream:
            prefs = plistlib.load(stream)
        if isinstance(prefs, dict) and any(k in prefs for k in ('favoritesV1', 'playbackHistoryV1')):
            matches.append((app_domain, prefs))
        elif isinstance(prefs, dict) and any(k.startswith('progress:') for k in prefs):
            matches.append((app_domain, prefs))
    if not matches:
        raise ValueError('此备份未找到局域影院的收藏或观看记录，不能据此确认升级安全。请确认备份时间、App 标识以及是否允许备份。')
    if len(matches) != 1:
        raise ValueError('备份包含多个局域影院实例，请指定要导入的 App domain。')
    app_domain, prefs = matches[0]
    selected = {k: v for k, v in prefs.items() if k in ('favoritesV1', 'playbackHistoryV1') or k in PREFERENCES or k.startswith('progress:')}
    return {'format': 'LanCinema-legacy-backup', 'version': 1, 'domain': app_domain,
            'exportedAt': time.time(), 'preferences': selected}


def save_archive(archive, destination):
    """Exclusive creation: never overwrite a previous safety copy."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=True)
    with destination.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    # Read back rather than assuming a successful write is a valid archive.
    if plistlib.loads(destination.read_bytes()) != archive:
        raise ValueError('导出的记录校验失败。')
    return hashlib.sha256(data).hexdigest()


def prepare_import(archive):
    if archive.get('format') != 'LanCinema-legacy-backup' or archive.get('version') != 1:
        raise ValueError('不是支持的局域影院记录备份。')
    prefs = archive['preferences']
    grouped, skipped = {}, 0
    def put(library, kind, key, value):
        nonlocal skipped
        if not isinstance(library, str) or not re.fullmatch(r'[0-9a-f]{16}', library):
            skipped += 1
            return
        op = {'id': str(uuid.uuid4()), 'seq': 1, 'base': 0, 'kind': kind, 'key': key,
              'mode': 'seed', 'deleted': False, 'value': value}
        try:
            validate_operation(op)
        except (ValueError, TypeError):
            skipped += 1
            return
        entries = grouped.setdefault(library, {})
        previous = entries.get((kind, key))
        if previous is None or value.get('updated', 0) > previous['value'].get('updated', 0):
            entries[(kind, key)] = op
    for kind, field in (('favorite', 'favoritesV1'), ('history', 'playbackHistoryV1')):
        rows = prefs.get(field, [])
        if not isinstance(rows, list):
            skipped += 1
            continue
        for index, row in enumerate(rows):
            if not isinstance(row, dict) or not isinstance(row.get('item'), dict):
                skipped += 1
                continue
            value = {k: v for k, v in row.items() if k in ('item', 'position', 'duration', 'updated')}
            value.setdefault('updated', archive['exportedAt'] - index * .001)
            put(row.get('library'), kind, row['item'].get('path'), value)
    for key, position in prefs.items():
        if not key.startswith('progress:') or not number(position) or position <= 0:
            continue
        match = re.fullmatch(r'progress:.+:([0-9a-f]{16}):(.+)', key)
        if not match:
            skipped += 1
            continue
        library, path = match.groups()
        path = path.removesuffix(':ts-indexed-v1')
        if ('history', path) in grouped.get(library, {}):
            continue
        put(library, 'history', path, {'item': {'path': path, 'name': path.rsplit('/', 1)[-1], 'video': True},
                                     'position': position, 'duration': 0, 'updated': archive['exportedAt']})
    for library, entries in grouped.items():
        for key, validator in PREFERENCES.items():
            if key in prefs and validator(prefs[key]):
                entries[('preference', key)] = {'id': str(uuid.uuid4()), 'seq': 1, 'base': 0,
                    'kind': 'preference', 'key': key, 'mode': 'seed', 'deleted': False, 'value': prefs[key]}
        for seq, op in enumerate(entries.values(), 1):
            op['seq'] = seq
    counts = {kind: sum(op['kind'] == kind for entries in grouped.values() for op in entries.values())
              for kind in ('favorite', 'history', 'preference')}
    return grouped, {**counts, 'skipped': skipped, 'libraries': len(grouped)}


def import_archive(archive, state):
    grouped, counts = prepare_import(archive)
    if not grouped:
        raise ValueError('备份中没有可导入的有效记录，不能据此确认升级安全。')
    device = 'backup-' + str(uuid.uuid4())
    for library, entries in grouped.items():
        operations = list(entries.values())
        for start in range(0, len(operations), 200):
            result = state.exchange(library, {'protocol': 1, 'libraryID': library,
                'deviceID': device, 'operations': operations[start:start+200]})
        persisted = {(r['kind'], r['key']) for r in result['records']}
        if not set(entries).issubset(persisted):
            raise RuntimeError('电脑同步库读回校验失败。原始备份仍保留，请勿升级。')
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backup', help='包含 Manifest.db 的 Apple 备份文件夹')
    parser.add_argument('--export', required=True, help='新的 .plist 安全副本路径')
    parser.add_argument('--domain', help='只在存在多个 App 实例时指定 AppDomain-…')
    parser.add_argument('--import-state', action='store_true', help='导出并校验后写入电脑同步库')
    parser.add_argument('--state-path', help='测试/便携模式的同步数据库路径')
    args = parser.parse_args()
    archive = read_backup(args.backup, args.domain)
    digest = save_archive(archive, args.export)
    _, counts = prepare_import(archive)
    if args.import_state:
        counts = import_archive(archive, UserState(args.state_path))
    print(json.dumps({'sha256': digest, 'imported': args.import_state, **counts}, ensure_ascii=False))


if __name__ == '__main__':
    main()
