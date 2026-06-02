#!/usr/bin/env python3
# production path-1 model-load-indicator GUI harness.
#
# Unlike an earlier meta-frame harness (which prefixed the
# CHAT-completions stream with model_loading meta-frames to drive
# applyChatMetaEvent — a path pie-control v1 never emits), this harness
# exercises the REAL production indicator path:
#
#   model menu -> confirm gate -> ProfileSwapCoordinator
#     -> ModelLoadCenter.load(modelID:streamFactory:)
#       -> HTTPEngineClient.loadModel -> POST /v1/models/load
#
# `center.load` sets state=.loading LOCALLY at ModelLoadCenter.swift:124
# the instant the load begins, BEFORE any stream frame arrives. So the
# load endpoint here emits ONLY a hold then `model_ready` (no
# `model_loading` frame) — exactly pie-control v1's shape
# (HTTPEngineClient.swift:21 "model_ready + [DONE]"). The hold keeps the
# `.loading` window open long enough for XCUITest to observe the toolbar
# "Loading <id>" label before it clears to the ready ring
# ("Model loaded: <id>"). Pure test infrastructure — no production code.
import argparse
import json
import select
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class State:
    def __init__(self, hold_seconds: float, fail_load_attempts: int = 0):
        self.hold_seconds = hold_seconds
        # #396 retry coverage: fail the FIRST `fail_load_attempts`
        # `/v1/models/load` requests with HTTP 500 so ModelLoadCenter goes
        # `.failed`, then succeed (hold -> model_ready) on the next attempt
        # — the popover's Retry re-invokes the stored factory, which must
        # recover. 0 = legacy behaviour (every load succeeds).
        self.fail_load_attempts = fail_load_attempts
        self._load_calls = 0
        self._lock = threading.Lock()

    def should_fail_load(self) -> bool:
        """Atomically count this /v1/models/load and report whether it is
        within the leading failure window."""
        with self._lock:
            self._load_calls += 1
            return self._load_calls <= self.fail_load_attempts


class Handler(BaseHTTPRequestHandler):
    server_version = "LoadVizHarness/1.0"

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            self.send_json({"status": "ok"})
        elif self.path == "/v1/models":
            # Two entries on purpose. ChatScaffoldView reconciles this list
            # into the toolbar model menu AND sets residentModelID = ids[0].
            # The model-menu confirm gate only publishes a Switch (→ load)
            # when the picked id DIFFERS from the resident, so the resident
            # stub MUST be first and MUST NOT be the seeded default the
            # S302 test clicks. The second entry is the seeded default
            # (ProfileStore.defaultChatModelID) whose leaf is the menu
            # label the test selects ("Qwen3-0.6B-Q8_0.gguf").
            self.send_json({
                "object": "list",
                "data": [
                    {
                        "id": "loadviz-resident",
                        "object": "model",
                        "owned_by": "pie-test",
                    },
                    {
                        "id": "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
                        "object": "model",
                        "owned_by": "pie-test",
                    },
                ],
            })
        else:
            self.send_error(404, "not found")

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        if self.path == "/v1/models/load":
            # #396 retry coverage: fail the leading N loads with HTTP 500
            # so ModelLoadCenter goes `.failed`; the popover's Retry then
            # re-invokes the stored factory and the next attempt recovers.
            if self.server.state.should_fail_load():
                self.send_error(500, "loadviz forced load failure (#396 retry coverage)")
                return
            # Production path-1 load. Hold (model still loading) then
            # `model_ready`. NO `model_loading` frame — `.loading` is set
            # locally by ModelLoadCenter.load() at load-start, so the
            # toolbar lights up regardless. The hold is what makes the
            # window deterministically observable.
            #
            # Disconnect-aware hold (review F5): `time.sleep` would block
            # the handler thread regardless of client disconnect and then
            # synthesize a late `model_ready` write — which masks a real
            # cancel regression (the cancel test's negative-assert window
            # could end before the late ready landed). Use `select` on
            # the underlying socket so the hold short-circuits the
            # moment the client closes (e.g. URLSession task cancelled
            # by `center.cancel()`); when ready fires, skip the
            # `model_ready` write entirely so a cancelled load never
            # produces a ready event over the wire.
            try:
                self.start_sse()
                ready, _, _ = select.select(
                    [self.connection], [], [], self.server.state.hold_seconds)
                if ready:
                    # Client closed the connection — this is what a
                    # mid-load cancel looks like over the wire. Bail
                    # without synthesizing `model_ready`.
                    return
                self.write_frame({"event": "model_ready"})
                self.finish_sse()
            except (BrokenPipeError, ConnectionResetError):
                # Defensive — `select` should make this path rare now.
                pass
        else:
            self.send_error(404, "not found")

    # --- SSE helpers (incremental: each frame flushed before the next) ---

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
        sys.stderr.write("loadviz-harness: " + fmt % args + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--hold-seconds", type=float, default=8.0)
    parser.add_argument("--fail-load-attempts", type=int, default=0,
                        help="fail the first N /v1/models/load requests with "
                             "HTTP 500 before succeeding (#396 retry coverage)")
    args = parser.parse_args()

    port_file = Path(args.port_file)
    port_file.parent.mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    # Explicit (stdlib default is True, but make it intentional — review
    # F5): handler threads exit with the server on `kill $HARNESS_PID`,
    # no lingering sleeping handlers.
    server.daemon_threads = True
    server.state = State(args.hold_seconds, fail_load_attempts=args.fail_load_attempts)
    host, port = server.server_address
    port_file.write_text(f"http://{host}:{port}", encoding="utf-8")
    print(f"loadviz-harness: listening http://{host}:{port} hold={args.hold_seconds}s", flush=True)

    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
