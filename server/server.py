"""Read-only LAN video server; desktop settings choose the shared root."""
import argparse
import hmac
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import socket
import ipaddress
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from playback_cache import PlaybackCache, TRANSPORT_STREAMS

ROOT = Path(r"G:\123")
VIDEO = {'.mp4', '.mkv', '.avi', '.mov', '.m4v', '.webm', '.wmv', '.flv', '.ts', '.m2ts', '.mts', '.mpg', '.mpeg', '.vob', '.3gp', '.ogv', '.rm', '.rmvb', '.asf', '.divx'}
SUBTITLES = {'.srt', '.ass', '.ssa', '.vtt', '.sub', '.sup'}


class MediaServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, root, token):
        self.root = Path(root).resolve(strict=True)
        self.token = token
        self.library_id = hashlib.sha256(str(self.root).encode()).hexdigest()[:16]
        self.playback_cache = PlaybackCache()
        super().__init__(address, Handler)

    def server_close(self):
        self.playback_cache.close()
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'LanCinema/1.0'

    def log_message(self, fmt, *args):
        # Never log URLs, filenames or access tokens.
        pass

    def reply(self, status, body, content_type='application/json; charset=utf-8', extra=None):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def error(self, status, message, extra=None):
        self.reply(status, json.dumps({'error': message}, ensure_ascii=False).encode(), extra=extra)

    def resolve(self, value):
        # Only root-relative POSIX paths; reject Windows drive and ADS syntax.
        if '\\' in value or ':' in value or '\0' in value or value.startswith('/'):
            raise PermissionError()
        if any(piece in ('.', '..') for piece in value.split('/')):
            raise PermissionError()
        path = (self.server.root / value).resolve(strict=True)
        if os.path.commonpath([self.server.root, path]) != str(self.server.root):
            raise PermissionError()
        return path

    def describe(self, entry, checked):
        directory = checked.is_dir()
        if not directory and not checked.is_file():
            return None
        metadata = checked.stat()
        return {'name': entry.name, 'path': entry.relative_to(self.server.root).as_posix(),
                'directory': directory, 'size': 0 if directory else metadata.st_size,
                'modified': metadata.st_mtime,
                'video': entry.suffix.lower() in VIDEO, 'subtitle': entry.suffix.lower() in SUBTITLES}

    def search(self, start, keyword):
        """Visit every readable descendant, without following cycles or escaping the search scope."""
        needle = unicodedata.normalize('NFKC', keyword).casefold()
        pending, visited, results, skipped = [start], set(), [], 0
        while pending:
            directory = pending.pop()
            try:
                real = directory.resolve(strict=True)
                real.relative_to(start)
                if real in visited:
                    continue
                visited.add(real)
                with os.scandir(directory) as entries:
                    for entry in entries:
                        try:
                            lexical = Path(entry.path)
                            checked = self.resolve(lexical.relative_to(self.server.root).as_posix())
                            # Junctions and symlinks cannot broaden a subfolder search to siblings.
                            checked.relative_to(start)
                            if checked.is_dir():
                                pending.append(lexical)
                            if needle in unicodedata.normalize('NFKC', entry.name).casefold():
                                item = self.describe(lexical, checked)
                                if item is not None:
                                    results.append(item)
                        except (OSError, ValueError):
                            skipped += 1
            except (OSError, ValueError):
                skipped += 1
        results.sort(key=lambda item: (not item['directory'], item['name'].casefold(), item['path'].casefold()))
        return results, skipped

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            route = urlsplit(self.path)
            query = parse_qs(route.query, keep_blank_values=True)
            token = query.get('token', [''])[0]
            if not hmac.compare_digest(token.encode(), self.server.token.encode()):
                return self.error(401, '访问码不正确')
            if route.path == '/api/info':
                return self.reply(200, json.dumps({'name': socket.gethostname(), 'root': str(self.server.root), 'libraryID': self.server.library_id}, ensure_ascii=False).encode())
            if route.path not in ('/api/list', '/api/search', '/api/crop', '/api/playback', '/media'):
                return self.error(404, '接口不存在')
            relative = query.get('path', [''])[0]
            path = self.resolve(relative)
            if route.path == '/api/playback':
                if not path.is_file() or path.suffix.lower() not in TRANSPORT_STREAMS:
                    return self.error(400, '不是 TS 视频')
                return self.reply(200, json.dumps(self.server.playback_cache.prepare(path), ensure_ascii=False).encode())
            if route.path == '/api/crop':
                if not path.is_file() or path.suffix.lower() not in VIDEO:
                    return self.error(400, '不是视频文件')
                from video_probe import detect_crop
                return self.reply(200, json.dumps(detect_crop(path)).encode())
            if route.path == '/api/search':
                if not path.is_dir():
                    return self.error(400, '不是文件夹')
                keyword = query.get('q', [''])[0].strip()
                if not keyword:
                    return self.error(400, '请输入搜索关键词')
                items, skipped = self.search(path, keyword)
                return self.reply(200, json.dumps({'path': relative, 'items': items, 'skipped': skipped, 'root': str(self.server.root), 'libraryID': self.server.library_id}, ensure_ascii=False).encode())
            if route.path == '/api/list':
                if not path.is_dir():
                    return self.error(400, '不是文件夹')
                items = []
                for entry in path.iterdir():
                    try:
                        rel = entry.relative_to(self.server.root).as_posix()
                        checked = self.resolve(rel)
                        item = self.describe(entry, checked)
                        if item is not None:
                            items.append(item)
                    except (OSError, ValueError):
                        continue
                items.sort(key=lambda item: (not item['directory'], item['name'].casefold()))
                return self.reply(200, json.dumps({'path': relative, 'items': items, 'root': str(self.server.root), 'libraryID': self.server.library_id}, ensure_ascii=False).encode())
            if not path.is_file():
                return self.error(404, '不是文件')
            if query.get('prepared', [''])[0] == '1':
                if path.suffix.lower() not in TRANSPORT_STREAMS:
                    return self.error(400, '不是 TS 视频')
                path = self.server.playback_cache.ready_path(path)
                if path is None:
                    return self.error(425, '视频尚未准备完成，请重新打开')
            with path.open('rb') as stream:
                size = os.fstat(stream.fileno()).st_size
                start, end, status = 0, size - 1, 200
                requested = self.headers.get('Range')
                if requested:
                    match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested.strip())
                    if not match or not any(match.groups()) or size == 0:
                        return self.error(416, '无效范围', {'Content-Range': f'bytes */{size}'})
                    left, right = match.groups()
                    if left:
                        start = int(left)
                        end = min(int(right), size - 1) if right else size - 1
                    else:
                        count = int(right)
                        if count == 0:
                            return self.error(416, '无效范围', {'Content-Range': f'bytes */{size}'})
                        start = max(0, size - count)
                    if start >= size or start > end:
                        return self.error(416, '范围超出文件', {'Content-Range': f'bytes */{size}'})
                    status = 206
                self.send_response(status)
                self.send_header('Content-Type', mimetypes.guess_type(path.name)[0] or 'application/octet-stream')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(max(0, end - start + 1)))
                self.send_header('Cache-Control', 'no-store')
                if status == 206:
                    self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                self.end_headers()
                if self.command == 'HEAD':
                    return
                stream.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = stream.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
        except FileNotFoundError:
            self.error(404, '文件或目录不存在')
        except PermissionError:
            self.error(403, '不允许访问此路径')
        except (OSError, ValueError):
            self.error(400, '无法读取文件或目录')


def main():
    parser = argparse.ArgumentParser()
    candidates = [entry[4][0] for entry in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)]
    addresses = [ip for ip in candidates if any(ipaddress.ip_address(ip) in ipaddress.ip_network(net)
                 for net in ('192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12'))]
    addresses.sort(key=lambda ip: (not ip.startswith('192.168.'), ip))
    parser.add_argument('--bind', default=addresses[0] if addresses else '127.0.0.1')
    parser.add_argument('--port', type=int, default=8123)
    args = parser.parse_args()
    token_file = Path(__file__).with_name('.access-token')
    if not token_file.exists():
        token_file.write_text(secrets.token_hex(8), encoding='utf-8')
    token = token_file.read_text(encoding='utf-8').strip()
    if len(token) < 16:
        raise SystemExit('Invalid access token file')
    server = MediaServer((args.bind, args.port), ROOT, token)
    print(f'Root: {ROOT}\nComputer: {args.bind}\nPort: {args.port}\nAccess code: {token}', flush=True)
    print('Read-only server running. Press Ctrl+C to stop.', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
