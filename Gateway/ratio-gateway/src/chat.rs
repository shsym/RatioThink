//! `POST /v1/chat/completions` (doc §7, §8).
//!
//! The gateway owns ids, timestamps, HTTP statuses and the OpenAI shapes.
//! It parses only routing/transport fields and forwards the body untouched —
//! `gen-core` owns request semantics.

use crate::routes::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use axum::Json;
use pie_client::client::{Client, Process, ProcessEvent};
use ratio_wire::{Event, GenResult, OpenAiSse, RunInput, SeqChecker};
use serde_json::json;
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Duration, Instant, timeout};

/// The guest reports semantics; the gateway alone decides HTTP status
/// (doc §5.1). Keep this exhaustive over the codes `gen-core` can emit.
pub fn status_for(code: &str) -> StatusCode {
    match code {
        "server_busy" => StatusCode::SERVICE_UNAVAILABLE,
        "model_not_found" => StatusCode::NOT_FOUND,
        "invalid_request"
        | "unsupported_role"
        | "tool_role_unsupported"
        | "unsupported_envelope_version" => StatusCode::BAD_REQUEST,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub fn api_error(status: StatusCode, code: &str, message: &str) -> Response {
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

/// 1 MiB, matching chat-apc's `CHAT_MAX_BODY` (sse.rs:28).
const CHAT_MAX_BODY: usize = 1 << 20;

enum Frame {
    Data(String),
    /// The complete terminal sequence, assembled by the driver. Carrying it as
    /// one message is what guarantees "exactly one finish" — the SSE body
    /// cannot end without it.
    Terminal {
        reason: ratio_wire::FinishReason,
        usage: Option<ratio_wire::UsageCounts>,
        metrics: Option<ratio_wire::MetricsCounts>,
        error: Option<(String, String)>,
    },
}

pub async fn chat_completions(
    State(st): State<Arc<AppState>>,
    body: axum::body::Bytes,
) -> Response {
    // ---- pre-commit ----
    if body.len() > CHAT_MAX_BODY {
        return api_error(StatusCode::PAYLOAD_TOO_LARGE, "payload_too_large", "body too large");
    }
    let raw: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => return api_error(StatusCode::BAD_REQUEST, "invalid_request", &e.to_string()),
    };

    // §2: a dispatch-shaped request (`inferlet:` naming tree-of-thought or
    // best-of-n) is NOT an ordinary chat request. Without routing on this field
    // it would deserialize as a plain ChatRequest, silently drop the advanced
    // envelope, and answer as if the profile had never been selected — a wrong
    // answer, not an error.
    //
    // The registry decides what that name means. `chat-apc` from the shipped
    // app reaches `chat` through a manifest alias rather than a string compare
    // here, so the gateway has no per-inferlet knowledge to update.
    let route = raw
        .get("inferlet")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("chat");
    let entry = match st.prepare(route).await {
        Ok(e) => e,
        Err(resp) => return resp,
    };

    // Only routing/transport fields are read here. Everything else — roles,
    // sampling bounds, cue mode — belongs to gen-core.
    let model = raw.get("model").and_then(|m| m.as_str()).unwrap_or("").to_string();
    let stream = raw.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
    let include_usage = raw
        .get("stream_options")
        .and_then(|o| o.get("include_usage"))
        .and_then(|b| b.as_bool())
        .unwrap_or(false);

    let request_id = format!("chatcmpl-{}", uuid::Uuid::new_v4().simple());
    let created = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let run_input = RunInput {
        v: 1,
        request_id: request_id.clone(),
        stream,
        request: raw,
    };
    let input = match serde_json::to_string(&run_input) {
        Ok(s) => s,
        Err(e) => return api_error(StatusCode::INTERNAL_SERVER_ERROR, "encode_failed", &e.to_string()),
    };

    let client = match st.engine.request_client().await {
        Ok(c) => Arc::new(c),
        Err(e) => {
            return api_error(StatusCode::SERVICE_UNAVAILABLE, "engine_unavailable", &e.to_string());
        }
    };
    let mut proc = match client
        .launch_process(entry.program.clone(), input, true, None)
        .await
    {
        Ok(p) => p,
        Err(e) => return api_error(StatusCode::BAD_GATEWAY, "launch_failed", &e.to_string()),
    };

    // Deferred commit: hold the status open until the guest reaches `Ready`.
    // Warnings may precede it and are buffered (doc §5.3 rule 1).
    let mut seq = SeqChecker::default();
    let mut pre_warnings: Vec<Event> = Vec::new();
    let started = Instant::now();
    loop {
        match timeout(st.first_event_timeout, proc.recv()).await {
            Err(_) => {
                let _ = client.terminate_process(proc.id()).await;
                return api_error(StatusCode::GATEWAY_TIMEOUT, "inferlet_start_timeout", "no ready");
            }
            Ok(Err(e)) => {
                return api_error(StatusCode::BAD_GATEWAY, "engine_stream_closed", &e.to_string());
            }
            Ok(Ok(ProcessEvent::Error(e))) => {
                return api_error(StatusCode::BAD_GATEWAY, "inferlet_error", &e);
            }
            Ok(Ok(ProcessEvent::Return(_))) => {
                return api_error(StatusCode::INTERNAL_SERVER_ERROR, "no_output", "returned before ready");
            }
            Ok(Ok(ProcessEvent::Message(m))) => {
                let env = match seq.accept(&m) {
                    Ok(e) => e,
                    Err(pe) => {
                        return api_error(StatusCode::BAD_GATEWAY, "protocol_error", &pe.to_string());
                    }
                };
                match env.decode_event() {
                    Ok(Some(Event::Ready)) => break,
                    Ok(Some(Event::Warning { code, message })) => {
                        pre_warnings.push(Event::Warning { code, message });
                    }
                    // A pre-commit failure is still a real HTTP status.
                    Ok(Some(Event::Error { code, message, .. })) => {
                        let _ = client.terminate_process(proc.id()).await;
                        return api_error(status_for(&code), &code, &message);
                    }
                    Ok(_) | Err(_) => {}
                }
            }
            Ok(Ok(_)) => {}
        }
    }

    if stream {
        stream_response(st, client, proc, seq, pre_warnings, request_id, model, created,
                        include_usage, started)
    } else {
        buffered_response(client, proc, seq, request_id, model, created, started).await
    }
}

#[allow(clippy::too_many_arguments)]
fn stream_response(
    st: Arc<AppState>,
    client: Arc<Client>,
    proc: Process,
    seq: SeqChecker,
    pre_warnings: Vec<Event>,
    id: String,
    model: String,
    created: i64,
    include_usage: bool,
    started: Instant,
) -> Response {
    let (tx, mut rx) = mpsc::channel::<Frame>(256);
    let (cancel_tx, cancel_rx) = oneshot::channel::<()>();
    tokio::spawn(drive(proc, Arc::clone(&client), tx, cancel_rx, seq, st.cancel_grace, started));

    let guard = crate::routes::CancelOnDrop(Some(cancel_tx));
    let mut r = OpenAiSse::new(id, model, created).with_usage_chunk(include_usage);

    let stream = async_stream::stream! {
        let _guard = guard;
        for w in &pre_warnings {
            for f in r.render(w) { yield Ok::<_, Infallible>(SseEvent::default().data(f)); }
        }
        for f in r.render(&Event::Ready) { yield Ok(SseEvent::default().data(f)); }
        let mut terminated = false;
        while let Some(frame) = rx.recv().await {
            match frame {
                Frame::Data(raw) => {
                    if let Ok(ev) = serde_json::from_str::<Event>(&raw) {
                        for f in r.render(&ev) { yield Ok(SseEvent::default().data(f)); }
                    }
                }
                Frame::Terminal { reason, usage, metrics, error } => {
                    for f in r.terminal(reason, usage, metrics, error) {
                        yield Ok(SseEvent::default().data(f));
                    }
                    terminated = true;
                    break;
                }
            }
        }
        // Belt and braces: if the driver task itself died without sending a
        // terminal, still close the stream properly rather than emitting a
        // bare [DONE] that reads as success.
        if !terminated {
            for f in r.terminal(
                ratio_wire::FinishReason::Error,
                None,
                None,
                Some(("driver_lost".into(), "event driver stopped unexpectedly".into())),
            ) {
                yield Ok(SseEvent::default().data(f));
            }
        }
    };

    // No keep_alive: comment lines would make the stream non-diffable
    // against chat-apc.
    Sse::new(stream).into_response()
}

/// Non-streaming shares the same guest loop; it just discards the deltas and
/// serializes the terminal `GenResult` (doc §4.2).
async fn buffered_response(
    client: Arc<Client>,
    mut proc: Process,
    mut seq: SeqChecker,
    id: String,
    model: String,
    created: i64,
    started: Instant,
) -> Response {
    let mut result: Option<GenResult> = None;
    let mut err: Option<(String, String)> = None;
    loop {
        match proc.recv().await {
            Ok(ProcessEvent::Message(m)) => {
                if let Ok(env) = seq.accept(&m) {
                    if let Ok(Some(Event::Error { code, message, .. })) = env.decode_event() {
                        err = Some((code, message));
                    }
                }
            }
            Ok(ProcessEvent::Return(r)) => {
                result = serde_json::from_str::<GenResult>(&r).ok();
                if let Some(g) = &result {
                    tracing::info!(
                        boundary_found = g.boundary_found,
                        reused_tokens = g.reused_tokens,
                        prompt_tokens = g.prompt_tokens,
                        "kv reuse"
                    );
                }
                break;
            }
            Ok(ProcessEvent::Error(e)) => {
                err = Some(("inferlet_error".into(), e));
                break;
            }
            Ok(_) => {}
            Err(e) => {
                err = Some(("engine_stream_closed".into(), e.to_string()));
                break;
            }
        }
    }
    let _ = client.terminate_process(proc.id()).await;
    let _ = started;

    // An `Error` event alongside a `GenResult` means the generation ABORTED.
    // Preferring the result turned a failed generation into HTTP 200.
    match (&err, &result) {
        // Pure failure: no partial output at all.
        (Some((code, message)), None) => {
            return api_error(status_for(code), code, message);
        }
        // Partial: content was produced before the abort. chat-apc reports
        // this as 502 rather than a clean 200.
        (Some((code, message)), Some(r)) if r.content.is_empty() => {
            return api_error(status_for(code), code, message);
        }
        (Some((code, message)), Some(_)) => {
            return api_error(StatusCode::BAD_GATEWAY, code, message);
        }
        _ => {}
    }
    let Some(res) = result else {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, "no_output", "no result");
    };

    let finish = res.finish_reason.map(|f| f.as_wire()).unwrap_or("stop");
    let mut msg = json!({"role":"assistant","content":res.content});
    if let Some(r) = &res.reasoning {
        msg["reasoning_content"] = json!(r);
    }
    Json(json!({
        "id": id,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [{"index":0,"message":msg,"finish_reason":finish}],
        "usage": {
            "prompt_tokens": res.prompt_tokens,
            "completion_tokens": res.completion_tokens,
            "total_tokens": res.prompt_tokens + res.completion_tokens
        }
    }))
    .into_response()
}

/// Owns the `Process`. Forwards events, and guarantees exactly one terminal
/// sequence no matter how the stream ends.
///
/// Three failure properties this must hold (all were broken before):
///   1. A full downstream channel must NOT block the cancellation branch.
///      `tx.send().await` inside the select arm parked the driver so it could
///      no longer observe cancel, while pie kept buffering upstream.
///   2. Every exit path terminates the process. Dropping the client only
///      DETACHES it (`server.rs:400-403`), so a lost receiver used to leak a
///      running generation.
///   3. A post-commit fault must surface as an in-band `error` frame plus a
///      synthesized `finish`, never as a clean truncated stream. Generic
///      OpenAI clients have no `missing_finish_reason` fallback.
#[allow(clippy::too_many_arguments)]
async fn drive(
    mut proc: Process,
    client: Arc<Client>,
    tx: mpsc::Sender<Frame>,
    mut cancel_rx: oneshot::Receiver<()>,
    mut seq: SeqChecker,
    grace: Duration,
    started: Instant,
) {
    let pid = proc.id().to_string();
    let mut usage: Option<ratio_wire::UsageCounts> = None;
    let mut finish: Option<ratio_wire::FinishReason> = None;
    let mut error: Option<(String, String)> = None;
    let mut cancelled = false;

    loop {
        // `reserve()` is cancellation-safe and yields a permit without
        // committing, so a full channel parks HERE — inside select, where the
        // cancel branch is still live — instead of inside an arm.
        let permit = tokio::select! {
            biased;
            _ = &mut cancel_rx => { cancelled = true; break }
            p = tx.reserve() => match p {
                Ok(p) => p,
                // Receiver gone: the HTTP client hung up.
                Err(_) => { cancelled = true; break }
            }
        };

        let ev = tokio::select! {
            biased;
            _ = &mut cancel_rx => { cancelled = true; break }
            ev = proc.recv() => ev,
        };

        match ev {
            Ok(ProcessEvent::Message(m)) => match seq.accept(&m) {
                Ok(env) => match env.decode_event() {
                    Ok(Some(Event::Usage { prompt_tokens, completion_tokens, context_window })) => {
                        usage = Some(ratio_wire::UsageCounts {
                            prompt_tokens,
                            completion_tokens,
                            context_window,
                        });
                    }
                    Ok(Some(Event::Finish { reason })) => finish = Some(reason),
                    Ok(Some(Event::Error { code, message, .. })) => {
                        error = Some((code, message));
                    }
                    // Forward everything else verbatim.
                    Ok(Some(_)) => permit.send(Frame::Data(env.e.to_string())),
                    // Unknown tag: ignore (§5.3 rule 5).
                    Ok(None) => {}
                    Err(pe) => {
                        error = Some(("protocol_error".into(), pe.to_string()));
                        break;
                    }
                },
                Err(pe) => {
                    error = Some(("protocol_error".into(), pe.to_string()));
                    break;
                }
            },
            Ok(ProcessEvent::Return(_)) => break,
            Ok(ProcessEvent::Error(e)) => {
                error = Some(("inferlet_error".into(), e));
                break;
            }
            Ok(_) => {}
            Err(e) => {
                error = Some(("engine_stream_closed".into(), e.to_string()));
                break;
            }
        }
    }

    if cancelled {
        // Cooperative first, then authoritative.
        tracing::info!(process = %pid, "client gone — cancelling");
        let sent = Instant::now();
        let _ = proc.signal(r#"{"v":1,"c":{"t":"cancel"}}"#).await;
        let deadline = sent + grace;
        // Did the GUEST stop on its own, or did we have to force-kill it? That
        // distinction is the whole point of cooperative cancellation, so it is
        // logged rather than inferred.
        let mut guest_stopped = false;
        while Instant::now() < deadline {
            match timeout(deadline - Instant::now(), proc.recv()).await {
                Ok(Ok(ProcessEvent::Message(m))) => {
                    if m.contains(r#""t":"finish""#) { guest_stopped = true; }
                }
                Ok(Ok(ProcessEvent::Return(_))) => { guest_stopped = true; break }
                Ok(Ok(ProcessEvent::Error(_))) => break,
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }
        tracing::info!(
            process = %pid, guest_stopped,
            latency_ms = sent.elapsed().as_millis() as u64,
            "cancel resolved"
        );
        if finish.is_none() {
            finish = Some(ratio_wire::FinishReason::Cancelled);
        }
    }

    // ALWAYS terminate: every exit path, including a lost receiver.
    let _ = client.terminate_process(&pid).await;

    // A fault after commit must still produce a terminal chunk. Without this a
    // generic OpenAI client sees a clean `[DONE]` after a truncated answer.
    let reason = finish.unwrap_or_else(|| {
        if error.is_some() {
            ratio_wire::FinishReason::Error
        } else {
            tracing::warn!(process = %pid, "stream ended with no finish — synthesizing error");
            error = Some((
                "missing_finish".into(),
                "generation ended without a terminal event".into(),
            ));
            ratio_wire::FinishReason::Error
        }
    });

    let metrics = usage.map(|u| ratio_wire::MetricsCounts {
        output_tokens: u.completion_tokens,
        elapsed_s: started.elapsed().as_secs_f64(),
    });
    let _ = tx.send(Frame::Terminal { reason, usage, metrics, error }).await;
}
