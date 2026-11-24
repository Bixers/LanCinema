"""Lazy filesystem inventory. Never decode media while enumerating the library."""
import os
from pathlib import Path
import threading
import time


class VideoLibrary:
    def __init__(self, roots, mounts, extensions):
        self.roots, self.mounts, self.extensions = roots, mounts, extensions
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.worker = None
        self.result = None
        self.updated = 0

    def snapshot(self, refresh=False):
        with self.lock:
            if not self.stopped.is_set() and (self.worker is None or not self.worker.is_alive()):
                if refresh or self.result is None or time.monotonic() - self.updated > 60:
                    self.worker = threading.Thread(target=self._scan, daemon=True)
                    self.worker.start()
            if self.result is None:
                return {'state': 'preparing', 'items': []}
            return dict(self.result, refreshing=bool(self.worker and self.worker.is_alive()))

    def _scan(self):
        items, skipped, seen_files = [], 0, set()
        roots = [(root, name + '/') for name, root in self.mounts.items()] if self.mounts else [(self.roots[0], '')]
        for root, prefix in roots:
            pending, visited = [root], set()
            while pending and not self.stopped.is_set():
                directory = pending.pop()
                try:
                    real = directory.resolve(strict=True)
                    real.relative_to(root)
                    if real in visited:
                        continue
                    visited.add(real)
                    with os.scandir(directory) as entries:
                        for entry in entries:
                            if self.stopped.is_set():
                                return
                            try:
                                lexical = Path(entry.path)
                                checked = lexical.resolve(strict=True)
                                checked.relative_to(root)
                                if checked.is_dir():
                                    pending.append(lexical)
                                elif checked.is_file() and lexical.suffix.lower() in self.extensions:
                                    if checked in seen_files:
                                        continue
                                    stat = checked.stat()
                                    if stat.st_size == 0:
                                        continue
                                    seen_files.add(checked)
                                    items.append({'name': lexical.name, 'path': prefix + lexical.relative_to(root).as_posix(),
                                                  'directory': False, 'video': True, 'subtitle': False,
                                                  'size': stat.st_size, 'modified': stat.st_mtime,
                                                  'thumbnailVersion': f'{stat.st_size}:{stat.st_mtime_ns}'})
                            except (OSError, ValueError):
                                skipped += 1
                except (OSError, ValueError):
                    skipped += 1
                # Yield between directories so discovery does not monopolize I/O.
                self.stopped.wait(.001)
        items.sort(key=lambda item: (item['name'].casefold(), item['path'].casefold()))
        with self.lock:
            self.result = {'state': 'ready', 'items': items, 'skipped': skipped}
            self.updated = time.monotonic()

    def close(self):
        self.stopped.set()
        if self.worker:
            self.worker.join(timeout=2)
