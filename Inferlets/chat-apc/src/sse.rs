//! SSE wire-format helpers + meta-frame schema (`model_loading` /
//! `model_ready`) per the v1 design doc.
//!
//! `Emitter` owns the response body half (after `start_response`) and
//! exposes one method per frame type. Every emit writes the JSON +
//! `\n\n` delimiter and flushes — the inferlet must surface content
//! token-by-token, so any path that buffers (default `wstd` body)
//! would defeat the streaming UX the GUI's clockwise-fill loading
//! indicator depends on.
//!
//! Emit calls return [`EmitError`] so handlers can distinguish a
//! disconnected client (silent end-of-stream) from a serializer
//! failure (host-visible bug). The previous `Result<(), ()>` shape
//! collapsed both into the same `()`, masking serializer regressions
//! under what looked like routine peer disconnects.

use serde::Serialize;
use wstd::http::body::{BodyForthcoming, IncomingBody, OutgoingBody};
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};
use wstd::io::AsyncWrite;

/// Cap on request-body bytes the chat handler will buffer. 1 MiB is
/// well above any realistic OpenAI-shape chat body (each message
/// content is plain text; even 50 turns of long-form prose fit
/// comfortably). The handler returns 413 once the cap is reached, so
/// a misbehaving client can't OOM the inferlet (F6).
pub const CHAT_MAX_BODY: usize = 1 << 20; // 1 MiB

/// Cap on `/v1/inferlet` dispatch bodies. Higher than chat because
/// the `input` payload is inferlet-defined and may carry larger
/// state-replay blobs.
pub const DISPATCH_MAX_BODY: usize = 1 << 18; // 256 KiB

// =============================================================================
// EmitError (F10)
// =============================================================================

/// Distinguishes the two ways an SSE emit can fail. Handlers
/// silence `Disconnected` (it's the normal HTTP end-of-stream signal
/// when a client closes), but `Serialize` indicates a host-visible
/// bug — a struct field that broke our hand-checked
/// "cannot-fail-to-serialize" invariant.
///
/// `From<std::io::Error>` + `From<serde_json::Error>` are provided so
/// `?` propagation reads naturally in handler code.
#[derive(Debug)]
pub enum EmitError {
    /// The peer closed the connection mid-stream. Treat as end-of-stream.
    Disconnected,
    /// The frame could not be serialized. Indicates a programmer
    /// error in our own response schemas, not a peer problem.
    Serialize(serde_json::Error),
}

impl From<std::io::Error> for EmitError {
    fn from(_: std::io::Error) -> Self {
        EmitError::Disconnected
    }
}

impl From<serde_json::Error> for EmitError {
    fn from(e: serde_json::Error) -> Self {
        EmitError::Serialize(e)
    }
}

// =============================================================================
// Emitter
// =============================================================================

/// Streaming-friendly SSE response body. Construct via [`Emitter::start`].
pub struct Emitter {
    body: OutgoingBody,
}

impl Emitter {
    /// Open an SSE response. Sets `Content-Type: text/event-stream` and
    /// `Cache-Control: no-cache` (browsers + curl `-N` rely on the
    /// latter to skip transparent buffering).
    pub fn start(res: Responder) -> Self {
        let response = Response::builder()
            .header("Content-Type", "text/event-stream")
            .header("Cache-Control", "no-cache")
            .body(BodyForthcoming)
            .unwrap();
        Self {
            body: res.start_response(response),
        }
    }

    /// Emit a single SSE frame whose `data:` payload is the JSON
    /// encoding of `value`.
    pub async fn emit_json<T: Serialize>(&mut self, value: &T) -> Result<(), EmitError> {
        let json = serde_json::to_string(value)?;
        self.emit_raw(&json).await
    }

    /// Emit a single SSE frame whose `data:` payload is `payload`
    /// verbatim — used for the terminal `[DONE]` sentinel and any
    /// caller-formatted JSON.
    pub async fn emit_raw(&mut self, payload: &str) -> Result<(), EmitError> {
        let mut frame = String::with_capacity(payload.len() + 8);
        frame.push_str("data: ");
        frame.push_str(payload);
        frame.push_str("\n\n");
        self.body.write_all(frame.as_bytes()).await?;
        self.body.flush().await?;
        Ok(())
    }

    /// Consume the emitter and finalize the HTTP response.
    pub fn finish(self) -> Finished {
        Finished::finish(self.body, Ok(()), None)
    }
}

// =============================================================================
// Meta-frame schema (v1 design doc §SSE meta-frame schema)
// =============================================================================

// `data: {"event":"model_loading","loaded_bytes":N,"total_bytes":M,
// "eta_s":…}` is part of the wire schema but not emitted in v1 —
// pie loads models at engine boot, so the inferlet has no in-process
// progress source. The frame returns when pie surfaces a load-progress
// WIT import (a follow-up); until then handlers skip directly to
// `ModelReady`. Re-add `ModelLoading` here when that lands.

/// `data: {"event":"model_ready"}` — terminal meta-frame; transitions
/// the GUI's loading indicator to "ready" and (for chat-completions)
/// signals "OpenAI content frames follow".
#[derive(Serialize)]
pub struct ModelReady {
    pub event: &'static str,
}

impl ModelReady {
    pub const fn new() -> Self {
        Self {
            event: "model_ready",
        }
    }
}

/// JSON-shape warning frame used inside SSE streams for non-fatal
/// signals that the caller should see in-band (I5). Pattern:
/// `data: {"event":"warning","code":…,"message":…}`. Distinct from
/// [`SseError`] (`event:"error"`) so consumers can filter on the
/// event type — warnings don't imply the response will fail.
#[derive(Serialize)]
pub struct SseWarning<'a> {
    pub event: &'static str,
    pub code: &'a str,
    pub message: &'a str,
}

impl<'a> SseWarning<'a> {
    pub fn new(code: &'a str, message: &'a str) -> Self {
        Self {
            event: "warning",
            code,
            message,
        }
    }
}

/// JSON-shape error frame used inside SSE streams when the request
/// already committed (headers sent, body in flight) and we can't fall
/// back to a 4xx/5xx. Pattern: `data: {"event":"error","code":…,"message":…}`.
#[derive(Serialize)]
pub struct SseError<'a> {
    pub event: &'static str,
    pub code: &'a str,
    pub message: &'a str,
    /// Set via [`SseError::with_dedup_counts`]. Same N3 motivation:
    /// surface raw counts as structured fields when the diag carries
    /// dedup-capped state, so log shippers / dashboards don't parse the
    /// message string.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub distinct_modes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overflow_modes: Option<usize>,
}

impl<'a> SseError<'a> {
    pub fn new(code: &'a str, message: &'a str) -> Self {
        Self {
            event: "error",
            code,
            message,
            distinct_modes: None,
            overflow_modes: None,
        }
    }

    pub fn with_dedup_counts(mut self, distinct: usize, overflow: usize) -> Self {
        self.distinct_modes = Some(distinct);
        self.overflow_modes = Some(overflow);
        self
    }
}

/// `data: {"event":"usage","prompt_tokens":P,"completion_tokens":C,
/// "total_tokens":T,"context_window":W}` — engine-true token accounting
/// for the conversation context (#711). Emitted once, between the terminal
/// chunk and `[DONE]`, so the GUI's context meter can render used/window.
///
/// `total_tokens` (== the engine-true context occupancy: committed +
/// working + buffered tokens) is the numerator; `context_window` is the
/// effective KV budget in tokens (`budget_pages × tokens_per_page`) and is
/// the denominator. `context_window` is omitted when the budget is unknown
/// (context not yet resident), so the app falls back rather than dividing
/// by zero. A distinct `event:"usage"` keeps the demux off the OpenAI
/// content-chunk path — generic clients ignore the frame.
#[derive(Serialize)]
pub struct SseUsage {
    pub event: &'static str,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u32>,
}

impl SseUsage {
    pub fn new(prompt_tokens: u32, completion_tokens: u32, context_window: Option<u32>) -> Self {
        Self {
            event: "usage",
            prompt_tokens,
            completion_tokens,
            total_tokens: prompt_tokens.saturating_add(completion_tokens),
            context_window,
        }
    }
}

/// The `[DONE]` terminator OpenAI's SSE chat-completions schema ends
/// every stream with. Clients pin on this exact byte sequence.
pub async fn emit_done(em: &mut Emitter) -> Result<(), EmitError> {
    em.emit_raw("[DONE]").await
}

/// `emit_done` with discipline: peer-disconnect is silent (expected
/// EOF), but any other failure (serialize bug, IO write failure)
/// gets `eprintln!`'d before swallowing — otherwise an
/// OpenAI/JS SDK iterator pinned on `[DONE]` hangs until socket
/// timeout with zero host signal.
///
/// ## Embedder contract for diagnostic visibility (G6 / H5)
///
/// Every `eprintln!` in this crate — here, `now_unix_secs` (clock
/// skew), `id_seed` (entropy fallback), the F7 body-read site, the
/// F9 tool-decoder-disabled site, the H4 tool-warning-frame
/// dropped-on-disconnect site, and the F6 serialize-recover
/// sites — emits to wasm `stderr` via `wasi:cli/stderr`.
///
/// **Verified embedder reality (vs Vendor/pie @ b4601f5):** the
/// daemon request path does NOT route component stderr to operators.
/// `runtime/src/daemon.rs::handle_request` instantiates each
/// per-request component with `capture_outputs = false`
/// (`daemon.rs:216`), and `instance.rs:100-103` only wires
/// `builder.stderr(LogStream::new_stderr(id))` when `capture_outputs`
/// is true. With it false, wasm stderr falls through to wasmtime's
/// default SINK and is DISCARDED inside pie — it never becomes a
/// `ProcessEvent::Stderr`, and `handle_launch_daemon` attaches no
/// client to receive one anyway. So these `eprintln!`s are visible
/// only under `pie run` / `launch_process` (`capture_outputs = true`,
/// the CLI/dev path — `run_cmd.rs:226`), NOT in the pie-mac daemon
/// deployment. The earlier "subscribe to `ProcessEvent::Stderr` in
/// PieControlLauncher" plan is INFEASIBLE for daemons: there are no
/// such events to subscribe to. Fixing this at the source (route
/// daemon stderr to pie-server's own log) is tracked as a pie-side
/// follow-up.
///
/// ## In-band path is the production contract (I5)
///
/// Because stderr is discarded for daemons, the operator-visible
/// diagnostic surface IS the HTTP response. Request-scoped failures
/// (tool-decoder mid-turn disable, F7 body reads, model load) ride
/// the response envelope — `PartialError` for the non-stream
/// OpenAI-shape `error` block, `SseError` for the streaming
/// `{event:"error",...}` meta-frame.
///
/// Launch-scoped infrastructure failures (id_seed entropy fallback,
/// now_unix_secs clock skew) are recorded into a `LAUNCH_DIAGS`
/// registry (`crate::chat::completions`) and drained at the start of
/// each chat-completion request: the stream branch emits them as
/// `{event:"warning",code,message}` SSE meta-frames (see `SseWarning`)
/// between `model_ready` and the role chunk; non-stream surfaces them
/// in the `ChatCompletion.warnings: Vec` field; and the
/// `X-ChatAPC-Launch-Diags` response header carries them on every
/// response. One-shot per launch.
///
/// The F7 `read_body` transport `io::ErrorKind` rides in-band only on
/// the CLI / `pie run` / streaming-guest path — `body_error_response`
/// maps it to a stable `error.code` in the 400 envelope
/// (`transport_error_code`).
/// This 400 is UNREACHABLE on the pie-mac daemon path: pie's daemon
/// host pre-collects the whole request body
/// (`Vendor/pie/runtime/src/daemon.rs:207`, `BodyExt::collect`) BEFORE
/// instantiating the guest, so a real transport-read failure surfaces
/// as pie's host-level error at `daemon.rs:209`, never reaching
/// `read_body` -> `BodyError::Transport`. Daemon-side visibility of
/// such failures is the pie-side follow-up work.
///
/// Residual stderr-ONLY sites — structurally undeliverable in-band,
/// so dev-only by nature (not blocked on the pie-side follow-up):
/// - `emit_done_logged` Serialize failures (post-stream; the SSE
///   channel is already closed). NOTE: post-stream *IO* write failures
///   do NOT reach stderr either — `From<io::Error>` (above) collapses
///   every IO error to `EmitError::Disconnected`, which
///   `emit_done_logged` silently swallows; only `Serialize` hits the
///   `eprintln!`. Telling a genuine mid-stream IO error apart from
///   peer-EOF would need a separate `EmitError::Io` variant (out of
///   scope here).
/// - The H4 `tool_decode_disabled` meta-frame Disconnected branch
///   (peer is gone by definition).
///
/// The pie-side daemon-stderr surfacing would make even these
/// dev-only sites operator-visible without any chat-apc change, and
/// fix the same gap for every other inferlet.
pub async fn emit_done_logged(em: &mut Emitter, site: &str) {
    match emit_done(em).await {
        Ok(()) => {}
        Err(EmitError::Disconnected) => {}
        Err(e) => eprintln!("[chat-apc] emit_done at {site} failed: {e:?}"),
    }
}

// =============================================================================
// Non-SSE helpers (used by error paths that haven't committed a body)
// =============================================================================

/// Build a single JSON response with an OpenAI-shape `error` envelope.
/// Status codes follow OpenAI conventions: 400 invalid_request,
/// 404 model_not_found, 409 target_mismatch, 413 payload_too_large,
/// 500 server_error.
pub fn json_error(
    status: u16,
    code: &str,
    message: &str,
) -> Response<wstd::http::body::BoundedBody<Vec<u8>>> {
    let body = serde_json::json!({
        "error": {
            "type": match status {
                400 => "invalid_request_error",
                404 => "not_found_error",
                409 => "conflict_error",
                413 => "payload_too_large_error",
                _ => "server_error",
            },
            "code": code,
            "message": message,
            "param": serde_json::Value::Null,
        }
    });
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(body.to_string().into_body())
        .unwrap()
}

// =============================================================================
// Body reader (F6 — bounded)
// =============================================================================

/// Errors `read_body` can return.
///
/// `Transport` carries the underlying `io::ErrorKind` so operators
/// debugging slowloris vs TLS reset vs mid-body abort can tell them
/// apart — collapsing all transport failures into a single opaque
/// variant made root cause untraceable. The kind maps to a
/// stable `error.code` in the in-band 400 envelope (`body_error_response`
/// → `transport_error_code`) on the streaming-guest path. On the
/// pie-mac daemon path this arm is unreachable — pie collects the
/// body host-side before the guest runs (see `transport_error_code`
/// doc), so the failure is pie's host-level error, not this 400.
#[derive(Debug)]
pub enum BodyError {
    /// Transport died mid-read. Map to 400. The `ErrorKind` becomes a
    /// stable `error.code` (e.g. `transport_broken_pipe` vs
    /// `transport_timed_out`) so callers can branch on the mode.
    Transport(std::io::ErrorKind),
    /// Body exceeded the caller's `max_bytes` cap. Map to 413.
    TooLarge,
}

/// Read an entire `IncomingBody` into `buf`, refusing to accumulate
/// past `max_bytes`. The chat handler caps at 1 MiB; load at 4 KiB.
///
/// Returns `Err(BodyError::TooLarge)` the first time the cap would
/// be exceeded — the inferlet drops the remaining bytes silently
/// (the connection is already in a half-broken state since the
/// client expected to upload more). This is acceptable: 413 is the
/// HTTP spec's "we refuse to read further" status.
pub async fn read_body(
    body: &mut IncomingBody,
    buf: &mut Vec<u8>,
    max_bytes: usize,
) -> Result<(), BodyError> {
    use wstd::io::AsyncRead;
    let mut chunk = [0u8; 4096];
    loop {
        match body.read(&mut chunk).await {
            Ok(0) => return Ok(()),
            Ok(n) => {
                if buf.len() + n > max_bytes {
                    return Err(BodyError::TooLarge);
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            Err(e) => {
                let kind = e.kind();
                // F7: log the full error to stderr for dev/CLI triage
                // (`pie run` only — discarded for daemons, see
                // emit_done_logged doc). The discriminating
                // `io::ErrorKind` rides in-band in the 400 envelope via
                // `body_error_response` on the streaming-guest path. On
                // the daemon path this arm is unreachable: pie collects
                // the body host-side before instantiating the guest
                // (`Vendor/pie/runtime/src/daemon.rs:207`), so a
                // transport failure becomes pie's host-level error, not
                // this 400 (daemon-side visibility is a pie-side follow-up).
                eprintln!("[chat-apc] body read failed: kind={kind:?} err={e}");
                return Err(BodyError::Transport(kind));
            }
        }
    }
}

/// Map a [`BodyError`] to an HTTP error response. Caller uses
/// `responder.respond(body_error_response(...)).await` on the
/// pre-handler error path.
pub fn body_error_response(err: BodyError) -> Response<wstd::http::body::BoundedBody<Vec<u8>>> {
    match err {
        BodyError::Transport(kind) => json_error(
            400,
            transport_error_code(kind),
            &transport_error_message(kind),
        ),
        BodyError::TooLarge => json_error(
            413,
            "payload_too_large",
            "Request body exceeds the endpoint cap",
        ),
    }
}

/// Map a transport read failure to a stable, machine-branchable
/// `error.code`.
///
/// SDK consumers that need to discriminate transport modes
/// ("slowloris vs TLS reset vs mid-body abort") branch on this code,
/// NOT on free-text in `message`. `std::io::ErrorKind` is
/// `#[non_exhaustive]` and its `Debug` labels carry no stability
/// guarantee, so we pin the kinds we care about to fixed snake_case
/// codes and collapse everything else to `transport_error`.
///
/// This only fires on the streaming-guest path (`pie run` / a
/// guest that reads its own body). It does NOT reach the pie-mac
/// daemon path: pie pre-collects the request body host-side
/// (`Vendor/pie/runtime/src/daemon.rs:207`) before the guest runs, so
/// a transport failure there is pie's host-level error, not this 400.
fn transport_error_code(kind: std::io::ErrorKind) -> &'static str {
    use std::io::ErrorKind;
    match kind {
        ErrorKind::ConnectionReset => "transport_connection_reset",
        ErrorKind::UnexpectedEof => "transport_unexpected_eof",
        ErrorKind::TimedOut => "transport_timed_out",
        ErrorKind::BrokenPipe => "transport_broken_pipe",
        _ => "transport_error",
    }
}

/// Render the client-facing 400 message for a transport read failure.
///
/// Human-readable only: it names the `io::ErrorKind` to keep
/// "slowloris vs TLS reset vs mid-body abort" debuggable from the
/// response alone. SDKs must NOT branch on this free text — the
/// stable discriminator is `error.code` (see `transport_error_code`).
fn transport_error_message(kind: std::io::ErrorKind) -> String {
    format!("Failed to read request body (transport error: {kind:?})")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::ErrorKind;

    #[test]
    fn transport_error_code_is_stable_and_machine_branchable() {
        // SDKs discriminate transport modes on `error.code`, NOT on
        // free-text in `message`. Pin each known kind to its stable
        // snake_case code so a future refactor can't silently drift the
        // wire contract.
        for (kind, code) in [
            (ErrorKind::ConnectionReset, "transport_connection_reset"),
            (ErrorKind::UnexpectedEof, "transport_unexpected_eof"),
            (ErrorKind::TimedOut, "transport_timed_out"),
            (ErrorKind::BrokenPipe, "transport_broken_pipe"),
        ] {
            assert_eq!(transport_error_code(kind), code);
        }
    }

    #[test]
    fn transport_error_code_collapses_unknown_kinds() {
        // io::ErrorKind is #[non_exhaustive]; kinds we don't pin fall
        // back to the generic `transport_error` rather than leaking an
        // unstable Debug label into the wire contract.
        assert_eq!(
            transport_error_code(ErrorKind::NotConnected),
            "transport_error"
        );
        assert_eq!(transport_error_code(ErrorKind::Other), "transport_error");
    }

    #[test]
    fn transport_error_message_carries_the_kind() {
        // The human-readable message still names the kind for triage,
        // but it is NOT the branch surface — that's `error.code` above.
        for kind in [
            ErrorKind::ConnectionReset,
            ErrorKind::UnexpectedEof,
            ErrorKind::TimedOut,
            ErrorKind::BrokenPipe,
        ] {
            let msg = transport_error_message(kind);
            assert!(msg.starts_with("Failed to read request body"));
            assert!(
                msg.contains(&format!("{kind:?}")),
                "message {msg:?} must name the ErrorKind {kind:?}",
            );
        }
    }
}
