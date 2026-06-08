#!/usr/bin/env python3
# Offline mock pie engine for README screenshot capture.
#
# Serves the four loopback endpoints Rational.app's HTTPEngineClient
# speaks (see Shared/Engine/HTTPEngineClient.swift "Wire shapes"), with
# canned content, so the REAL app UI can be driven into a populated state
# for screenshots WITHOUT a real pie engine or a multi-GB model download:
#
#   GET  /healthz            -> {"status":"ok"}
#   GET  /v1/models          -> {"object":"list","data":[{id,object,owned_by}]}
#   POST /v1/models/load     -> SSE: (optional hold) {"event":"model_ready"} + [DONE]
#   POST /v1/chat/completions-> SSE: {"event":"model_ready"} meta, then OpenAI
#                               chat.completion.chunk frames replaying --answer
#                               (first delta carries role:"assistant"), a final
#                               finish_reason:"stop" chunk, then [DONE].
#
# Pure test infrastructure — no production code. Mirrors loadviz-harness.py's
# disconnect-aware SSE hold so a cancelled load never synthesizes model_ready.
import argparse
import json
import select
import sys
import time
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


DEFAULT_ANSWER = (
    "Everything runs on your Mac. Rational launches a bundled Pie engine "
    "locally, so your prompts and replies never leave the device — and the "
    "same engine is exposed as an OpenAI-compatible endpoint your own scripts "
    "can call."
)


class State:
    def __init__(self, model, answer, load_hold_seconds, chat_step_seconds):
        self.model = model
        self.answer = answer
        self.load_hold_seconds = load_hold_seconds
        self.chat_step_seconds = chat_step_seconds


class Handler(BaseHTTPRequestHandler):
    server_version = "ReadmeScreenshotHarness/1.0"

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            self.send_json({"status": "ok"})
        elif self.path == "/v1/models":
            self.send_json({
                "object": "list",
                "data": [{
                    "id": self.server.state.model,
                    "object": "model",
                    "owned_by": "pie",
                }],
            })
        else:
            self.send_error(404, "not found")

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        if self.path == "/v1/models/load":
            self.handle_load()
        elif self.path == "/v1/chat/completions":
            self.handle_chat()
        else:
            self.send_error(404, "not found")

    def handle_load(self):
        # Optional disconnect-aware hold so a screenshot of the "Loading
        # <id>" indicator window has time to be captured; a client close
        # mid-hold (a cancel) short-circuits without a late model_ready.
        try:
            self.start_sse()
            hold = self.server.state.load_hold_seconds
            if hold > 0:
                ready, _, _ = select.select([self.connection], [], [], hold)
                if ready:
                    return
            self.write_frame({"event": "model_ready"})
            self.finish_sse()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_chat(self):
        try:
            self.start_sse()
            # Meta-frame the demux tolerates (pie-control v1 emits it).
            self.write_frame({"event": "model_ready"})
            step = self.server.state.chat_step_seconds
            first = True
            for token in self.tokenize(self.server.state.answer):
                delta = {"content": token}
                if first:
                    delta = {"role": "assistant", "content": token}
                    first = False
                self.write_frame({"choices": [{"index": 0,
                                               "delta": delta,
                                               "finish_reason": None}]})
                if step > 0:
                    time.sleep(step)
            self.write_frame({"choices": [{"index": 0,
                                           "delta": {},
                                           "finish_reason": "stop"}]})
            self.finish_sse()
        except (BrokenPipeError, ConnectionResetError):
            pass

    @staticmethod
    def tokenize(answer):
        # Split into whitespace-prefixed tokens so concatenation
        # reproduces the answer exactly and the UI streams word-by-word.
        words = answer.split(" ")
        out = []
        for i, word in enumerate(words):
            out.append(word if i == 0 else " " + word)
        return out

    # --- SSE helpers (each frame flushed before the next) ---

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def write_frame(self, frame):
        self.wfile.write(b"data: ")
        self.wfile.write(json.dumps(frame, separators=(",", ":")).encode("utf-8"))
        self.wfile.write(b"\n\n")
        self.wfile.flush()

    def finish_sse(self):
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def send_json(self, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("readme-screenshot-harness: " + fmt % args + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--model", default="Qwen3-8B-Instruct")
    parser.add_argument("--answer", default=DEFAULT_ANSWER)
    parser.add_argument("--load-hold-seconds", type=float, default=0.0)
    parser.add_argument("--chat-step-ms", type=float, default=45.0)
    args = parser.parse_args()

    port_file = Path(args.port_file)
    port_file.parent.mkdir(parents=True, exist_ok=True)

    server = LocalThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.state = State(
        model=args.model,
        answer=args.answer,
        load_hold_seconds=args.load_hold_seconds,
        chat_step_seconds=args.chat_step_ms / 1000.0,
    )
    host, port = server.server_address
    port_file.write_text(f"http://{host}:{port}", encoding="utf-8")
    print(f"readme-screenshot-harness: listening http://{host}:{port} "
          f"model={args.model}", flush=True)

    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
