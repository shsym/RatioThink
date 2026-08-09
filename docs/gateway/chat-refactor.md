# Gateway architecture

RatioThink serves OpenAI-compatible HTTP from a native Rust gateway. PIE owns
model execution and exposes its WebSocket control plane; inferlets contain
request semantics and generation logic but no HTTP code.

```
Rational.app
  -> ratio-gateway        HTTP, SSE, routing, ids, status
    -> PIE WebSocket      process execution and cancellation
      -> inferlet wasm    request semantics and model interaction
        -> gen-core       prompt construction and generation
```

The helper starts PIE, then starts the gateway in attach mode with PIE's control
address and token. It publishes the gateway port in `EngineStatus.running`,
which is the endpoint used by `HTTPEngineClient`. The filesystem `http.port`
file exists for test harnesses and is not the app's source of truth.

## Ownership and lifecycle

The helper supervises both native processes. It owns a pipe connected to the
gateway's stdin; EOF makes the gateway exit if the helper is killed. Normal
shutdown closes that pipe and confirms the gateway is reaped before stopping
PIE. The gateway removes its supervisor port file on every exit path.

After readiness, liveness checks both the child process and `/healthz`. A dead
or wedged gateway is reported by name as a session liveness failure. Recovery
restarts the complete PIE and gateway session, including reloading the model;
it never falls back silently to the legacy daemon backend.

Gateway mode does not call PIE's `launch_daemon`. Daemon mode remains an
explicit alternative while migration is in progress.

## Request path

The gateway parses the routing and transport fields it needs, then launches the
selected inferlet through PIE. `gen-core` owns OpenAI request validation,
prompt construction, sampling, and decoding. Nothing below the gateway creates
HTTP statuses, OpenAI response objects, ids, or timestamps.

Inferlets send versioned, sequenced events through `session::send`. The gateway
rejects sequence gaps because PIE's guest send API does not report delivery
failure. The first protocol commit event determines when an HTTP response can
be opened:

- `chat-v1`: `Ready`
- `tree-v1`: `tree_start`
- `json-unary-v1`: the returned value

Errors before the commit event become ordinary HTTP errors. Errors after it are
rendered in-band according to the protocol class.

## Streaming and cancellation

The inferlet runs one generation loop for both streaming and buffered replies.
Streaming renders events as SSE. Buffered replies collect the same events and
serialize the neutral return value.

Cancellation is the backpressure mechanism. Dropping the HTTP body wakes the
driver, signals the PIE process, and always terminates the process after the
guest's bounded cancellation grace period. This prevents a slow or disconnected
client from indefinitely buffering events or occupying model execution.

## Inferlet registry

An inferlet is a wasm and manifest pair. The manifest declares its route,
protocol class, aliases, preload behavior, and snapshot-prefix metadata.
Reload scans and validates a complete replacement registry before swapping it
in. Installed artifacts are keyed by content digest so changed files reinstall.

The inferlet directory is trusted. Snapshot prefixes support correctness and GC
scoping, not isolation: PIE currently authorizes snapshots by user and name,
not by launching program.

## Compatibility constraints

- `Inferlets/chat-apc` stays frozen as the comparison implementation.
- The app continues to resolve its endpoint from helper-published engine state.
- Gateway selection crosses XPC as an explicit per-request value.
- A new inferlet needs no gateway code only when an existing protocol class
  describes its commit, terminal, rendering, and cancellation behavior.
- Full byte-for-byte legacy parity is not implied by the development A/B gate;
  that gate compares visible content and event-kind ordering.
