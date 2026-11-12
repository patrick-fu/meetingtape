import http.server
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        source = json.loads(request["messages"][1]["content"])
        with (root / "requests.jsonl").open("a") as stream:
            stream.write(json.dumps(source, ensure_ascii=False) + "\n")
        citation = source["citations"][-1]
        notes = {"overview": [{"text": "尾句已归档", "citationIDs": [citation["id"]]}],
                 "topics": [], "decisions": [], "todos": []}
        data = json.dumps({"choices": [{"message": {"content": json.dumps(notes)},
                                       "finish_reason": "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "endpoint.txt").write_text(f"http://127.0.0.1:{server.server_port}/v1")
server.serve_forever()
