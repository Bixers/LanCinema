"""Authenticated user metadata, separate from read-only shared media.

Server revisions resolve conflicts without trusting a phone's wall clock.
Tombstones and per-device sequence receipts survive restarts and retries.
"""
import json
import math
import os
from pathlib import Path
import sqlite3
import uuid


def state_path():
    return Path(os.environ.get('LOCALAPPDATA', str(Path.home() / '.local/share'))) / 'LanCinema' / 'user-state.sqlite3'


def integer(value):
    return type(value) is int and 0 <= value <= 2**53-1


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def path_key(value):
    return (isinstance(value, str) and 0 < len(value) <= 4096 and
            not any(c in value for c in ('\\', ':', '\0')) and not value.startswith('/') and
            all(p not in ('', '.', '..') for p in value.split('/')))


PREFERENCES = {
    'playbackRate': lambda v: number(v) and .5 <= v <= 3,
    'holdPlaybackRate': lambda v: number(v) and 2 <= v <= 3,
    'fileIconView': lambda v: type(v) is bool,
    'fileSortDescending': lambda v: type(v) is bool,
    'fileSortKey': lambda v: v in ('name', 'size', 'type', 'modified'),
    'videoDisplayMode': lambda v: v in ('smart', 'fill', 'full'),
}


def validate_operation(op):
    if not isinstance(op, dict):
        raise ValueError('Invalid operation')
    if (not isinstance(op.get('id'), str) or not 1 <= len(op['id']) <= 80 or
            not integer(op.get('seq')) or not op['seq'] or not integer(op.get('base')) or
            op.get('mode') not in ('edit', 'seed') or type(op.get('deleted')) is not bool):
        raise ValueError('Invalid operation identity')
    kind, key = op.get('kind'), op.get('key')
    if kind not in ('favorite', 'history', 'preference'):
        raise ValueError('Invalid kind')
    if kind == 'preference':
        if not isinstance(key, str) or key not in PREFERENCES or (not op['deleted'] and not PREFERENCES[key](op.get('value'))):
            raise ValueError('Invalid preference')
        return
    if not path_key(key):
        raise ValueError('Invalid path')
    if op['deleted']:
        return
    value = op.get('value')
    if not isinstance(value, dict) or not isinstance(value.get('item'), dict):
        raise ValueError('Invalid record')
    item = value['item']
    if (item.get('path') != key or not isinstance(item.get('name'), str) or len(item['name']) > 4096 or
            not number(value.get('updated'))):
        raise ValueError('Invalid metadata')
    # Only these fields are persisted; credentials and addresses are never part of a record.
    if set(value) - {'item', 'position', 'duration', 'updated'} or set(item) - {'path', 'name', 'size', 'modified', 'thumbnailVersion', 'video', 'directory'}:
        raise ValueError('Unknown metadata')
    if any(field in item and not number(item[field]) for field in ('size', 'modified')):
        raise ValueError('Invalid file metadata')
    if 'thumbnailVersion' in item and (not isinstance(item['thumbnailVersion'], str) or len(item['thumbnailVersion']) > 256):
        raise ValueError('Invalid thumbnail version')
    if any(field in item and type(item[field]) is not bool for field in ('video', 'directory')):
        raise ValueError('Invalid file kind')
    if kind == 'favorite' and not (item.get('directory') or item.get('video')):
        raise ValueError('Unsupported favorite')
    if kind == 'history' and (not number(value.get('position')) or value['position'] <= 0 or
                              not number(value.get('duration')) or item.get('directory')):
        raise ValueError('Invalid progress')
    if len(json.dumps(value)) > 32768:
        raise ValueError('Record too large')


class UserState:
    def __init__(self, path=None):
        self.path = Path(path) if path is not None else state_path()

    def exchange(self, library, payload):
        if (not isinstance(payload, dict) or payload.get('protocol') != 1 or payload.get('libraryID') != library or
                not isinstance(payload.get('deviceID'), str) or not 1 <= len(payload['deviceID']) <= 80 or
                not isinstance(payload.get('operations'), list) or len(payload['operations']) > 200):
            raise ValueError('Invalid synchronization request')
        operations = payload['operations']
        for op in operations:
            validate_operation(op)
        if len({op['seq'] for op in operations}) != len(operations) or len({op['id'] for op in operations}) != len(operations):
            raise ValueError('Duplicate operation identity')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA synchronous=FULL')
            db.execute('BEGIN IMMEDIATE')
            db.execute('CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS records (library TEXT, kind TEXT, key TEXT, revision INTEGER, deleted INTEGER, value TEXT, device TEXT, sequence INTEGER, PRIMARY KEY(library,kind,key))')
            db.execute('CREATE TABLE IF NOT EXISTS receipts (library TEXT, device TEXT, sequence INTEGER, PRIMARY KEY(library,device))')
            db.execute('INSERT OR IGNORE INTO metadata VALUES (?,?)', ('serverID', str(uuid.uuid4())))
            db.execute('INSERT OR IGNORE INTO metadata VALUES (?,?)', ('revision', '0'))
            server_id = db.execute('SELECT value FROM metadata WHERE key=?', ('serverID',)).fetchone()[0]
            expected = payload.get('serverID')
            if expected and expected != server_id:
                # A different PC at the same IP must not silently receive private pending records.
                db.rollback()
                return {'protocol': 1, 'serverID': server_id, 'libraryID': library, 'identityChanged': True}
            revision = int(db.execute('SELECT value FROM metadata WHERE key=?', ('revision',)).fetchone()[0])
            device = payload['deviceID']
            receipt = db.execute('SELECT sequence FROM receipts WHERE library=? AND device=?', (library, device)).fetchone()
            seen = receipt[0] if receipt else 0
            acknowledged, conflicts = [], []
            for op in sorted(operations, key=lambda op: op['seq']):
                acknowledged.append(op['id'])
                if op['seq'] <= seen:
                    continue
                seen = op['seq']
                old = db.execute('SELECT * FROM records WHERE library=? AND kind=? AND key=?', (library, op['kind'], op['key'])).fetchone()
                accept = (old is None) if op['mode'] == 'seed' else (
                    op['base'] == (old['revision'] if old else 0) or (old is not None and old['device'] == device and op['seq'] > old['sequence']))
                if not accept:
                    if op['mode'] == 'edit':
                        conflicts.append({'kind': op['kind'], 'key': op['key']})
                    continue
                revision += 1
                db.execute('INSERT OR REPLACE INTO records VALUES (?,?,?,?,?,?,?,?)',
                           (library, op['kind'], op['key'], revision, int(op['deleted']),
                            json.dumps(op.get('value'), ensure_ascii=False, allow_nan=False) if not op['deleted'] else 'null', device, op['seq']))
            db.execute('INSERT OR REPLACE INTO receipts VALUES (?,?,?)', (library, device, seen))
            db.execute('UPDATE metadata SET value=? WHERE key=?', (str(revision), 'revision'))
            records = [{'kind': r['kind'], 'key': r['key'], 'revision': r['revision'], 'deleted': bool(r['deleted']), 'value': json.loads(r['value'])}
                       for r in db.execute('SELECT * FROM records WHERE library=? ORDER BY revision DESC', (library,))]
            db.commit()  # Acknowledge only after durable commit; a lost response can be retried.
            return {'protocol': 1, 'serverID': server_id, 'libraryID': library, 'revision': revision,
                    'acknowledged': acknowledged, 'conflicts': conflicts, 'records': records}
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()
