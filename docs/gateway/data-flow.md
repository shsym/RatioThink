# Data flow: old (chat-apc) vs new (gateway)

One chat turn, end to end, in each design. Line references are to the state of
the repo as of 2026-08-02.

---

## OLD — everything inside one wasm component

```
Rational.app
  │  HTTPEngineClient.baseURLProvider
  │    ← EngineStatusStore.baseURL  = http://127.0.0.1:<port>
  │      ← EngineStatus.running(port:)                    [XPC, from the helper]
  │        ← PieControlLauncher.launch → launch_daemon's bound port
  ▼
POST /v1/chat/completions
  │
  ▼
pie daemon                                    runtime/src/daemon.rs
  • TCP listener bound by pie                 daemon.rs:175-179
  • hyper http1 + service_fn
  • FRESH wasm component per request          daemon.rs:221, 262-292
  ▼
chat-apc.wasm                exports wasi:http/incoming-handler@0.2.4
  • one `match` routes 4 endpoints            lib.rs:52-58
  ▼
chat/completions.rs (5,538 prod lines)
  1. parse the OpenAI body, validate roles/sampling
  2. fill_context → build_prompt_tokens → ctx.append   :5280-5392
  3. Emitter::start(res)  ← HEADERS COMMIT HERE        :3648
  4. decode loop: Generator::next → step.execute()
  5. per delta: try_emit!(em, chunk)  → writes `data: …` bytes itself
  6. terminal chunk, generation_metrics, usage, [DONE]
```

**Where each concern lives:** HTTP, SSE framing, `chatcmpl-` ids, timestamps,
OpenAI shapes, request validation, prompt construction and the decode loop are
all inside the same wasm component.

**Consequences that shaped the rewrite**

- **Commit membrane is early.** Headers go out before generation, so every
  fallible step must happen before line 3648. A late failure can only be an
  in-band frame, never a status code.
- **`session::send` is dead here.** Daemon-hosted instances get no `Process`
  actor, so the guest's own event channel is a silent no-op
  (`api/session.rs:17`). The only way out is the HTTP response.
- **`launch_daemon`'s `input` is discarded** (`daemon.rs:238` binds
  `_input: String`) — the daemon path cannot even be parameterised.
- **Two decode loops.** Streaming (`:3503-4413`) and non-streaming
  (`:4414-5158`) are near-identical and can drift.
- **This entire path disappears** when pie removes `wasi:http` hosting.

---

## NEW — HTTP in the host, generation in the guest

```
Rational.app
  │  HTTPEngineClient.baseURLProvider          [UNCHANGED resolution path]
  │    ← EngineStatus.running(port:)  ← now the GATEWAY's port
  │        ← GatewaySupervisor.start() → /healthz probe → bound port
  ▼
POST /v1/chat/completions
  │
  ▼
ratio-gateway  (host-native Rust, axum)        OWNS: HTTP, SSE, ids, clock, status
  1. body cap, JSON parse, routing fields only (model/stream/stream_options)
  2. dispatch-shaped request? → 501 inferlet_not_implemented
  3. mint chatcmpl-id + created
  4. wrap body UNTOUCHED in RunInput { v, request_id, stream, request }
  5. one pie Client per request: connect → auth_by_token
  6. launch_process(chat@0.1.0, input, capture_outputs = true)   ← MANDATORY
  │
  │        ══ pie WebSocket control plane (no HTTP anywhere) ══
  ▼
chat.wasm   #[inferlet::main] async fn main(RunInput) -> Result<String>
  │  thin shell: deserialize, wire a SessionSink
  ▼
gen-core  (transport-independent)
  1. validate_sampling                          ← pre-commit, so 400 is possible
  2. fill_context → build_prompt_tokens         ← ported VERBATIM (parity)
  3. emit Event::Ready                          ← THE COMMIT SIGNAL
  4. decode loop: select(step.execute(), cancel_pollable)
  5. emit ContentDelta / ReasoningDelta per visible delta
  6. emit Finish, Usage; RETURN GenResult (neutral: no ids, no OpenAI shapes)
  │
  │  each event → Envelope { v, seq, e } → session::send   (sync, infallible)
  ▼
gateway driver task (owns the Process)
  • SeqChecker: a gap is a protocol error       ← session::send drops silently
  • holds Finish/Usage back; assembles ONE terminal sequence
  • select over: reserve() | proc.recv() | cancel   ← cancellation-safe
  ▼
OpenAiSse
  • render(Ready)    → {"event":"model_ready"} + role chunk   (1 event → 2 frames)
  • render(delta)    → chat.completion.chunk
  • terminal(finish, usage, metrics, error) →
        finish chunk → [usage chunk] → [generation_metrics] → usage meta → [DONE]
  ▼
SSE bytes — byte-identical to the old design (A/B verified at temperature=0)
```

### Deferred commit

The gateway does not open the SSE response until the guest reaches `Ready`:

```
launch_process → await first event
  ├─ Error{code}  → HTTP status from the code table. NO SSE opened.
  ├─ Ready        → 200 text/event-stream, stream from here
  └─ Warning      → buffered, keep waiting
```

Strictly better than the old membrane: a doomed request still gets a real status
code, because `Ready` fires after `fill_context` but before any forward pass.

### Cancellation (the reverse path)

```
client hangs up
  → axum drops the response body
    → CancelOnDrop fires a oneshot
      → driver's select wakes (NOT blocked on a full channel)
        → Process::signal {"c":{"t":"cancel"}}
          → guest's select: cancel pollable beats step.execute()
            → Outcome::Cancelled → Finish{reason:"cancelled"}
              → gateway terminate_process       ← ALWAYS, on every exit path
```

Measured at **0 ms** guest acknowledgement. `.get()` polling does not work here —
the host only completes the future when its pollable is actually polled, so the
forward pass must be *raced*, not interleaved with a poll.

### Non-streaming

Same guest loop, no second code path. The gateway discards the deltas and
serialises `GenResult` (arriving as `ProcessEvent::Return`) into a
`chat.completion`. That is what collapsed the old design's two loops — ~700
duplicated lines that could drift.

---

## The contrast in one table

| | old | new |
|---|---|---|
| HTTP listener | pie daemon (`wasi:http`) | ratio-gateway (axum) |
| Transport to the guest | HTTP request/response | WS control plane + `session::send` |
| Wasm instances | fresh per HTTP request | fresh per `launch_process` |
| ids / timestamps / statuses | inside wasm | gateway only |
| Request semantics + prompt | inside wasm | `gen-core` (still guest-side) |
| Commit point | `Emitter::start`, before generation | first guest event (`Ready`) |
| Late failure | in-band frame only | in-band frame, or a real status if pre-`Ready` |
| Cancellation | none (`tot` never aborts) | cooperative, then authoritative |
| Backpressure | none | cancellation + in-flight cap |
| Streaming vs buffered | two loops | one loop + a neutral return value |
| Survives pie's HTTP removal | **no** | yes |

## What deliberately did NOT change

The app's URL resolution path is identical — `HTTPEngineClient` still reads
`EngineStatus.running(port:)` over XPC. Only the *value* changes, from the
daemon's port to the gateway's. That is why no Swift client code needed
rewriting, and why the SSE bytes had to stay byte-compatible rather than merely
equivalent.
