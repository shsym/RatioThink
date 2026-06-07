# RatioThink Architecture

RatioThink is a native macOS app that runs the [Pie](https://github.com/pie-project/pie)
inference engine locally and talks to it like any OpenAI-compatible server — except the
server lives on your own machine. A SwiftUI app gives you chat, models, and settings; a
small menu-bar **helper** keeps the engine alive in the background; the **pie engine**
loads the model and runs inference; and a single WebAssembly **inferlet** (`chat-apc`)
turns pie into an OpenAI-style HTTP API.

There is also an interactive companion to this document: open
[`architecture.html`](architecture.html) directly in a browser (no server needed).

```
┌──────────────────────────────────────────────────────────────────────┐
│  RatioThink.app  (SwiftUI front end)                                   │
│  chat · models · profiles · settings · status surfaces                 │
└───────────────┬──────────────────────────────────┬─────────────────────┘
                │ XPC                                │ HTTP + SSE
                │ (control: status, start/stop,      │ (data: chat,
                │  download, profiles)               │  models — loopback)
                ▼                                    │
┌──────────────────────────────────┐                │
│  RatioThinkHelper  (menu-bar)     │                │
│  owns the engine process,         │                │
│  profiles, downloads              │                │
└───────────────┬───────────────────┘               │
                │ launch + WebSocket control          │
                │ (spawn pie, install inferlet)       │
                ▼                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│  pie engine  (`pie serve`)                                             │
│  loads the model at boot · hosts WASM inferlets · WS control plane     │
│   └── chat-apc inferlet (wasm): OpenAI HTTP API — data + control plane │
└──────────────────────────────────────────────────────────────────────┘
```

The four layers, top down:

| Layer | Bundle / location | Responsibility |
|-------|-------------------|----------------|
| **Front-end app** | `App/` → `RatioThink.app` | All UI and user actions: chat, model picker, profiles, settings, engine/model status surfaces. |
| **Background helper** | `Helper/` → `RatioThinkHelper` | Privileged-of-its-own background agent. Owns the engine process lifecycle, the on-disk profiles, and model downloads. Survives app restarts. |
| **pie engine / runtime** | `Vendor/pie/` (`pie serve`) | Loads the model, runs the forward pass, hosts WASM inferlets next to the KV cache, and exposes a WebSocket control plane. |
| **chat-apc inferlet** | `Inferlets/chat-apc/` (Rust → wasm) | The one inferlet RatioThink ships. Serves the OpenAI-compatible HTTP API — **both** the chat data plane and the model/health control endpoints. |

Most of the cross-cutting code (the XPC contract, the engine clients, model
resolution, persistence) lives in a shared Swift library, **RatioThinkCore**
(`Shared/`), linked into both the app and the helper.

---

## How the modules talk

### App ↔ Helper — XPC (control plane)

The app drives the helper over an `NSXPCConnection` to the mach service
`com.ratiothink.helper`. The contract is the `@objc(PieHelperXPC)` protocol
(`Shared/XPC/PieHelperXPC.swift`). Every Codable payload (`EngineStatus`,
`EngineError`, handles, profiles-as-TOML) crosses the wire as a `Data` blob
encoded by `XPCPayload` — frozen JSON (`sortedKeys`, ISO-8601 dates, base64).
Only `Data`, `String`, and `FileHandle` traverse the connection natively.

Key calls (every method has a reply block with an error channel — no silent
fire-and-forget):

| Call | Purpose |
|------|---------|
| `engineStatus()` | Returns the current `EngineStatus`. The app **polls** this (~1 Hz); there is no push channel. |
| `startEngine(profileID:)` / `stopEngine()` | Bring the engine up for a profile / shut it down. Helper boot leaves the engine stopped; the app/user launch prompt, explicit restart, and post-download recovery paths invoke `startEngine(profileID:)`. |
| `loadModel` / `cancelLoad` | Model-load handles (forward-compat stubs in v1 — see invariants). |
| `downloadModel(repo:file:)` / `cancelDownload` | Fetch a model into the local cache. |
| `listProfiles()` / `reloadProfiles()` | Read/refresh the on-disk TOML profiles. |
| `tailLog(stream:)` | Hand back a `FileHandle` to a log stream. |

The helper is registered as a launchd **agent** (via `SMAppService`), not a plain
login item, so its `MachServices` entry lets launchd respawn it on demand when the
app reconnects. `EngineStatus` models `.stopped`, `.starting`,
`.running(port:profileID:)`, `.stopping`, and `.failed(code:message:)`.

### Helper ↔ pie — process launch + WebSocket control

The helper owns the engine through `PieEngineHost`, which uses
`PieControlLauncher` to bring an engine up. One launch (`PieControlLauncher.swift`):

1. Reserve a free loopback port (`bind(127.0.0.1:0)`) to hand to the inferlet.
2. Spawn `pie serve --config <config.toml> --no-auth --debug`, with
   `PIE_HOME` and `PIE_SHMEM_NAME` in the environment.
3. Parse the engine's stdout for `pie-server serving on <host>:<port>` and
   `internal token: <token>` (both must appear within the handshake timeout).
4. Open a WebSocket to `ws://<host>:<port>` and run the MessagePack control RPC:
   `auth_by_token` → `install_program(wasm, manifest)` → `launch_daemon("chat-apc@0.1.0", <port>)`.
5. The inferlet's HTTP listener is now bound on the reserved port; the app reaches it there.
6. Teardown: `SIGINT` → 10 s grace → `SIGKILL`, then `shm_unlink` so the shared-memory region never leaks.

The model is chosen by the active **profile** and written into `config.toml` as
`[[model]] name = … / hf_repo = …`, so **the model loads at `pie serve` boot**, not
through a later API call. Models resolve either from an app-staged path or from the
local Hugging Face cache (`LaunchSpecResolver`, `HFCacheResolver`).

### App ↔ engine — loopback HTTP + SSE (data plane)

Chat does **not** go through the helper. The app talks straight to the engine on
`127.0.0.1:<port>` (the port comes from `EngineStatus.running(port:)`), using the
OpenAI-compatible HTTP surface (`HTTPEngineClient`):

| Endpoint | Shape |
|----------|-------|
| `GET /healthz` | `{"status":"ok"}` liveness. |
| `GET /v1/models` | `{"object":"list","data":[{id,object,owned_by}]}`. |
| `POST /v1/chat/completions` | **SSE** stream: a `{"event":"model_ready"}` meta-frame, then OpenAI `chat.completion.chunk` deltas, ending in `data: [DONE]`. |
| `POST /v1/models/load` | SSE: `model_ready` + `[DONE]` (instant — see invariants). |
| `POST /v1/inferlet` | Raw inferlet dispatch (v1 routes only `chat-apc`). |

Streaming is consumed with `URLSession.bytes(for:)`, so cancelling the consumer
cancels the network task. Tokens land in the UI via `ChatSendController` →
`MessageStreamWriter`, which buffers deltas and flushes them into SwiftData; the
transcript view observes the message and scrolls.

### Inside the inferlet — chat-apc request/response

`chat-apc` is one wasm component exporting `wasi:http/incoming-handler`. pie binds
its HTTP listener and routes each request to it (`Inferlets/chat-apc/src/lib.rs`):

| Method + path | Handler | Role |
|---------------|---------|------|
| `GET /healthz` | `control::health` | Liveness. |
| `GET /v1/models` | `control::models` | List the model registered at boot. |
| `POST /v1/chat/completions` | `chat::completions` | Generate; stream OpenAI SSE chunks. |
| `POST /v1/inferlet` | `chat::dispatch` | Raw dispatch (v1: chat-apc only). |
| `POST` / `DELETE /v1/models/load` | `control::load` | Confirm load / no-op cancel. |

"APC" is **A**daptive **P**ersonality/**C**apability: the chat loop runs decoder
wrappers (`chat/apc.rs`) alongside the base decoder. The reasoning decoder emits
`reasoning_content` deltas for `<think>` blocks. The tool-use decoder is fully
implemented — it emits OpenAI `tool_calls` (with `finish_reason: "tool_calls"`)
whenever a request supplies a `tools` array — but the v1 RatioThink app never
sends `tools`, so it stays dormant in the shipping product (OpenAI client-side
tool-call model). The control plane is a thin
registry view — because the model is already loaded at boot, `/v1/models/load`
just confirms the model and emits `model_ready`.

---

## Two end-to-end flows

**Cold start.** The helper boots as a launchd agent, publishes its XPC/menu-bar
state, and leaves the engine `.stopped`; boot model-load is disabled. The app discovers
that state by polling `engineStatus()` at ~1 Hz after reconciling helper registration
(re-registering via `SMAppService` if the mach service is unreachable). The launch
prompt/user-confirm path, explicit Restart, Local API start, and post-download recovery
paths can then invoke `startEngine(profileID:)`. `HelperExportedAPI` resolves the profile
and `PieEngineHost.startOrAttach` starts the engine or attaches same-profile requests;
once `.running(port:)` appears, the app resolves the HTTP base URL. `EngineStatusStore`
swallows only App-side reply timeouts because the start remains in flight, while any
helper `.alreadyRunning` that reaches the app is an incompatible-start conflict surfaced
to the caller.

**Send a message.** You type and hit Return (`ComposerView`) → the user turn is
saved to SwiftData and `ChatSendController.send()` builds the request →
`HTTPEngineClient` POSTs `/v1/chat/completions` to the loopback port → the engine
streams SSE chunks → `MessageStreamWriter` flushes deltas into the assistant
message → the transcript view re-renders live until `[DONE]`.

---

## Contributor notes & invariants

Things that are easy to get wrong, and where to look:

- **One inferlet, two planes.** `chat-apc` serves *both* the chat data plane and the
  health/models control endpoints. There is **no separate `pie-control` inferlet** —
  `Inferlets/pie-control/` does not exist. "pie-control" survives in some comments and
  test names as the old label for the *control-plane wire surface* (now part of
  `chat-apc`); treat it as a wire/protocol name, never a directory. The original v1
  plan put these routes in an axum listener inside pie and was later consolidated into
  the inferlet (`Inferlets/chat-apc/src/lib.rs` header).
- **One model id, end to end.** The profile's `model` slug *is* the engine's served id
  (`[[model]].name`) *is* the id in chat/model responses — no translation layer
  (`PieControlLauncher.renderConfigBody`).
- **The model loads at engine boot.** It comes from `config.toml`'s `hf_repo`, not from
  a runtime load call. So `/v1/models/load` is an instant registry confirm, and a slow
  first load shows up as `EngineStatus.starting`, not as in-flight load progress
  (`Shared/Engine/ModelLoadCenter.swift`, `Inferlets/chat-apc/src/control/load.rs`).
- **XPC status is pull, not push; starts are explicit requests.** The app polls
  `engineStatus()`; the helper does not stream status changes, and helper boot leaves
  the engine stopped. The launch prompt/user-confirm path plus explicit Restart, Local
  API start, and post-download recovery can request `startEngine(profileID:)`;
  same-profile idempotency stays inside `HelperExportedAPI` /
  `PieEngineHost.startOrAttach`. Every XPC reply carries an error channel so a dropped
  click is never silently swallowed (`Shared/XPC/PieHelperXPC.swift`).
- **Two ports per launch.** pie announces its own control-plane port on stdout (used for
  the WebSocket handshake); the inferlet's OpenAI HTTP listener binds a *separate*
  reserved port (`PieControlLauncher.swift`). The app's HTTP traffic targets the latter.
- **Ownership split.** The helper process owns the engine lifecycle, `ProfileStore`, and
  downloads; the app owns chat, UI, persistence, and the direct HTTP connection.

Where to start reading:

| Area | Files |
|------|-------|
| App entry & wiring | `App/RatioThinkApp.swift` |
| Chat UI & send path | `App/Views/Chat/`, `Shared/Persistence/ChatSendController.swift`, `Shared/Persistence/MessageStreamWriter.swift` |
| Status surfaces | `Shared/Engine/EngineStatusStore.swift`, `App/Views/ModelLoadIndicator.swift` |
| XPC contract | `Shared/XPC/PieHelperXPC.swift`, `AppXPCClient.swift`, `HelperXPCListener.swift`, `EngineStatus.swift` |
| Helper process | `Helper/HelperMain.swift`, `App/Services/LoginItemRegistrar.swift` |
| Engine launch & control | `Shared/Engine/PieControlLauncher.swift`, `PieControlClient.swift`, `PieEngineHost.swift` |
| Model resolution | `Shared/Engine/LaunchSpecResolver.swift`, `HFCacheResolver.swift` |
| HTTP engine client | `Shared/Engine/HTTPEngineClient.swift`, `EngineClient.swift` |
| Inferlet | `Inferlets/chat-apc/src/lib.rs`, `src/chat/`, `src/control/` |
