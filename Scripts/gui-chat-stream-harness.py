#!/usr/bin/env python3
"""Deterministic chat-stream mock engine for the #381 GUI E2E suites.

Serves the two `/v1` endpoints the App's `HTTPEngineClient` consumes — a
`GET /v1/models` listing and a streaming `POST /v1/chat/completions` — with
fully controllable timing so a seated GUI test can assert paths a real engine
cannot reproduce deterministically:

  --mode hold    The first `--hold-count` chat requests (default 1) stream a
                 role frame + one content delta (`--hold-token`) and then
                 HOLD the connection open with NO finish frame and NO
                 `[DONE]` sentinel, so the stream stays in flight until
                 either the client cancels (#507's composer stop button /
                 chat deletion) or the test releases it via
                 `POST /control/release[?n=K]`, which grants K (default 1)
                 release credits; each credit finishes exactly ONE held
                 stream with `--reply` + a `stop` finish frame. Credit
                 consumption is atomic (#518), so concurrent held streams
                 each need their own credit. Every request past
                 `--hold-count` returns a normal, fully-finished reply
                 (`--reply`).

  --mode normal  EVERY chat request returns a normal finished reply
                 (`--reply`). Used by the no-model → Load-default follow-through
                 suite, where the interesting timing is the engine start, not
                 the stream.

The held thread polls the socket with a tiny SSE comment keep-alive so it
exits promptly when the client disconnects (rather than lingering for the full
`--hold-seconds` backstop). SSE comment lines (`:`-prefixed) are ignored by the
client parser, so they never leak into the assistant bubble.
"""
import argparse
import json
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class LocalThreadingHTTPServer(ThreadingHTTPServer):
    """Bind loopback test servers without reverse-DNS/FQDN lookup."""

    daemon_threads = True

    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = port


class State:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.chat_count = 0
        # #507/#518: release credits granted by POST /control/release.
        # Each credit finishes exactly ONE held stream; held threads consume
        # credits atomically under `lock` (a bare Event's test-then-clear let
        # two concurrent holders both finish on a single release).
        self.release_credits = 0

    def try_consume_release(self) -> bool:
        with self.lock:
            if self.release_credits > 0:
                self.release_credits -= 1
                return True
            return False

    def next_request_index(self) -> int:
        with self.lock:
            self.chat_count += 1
            return self.chat_count


class Handler(BaseHTTPRequestHandler):
    server_version = "GuiChatStreamHarness/1.0"

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            self.send_json({"status": "ok"})
        elif self.path == "/v1/models":
            self.send_json({
                "object": "list",
                "data": [
                    {
                        "id": self.server.state.args.model_id,
                        "object": "model",
                        "owned_by": "pie-test",
                    }
                ],
            })
        else:
            self.send_error(404, "not found")

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)  # drain the request body
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/control/release":
            # #518: counting release. `?n=K` (default 1) grants K credits;
            # each credit finishes exactly ONE held stream — consumption is
            # atomic under `state.lock`, so two concurrently-held streams can
            # never both consume a single credit.
            query = urllib.parse.parse_qs(parsed.query)
            try:
                count = int(query.get("n", ["1"])[0])
            except ValueError:
                self.send_error(400, "n must be an integer")
                return
            if count < 1:
                self.send_error(400, "n must be >= 1")
                return
            with self.server.state.lock:
                self.server.state.release_credits += count
            self.send_json({"released": count})
            return
        if parsed.path != "/v1/chat/completions":
            self.send_error(404, "not found")
            return

        args = self.server.state.args
        index = self.server.state.next_request_index()

        if args.mode == "hold" and index <= args.hold_count:
            self.stream_hold(args.hold_token, args.hold_seconds, args.reply)
        else:
            self.stream_reply(args.reply)

    # --- SSE writers -------------------------------------------------------

    def open_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def write_frame(self, frame: dict):
        self.wfile.write(b"data: ")
        self.wfile.write(json.dumps(frame, separators=(",", ":")).encode("utf-8"))
        self.wfile.write(b"\n\n")
        self.wfile.flush()

    def stream_reply(self, text: str):
        """A normal, fully-finished assistant turn."""
        self.open_sse()
        self.write_frame({"choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
        self.write_frame({"choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]})
        self.write_frame({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def stream_hold(self, token: str, hold_seconds: float, reply: str):
        """Emit one partial delta, then hold the stream open WITHOUT a finish
        frame until the client disconnects, the backstop elapses, or the test
        releases it (`POST /control/release`) — on release, finish normally
        with `reply` + a `stop` frame (#507: proves a backgrounded stream
        runs to completion instead of being cancelled)."""
        self.open_sse()
        self.write_frame({"choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
        self.write_frame({"choices": [{"index": 0, "delta": {"content": token}, "finish_reason": None}]})
        deadline = time.monotonic() + hold_seconds
        while time.monotonic() < deadline:
            try:
                if self.server.state.try_consume_release():
                    self.write_frame({"choices": [{"index": 0, "delta": {"content": reply}, "finish_reason": None}]})
                    self.write_frame({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    return
                # SSE comment keep-alive: ignored by the client parser, but the
                # write raises once the client closes the connection, so the
                # thread exits promptly on cancel instead of sleeping the full
                # backstop.
                self.wfile.write(b": hold\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return
            time.sleep(0.25)

    # --- helpers -----------------------------------------------------------

    def send_json(self, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("gui-chat-stream-harness: " + fmt % args + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--model-id", default="gui-stream-deterministic")
    parser.add_argument("--mode", choices=["hold", "normal"], default="normal")
    parser.add_argument("--hold-count", type=int, default=1,
                        help="hold mode: number of leading chat requests that hold")
    parser.add_argument("--hold-token", default="PARTIAL-HOLD-381")
    parser.add_argument("--reply", default="Recovered reply after cancel.")
    parser.add_argument("--hold-seconds", type=float, default=60.0)
    args = parser.parse_args()

    port_file = Path(args.port_file)
    port_file.parent.mkdir(parents=True, exist_ok=True)

    server = LocalThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.state = State(args)
    host, port = server.server_address
    port_file.write_text(f"http://{host}:{port}", encoding="utf-8")
    print(f"gui-chat-stream-harness: mode={args.mode} model={args.model_id} listening http://{host}:{port}", flush=True)

    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
