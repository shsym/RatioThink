//! The `tree-v1` protocol class.
//!
//! | | chat-v1 | tree-v1 |
//! |---|---|---|
//! | commits on | `Event::Ready` | the first tree event |
//! | opening frames | `model_ready` + role chunk | `tree_start` only |
//! | terminates on | `Finish` | `TreeComplete` / `AwaitingSelection` / `Error` |
//! | terminal sequence | `terminal()` builds it | the GUEST's own last event |
//! | finish chunk | always | never |
//! | `usage` frame | yes | never |
//! | `generation_metrics` | in `terminal()` | inline, mid-stream |
//!
//! The tree driver owns terminal-event semantics; `OpenAiSse` owns framing.

use crate::chat::{api_error, status_for};
use crate::routes::{AppState, CancelOnDrop};
use axum::http::StatusCode;
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use pie_client::client::{Client, Process, ProcessEvent};
use ratio_wire::RunInput;
use ratio_wire::{Event, OpenAiSse, SeqChecker};
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Duration, Instant, timeout};

/// Frames the driver task hands to the SSE body.
enum Frame {
    Data(String),
    /// A guest error that arrived AFTER commit. It renders in band and ends the
    /// stream — in tree-v1 the error frame IS the terminal, replacing
    /// `tree_complete` entirely rather than trailing it.
    Fault(String, String),
    /// The guest emitted its own terminal event; only `[DONE]` remains.
    Done,
}

/// Which guest events end a tree stream.
///
/// `AwaitingSelection` is terminal too: a Best-of-N round ends by handing the
/// client a pick set and waiting for a human, with no `tree_complete` at all.
/// Milestone C produces it; recognizing it here now means C adds a producer,
/// not a protocol change.
fn is_terminal(ev: &Event) -> bool {
    matches!(
        ev,
        Event::TreeComplete { .. } | Event::AwaitingSelection { .. }
    )
}

/// Whether this tree-v1 request is a CONTROL op rather than a generative one.
///
/// Best-of-N's commit and release run no generation and emit no events: they
/// return an accounting JSON body. Opening an SSE stream for them would hang
/// until `first_event_timeout` and then 504, because the deferred-commit loop
/// waits for an event that is never coming — the same failure mode as pointing
/// the chat driver at a tree inferlet.
///
/// Keyed on the BODY, not on a second protocol class. A class is per registry
/// Entry, and `bestofn` needs both shapes; splitting it would mean two wasm
/// artifacts writing the same `bon/` namespace, which is worse.
fn is_control_op(raw: &serde_json::Value) -> bool {
    let body = raw.get("input").unwrap_or(raw);
    body.get("commit").is_some_and(|c| !c.is_null())
        || body
            .get("release")
            .and_then(|r| r.as_array())
            .is_some_and(|r| !r.is_empty())
}

/// `POST /v1/inferlet` for a `tree-v1` route.
pub async fn dispatch(
    st: Arc<AppState>,
    route: String,
    entry_program: String,
    raw: serde_json::Value,
) -> Response {
    // ---- pre-commit: every failure here is still a real HTTP status ----
    let request_id = format!("tot-{}", uuid::Uuid::new_v4().simple());
    let created = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    // `tree_start.model` is rendered from here, so a blank one shows blank in
    // the client's tree header. chat-apc resolved an omitted model to the
    // engine's first (tot/mod.rs:254-277); mirror that instead of shipping an
    // empty string. NOTE this string is display-only — the model the guest
    // digests into the `conv/` boundary name is the one IT resolves, and the
    // returned `TreeResult.model` is what a test should compare.
    let control = is_control_op(&raw);

    let requested = raw
        .get("input")
        .and_then(|i| i.get("model"))
        .or_else(|| raw.get("model"))
        .and_then(|m| m.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    let model = if requested.is_empty() {
        st.first_model().await.unwrap_or_default()
    } else {
        requested
    };

    let input = match serde_json::to_string(&RunInput {
        v: 1,
        request_id: request_id.clone(),
        stream: true,
        request: raw,
    }) {
        Ok(s) => s,
        Err(e) => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "encode_failed",
                &e.to_string(),
            );
        }
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
        .launch_process(entry_program, input, true, None)
        .await
    {
        Ok(p) => p,
        Err(e) => return api_error(StatusCode::BAD_GATEWAY, "launch_failed", &e.to_string()),
    };

    if control {
        return unary_response(client, proc, seq_start(), st.first_event_timeout).await;
    }

    // ---- deferred commit ----
    //
    // Commit on the first RENDERABLE event rather than on a designated one.
    // chat-v1 can wait for `Ready` because the guest promises to send it; a
    // tree guest's first event is `tree_start`, but a pre-commit failure
    // arrives as `Error` and must still become an HTTP status, not a 200 that
    // turns bad. So: an `Error` before anything else is a status; anything
    // else commits.
    let mut seq = SeqChecker::default();
    let started = Instant::now();
    // The loop YIELDS the committing event, so there is no `Option` to unwrap
    // later and no way to reach the stream without one.
    let opening: Event = loop {
        match timeout(st.first_event_timeout, proc.recv()).await {
            Err(_) => {
                let _ = client.terminate_process(proc.id()).await;
                return api_error(
                    StatusCode::GATEWAY_TIMEOUT,
                    "inferlet_start_timeout",
                    "no tree_start",
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
                    "returned before tree_start",
                );
            }
            Ok(Ok(ProcessEvent::Message(m))) => {
                let env = match seq.accept(&m) {
                    Ok(e) => e,
                    Err(pe) => {
                        return api_error(
                            StatusCode::BAD_GATEWAY,
                            "protocol_error",
                            &pe.to_string(),
                        );
                    }
                };
                match env.decode_event() {
                    // A guest error before any output is a real status. `param`
                    // is carried through: the ToT validators produce
                    // `param: "top_p"` and friends, and dropping it here would
                    // make every 400 anonymous.
                    Ok(Some(Event::Error {
                        code,
                        message,
                        param,
                    })) => {
                        let _ = client.terminate_process(proc.id()).await;
                        return api_error_param(
                            status_for(&code),
                            &code,
                            &message,
                            param.as_deref(),
                        );
                    }
                    Ok(Some(ev)) => break ev,
                    // Warnings and unknown-tag frames are ignorable; keep
                    // waiting for something that commits.
                    Ok(None) | Err(_) => continue,
                }
            }
            Ok(Ok(_)) => continue,
        }
    };

    // ---- committed ----
    let (tx, mut rx) = mpsc::channel::<Frame>(256);
    let (cancel_tx, cancel_rx) = oneshot::channel::<()>();
    tokio::spawn(drive(
        proc,
        Arc::clone(&client),
        tx,
        cancel_rx,
        seq,
        st.cancel_grace,
        route,
    ));

    let guard = CancelOnDrop(Some(cancel_tx));
    // `with_tree_metrics(true)` is mandatory. Without it the guest's
    // `generation_metrics` renders to an empty Vec and vanishes with no error,
    // no log and no test failure.
    let mut r = OpenAiSse::new(request_id, model, created).with_tree_metrics(true);

    let stream = async_stream::stream! {
        let _guard = guard;
        for f in r.render(&opening) { yield Ok::<_, Infallible>(SseEvent::default().data(f)); }
        while let Some(frame) = rx.recv().await {
            match frame {
                Frame::Data(raw) => {
                    if let Ok(ev) = serde_json::from_str::<Event>(&raw) {
                        for f in r.render(&ev) { yield Ok(SseEvent::default().data(f)); }
                    }
                }
                Frame::Fault(code, message) => {
                    // The guest's own terminal never arrived, so synthesize the
                    // error terminal. `render` emits the same
                    // {"event":"error",...} shape chat-apc used.
                    for f in r.render(&Event::Error { code, message, param: None }) {
                        yield Ok(SseEvent::default().data(f));
                    }
                    break;
                }
                Frame::Done => break,
            }
        }
        // The guest owns the terminal EVENT; the gateway owns only the
        // sentinel. `terminal()` is deliberately not called — it would prepend
        // an OpenAI finish chunk no tree capture contains.
        yield Ok(SseEvent::default().data("[DONE]"));
    };

    tracing::debug!(
        elapsed_ms = started.elapsed().as_millis() as u64,
        "tree committed"
    );
    Sse::new(stream).into_response()
}

/// Like `api_error` but carries `param`, which the ToT validators populate for
/// every bounds rejection (`breadth`, `depth`, `top_p`, `exec`, …).
fn api_error_param(status: StatusCode, code: &str, message: &str, param: Option<&str>) -> Response {
    let mut resp = api_error(status, code, message);
    if let Some(p) = param {
        // Rebuild rather than patch: the body is already serialized.
        let kind = if status.is_client_error() {
            "invalid_request_error"
        } else {
            "server_error"
        };
        resp = (
            status,
            axum::Json(serde_json::json!({
                "error": {"type": kind, "code": code, "message": message, "param": p}
            })),
        )
            .into_response();
    }
    resp
}

/// Owns the process and races its events against client disconnect.
///
/// Identical in shape to the chat driver, with one difference: there is no
/// terminal ASSEMBLY here. The guest's `tree_complete` / `awaiting_selection`
/// is the terminal, so the driver's job ends at recognizing it.
#[allow(clippy::too_many_arguments)]
async fn drive(
    mut proc: Process,
    client: Arc<Client>,
    tx: mpsc::Sender<Frame>,
    mut cancel_rx: oneshot::Receiver<()>,
    mut seq: SeqChecker,
    grace: Duration,
    route: String,
) {
    let pid = proc.id().to_string();
    let mut terminal_seen = false;
    loop {
        tokio::select! {
            _ = &mut cancel_rx => {
                // A tree search is the most expensive thing to leave running:
                // breadth x depth branches plus a scorer generation each.
                tracing::info!(process = %pid, %route, "client disconnected — signalling cancel");
                let started = Instant::now();
                let _ = proc.signal(r#"{"v":1,"c":{"t":"cancel"}}"#).await;
                let deadline = started + grace;
                while Instant::now() < deadline {
                    match timeout(deadline - Instant::now(), proc.recv()).await {
                        Ok(Ok(ProcessEvent::Return(_))) | Ok(Ok(ProcessEvent::Error(_))) => break,
                        Ok(Ok(_)) => continue,
                        _ => break,
                    }
                }
                tracing::info!(
                    process = %pid,
                    elapsed_ms = started.elapsed().as_millis() as u64,
                    "terminating tree process"
                );
                // Authoritative: dropping the client only detaches.
                let _ = client.terminate_process(proc.id()).await;
                let _ = tx.send(Frame::Done).await;
                return;
            }
            ev = proc.recv() => {
                match ev {
                    Ok(ProcessEvent::Message(m)) => {
                        let env = match seq.accept(&m) {
                            Ok(e) => e,
                            Err(pe) => {
                                let _ = tx.send(Frame::Fault("protocol_error".into(), pe.to_string())).await;
                                let _ = client.terminate_process(proc.id()).await;
                                return;
                            }
                        };
                        let decoded = env.decode_event();
                        if tx.send(Frame::Data(env.e.to_string())).await.is_err() { return; }
                        // A guest error post-commit IS the terminal (F1): it
                        // replaces tree_complete rather than preceding it, so
                        // a failed search never renders as a blank success.
                        //
                        // Do NOT break here. The terminal EVENT is not the end
                        // of the exchange — the process still returns, and the
                        // return value carries the reuse diagnostics. Breaking
                        // on the event drops them silently, which makes a ToT
                        // path that cold-starts every turn indistinguishable
                        // from one that reuses. The guest completes both
                        // boundary saves BEFORE its terminal event (§6.1), so
                        // waiting for the return costs nothing.
                        if let Ok(Some(ev)) = decoded {
                            if is_terminal(&ev) || matches!(ev, Event::Error { .. }) {
                                terminal_seen = true;
                            }
                        }
                    }
                    // The guest returned. Its terminal event already went out;
                    // read the result only for the reuse diagnostics, which are
                    // otherwise unobservable — without them a ToT path that
                    // cold-starts every turn looks identical to one that reuses.
                    Ok(ProcessEvent::Return(r)) => {
                        if !terminal_seen {
                            // The guest returned without a terminal event, so
                            // the stream would otherwise end on a bare [DONE]
                            // that reads as success.
                            let _ = tx.send(Frame::Fault(
                                "no_terminal".into(),
                                "tree inferlet returned without a terminal event".into(),
                            )).await;
                            return;
                        }
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&r) {
                            // TODO(kv-residency): as in chat.rs — `reused_tokens`
                            // cannot distinguish a resident boundary from an
                            // evicted one that replayed. A tree search forks
                            // 15-21 contexts, so this is the route where the
                            // distinction matters most and is least visible.
                            tracing::info!(
                                %route,
                                boundary_found = v.get("boundary_found").and_then(|b| b.as_bool()).unwrap_or(false),
                                reused_tokens = v.get("reused_tokens").and_then(|t| t.as_u64()).unwrap_or(0),
                                model = v.get("model").and_then(|m| m.as_str()).unwrap_or(""),
                                synthesized = v.get("synthesized").and_then(|s| s.as_bool()).unwrap_or(false),
                                // Best-of-N resume diagnostics. A think-more
                                // that silently falls back to a cold rebuild
                                // looks identical to a warm one from the
                                // outside, so a gate can only assert on this.
                                resume = v.get("resume").and_then(|r| r.get("kind")).and_then(|k| k.as_str()).unwrap_or(""),
                                resume_validated = v.get("resume").and_then(|r| r.get("validated")).and_then(|b| b.as_bool()).unwrap_or(false),
                                "tree kv reuse"
                            );
                        }
                        break;
                    }
                    Ok(ProcessEvent::Stderr(line)) => {
                        tracing::debug!(process = %pid, %route, "guest: {}", line.trim_end());
                    }
                    Ok(ProcessEvent::Error(e)) => {
                        let _ = tx.send(Frame::Fault("inferlet_error".into(), e)).await;
                        return;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        let _ = tx.send(Frame::Fault("engine_stream_closed".into(), e.to_string())).await;
                        return;
                    }
                }
            }
        }
    }
    let _ = tx.send(Frame::Done).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratio_wire::event::Pick;

    #[test]
    fn tree_complete_is_terminal() {
        assert!(is_terminal(&Event::TreeComplete {
            selected_node_id: Some("tot-n1".into()),
            final_answer: Some("42".into()),
            synthesized: true,
        }));
    }

    /// `AwaitingSelection` terminates an interactive Best-of-N round.
    #[test]
    fn awaiting_selection_is_terminal() {
        assert!(is_terminal(&Event::AwaitingSelection {
            level: 1,
            candidates: vec![Pick {
                id: "bon-n1".into(),
                branch_index: 0,
                snapshot_name: "bon/abc/1/0/def".into(),
            }],
        }));
    }

    #[test]
    fn mid_stream_events_are_not_terminal() {
        assert!(!is_terminal(&Event::TreeStart {
            breadth: 2,
            depth: 1,
            beam_width: 1
        }));
        assert!(!is_terminal(&Event::LevelPruned {
            level: 1,
            kept: vec!["tot-n1".into()]
        }));
        assert!(!is_terminal(&Event::FinalDelta { text: "7".into() }));
        // GenerationMetrics precedes tree_complete in the capture, so treating
        // it as terminal would truncate the stream one frame early.
        assert!(!is_terminal(&Event::GenerationMetrics {
            output_tokens: 283,
            elapsed_s: 14.0,
            tokens_per_sec: 20.0,
        }));
    }

    /// Tree rendering must not add chat opening or closing frames.
    #[test]
    fn the_tree_renderer_emits_no_chat_chunks() {
        let mut r = OpenAiSse::new("tot-0", "qwen", 0).with_tree_metrics(true);
        let frames: Vec<String> = [
            Event::TreeStart {
                breadth: 2,
                depth: 1,
                beam_width: 1,
            },
            Event::NodeStart {
                id: "tot-n1".into(),
                parent_id: "root".into(),
                depth: 1,
                branch_index: 0,
            },
            Event::GenerationMetrics {
                output_tokens: 283,
                elapsed_s: 14.017725042,
                tokens_per_sec: 0.0,
            },
            Event::TreeComplete {
                selected_node_id: Some("tot-n1".into()),
                final_answer: Some("One prime number is 7.".into()),
                synthesized: true,
            },
        ]
        .iter()
        .flat_map(|e| r.render(e))
        .collect();

        assert_eq!(frames.len(), 4, "each tree event renders exactly one frame");
        for f in &frames {
            assert!(
                !f.contains("chat.completion.chunk"),
                "chat chunk leaked into a tree stream: {f}"
            );
            assert!(!f.contains("finish_reason"), "finish_reason leaked: {f}");
        }
        assert!(
            frames[2].contains(r#""tokens_per_sec":20.188725285456343"#),
            "got {}",
            frames[2]
        );
    }
}

fn seq_start() -> SeqChecker {
    SeqChecker::default()
}

/// Drive a control op to its return value.
///
/// No commit membrane and no stream: the whole exchange is one request and one
/// JSON body, so a guest error is a real HTTP status all the way through rather
/// than an in-band frame after a 200.
async fn unary_response(
    client: Arc<Client>,
    mut proc: Process,
    mut seq: SeqChecker,
    first_event_timeout: Duration,
) -> Response {
    loop {
        match timeout(first_event_timeout, proc.recv()).await {
            Err(_) => {
                let _ = client.terminate_process(proc.id()).await;
                return api_error(
                    StatusCode::GATEWAY_TIMEOUT,
                    "inferlet_timeout",
                    "control op did not return",
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
            Ok(Ok(ProcessEvent::Message(m))) => {
                // A control op emits at most one event, and only to report a
                // failure. `param` is carried through: these ops reject with
                // `param: "round_id"` / `"commit.snapshot_name"`, and losing it
                // makes an authorization refusal indistinguishable from a
                // generic 400.
                if let Ok(env) = seq.accept(&m) {
                    if let Ok(Some(Event::Error {
                        code,
                        message,
                        param,
                    })) = env.decode_event()
                    {
                        let _ = client.terminate_process(proc.id()).await;
                        return api_error_param(
                            status_for(&code),
                            &code,
                            &message,
                            param.as_deref(),
                        );
                    }
                }
            }
            Ok(Ok(ProcessEvent::Return(r))) => {
                let body: serde_json::Value =
                    serde_json::from_str(&r).unwrap_or(serde_json::Value::Null);
                if body.is_null() || body.as_object().is_some_and(|o| o.is_empty()) {
                    // `{}` is what the guest returns after emitting a GenError.
                    // Reaching here means the error frame was lost, so fail
                    // rather than acking an operation that may not have run.
                    return api_error(
                        StatusCode::BAD_GATEWAY,
                        "no_output",
                        "control op returned no accounting",
                    );
                }
                tracing::info!(ack = %r, "best-of-n control op");
                return axum::Json(body).into_response();
            }
            Ok(Ok(ProcessEvent::Stderr(line))) => {
                tracing::debug!("guest: {}", line.trim_end());
            }
            Ok(Ok(_)) => {}
        }
    }
}

#[cfg(test)]
mod control_tests {
    use super::is_control_op;
    use serde_json::json;

    #[test]
    fn a_commit_is_a_control_op() {
        assert!(is_control_op(
            &json!({"input": {"commit": {"answer": "x"}}})
        ));
        assert!(is_control_op(&json!({"commit": {"answer": "x"}})));
    }

    #[test]
    fn a_non_empty_release_is_a_control_op() {
        assert!(is_control_op(
            &json!({"input": {"release": ["bon/a/1/0/b"]}})
        ));
    }

    /// An EMPTY release list is not a control op — it would delete nothing and
    /// must not suppress a generative round that happens to carry the field.
    #[test]
    fn an_empty_release_is_not_a_control_op() {
        assert!(!is_control_op(&json!({"input": {"release": []}})));
        assert!(!is_control_op(&json!({"input": {"release": null}})));
    }

    #[test]
    fn a_generative_round_is_not_a_control_op() {
        assert!(!is_control_op(&json!({"input": {"n": 5, "messages": []}})));
        assert!(!is_control_op(&json!({"input": {"commit": null}})));
    }
}
