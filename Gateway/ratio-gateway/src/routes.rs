//! HTTP routing and PIE process driving.

use crate::engine::Engine;
use crate::registry::{Entry, Installed, Registry};
// Envelope + sequence contract come from the shared crate, so the gateway
// and the inferlets cannot drift apart.
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router, routing::get, routing::post};
use pie_client::client::{Client, Process, ProcessEvent};
use ratio_wire::{ProtocolError, SeqChecker};
use serde_json::json;
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Duration, Instant, timeout};

pub struct AppState {
    pub engine: Engine,
    /// Swapped wholesale on reload. Readers clone the `Arc` out immediately and
    /// never hold the lock across an await, so an in-flight request keeps
    /// serving the version it started with even as a new one is installed.
    pub registry: std::sync::RwLock<Arc<Registry>>,
    pub installed: Installed,
    /// Serializes install so two concurrent first-uses of the same lazily
    /// installed inferlet do not both pay for `add_program`.
    pub install_lock: tokio::sync::Mutex<()>,
    pub inferlet_dir: PathBuf,
    pub admin_token: Option<String>,
    /// Escape hatch if pie renames the model_status keys.
    pub model_override: Option<String>,
    /// How long to wait for the guest's first event before giving up.
    pub first_event_timeout: Duration,
    /// Time the guest gets to emit its own terminal frame after a cancel.
    pub cancel_grace: Duration,
}

impl AppState {
    pub fn registry(&self) -> Arc<Registry> {
        Arc::clone(&self.registry.read().unwrap())
    }

    /// Resolve a route name, or produce the 404 that names the alternatives —
    /// a bare "not found" here sends people hunting for a routing bug when the
    /// real problem is a missing file in the inferlet directory.
    pub fn resolve(&self, route: &str) -> Result<Arc<Entry>, Response> {
        let reg = self.registry();
        match reg.get(route) {
            Some(e) => Ok(Arc::clone(e)),
            None => Err(api_error(
                StatusCode::NOT_FOUND,
                "inferlet_not_found",
                &format!(
                    "no inferlet {route:?} is registered; available: {}",
                    reg.routes().join(", ")
                ),
            )),
        }
    }

    /// Install this exact artifact version if the engine does not have it.
    ///
    /// Keyed on the digest, so an inferlet whose files changed reinstalls. A
    /// per-route `OnceCell` would report success while continuing to serve the
    /// old wasm — reload would look like it worked and change nothing.
    pub async fn ensure_installed(&self, e: &Entry) -> anyhow::Result<()> {
        if !self.installed.needs_install(e) {
            return Ok(());
        }
        let _g = self.install_lock.lock().await;
        if !self.installed.needs_install(e) {
            return Ok(()); // won by another task while we waited
        }
        let control = self.engine.control_client().await?;
        crate::engine::install(&control, &e.wasm, &e.manifest).await?;
        self.installed.mark(e);
        tracing::info!(route = %e.route, program = %e.program, digest = %e.digest, "installed");
        Ok(())
    }

    /// Model ids the engine is serving, sorted. `--model` short-circuits it.
    ///
    /// `runtime::models()` is a WIT import available only inside wasm, so the
    /// host reads the list from `query("model_status")`, whose keys are
    /// `"<model>.kv_pages_total"` (handler.rs:53-66).
    pub async fn models(&self) -> Vec<String> {
        if let Some(m) = &self.model_override {
            return vec![m.clone()];
        }
        let Ok(c) = self.engine.control_client().await else {
            return vec![];
        };
        let Ok(raw) = c.query("model_status", "{}".to_string()).await else {
            return vec![];
        };
        serde_json::from_str::<serde_json::Value>(&raw)
            .ok()
            .and_then(|v| v.as_object().cloned())
            .map(|o| {
                let mut v: Vec<String> = o
                    .keys()
                    .filter_map(|k| k.strip_suffix(".kv_pages_total").map(str::to_string))
                    .collect();
                v.sort();
                v.dedup();
                v
            })
            .unwrap_or_default()
    }

    /// The engine's first model, for a request that omitted one.
    ///
    /// chat-apc resolved an omitted ToT model this way (`tot/mod.rs:254-277`)
    /// and emitted the RESOLVED id in `tree_start`. Without this the gateway
    /// would render `"model":""` into the client's tree header — no error, just
    /// a blank.
    pub async fn first_model(&self) -> Option<String> {
        self.models().await.into_iter().next()
    }

    /// Resolve, check the protocol is one the gateway can actually drive, and
    /// make sure the engine has the bytes. The common prologue of every
    /// generative endpoint.
    pub async fn prepare(&self, route: &str) -> Result<Arc<Entry>, Response> {
        let entry = self.resolve(route)?;
        if !entry.protocol.implemented() {
            return Err(api_error(
                StatusCode::NOT_IMPLEMENTED,
                "protocol_not_implemented",
                &format!(
                    "inferlet {route:?} declares protocol {:?}, which the gateway cannot \
                     drive yet. Use RATIO_CHAT_BACKEND=daemon for tree-of-thought / best-of-n.",
                    entry.protocol.as_str()
                ),
            ));
        }
        if let Err(e) = self.ensure_installed(&entry).await {
            return Err(api_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "install_failed",
                &e.to_string(),
            ));
        }
        Ok(entry)
    }
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/models", get(models))
        .route("/v1/inferlets", get(list_inferlets))
        .route("/v1/admin/reload", post(reload))
        .route("/v1/echo", post(echo))
        .route("/v1/chat/completions", post(crate::chat::chat_completions))
        .route("/v1/inferlet", post(inferlet_dispatch))
        .with_state(state)
}

/// Gateway-local liveness. Does not touch the engine — a control-plane round
/// trip here would make the health check fail for reasons unrelated to the
/// gateway being able to serve.
async fn healthz() -> impl IntoResponse {
    Json(json!({ "status": "ok" }))
}

/// `GET /v1/models`. `runtime::models()` is a WIT import available only inside
/// wasm, so the host reads the list from `query("model_status")`, whose keys
/// are `"<model>.kv_pages_total"` (handler.rs:53-66). `--model` overrides if
/// pie ever renames those keys.
async fn models(State(st): State<Arc<AppState>>) -> Response {
    let ids = st.models().await;
    Json(json!({
        "object": "list",
        "data": ids.iter().map(|id| json!({
            "id": id, "object": "model", "owned_by": "pie"
        })).collect::<Vec<_>>()
    }))
    .into_response()
}

/// `GET /v1/inferlets` — what is registered, and whether it can be driven.
///
/// Unauthenticated on purpose: it exposes route names and digests, which the
/// 404 body already reveals, and it is the first thing to check when a route
/// unexpectedly 404s.
async fn list_inferlets(State(st): State<Arc<AppState>>) -> Response {
    let reg = st.registry();
    Json(json!({
        "object": "list",
        "dir": st.inferlet_dir.display().to_string(),
        "data": reg.entries().map(|e| json!({
            "route": e.route,
            "aliases": e.aliases,
            "program": e.program,
            "protocol": e.protocol.as_str(),
            "digest": e.digest,
            "preload": e.preload,
            "installed": !st.installed.needs_install(e),
            "drivable": e.protocol.implemented(),
            "snapshot_prefixes": e.snapshot_prefixes,
        })).collect::<Vec<_>>()
    }))
    .into_response()
}

/// `POST /v1/admin/reload` — rescan the directory and swap atomically.
///
/// The swap is all-or-nothing: `Registry::scan` validates everything before
/// returning, so a directory with one broken manifest leaves the running
/// registry exactly as it was. In-flight requests keep the `Arc` they resolved
/// against and finish on the old version.
async fn reload(State(st): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    // 404, not 401: without a token this endpoint does not exist, and saying
    // "unauthorized" would advertise an admin surface that cannot be used.
    let Some(expected) = st.admin_token.as_deref() else {
        return api_error(
            StatusCode::NOT_FOUND,
            "admin_disabled",
            "reload is disabled; start the gateway with --admin-token to enable it",
        );
    };
    let presented = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if !constant_time_eq(presented.as_bytes(), expected.as_bytes()) {
        return api_error(StatusCode::UNAUTHORIZED, "unauthorized", "bad admin token");
    }

    let next = match Registry::scan(&st.inferlet_dir) {
        Ok(r) => Arc::new(r),
        Err(e) => {
            tracing::warn!(error = %e, "reload rejected; keeping the current registry");
            return api_error(
                StatusCode::BAD_REQUEST,
                "invalid_inferlet_dir",
                &format!("{e:#} — the previous registry is still serving"),
            );
        }
    };

    let before: Vec<(String, String)> = st
        .registry()
        .entries()
        .map(|e| (e.route.clone(), e.digest.clone()))
        .collect();
    *st.registry.write().unwrap() = Arc::clone(&next);

    // Reinstall eagerly for anything marked preload whose bytes changed; the
    // rest reinstalls on next use, since `Installed` keys on the digest.
    let mut changed = Vec::new();
    for e in next.entries() {
        let was = before
            .iter()
            .find(|(r, _)| *r == e.route)
            .map(|(_, d)| d.as_str());
        if was != Some(e.digest.as_str()) {
            changed.push(json!({"route": e.route, "from": was, "to": e.digest}));
            if e.preload {
                if let Err(err) = st.ensure_installed(e).await {
                    // The registry already points at the new version, so this
                    // route will retry the install on its next request.
                    tracing::warn!(route = %e.route, error = %err, "preload after reload failed");
                }
            }
        }
    }
    tracing::info!(changed = changed.len(), "registry reloaded");
    Json(json!({"reloaded": true, "routes": next.routes(), "changed": changed})).into_response()
}

/// Length-independent only for equal-length inputs, which is enough here: the
/// token length is not a secret worth protecting.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// `POST /v1/inferlet` — the app's raw dispatch endpoint (4 call sites).
///
/// Unknown inferlets return 404; unsupported protocol classes return 501.
async fn inferlet_dispatch(State(st): State<Arc<AppState>>, body: axum::body::Bytes) -> Response {
    let name = serde_json::from_slice::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| {
            v.get("inferlet")
                .and_then(|s| s.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    if name.is_empty() {
        return api_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "POST /v1/inferlet requires an \"inferlet\" field",
        );
    }
    let entry = match st.prepare(&name).await {
        Ok(e) => e,
        Err(resp) => return resp,
    };

    // Dispatch by PROTOCOL CLASS, not by inferlet name. This is what makes a
    // new tree-shaped inferlet a manifest entry rather than a gateway change:
    // `tot` and `bestofn` both declare `tree-v1` and both land in one driver.
    match entry.protocol {
        crate::registry::Protocol::TreeV1 => {
            let raw = match serde_json::from_slice::<serde_json::Value>(&body) {
                Ok(v) => v,
                Err(e) => {
                    return api_error(StatusCode::BAD_REQUEST, "invalid_request", &e.to_string());
                }
            };
            crate::tree::dispatch(st, entry.route.clone(), entry.program.clone(), raw).await
        }
        // Chat has its own endpoint and its own request shape; routing it here
        // would duplicate the OpenAI body handling for no gain.
        crate::registry::Protocol::ChatV1 => api_error(
            StatusCode::NOT_IMPLEMENTED,
            "dispatch_not_implemented",
            &format!(
                "{:?} speaks chat-v1; use POST /v1/chat/completions",
                entry.route
            ),
        ),
        // `prepare` already rejects protocols with no driver, so this is
        // unreachable — but stating it keeps the match exhaustive by class
        // rather than by a catch-all that would silently absorb a new one.
        crate::registry::Protocol::JsonUnaryV1 => api_error(
            StatusCode::NOT_IMPLEMENTED,
            "protocol_not_implemented",
            "json-unary-v1 has no driver",
        ),
    }
}

pub fn api_error(status: StatusCode, code: &str, message: &str) -> Response {
    let kind = match status.as_u16() {
        400 => "invalid_request_error",
        401 => "authentication_error",
        404 => "not_found_error",
        413 => "payload_too_large_error",
        501 => "not_implemented_error",
        503 => "service_unavailable_error",
        _ => "server_error",
    };
    let mut resp = (
        status,
        Json(json!({"error":{"type":kind,"code":code,"message":message,"param":null}})),
    )
        .into_response();
    // The app's retry ladder keys on Retry-After for over-capacity; without it
    // a 503 is treated as a hard failure instead of a backoff.
    if status == StatusCode::SERVICE_UNAVAILABLE {
        resp.headers_mut()
            .insert("Retry-After", axum::http::HeaderValue::from_static("1"));
    }
    resp
}

/// What the driver task forwards to the SSE body.
enum Frame {
    Data(String),
    Fault(String),
    Done,
}

/// POST /v1/echo — drives the `echo` inferlet and streams its envelopes.
async fn echo(State(st): State<Arc<AppState>>, body: axum::body::Bytes) -> Response {
    // ---- pre-commit: every failure below is a real HTTP status ----
    let input = if body.is_empty() {
        json!({ "count": 4, "hold_ms": 0 }).to_string()
    } else {
        match serde_json::from_slice::<serde_json::Value>(&body) {
            Ok(v) => v.to_string(),
            Err(e) => return api_error(StatusCode::BAD_REQUEST, "invalid_request", &e.to_string()),
        }
    };

    let entry = match st.prepare("echo").await {
        Ok(e) => e,
        Err(resp) => return resp,
    };

    let client = match st.engine.request_client().await {
        Ok(c) => Arc::new(c),
        Err(e) => {
            return api_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "engine_unavailable",
                &e.to_string(),
            );
        }
    };

    let mut proc = match client
        .launch_process(
            entry.program.clone(),
            input,
            /* capture_outputs */ true,
            None,
        )
        .await
    {
        Ok(p) => p,
        Err(e) => return api_error(StatusCode::BAD_GATEWAY, "launch_failed", &e.to_string()),
    };

    // Deferred commit (§8.1): hold the status open until the guest speaks, so a
    // fast failure is still a clean JSON error rather than a 200 that turns bad.
    let mut seq = SeqChecker::default();
    let first = match timeout(st.first_event_timeout, proc.recv()).await {
        Err(_) => {
            let _ = client.terminate_process(proc.id()).await;
            return api_error(
                StatusCode::GATEWAY_TIMEOUT,
                "inferlet_start_timeout",
                "no first event",
            );
        }
        Ok(Err(e)) => {
            return api_error(
                StatusCode::BAD_GATEWAY,
                "engine_stream_closed",
                &e.to_string(),
            );
        }
        Ok(Ok(ProcessEvent::Error(e))) => {
            return api_error(StatusCode::BAD_GATEWAY, "inferlet_error", &e);
        }
        Ok(Ok(ProcessEvent::Return(_))) => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "no_output",
                "returned without emitting",
            );
        }
        Ok(Ok(ProcessEvent::Message(m))) => match seq.accept(&m) {
            Ok(_) => m,
            Err(pe) => return protocol_fault(&pe),
        },
        Ok(Ok(_)) => String::new(),
    };

    // ---- committed: everything below rides the stream ----
    let (tx, mut rx) = mpsc::channel::<Frame>(64);
    let (cancel_tx, cancel_rx) = oneshot::channel::<()>();

    if !first.is_empty() {
        let _ = tx.send(Frame::Data(first)).await;
    }
    tokio::spawn(drive(
        proc,
        Arc::clone(&client),
        tx,
        cancel_rx,
        seq,
        st.cancel_grace,
    ));

    // Dropping the guard (client hung up, or normal completion) tells the
    // driver to cancel. This is the backpressure mechanism, not just hygiene:
    // nothing else stops a generating inferlet (§2.3).
    let guard = CancelOnDrop(Some(cancel_tx));

    let stream = async_stream::stream! {
        let _guard = guard;
        while let Some(frame) = rx.recv().await {
            match frame {
                Frame::Data(d) => yield Ok::<_, Infallible>(SseEvent::default().data(d)),
                Frame::Fault(f) => {
                    yield Ok(SseEvent::default()
                        .data(json!({"event":"error","code":"protocol_error","message":f}).to_string()));
                }
                Frame::Done => break,
            }
        }
        yield Ok(SseEvent::default().data("[DONE]"));
    };

    // No keep_alive: axum injects `:` comment lines, which would make the byte
    // stream non-diffable against chat-apc (§7).
    Sse::new(stream).into_response()
}

fn protocol_fault(pe: &ProtocolError) -> Response {
    api_error(StatusCode::BAD_GATEWAY, "protocol_error", &pe.to_string())
}

pub struct CancelOnDrop(pub Option<oneshot::Sender<()>>);

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if let Some(tx) = self.0.take() {
            let _ = tx.send(());
        }
    }
}

/// Owns the `Process` and selects between its events and cancellation.
/// `Process::signal` lives on `Process`, not `Client`, which is why the process
/// must be owned here rather than reached from the drop guard.
async fn drive(
    mut proc: Process,
    client: Arc<Client>,
    tx: mpsc::Sender<Frame>,
    mut cancel_rx: oneshot::Receiver<()>,
    mut seq: SeqChecker,
    grace: Duration,
) {
    loop {
        tokio::select! {
            _ = &mut cancel_rx => {
                // Signal cooperatively before authoritative termination.
                let pid = proc.id().to_string();
                tracing::info!(process = %pid, "client disconnected — signalling cancel");
                let started = Instant::now();
                let _ = proc.signal(r#"{"v":1,"c":{"t":"cancel"}}"#).await;
                let deadline = started + grace;
                let mut acked = false;
                while Instant::now() < deadline {
                    match timeout(deadline - Instant::now(), proc.recv()).await {
                        Ok(Ok(ProcessEvent::Message(m))) => {
                            if m.contains(r#""cancelled":true"#) { acked = true; }
                        }
                        Ok(Ok(ProcessEvent::Return(_))) | Ok(Ok(ProcessEvent::Error(_))) => break,
                        Ok(Ok(_)) => continue,
                        _ => break,
                    }
                }
                tracing::info!(
                    process = %pid, guest_acked = acked,
                    elapsed_ms = started.elapsed().as_millis() as u64,
                    "terminating process"
                );
                // Authoritative: dropping the client only detaches
                // (server.rs:400-403), so the process would keep running.
                let _ = client.terminate_process(proc.id()).await;
                let _ = tx.send(Frame::Done).await;
                return;
            }
            ev = proc.recv() => {
                match ev {
                    Ok(ProcessEvent::Message(m)) => match seq.accept(&m) {
                        Ok(_) => {
                            if tx.send(Frame::Data(m)).await.is_err() { break; }
                        }
                        Err(pe) => {
                            let _ = tx.send(Frame::Fault(pe.to_string())).await;
                            let _ = client.terminate_process(proc.id()).await;
                            break;
                        }
                    },
                    Ok(ProcessEvent::Return(_)) => break,
                    Ok(ProcessEvent::Error(e)) => {
                        let _ = tx.send(Frame::Fault(e)).await;
                        break;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        let _ = tx.send(Frame::Fault(e.to_string())).await;
                        break;
                    }
                }
            }
        }
    }
    let _ = tx.send(Frame::Done).await;
}
