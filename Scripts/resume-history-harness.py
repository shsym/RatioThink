#!/usr/bin/env python3
import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class LocalThreadingHTTPServer(ThreadingHTTPServer):
    """Bind loopback test servers without reverse-DNS/FQDN lookup."""

    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = port


RESPONSES = [
    "I will remember cerulean-275.",
    "The code word is cerulean-275.",
    "Again: cerulean-275.",
]


class State:
    def __init__(self, request_log: Path):
        self.request_log = request_log
        self.lock = threading.Lock()
        self.chat_count = 0

    def record_chat(self, body: bytes) -> str:
        with self.lock:
            self.chat_count += 1
            response = RESPONSES[min(self.chat_count - 1, len(RESPONSES) - 1)]
            parsed = json.loads(body.decode("utf-8"))
            with self.request_log.open("a", encoding="utf-8") as f:
                f.write(json.dumps(parsed, sort_keys=True, separators=(",", ":")))
                f.write("\n")
            return response


class Handler(BaseHTTPRequestHandler):
    server_version = "HistoryHarness/1.0"

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            self.send_json({"status": "ok"})
        elif self.path == "/v1/models":
            self.send_json({
                "object": "list",
                "data": [
                    {
                        "id": "resume-deterministic",
                        "object": "model",
                        "owned_by": "pie-test",
                    }
                ],
            })
        else:
            self.send_error(404, "not found")

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        # #469: no /v1/models/load — pie binds the model at boot.
        if self.path == "/v1/chat/completions":
            response = self.server.state.record_chat(body)
            self.send_sse([
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"role": "assistant"},
                            "finish_reason": None,
                        }
                    ]
                },
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": response},
                            "finish_reason": None,
                        }
                    ]
                },
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {},
                            "finish_reason": "stop",
                        }
                    ]
                },
            ])
        else:
            self.send_error(404, "not found")

    def send_json(self, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_sse(self, frames):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for frame in frames:
            self.wfile.write(b"data: ")
            self.wfile.write(json.dumps(frame, separators=(",", ":")).encode("utf-8"))
            self.wfile.write(b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, fmt, *args):
        sys.stderr.write("resume-history-harness: " + fmt % args + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--request-log", required=True)
    args = parser.parse_args()

    port_file = Path(args.port_file)
    request_log = Path(args.request_log)
    port_file.parent.mkdir(parents=True, exist_ok=True)
    request_log.parent.mkdir(parents=True, exist_ok=True)
    request_log.write_text("", encoding="utf-8")

    server = LocalThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.state = State(request_log)
    host, port = server.server_address
    port_file.write_text(f"http://{host}:{port}", encoding="utf-8")
    print(f"resume-history-harness: listening http://{host}:{port}", flush=True)

    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
