# Gateway + single-purpose inferlets

**Status:** proposal, rev 2 · **Scope of slice 1:** `/v1/chat/completions` only

Rev 2 incorporates review feedback: the app-lifecycle assumption was wrong, the
host/wasm ownership boundary was self-contradictory, a PIE client transport race
was unaccounted for, the cancellation sketch did not compile, several protocol
rules conflicted, and phase 0 was not actually leaving the legacy component
frozen. All six are corrected below; §2.2, §2.5 and §11 changed most.

## 1. Context

Pie is removing its HTTP server and `wasi:http/incoming-handler` daemon hosting
(confirmed with the pie author). RatioThink's entire API surface lives *inside*
that mechanism: `Inferlets/chat-apc` is one wasm component exporting
`wasi:http/incoming-handler`, serving four endpoints from a single `match` in
`lib.rs:52-58`. When the daemon goes, that component cannot be reached at all.

The intended boundary:

```
RatioThink app
  → ratio-gateway          HTTP, SSE, IDs, timestamps, status codes
    → PIE WebSocket API    process lifecycle and cancellation
      → chat.wasm          request semantics and model interaction
        → gen-core         transport-independent generation
```

Each layer owns exactly one thing, and nothing below `ratio-gateway` knows what
HTTP is.

Tree of Thought, Best-of-N, speculative decoding and the prefix cache are
deferred, but the structure is chosen so they follow without a second rewrite.

## 2. Findings that shape the design

**2.1 — `session::send` is synchronous and infallible.**
`Vendor/pie/runtime/wit/core/wit/session.wit:6` is `send: func(message: string);`
— no return, no error. This deletes the `EmitError` / `try_emit!` /
`Disconnected` apparatus and removes `BranchSink`'s reason to exist:
`tot/stream.rs:100-106` justifies its async `Mutex` only because the frame write
`.await`s. With a sync sink, N concurrent branch futures share `&dyn EventSink`
with no lock and no lifetime gymnastics. The hardest part of the eventual ToT
carve-out is deleted by the transport change rather than worked around.

**2.2 — The app does NOT read `<PIE_HOME>/http.port`.** (Corrects rev 1.)
Production resolves the base URL through XPC, not the filesystem:

```
PieControlLauncher.launch → (httpPort, session)          PieControlLauncher.swift:715,911
  → PieEngineHost.runLaunch publishes EngineStatus.running(port:)   PieEngineHost.swift:755
    → EngineStatusStore.baseURL = http://127.0.0.1:<snapshot.port>  EngineStatusStore.swift:91
      → HTTPEngineClient.baseURLProvider (async closure)            HTTPEngineClient.swift:53
```

`HTTPEngineClient`'s own doc comment says the port "is only known after
`PieEngineHost` reports `EngineStatus.running(port:_)` over XPC."
`writePortFile` (`PieControlLauncher.swift:899,1218-1224`) exists for
`IsolatedTestCase`; grepping `Shared/` and `App/` finds **no reader** of it.

Consequence: rewriting `http.port` redirects test harnesses only. Bundling,
supervision, a readiness handshake, and gateway-port publication must all land
**before the production flip**, not in a final cleanup phase. Rev 1's claim that
"each phase leaves a shippable app" was false as sequenced; §11 fixes the order.

**2.3 — Nothing applies backpressure to a generating inferlet.**
`session::send` → `server::send_event` → `CLIENT_SERVICES.send`, and `ServiceMap`
uses an **unbounded** channel (`runtime/src/service.rs:105,236`). Downstream the
pie Rust client allocates `mpsc::channel(64)` per process (`client.rs:449`) and
`:616` sends into it from the *single* WS reader task while holding a `DashMap`
guard from `:604`. A stalled HTTP consumer makes pie buffer without bound while
the GPU runs flat out, and one slow stream can park the reader for every other
process on that connection. **Cancellation is the backpressure mechanism.**

**2.4 — `session::send` is API-infallible but not delivery-guaranteed.**
`runtime/src/api/session.rs:14-21`:

```rust
if let Ok(Some(client_id)) = process::get_client_id(inst_id).await {
    server::send_event(client_id, inst_id, &ProcessEvent::Message(message)).ok();
}
Ok(())
```

Both the missing-client case and a send failure are silently swallowed. The guest
cannot tell. Therefore the `seq` field in the envelope is **load-bearing, not
decorative**: the gateway must detect gaps and treat them as protocol failures.

**2.5 — There is an event-registration race in the PIE Rust client.** (New.)

```
handler.rs:471   process::spawn(...)          ← process starts emitting
handler.rs:~490  send_response(corr_id, ...)  ← response sent after
client.rs:441    send_msg_and_wait(msg)       ← client waits for that response
client.rs:451-2  process_event_tx.insert(...) ← channel registered only now
client.rs:604    if let Some(sender) = ...get(&process_id)   ← NO else branch
```

Events arriving in that window are **silently discarded**. Fast failures,
`Ready`, or even `Return` can disappear. The window is small on loopback, so a
slow `Ready` (after model load) usually survives — but a fast-failing inferlet is
reliably lossy, and this is exactly the path error handling depends on.

The Python client already buffers orphan events
(`client/python/src/pie_client/client.py:148-152`), which suggested the race was
known and live.

**MEASURED — it does not reproduce. Phase 1 gate, 2026-08-01.**
`Gateway/pie-conformance` against `Inferlets/echo` (which emits on its first
line, no model work), dummy driver:

| concurrency | launches | lossy runs | events lost | missing `return` | rate |
|---|---|---|---|---|---|
| 1 | 5,000 | 0 | 0 | 0 | 6,105/s |
| 8 | 4,000 | 0 | 0 | 0 | 10,589/s |
| 32 | 4,000 | 0 | 0 | 0 | 11,551/s |

**13,000 launches, zero loss.** The reason is a timing margin, not a guarantee:
*every* `ProcessEvent` requires the guest to be instantiated and running, so the
losing side of the race is `[wasm instantiation + first emit + network]`
(milliseconds) against `[oneshot resolve + DashMap insert]` (sub-microsecond) —
roughly a 1000× margin. There is no host-side event that can be emitted before
instantiation; spawn failures come back as a non-ok launch *response*, not as a
`ProcessEvent`.

**Decision: do not patch `Vendor/pie`, and do not carry a fork.** The window is
real but unreachable under any realistic workload. Instead, keep
`pie-conformance` as a permanent regression gate and re-run it on every
`Vendor/pie` submodule bump — if pie ever makes instantiation lazy or adds a
host-emitted pre-instantiation event, the margin collapses and this catches it.
This removes what was rev 2's largest risk and its upstream-dependency burden.

**2.6 — The daemon path is already second-class**, which makes this a good trade
rather than a forced march: `launch_daemon`'s `input` is silently discarded
(`daemon.rs:238` binds `_input: String`), and daemon-hosted instances get no
`Process` actor, so `session::send` from inside a daemon is a **no-op**
(`api/session.rs:17`).

## 3. Ownership boundary

Rev 1 was self-contradictory: it claimed the host owns the OpenAI wire contract,
*and* that `RunResult` carries an assembled OpenAI completion, *and* that the
host mints ids, *and* that `Event::ToolCall` carries an id. Those cannot all
hold. The rule now:

> **Nothing below `ratio-gateway` ever constructs an OpenAI object, an id, a
> timestamp, or an HTTP status.**

| concern | owner |
|---|---|
| HTTP, SSE framing, status codes, headers | `ratio-gateway` |
| `chatcmpl-*` ids, tool-call ids, `created` timestamps | `ratio-gateway` |
| OpenAI request schema + semantic validation | `gen-core` |
| Prompt construction, decode loop, sampling | `gen-core` |
| Process lifecycle, cancellation, timeouts | `ratio-gateway` via PIE WS |

**The gateway parses only what routing and transport need** — `model`, `stream`,
`stream_options`, and the routing field — and forwards the body otherwise
untouched. `gen-core` owns the rest of the schema. Rev 1 copied the full
validation surface into *both* the gateway and `gen-core`, which manufactures
precisely the drift this refactor exists to remove.

Consequence to accept knowingly: a semantically malformed request now costs a
process launch before it can 400. That is acceptable because of the deferred
commit (§7.2) — the gateway can still return a clean 400 — but it is a real
round trip, not free.

### 3.1 What wasm returns

```rust
/// Transport-neutral. No ids, no timestamps, no OpenAI shapes.
pub struct GenResult {
    pub content: String,
    pub reasoning: Option<String>,
    pub tool_calls: Vec<ToolCallDraft>,      // { name, arguments } — no id
    pub finish_reason: FinishReason,
    pub usage: Usage,
    pub diagnostics: Vec<Diagnostic>,
}
```

The gateway constructs both the SSE chunk sequence and the non-streaming OpenAI
body from this plus its own ids and clock.

**Explicit non-goal for slice 1:** streaming tool-call *deltas*. Tool calls are
reported once, on the terminal frame — which is what chat-apc already does
(`delta.tool_calls` rides the terminal chunk). Revisit only if a client needs
incremental arguments.

## 4. Target layout

`Inferlets/chat-apc/` stays **completely unmodified** — see §8.

```
Inferlets/Cargo.toml         [workspace] exclude = ["chat-apc"]
Inferlets/clippy.toml        cross-crate lint enforcement
├── ratio-wire/              pure serde: Event, EventSink, envelope, GenResult
├── ratio-names/             durable-name registry + store wrappers
├── gen-core/                request schema, validation, prompt, decode loop
├── echo/                    cdylib, ~30 lines — the phase-0 conformance target
├── chat/                    cdylib, ~130 lines over gen-core
└── chat-apc/                LEGACY, untouched, own Cargo.lock, excluded

Gateway/Cargo.toml           [workspace]
├── ratio-gateway/           bin: axum, SSE rendering, ids, statuses
└── pie-pool/                pie-client connection + process-driver tasks
```

`ratio-wire` and `ratio-names` compile for **both** host and `wasm32-wasip2`, so
they may depend only on `serde` / `serde_json`.

Not copied into the gateway (contrast rev 1): `validate.rs`. Validation lives in
`gen-core` only. The gateway copies just the **response/frame** shapes it
constructs — `sse.rs:132-235` (`ModelReady`, `SseWarning`, `SseError`,
`SseUsage`), `completions.rs:447-533` (chunk structs), `:535-569` + `:1343-1393`
(non-stream), `:649-670` (`GenerationMetricsSse`) — plus `sse.rs:338-362`
(`json_error`) adapted to `axum::response::Response`.

## 5. The event protocol

### 5.1 Vocabulary

`ratio-wire::Event` declares the **complete** vocabulary now, including ToT and
Best-of-N variants, even though slice 1 produces only the chat subset. Lift the
shapes from `tot/stream.rs:209-296` and `bestofn/stream.rs:36-48`. This is the
main anti-rewrite lever.

```rust
pub enum Event {
    // lifecycle
    Ready,
    Warning { code: String, message: String },
    Error   { code: String, message: String, param: Option<String> },   // no http_status
    Usage   { prompt_tokens: u32, completion_tokens: u32, context_window: Option<u32> },
    GenerationMetrics { output_tokens: usize, elapsed_s: f64, tokens_per_sec: f64 },
    Finish  { reason: FinishReason },
    // linear generation (slice 1)
    ContentDelta   { text: String },
    ReasoningDelta { text: String },
    // tree generation — defined now, produced in a later phase
    TreeStart { .. }, NodeStart { .. }, NodeDelta { .. }, NodeScoring { .. },
    NodeComplete { .. }, LevelPruned { .. }, TreeComplete { .. },
    AwaitingSelection { level: usize, candidates: Vec<Pick> },
    // forward compatibility
    Unknown(serde_json::Value),
}
```

`http_status` is gone from guest events (rev 1 had it). The gateway maps stable
guest error codes to statuses via one documented table — a new artifact that must
be maintained deliberately:

| guest code | status |
|---|---|
| `server_busy` | 503 + `Retry-After: 1` |
| `model_not_found` | 404 |
| `unsupported_role`, `tool_role_unsupported`, `invalid_request` | 400 |
| *(unmapped)* | 500 |

### 5.2 Unknown-tag decoding is not free

Rev 1 claimed unknown tags "trace and drop". **A derived internally-tagged serde
enum errors on an unknown tag** — it does not skip it. `#[serde(other)]` only
covers unit variants and is not available for internally-tagged enums with data.
Implement it explicitly: deserialize the envelope's `e` field to
`serde_json::Value`, attempt `Event`, and on failure yield
`Event::Unknown(value)`. Cover it with a test (§12, L3), because this silently
regresses if someone later "simplifies" the derive.

### 5.3 Envelope

Downstream over `session::send`, one single-line JSON object per call
(`serde_json::to_string` never emits a raw newline, so the message boundary *is*
the frame boundary):

```json
{"v":1,"seq":1,"e":{"t":"content_delta","text":"Hel"}}
```

Upstream over `signal_process` → `session::receive()`:

```json
{"v":1,"c":{"t":"cancel"}}
{"v":1,"c":{"t":"select","node_id":"bon-n3","action":"think_more"}}
```

Rules (rev 1's conflicted; these are consistent):

1. **Zero or more `Warning`s may precede exactly one `Ready`.** `Ready` is the
   commit signal, not literally the first frame.
2. **Pre-commit failures need no guest `Finish`.** A guest that fails before
   `Ready` may emit `Error` and return.
3. **After commit, the gateway guarantees exactly one externally visible terminal
   sequence** — synthesizing it if the guest crashes or returns without `Finish`.
   The guest-side "always emit `Finish`" obligation is replaced by a *gateway*
   obligation, which is the only one that can actually be honored.
4. `seq` must be gap-free; a gap is a protocol failure (§2.4).
5. **Unknown optional event tags are ignored** (§5.2).
6. **An unsupported major `v` fails closed** — the guest rejects it and the
   gateway surfaces a 500. Graceful degradation applies to *tags*, not versions.
7. Adding a variant or an optional field is additive, no `v` bump.

## 6. The transport abstraction

```rust
pub trait EventSink {
    /// Infallible by construction: session::send has no error channel.
    fn emit(&self, ev: Event);
    fn cancelled(&self) -> bool { false }
}
```

`&self`, not `&mut self` — that is what lets concurrent futures share one handle
with zero synchronization (`seq` behind a `Cell<u64>`, sound because the wasm
guest is a single cooperative stack). Implementations: `SessionSink` (wasm),
`VecSink` (host tests), `TeeSink` (A/B fan-out).

**Rendering lives in `ratio-wire`**, pure and testable with no engine and no GPU:

```rust
impl OpenAiSse {
    pub fn render(&mut self, ev: &Event) -> Vec<String>;   // `data:` payloads
    pub fn finish(&mut self) -> Vec<String>;
}
```

Ordering is the core's responsibility; framing and identity are the renderer's.

## 7. The wire contract the gateway must emit

From `HTTPEngineClient.swift:213-314` and `ChatEvent`
(`EngineClient.swift:616-641`). The app peeks the top-level `event` key
(`:542-548`) to demux meta-frames from chunks.

| # | Trigger | Bytes |
|---|---|---|
| 1 | `Warning` before `Ready` | `data: {"event":"warning","code":…,"message":…}` |
| 2 | `Ready` | `data: {"event":"model_ready"}` |
| 3 | after 2 | role chunk — `finish_reason` **omitted**, not null (`completions.rs:498-499`) |
| 4 | `ContentDelta` | chunk with `delta.content` |
| 4′ | `ReasoningDelta` | chunk with `delta.reasoning_content` |
| 5 | `Finish` | terminal chunk with `finish_reason`; `delta.tool_calls` rides it |
| 6 | + `include_usage` | extra chunk, `choices: []`, `usage` populated |
| 7 | buffered `Error` | `data: {"event":"error",…}` |
| 8 | tokens > 0 | `data: {"event":"generation_metrics",…}` |
| 9 | always | `data: {"event":"usage",…}` |
| 10 | always | `data: [DONE]` |

**Unknown `event` values are silently skipped by the app**
(`HTTPEngineClient.swift:268` is `default: continue`) — the escape hatch that
makes §5.1's "declare everything now" safe.

**Frames 8 and 9 are strict-decoded** (`:249-267`, `:702-738`):
`generation_metrics` throws unless all three values are finite and positive;
`usage` requires `total_tokens`. Subtle errors throw into the app rather than
degrading. Reuse `GenerationMetricsSse::build` (`completions.rs:657-670`), which
already returns `None` below threshold.

Keep `Sse::keep_alive` **off** so the byte stream stays diffable against
chat-apc; the app's idle timeout is 24 h (`:75`), so it buys nothing.

## 8. Gateway internals

### 8.1 Deferred commit

> **Do not open the SSE response until the first event arrives.**

```
launch_process → await first event
  ├─ Error{code}      → HTTP status from the §5.1 table. No SSE opened.
  ├─ Ready            → 200 text/event-stream; stream from here.
  ├─ Warning          → buffer, keep waiting.
  └─ ProcessEvent::Error / Return / timeout → 502/503/504 + stable code
```

`Ready` is emitted after `fill_context` succeeds (tokenizer only, no forward
pass), landing at the same lifecycle point where chat-apc emits `model_ready`
(`completions.rs:3690`) — which is what preserves byte parity.

Fields accepted but not yet honored (`speculation`, `cache`) get a
`Warning{code:"feature_unavailable"}`, **not** a 400 — the app sends them today
(`EngineClient.swift:331-336`) and 400ing would break Repeat Boost.

### 8.2 Connection model

One `Client` per request in v1: connect → `auth_by_token` → `launch_process` →
drain → drop. On loopback the handshake is sub-millisecond, and this sidesteps
head-of-line blocking (§2.3) by giving each stream its own WS reader. Keep one
long-lived **control** client for boot-time `add_program` and `query`, which
never carries process events. Pooling is a later optimization, justified only by
TTFT profiling.

### 8.3 The process-driver task

Rev 1's `CancelGuard` called `Client::signal`, which **does not exist** — `signal`
is on `Process` (`client.rs:88`, inside `impl Process` at `:81`; `impl Client`
starts at `:144`). It would not compile.

Instead, one task owns the `Process` and selects over four sources:

```
loop select:
  ev  = process.recv()          → decode envelope, check seq, forward downstream
  _   = http_body_cancelled     → cancel path (below)
  _   = timeout                 → cancel path, then 504 or terminal error frame
  _   = downstream_full         → bounded delivery: terminate, close
```

Cancel path, with a **grace period** — rev 1 sent cancel and terminated
immediately, giving the guest no chance to emit its claimed
`Finish{reason: Cancelled}`:

```
process.signal(r#"{"v":1,"c":{"t":"cancel"}}"#)      // cooperative
await Finish OR grace_deadline (~250ms)
client.terminate_process(pid)                        // authoritative
```

**Measured (phase 1): the guest acknowledges in under 1 ms**, so a 250 ms grace
is generous. `Process::signal` → `session::receive()` works.

**RESOLVED 2026-08-01 — and `.get()` polling is definitively not the answer.**

Rev 2 said the guest "polls it non-blockingly (`.get()`) each iteration". That
was measured wrong **twice**:

| attempt | result |
|---|---|
| `.get()` inside a `wstd::task::sleep` loop (phase 1) | never observed, 1000 ms budget |
| `.get()` once per decode step, right after `step.execute().await` (phase 5) | never observed; force-killed at the 250 ms grace |
| `FutureStringExt::wait_async()` — awaits the pollable | resolves in **<1 ms** |

The second attempt is the informative one: the plausible theory was that a real
forward-pass await yields to the host and lets the messaging task resolve the
future, so `.get()` would then see it. It does not. **The host only completes
the future when its pollable is actually polled** — no amount of awaiting
something *else* helps.

So the decode loop RACES the forward pass against the cancel pollable rather
than interleaving a poll with it:

```rust
let exec   = pin!(step.execute());
let cancel = pin!(AsyncPollable::new(cancel_signal.pollable()).wait_for());
match futures::future::select(exec, cancel).await {
    Either::Left((Ok(o), _))  => o,                       // forward pass won
    Either::Right(((), _))    => break (Outcome::Cancelled, None),
}
```

Two design consequences:

- **`gen-core` owns the cancel future, not the sink.** Racing needs the
  pollable, and that is a wasm-only type that cannot cross the host-portable
  `EventSink` trait. `EventSink::cancelled()` is now vestigial for chat.
- **`session::receive()` is called ONCE.** Each call mints a fresh consumer of
  the same per-process topic, so a per-iteration call would race several
  consumers for one message.

`Outcome::Cancelled` was added so a disconnect reports `finish_reason:
"cancelled"` rather than being misattributed as `"error"` — nothing failed.

**Measured:** long generation, client killed 4 s in →
`guest_stopped=true, latency_ms=0`, versus `guest_stopped=false, latency_ms=253`
(force-kill) before the fix. A/B still 4/4, 33 tests green.

**Dropping the `Client` alone is not enough** — `Session::cleanup` calls
`process::detach`, not terminate (`runtime/src/server.rs:400-403`), so the
process keeps burning GPU to completion. Explicit termination is mandatory. This
also structurally fixes the defect where `tot/` never aborts on disconnect
(`grep -rn Disconnected tot/` returns zero hits).

### 8.4 Launch flags and boot gotchas

`launch_process(program, input, capture_outputs=true, None)`.
**`capture_outputs=true` is mandatory** — with `false` the runtime sets
`client_id=None` (`handler.rs:471`) and every `session::send` is silently
dropped. Never use `run_processes`; it hardcodes `client_id=None`
(`handler.rs:573-655`) and can never stream.

- The pie handshake banner goes to **stderr**, not stdout
  (`server/src/serve.rs:410-415,159` are `eprintln!`).
  `PieControlLauncher.swift:186` has the correct regex to mirror.
- `internal token:` prints **only** with `--debug` (`serve_cmd.rs:66-67`).
  Without it the dev-spawn hangs on handshake with no diagnostic.
- `add_program` once at **boot** — `program::add` is global (`handler.rs:409`)
  and each session caches `installed_programs` (`handler.rs:465-473`).
- `runtime::models()` is wasm-only. Host-side the model list comes from
  `query("model_status")`, keys `"<model>.kv_pages_total"` (`handler.rs:53-66`);
  `KVUsageSnapshot.swift:70-71` already does this suffix-strip. Add a `--model`
  override as the escape hatch.

## 9. Legacy component: genuinely frozen

Rev 1 said `chat-apc` was untouched and then had phase 0 make it depend on
`ratio-names` and delete its local `snapshot_names.rs`. That rebuilds the
baseline and destroys its value as an oracle.

**`Inferlets/chat-apc/` is not modified at any point.** It keeps its own
`Cargo.lock`, its own `snapshot_names.rs`, its own canary, and its committed
`prebuilt/chat-apc.wasm` + stamp. Namespace enforcement (§10) goes only into the
new crates. Both wasms can be installed simultaneously — distinct programs
sharing one snapshot namespace, which is safe precisely because both honor the
same declared prefixes and policies.

Bug fixes during the overlap go to `gen-core` only; the env-var flag is the
rollback.

## 10. Durable names — three enforcement layers

The host keys snapshots `(username, name)` (`context.rs:1355`) and blobs the same
(`blob_store.rs:28-32`), with **no** program component, and `auth_by_token` pins
every program to `username="internal"` (`server.rs:576`). (`metadata-put` *is*
program-scoped — `metadata_store.rs:20-43` — and is the one store nothing needs.)

1. **Type-level** — opaque `SnapshotName`, constructible only via
   `apc_prefix(...)` / `bon_candidate(request_id, level, idx)`. The `RequestId`
   is minted by the long-lived gateway, structurally removing the `bon/bon-0/…`
   collision (today `ID_COUNTER` at `bestofn/mod.rs:94` restarts every request,
   so *every* round reuses the same names).
2. **Policy-level** — `ratio_names::store::{save,delete,blob_save}` are the only
   writers; the collision-policy match happens once, inside `save`.
3. **Lint-level** — `Inferlets/clippy.toml` `disallowed-methods` bans raw
   `Context::save`/`delete`/`open` across the new workspace, plus a canary in
   `ratio-names/tests/` scanning sibling crates and `Gateway/`. Scope it to the
   new crates only; `chat-apc` keeps its own.

Register the undeclared third namespace too: blob names
`chat-apc/cacheback/v1/{hash}` (`chat/spec/sidecar.rs:53`), sharing a per-user
cap (`blob_store.rs:162-179`).

## 11. Sequencing

Replaces rev 1's proxy-first plan. The ordering front-loads the two integration
risks that rev 1 treated as settled: the PIE transport race (§2.5) and the app
lifecycle (§2.2).

| # | Phase | Exit criterion |
|---|---|---|
| 1 | ~~**PIE transport conformance.**~~ **DONE 2026-08-01.** `Inferlets/echo` + `Gateway/pie-conformance` built; race measured as unreachable (§2.5), cancellation verified <1 ms. No pie patch needed. | ✅ 13,000 launches at concurrency 1/8/32, zero loss; cancel acknowledged |
| 2 | ~~**Gateway skeleton, direct to PIE.**~~ **DONE 2026-08-01.** `ratio-gateway` with engine spawn/attach, `/healthz`, `POST /v1/echo`, deferred commit, process-driver task, cancel→grace→terminate, seq-gap detection. | ✅ see below |
| 3 | ~~**Neutral protocol + golden renderer.**~~ **DONE 2026-08-01.** `Inferlets/ratio-wire` (Event, envelope, GenResult, EventSink, OpenAiSse); fixtures captured live from chat-apc + Qwen2.5-7B. Gateway rewired onto the shared crate. | ✅ 11/11 tests; byte-exact on all three captures |
| 4 | ~~**Minimal `chat.wasm` + `gen-core`.**~~ **DONE 2026-08-01.** `gen-core` (schema/prompt/demux/unified loop) + `chat.wasm` (301 KB) + gateway `/v1/chat/completions`. | ✅ A/B 5/5 identical at `temperature=0`; 18/18 host tests |
| 5 | **Launcher, bundle, supervision, A/B fallback.** **CODE DONE 2026-08-01**, GUI verification blocked — see below. `GatewaySupervisor`, `Scripts/build-gateway.sh`, entitlements, `project.yml` staging, launcher wiring behind `RATIO_CHAT_BACKEND`. | ⚠️ partial — bundling + attach mode verified; GUI e2e blocked by code signing |
| 6 | **Prefix cache, speculation, ToT, Best-of-N.** Fold the first two into `gen-core`; `tot-core` + `tot`; `bestofn` as a long-lived interactive process. **Moved ahead of the flip** — see §2 sequencing below. | Every route the app calls is implemented; operator harnesses green |
| 7 | **Production flip.** Default to the inferlet path; chat-apc reachable via flag for one release. | Load + cancellation gates green; GUI e2e green on a signing machine |
| 8 | **Delete `chat-apc`** — only after every live route has migrated. | — |

Phases 1-3 need no GPU. Phase 5 is the one rev 1 got badly wrong by deferring to
the end; it is a prerequisite for the flip, not cleanup.

### Phase 2 results (2026-08-01)

`Gateway/ratio-gateway`, dev-spawn mode against the dummy driver. Engine boot to
serving: **2 s**.

| check | result |
|---|---|
| `GET /healthz` | `{"status":"ok"}`, no engine round trip |
| `POST /v1/echo` → SSE | all frames + `[DONE]`; `text/event-stream`, `cache-control: no-cache`, chunked |
| **Deferred commit** — guest fails fast | **HTTP 502 `application/json`** with the OpenAI error envelope; **no SSE opened** |
| **Cancellation** — client killed 3 s into a 30 s hold | `guest_acked=true` in **0 ms**, then `terminate_process`; process did not run on |
| 40 concurrent SSE streams | **40/40 complete**, 48 ms wall, zero errors |
| `proto` unit tests | 4/4 — in-order, gap detected, unsupported `v` fails closed, unknown tag tolerated |

The one-`Client`-per-request policy (§8.2) held cleanly at 40 concurrent; no
sign of the head-of-line problem, as expected since each stream gets its own
reader task.

Structure that phases 3-4 inherit unchanged: `engine.rs` (spawn parses the
handshake off **stderr**, requires `--debug`; attach mode for production) and
`routes.rs`'s driver task. Phase 3 replaces the passthrough body with the OpenAI
renderer; the membrane, the driver and the cancel path do not move.

### Phase 3 results (2026-08-01)

`Inferlets/ratio-wire` — pure serde, builds for **both** host and
`wasm32-wasip2`. 11/11 tests green. The gateway's local `proto.rs` was deleted
and it now depends on the shared crate, so there is exactly one envelope
implementation.

**Fixtures are real.** `tests/fixtures/{chat_stream,tot_stream,bestofn_stream}.sse`
were captured from the running `chat-apc` daemon serving Qwen2.5-7B — not
hand-written. Golden tests rebuild the `Event` sequence each represents, render
it, and assert byte equality.

**Capturing before designing paid for itself immediately.** Four shapes were
wrong in the rev-2 design, and only the fixtures revealed them:

| assumed | actual |
|---|---|
| `NodeDelta { channel }` | wire key is `kind` |
| `NodeComplete { id, score, status }` flat | nests a `node` object |
| `score: f64` → renders `7.0` | **`Option<u8>` → renders `7`** (byte-different; caught by the golden test, confirmed at `tot/tree.rs:60`) |
| — | **`final_delta` event did not exist in the design at all** (synthesis streaming) |

`NodeView` was also missing `reasoning` / `error` / `score_error`, all
`skip_serializing_if`, so a clean capture never shows them —
`tot/stream.rs:172-188` has the authoritative field list and order.

**Two ownership decisions confirmed against the wire.** `tree_start` carries
`"id":"tot-0"`/`"bon-0"` and `"model"`, but both are gateway-owned, so
`Event::TreeStart` carries neither and the renderer injects them. That is the
structural fix for the `bon-0` collision: a per-request wasm instance restarts
its counter, so a guest can never mint a unique tree id.

Best-of-N's wire is confirmed to be **ToT's frames verbatim** plus
`awaiting_selection`, which is why `tot-core` as a shared library (phase 7) is
the right shape rather than two independent inferlets.

### Phase 4 results (2026-08-01)

Real generation through the new stack: `gateway → chat.wasm → gen-core`, against
Qwen2.5-7B on Metal, with `chat-apc` running beside it as the oracle.

**A/B at `temperature=0`, 5 prompts: content byte-identical AND frame ordering
identical on all five.** Non-streaming likewise — same text, same
`finish_reason`, same token counts (13/7/20).

| check | result |
|---|---|
| `gen-core` host tests | 18/18 (schema, demux, role policy) |
| A/B streaming | 5/5 content + frame-kind identical |
| A/B non-streaming | identical text, finish_reason, usage |
| unknown role / unknown model / bad JSON | 400 / 404 / 400, all clean JSON, no SSE opened |
| deferred-feature warning | `feature_unavailable` frame precedes `model_ready` |

**One real bug, caught only by the A/B.** The first run had identical content but
`usage` and `generation_metrics` **transposed**: chat-apc emits metrics *then*
usage. The cause is structural — the guest emits usage last because it cannot
know elapsed time (the gateway owns the clock), so the gateway now holds the
usage frame back and re-emits it after the synthesized metrics. Content parity
alone would have passed; only asserting frame *order* caught it, which is why
§12 lists ordering as part of the contract.

**Ownership calls made while porting:**

- **The gateway owns the clock.** `generation_metrics` is computed host-side
  from `Ready`→end, so `gen-core` needs no `Instant` and therefore no `wstd`,
  which is what keeps it host-testable.
- **No local token accumulator.** `stream.tokens_generated()` is authoritative
  for both the `length` cutoff and the usage block; a second counter can
  diverge and flip `length` into `stop`.

Parity landmines preserved verbatim, each commented in place: the
`out.is_empty()` → `first_user` vs `user` BOS branch; multi-part content joined
with **no separator**; `was_in_reasoning` snapshotted *before* `reason_dec.feed`;
starvation checked on `raw().slots` not `out.tokens`; `chat::Event::Done(_)`
payload discarded; the `!visible.is_empty()` guard; `prompt_tokens` read before
the generator runs.

**Known gaps in this slice** (deliberate, not defects): no tools, no JSON mode,
no prefix cache, no speculation, and `CueMode::Thinking` falls back to the
generic cue pending the Gemma channel-marker probe. Also `usage` omits
`prompt_tokens_details.cached_tokens`, which only becomes meaningful when the
prefix cache returns.

### Phase 5 results (2026-08-01) — partial, and honestly so

Shipped: `Shared/Engine/GatewaySupervisor.swift` (spawn, `/healthz` readiness
probe, SIGTERM→SIGKILL teardown, `ChatBackend` env switch),
`Scripts/build-gateway.sh` + `Scripts/ratio-gateway.entitlements`, a
`Build ratio-gateway` **postCompileScript** in `project.yml`, and the
`PieControlLauncher.launch` wiring that returns the *gateway's* port when
`RATIO_CHAT_BACKEND=gateway`.

| check | result |
|---|---|
| Swift compiles with the wiring | ✅ `** BUILD SUCCEEDED **` |
| gateway staged into `Rational.app` | ✅ 6.3 MB binary + `chat.wasm` (301 KB) + `echo.wasm` + manifests |
| entitlements | ✅ **network client/server only** — no JIT, deliberately narrower than `pie-engine.entitlements` |
| signature | ✅ `adhoc,runtime` (hardened) |
| **attach mode, bundled binary + bundled wasm** | ✅ engine → gateway on an ephemeral port → `"The capital of France is Paris."` |
| A/B switch defaults | ✅ unset / empty / garbage / `daemon` → `.daemon`; `gateway` / `GATEWAY` → `.gateway` |

**Design note.** Attach mode is what the supervisor uses: `pie serve` is already
owned by `PieControlLauncher`, so the gateway is handed the existing control
address and token from the launch handshake rather than spawning its own engine.
The supervisor is adopted by `LaunchedSession`, so engine teardown stops the
gateway too — an orphan would hold a loopback listener and fight the next launch
for the port.

**What is NOT verified, and why.**

- **GUI end-to-end.** `SMAppService` refuses an unsigned/ad-hoc agent, so the
  helper cannot register on this machine and the app's XPC path cannot be
  exercised. Closing this needs a free Apple ID in Xcode → Settings → Accounts;
  it is an environment gap, not a code gap.
- **`make test-app-unit`.** Fails with *"Failed to establish communication with
  the test runner… `com.apple.testmanagerd.control` was invalidated"* and
  **0 test cases executed** — a headless-environment failure, not a regression
  signal. The launcher edit is compile-verified and gated so the default path is
  unchanged, but it has not been exercised by the app-tier suite.

Phase 6 (the production flip) should not happen until both of those are green on
a machine that can sign.

### Review round 2 — fixes applied 2026-08-01

Nine findings, all reproduced against the code. Fixed:

| # | finding | fix |
|---|---|---|
| 1 | helper read gateway assets from `Bundle.main` (the *helper* bundle) | `InferletResources.gateway()` reuses the existing nested-bundle walk |
| 3 | `tx.send().await` inside a select arm blocked cancellation; lost receiver skipped `terminate_process` | driver uses cancellation-safe `reserve()`; **every** exit path terminates |
| 4 | post-commit faults became clean truncated streams; buffered path returned 200 despite an abort | `Frame::Terminal` guarantees exactly one finish; buffered gives error precedence over result |
| 6 | `decode_event` conflated unknown tags with malformed known ones | `KNOWN_TAGS` check → malformed known tag is `ProtocolError::Malformed` |
| 7 | no sampling validation; no `server_busy`; no `Retry-After` | `validate_sampling` ported (pre-commit), `classify_engine_error`, `Retry-After: 1` on 503 |
| 8 | `include_usage` chunk emitted after the meta-frames | `OpenAiSse::terminal()` owns the whole terminal sequence in one order |
| 9 | build phase declared one output → stale wasm could ship | every staged artifact is an output; Rust sources are inputs |
| 2 | `/v1/models` missing | added, via `query("model_status")` with a `--model` override |

**§2 sequencing — FIXED 2026-08-01.**

Two halves, and they interact: skipping the daemon leaves nothing to proxy *to*,
so "proxy unported routes" and "make gateway mode standalone" are mutually
exclusive. Chose standalone, because a proxy to `launch_daemon` would be built on
the very mechanism pie is removing.

1. **Dependency inverted.** `launch_daemon` and the chat-apc `installProgram`
   are now gated on `backend == .daemon`. In gateway mode the app's HTTP surface
   is the gateway alone, driving pie over the WebSocket control plane — so the
   path can actually run post-HTTP-removal, which it could not before.
2. **Unported routes fail honestly.** The app calls exactly three engine paths
   (verified by grep): `/v1/chat/completions`, `/v1/inferlet`, `/v1/models`.
   `/v1/models` is implemented; `/v1/inferlet` and dispatch-shaped chat requests
   now return **501 `inferlet_not_implemented`** naming the inferlet and the
   fallback backend.

   The second one mattered most: a `{"inferlet":"tree-of-thought"}` body used to
   deserialize as a plain `ChatRequest`, silently discarding the advanced
   envelope and answering as if the profile had never been selected. That is a
   *wrong answer*, not an error — far worse than a 501.
3. **Phase order corrected.** The flip is now phase 7, after the advanced
   inferlets land. `RATIO_CHAT_BACKEND=gateway` is usable today for chat-only
   work; it must not become the default while ToT / Best-of-N still 501.

Verified: all four app-facing behaviors correct (models 200, chat 200,
`/v1/inferlet` 501, dispatch-shaped chat 501), A/B still 4/4, suites green.

**Still open, and they gate the flip:**
- ~~**§5 supervision after readiness**~~ — **FIXED 2026-08-01.**
  `GatewaySupervisor` now remembers its bound port and exposes `health()`
  (process check, then a real `/healthz` round trip — a wedged gateway can still
  be "running"). `LaunchedSession.checkLiveness()` consults it as a third
  signal, **before** the engine WS ping: if the gateway is gone the app cannot
  reach anything, so the engine's health is moot and the existing restart ladder
  should fire on the real cause.

  Verified by driving the real `GatewaySupervisor` against the real bundled
  binary and a live engine, then `kill -9`-ing the gateway:

  ```
  ✅ start() returns a bound port: port 64777
  ✅ health() == nil while running
  ✅ health() reports a reason after a crash: gateway process exited (code 9)
  ✅ port is genuinely dead
  ```

  The third line is the regression that previously went undetected. Note this
  exercises `GatewaySupervisor` directly (it imports only Foundation, so it
  compiles standalone); the `checkLiveness()` wiring itself is compile-verified
  but still needs the app-tier suite on a signing machine.
- **§5 env var crosses a process boundary** — `RATIO_CHAT_BACKEND` is read in the
  launchd-managed helper, not the app, so an app-side `launchEnvironment` will
  not reach it. Needs `launchctl setenv` or carrying the choice through the XPC
  start request.

## 12. Verification

**L0 — transport conformance (phase 1, gating).** Loop `launch_process` against
an `echo` inferlet that emits and exits immediately; assert every `Ready` /
`Return` / `Error` is observed. Separately assert a cancel mid-stream yields a
guest-emitted `Finish{Cancelled}` before termination. Without this, everything
downstream is built on a lossy channel.

**L1 — mapper golden test (no engine, milliseconds).** Feed a hand-built
`Vec<Event>` through the renderer and assert exact bytes, seeded from captured
chat-apc streams. Cases: happy path, reasoning-then-content, error mid-stream,
guest crash with no `Finish` (gateway must synthesize a terminal),
`include_usage`, zero-token completion (`generation_metrics` absent). **Capture
ToT/Best-of-N fixtures here too**, before those planes are ported.

**L2 — validation tests**, ported once into `gen-core` (not duplicated).

**L3 — forward compatibility.** Unknown tag → `Event::Unknown`; unknown optional
field → ignored; unsupported major `v` → **fails closed**. Guards §5.2 against a
future "simplification" of the derive.

**L4 — seq-gap detection.** Inject a dropped event; assert the gateway raises a
protocol failure rather than emitting a silently truncated stream.

**L5 — A/B byte diff**, `temperature=0`, speculation off:

```bash
norm() { sed -E 's/"id":"chatcmpl-[^"]*"/"id":"ID"/; s/"created":[0-9]+/"created":0/;
                 s/"elapsed_s":[0-9.]+/"elapsed_s":0/; s/"tokens_per_sec":[0-9.]+/"tokens_per_sec":0/' "$1"; }
diff <(norm /tmp/apc.sse) <(norm /tmp/gw.sse)
```

Greedy decode plus a verbatim `build_prompt_tokens` port means the token sequence
must be **identical**. Divergence means the prompt copy drifted — the bug this
test exists to catch. A `--dump-prompt-tokens` flag on both sides gives a direct
token diff.

**L6 — the app's own client.** `Sources/api-probe/main.swift` drives
`HTTPEngineClient.chatCompletion` — the exact path Rational.app uses — against
any base URL:

```bash
PIE_TEST_API_BASE_URL=http://127.0.0.1:8100 PIE_TEST_API_EXPECT=Paris swift run api-probe
```

Then a manual GUI session: indicator flip (`model_ready`), progressive text
(deltas + real flushing), thinking panel (`reasoning_content`), context meter
(strict-decoded `usage`).

**L7 — load (phase 6).** `make test-e2e-harsh-load` at N=8 concurrent; the gate
for unbounded buffering and HOL blocking.

**L8 — cancellation.** Kill a `curl -N` mid-generation; confirm termination in
the pie log, not a run to completion.

## 13. Risks, ranked

1. **Gateway lifecycle in the app (§2.2)** — bundling, supervision, readiness,
   port publication, codesign. Rev 1 deferred this to the end and was wrong.
   Now the top risk, since the transport risk was retired empirically.
3. **Unbounded buffering + HOL blocking (§2.3)** — contained by one-client-per-request
   plus aggressive cancellation and an in-flight cap. Load-test in phase 6.
4. **`Event` enum churn after ship** — mitigated by declaring all tree variants
   in phase 3 and locking them with fixtures before ToT is ported.
5. **Prompt-building parity** — a one-token drift breaks reply parity and, once
   the cache returns, poisons snapshot keys. L5 is the only detector.
6. **Per-request instantiation cost** — measure in phase 4 (`instantiate_us` is
   instrumented at `process.rs:476`) against the ~103 ms TTFT recorded for
   chat-apc. If material, a warm-process pool; the protocol already supports it,
   since a process outliving one request is what Best-of-N needs.
7. **Shared `(username,name)` namespace** — mitigated by §10. Residual: a
   third-party inferlet could still collide. Escape hatch is real per-user auth
   (`auth.rs:140-163`); document, don't build.
8. **Error-code→status table drift** — the price of removing `http_status` from
   guest events. Keep the table in one file with a test enumerating every code
   `gen-core` can emit.

### Client API notes found in phase 1

Small, real, and each would have cost an hour:

- **`pie-client` does not re-export at the crate root.** `lib.rs` is just
  `pub mod client; …`, so it is `pie_client::client::{Client, Process, ProcessEvent}`.
- **`Client::close()` never returns** — it awaits a shutdown the reader task does
  not complete. The gateway must drop the client or exit rather than await close;
  the engine reclaims the session via `Session::cleanup`
  (`runtime/src/server.rs:400`).
- **`add_program` takes `&Path`**, not `&str`.
- **Input encoding differs by client.** The Rust client takes the input as an
  already-serialized JSON *string*; the Python client serializes for you, so
  passing `json.dumps(...)` there double-encodes and the guest fails with
  `invalid type: string`.
- **`signal` is on `Process`, not `Client`** (`client.rs:88` inside
  `impl Process` at `:81`; `impl Client` starts at `:144`) — as flagged in
  review, and confirmed by the compiler.

## 14. Open questions

- **Confirm with the pie author:** is `pie:core/session` (`send`/`receive`) plus
  `launch_process(capture_outputs=true)` stable through the HTTP removal? The
  design rests on it; the only fallback is stdout scraping. Keep `SessionSink` a
  ~30-line file with one call site so a swap is a one-file change. Also raise the
  §2.5 race — a fix upstream is better than a carried patch.
- ~~Does the gateway become a separate supervised process or a linked library?~~
  **Decided: a supervised sibling process.** `ratio-gateway` stays a `bin`. The
  helper spawns and supervises it alongside `pie serve`, and publishes the
  gateway's port through `EngineStatus.running` (§2.2). No C ABI, no `lib`
  façade.
- `runtime::max-output-tokens()` is wasm-only, so the gateway cannot compute
  chat-apc's memory-aware ceiling (`completions.rs:138-144`) pre-commit. Clamp in
  the inferlet and emit a `Warning`, or have the gateway read the limit from
  config — open for production mode, where the app owns the config.
