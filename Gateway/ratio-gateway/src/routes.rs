//! HTTP surface (doc/chat-refactor.md §8.1, §8.3).
//!
//! Phase 2 exercises the structure end to end against `echo`: deferred commit,
//! a process-driver task, cooperative cancel → grace → terminate, and
//! sequence-gap detection. Phase 3 swaps the passthrough renderer for the real
//! OpenAI dialect; nothing here changes shape.

use crate::engine::Engine;
// Envelope + sequence contract come from the shared crate, so the gateway
// and the inferlets cannot drift apart.
use ratio_wire::{ProtocolError, SeqChecker};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router, routing::get, routing::post};
use pie_client::client::{Client, Process, ProcessEvent};
use serde_json::json;
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Duration, Instant, timeout};

pub struct AppState {
    pub engine: Engine,
    pub inferlet: String,
    pub chat_inferlet: String,
    /// Escape hatch if pie renames the model_status keys.
    pub model_override: Option<String>,
    /// How long to wait for the guest's first event before giving up.
    pub first_event_timeout: Duration,
    /// Time the guest gets to emit its own terminal frame after a cancel.
    pub cancel_grace: Duration,
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/models", get(models))
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
    let ids: Vec<String> = if let Some(m) = &st.model_override {
        vec![m.clone()]
    } else {
        match st.engine.control_client().await {
            Ok(c) => match c.query("model_status", "{}".to_string()).await {
                Ok(raw) => serde_json::from_str::<serde_json::Value>(&raw)
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
                    .unwrap_or_default(),
                Err(_) => vec![],
            },
            Err(e) => {
                return api_error(
                    StatusCode::SERVICE_UNAVAILABLE, "engine_unavailable", &e.to_string());
            }
        }
    };
    Json(json!({
        "object": "list",
        "data": ids.iter().map(|id| json!({
            "id": id, "object": "model", "owned_by": "pie"
        })).collect::<Vec<_>>()
    }))
    .into_response()
}

/// `POST /v1/inferlet` — the app's raw dispatch endpoint (4 call sites).
///
/// Present deliberately: a 404 here reads as "wrong URL" and sends people
/// hunting for a routing bug. A 501 with the inferlet name says exactly what is
/// missing and which backend still has it.
async fn inferlet_dispatch(body: axum::body::Bytes) -> Response {
    let name = serde_json::from_slice::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| v.get("inferlet").and_then(|s| s.as_str()).map(str::to_string))
        .unwrap_or_else(|| "<unspecified>".into());
    api_error(
        StatusCode::NOT_IMPLEMENTED,
        "inferlet_not_implemented",
        &format!(
            "/v1/inferlet ({name}) is not implemented on the gateway backend yet. \
             Use RATIO_CHAT_BACKEND=daemon until the advanced inferlets are ported."
        ),
    )
}

fn api_error(status: StatusCode, code: &str, message: &str) -> Response {
    let kind = match status.as_u16() {
        400 => "invalid_request_error",
        404 => "not_found_error",
        413 => "payload_too_large_error",
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
        resp.headers_mut().insert("Retry-After", axum::http::HeaderValue::from_static("1"));
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

    let client = match st.engine.request_client().await {
        Ok(c) => Arc::new(c),
        Err(e) => {
            return api_error(StatusCode::SERVICE_UNAVAILABLE, "engine_unavailable", &e.to_string());
        }
    };

    let mut proc = match client
        .launch_process(st.inferlet.clone(), input, /* capture_outputs */ true, None)
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
            return api_error(StatusCode::GATEWAY_TIMEOUT, "inferlet_start_timeout", "no first event");
        }
        Ok(Err(e)) => return api_error(StatusCode::BAD_GATEWAY, "engine_stream_closed", &e.to_string()),
        Ok(Ok(ProcessEvent::Error(e))) => {
            return api_error(StatusCode::BAD_GATEWAY, "inferlet_error", &e);
        }
        Ok(Ok(ProcessEvent::Return(_))) => {
            return api_error(StatusCode::INTERNAL_SERVER_ERROR, "no_output", "returned without emitting");
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
    tokio::spawn(drive(proc, Arc::clone(&client), tx, cancel_rx, seq, st.cancel_grace));

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
                // Cooperative first: give the guest a chance to emit its own
                // terminal frame. Measured at <1 ms in the phase-1 gate.
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
