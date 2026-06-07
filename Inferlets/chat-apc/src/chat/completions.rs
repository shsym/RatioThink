//! `POST /v1/chat/completions` — OpenAI-shape chat completions.
//!
//! Wire body (subset enforced):
//!
//! ```text
//! {
//!   "model": "<id>",                  // required
//!   "messages": [{role, content}, …], // required, non-empty
//!   "stream": true | false,           // default false
//!   "temperature": f32,               // default 0.7, range [0.0, 2.0]
//!   "top_p": f32,                     // default 1.0, range (0.0, 1.0]
//!   "max_tokens": usize               // default 1024, range [1, MAX]
//! }
//! ```
//!
//! Streaming branch (`stream: true`):
//! - `Content-Type: text/event-stream`.
//! - Model is loaded **before** the SSE response is opened — so a
//!   load failure returns a 5xx JSON envelope, not a deceptive
//!   `model_ready` followed by an error frame (F9).
//! - Stream is prefixed with `data: {"event":"model_ready"}\n\n` so
//!   the GUI's `ChatEvent.modelReady` arm fires before any content.
//!   Real `model_loading` frames are deferred (pie loads models at
//!   engine boot — no per-request load progress surfaced to the
//!   inferlet yet).
//! - One OpenAI-shape `chat.completion.chunk` frame per visible
//!   delta. First content frame carries `delta.role="assistant"`
//!   (OpenAI parity); subsequent frames omit `role`.
//! - One terminal chunk with `finish_reason` set, followed by the
//!   literal `data: [DONE]\n\n` sentinel.
//! - **Failure modes are explicit** (review F1/F2/F3/F5/F8): a
//!   `Generator::next` error, decoder error, or chat-template
//!   `Interrupt` aborts the loop, emits a terminal chunk with
//!   `finish_reason: "error"`, and a `{"event":"error",…}` meta-
//!   frame with the diagnostic before `[DONE]`. No code path reports
//!   abnormal termination as a clean `"stop"`.
//!
//! Non-streaming branch (`stream: false`): generates token-by-token
//! so the `finish_reason` can distinguish natural stop from
//! max-tokens cap, returning a single OpenAI-shape `chat.completion`
//! JSON 200.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use inferlet::chat;
use inferlet::Context;
use inferlet::GrammarConstraint;
use inferlet::inference::SlotOutput;
use inferlet::model::Model;
use inferlet::runtime;
use serde::{Deserialize, Serialize};
use wstd::http::body::IncomingBody;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Request, Response};

use super::apc::{ReasoningDecoder, ToolUseDecoder};
use super::generate::{self, DecodeStrategy};
use super::spec::{SpecConfig, SpecMetrics};
use crate::sse::{self, EmitError, Emitter, SseError};

// =============================================================================
// Non-terminal emit handling (F10b)
// =============================================================================

/// Try emit a frame at a **non-terminal** site (model_ready, role
/// delta, content delta). The stream isn't done yet, so callers
/// can't just swallow errors:
///
/// * `Ok(())`                       → continue.
/// * `Err(Disconnected)`            → silently end (peer gone; no
///                                    point trying to push more bytes).
/// * `Err(Serialize(e))`            → invariant violation in our own
///                                    schemas. Push an inline
///                                    `{"event":"error","code":"serialize_bug",…}`
///                                    meta-frame + `[DONE]` so any
///                                    client still attached gets a
///                                    signal, then end.
///
/// The macro returns `em.finish()` from the enclosing function on
/// both error variants, so callers stop generation immediately.
/// Embeds the eprintln so review F10 (stderr visibility for our own
/// bugs) holds across every non-terminal site.
macro_rules! try_emit {
    ($em:expr, $frame:expr, $site:literal) => {
        match $em.emit_json($frame).await {
            Ok(()) => {}
            Err(EmitError::Disconnected) => return $em.finish(),
            Err(EmitError::Serialize(e)) => {
                eprintln!("[chat-apc] {} serialize bug: {}", $site, e);
                let msg = e.to_string();
                // L5: the operator surface here is the in-band
                // `SseError` meta-frame emitted just below — these
                // emits can themselves fail, and the eprintln is the
                // dev-only last resort for that double-failure (wasm
                // stderr is discarded on the daemon path, see ).
                // Disconnected is silent — peer is gone and there's
                // nothing useful left to do.
                match $em
                    .emit_json(&SseError::new("serialize_bug", &msg))
                    .await
                {
                    Ok(()) => {}
                    Err(EmitError::Disconnected) => {}
                    Err(EmitError::Serialize(e2)) => {
                        eprintln!(
                            "[chat-apc] {} serialize_bug meta-frame ALSO failed \
                             to serialize: {e2} (original: {msg})",
                            $site,
                        );
                    }
                }
                sse::emit_done_logged(&mut $em, "try_emit_serialize_recover").await;
                return $em.finish();
            }
        }
    };
}

// =============================================================================
// Defaults + bounds (F7)
// =============================================================================

const DEFAULT_TEMPERATURE: f32 = 0.7;
const DEFAULT_TOP_P: f32 = 1.0;
const DEFAULT_MAX_TOKENS: usize = 1024;

/// Inclusive upper bound on `temperature`. Above this, samplers
/// produce essentially uniform garbage; reject rather than emit
/// unreadable tokens.
const MAX_TEMPERATURE: f32 = 2.0;
/// Inclusive upper bound on `top_p` (the canonical nucleus cap).
const MAX_TOP_P: f32 = 1.0;
/// Fallback ceiling on `max_tokens`, used only when the engine reports
/// no capacity (`runtime::max-output-tokens()` == 0 — e.g. no model
/// registered yet). In normal operation the live engine value — its
/// launch-time KV-cache capacity, which is memory-aware — is used
/// instead (see `max_output_ceiling`). 8192 is a conservative cap well
/// above any sensible chat reply length.
const MAX_OUTPUT_TOKENS_FALLBACK: usize = 8192;

/// Inclusive bounds on the #418 speculation knobs. Out-of-range values
/// are rejected at the 400 boundary (see `validate_sampling`), mirroring
/// the `max_tokens` contract; `SpecRequest::to_config`'s `.clamp` then
/// stays only as a redundant safety net.
const MIN_LEADER_LEN: usize = 1;
const MAX_LEADER_LEN: usize = 8;
const MIN_DRAFT_LEN: usize = 1;
const MAX_DRAFT_LEN: usize = 16;

// =============================================================================
// Request schema
// =============================================================================

#[derive(Deserialize)]
pub struct ChatCompletionsRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
    pub max_tokens: Option<usize>,
    /// OpenAI-shape tool list. Each entry is `{type:"function",
    /// function:{name, description?, parameters}}`. Forwarded through
    /// the chat template via `inferlet::tools::equip_prefix`.
    #[serde(default)]
    pub tools: Option<Vec<ToolSchema>>,
    /// OpenAI `tool_choice` — accepted but not yet enforced (no
    /// constrained-grammar plumbing in v1). Kept on the schema so
    /// clients don't see a deserialization error.
    #[serde(default)]
    #[allow(dead_code)]
    pub tool_choice: Option<serde_json::Value>,
    /// chat-apc extension: opt-in linear Cacheback speculative decoding.
    /// Absent → normal decode, byte-identical to pre-speculation
    /// behavior. Present → the `spec_metrics` block is returned and,
    /// when `enabled` + greedy (`temperature == 0`), drafting engages.
    #[serde(default)]
    pub speculation: Option<SpecRequest>,
}

/// Request-side speculation knobs (chat-apc extension). Dimensions
/// default to the paper-optimal LL=1 / FL=3 and are clamped to safe
/// bounds. See [`super::spec`].
#[derive(Deserialize, Clone)]
pub struct SpecRequest {
    #[serde(default)]
    pub enabled: bool,
    pub leader_len: Option<usize>,
    pub draft_len: Option<usize>,
}

impl SpecRequest {
    fn to_config(&self) -> SpecConfig {
        let d = SpecConfig::default();
        SpecConfig {
            // Redundant safety net: `validate_sampling` already rejects
            // out-of-range values at the 400 boundary before this runs.
            leader_len: self
                .leader_len
                .unwrap_or(d.leader_len)
                .clamp(MIN_LEADER_LEN, MAX_LEADER_LEN),
            draft_len: self
                .draft_len
                .unwrap_or(d.draft_len)
                .clamp(MIN_DRAFT_LEN, MAX_DRAFT_LEN),
            ..d
        }
    }
}

#[derive(Deserialize, Serialize, Clone)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

/// OpenAI tool entry. Only `function`-type tools are recognized; the
/// `type` discriminator is parsed but other variants are ignored at
/// equip time (the SDK has no surface for non-function tools).
#[derive(Deserialize, Clone)]
pub struct ToolSchema {
    #[serde(rename = "type", default)]
    pub kind: String,
    pub function: ToolFunction,
}

#[derive(Deserialize, Clone)]
pub struct ToolFunction {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub parameters: serde_json::Value,
}

// =============================================================================
// Response schemas
// =============================================================================

#[derive(Serialize)]
struct ChatCompletionChunk<'a> {
    id: &'a str,
    object: &'static str,
    created: i64,
    model: &'a str,
    choices: Vec<ChunkChoice<'a>>,
}

#[derive(Serialize)]
struct ChunkChoice<'a> {
    index: u32,
    delta: ChunkDelta<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    finish_reason: Option<&'static str>,
}

#[derive(Serialize, Default)]
struct ChunkDelta<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<&'a str>,
    /// OpenAI `reasoning_content` delta — only emitted on frames
    /// produced by the reasoning decoder. Mirrors the field newer
    /// OpenAI thinking-model APIs use to surface the model's
    /// scratchpad separately from visible content.
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_content: Option<&'a str>,
    /// OpenAI `tool_calls` delta. Emitted once per detected tool call
    /// on the same frame that flips `finish_reason` to `"tool_calls"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_calls: Option<Vec<ChunkToolCall<'a>>>,
}

#[derive(Serialize)]
struct ChunkToolCall<'a> {
    index: u32,
    id: &'a str,
    #[serde(rename = "type")]
    kind: &'static str,
    function: ChunkToolCallFunction<'a>,
}

#[derive(Serialize)]
struct ChunkToolCallFunction<'a> {
    name: &'a str,
    arguments: &'a str,
}

#[derive(Serialize)]
struct ChatCompletion<'a> {
    id: &'a str,
    object: &'static str,
    created: i64,
    model: &'a str,
    choices: Vec<NonStreamChoice<'a>>,
    /// OpenAI-extension partial-error block. Present only when
    /// generation aborted AFTER producing visible content or a
    /// pending tool call — the choice's `finish_reason` is `"error"`
    /// and this carries the diagnostic so the caller can distinguish
    /// "got partial reply, model died" from "clean stop".
    /// Pure-failure cases (no tokens produced) skip the body entirely
    /// and return 500 `json_error` instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<PartialError<'a>>,
    /// I5: in-band one-shot launch diagnostics
    /// (`clock_skew` / `entropy_degraded` / etc.) drained from the
    /// LAUNCH_DIAGS registry on this request. Otherwise these would
    /// live only in `eprintln!` and be dropped in the pie-mac
    /// production deployment (see `crate::sse::emit_done_logged`
    /// doc + ). Skipped from serialization when empty.
    #[serde(skip_serializing_if = "Option::is_none")]
    warnings: Option<Vec<NonStreamWarning<'a>>>,
    /// chat-apc extension: speculative-decode metrics. Present only when
    /// the request included a `speculation` block, so normal responses
    /// stay byte-identical. Carries draft accounting + throughput, plus
    /// `fallback_reason` when speculation was requested but inactive.
    #[serde(skip_serializing_if = "Option::is_none")]
    spec_metrics: Option<SpecMetricsReport>,
}

// =============================================================================
// Speculative-decode metrics (ticket #418)
// =============================================================================

/// Structured speculation metrics, emitted on the non-stream response as
/// `spec_metrics` and on the SSE stream as a terminal `spec_metrics`
/// frame. `generated_tokens` / `decode_steps` / throughput are measured
/// by the transport loop; the draft accounting comes from the drafter's
/// shared [`SpecMetrics`].
#[derive(Serialize)]
struct SpecMetricsReport {
    /// Whether drafting actually engaged this turn.
    enabled: bool,
    /// Why speculation did not engage despite being requested
    /// (`disabled`, `non_greedy_sampling`); `None` when it engaged.
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback_reason: Option<&'static str>,
    generated_tokens: usize,
    decode_steps: usize,
    proposed_draft_tokens: usize,
    accepted_draft_tokens: usize,
    rejected_draft_tokens: usize,
    avg_tokens_per_step: f64,
    decode_tokens_per_sec: f64,
    leader_len: usize,
    draft_len: usize,
}

impl SpecMetricsReport {
    fn build(
        enabled: bool,
        fallback_reason: Option<&'static str>,
        dims: (usize, usize),
        spec: SpecMetrics,
        generated_tokens: usize,
        decode_steps: usize,
        elapsed: Duration,
    ) -> Self {
        let secs = elapsed.as_secs_f64();
        Self {
            enabled,
            fallback_reason,
            generated_tokens,
            decode_steps,
            proposed_draft_tokens: spec.proposed,
            accepted_draft_tokens: spec.accepted,
            rejected_draft_tokens: spec.rejected,
            avg_tokens_per_step: if decode_steps > 0 {
                generated_tokens as f64 / decode_steps as f64
            } else {
                0.0
            },
            decode_tokens_per_sec: if secs > 0.0 {
                generated_tokens as f64 / secs
            } else {
                0.0
            },
            leader_len: dims.0,
            draft_len: dims.1,
        }
    }

    /// One parseable line for the smoke harness (mirrors
    /// `text-completion-spec`'s `SPEC_STATS`). wasm stderr is dropped on
    /// the daemon path, so this is dev/smoke-tier only — the wire surface
    /// is the SSE frame / JSON field.
    fn log_spec_stats(&self) {
        eprintln!(
            "SPEC_STATS enabled={} fallback={} generated_tokens={} decode_steps={} \
             proposed={} accepted={} rejected={} avg_tokens_per_step={:.3} \
             decode_tokens_per_sec={:.2}",
            self.enabled,
            self.fallback_reason.unwrap_or("none"),
            self.generated_tokens,
            self.decode_steps,
            self.proposed_draft_tokens,
            self.accepted_draft_tokens,
            self.rejected_draft_tokens,
            self.avg_tokens_per_step,
            self.decode_tokens_per_sec,
        );
    }
}

/// SSE wrapper: tags the report with `event:"spec_metrics"` so the GUI's
/// frame router can branch on it like the other meta-frames.
#[derive(Serialize)]
struct SpecMetricsSse<'a> {
    event: &'static str,
    #[serde(flatten)]
    report: &'a SpecMetricsReport,
}

/// Decide the decode strategy from the request, greedy gate, and whether
/// a tool call is forced. Returns `(strategy, fallback_reason,
/// want_metrics, (leader_len, draft_len))`. `want_metrics` is true
/// whenever the caller sent a `speculation` block, so a requested-but-
/// inactive run still reports why (no silent no-op).
///
/// `forced_tool` gates speculation OFF: when `tool_choice` forces a call
/// the sampler is constrained to the tool-call grammar, and the drafter's
/// verify must not run against a grammar-constrained sampler. Forced-tool
/// is checked before the greedy gate so a forced+greedy request reports
/// `tool_choice_forced`, not speculative.
fn plan_strategy(
    spec: Option<&SpecRequest>,
    greedy: bool,
    forced_tool: bool,
) -> (DecodeStrategy, Option<&'static str>, bool, (usize, usize)) {
    match spec {
        None => (DecodeStrategy::Plain, None, false, (0, 0)),
        Some(s) if s.enabled && forced_tool => {
            (DecodeStrategy::Plain, Some("tool_choice_forced"), true, (0, 0))
        }
        Some(s) if s.enabled && greedy => {
            let cfg = s.to_config();
            let dims = (cfg.leader_len, cfg.draft_len);
            (DecodeStrategy::Speculative(cfg), None, true, dims)
        }
        Some(s) if s.enabled => {
            (DecodeStrategy::Plain, Some("non_greedy_sampling"), true, (0, 0))
        }
        Some(_) => (DecodeStrategy::Plain, Some("disabled"), true, (0, 0)),
    }
}

/// Stand-alone tokenization of the prompt to seed the drafter's dynamic
/// table. Exact chat-template alignment isn't required — accepted tokens
/// grow the cache as generation proceeds (see `super::spec`).
fn seed_tokens_from(model: &Model, messages: &[ChatMessage]) -> Vec<u32> {
    let joined = messages
        .iter()
        .map(|m| m.content.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    model.tokenizer().encode(&joined)
}

#[derive(Serialize)]
struct NonStreamWarning<'a> {
    code: &'a str,
    message: &'a str,
}

/// OpenAI-shape error envelope, returned at the JSON root of a
/// `ChatCompletion` when the loop produced partial content before
/// failing (or completed normally with a warning). Field order +
/// names match `openai-python`'s `APIError` surface so SDK consumers
/// see `response.error.{type,code,message,param}` natively.
#[derive(Serialize)]
struct PartialError<'a> {
    /// `"server_error"` for fatal `error_diag`; `"warning"` for the
    /// G2 `tool_decode_disabled` non-fatal case. OpenAI defines
    /// `invalid_request_error`/`api_error`/`rate_limit_error`/etc.;
    /// `warning` is a chat-apc extension.
    #[serde(rename = "type")]
    kind: &'a str,
    code: &'a str,
    message: &'a str,
    /// Mirrors OpenAI's optional `param` field. Always `None` for
    /// loop-failure cases (no single field at fault); reserved so
    /// future error sites can populate without a schema break.
    #[serde(skip_serializing_if = "Option::is_none")]
    param: Option<&'a str>,
    /// N3: structured raw counts for capped-dedup diagnostics
    /// (currently `tool_decode_disabled`). Downstream tooling reads
    /// the numeric fields directly instead of parsing the
    /// "(capped, total >= N)" string — eliminates the ASCII-stripping
    /// + false-precision risk M3/N3 flagged. True lower bound on
    /// distinct error modes = `1 + distinct_modes + overflow_modes`
    /// (the `1` accounts for the first error included in `message`).
    #[serde(skip_serializing_if = "Option::is_none")]
    distinct_modes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    overflow_modes: Option<usize>,
}

#[derive(Serialize)]
struct NonStreamChoice<'a> {
    index: u32,
    message: NonStreamMessage<'a>,
    finish_reason: &'static str,
}

#[derive(Serialize)]
struct NonStreamMessage<'a> {
    role: &'static str,
    content: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_content: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_calls: Option<Vec<NonStreamToolCall<'a>>>,
}

#[derive(Serialize)]
struct NonStreamToolCall<'a> {
    id: &'a str,
    #[serde(rename = "type")]
    kind: &'static str,
    function: ChunkToolCallFunction<'a>,
}

// =============================================================================
// Tool-decoder failure capture (H3 — first + last + count)
// =============================================================================

/// State accumulated when the tool decoder errors mid-turn (F9 path).
/// H3: keep first AND last error plus a distinct-modes count —
/// transient malformed-token followed by a structural failure tells
/// operators different things than a host that errors once and
/// recovers, but the previous single-`Option<String>` shape made
/// them indistinguishable.
struct ToolDisabledDiag {
    first: String,
    last: String,
    /// Distinct error messages observed (first included). Capped at
    /// [`Self::DEDUP_CAP`]; further distinct messages past the cap
    /// flip `overflow` but never extend the Vec or inflate
    /// `distinct`. J4: previously `dropped: usize` driven by `e ==
    /// d.last` only-check, which failed to dedupe a cycling two-mode
    /// A,B,A,B pattern. L2: also guards against per-token inflation
    /// past the cap (e.g. A..H fills `seen`, then cycling I,J,I,J
    /// past the boundary would otherwise re-inflate every token).
    seen: Vec<String>,
    /// Count of distinct error modes seen after `first`, ≤ DEDUP_CAP-1.
    /// Past the cap, see `overflow`.
    distinct: usize,
    /// M3: count of distinct error modes observed past the cap.
    /// L2 (predecessor) used a `bool`, collapsing "9 modes" and
    /// "9000 modes" into the identical render — exactly the
    /// distinction operators need to triage minor vs catastrophic
    /// degradation. `usize` increments per past-cap distinct mode
    /// observed (the dedup-against-`seen` test still gates it). The
    /// renderer reports `(capped, total >= N)` where N includes both
    /// the in-cap distinct count and this overflow count, so the
    /// number is a true lower bound on distinct modes seen.
    overflow_count: usize,
}

impl ToolDisabledDiag {
    /// Cap on the dedupe set. Eight distinct error modes is plenty
    /// for operator triage — beyond that, the failure mode is
    /// "decoder is fundamentally broken" and the exact distribution
    /// stops being useful. Bounded so a pathological host can't
    /// grow the Vec without limit.
    const DEDUP_CAP: usize = 8;

    fn record(state: &mut Option<Self>, e: String) {
        match state {
            None => {
                *state = Some(Self {
                    first: e.clone(),
                    last: e.clone(),
                    seen: vec![e],
                    distinct: 0,
                    overflow_count: 0,
                });
            }
            Some(d) => {
                // Always update `last` so the rendered tail reflects
                // the most-recent symptom, even when the message has
                // been seen before.
                d.last = e.clone();
                // First sight only. L2: gate `distinct +=` together
                // with `seen.push` — past the cap, increment
                // `overflow_count` (M3) and DO NOT inflate
                // `distinct`. Previously `d.distinct += 1` ran
                // unconditionally outside the cap check, so cycling-
                // past-cap re-introduced the per-token inflation J4
                // was meant to kill. M3: bool→usize so operators
                // can distinguish 9-mode vs 9000-mode failures.
                if !d.seen.iter().any(|s| s == &e) {
                    if d.seen.len() < Self::DEDUP_CAP {
                        d.seen.push(e);
                        d.distinct += 1;
                    } else {
                        d.overflow_count += 1;
                    }
                }
            }
        }
    }

    /// Render for SSE `message` field / `PartialError.message`. One
    /// line when only one mode was seen; two-clause format with
    /// distinct-mode count + last error when more arrived. J4+L2:
    /// the count is now a true bounded distinct-modes count via the
    /// `seen` Vec; cycling A,B,A,B,A renders "+1 more distinct
    /// error(s)". Past the cap, count freezes at `DEDUP_CAP-1` and
    /// the `+ (capped)` annotation flags the truncation so operators
    /// don't read it as a hard count.
    /// N3: expose the raw dedup-cap counts for attachment to the
    /// SseError / PartialError numeric fields. Pair: `distinct` (number
    /// of distinct modes shown past `first`, capped at DEDUP_CAP-1)
    /// + `overflow_count` (additional distinct modes seen past the
    /// cap). True lower bound on distinct modes = 1 + distinct +
    /// overflow_count.
    fn dedup_counts(&self) -> (usize, usize) {
        (self.distinct, self.overflow_count)
    }

    fn render(&self) -> String {
        if self.distinct == 0 && self.overflow_count == 0 {
            self.first.clone()
        } else if self.overflow_count == 0 {
            format!(
                "{first}; +{n} more distinct error(s), last: {last}",
                first = self.first,
                n = self.distinct,
                last = self.last,
            )
        } else {
            // M3: `distinct` is frozen at `DEDUP_CAP - 1` past the
            // cap; the true distinct-mode count is at least
            // `distinct + overflow_count`. Render the lower bound so
            // operators can distinguish "barely past cap" from
            // "catastrophically broken decoder" — the bool overflow
            // flag could not.
            let total_lower_bound = self.distinct + self.overflow_count;
            // N3: render uses ASCII `>=` instead of U+2265 so terminals
            // / log scrapers / grep that don't pass UTF-8 unchanged
            // (some `journalctl` configurations, narrow-encoding email
            // forwarders) read the comparator correctly.
            format!(
                "{first}; +{n} more distinct error(s) \
                 (capped, total >= {total}), last: {last}",
                first = self.first,
                n = self.distinct,
                total = total_lower_bound,
                last = self.last,
            )
        }
    }
}

// =============================================================================
// Outcome (F3 — replaces the count-based heuristic)
// =============================================================================

/// How generation terminated. Set at the exit point of each loop
/// branch rather than inferred from a token counter, so error and
/// natural-stop paths can never collapse onto the same `finish_reason`.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum Outcome {
    /// Decoder reported `Done` — natural end-of-turn.
    Natural,
    /// `max_tokens` cap reached before the model emitted a stop.
    MaxTokens,
    /// Tool-use decoder produced a complete `Event::Call`; generation
    /// stops at the call boundary so the client can execute the tool
    /// and resume on the next request.
    ToolCalls,
    /// Runtime / decoder / chat-template error. Surfaced as
    /// `finish_reason: "error"` to OpenAI clients, plus a meta-frame
    /// with the diagnostic detail.
    Aborted,
}

impl Outcome {
    fn finish_reason(self) -> &'static str {
        match self {
            Outcome::Natural => "stop",
            Outcome::MaxTokens => "length",
            Outcome::ToolCalls => "tool_calls",
            Outcome::Aborted => "error",
        }
    }
}

// =============================================================================
// Forward-pass starvation guard (#439)
// =============================================================================

/// True when a generation step came back with **no sampled token**, i.e.
/// the host returned zero `Token` slots for a decode that had the auto-
/// sampler attached.
///
/// Why this is a terminal condition, not "zero progress this step":
/// pie's scheduler swallows a forward-pass failure / per-batch timeout /
/// mid-stream KV eviction into an empty `ForwardPassOutput::default()`
/// (`Ok`, **not** `Err`) — `runtime/src/inference/scheduler.rs`. The SDK
/// `Generator` then folds that empty output in as "0 tokens accepted",
/// which never advances `tokens_generated` and never errors, so the
/// completion loop neither hits `MaxTokens` nor `Aborted` — it spins, and
/// the next step issues an empty-input forward pass that hangs the Metal
/// driver. The SSE body then closes with no terminal `finish_reason` chunk
/// and the app falls back to the opaque `missing_finish_reason` (#439).
///
/// This is distinct from a natural stop: on a stop-token step the host
/// still samples and returns `Token(stop)`, so `slots` carries a `Token`
/// and this returns `false`. (The SDK truncates that stop token out of
/// `Output::tokens` afterwards — which is why the loop must inspect the raw
/// host slots here, not `out.tokens`.)
fn forward_pass_starved(slots: &[SlotOutput]) -> bool {
    !slots.iter().any(|s| matches!(s, SlotOutput::Token(_)))
}

/// Diagnostic carried on the terminal `error` chunk + SSE meta-frame when
/// [`forward_pass_starved`] fires. Stable code so clients/log scrapers can
/// branch on the starvation case distinctly from a generic
/// `forward_pass_failed`.
const STARVED_CODE: &str = "forward_pass_starved";
const STARVED_MESSAGE: &str =
    "engine produced no tokens for a decode step (device failure, per-batch \
     timeout, or KV eviction); generation cannot continue";

// =============================================================================
// Reasoning/content channel demux
// =============================================================================

/// Whether a generation step's chat-decoder text belongs on the
/// **visible content** channel rather than the reasoning channel.
///
/// The reasoning decoder and chat decoder are fed the SAME token batch
/// each step. The chat decoder is model-generic and surfaces *all*
/// decoded text — including the `<think>` / `</think>` delimiter strings
/// the reasoning decoder treats as structural. A batch is visible content
/// only when it lands ENTIRELY OUTSIDE a reasoning block:
///
/// * `reason_idle` — the reasoning decoder reported no boundary or
///   reasoning text for this batch (`Event::Idle`); a `Start`, `Delta`,
///   or `End` means the batch is reasoning-channel material.
/// * `was_in_reasoning` — the `in_reasoning` state *before* this batch
///   was processed. Captured pre-`feed` because the reasoning decoder
///   flips the flag as a side effect of consuming the boundary token.
///
/// The closing `</think>` batch makes the reasoning decoder
/// report `End` and flips `in_reasoning` to false, but the chat decoder
/// still emits `"</think>"` as a `Delta` on that same batch. Gating on
/// the post-`feed` `in_reasoning` alone (the old `!in_reasoning` guard)
/// re-opened the content channel exactly in time for the delimiter to
/// leak. `End` is not `Idle`, so this returns false for that batch.
/// The opening `<think>` batch was already handled correctly (`Start`
/// is not `Idle`), which is why only the closing tag leaked.
fn content_visible(reason_idle: bool, was_in_reasoning: bool) -> bool {
    reason_idle && !was_in_reasoning
}

// =============================================================================
// Launch-diagnostics registry (N1/N2 — OnceLock immutable snapshot)
// =============================================================================

/// One in-band-deliverable diagnostic produced by infrastructure
/// detection (id_seed entropy fallback, now_unix_secs clock-skew,
/// monotonic-clock stub/coarse) that would otherwise live only in
/// `eprintln!` and be dropped in the pie-mac production deployment
/// (see `crate::sse::emit_done_logged` doc + ).
///
/// N1/N2 design: computed exactly once at first request entry via
/// `compute_launch_diags()`, then frozen in `LAUNCH_DIAGS: OnceLock`
/// for the lifetime of the process. Every response — streaming SSE
/// warnings, non-streaming `warnings` field, 400/404/500 error paths
/// (via the `X-ChatAPC-Launch-Diags` header) — reads the same
/// immutable Vec. The previous Mutex<Vec<…>> design needed a
/// drain/restore/poison-recovery dance (M2 / L4 / J2) just to keep
/// the registry consistent across early-exits; an immutable snapshot
/// eliminates the entire failure surface.
#[derive(Clone)]
pub(crate) struct LaunchDiag {
    pub code: &'static str,
    pub message: String,
}

/// Y1: the v∞-frozen universe of `LaunchDiag.code` wire
/// identifiers. Every code that has shipped on the
/// `X-ChatAPC-Launch-Diags` header (or its SSE `warning` / non-stream
/// `warnings` siblings) is load-bearing for downstream dashboards and
/// alerts — same stability contract as the heartbeat
/// `launch_probes_ok` / `launch_probes_serialize_failed` literals
/// already pinned by `golden_wire_*_code_literal`.
///
/// Policy:
///   * Never rename. A rename is a silent break for every consumer
///     pattern-matching on the literal.
///   * Never remove. Even a no-longer-emitted code stays in the list
///     so the test below (`stable_launch_diag_codes_universe_frozen`)
///     keeps catching accidental re-introductions under a different
///     spelling.
///   * Adding a new code: define a module const for the literal, add
///     a `LaunchDiag { code: CODE_NEW_THING, ... }` push site, append
///     `CODE_NEW_THING` here AND extend the freeze test in the same
///     commit. Routing every push site through a module const means
///     a rename collapses both sides of the freeze (constant value
///     and slice membership), so the test catches it.
///
/// Tool-decode warnings (`tool_decode_disabled`, emitted by
/// `chat/completions.rs` non-stream `PartialError` and the SSE warning
/// path) carry the same stability contract but ride a different
/// envelope (`PartialError.code` + `SseError.code`) — they are NOT
/// LaunchDiag entries and are tracked alongside the chat-error
/// envelope under , not here. This list is launch-scope only.
pub(crate) const CODE_CLOCK_SKEW: &str = "clock_skew";
pub(crate) const CODE_CLOCK_SKEW_FALLBACK_ENTROPY: &str = "clock_skew_fallback_entropy";
pub(crate) const CODE_ENTROPY_DEGRADED: &str = "entropy_degraded";
pub(crate) const CODE_MONOTONIC_CLOCK_STUBBED: &str = "monotonic_clock_stubbed";
pub(crate) const CODE_MONOTONIC_CLOCK_COARSE_RESOLUTION: &str = "monotonic_clock_coarse_resolution";

// Read by `stable_launch_diag_codes_universe_frozen` (and only by
// that test). Production builds don't reference the slice, so dead-
// code lint fires without this attribute — the const stays
// load-bearing for the CI freeze gate regardless.
#[allow(dead_code)]
pub(crate) const STABLE_LAUNCH_DIAG_CODES: &[&str] = &[
    CODE_CLOCK_SKEW,
    CODE_CLOCK_SKEW_FALLBACK_ENTROPY,
    CODE_ENTROPY_DEGRADED,
    CODE_MONOTONIC_CLOCK_STUBBED,
    CODE_MONOTONIC_CLOCK_COARSE_RESOLUTION,
];

static LAUNCH_DIAGS: OnceLock<Vec<LaunchDiag>> = OnceLock::new();

/// Read-only accessor. Forces initialization on first call (idempotent
/// thereafter). Safe to call from any path including 400/404 entry
/// validators — `OnceLock::get_or_init` is sync + thread-safe and
/// returns the same `&'static Vec` for every subsequent caller.
fn launch_diags() -> &'static [LaunchDiag] {
    LAUNCH_DIAGS.get_or_init(compute_launch_diags).as_slice()
}

/// One-shot detection: runs the SystemTime probe + id_seed init under
/// a fresh local Vec, returning whatever diagnostics fired. Called
/// exactly once via `LAUNCH_DIAGS.get_or_init`. `eprintln!` still
/// fires for host-side stderr capture (where available); the Vec is
/// the in-band channel  was meant to make redundant.
///
/// S1: ALSO force-initializes `LAUNCH_TIMESTAMP` here at the head of
/// the probe chain — every `handle_parsed` call funnels through
/// `launch_diags()` before any validation, so this is the earliest
/// observable point in this wasm component's lifetime (wasm has no
/// pre-request hook we can attach to). Previously `launch_timestamp()`
/// was lazy-initialized at first HEADER build, which under-reported
/// process age by however long the daemon was idle before serving its
/// first chat-completion. The remaining gap (process spawn → first
/// request entry) is structurally unobservable from inside the wasm
/// guest — `launched_at` on the heartbeat is a LOWER BOUND on real
/// process age, NOT spawn time. See the wire-shape stability policy
/// block on `HEARTBEAT_SCHEMA_VERSION` for the
/// consumer-side reading.
fn compute_launch_diags() -> Vec<LaunchDiag> {
    let _ = launch_timestamp();
    let mut diags = Vec::new();
    if let Err(e) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        let msg = format!(
            "system clock before UNIX_EPOCH ({e}); stamping created=0 \
             for this and all subsequent requests (one-shot)"
        );
        eprintln!("[chat-apc] {msg}");
        diags.push(LaunchDiag { code: CODE_CLOCK_SKEW, message: msg });
    }
    init_seed_into(&mut diags);
    diags
}

// =============================================================================
// X-ChatAPC-Launch-Diags header (O1 + O3 + O4)
// =============================================================================

/// O3: per-message byte cap. Worst-case practical message today is
/// ~600 bytes (entropy_degraded with embedded `e.duration` printf);
/// 1KB leaves headroom for future probes interpolating modest
/// structured detail. Past this, the message tail is replaced with
/// `...[truncated]` so log scrapers see the truncation explicitly
/// instead of decoding a half-clipped JSON envelope.
const MAX_DIAG_MESSAGE_LEN: usize = 1024;

/// O3: total header-value cap, well under nginx's default 8KB
/// `large_client_header_buffers` and most CDN/proxy caps. The
/// remainder count rides as a `{"_truncated": N}` sentinel entry so
/// the truncation is observable in-band; entries are kept up to the
/// budget, then dropped (front-to-back order preserved — first diags
/// recorded survive truncation).
const MAX_HEADER_PAYLOAD_BYTES: usize = 4096;

/// O4 + P2 + Q1 + T2: heartbeat sentinel `code` identifier.
///
/// Wire contract: stable forever. `code` is the load-bearing field
/// dashboards / alerts pattern-match on; renaming it across a
/// release silently breaks every consumer keyed on the literal
/// string. Q1's prior attempt to encode snapshot scope by renaming
/// `launch_probes_ok` → `launch_probes_startup_ok` regressed v9-v10
/// consumers (S2). T2 reverts to the original stable identifier;
/// the snapshot scope now lives in additive structured fields
/// (`scope:"startup_snapshot"` + `launched_at:<unix-ts>` +
/// `_schema_version`) so machine consumers can distinguish snapshot-
/// from-live without renaming the load-bearing field. Wire-shape
/// stability policy tracked separately. Live liveness
/// (re-probe endpoint / liveness counter) tracked separately.
///
/// NOT propagated into the body `warnings` field or SSE warning
/// frames — those carry the SDK-facing contract and would otherwise
/// emit a benign warning on every clean response, which dashboards
/// would learn to ignore.
const LAUNCH_PROBES_OK: &str = "launch_probes_ok";

/// Q4: distinct code emitted by `fallback_serialize_failed_payload`
/// when the final header serialization crashes. Dashboards alerting
/// on `code == launch_probes_ok` must see this as a separate state,
/// not a false-positive healthy launch.
const LAUNCH_PROBES_SERIALIZE_FAILED: &str = "launch_probes_serialize_failed";

/// Q1: monotonic-since-process-start would be the cleaner clock, but
/// `wasi:clocks/monotonic_clock` doesn't give an absolute timestamp
/// — only relative durations. Use wall-clock seconds captured at
/// first header build (or first chat-completion request, whichever
/// fires first); reused across the process lifetime so dashboards
/// can compute `now - launched_at` for snapshot age. `0` on a
/// clock-skewed host (paired with the `clock_skew` diag in the
/// same payload, which already signals the cause).
static LAUNCH_TIMESTAMP: OnceLock<i64> = OnceLock::new();

fn launch_timestamp() -> i64 {
    *LAUNCH_TIMESTAMP.get_or_init(now_unix_secs)
}

/// Cut a UTF-8 string at a char boundary at or below `max` bytes.
/// Returns the original string if it already fits. Appends a
/// truncation marker so log readers see the cut explicitly; the
/// marker degrades as `max` shrinks so the byte cap is honored
/// even for very small budgets (P1).
///
/// Marker selection:
///   * `max >= 14`  → `"...[truncated]"` (full marker, fits today's
///                    1024-byte cap and any reasonable future probe)
///   * `max >= 3`   → `"..."` (short marker; signals truncation
///                    without exceeding the budget)
///   * `max < 3`    → no marker — bare truncated head only. Caller
///                    asked for a budget too small to carry any
///                    marker; honoring `max` wins over signaling
///                    truncation, since exceeding the budget could
///                    blow a wire-shape constraint (e.g. an 8-byte
///                    tag field).
fn truncate_message(msg: &str, max: usize) -> String {
    if msg.len() <= max {
        return msg.to_string();
    }
    const FULL: &str = "...[truncated]";
    const SHORT: &str = "...";
    let suffix: &str = if max >= FULL.len() {
        FULL
    } else if max >= SHORT.len() {
        SHORT
    } else {
        ""
    };
    let budget = max.saturating_sub(suffix.len());
    let mut end = budget.min(msg.len());
    while end > 0 && !msg.is_char_boundary(end) {
        end -= 1;
    }
    let mut out = String::with_capacity(end + suffix.len());
    out.push_str(&msg[..end]);
    out.push_str(suffix);
    out
}

/// Q2 + S4: bytes of message prefix retained for dropped entries.
/// Pairs with the dropped `code` in the sentinel so operators can
/// identify which message variant of a possibly-duplicated code was
/// lost. S4 bumped 16 → 48 to clear common probe-family namespacing
/// (e.g. `"id_seed: wasi:clocks/monotonic_clock ..."` vs
/// `"id_seed: wasi:clocks/wall_clock ..."` previously truncated to
/// identical 16-byte prefixes, defeating Q2's disambiguation goal).
/// 48 bytes leaves ~30 visible chars past a typical
/// `probe_name: subsystem:component ` namespace header — enough to
/// reach the differentiating tail of all current diag messages.
/// The prefix uses cut-only semantics (no `...[truncated]` marker)
/// — the field name `message_prefix` already signals the truncation;
/// reusing `truncate_message`'s marker would consume most of the
/// budget for the marker itself.
const DROPPED_MESSAGE_PREFIX_LEN: usize = 48;

/// S2 + T2 + U2: heartbeat schema version. Bumped on any additive
/// shape change so downstream consumers can detect schema
/// transitions deterministically without matching on the literal
/// `code` string.
///
/// Emitted as a JSON STRING (`"2"`, not bare `2`) so Grafana
/// template-variable matching, JS string-comparison idioms
/// (`if (frame._schema_version === "2")`), and other consumers
/// that key on the field as text don't silently miss matches.
/// JSON-number consumers can still coerce via `parseInt`/`as i64`;
/// the asymmetry favors the more failure-prone string consumers.
///
/// v9-v10 emitted no schema version (`code:"launch_probes_ok"`,
/// no version); v11 renamed to `launch_probes_startup_ok` without
/// versioning (silent break — S2); v12 pinned `_schema_version: 2`
/// as JSON number but kept the rename; T2 (v13) reverted to the
/// stable `launch_probes_ok` code while keeping the additive
/// fields; U2 (v14) changes `_schema_version` to a JSON string
/// for template-var compatibility. The version number stays at 2
/// — the v12→v13→v14 series is all the same additive-fields
/// surface, only the wire-encoding type changed. Future shape
/// changes bump to "3".
///
/// Wire-shape stability policy (tracked under ).
/// Owns the launch-diag code-freeze ONLY. The cross-boundary error
/// envelope/taxonomy (WS Response.ok + HTTP body + SSE error frame)
/// is owned by ; any new launch-diag code added here must fit
/// within (or map cleanly into) 's unified code space.
///
///   * MUST1: `code` strings are stable wire identifiers; never
///     rename, add new codes instead. The active LaunchDiag code
///     universe is pinned in `STABLE_LAUNCH_DIAG_CODES`. Heartbeat
///     and fallback codes (`launch_probes_ok` /
///     `launch_probes_serialize_failed`) are additionally pinned by
///     `golden_wire_heartbeat_code_literal` /
///     `golden_wire_fallback_code_literal`. Enforced by
///     `stable_launch_diag_codes_universe_frozen`.
///   * MUST2: `_schema_version` is the documented version key for
///     downstream consumers; pin on it for shape detection.
///     Enforced by `heartbeat_carries_schema_version` /
///     `fallback_payload_carries_schema_version_as_string`.
///   * MUST3: Additive fields are safe; deletions / type changes /
///     MEANING changes under a stable type all bump the version.
///     The meaning-change clause is X1's tightening: V1's
///     nullable widening was caught because the JSON type
///     changed; W1's "entries_lost_total goes from authoritative
///     sum to lower bound" slipped through because the JSON type
///     didn't. Either widens the contract — both bump.
///   * MUST4: RENAMES of any field, including `*_measured` siblings,
///     bump the version. X2 codification: the `_failed_lost_`
///     stutter in `heartbeat_seed_failed_lost_measured` is NOT a
///     future cleanup opportunity — the wire name is frozen by
///     the same policy as `code` strings. Enforced by
///     `heartbeat_field_names_frozen` /
///     `fallback_payload_field_names_frozen`.
///   * MUST5: Every new `*_lost` COUNTER MUST ship with its
///     `*_lost_measured` sibling in the same commit. Half-pair
///     landings break the bool-aware consumer's
///     "measured = all four flags true" invariant. Enforced by
///     `fallback_payload_lost_counter_pairing` (parses the wire
///     and asserts bijection between `*_lost` and `*_lost_measured`,
///     excluding the `entries_lost_total` aggregate).
///   * MUST6: Absent `*_measured` is CONTRACTUALLY EQUIVALENT to
///     `measured: true`. Legacy v9-era readers that don't see
///     the bool MUST treat the paired counter as authoritative;
///     this defines well-formed behavior for cross-version
///     consumers and pins the X1 "legacy consumer trusts the
///     number" path as policy-allowed, not policy-undefined.
///     Consumer-side semantic — not mechanically enforceable from
///     the producer; documented here as the canonical reading.
///   * MUST7: `HEARTBEAT_SCHEMA_VERSION` is `&str`. Enforced at
///     compile time by `_HEARTBEAT_SCHEMA_VERSION_MUST_BE_STR`
///     (below) — any non-`&str` value would fail to compile.
///
/// Known limitation (`launched_at`): the timestamp captures the
/// FIRST-REQUEST-ENTRY moment, not process spawn. The WASM
/// request-handler model has no pre-request lifecycle hook the guest
/// can attach to (`compute_launch_diags()` is driven on first
/// `handle_parsed` call), so the gap between process spawn and first
/// chat-completion is structurally unobservable from inside this
/// guest. Host-side spawn timestamps live on the pie daemon and are
/// out of scope here. Consumers computing "age since launch" should
/// read `launched_at` as a LOWER BOUND on real process age.
const HEARTBEAT_SCHEMA_VERSION: &str = "2";

/// U2 INVARIANT: `HEARTBEAT_SCHEMA_VERSION` MUST remain `&str`.
/// Both emission sites (heartbeat builder + fallback `format!`)
/// rely on this type to produce a JSON string on the wire; a
/// future contributor flipping the constant back to `u32` would
/// silently desync the heartbeat path (JSON number) from the
/// fallback path (still string) for the same logical field —
/// Grafana template-vars match one, miss the other. The line
/// below is a compile-time type pin: any non-`&str` value
/// assigned to `HEARTBEAT_SCHEMA_VERSION` produces a build error
/// pointing here.
const _HEARTBEAT_SCHEMA_VERSION_MUST_BE_STR: &str = HEARTBEAT_SCHEMA_VERSION;

/// Cut a UTF-8 string at a char boundary at or below `max` bytes.
/// Unlike `truncate_message`, does NOT append a truncation marker —
/// used for sentinel-payload prefixes where the field name already
/// conveys the prefix semantics and the marker would crowd out the
/// actual signal.
fn message_prefix(msg: &str, max: usize) -> String {
    if msg.len() <= max {
        return msg.to_string();
    }
    let mut end = max.min(msg.len());
    while end > 0 && !msg.is_char_boundary(end) {
        end -= 1;
    }
    msg[..end].to_string()
}

/// Build the JSON payload that rides the `X-ChatAPC-Launch-Diags`
/// header. Always non-empty thanks to the O4 heartbeat sentinel;
/// real diagnostics follow in original order, with per-message
/// truncation (O3a), total-payload budget enforcement (O3b),
/// per-entry skip-on-serialize-failure (P4), and partitioned
/// drop sentinels distinguishing budget drops from data drops (Q3).
fn launch_diags_header_payload() -> String {
    build_launch_diags_payload(launch_diags())
}

/// F10 (PR  review v2): the actual payload builder, parameterized
/// on the diag slice so freeze tests can drive the production code
/// path end-to-end with a synthetic seed instead of waiting for the
/// OnceLock `LAUNCH_DIAGS` registry to be populated by a clock-skew
/// / entropy / monotonic-clock fault. Re-inlining the entry-frame
/// `json!` construction with a typo (e.g. `"msg"` instead of
/// `"message"`) breaks this function's wire output even when the
/// extracted `launch_diag_entry_json` helper stays untouched — so
/// `launch_diags_header_payload_arr1_field_names_frozen` catches the
/// regression at CI time.
fn build_launch_diags_payload(diags: &[LaunchDiag]) -> String {
    // T2: heartbeat code is the stable `launch_probes_ok` literal.
    // Snapshot scope lives in the additive structured fields
    // (`scope`, `launched_at`, `_schema_version`) so consumers
    // pattern-matching on `code` keep working across releases while
    // machine consumers reading the structured fields can still
    // distinguish snapshot-from-live and compute age.
    let heartbeat = serde_json::json!({
        "code": LAUNCH_PROBES_OK,
        "_schema_version": HEARTBEAT_SCHEMA_VERSION,
        "scope": "startup_snapshot",
        "launched_at": launch_timestamp(),
        "message": "launch probe chain ran once at startup; live health not reflected. \
                    Sibling entries enumerate degraded launch state.",
    });
    let mut entries: Vec<serde_json::Value> = vec![heartbeat];
    // Reserve headroom for the trailing sentinels. Worst case: ~5
    // codes split across budget-drop + serialize-fail sentinels,
    // each with 16-byte message prefix. ~80 bytes/entry × up to 10
    // recorded slots × structural overhead ≈ 768. Round to 1024
    // for headroom; if future probes inflate this past the
    // reserve, the worst case is a slightly under-filled payload —
    // fail-closed.
    const SENTINEL_RESERVE: usize = 1024;
    let mut size = match serde_json::to_string(&entries) {
        Ok(s) => s.len(),
        // U1 + V1: heartbeat-only serialize failed — diag Vec lost
        // before per-entry budget/serialize partitioning could run.
        // `heartbeat_seed_failed = Some(diags.len())` records the
        // observed loss; the other three counters pass `None` (not
        // `Some(0)`) so the wire distinguishes "not measured" from
        // "measured as zero." Without the V1 distinction, operators
        // seeing `budget_dropped_lost: 0` here would wrongly
        // conclude no budget drops occurred — when in truth no
        // budget check ran at all.
        Err(_) => {
            return fallback_serialize_failed_payload(
                Some(diags.len()),
                None,
                None,
                None,
            );
        }
    };
    // Q3: partition dropped entries by REASON so operators can tell
    // "ran out of header budget" (operator action: shrink earlier
    // probes / raise the cap) from "serializer rejected the Value"
    // (operator action: fix the probe interpolation logic). Both
    // record (code, message_prefix) per Q2 so duplicate codes with
    // distinct messages are individually identifiable.
    let mut budget_dropped: Vec<(&'static str, String)> = Vec::new();
    let mut serialize_dropped: Vec<(&'static str, String)> = Vec::new();
    // S3: track real diag entries that made it INTO `entries`
    // separately from `entries.len()`. The fallback path computes
    // upstream-loss count from this; relying on `entries.len() - 1`
    // (heartbeat) over-counted sentinel blocks AND under-counted
    // the upstream drops the sentinels described.
    let mut accepted_real_diags: usize = 0;
    for d in diags {
        let msg = truncate_message(&d.message, MAX_DIAG_MESSAGE_LEN);
        let entry = launch_diag_entry_json(d.code, &msg);
        let prefix = message_prefix(&d.message, DROPPED_MESSAGE_PREFIX_LEN);
        // Q3: distinguish budget drops from serializer drops. P4
        // unwrap_or(0)→match removed the size undercount; Q3 ALSO
        // routes the failure into a separate sentinel.
        let entry_size = match serde_json::to_string(&entry) {
            Ok(s) => s.len() + 1, // `+1` accounts for the `,` separator
            Err(_) => {
                serialize_dropped.push((d.code, prefix));
                continue;
            }
        };
        if size + entry_size + SENTINEL_RESERVE > MAX_HEADER_PAYLOAD_BYTES {
            budget_dropped.push((d.code, prefix));
            continue;
        }
        entries.push(entry);
        size += entry_size;
        accepted_real_diags += 1;
    }
    if !budget_dropped.is_empty() {
        entries.push(budget_drop_sentinel(&budget_dropped));
    }
    if !serialize_dropped.is_empty() {
        entries.push(serialize_fail_sentinel(&serialize_dropped));
    }
    match serde_json::to_string(&entries) {
        Ok(s) => s,
        // T1 + V1: final serialize crashed AFTER we built the
        // entries Vec. All four categories are KNOWN (we ran the
        // partitioning loop), so pass each as `Some(n)`. The
        // heartbeat-seed counter is `Some(0)` here — we know the
        // heartbeat itself serialized successfully (early-bail
        // above handles that case). Q4 distinct code stays so
        // dashboards don't misread this as a healthy launch.
        Err(_) => fallback_serialize_failed_payload(
            Some(0),
            Some(accepted_real_diags),
            Some(budget_dropped.len()),
            Some(serialize_dropped.len()),
        ),
    }
}

/// Convert a `(code, message_prefix)` drop list into the JSON
/// sub-array structure used inside the sentinels. Per Q2.
fn dropped_entries_json(items: &[(&'static str, String)]) -> Vec<serde_json::Value> {
    items
        .iter()
        .map(|(code, prefix)| serde_json::json!({"code": *code, "message_prefix": prefix}))
        .collect()
}

/// F1 (PR  review v1,  MUST4): per-LaunchDiag entry
/// frame builder. Extracted from the inline `json!` in
/// `launch_diags_header_payload` so the entry-frame field-name freeze
/// (`{code, message}`) is testable from a unit test without seeding
/// the OnceLock `LAUNCH_DIAGS` registry. Wire-frozen field set:
/// `{"code", "message"}`. Renames here bump `HEARTBEAT_SCHEMA_VERSION`.
fn launch_diag_entry_json(code: &str, message: &str) -> serde_json::Value {
    serde_json::json!({"code": code, "message": message})
}

/// F2 (PR  review v1,  MUST4): budget-drop sentinel
/// frame builder. Wire-frozen field set:
/// `{"_truncated", "_truncated_codes"}`. Renames bump
/// `HEARTBEAT_SCHEMA_VERSION`. Extracted from
/// `launch_diags_header_payload` so the freeze test can pin the keys
/// without driving the full overflow pipeline.
fn budget_drop_sentinel(dropped: &[(&'static str, String)]) -> serde_json::Value {
    serde_json::json!({
        "_truncated": dropped.len(),
        "_truncated_codes": dropped_entries_json(dropped),
    })
}

/// F2 (PR  review v1,  MUST4): serialize-fail sentinel
/// frame builder. Wire-frozen field set:
/// `{"_serialize_failed", "_serialize_failed_codes"}`. Renames bump
/// `HEARTBEAT_SCHEMA_VERSION`. Extracted alongside
/// `budget_drop_sentinel` so the freeze test can pin the keys
/// directly — the in-line construction is unreachable through normal
/// inputs (entries are `{code: &str, message: String}` pairs that
/// always serialize).
fn serialize_fail_sentinel(dropped: &[(&'static str, String)]) -> serde_json::Value {
    serde_json::json!({
        "_serialize_failed": dropped.len(),
        "_serialize_failed_codes": dropped_entries_json(dropped),
    })
}

/// Q4 + T1 + U1 + V1 + W1: fallback when even the simplest
/// serialization fails. Uses a DISTINCT code
/// (`launch_probes_serialize_failed`) so dashboards alerting on
/// `launch_probes_ok` don't mark a hard serializer failure as a
/// healthy launch.
///
/// W1/W2: each `*_lost` counter stays a JSON NUMBER (the v9-era
/// wire shape), paired with an additive `*_lost_measured: bool`
/// sibling that says whether the partitioning loop produced an
/// authoritative count. `measured=false` → counter is a
/// placeholder zero (the upstream code path bailed before this
/// category could be computed). Old integer-only consumers keep
/// working; new consumers read the bools to filter authoritative
/// values. No wire-type change → `HEARTBEAT_SCHEMA_VERSION` stays
/// `"2"` per the stability policy ("deletions / type changes
/// bump the version").
///
/// V1 (superseded by W1): the prior approach widened each counter
/// to `integer | null`. That was a JSON-type change and would have
/// silently broken type-strict consumers (TS strict, JSON-Schema-
/// validated dashboards, `serde::Deserialize<i64>`). The current
/// approach replaces the union type with an additive sibling bool.
///
/// `entries_lost_total` sums the MEASURED counters only. Combined
/// with the four `*_measured` flags an operator can reconstruct
/// "is total authoritative" (all four flags true) vs "lower-bound
/// of true total" (any flag false).
///
/// T1 + U1: four categories map 1:1 to distinct remediation paths
/// (when measured):
///   * `heartbeat_seed_failed` — heartbeat sentinel itself failed
///     to serialize. Remediation: investigate `launch_timestamp` /
///     `HEARTBEAT_SCHEMA_VERSION` / `LAUNCH_PROBES_OK` interpolation.
///   * `accepted_real_diags` — diags that made it into entries Vec
///     but never reached the wire because FINAL serialize crashed.
///     Remediation: investigate post-loop serialization.
///   * `budget_dropped` — diags rejected for not fitting under the
///     4KB payload cap. Remediation: shrink probes / raise
///     `MAX_HEADER_PAYLOAD_BYTES`.
///   * `serialize_failed` — diags whose individual Value rejected
///     `serde_json::to_string` (e.g. f64::NAN). Remediation: fix
///     the probe interpolation logic.
///
/// Hand-rolled JSON so we don't depend on `serde_json` — interpolated
/// values are `usize` numbers and `true`/`false` booleans; all other
/// text is ASCII literal.
fn fallback_serialize_failed_payload(
    heartbeat_seed_failed: Option<usize>,
    accepted_real_diags: Option<usize>,
    budget_dropped: Option<usize>,
    serialize_failed: Option<usize>,
) -> String {
    // W1: split `Option<usize>` into `(count, measured)` for the
    // wire. `None` becomes `(0, false)` — counter is a placeholder
    // that consumers MUST cross-reference with `*_measured` before
    // trusting. `Some(n)` becomes `(n, true)`.
    fn split(v: Option<usize>) -> (usize, bool) {
        match v {
            Some(n) => (n, true),
            None => (0, false),
        }
    }
    let (heartbeat, heartbeat_measured) = split(heartbeat_seed_failed);
    let (accepted, accepted_measured) = split(accepted_real_diags);
    let (budget, budget_measured) = split(budget_dropped);
    let (serialize, serialize_measured) = split(serialize_failed);
    // W1: sum MEASURED counters only — unmeasured placeholder zeros
    // are excluded.
    let total = (if heartbeat_measured { heartbeat } else { 0 })
        + (if accepted_measured { accepted } else { 0 })
        + (if budget_measured { budget } else { 0 })
        + (if serialize_measured { serialize } else { 0 });
    // X1: surface "is the total authoritative" as its own bool so
    // bool-aware consumers don't have to AND four siblings to know.
    // Discoverable companion field for the legacy-consumer case
    // that reads `entries_lost_total` as a number — those consumers
    // get the bool naming-convention hook to upgrade against. Per
    // the W1 policy ("absent *_measured ≡ measured:true"), legacy
    // consumers that ignore this bool default to treating the
    // number as authoritative.
    let total_authoritative =
        heartbeat_measured && accepted_measured && budget_measured && serialize_measured;
    // U2: `_schema_version` is JSON-string-encoded; quoting here
    // matches the heartbeat serde_json::json! path which already
    // serializes the `&str` constant as a JSON string.
    format!(
        "[{{\"code\":\"{LAUNCH_PROBES_SERIALIZE_FAILED}\",\
          \"_schema_version\":\"{HEARTBEAT_SCHEMA_VERSION}\",\
          \"scope\":\"startup_snapshot\",\
          \"entries_lost_total\":{total},\
          \"entries_lost_total_authoritative\":{total_authoritative},\
          \"heartbeat_seed_failed_lost\":{heartbeat},\
          \"heartbeat_seed_failed_lost_measured\":{heartbeat_measured},\
          \"accepted_real_diags_lost\":{accepted},\
          \"accepted_real_diags_lost_measured\":{accepted_measured},\
          \"budget_dropped_lost\":{budget},\
          \"budget_dropped_lost_measured\":{budget_measured},\
          \"serialize_failed_lost\":{serialize},\
          \"serialize_failed_lost_measured\":{serialize_measured},\
          \"message\":\"header payload serializer crashed; see *_lost fields for upstream breakdown. Each *_lost is paired with *_lost_measured:bool — when false the counter is a placeholder (partitioning didn't run for that category) and entries_lost_total is a lower bound (entries_lost_total_authoritative:false).\"}}]"
    )
}

/// O1: percent-encode any byte outside printable ASCII (0x21..=0x7E,
/// excluding `%` itself which becomes `%25`). Guarantees the value
/// satisfies `wstd::http::HeaderValue::from_str`'s VCHAR constraint
/// regardless of what the underlying JSON payload contains (future
/// diag messages may interpolate Unicode without notice). Decode is
/// trivial on the consumer side (`urllib.parse.unquote` /
/// `percent-encoding` crate).
fn percent_encode_for_header(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for &b in raw.as_bytes() {
        if (0x21..=0x7E).contains(&b) && b != b'%' {
            out.push(b as char);
        } else {
            out.push('%');
            // Inline two-hex-digit format — `format!("{:02X}", b)`
            // would allocate per-byte.
            const HEX: &[u8; 16] = b"0123456789ABCDEF";
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0F) as usize] as char);
        }
    }
    out
}

/// Attach the `X-ChatAPC-Launch-Diags` header (O4 heartbeat + any
/// degraded-state entries, percent-encoded per O1, size-capped per
/// O3). On the (now structurally impossible) `HeaderValue::from_str`
/// rejection, attaches a sentinel `X-ChatAPC-Launch-Diags-Error`
/// header so the gap is observable instead of being silently
/// dropped, and logs once.
fn with_launch_diags_header<B>(mut resp: Response<B>) -> Response<B> {
    let payload = launch_diags_header_payload();
    let encoded = percent_encode_for_header(&payload);
    match wstd::http::HeaderValue::from_str(&encoded) {
        Ok(hv) => {
            resp.headers_mut().insert("X-ChatAPC-Launch-Diags", hv);
        }
        Err(e) => {
            // O1: percent-encoded output is structurally restricted
            // to 0x21..=0x7E (no spaces, no controls, no high-bit
            // bytes), so this branch should be unreachable. If it
            // fires the issue is upstream of the encoder (e.g. a
            // future change to `HeaderValue::from_str`'s allowed
            // set); log once + attach a sentinel marker header so
            // operators see the encoding failure instead of a
            // silently absent diag header.
            static ENCODE_FAIL_LOGGED: AtomicBool = AtomicBool::new(false);
            if !ENCODE_FAIL_LOGGED.swap(true, Ordering::Relaxed) {
                eprintln!(
                    "[chat-apc] X-ChatAPC-Launch-Diags HeaderValue::from_str \
                     rejected percent-encoded payload ({e}); attaching \
                     X-ChatAPC-Launch-Diags-Error sentinel. One-shot log."
                );
            }
            if let Ok(sentinel) =
                wstd::http::HeaderValue::from_str("encoding_failed")
            {
                resp.headers_mut()
                    .insert("X-ChatAPC-Launch-Diags-Error", sentinel);
            }
        }
    }
    resp
}

// =============================================================================
// ID + clock helpers
// =============================================================================

/// Hot-path clock read. The one-shot `clock_skew` diagnostic that
/// previously fired inline here now lives in `compute_launch_diags()`
/// (N1 — single source of truth for launch-scope state), so this
/// function silently returns 0 on permanent skew. Per-request callers
/// pay only a SystemTime probe + branch.
fn now_unix_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Shared launch-time id seed. `0` is the "not yet initialized"
/// sentinel; the heavy entropy/clock detection lives in
/// `init_seed_into()` which is driven once by `compute_launch_diags()`
/// at first request entry and on subsequent fallbacks via the throwaway-
/// Vec path inside `id_seed()`.
static SEED: AtomicU64 = AtomicU64::new(0);

/// Hot-path seed read. Returns the cached value once initialized;
/// otherwise drives `init_seed_into` with a throwaway Vec (the
/// authoritative diag-capture path runs out of `launch_diags()`).
/// `next_id`/`next_tool_call_id` always go through `handle_parsed`
/// which calls `launch_diags()` at the very top, so under normal
/// routing this branch is dead — kept for defense against future
/// callers that bypass the entry gate.
fn id_seed() -> u64 {
    let cached = SEED.load(Ordering::Relaxed);
    if cached != 0 {
        return cached;
    }
    let mut throwaway = Vec::new();
    init_seed_into(&mut throwaway);
    SEED.load(Ordering::Relaxed)
}

/// Compute and publish the launch-time seed, pushing any detection
/// diagnostics into `diags` instead of recording them through a
/// shared registry. Idempotent: subsequent calls early-return once
/// `SEED` is non-zero.
fn init_seed_into(diags: &mut Vec<LaunchDiag>) {
    if SEED.load(Ordering::Relaxed) != 0 {
        return;
    }
    let candidate = match std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
    {
        Ok(d) => d.as_nanos() as u64,
        Err(e) => {
            // Mix wasi entropy + the SEED static's address. The
            // address would add inter-launch jitter on hosts with
            // ASLR, but `wasm32-wasip2` statics live at fixed linear-
            // memory offsets, so it's byte-identical across launches
            // — entropy is the only real defense. H1: detect the
            // all-zero buffer case explicitly (a wasi backend that
            // stubs out / fails silently leaves entropy=0; without
            // this guard the seed collapses to `addr.rotate_left(13)`
            // and the F3 collision returns indistinguishable from a
            // healthy fallback).
            let mut buf = [0u8; 8];
            wstd::rand::get_random_bytes(&mut buf);
            // One retry: a real RNG transient can flake; a stub
            // always returns zero. After the retry, treat persistent
            // all-zero as entropy-failed and use a different mix.
            if buf == [0u8; 8] {
                wstd::rand::get_random_bytes(&mut buf);
            }
            let addr = &SEED as *const _ as usize as u64;
            let candidate = if buf == [0u8; 8] {
                // I1: entropy stubbed AND wall-clock stubbed (the
                // SystemTime branch we're already in). Mix the
                // wasi:clocks/monotonic_clock (`wstd::time::Instant`)
                // — typically not subject to wall-clock skew and
                // distinct per process even when both wasi:random
                // and wasi:clocks/wall-clock are pre-epoch stubs.
                let skew_nanos = e.duration().as_nanos() as u64;
                let mono_nanos = monotonic_nanos_since_anchor();
                // N4: tri-state monotonic-clock detection — separate
                // codes for hard stub (zero advances across 3 spin
                // budgets) and live-but-coarse-resolution (1 or 2
                // advances). Pre-N4 collapsed both under
                // `monotonic_clock_stubbed`, which made the M4
                // 2-of-3 widening invisible to operators triaging
                // "did wasi:clocks/monotonic_clock actually stub?"
                // vs "did the host just have a coarse ticker?". The
                // wasi-mix below uses the clock either way, but the
                // operator action differs (config wasi-capability
                // imports vs accept ms-resolution jitter).
                match detect_monotonic_clock_state() {
                    MonotonicClockState::Live => {}
                    MonotonicClockState::Stubbed => {
                        let msg = "id_seed: wasi:clocks/monotonic_clock did \
                             not advance across any of 3 spin budgets \
                             (~1ms wall total) in addition to wasi:random \
                             + wasi:clocks/wall-clock being unavailable. \
                             High-confidence stub. ID uniqueness across \
                             restarts is fully degraded; within-launch \
                             counter fold in next_id remains the only \
                             defense. See  for wasi-capability \
                             configuration."
                            .to_string();
                        eprintln!("[chat-apc] {msg}");
                        diags.push(LaunchDiag {
                            code: CODE_MONOTONIC_CLOCK_STUBBED,
                            message: msg,
                        });
                    }
                    MonotonicClockState::CoarseResolution { advances } => {
                        let msg = format!(
                            "id_seed: wasi:clocks/monotonic_clock advanced \
                             only {advances}-of-3 spin budgets (~1ms wall \
                             total); live but coarse-resolution clock that \
                             cannot carry sub-ms id jitter. Within-launch \
                             counter fold in next_id remains the dominant \
                             defense against id collision."
                        );
                        eprintln!("[chat-apc] {msg}");
                        diags.push(LaunchDiag {
                            code: CODE_MONOTONIC_CLOCK_COARSE_RESOLUTION,
                            message: msg,
                        });
                    }
                }
                const BUILD_NONCE: u64 = 0x6368_6174_6170_6300; // "chatapc\0"
                let mixed = skew_nanos
                    .rotate_left(17)
                    ^ addr.rotate_left(13)
                    ^ mono_nanos.rotate_left(31)
                    ^ BUILD_NONCE;
                let msg = format!(
                    "id_seed: clock skewed ({e}) AND wasi:random returned \
                     all-zero buffer twice; using monotonic-clock + skew-nanos \
                     + address + build-nonce fallback. ID uniqueness across \
                     restarts depends on wasi:clocks/monotonic_clock (per-call \
                     mix in next_id provides additional defense). See  / \
                     wasi:random host configuration."
                );
                eprintln!("[chat-apc] {msg}");
                diags.push(LaunchDiag { code: CODE_ENTROPY_DEGRADED, message: msg });
                mixed
            } else {
                let entropy = u64::from_le_bytes(buf);
                let mixed = entropy ^ addr.rotate_left(13);
                let msg = format!(
                    "id_seed: system clock before UNIX_EPOCH ({e}); falling \
                     back to wasi-entropy seed (one-shot)"
                );
                eprintln!("[chat-apc] {msg}");
                diags.push(LaunchDiag {
                    code: CODE_CLOCK_SKEW_FALLBACK_ENTROPY,
                    message: msg,
                });
                mixed
            };
            // Guarantee non-zero — `0` is the "not yet seeded"
            // sentinel and CAS would loop forever on it.
            if candidate == 0 { 1 } else { candidate }
        }
    };
    // CAS pattern keeps the seed stable across concurrent first
    // callers — whichever one wins, every subsequent reader sees the
    // same value. The losing branch's eprintln still fired, but it's
    // a one-per-launch event in practice (and the cost is bounded by
    // concurrent first-call count, not request rate).
    let _ = SEED.compare_exchange(0, candidate, Ordering::Relaxed, Ordering::Relaxed);
}

/// Nanoseconds elapsed since the first call to this function (anchored
/// at first id-issue). Reads `wasi:clocks/monotonic_clock` via
/// `wstd::time::Instant`. Used as per-call inter-launch jitter when
/// `id_seed()` lands on a deterministic fallback (I1) — even if
/// wasi:random and wasi:clocks/wall-clock are both stubbed, the
/// monotonic clock is typically still live, so the format-level mix
/// keeps ids distinct.
fn monotonic_nanos_since_anchor() -> u64 {
    static ANCHOR: OnceLock<wstd::time::Instant> = OnceLock::new();
    let anchor = *ANCHOR.get_or_init(wstd::time::Instant::now);
    wstd::time::Instant::now().duration_since(anchor).as_nanos() as u64
}

/// Verdict from probing `wasi:clocks/monotonic_clock` against three
/// CPU-bound spin budgets. N4 splits the previous boolean
/// "stubbed/live" into three states so the resulting diag code can
/// distinguish a hard stub (operator must fix wasi capability) from
/// a live-but-coarse clock (operator accepts ms-jitter behavior).
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum MonotonicClockState {
    /// All three deltas advanced — clock is live with sub-ms tick.
    Live,
    /// 1 or 2 of 3 deltas advanced — clock is live but its tick
    /// resolution is coarser than the spin budgets, or it stalls
    /// intermittently. Either way, can't carry sub-ms id jitter.
    CoarseResolution { advances: u8 },
    /// Zero advances across all three budgets — high-confidence
    /// hard stub. wasi:clocks/monotonic_clock is not actually wired.
    Stubbed,
}

/// J5 + L3 + M4 + N4: detect monotonic-clock state by sampling four
/// `Instant`s across progressively-longer CPU-bound spin budgets.
/// Always runs ALL three budgets and classifies on the full sample;
/// callers map the state to one of two stable diag codes
/// (`monotonic_clock_stubbed` / `monotonic_clock_coarse_resolution`)
/// or skip the diag entirely when the clock is `Live`.
fn detect_monotonic_clock_state() -> MonotonicClockState {
    // ~300k total ops across three budgets ≈ ~1ms wall time on a
    // modern CPU. Always runs to completion so the live/coarse/
    // stubbed verdict is based on the full sample.
    const SPIN_BUDGETS: [u64; 3] = [4_096, 32_768, 262_144];
    let mut prev = wstd::time::Instant::now();
    let mut accum = 0u64;
    let mut advances = 0u8;
    for budget in SPIN_BUDGETS {
        for i in 0u64..budget {
            accum = accum.wrapping_add(i).rotate_left(13);
        }
        // `black_box` prevents the optimizer from eliding the spin —
        // without it the loop folds to a constant and runs in 0 cycles.
        std::hint::black_box(accum);
        let next = wstd::time::Instant::now();
        if next.duration_since(prev).as_nanos() > 0 {
            advances += 1;
        }
        prev = next;
    }
    match advances {
        3 => MonotonicClockState::Live,
        0 => MonotonicClockState::Stubbed,
        n => MonotonicClockState::CoarseResolution { advances: n },
    }
}

fn next_id() -> String {
    // F3: seed the high bits with launch-time nanos so a fresh
    // `launch_daemon` after a wasm-instance restart doesn't reissue
    // the same `chatcmpl-*` id space.
    // I1: fold per-call monotonic-clock nanos into the format so two
    // launches that happened to land on identical `id_seed()` values
    // (entropy stub + clock stub) still produce distinct ids — the
    // monotonic clock is a separate WIT surface from wall-clock and
    // typically remains live even when wall-clock is frozen.
    // J5: also fold the counter `n` into the low (mono) segment so
    // within-launch ids stay unique even when wasi:clocks/monotonic
    // is stubbed (mono stays 0; `mono.wrapping_add(n)` still
    // increments per call).
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mono = monotonic_nanos_since_anchor();
    format!(
        "chatcmpl-{:016x}{:016x}",
        id_seed().wrapping_add(n),
        mono.wrapping_add(n),
    )
}

// =============================================================================
// Entry points
// =============================================================================

pub async fn handle(req: Request<IncomingBody>, res: Responder) -> Finished {
    let (_parts, mut body) = req.into_parts();
    let mut body_bytes = Vec::new();
    if let Err(e) = sse::read_body(&mut body, &mut body_bytes, sse::CHAT_MAX_BODY).await {
        return res.respond(sse::body_error_response(e)).await;
    }

    let request: ChatCompletionsRequest = match serde_json::from_slice(&body_bytes) {
        Ok(r) => r,
        Err(e) => {
            // Force launch-diag init before responding so the
            // 400-only-launch case still attaches the header.
            let _ = launch_diags();
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    400,
                    "invalid_request",
                    &format!("Invalid JSON: {e}"),
                )))
                .await;
        }
    };

    handle_parsed(request, res).await
}

/// Handle a request whose body was parsed upstream — used by
/// `/v1/inferlet` dispatch so the messages-sugar surface can route
/// here without re-serializing.
pub async fn handle_parsed(request: ChatCompletionsRequest, res: Responder) -> Finished {
    // N1/M1: force the OnceLock initialization at the very top, ABOVE
    // all validation. A health-probe shape like `curl -d 'broken'
    // /v1/chat/completions` only ever hits a 400 — but the
    // `with_launch_diags_header` wrappers below still attach the
    // immutable diag snapshot to the error response, so operators
    // see launch-scope state even on a launch whose only request is
    // malformed. Idempotent past the first call (OnceLock fast path).
    let _ = launch_diags();

    // F8: reject empty model + blank content at the 400 boundary.
    // Otherwise `""` flows into `runtime::models().contains(&"")` and
    // surfaces as a misleading 404 `Model '' not registered`; empty
    // `content` lands in `ctx.user("")` and degenerates the prompt
    // with no diagnostic.
    if request.model.trim().is_empty() {
        return res
            .respond(with_launch_diags_header(json_error_param(
                400,
                "invalid_request",
                "model must be a non-empty string",
                "model",
            )))
            .await;
    }
    if request.messages.is_empty() {
        return res
            .respond(with_launch_diags_header(json_error_param(
                400,
                "invalid_request",
                "messages must be a non-empty list",
                "messages",
            )))
            .await;
    }
    // G4: use `trim().is_empty()` for parity with the model check
    // above. `content:"\n"` / `content:"   "` / zero-width-space
    // strings would otherwise slip through and feed `ctx.user("   ")`,
    // degenerating the prompt — the asymmetric `is_empty()` check
    // partially fixed F8 but left the whitespace path silently broken.
    if let Some((i, _)) = request
        .messages
        .iter()
        .enumerate()
        .find(|(_, m)| m.content.trim().is_empty())
    {
        let body = serde_json::json!({
            "error": {
                "type": "invalid_request_error",
                "code": "invalid_request",
                "message": "message content must be a non-empty, non-whitespace string",
                "param": format!("messages[{i}].content"),
            }
        });
        let response = Response::builder()
            .status(400)
            .header("Content-Type", "application/json")
            .body(body.to_string().into_body())
            .unwrap();
        return res.respond(with_launch_diags_header(response)).await;
    }

    let max_output_ceiling = max_output_ceiling();
    let effective_max_tokens = match validate_sampling(&request, max_output_ceiling) {
        Ok(max_tokens) => max_tokens,
        Err((field, msg)) => {
            return res
                .respond(with_launch_diags_header(json_error_param(
                    400,
                    "invalid_request",
                    &msg,
                    field,
                )))
                .await;
        }
    };

    // F4: reject `role:"tool"` until the chat template grows a real
    // tool slot. Silent demotion to `user` (the prior `_` arm in
    // `fill_context`) makes multi-turn tool-call round-trips quietly
    // wrong — better to fail loud than ship half-wired tool support.
    if let Some((i, m)) = request
        .messages
        .iter()
        .enumerate()
        .find(|(_, m)| m.role == "tool")
    {
        let body = serde_json::json!({
            "error": {
                "type": "invalid_request_error",
                "code": "tool_role_unsupported",
                "message": format!(
                    "messages[{i}].role=\"tool\" is not yet supported (chat template has no tool slot); \
                     post the tool result as a user turn or wait for the SDK tool-answer surface to land"
                ),
                "param": format!("messages[{i}].role"),
            }
        });
        let _ = m;
        let response = Response::builder()
            .status(400)
            .header("Content-Type", "application/json")
            .body(body.to_string().into_body())
            .unwrap();
        return res.respond(with_launch_diags_header(response)).await;
    }

    let registered = runtime::models();
    if !registered.iter().any(|m| m == &request.model) {
        return res
            .respond(with_launch_diags_header(sse::json_error(
                404,
                "model_not_found",
                &format!("Model '{}' not registered with this engine", request.model),
            )))
            .await;
    }

    // N1: no per-request drain — handlers read directly from the
    // immutable OnceLock snapshot via `launch_diags()`. Every path
    // (success + 400 + 404 + 500) gets the same Vec; SSE warnings
    // and non-stream `warnings` field and `X-ChatAPC-Launch-Diags`
    // header all source from the same place.
    if request.stream {
        handle_streaming(request, res, effective_max_tokens).await
    } else {
        handle_non_streaming(request, res, effective_max_tokens).await
    }
}

// =============================================================================
// Validation (F7)
// =============================================================================

/// Per-request `max_tokens` ceiling, read live from the engine. This is
/// `runtime::max-output-tokens()` — the runtime-reported output-token
/// ceiling: configured scheduler `default_token_limit` capped by raw KV
/// capacity when set, otherwise raw KV capacity. Falls back to
/// `MAX_OUTPUT_TOKENS_FALLBACK` when the engine reports 0 (no model
/// registered / ceiling unknown).
fn max_output_ceiling() -> usize {
    match runtime::max_output_tokens() as usize {
        0 => MAX_OUTPUT_TOKENS_FALLBACK,
        n => n,
    }
}

/// `max_output_ceiling` is the inclusive upper bound on `max_tokens`,
/// supplied by the caller from `runtime::max-output-tokens` so validation
/// follows the runtime-reported ceiling (configured `default_token_limit`
/// capped by KV capacity, or raw KV capacity when unset) instead of a
/// hardcoded constant. Kept as a parameter — rather than reading the host
/// import in here — so this stays a pure function the unit tests can drive
/// without an engine host.
/// Returns the effective generation `max_tokens` budget. For omitted
/// `max_tokens`, the default is clamped down to the runtime ceiling so the
/// common default request path cannot exceed a memory-aware engine limit.
/// Returns `Err((field, message))` where `field` names the offending JSON key
/// (passed to the OpenAI-shape error envelope's `param`).
fn validate_sampling(
    req: &ChatCompletionsRequest,
    max_output_ceiling: usize,
) -> Result<usize, (&'static str, String)> {
    if let Some(t) = req.temperature {
        if !(t.is_finite() && (0.0..=MAX_TEMPERATURE).contains(&t)) {
            return Err((
                "temperature",
                format!("temperature must be in [0.0, {MAX_TEMPERATURE}]"),
            ));
        }
    }
    if let Some(p) = req.top_p {
        if !(p.is_finite() && p > 0.0 && p <= MAX_TOP_P) {
            return Err(("top_p", format!("top_p must be in (0.0, {MAX_TOP_P}]")));
        }
    }
    let effective_max_tokens = match req.max_tokens {
        Some(n) if n == 0 || n > max_output_ceiling => {
            return Err((
                "max_tokens",
                format!("max_tokens must be in [1, {max_output_ceiling}]"),
            ));
        }
        Some(n) => n,
        None => DEFAULT_MAX_TOKENS.min(max_output_ceiling),
    };
    // #418: range-check the speculation knobs at the 400 boundary so an
    // out-of-range value is rejected with a `param`, mirroring
    // `max_tokens` — rather than silently coerced by `to_config`'s
    // `.clamp`. `enabled` is a bool (nothing to range-check); cache caps
    // are internal (not request-settable).
    if let Some(spec) = &req.speculation {
        if let Some(n) = spec.leader_len {
            if !(MIN_LEADER_LEN..=MAX_LEADER_LEN).contains(&n) {
                return Err((
                    "speculation.leader_len",
                    format!("speculation.leader_len must be in [{MIN_LEADER_LEN}, {MAX_LEADER_LEN}]"),
                ));
            }
        }
        if let Some(n) = spec.draft_len {
            if !(MIN_DRAFT_LEN..=MAX_DRAFT_LEN).contains(&n) {
                return Err((
                    "speculation.draft_len",
                    format!("speculation.draft_len must be in [{MIN_DRAFT_LEN}, {MAX_DRAFT_LEN}]"),
                ));
            }
        }
    }
    Ok(effective_max_tokens)
}

/// Build an OpenAI-shape error JSON with a populated `param` field.
pub(crate) fn json_error_param(
    status: u16,
    code: &str,
    message: &str,
    param: &'static str,
) -> Response<wstd::http::body::BoundedBody<Vec<u8>>> {
    let body = serde_json::json!({
        "error": {
            "type": "invalid_request_error",
            "code": code,
            "message": message,
            "param": param,
        }
    });
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(body.to_string().into_body())
        .unwrap()
}

// =============================================================================
// Streaming branch
// =============================================================================

async fn handle_streaming(
    req: ChatCompletionsRequest,
    res: Responder,
    max_tokens: usize,
) -> Finished {
    let temperature = req.temperature.unwrap_or(DEFAULT_TEMPERATURE);
    let top_p = req.top_p.unwrap_or(DEFAULT_TOP_P);

    // F9: load the model BEFORE opening the SSE response so a load
    // failure returns a clean 5xx JSON envelope rather than a
    // misleading `model_ready` followed by an error frame. N1: the
    // pre-Emitter 500 paths attach the immutable launch-diags
    // snapshot via the response header — no drain/restore dance
    // needed since the OnceLock isn't mutated by these paths.
    let model = match Model::load(&req.model) {
        Ok(m) => m,
        Err(e) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    500,
                    "model_load_failed",
                    &format!("Failed to load model: {e}"),
                )))
                .await;
        }
    };
    let mut ctx = match Context::new(&model) {
        Ok(c) => c,
        Err(e) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    500,
                    "context_create_failed",
                    &format!("Failed to create context: {e}"),
                )))
                .await;
        }
    };
    if let Err((code, msg)) = fill_context(&mut ctx, &model, &req.messages, req.tools.as_deref(), true) {
        return res
            .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
            .await;
    }

    // `tool_choice: "required" | {function}` constrains generation to the
    // model's native tool-call grammar (OpenAI tool_choice enforcement).
    // Built BEFORE the Emitter so an unsatisfiable directive returns a
    // clean 4xx JSON envelope instead of a half-open stream.
    let tool_constraint = match build_forced_tool_constraint(
        &model,
        req.tools.as_deref(),
        req.tool_choice.as_ref(),
    ) {
        Ok(c) => c,
        Err((status, code, msg)) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(status, code, &msg)))
                .await;
        }
    };
    let forced_tool = tool_constraint.is_some();

    // Headers committed; from here we must finish via the Emitter.
    let mut em = Emitter::start(res);
    let id = next_id();
    let created = now_unix_secs();

    // J3 + N1: emit warnings BEFORE `model_ready`. Source is the
    // immutable OnceLock snapshot via `launch_diags()` — same Vec on
    // every request, no drain/restore. SSE Disconnect or Serialize
    // mid-emit is a fatal-stream event; we just unwind silently
    // (Disconnect) or with a single recovery meta-frame (Serialize).
    // Future requests still see the same diags via their own header /
    // body emit (no state to preserve here).
    for diag in launch_diags() {
        let frame = sse::SseWarning::new(diag.code, &diag.message);
        match em.emit_json(&frame).await {
            Ok(()) => {}
            Err(EmitError::Disconnected) => return em.finish(),
            Err(EmitError::Serialize(e)) => {
                eprintln!("[chat-apc] launch_warning serialize bug: {e}");
                let orig_msg = e.to_string();
                match em
                    .emit_json(&SseError::new("serialize_bug", &orig_msg))
                    .await
                {
                    Ok(()) => {}
                    Err(EmitError::Disconnected) => {}
                    Err(EmitError::Serialize(e2)) => {
                        eprintln!(
                            "[chat-apc] launch_warning serialize_bug meta-frame \
                             ALSO failed to serialize: {e2} (original: {orig_msg})"
                        );
                    }
                }
                sse::emit_done_logged(&mut em, "launch_warning_serialize_recover").await;
                return em.finish();
            }
        }
    }

    // F9: emit `model_ready` only after a successful load + context
    // creation. Clients that pin on this frame to flip the loading
    // indicator never see a false positive.
    try_emit!(em, &sse::ModelReady::new(), "model_ready");

    // OpenAI clients (incl. the openai-python SDK's iterator) rely
    // on a leading role-only delta to seed the assistant-message
    // accumulator before any content arrives.
    let role_chunk = ChatCompletionChunk {
        id: &id,
        object: "chat.completion.chunk",
        created,
        model: &req.model,
        choices: vec![ChunkChoice {
            index: 0,
            delta: ChunkDelta {
                role: Some("assistant"),
                ..Default::default()
            },
            finish_reason: None,
        }],
    };
    try_emit!(em, &role_chunk, "role_chunk");

    let stop_tokens = chat::stop_tokens(&model);
    // #418: pick plain vs speculative decode. Speculation engages only
    // when requested, greedy (temperature 0), AND no tool call is forced
    // — a forced tool call constrains the sampler to the tool-call
    // grammar, and the drafter's verify must not run against a
    // grammar-constrained sampler. Otherwise plain decode, with
    // `fallback_reason` reporting why (no silent no-op).
    let greedy = temperature <= 0.0;
    let (strategy, fallback_reason, want_metrics, dims) =
        plan_strategy(req.speculation.as_ref(), greedy, forced_tool);
    let spec_enabled = matches!(strategy, DecodeStrategy::Speculative(_));
    let sampler = generate::resolve_sampler(temperature, top_p);
    let seed_tokens = if spec_enabled {
        seed_tokens_from(&model, &req.messages)
    } else {
        Vec::new()
    };
    let generate::GenSession {
        generator: mut stream,
        metrics: spec_metrics_handle,
    } = generate::start(&mut ctx, sampler, max_tokens, &stop_tokens, strategy, &seed_tokens);
    // tool_choice enforcement (from main): constrain to the tool-call
    // grammar when a call is forced. Speculation is gated off in that
    // case (`forced_tool` above), so this only ever applies to the plain
    // generator.
    if let Some(c) = tool_constraint {
        stream = stream.constrain(c);
    }
    let mut spec_generated = 0usize;
    let mut spec_steps = 0usize;
    let spec_start = Instant::now();
    let mut decoder = chat::Decoder::new(&model);
    // Reasoning decoder is always live — cheap on models without a
    // thinking template (returns `Idle` for every batch). Tool-use
    // decoder only matters when the caller equipped tools; the host
    // surface is the same shape either way.
    let mut reason_dec = ReasoningDecoder::new(&model);
    let mut tool_dec = ToolUseDecoder::new(&model);
    let mut tool_dec_active = req.tools.as_ref().is_some_and(|t| !t.is_empty());
    // G2: when the tool decoder errors mid-turn and we keep
    // generating (F9), capture the diagnostic so the terminal chunk
    // can carry a `tool_decode_disabled` warning meta-frame. Without
    // this, a request with `tools:[…]` that produces no `tool_calls`
    // looks identical to "model chose not to call a tool" — and any
    // partial tool tokens that bled into the chat decoder ship as
    // plain content with no client-visible signal.
    let mut tool_disabled_diag: Option<ToolDisabledDiag> = None;
    let mut pending_tool: Option<PendingToolCall> = None;
    let mut in_reasoning = false;

    // F1/F2/F3/F5: explicit-match loop with an `Outcome` set at the
    // exit point. `Generator::next` Err, decoder Err, and chat-
    // template `Interrupt` all surface as `Outcome::Aborted` with a
    // diagnostic; no code path falls through to a fake "stop".
    let (outcome, error_diag): (Outcome, Option<(&str, String)>) = loop {
        let step = match stream.next() {
            Ok(None) => {
                // `next()` returns None once the generator is done.
                // Distinguish a max_tokens cap ("length") from a stop-token
                // natural end ("stop"): the SDK truncates the stop token out
                // of `out.tokens` (it's in `chat::stop_tokens`) before the
                // chat decoder ever sees it, so a stop-token end never reaches
                // the `Event::Done` arm below and would otherwise be
                // mislabeled "length". The ticket's contract is explicit:
                // length on the cap, stop on natural end (#439).
                let reason = if stream.tokens_generated() >= max_tokens {
                    Outcome::MaxTokens
                } else {
                    Outcome::Natural
                };
                break (reason, None);
            }
            Ok(Some(s)) => s,
            Err(e) => break (Outcome::Aborted, Some(("forward_pass_failed", e.to_string()))),
        };
        let out = match step.execute().await {
            Ok(o) => o,
            Err(e) => break (Outcome::Aborted, Some(("forward_pass_failed", e.to_string()))),
        };
        // #439: a decode step that returns no sampled token means the
        // forward-pass layer starved — pie swallows a device failure / batch
        // timeout / mid-stream KV eviction into an empty output rather than an
        // error, and the SDK folds that in as zero progress. Break with an
        // explicit reason so the stream still carries a terminal
        // `finish_reason` (instead of truncating into the app's
        // `missing_finish_reason` fallback), and so the loop never issues the
        // empty-input forward pass that hangs the Metal driver.
        if forward_pass_starved(&out.raw().slots) {
            break (Outcome::Aborted, Some((STARVED_CODE, STARVED_MESSAGE.to_string())));
        }
        // #418: per-step decode accounting (one forward pass; `out.tokens`
        // is a burst of 1 free pick + accepted drafts under speculation).
        spec_steps += 1;
        spec_generated += out.tokens.len();

        // Reasoning side: thinking-blocks become `reasoning_content`
        // deltas. `Idle` is the no-op signal; `Start` flips the
        // `in_reasoning` guard so chat::Delta arms inside the block
        // are not double-emitted as visible content (mirrors the
        // text-completion canonical loop in pie/inferlets).
        // capture the gate state BEFORE feeding the reasoning
        // decoder — `feed` flips `in_reasoning` as a side effect of
        // consuming a boundary token, and the chat decoder (fed below)
        // must be gated on the batch's channel, not the post-flip state.
        let was_in_reasoning = in_reasoning;
        let mut reason_idle = false;
        match reason_dec.feed(&out.tokens) {
            Ok(inferlet::reasoning::Event::Start) => {
                in_reasoning = true;
            }
            Ok(inferlet::reasoning::Event::Delta(s)) => {
                in_reasoning = true;
                let chunk = ChatCompletionChunk {
                    id: &id,
                    object: "chat.completion.chunk",
                    created,
                    model: &req.model,
                    choices: vec![ChunkChoice {
                        index: 0,
                        delta: ChunkDelta {
                            reasoning_content: Some(&s),
                            ..Default::default()
                        },
                        finish_reason: None,
                    }],
                };
                try_emit!(em, &chunk, "reasoning_delta");
            }
            Ok(inferlet::reasoning::Event::End(_)) => {
                in_reasoning = false;
            }
            Ok(inferlet::reasoning::Event::Idle) => {
                reason_idle = true;
            }
            Err(e) => break (Outcome::Aborted, Some(("reasoning_decode_failed", e.to_string()))),
        }

        // Tool-use side: a completed `Call(name, args)` terminates
        // generation with `finish_reason: "tool_calls"`. The delta
        // frame is buffered (emitted on the terminal chunk so the
        // index/id appears on the same frame as the finish_reason,
        // matching OpenAI's wire shape).
        if tool_dec_active {
            match tool_dec.feed(&out.tokens) {
                Ok(inferlet::tools::Event::Call(name, args)) => {
                    pending_tool = Some(PendingToolCall {
                        id: next_tool_call_id(),
                        name,
                        arguments: args,
                    });
                    break (Outcome::ToolCalls, None);
                }
                Ok(inferlet::tools::Event::Start) => {}
                // F9: see non-stream branch for rationale — disable
                // the tool decoder for the rest of the turn rather
                // than aborting a viable plain-text reply.
                Err(e) => {
                    let msg = e.to_string();
                    eprintln!("[chat-apc] tool decoder disabled mid-turn: {msg}");
                    tool_dec_active = false;
                    // G2: keep only the first failure — chained
                    // errors on subsequent tokens are usually the
                    // same root cause and would dilute the signal.
                    ToolDisabledDiag::record(&mut tool_disabled_diag, msg);
                }
            }
        }

        match decoder.feed(&out.tokens) {
            // When a forced `tool_choice` constrains output to the
            // tool-call grammar, the ENTIRE generation IS the call
            // (`root` has no free-text alternative), so suppress the
            // visible content channel — the call rides only the terminal
            // `tool_calls` delta (OpenAI emits content:null alongside
            // tool_calls). Composes with the reasoning content gate; the
            // suppressed deltas fall through to the no-op arm below.
            Ok(chat::Event::Delta(s)) if content_visible(reason_idle, was_in_reasoning) && !forced_tool => {
                let chunk = ChatCompletionChunk {
                    id: &id,
                    object: "chat.completion.chunk",
                    created,
                    model: &req.model,
                    choices: vec![ChunkChoice {
                        index: 0,
                        delta: ChunkDelta {
                            content: Some(&s),
                            ..Default::default()
                        },
                        finish_reason: None,
                    }],
                };
                // Non-terminal delta frame: disconnect = silently
                // abandon (no client to push to); serialize-bug =
                // emit inline error frame + [DONE] before bailing,
                // so any client still attached gets a signal.
                try_emit!(em, &chunk, "content_delta");
            }
            Ok(chat::Event::Delta(_)) => {
                // Suppressed: this batch is reasoning-channel material —
                // either inside a `<think>` block, or the opening/closing
                // delimiter itself. The chat decoder is model-generic and
                // surfaces the delimiter text (`<think>` / `</think>`) as a
                // Delta; `content_visible` keeps it off the visible channel
                // so the scratchpad and its delimiters never leak.
            }
            Ok(chat::Event::Done(_)) => break (Outcome::Natural, None),
            Ok(chat::Event::Interrupt(id)) => {
                break (
                    Outcome::Aborted,
                    Some(("chat_template_interrupt", format!("control token {id} from chat template")))
                );
            }
            Ok(chat::Event::Idle) => continue,
            Err(e) => break (Outcome::Aborted, Some(("decode_failed", e.to_string()))),
        }
    };

    // F1: a forced `tool_choice` whose constrained generation never closed
    // a complete tool call (max_tokens too small for the args, a natural
    // stop before `Event::Call`, or a mid-turn tool-decoder disable) leaves
    // `pending_tool` None. Content was suppressed on the forced path, so the
    // default terminal here would be a deceptive empty success
    // (`finish_reason:"stop"`/`"length"`, no `tool_calls`, no error) —
    // silently dropping the directive this path exists to enforce. The
    // "preserve a viable plain-text reply" rationale does not apply when
    // content is suppressed. Reclassify as an explicit error so the terminal
    // chunk carries `finish_reason:"error"` + the diagnostic meta-frame.
    let (outcome, error_diag) = if forced_tool && pending_tool.is_none() && error_diag.is_none() {
        (
            Outcome::Aborted,
            Some((
                "tool_call_not_produced",
                "tool_choice forced a tool call but generation ended before a complete \
                 tool call was produced; raise max_tokens or relax tool_choice"
                    .to_string(),
            )),
        )
    } else {
        (outcome, error_diag)
    };

    // Terminal chunk first so OpenAI clients see a `finish_reason`
    // in the canonical envelope (F8). When the loop exited via
    // ToolCalls, the buffered call lands here on the same frame —
    // OpenAI's wire shape pairs `tool_calls` deltas with the
    // finish_reason chunk rather than emitting them on separate
    // events. The diagnostic meta-frame follows for pie-native
    // clients that want the detail.
    let final_delta = match &pending_tool {
        Some(call) => ChunkDelta {
            tool_calls: Some(vec![ChunkToolCall {
                index: 0,
                id: &call.id,
                kind: "function",
                function: ChunkToolCallFunction {
                    name: &call.name,
                    arguments: &call.arguments,
                },
            }]),
            ..Default::default()
        },
        None => ChunkDelta::default(),
    };
    let final_chunk = ChatCompletionChunk {
        id: &id,
        object: "chat.completion.chunk",
        created,
        model: &req.model,
        choices: vec![ChunkChoice {
            index: 0,
            delta: final_delta,
            finish_reason: Some(outcome.finish_reason()),
        }],
    };
    // Each emit returns `Result<(), EmitError>`. We surface Serialize
    // bugs to stderr (pie-server's log capture picks them up — better
    // than silent corruption) while letting Disconnected end the
    // stream silently. The Disconnected branch happens on every
    // closed peer; the Serialize branch should be impossible against
    // our hand-checked schemas, so logging it is host-visible signal.
    if let Err(EmitError::Serialize(e)) = em.emit_json(&final_chunk).await {
        eprintln!("[chat-apc] final-chunk serialize bug: {e}");
    }
    // G2: emit a `tool_decode_disabled` warning meta-frame BEFORE
    // the diagnostic-error frame, so a client parsing the SSE log
    // sees the F9 degraded path explicitly. Without this, a request
    // with `tools:[…]` that completed with `finish_reason:"stop"`
    // and `tool_calls:None` looks identical to "model chose not to
    // call a tool" — but raw tool tokens may have bled into
    // `content` after the decoder gave up.
    if let Some(diag) = &tool_disabled_diag {
        let rendered = diag.render();
        let (distinct, overflow) = diag.dedup_counts();
        // N3: ship raw counts as structured fields so consumers don't
        // string-parse the rendered "(capped, total >= N)" tail.
        let frame = SseError::new("tool_decode_disabled", &rendered)
            .with_dedup_counts(distinct, overflow);
        match em.emit_json(&frame).await {
            Ok(()) => {}
            // H4: the warning meta-frame sits BETWEEN the terminal
            // chunk and `[DONE]` — it's not the normal end-of-stream
            // site, so a peer that closes after `final_chunk` but
            // before this frame silently loses the F9 degraded
            // signal. Reserve Disconnected-silence for the `[DONE]`
            // terminator only; log here so operators can correlate
            // "client got finish_reason:'stop'" with "but the
            // decoder had bailed and the warning was dropped."
            Err(EmitError::Disconnected) => {
                eprintln!(
                    "[chat-apc] tool_decode_disabled meta-frame dropped: \
                     peer disconnect before warning could be delivered \
                     (client sees finish_reason without the diag)"
                );
            }
            Err(EmitError::Serialize(e)) => {
                eprintln!("[chat-apc] tool-decode-disabled meta-frame serialize bug: {e}");
            }
        }
    }
    if let Some((code, message)) = &error_diag {
        if let Err(EmitError::Serialize(e)) = em.emit_json(&SseError::new(code, message)).await {
            eprintln!("[chat-apc] error-meta serialize bug: {e}");
        }
    }
    // #418: terminal spec_metrics frame (only when the caller opted into
    // the speculation surface, so normal streams are byte-identical).
    if want_metrics {
        let spec = spec_metrics_handle
            .map(|h| *h.lock().unwrap())
            .unwrap_or_default();
        let report = SpecMetricsReport::build(
            spec_enabled,
            fallback_reason,
            dims,
            spec,
            spec_generated,
            spec_steps,
            spec_start.elapsed(),
        );
        report.log_spec_stats();
        let frame = SpecMetricsSse {
            event: "spec_metrics",
            report: &report,
        };
        if let Err(EmitError::Serialize(e)) = em.emit_json(&frame).await {
            eprintln!("[chat-apc] spec_metrics serialize bug: {e}");
        }
    }
    sse::emit_done_logged(&mut em, "stream_exit").await;
    em.finish()
}

// =============================================================================
// Non-streaming branch (F4 — finish_reason driven by actual termination)
// =============================================================================

async fn handle_non_streaming(
    req: ChatCompletionsRequest,
    res: Responder,
    max_tokens: usize,
) -> Finished {
    let temperature = req.temperature.unwrap_or(DEFAULT_TEMPERATURE);
    let top_p = req.top_p.unwrap_or(DEFAULT_TOP_P);

    // N1: pre-loop 500 paths attach the immutable launch-diags
    // snapshot via the response header. No drain/restore needed —
    // the OnceLock is read-only across requests.
    let model = match Model::load(&req.model) {
        Ok(m) => m,
        Err(e) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    500,
                    "model_load_failed",
                    &format!("Failed to load model: {e}"),
                )))
                .await;
        }
    };
    let mut ctx = match Context::new(&model) {
        Ok(c) => c,
        Err(e) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    500,
                    "context_create_failed",
                    &format!("Failed to create context: {e}"),
                )))
                .await;
        }
    };
    if let Err((code, msg)) = fill_context(&mut ctx, &model, &req.messages, req.tools.as_deref(), true) {
        return res
            .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
            .await;
    }

    // tool_choice enforcement (mirrors handle_streaming): constrain to the
    // model's native tool-call grammar when a call is forced; an
    // unsatisfiable directive returns a 4xx before generation begins.
    let tool_constraint = match build_forced_tool_constraint(
        &model,
        req.tools.as_deref(),
        req.tool_choice.as_ref(),
    ) {
        Ok(c) => c,
        Err((status, code, msg)) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(status, code, &msg)))
                .await;
        }
    };
    let forced_tool = tool_constraint.is_some();
    let stop_tokens = chat::stop_tokens(&model);
    // #418: plain vs speculative decode (see handle_streaming for the
    // greedy + forced-tool gate rationale).
    let greedy = temperature <= 0.0;
    let (strategy, fallback_reason, want_metrics, dims) =
        plan_strategy(req.speculation.as_ref(), greedy, forced_tool);
    let spec_enabled = matches!(strategy, DecodeStrategy::Speculative(_));
    let sampler = generate::resolve_sampler(temperature, top_p);
    let seed_tokens = if spec_enabled {
        seed_tokens_from(&model, &req.messages)
    } else {
        Vec::new()
    };
    let generate::GenSession {
        generator: mut stream,
        metrics: spec_metrics_handle,
    } = generate::start(&mut ctx, sampler, max_tokens, &stop_tokens, strategy, &seed_tokens);
    // tool_choice enforcement (from main); spec is gated off when forced,
    // so this only applies to the plain generator.
    if let Some(c) = tool_constraint {
        stream = stream.constrain(c);
    }
    let mut spec_generated = 0usize;
    let mut spec_steps = 0usize;
    let spec_start = Instant::now();
    let mut decoder = chat::Decoder::new(&model);
    let mut reason_dec = ReasoningDecoder::new(&model);
    let mut tool_dec = ToolUseDecoder::new(&model);
    let mut tool_dec_active = req.tools.as_ref().is_some_and(|t| !t.is_empty());
    // G2: same diag-capture as the streaming branch; surfaces as a
    // `tool_decode_disabled` PartialError on the response when the
    // decoder bailed mid-turn but generation kept going.
    let mut tool_disabled_diag: Option<ToolDisabledDiag> = None;
    let mut full_text = String::new();
    let mut reasoning_text = String::new();
    let mut pending_tool: Option<PendingToolCall> = None;
    let mut in_reasoning = false;

    // F4: drive the loop ourselves so we can record the actual
    // termination reason. `collect_text` collapsed natural stop and
    // max-tokens cap into the same `Ok(String)` return, which made
    // it impossible to distinguish `"stop"` from `"length"` on the
    // wire.
    let (outcome, error_diag): (Outcome, Option<(&str, String)>) = loop {
        let step = match stream.next() {
            Ok(None) => {
                // `next()` returns None once the generator is done.
                // Distinguish a max_tokens cap ("length") from a stop-token
                // natural end ("stop"): the SDK truncates the stop token out
                // of `out.tokens` (it's in `chat::stop_tokens`) before the
                // chat decoder ever sees it, so a stop-token end never reaches
                // the `Event::Done` arm below and would otherwise be
                // mislabeled "length". The ticket's contract is explicit:
                // length on the cap, stop on natural end (#439).
                let reason = if stream.tokens_generated() >= max_tokens {
                    Outcome::MaxTokens
                } else {
                    Outcome::Natural
                };
                break (reason, None);
            }
            Ok(Some(s)) => s,
            Err(e) => break (Outcome::Aborted, Some(("forward_pass_failed", e.to_string()))),
        };
        let out = match step.execute().await {
            Ok(o) => o,
            Err(e) => break (Outcome::Aborted, Some(("forward_pass_failed", e.to_string()))),
        };
        // #439: a decode step that returns no sampled token means the
        // forward-pass layer starved — pie swallows a device failure / batch
        // timeout / mid-stream KV eviction into an empty output rather than an
        // error, and the SDK folds that in as zero progress. Break with an
        // explicit reason so the stream still carries a terminal
        // `finish_reason` (instead of truncating into the app's
        // `missing_finish_reason` fallback), and so the loop never issues the
        // empty-input forward pass that hangs the Metal driver.
        if forward_pass_starved(&out.raw().slots) {
            break (Outcome::Aborted, Some((STARVED_CODE, STARVED_MESSAGE.to_string())));
        }
        // #418: per-step decode accounting (one forward pass; `out.tokens`
        // is a burst of 1 free pick + accepted drafts under speculation).
        spec_steps += 1;
        spec_generated += out.tokens.len();

        // capture the gate state BEFORE feeding the reasoning
        // decoder (see streaming branch + `content_visible`). Mirrors the
        // streaming gate so stream + non-stream produce identical content.
        let was_in_reasoning = in_reasoning;
        let mut reason_idle = false;
        match reason_dec.feed(&out.tokens) {
            Ok(inferlet::reasoning::Event::Start) => in_reasoning = true,
            Ok(inferlet::reasoning::Event::Delta(s)) => {
                in_reasoning = true;
                reasoning_text.push_str(&s);
            }
            // F5: discard the End payload to stay byte-identical with
            // the streaming branch (which also ignores it). The
            // delta-stitched `reasoning_text` is the single source of
            // truth across stream + non-stream; trusting `End(s)` on
            // one branch and not the other made the same prompt
            // produce divergent `reasoning_content` on `stream:true`
            // vs `stream:false` whenever the decoder's End payload
            // disagreed with the accumulated deltas.
            Ok(inferlet::reasoning::Event::End(_)) => {
                in_reasoning = false;
            }
            Ok(inferlet::reasoning::Event::Idle) => {
                reason_idle = true;
            }
            Err(e) => break (Outcome::Aborted, Some(("reasoning_decode_failed", e.to_string()))),
        }

        if tool_dec_active {
            match tool_dec.feed(&out.tokens) {
                Ok(inferlet::tools::Event::Call(name, args)) => {
                    pending_tool = Some(PendingToolCall {
                        id: next_tool_call_id(),
                        name,
                        arguments: args,
                    });
                    break (Outcome::ToolCalls, None);
                }
                Ok(inferlet::tools::Event::Start) => {}
                // F9: a tool-decoder error on a token that wasn't
                // actually a tool call shouldn't brick an otherwise-
                // fine chat reply. Disable the decoder for the rest
                // of the turn and log once; reserve `Aborted` for
                // forward-pass and chat-decoder failures that
                // genuinely can't continue.
                Err(e) => {
                    let msg = e.to_string();
                    eprintln!("[chat-apc] tool decoder disabled mid-turn: {msg}");
                    tool_dec_active = false;
                    ToolDisabledDiag::record(&mut tool_disabled_diag, msg);
                }
            }
        }

        match decoder.feed(&out.tokens) {
            // Forced tool_choice suppresses visible content (see
            // handle_streaming) — the call surfaces only via tool_calls.
            Ok(chat::Event::Delta(s)) if content_visible(reason_idle, was_in_reasoning) && !forced_tool => {
                full_text.push_str(&s)
            }
            Ok(chat::Event::Delta(_)) => {}
            // F1: trust the delta-stitched `full_text` that respects the
            // reasoning channel (`content_visible`). The chat decoder runs
            // alongside (not downstream of) the reasoning decoder, so
            // `Done(s)` typically still contains the `<think>...</think>`
            // span — overwriting `full_text` with it leaks reasoning into
            // visible content. Streaming gates content deltas the
            // same way; mirror that here so stream + non-stream
            // produce the same `content` for the same prompt.
            Ok(chat::Event::Done(_)) => {
                break (Outcome::Natural, None);
            }
            Ok(chat::Event::Interrupt(tok)) => {
                break (
                    Outcome::Aborted,
                    Some((
                        "chat_template_interrupt",
                        format!("control token {tok} from chat template"),
                    )),
                );
            }
            Ok(chat::Event::Idle) => continue,
            Err(e) => break (Outcome::Aborted, Some(("decode_failed", e.to_string()))),
        }
    };

    // F1: forced `tool_choice` that never closed a complete tool call (see
    // the streaming branch) leaves `pending_tool` None with content
    // suppressed — reclassify as an explicit error so the no-tokens-produced
    // branch below returns a 500 instead of a deceptive empty 200.
    let (outcome, error_diag) = if forced_tool && pending_tool.is_none() && error_diag.is_none() {
        (
            Outcome::Aborted,
            Some((
                "tool_call_not_produced",
                "tool_choice forced a tool call but generation ended before a complete \
                 tool call was produced; raise max_tokens or relax tool_choice"
                    .to_string(),
            )),
        )
    } else {
        (outcome, error_diag)
    };

    // F2: only the no-tokens-produced abort drops to a bare 500.
    // When the loop produced visible content or a pending tool call
    // before failing, return the partial body with
    // `finish_reason:"error"` and a top-level `error` block so the
    // caller can salvage the work. Matches the streaming branch,
    // which already emits the partial body + a terminal error chunk.
    let has_partial = !full_text.is_empty() || pending_tool.is_some() || !reasoning_text.is_empty();
    if error_diag.is_some() && !has_partial {
        let (code, msg) = error_diag.unwrap();
        // N1: pure-failure 500 attaches launch diags via header —
        // the snapshot is immutable, so the next request gets the
        // same diags regardless.
        return res
            .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
            .await;
    }

    let id = next_id();
    let tool_calls_vec: Option<Vec<NonStreamToolCall>> = pending_tool.as_ref().map(|c| {
        vec![NonStreamToolCall {
            id: &c.id,
            kind: "function",
            function: ChunkToolCallFunction {
                name: &c.name,
                arguments: &c.arguments,
            },
        }]
    });
    let reasoning_opt = if reasoning_text.is_empty() {
        None
    } else {
        Some(reasoning_text.as_str())
    };
    // Error block priority: a fatal `error_diag` wins, otherwise
    // surface the G2 `tool_decode_disabled` warning when the tool
    // decoder bailed mid-turn but generation completed normally. Both
    // None → no block (and the field is `skip_serializing_if = none`).
    // H2: OpenAI-shape `{error:{type,code,message,param}}` at the
    // JSON root — stock SDKs (openai-python ≥1.x) surface this as
    // `response.error` on a successful 200 without raising. The
    // previous 502+partial-body shape lost the content under
    // `openai-python`'s APIStatusError.
    // H3: pre-render the tool-disabled diag so message carries
    // first + dropped-count + last when multiple decoder errors fired.
    // N3: also pre-extract the raw dedup-cap counts so they ride the
    // PartialError as structured numeric fields (downstream tooling
    // reads them directly instead of parsing "(capped, total >= N)").
    let tool_disabled_rendered = tool_disabled_diag.as_ref().map(|d| d.render());
    let tool_disabled_counts = tool_disabled_diag.as_ref().map(|d| d.dedup_counts());
    let error_block = match (&error_diag, &tool_disabled_rendered) {
        (Some((code, msg)), _) => Some(PartialError {
            kind: "server_error",
            code,
            message: msg.as_str(),
            param: None,
            distinct_modes: None,
            overflow_modes: None,
        }),
        (None, Some(rendered)) => Some(PartialError {
            kind: "warning",
            code: "tool_decode_disabled",
            message: rendered.as_str(),
            param: None,
            distinct_modes: tool_disabled_counts.map(|(d, _)| d),
            overflow_modes: tool_disabled_counts.map(|(_, o)| o),
        }),
        (None, None) => None,
    };
    // I5 + N1: read directly from the immutable OnceLock snapshot.
    // Non-stream has no SSE surface, so the diags sit in the
    // `warnings` field (and also ride the `X-ChatAPC-Launch-Diags`
    // header for SDK-agnostic detection on partial / error responses).
    let diag_snapshot = launch_diags();
    let warnings_vec: Option<Vec<NonStreamWarning>> = if diag_snapshot.is_empty() {
        None
    } else {
        Some(
            diag_snapshot
                .iter()
                .map(|d| NonStreamWarning { code: d.code, message: d.message.as_str() })
                .collect(),
        )
    };
    // #418: speculation metrics, only when the caller opted into the
    // surface (so normal responses are byte-identical).
    let spec_metrics = if want_metrics {
        let spec = spec_metrics_handle
            .map(|h| *h.lock().unwrap())
            .unwrap_or_default();
        let report = SpecMetricsReport::build(
            spec_enabled,
            fallback_reason,
            dims,
            spec,
            spec_generated,
            spec_steps,
            spec_start.elapsed(),
        );
        report.log_spec_stats();
        Some(report)
    } else {
        None
    };
    let body = ChatCompletion {
        id: &id,
        object: "chat.completion",
        created: now_unix_secs(),
        model: &req.model,
        choices: vec![NonStreamChoice {
            index: 0,
            message: NonStreamMessage {
                role: "assistant",
                content: &full_text,
                reasoning_content: reasoning_opt,
                tool_calls: tool_calls_vec,
            },
            finish_reason: outcome.finish_reason(),
        }],
        error: error_block,
        warnings: warnings_vec,
        spec_metrics,
    };
    // `ChatCompletion` is a closed schema of plain scalars + an
    // assistant message string. None of the fields can fail to
    // serialize; an `expect` here surfaces an invariant bug at the
    // earliest point rather than masking it under a 500.
    let json = serde_json::to_string(&body).expect("ChatCompletion must serialize");
    // I3: status is content-dependent. Fatal `error_diag` returns
    // 502 (G3 was right for that case — `openai-python` ≥1.x raises
    // APIStatusError so SDK consumers don't iterate a partial body
    // as if it were a clean reply); warning-only (G2
    // tool_decode_disabled) returns 200 so consumers still see the
    // assistant content. Either way, `X-ChatAPC-Partial-Error`
    // header carries an SDK-independent detection signal — readers
    // that don't trust `response.error` (which on 200 sits in
    // `model_extra` for openai-python, an undocumented pydantic
    // surface) can match the header instead. Pure-failure (no
    // tokens produced) still hits the 500 envelope via the
    // `error_diag.is_some() && !has_partial` branch above.
    let (status, partial_kind) = match (&error_diag, &tool_disabled_diag) {
        (Some(_), _) => (502u16, Some("fatal")),
        (None, Some(_)) => (200u16, Some("warning")),
        (None, None) => (200u16, None),
    };
    let mut builder = Response::builder()
        .status(status)
        .header("Content-Type", "application/json");
    if let Some(kind) = partial_kind {
        builder = builder.header("X-ChatAPC-Partial-Error", kind);
    }
    let response = builder.body(json.into_body()).unwrap();
    res.respond(with_launch_diags_header(response)).await
}

// =============================================================================
// Internals
// =============================================================================

/// OpenAI `tool_choice` reduced to whether — and how — it FORCES a tool
/// call. Only the force-a-call modes enable constrained generation;
/// `"none"` / `"auto"` / absent leave generation unconstrained (the prior
/// behavior — `tool_choice` was parsed-but-ignored).
enum ForcedToolChoice {
    /// `"none"`, `"auto"`, or absent → do not constrain.
    No,
    /// `"required"` → constrain to the grammar over ALL equipped tools.
    Any,
    /// `{"type":"function","function":{"name":N}}` → constrain to the one
    /// named function so the call's `name` is pinned.
    Named(String),
}

/// Classify `tool_choice`. Unknown / malformed shapes degrade to `No`
/// (parsed-but-ignored) rather than erroring — matches the lenient
/// `#[serde(default)]` posture on the field.
fn forced_tool_choice(tc: Option<&serde_json::Value>) -> ForcedToolChoice {
    let Some(v) = tc else { return ForcedToolChoice::No };
    if let Some(s) = v.as_str() {
        return if s == "required" {
            ForcedToolChoice::Any
        } else {
            ForcedToolChoice::No
        };
    }
    if v.get("type").and_then(|t| t.as_str()) == Some("function")
        && let Some(name) = v
            .get("function")
            .and_then(|f| f.get("name"))
            .and_then(|n| n.as_str())
        && !name.is_empty()
    {
        return ForcedToolChoice::Named(name.to_string());
    }
    ForcedToolChoice::No
}

/// Build the `{name, description, parameters}` JSON envelopes the host's
/// `equip_prefix` / `native_grammar` expect from the OpenAI `tools[]`.
/// Non-function variants are dropped (the model template can't encode
/// them). `only` (a named `tool_choice`) restricts to a single function so
/// the constrain grammar pins that name.
fn tool_envelopes(tools: &[ToolSchema], only: Option<&str>) -> Vec<String> {
    tools
        .iter()
        .filter(|t| t.kind.is_empty() || t.kind == "function")
        .filter(|t| only.is_none_or(|n| t.function.name == n))
        .map(|t| {
            serde_json::json!({
                "name": t.function.name,
                "description": t.function.description.as_deref().unwrap_or(""),
                "parameters": t.function.parameters,
            })
            .to_string()
        })
        .collect()
}

/// When `tool_choice` forces a call, constrain generation to the model's
/// native tool-call grammar. This is real OpenAI `tool_choice` enforcement
/// (previously a no-op) AND the mechanism that makes a tool call
/// deterministic on the dummy driver — the dummy honors the grammar's
/// per-step logit mask, and the Qwen tool grammar's `root` forces a
/// `<tool_call>{…}</tool_call>` with the name pinned to the equipped
/// tool(s). Returns:
///   * `Ok(None)`      — not forced; leave generation unconstrained.
///   * `Ok(Some(c))`   — forced + model has a native tool grammar.
///   * `Err((status,code,msg))` — forced but unsatisfiable (no matching
///     tool in `tools[]`, or the model has no native tool-call grammar) →
///     the caller returns this OpenAI-shape error instead of silently
///     ignoring the directive.
fn build_forced_tool_constraint(
    model: &Model,
    tools: Option<&[ToolSchema]>,
    tool_choice: Option<&serde_json::Value>,
) -> Result<Option<GrammarConstraint>, (u16, &'static str, String)> {
    let only = match forced_tool_choice(tool_choice) {
        ForcedToolChoice::No => return Ok(None),
        ForcedToolChoice::Any => None,
        ForcedToolChoice::Named(n) => Some(n),
    };
    let envelopes = tool_envelopes(tools.unwrap_or(&[]), only.as_deref());
    if envelopes.is_empty() {
        return Err((
            400,
            "invalid_request",
            match &only {
                Some(n) => format!(
                    "tool_choice names function '{n}' but it is not present in tools[]"
                ),
                None => "tool_choice is \"required\" but tools[] is empty".to_string(),
            },
        ));
    }
    // `native_grammar` returns `None` gracefully when the model has no
    // tool-call format (unlike `native_matcher`, which would trap). Gate
    // on it, then wrap the grammar in a matcher-backed constraint.
    match inferlet::tools::native_grammar(model, &envelopes) {
        Some(grammar) => Ok(Some(GrammarConstraint::from_grammar(&grammar, model))),
        None => Err((
            400,
            "tool_choice_unsupported",
            "tool_choice forces a tool call but this model has no native \
             tool-call grammar (constrained tool calling is unsupported for \
             this architecture)"
                .to_string(),
        )),
    }
}

/// Apply role-tagged messages to `ctx` via the SDK's chat templating
/// and, when `tools` is non-empty, splice the model's native tool
/// schema preamble via `inferlet::tools::equip_prefix`. Equip runs
/// before any chat turn so the schemas land in the system slot the
/// chat template expects.
///
/// Roles outside the OpenAI canonical set are demoted to `user` so
/// future SDK extensions (e.g. `tool`) don't crash the handler — a
/// pessimistic but loss-of-information-preserving choice.
pub(crate) fn fill_context(
    ctx: &mut Context,
    model: &Model,
    messages: &[ChatMessage],
    tools: Option<&[ToolSchema]>,
    cue: bool,
) -> Result<(), (&'static str, String)> {
    if let Some(tools) = tools {
        // The SDK's `equip_prefix` expects `{name, description,
        // parameters}` per entry; the OpenAI `type:"function"` wrapper is
        // stripped here. Non-function variants are ignored — the model
        // template has no encoding for them. All tools are equipped
        // (visible to the model) regardless of `tool_choice`.
        let envelopes = tool_envelopes(tools, None);
        if !envelopes.is_empty() {
            let prefix = inferlet::tools::equip_prefix(model, &envelopes)
                .map_err(|e| ("tool_equip_failed", format!("equip_prefix: {e}")))?;
            ctx.append(&prefix);
        }
    }
    for msg in messages {
        match msg.role.as_str() {
            "system" => {
                ctx.system(&msg.content);
            }
            "assistant" => {
                ctx.assistant(&msg.content);
            }
            // `user`, `tool`, anything else → user. The chat template
            // doesn't have a `tool` slot in v1; surfacing the content
            // as a user message is closer-to-correct than dropping it.
            _ => {
                ctx.user(&msg.content);
            }
        }
    }
    // The trailing cue opens the assistant turn the generator fills.
    // Single-shot chat callers commit it with the prompt; tree-of-thought
    // defers it to each forked branch (so a freshly forked, fully-flushed
    // context still has tokens to process — an empty forward pass spins
    // the generator), so it is opt-out here.
    if cue {
        ctx.cue();
    }
    Ok(())
}

/// One detected tool call buffered for emit on the terminal chunk.
struct PendingToolCall {
    id: String,
    name: String,
    arguments: String,
}

fn next_tool_call_id() -> String {
    // F3 + I1 + J5: same id_seed + monotonic-clock + counter-fold
    // mix as `next_id`. OpenAI clients round-trip `tool_call_id` on
    // the next `role:"tool"` reply, so a collision across
    // wasm-instance restarts corrupts the caller's correlation
    // table.
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mono = monotonic_nanos_since_anchor();
    format!(
        "call_{:016x}{:016x}",
        id_seed().wrapping_add(n),
        mono.wrapping_add(n),
    )
}

// =============================================================================
// Unit tests (host-side; the per-request handler logic is exercised by
// e2e_test.py against the pie runtime — these cover only the pure helpers
// landed in Review v9, where regressions can be caught without wasm).
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    // ─── Forward-pass starvation guard (#439) ─────────────

    #[test]
    fn starved_when_no_slots() {
        // The real starvation shape: pie's scheduler hands back
        // `ForwardPassOutput::default()` (no slots) on a swallowed
        // device failure / batch timeout / KV eviction.
        assert!(forward_pass_starved(&[]));
    }

    #[test]
    fn not_starved_when_a_token_was_sampled() {
        assert!(!forward_pass_starved(&[SlotOutput::Token(5)]));
        assert!(!forward_pass_starved(&[SlotOutput::Token(5), SlotOutput::Token(6)]));
    }

    #[test]
    fn not_starved_when_token_leads_non_token_slots() {
        // A decode step with the auto-sampler at slot 0 plus probe slots:
        // the leading Token means the engine produced a pick.
        assert!(!forward_pass_starved(&[SlotOutput::Token(5), SlotOutput::Entropy(0.5)]));
    }

    #[test]
    fn starved_when_slots_carry_no_token() {
        // Probe-only output with no sampled token still counts as
        // starvation for a decode step (the loop always attaches the
        // auto-sampler, so a missing Token slot is the host producing none).
        assert!(forward_pass_starved(&[SlotOutput::Entropy(0.5)]));
    }

    // ─── Reasoning/content channel demux ──────────────────

    /// Reasoning-decoder event kind for one generation step, paired with
    /// the chat decoder's text for the same token batch. Models what the
    /// host decoders return without the wasm host.
    enum Step {
        ThinkStart(&'static str),  // reasoning Start; chat surfaces the `<think>` text
        Reason(&'static str),      // reasoning Delta; chat surfaces the same text
        ThinkEnd(&'static str),    // reasoning End/Complete; chat surfaces the `</think>` text
        Content(&'static str),     // reasoning Idle (outside); chat surfaces visible content
    }

    /// Replays the generation loop's reasoning/content demux exactly as
    /// `handle_streaming` / `handle_non_streaming` do: capture
    /// `was_in_reasoning`, feed reasoning (updating `in_reasoning` +
    /// `reason_idle`), then gate the chat delta on `content_visible`.
    /// Returns `(visible_content, reasoning)`.
    fn demux(steps: &[Step]) -> (String, String) {
        let mut content = String::new();
        let mut reasoning = String::new();
        let mut in_reasoning = false;
        for step in steps {
            let was_in_reasoning = in_reasoning;
            let mut reason_idle = false;
            let chat_text = match step {
                Step::ThinkStart(t) => {
                    in_reasoning = true;
                    *t
                }
                Step::Reason(t) => {
                    in_reasoning = true;
                    reasoning.push_str(t);
                    *t
                }
                Step::ThinkEnd(t) => {
                    in_reasoning = false;
                    *t
                }
                Step::Content(t) => {
                    reason_idle = true;
                    *t
                }
            };
            if content_visible(reason_idle, was_in_reasoning) {
                content.push_str(chat_text);
            }
        }
        (content, reasoning)
    }

    #[test]
    fn think_delimiters_never_leak_into_visible_content() {
        // A canonical Qwen reasoning turn: <think> reasoning </think> answer.
        let (content, reasoning) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("the user said hi"),
            Step::ThinkEnd("</think>"),
            Step::Content("Hello!"),
        ]);
        assert_eq!(content, "Hello!", "only the answer reaches visible content");
        assert_eq!(reasoning, "the user said hi");
        // The specific symptom: the CLOSING tag must not leak.
        assert!(!content.contains("</think>"), "closing delimiter leaked: {content:?}");
        assert!(!content.contains("<think>"), "opening delimiter leaked: {content:?}");
    }

    #[test]
    fn content_visible_only_outside_reasoning() {
        // Idle batch outside reasoning → visible.
        assert!(content_visible(true, false));
        // Closing-delimiter batch: reasoning End (not idle), was inside.
        assert!(!content_visible(false, true));
        // Opening-delimiter / reasoning-body batch: not idle.
        assert!(!content_visible(false, false));
        // Idle batch while still inside (no-visible-text reasoning token).
        assert!(!content_visible(true, true));
    }

    #[test]
    fn non_thinking_model_passes_all_content() {
        // NoopReasoningDecoder always reports Idle and never flips the
        // gate — every batch is visible content.
        let (content, reasoning) = demux(&[
            Step::Content("Plain "),
            Step::Content("answer."),
        ]);
        assert_eq!(content, "Plain answer.");
        assert!(reasoning.is_empty());
    }

    #[test]
    fn speculation_parses_and_maps_paper_defaults() {
        let r: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "temperature":0,"speculation":{"enabled":true}}"#,
        )
        .unwrap();
        let s = r.speculation.expect("speculation present");
        assert!(s.enabled);
        let cfg = s.to_config();
        assert_eq!(cfg.leader_len, 1);
        assert_eq!(cfg.draft_len, 3);
    }

    #[test]
    fn absent_speculation_is_none() {
        let r: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
        )
        .unwrap();
        assert!(r.speculation.is_none());
    }

    #[test]
    fn spec_dims_out_of_range_rejected() {
        // F1: out-of-range speculation knobs are rejected at the 400
        // boundary with a `param`, mirroring max_tokens — NOT silently
        // clamped. leader_len below range:
        let req: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "temperature":0,"speculation":{"enabled":true,"leader_len":0}}"#,
        )
        .unwrap();
        assert_eq!(
            validate_sampling(&req, MAX_OUTPUT_TOKENS_FALLBACK).unwrap_err().0,
            "speculation.leader_len"
        );

        // draft_len above range:
        let req: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "temperature":0,"speculation":{"enabled":true,"draft_len":99999}}"#,
        )
        .unwrap();
        assert_eq!(
            validate_sampling(&req, MAX_OUTPUT_TOKENS_FALLBACK).unwrap_err().0,
            "speculation.draft_len"
        );

        // in-range values pass; the clamp in to_config is then a
        // redundant safety net.
        let req: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "temperature":0,"speculation":{"enabled":true,"leader_len":2,"draft_len":4}}"#,
        )
        .unwrap();
        assert!(validate_sampling(&req, MAX_OUTPUT_TOKENS_FALLBACK).is_ok());
        let cfg = req.speculation.unwrap().to_config();
        assert_eq!((cfg.leader_len, cfg.draft_len), (2, 4));
    }

    #[test]
    fn max_tokens_ceiling_is_dynamic() {
        // The `max_tokens` ceiling is the engine value passed in, not a
        // hardcoded constant: a request at the ceiling passes, one above
        // is rejected, 0 is always rejected, and a larger engine capacity
        // lifts the ceiling. Drives the pure `validate_sampling` directly
        // with an explicit ceiling (no engine host needed).
        let mk = |mt: usize| -> ChatCompletionsRequest {
            serde_json::from_str(&format!(
                r#"{{"model":"m","messages":[{{"role":"user","content":"hi"}}],"max_tokens":{mt}}}"#
            ))
            .unwrap()
        };
        assert!(validate_sampling(&mk(4096), 4096).is_ok());
        assert_eq!(
            validate_sampling(&mk(4097), 4096).unwrap_err().0,
            "max_tokens"
        );
        // A larger engine KV capacity lifts the ceiling: 40000 now passes
        // where the old hardcoded 8192 would have rejected it.
        assert!(validate_sampling(&mk(40000), 65536).is_ok());
        // Zero is invalid regardless of ceiling.
        assert_eq!(
            validate_sampling(&mk(0), 65536).unwrap_err().0,
            "max_tokens"
        );
        // The 400 message reflects the dynamic ceiling, not a constant.
        let (_, msg) = validate_sampling(&mk(99999), 8192).unwrap_err();
        assert!(msg.contains("[1, 8192]"), "got: {msg}");
    }

    #[test]
    fn omitted_max_tokens_uses_dynamic_ceiling_when_below_default() {
        let req: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
        )
        .unwrap();

        assert_eq!(validate_sampling(&req, 512).unwrap(), 512);
        assert_eq!(
            validate_sampling(&req, DEFAULT_MAX_TOKENS + 1).unwrap(),
            DEFAULT_MAX_TOKENS
        );
    }

    #[test]
    fn plan_strategy_gates_on_greedy_and_enabled() {
        // requested + greedy + no forced tool -> speculative, no fallback
        let s = SpecRequest { enabled: true, leader_len: None, draft_len: None };
        let (st, fb, want, _) = plan_strategy(Some(&s), true, false);
        assert!(matches!(st, DecodeStrategy::Speculative(_)));
        assert!(fb.is_none());
        assert!(want);
        // requested + non-greedy -> plain, fallback reason
        let (st, fb, want, _) = plan_strategy(Some(&s), false, false);
        assert!(matches!(st, DecodeStrategy::Plain));
        assert_eq!(fb, Some("non_greedy_sampling"));
        assert!(want);
        // requested + greedy BUT a tool call is forced -> plain, gated off
        // with a distinct reason (checked before the greedy gate).
        let (st, fb, want, _) = plan_strategy(Some(&s), true, true);
        assert!(matches!(st, DecodeStrategy::Plain));
        assert_eq!(fb, Some("tool_choice_forced"));
        assert!(want);
        // enabled:false -> plain, disabled
        let off = SpecRequest { enabled: false, leader_len: None, draft_len: None };
        let (_, fb, want, _) = plan_strategy(Some(&off), true, false);
        assert_eq!(fb, Some("disabled"));
        assert!(want);
        // absent -> plain, no metrics surface
        let (_, fb, want, _) = plan_strategy(None, true, false);
        assert!(fb.is_none());
        assert!(!want);
    }

    #[test]
    fn truncate_message_passthrough() {
        let s = "hello";
        assert_eq!(truncate_message(s, 1024), s);
    }

    #[test]
    fn truncate_message_appends_suffix() {
        let s = "a".repeat(2000);
        let out = truncate_message(&s, 100);
        assert!(out.ends_with("...[truncated]"));
        assert!(out.len() <= 100);
        assert!(out.len() > "...[truncated]".len());
    }

    #[test]
    fn truncate_message_respects_utf8_boundary() {
        // 4-byte chars; cap mid-char.
        let s = "🦀".repeat(200);
        let out = truncate_message(&s, 50);
        // Should not panic, and the head portion must be valid UTF-8.
        assert!(out.ends_with("...[truncated]"));
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
    }

    #[test]
    fn truncate_message_small_max_uses_short_suffix() {
        // P1: max smaller than full suffix (14 bytes) must still
        // honor the cap. Degrade to short suffix `...` (3 bytes).
        let s = "a".repeat(50);
        let out = truncate_message(&s, 8);
        assert!(out.len() <= 8, "output {out:?} exceeds cap 8");
        assert!(out.ends_with("..."));
        assert!(!out.ends_with("...[truncated]"));
    }

    #[test]
    fn truncate_message_tiny_max_no_suffix() {
        // P1: max < 3 (smaller than even the short suffix) — drop
        // the suffix entirely and emit the bare truncated head so
        // the byte cap is honored absolutely. Caller asked for a
        // budget too small for any marker.
        let s = "abcdefgh".to_string();
        let out = truncate_message(&s, 2);
        assert!(out.len() <= 2, "output {out:?} exceeds cap 2");
        assert!(!out.contains("..."));
    }

    #[test]
    fn launch_diags_header_payload_heartbeat_message_notes_snapshot_scope() {
        // P2: heartbeat message must explicitly call out that the
        // probe ran at startup and doesn't reflect live health.
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let heartbeat = &parsed.as_array().expect("array")[0];
        assert_eq!(heartbeat["code"], LAUNCH_PROBES_OK);
        let msg = heartbeat["message"].as_str().expect("message string");
        assert!(
            msg.contains("startup") && msg.contains("live"),
            "heartbeat message {msg:?} should call out snapshot scope"
        );
    }

    #[test]
    fn percent_encode_ascii_passes_through() {
        let s = r#"[{"code":"clock_skew","message":"hello world"}]"#;
        let out = percent_encode_for_header(s);
        // Space encodes to %20; brackets/quotes/colons stay.
        assert!(out.contains("%20"));
        assert!(!out.contains(' '));
        assert!(out.starts_with("%5B") || out.starts_with("["));
        // `[` is 0x5B — printable, passes through unchanged.
        assert!(out.starts_with("["));
    }

    #[test]
    fn percent_encode_unicode_bytes() {
        // U+2265 `≥` is 3 bytes (E2 89 A5). Must encode.
        let s = "≥";
        let out = percent_encode_for_header(s);
        assert_eq!(out, "%E2%89%A5");
        // Round-trip via percent-decoding into bytes.
        // (We don't ship a decoder; assert against the known byte values.)
    }

    #[test]
    fn percent_encode_self_escape() {
        // `%` itself must encode so the result is self-consistent.
        let out = percent_encode_for_header("100%");
        assert_eq!(out, "100%25");
    }

    #[test]
    fn launch_diags_header_payload_always_has_heartbeat() {
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let arr = parsed.as_array().expect("array");
        // T2: first entry must be the heartbeat sentinel regardless
        // of whether any real diags fired. Code is the stable
        // `launch_probes_ok` literal; additive fields carry scope.
        assert_eq!(arr[0]["code"], LAUNCH_PROBES_OK);
    }

    #[test]
    fn launch_diags_header_payload_heartbeat_carries_scope_and_launched_at() {
        // Q1: structured fields encode snapshot scope + age basis so
        // machine consumers don't have to parse English prose.
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let heartbeat = &parsed.as_array().expect("array")[0];
        assert_eq!(heartbeat["scope"], "startup_snapshot");
        assert!(
            heartbeat["launched_at"].is_i64(),
            "launched_at must be a wall-clock timestamp (i64)"
        );
    }

    #[test]
    fn fallback_payload_uses_distinct_code() {
        // Q4: the serializer-crashed fallback path must NOT reuse the
        // healthy-launch code, or dashboards alarming on
        // `launch_probes_ok` get a false-positive on a hard
        // serializer failure. T1 + U1 + W1: exposes the four-category
        // breakdown via JSON-number counters paired with
        // *_lost_measured booleans (not the V1 nullable widening).
        // All four categories measured here.
        let s = fallback_serialize_failed_payload(Some(1), Some(2), Some(3), Some(4));
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let arr = parsed.as_array().expect("array");
        let frame = &arr[0];
        assert_eq!(frame["code"], LAUNCH_PROBES_SERIALIZE_FAILED);
        assert_eq!(frame["heartbeat_seed_failed_lost"], 1);
        assert_eq!(frame["heartbeat_seed_failed_lost_measured"], true);
        assert_eq!(frame["accepted_real_diags_lost"], 2);
        assert_eq!(frame["accepted_real_diags_lost_measured"], true);
        assert_eq!(frame["budget_dropped_lost"], 3);
        assert_eq!(frame["budget_dropped_lost_measured"], true);
        assert_eq!(frame["serialize_failed_lost"], 4);
        assert_eq!(frame["serialize_failed_lost_measured"], true);
        assert_eq!(frame["entries_lost_total"], 10);
    }

    #[test]
    fn dropped_entries_json_carries_code_and_message_prefix() {
        // Q2: dropped sentinels record (code, message_prefix) pairs
        // so duplicate codes with distinct messages are individually
        // identifiable. Prefix is cut-only (no `...[truncated]`
        // marker) so the 16-byte budget yields ~16 chars of useful
        // prefix instead of mostly-marker.
        //
        // F9 (PR  review v2) /  MUST4: also pin the
        // sub-frame field-name set. The F2 sentinel freeze tests
        // (`budget_drop_sentinel_field_names_frozen` /
        // `serialize_fail_sentinel_field_names_frozen`) freeze the
        // outer `{_truncated, _truncated_codes}` / `{_serialize_failed,
        // _serialize_failed_codes}` keys and assert
        // `_truncated_codes` is an array, but never inspect what's
        // INSIDE that array. A rename like `message_prefix` → `prefix`
        // or a sibling addition like `message_hash` would ship
        // silently. The BTreeSet pin below closes that gap with one
        // assertion; the existing `as_str()` Some(...) checks remain
        // immediately after as wire-type freezes (per F13 reviewer
        // resolution).
        use std::collections::BTreeSet;
        let prefix = message_prefix(
            "id_seed: wasi:clocks/monotonic_clock did not advance",
            DROPPED_MESSAGE_PREFIX_LEN,
        );
        let v = dropped_entries_json(&[("entropy_degraded", prefix.clone())]);
        assert_eq!(v.len(), 1);
        let observed: BTreeSet<&str> = v[0]
            .as_object()
            .expect("dropped sub-frame must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = ["code", "message_prefix"].into_iter().collect();
        assert_eq!(
            observed, expected,
            "dropped_entries_json sub-frame field-name drift — see \
              MUST4. Renames bump HEARTBEAT_SCHEMA_VERSION."
        );
        // Wire-type freezes (Some(...) over .as_str() pins both
        // presence and JSON-string typing).
        assert_eq!(v[0]["code"].as_str(), Some("entropy_degraded"));
        let observed = v[0]["message_prefix"].as_str().expect("string prefix");
        assert!(observed.len() <= DROPPED_MESSAGE_PREFIX_LEN);
        assert!(observed.starts_with("id_seed"));
    }

    #[test]
    fn message_prefix_no_marker() {
        // Q2: prefix cuts at char boundary without appending any
        // marker. Distinguishes from truncate_message which adds
        // `...[truncated]` / `...` markers.
        let s = "abcdefghijklmnop";
        assert_eq!(message_prefix(s, 5), "abcde");
        assert_eq!(message_prefix(s, 100), s);
        // UTF-8 boundary respected.
        let multi = "🦀🦀🦀";
        let out = message_prefix(multi, 5);
        assert!(out.len() <= 5);
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
    }

    #[test]
    fn message_prefix_distinguishes_namespaced_messages() {
        // S4: real-world failure case — two messages share the
        // probe-family namespace prefix (`id_seed: wasi:clocks/`)
        // but differ on the component name. At 16-byte budget they
        // collapsed to identical prefixes; at 48-byte budget they
        // must diverge.
        let a = "id_seed: wasi:clocks/monotonic_clock did not advance";
        let b = "id_seed: wasi:clocks/wall_clock failed";
        let pa = message_prefix(a, DROPPED_MESSAGE_PREFIX_LEN);
        let pb = message_prefix(b, DROPPED_MESSAGE_PREFIX_LEN);
        assert_ne!(
            pa, pb,
            "namespaced prefixes must distinguish: {pa:?} vs {pb:?}"
        );
        // Both fit within the cap.
        assert!(pa.len() <= DROPPED_MESSAGE_PREFIX_LEN);
        assert!(pb.len() <= DROPPED_MESSAGE_PREFIX_LEN);
    }

    #[test]
    fn heartbeat_carries_schema_version() {
        // S2 + U2: wire-shape rename without a version field would
        // silently break dashboards. `_schema_version` pins the
        // contract so future renames land observably. U2: emitted
        // as a JSON STRING so Grafana template-variable matching
        // (string-typed by default) and JS string-comparison
        // idioms don't silently miss. Both `is_string()` AND
        // `.as_str()` assertions so the type is pinned belt-and-
        // suspenders against a future `&str` → numeric flip.
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let heartbeat = &parsed.as_array().expect("array")[0];
        assert!(
            heartbeat["_schema_version"].is_string(),
            "heartbeat _schema_version must be JSON string, got {:?}",
            heartbeat["_schema_version"]
        );
        let version = heartbeat["_schema_version"]
            .as_str()
            .expect("_schema_version must be a JSON string for template-var compat");
        assert_eq!(version, HEARTBEAT_SCHEMA_VERSION);
    }

    #[test]
    fn fallback_payload_carries_schema_version_as_string() {
        // U2: fallback path also emits _schema_version as JSON string.
        // Hand-rolled JSON in `fallback_serialize_failed_payload`
        // must match the heartbeat encoding so consumers see one
        // type across both shapes.
        let s = fallback_serialize_failed_payload(Some(0), Some(0), Some(0), Some(0));
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let frame = &parsed.as_array().expect("array")[0];
        assert!(
            frame["_schema_version"].is_string(),
            "_schema_version must be JSON string, got {:?}",
            frame["_schema_version"]
        );
        assert_eq!(frame["_schema_version"].as_str().unwrap(), HEARTBEAT_SCHEMA_VERSION);
    }

    #[test]
    fn fallback_attributes_heartbeat_seed_failure_separately() {
        // U1 + W1: heartbeat-seed serialize failure must be
        // attributable to its own field, not silently bucketed
        // under `budget_dropped`. W1: counters stay JSON integers
        // (v9 wire shape preserved — no nullable widening). The
        // additive *_measured booleans say which counters are
        // authoritative; placeholder zeros pair with
        // `*_measured: false`. Old integer-only consumers read the
        // same integer types; new consumers filter on the booleans.
        let s = fallback_serialize_failed_payload(Some(5), None, None, None);
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let frame = &parsed.as_array().expect("array")[0];

        // Measured counter — value + flag.
        assert_eq!(frame["heartbeat_seed_failed_lost"], 5);
        assert_eq!(frame["heartbeat_seed_failed_lost_measured"], true);

        // Unmeasured counters — placeholder zero (JSON number, not
        // null!), flagged via *_measured: false.
        assert_eq!(frame["accepted_real_diags_lost"], 0);
        assert_eq!(frame["accepted_real_diags_lost_measured"], false);
        assert_eq!(frame["budget_dropped_lost"], 0);
        assert_eq!(frame["budget_dropped_lost_measured"], false);
        assert_eq!(frame["serialize_failed_lost"], 0);
        assert_eq!(frame["serialize_failed_lost_measured"], false);

        // entries_lost_total sums MEASURED counters only — lower
        // bound on true total when any flag is false. Here = 5
        // (just heartbeat).
        assert_eq!(frame["entries_lost_total"], 5);

        // W1: the wire shape must stay JSON numbers for the
        // counters (no nullable widening). Belt-and-suspenders.
        assert!(frame["heartbeat_seed_failed_lost"].is_number());
        assert!(frame["accepted_real_diags_lost"].is_number());
        assert!(frame["budget_dropped_lost"].is_number());
        assert!(frame["serialize_failed_lost"].is_number());
        assert!(frame["entries_lost_total"].is_number());
    }

    #[test]
    fn fallback_all_measured_sums_total() {
        // W1: when all four categories are `Some`, every
        // *_measured flag is true and `entries_lost_total` emits
        // the authoritative sum.
        let s = fallback_serialize_failed_payload(Some(0), Some(1), Some(2), Some(3));
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let frame = &parsed.as_array().expect("array")[0];
        assert_eq!(frame["entries_lost_total"], 6);
        assert_eq!(frame["heartbeat_seed_failed_lost_measured"], true);
        assert_eq!(frame["accepted_real_diags_lost_measured"], true);
        assert_eq!(frame["budget_dropped_lost_measured"], true);
        assert_eq!(frame["serialize_failed_lost_measured"], true);
    }

    #[test]
    fn fallback_entries_lost_total_authoritative_flag() {
        // X1: companion bool to `entries_lost_total` so bool-aware
        // consumers don't have to AND four siblings to know. True
        // iff all four *_measured are true; false otherwise.
        // Legacy consumers ignoring this bool default to treating
        // the number as authoritative (per the W1 stability policy
        // "absent *_measured ≡ measured:true").
        let all = fallback_serialize_failed_payload(Some(1), Some(2), Some(3), Some(4));
        let frame_all = serde_json::from_str::<serde_json::Value>(&all).unwrap()
            .as_array().unwrap()[0].clone();
        assert_eq!(frame_all["entries_lost_total_authoritative"], true);

        let partial = fallback_serialize_failed_payload(Some(5), None, None, None);
        let frame_partial = serde_json::from_str::<serde_json::Value>(&partial).unwrap()
            .as_array().unwrap()[0].clone();
        assert_eq!(frame_partial["entries_lost_total_authoritative"], false);

        // One unmeasured slot is enough to flip the flag — even
        // if the other three are measured.
        let three_measured =
            fallback_serialize_failed_payload(Some(1), Some(2), Some(3), None);
        let frame_three = serde_json::from_str::<serde_json::Value>(&three_measured).unwrap()
            .as_array().unwrap()[0].clone();
        assert_eq!(frame_three["entries_lost_total_authoritative"], false);
    }

    #[test]
    fn fallback_entries_lost_total_authoritative_wire_type_is_bool() {
        // X1: pin the wire type at JSON boolean so a future
        // accidental int/string conversion fires here instead of
        // silently breaking dashboards.
        let s = fallback_serialize_failed_payload(Some(0), Some(0), Some(0), Some(0));
        let frame = serde_json::from_str::<serde_json::Value>(&s).unwrap()
            .as_array().unwrap()[0].clone();
        assert!(
            frame["entries_lost_total_authoritative"].is_boolean(),
            "entries_lost_total_authoritative must be JSON boolean, got {:?}",
            frame["entries_lost_total_authoritative"]
        );
    }

    #[test]
    fn fallback_counter_wire_type_stable_under_unmeasured() {
        // W1 + W2: the explicit anti-regression guard. The V1
        // nullable widening silently broke type-strict consumers;
        // W1 reverted that. This test PINS the counter wire-type
        // at JSON number across BOTH measured and unmeasured
        // paths — any future change that re-introduces a
        // type-widening union (Option leaked as null,
        // `f64::NAN` interpolation, etc.) fires this assertion
        // before consumers notice. Schema-version stability
        // depends on it.
        let unmeasured =
            fallback_serialize_failed_payload(Some(7), None, None, None);
        let frame = serde_json::from_str::<serde_json::Value>(&unmeasured)
            .unwrap()
            .as_array()
            .unwrap()[0]
            .clone();
        for f in [
            "heartbeat_seed_failed_lost",
            "accepted_real_diags_lost",
            "budget_dropped_lost",
            "serialize_failed_lost",
            "entries_lost_total",
        ] {
            assert!(
                frame[f].is_number(),
                "wire type for {f} must remain JSON number across measured \
                 and unmeasured states; got {:?}",
                frame[f]
            );
        }
    }

    #[test]
    fn golden_wire_heartbeat_code_literal() {
        // U3: pin the wire literal directly, not the Rust constant.
        // A future PR renaming both the constant AND its value in
        // lockstep (e.g. `LAUNCH_PROBES_OK = "launch_ok"`) would
        // pass any test comparing `heartbeat["code"] ==
        // LAUNCH_PROBES_OK` — but every v9-v10 dashboard would
        // silently break. Asserting against the literal string is
        // the only way the wire-shape stability policy gets a CI
        // teeth.
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let heartbeat = &parsed.as_array().expect("array")[0];
        assert_eq!(
            heartbeat["code"].as_str(),
            Some("launch_probes_ok"),
            "heartbeat code is a stable wire identifier — see  \
             policy. Changing this literal silently breaks every dashboard \
             keyed on the v9+ string."
        );
    }

    #[test]
    fn golden_wire_fallback_code_literal() {
        // U3: same policy applies to the fallback path's distinct
        // code. Dashboards alarming on the serialize-failure state
        // pattern-match this exact literal.
        let s = fallback_serialize_failed_payload(Some(0), Some(0), Some(0), Some(0));
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let frame = &parsed.as_array().expect("array")[0];
        assert_eq!(
            frame["code"].as_str(),
            Some("launch_probes_serialize_failed"),
            "fallback code is a stable wire identifier — see  \
             policy. Changing this literal silently breaks alarms keyed \
             on serializer-failure state."
        );
    }

    #[test]
    fn stable_launch_diag_codes_universe_frozen() {
        // Y1 /  MUST1: the v∞ set of LaunchDiag.code wire
        // identifiers is a stable contract. The literal-string set is
        // pinned here so any future rename / deletion / reordering
        // surfaces as a CI failure with the policy citation, instead
        // of as a silent dashboard break in production.
        //
        // Adding a new code: append to STABLE_LAUNCH_DIAG_CODES AND
        // extend the `expected` set in this test in the SAME commit.
        // The two-side update is the policy gate.
        use std::collections::BTreeSet;
        let observed: BTreeSet<&'static str> =
            STABLE_LAUNCH_DIAG_CODES.iter().copied().collect();
        let expected: BTreeSet<&'static str> = [
            "clock_skew",
            "clock_skew_fallback_entropy",
            "entropy_degraded",
            "monotonic_clock_stubbed",
            "monotonic_clock_coarse_resolution",
        ]
        .into_iter()
        .collect();
        assert_eq!(
            observed, expected,
            "LaunchDiag.code universe drift — see  wire-shape \
             stability policy. Add new codes; never rename or remove."
        );
        // Sanity: STABLE_LAUNCH_DIAG_CODES has no duplicates (the
        // const slice can carry them; the universe set cannot).
        assert_eq!(
            observed.len(),
            STABLE_LAUNCH_DIAG_CODES.len(),
            "STABLE_LAUNCH_DIAG_CODES contains duplicate codes"
        );
    }

    #[test]
    fn launch_diags_header_payload_arr1_field_names_frozen() {
        // F10 (PR  review v2) /  MUST4: end-to-end pin
        // on the first non-heartbeat entry's field-name set.
        //
        // Why this matters even though `launch_diag_entry_field_names_frozen`
        // exists: that test calls the extracted helper directly. A
        // future PR that re-inlines the entry construction at the
        // call site as `json!({"code": d.code, "msg": &msg})` (typo
        // `msg` instead of `message`) is a real wire break — but the
        // helper-side freeze still passes (the helper is unchanged
        // and just goes unused), the heartbeat freeze only inspects
        // `arr[0]`, and the W2 fallback pins don't touch the header
        // path. Same regression vector class as v1 F3 / ,
        // but specifically targeting the helper-extraction pattern.
        //
        // Drives `build_launch_diags_payload` — the production
        // builder reached by `launch_diags_header_payload` — with a
        // synthetic diag slice so we exercise the line-911 entry
        // construction every test run, without needing to seed the
        // OnceLock LAUNCH_DIAGS registry through a clock-skew /
        // entropy fault.
        use std::collections::BTreeSet;
        let diags = [LaunchDiag {
            code: CODE_CLOCK_SKEW,
            message: "system clock pre-UNIX_EPOCH".to_string(),
        }];
        let json = build_launch_diags_payload(&diags);
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let arr = parsed.as_array().expect("array");
        assert!(
            arr.len() >= 2,
            "build_launch_diags_payload must include heartbeat + \
             seeded diag (got {} entries)",
            arr.len()
        );
        // Anchor heartbeat at index 0 to confirm the seeded diag is
        // at arr[1] — same defensive pattern as F4.
        assert_eq!(
            arr[0]["code"].as_str(),
            Some("launch_probes_ok"),
            "arr[0] is not the heartbeat (code={:?})",
            arr[0]["code"]
        );
        let entry = arr[1]
            .as_object()
            .expect("arr[1] must be a JSON object");
        let observed: BTreeSet<&str> =
            entry.keys().map(String::as_str).collect();
        let expected: BTreeSet<&str> = ["code", "message"].into_iter().collect();
        assert_eq!(
            observed, expected,
            "end-to-end LaunchDiag entry field-name drift — see the schema contract \
              MUST4. Renames bump HEARTBEAT_SCHEMA_VERSION. This \
             test reaches the line-911 entry construction through the \
             production builder, so a re-inline that bypasses \
             `launch_diag_entry_json` is still caught."
        );
        // Wire-type pins on the seeded entry's values.
        assert_eq!(arr[1]["code"].as_str(), Some("clock_skew"));
        assert_eq!(
            arr[1]["message"].as_str(),
            Some("system clock pre-UNIX_EPOCH")
        );
    }

    #[test]
    fn launch_diag_entry_field_names_frozen() {
        // F1 (PR  review v1) /  MUST4: every
        // per-LaunchDiag entry frame in `X-ChatAPC-Launch-Diags` is
        // built as `{"code": ..., "message": ...}` at
        // `launch_diags_header_payload`. Renaming `message` → `msg` or
        // adding a sibling field is a wire break the heartbeat /
        // fallback freeze tests don't cover. This pins the entry
        // frame directly by calling the extracted builder with a
        // representative populated diag — no need to seed the
        // OnceLock LAUNCH_DIAGS registry.
        use std::collections::BTreeSet;
        let entry = launch_diag_entry_json(CODE_CLOCK_SKEW, "system clock pre-UNIX_EPOCH");
        let observed: BTreeSet<&str> = entry
            .as_object()
            .expect("entry must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = ["code", "message"].into_iter().collect();
        assert_eq!(
            observed, expected,
            "per-LaunchDiag entry field-name drift — see  \
             MUST4. Renames bump HEARTBEAT_SCHEMA_VERSION."
        );
        assert_eq!(entry["code"].as_str(), Some("clock_skew"));
        assert_eq!(
            entry["message"].as_str(),
            Some("system clock pre-UNIX_EPOCH")
        );
    }

    #[test]
    fn budget_drop_sentinel_field_names_frozen() {
        // F2 (PR  review v1) /  MUST4: the budget-drop
        // sentinel frame appended to `X-ChatAPC-Launch-Diags` when
        // entries exceed the 4KB payload cap carries
        // `{"_truncated", "_truncated_codes"}`. A typo
        // (`_truncted`, `_truncated_code`) ships silently without
        // this pin.
        use std::collections::BTreeSet;
        let frame = budget_drop_sentinel(&[
            ("clock_skew", "skew".to_string()),
            ("entropy_degraded", "deg".to_string()),
        ]);
        let observed: BTreeSet<&str> = frame
            .as_object()
            .expect("sentinel must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = ["_truncated", "_truncated_codes"].into_iter().collect();
        assert_eq!(
            observed, expected,
            "budget-drop sentinel field-name drift — see  \
             MUST4. Renames bump HEARTBEAT_SCHEMA_VERSION."
        );
        assert_eq!(frame["_truncated"].as_u64(), Some(2));
        assert!(frame["_truncated_codes"].is_array());
    }

    #[test]
    fn serialize_fail_sentinel_field_names_frozen() {
        // F2 (PR  review v1) /  MUST4: same MUST4
        // coverage for the serializer-rejected sentinel frame
        // (`{"_serialize_failed", "_serialize_failed_codes"}`). The
        // in-line construction is unreachable through normal inputs
        // (entry payloads are string-only and always serialize), so
        // the test calls the extracted helper directly — same pattern
        // as the W2 fallback wire-type pins above.
        use std::collections::BTreeSet;
        let frame =
            serialize_fail_sentinel(&[("monotonic_clock_stubbed", "stub".to_string())]);
        let observed: BTreeSet<&str> = frame
            .as_object()
            .expect("sentinel must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = [
            "_serialize_failed",
            "_serialize_failed_codes",
        ]
        .into_iter()
        .collect();
        assert_eq!(
            observed, expected,
            "serialize-fail sentinel field-name drift — see the schema contract \
              MUST4. Renames bump HEARTBEAT_SCHEMA_VERSION."
        );
        assert_eq!(frame["_serialize_failed"].as_u64(), Some(1));
        assert!(frame["_serialize_failed_codes"].is_array());
    }

    #[test]
    fn heartbeat_field_names_frozen() {
        // Y1 /  MUST4: top-level heartbeat field NAMES are
        // wire-frozen. Renaming `scope` → `phase` or `launched_at` →
        // `started_at` is the same class of silent break as renaming
        // `launch_probes_ok` — and a version-bump is mandatory if it
        // ever happens. This pin catches drift at CI time.
        use std::collections::BTreeSet;
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let heartbeat = &parsed.as_array().expect("array")[0];
        // F4 (PR  review v1): anchor the index-0 assumption to the
        // wire-stable heartbeat code literal. Without this, a future
        // refactor that prepended a preamble frame (e.g. envelope
        // version) would silently freeze that frame's keys instead of
        // the heartbeat's — until the divergence is wide enough to
        // fail. The literal — not LAUNCH_PROBES_OK — so a lockstep
        // rename of both sides of the constant still trips here.
        assert_eq!(
            heartbeat["code"].as_str(),
            Some("launch_probes_ok"),
            "arr[0] is not the heartbeat (code={:?}). Test must pin \
             field names of the HEARTBEAT, not whatever happens to \
             occupy index 0 today.",
            heartbeat["code"]
        );
        let observed: BTreeSet<&str> = heartbeat
            .as_object()
            .expect("heartbeat must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = [
            "code",
            "_schema_version",
            "scope",
            "launched_at",
            "message",
        ]
        .into_iter()
        .collect();
        assert_eq!(
            observed, expected,
            "heartbeat field-name drift — see  MUST4. \
             Renames bump HEARTBEAT_SCHEMA_VERSION; additions extend \
             this set."
        );
    }

    #[test]
    fn fallback_payload_field_names_frozen() {
        // Y1 /  MUST4: same freeze as heartbeat, applied
        // to the fallback frame. The hand-rolled `format!` in
        // `fallback_serialize_failed_payload` is the easiest place
        // to typo-rename a field without compiler help — a CI pin
        // is the only enforcement available.
        use std::collections::BTreeSet;
        let s = fallback_serialize_failed_payload(Some(0), Some(0), Some(0), Some(0));
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let frame = &parsed.as_array().expect("array")[0];
        let observed: BTreeSet<&str> = frame
            .as_object()
            .expect("fallback frame must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = [
            "code",
            "_schema_version",
            "scope",
            "entries_lost_total",
            "entries_lost_total_authoritative",
            "heartbeat_seed_failed_lost",
            "heartbeat_seed_failed_lost_measured",
            "accepted_real_diags_lost",
            "accepted_real_diags_lost_measured",
            "budget_dropped_lost",
            "budget_dropped_lost_measured",
            "serialize_failed_lost",
            "serialize_failed_lost_measured",
            "message",
        ]
        .into_iter()
        .collect();
        assert_eq!(
            observed, expected,
            "fallback frame field-name drift — see  MUST4. \
             Renames bump HEARTBEAT_SCHEMA_VERSION; new *_lost counters \
             MUST ship paired *_lost_measured siblings (MUST5)."
        );
    }

    #[test]
    fn fallback_payload_lost_counter_pairing() {
        // Y1 /  MUST5: every `*_lost` counter MUST ship
        // with a paired `*_lost_measured: bool` sibling in the SAME
        // payload. Half-pair landings break the bool-aware consumer's
        // "measured = all four flags true" invariant — and slipped
        // through every wire-shape review prior to this enforcement.
        //
        // Mechanically: parse the fallback frame, collect all keys
        // ending in `_lost` (excluding `entries_lost_total`, which is
        // the AGGREGATE — its own pairing sibling is
        // `entries_lost_total_authoritative`, asserted separately),
        // and verify the bijection with `*_lost_measured` keys.
        use std::collections::BTreeSet;
        let s = fallback_serialize_failed_payload(Some(0), Some(0), Some(0), Some(0));
        let parsed: serde_json::Value = serde_json::from_str(&s).expect("valid JSON");
        let frame = parsed.as_array().expect("array")[0]
            .as_object()
            .expect("fallback frame must be a JSON object")
            .clone();

        let lost_counters: BTreeSet<String> = frame
            .keys()
            .filter(|k| k.ends_with("_lost") && k.as_str() != "entries_lost_total")
            .cloned()
            .collect();
        let measured_flags: BTreeSet<String> = frame
            .keys()
            .filter(|k| k.ends_with("_lost_measured"))
            .cloned()
            .collect();

        // Every *_lost has a *_lost_measured.
        for counter in &lost_counters {
            let expected_sibling = format!("{counter}_measured");
            assert!(
                measured_flags.contains(&expected_sibling),
                "MUST5 violation: counter {counter:?} has no paired \
                 {expected_sibling:?} sibling. See ."
            );
            // Counter is a JSON number (W1 wire-type pin).
            assert!(
                frame[counter].is_number(),
                "MUST5 sibling typing: {counter:?} must be JSON number, \
                 got {:?}",
                frame[counter]
            );
            // Sibling is a JSON boolean.
            assert!(
                frame[&expected_sibling].is_boolean(),
                "MUST5 sibling typing: {expected_sibling:?} must be JSON \
                 boolean, got {:?}",
                frame[&expected_sibling]
            );
        }

        // Symmetric: every *_lost_measured has a *_lost partner — no
        // orphan booleans either.
        for flag in &measured_flags {
            let expected_counter = flag
                .strip_suffix("_measured")
                .expect("flag ends in _measured");
            assert!(
                lost_counters.contains(expected_counter),
                "MUST5 orphan flag: {flag:?} has no paired \
                 {expected_counter:?} counter. See ."
            );
        }

        // The aggregate `entries_lost_total` has its own paired
        // `entries_lost_total_authoritative` (boolean) — X1 codified.
        assert!(
            frame.contains_key("entries_lost_total"),
            "entries_lost_total aggregate missing"
        );
        assert!(
            frame["entries_lost_total_authoritative"].is_boolean(),
            "entries_lost_total_authoritative must be JSON boolean (X1)"
        );
    }

    #[test]
    fn launched_at_documented_as_lower_bound() {
        // Y1 /  known-limitation pin: `launched_at`
        // captures FIRST-REQUEST-ENTRY, not process spawn — the wasm
        // request-handler model has no startup hook. Consumers
        // computing "age since launch" should read it as a LOWER
        // BOUND on real process age. Asserting the type + presence
        // here doubles as the regression guard if a future refactor
        // ever switches the field to a duration or removes it.
        let json = launch_diags_header_payload();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        let heartbeat = &parsed.as_array().expect("array")[0];
        assert!(
            heartbeat["launched_at"].is_i64(),
            "launched_at must remain a wall-clock i64 (lower bound on \
             real spawn time per  known limitation), got \
             {:?}",
            heartbeat["launched_at"]
        );
    }

    #[test]
    fn launch_timestamp_initialized_alongside_probe_chain() {
        // S1: launch_timestamp() must be observable as soon as
        // compute_launch_diags / launch_diags() has run. Trigger
        // the OnceLock init chain and confirm a non-trivial value
        // is captured.
        let _ = launch_diags();
        let ts = launch_timestamp();
        // ts == 0 only on clock-skewed hosts; in a test environment
        // we expect a real wall-clock value. Assert non-zero rather
        // than a tighter equality to avoid flakiness.
        assert!(
            ts != 0,
            "launch_timestamp should capture a wall-clock value at probe-chain init"
        );
    }
}
