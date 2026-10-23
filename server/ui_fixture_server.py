from pathlib import Path
from server import MediaServer

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1] / 'UITests' / 'Fixtures'
    MediaServer(('127.0.0.1', 8123), root, 'ui-test-access-code').serve_forever()
