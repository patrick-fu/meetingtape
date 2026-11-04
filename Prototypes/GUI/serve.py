#!/usr/bin/env python3
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import functools
from urllib.parse import urlsplit, parse_qs


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        parts = urlsplit(self.path)
        if parts.path == '/' and parse_qs(parts.query).get('study') == ['workflow']:
            self.path = '/workflow.html?' + parts.query
        super().do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='MeetingTape GUI prototype')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    handler = functools.partial(Handler, directory=str(root))
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler)
    print(f'MeetingTape workflow: http://127.0.0.1:{args.port}/?study=workflow&view=captions&variant=A', flush=True)
    print(f'MeetingTape captions: http://127.0.0.1:{args.port}/?study=captions&variant=B', flush=True)
    print(f'MeetingTape original: http://127.0.0.1:{args.port}/?variant=F', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
