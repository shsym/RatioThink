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

use std::collections::{hash_map::DefaultHasher, HashMap, HashSet, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use inferlet::Context;
use inferlet::GrammarConstraint;
use inferlet::chat;
use inferlet::inference::SlotOutput;
use inferlet::model::Model;
use inferlet::runtime;
use serde::{Deserialize, Serialize};
use wstd::http::body::IncomingBody;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Request, Response};

use super::apc::{ReasoningDecoder, ToolUseDecoder};
use super::generate::{self, DecodeStrategy};
use super::prefix_cache::{self, CacheDiag, ReusePlan};
use super::spec::sidecar::{encode_sidecar_blob, Lineage, SidecarKey, SidecarStatus, SidecarStore};
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
                match $em.emit_json(&SseError::new("serialize_bug", &msg)).await {
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
const CACHEBACK_SIDECAR_TTL: Duration = Duration::from_secs(30 * 60);

// =============================================================================
// Request schema
// =============================================================================

#[derive(Deserialize)]
pub struct ChatCompletionsRequest {
    /// chat-apc extension for profile-backed advanced modes. When present,
    /// `/v1/chat/completions` acts as the public envelope and routes internally
    /// to the named advanced chat-apc dispatch mode (`tree-of-thought` or
    /// `best-of-n`) instead of requiring clients to POST `/v1/inferlet`.
    #[serde(default)]
    pub inferlet: Option<String>,
    /// Opaque dispatch payload for `inferlet`. Normal OpenAI chat requests omit
    /// this; advanced profile modes carry their existing mode-specific input
    /// unchanged inside the chat-completions request body.
    #[serde(default)]
    pub input: Option<serde_json::Value>,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
    pub max_tokens: Option<usize>,
    /// OpenAI's newer alias for `max_tokens` (the only field current
    /// OpenAI/Codex-style clients send). Used as a fallback when
    /// `max_tokens` is absent so those clients don't silently fall back
    /// to `DEFAULT_MAX_TOKENS`.
    #[serde(default)]
    pub max_completion_tokens: Option<usize>,
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
    /// #522 cross-request KV prefix-cache directive. Absent → reuse
    /// disabled (byte-identical to the pre-#522 full-rebuild path).
    /// Present + `policy:"auto"` + non-empty `key` → the inferlet opens a
    /// matching prefix snapshot on a hit and saves the new boundary on
    /// success. See [`super::prefix_cache`].
    #[serde(default)]
    pub cache: Option<prefix_cache::CacheDirective>,
    /// OpenAI-shape `response_format`. `{"type":"json_object"}` constrains
    /// the answer to a JSON **object** (`{...}`); `{"type":"json_schema",
    /// "json_schema":{"schema":{…}}}` constrains it to the caller's schema.
    /// Both run real grammar-guided decoding (the "JSON Think" profile,
    /// #572/#619). Absent or `{"type":"text"}` → unconstrained,
    /// byte-identical to the prior behavior.
    #[serde(default)]
    pub response_format: Option<ResponseFormat>,
    /// OpenAI `stream_options` — only `include_usage` is inspected. When
    /// set on a streaming request, a final `chat.completion.chunk` with
    /// empty `choices` and a populated `usage` block is emitted just
    /// before `[DONE]`, mirroring the OpenAI/vLLM convention. Ignored on
    /// non-streaming requests (those always carry `usage`).
    #[serde(default)]
    pub stream_options: Option<StreamOptions>,
}

#[derive(Deserialize, Clone, Default)]
pub struct StreamOptions {
    #[serde(default)]
    pub include_usage: bool,
}

/// OpenAI-shape `response_format` discriminator. `json_object` and
/// `json_schema` are honored as constrained modes; `text` is the explicit
/// no-op; any other `type` is parsed-but-rejected at the 400 boundary
/// (`validate_response_format`) rather than silently ignored.
#[derive(Deserialize, Clone)]
pub struct ResponseFormat {
    #[serde(rename = "type", default)]
    pub kind: String,
    /// Present only for `{"type":"json_schema"}`. Carries the OpenAI
    /// `json_schema` envelope whose `schema` member is the JSON Schema the
    /// answer must satisfy.
    #[serde(default)]
    pub json_schema: Option<JsonSchemaSpec>,
}

/// OpenAI `response_format.json_schema` envelope. Only `schema` is
/// load-bearing; the sibling `name`/`strict` members a client may also
/// send are ignored by serde (no `deny_unknown_fields`).
#[derive(Deserialize, Clone)]
pub struct JsonSchemaSpec {
    /// The JSON Schema the answer must conform to. Compiled to a grammar
    /// via `GrammarConstraint::from_json_schema`.
    #[serde(default)]
    pub schema: Option<serde_json::Value>,
}

impl ResponseFormat {
    /// Constrain the answer to a JSON object (`{...}`, arbitrary contents).
    pub const JSON_OBJECT: &'static str = "json_object";
    /// Constrain the answer to a caller-supplied JSON Schema.
    pub const JSON_SCHEMA: &'static str = "json_schema";
    /// Explicit unconstrained mode (OpenAI default). A no-op here.
    pub const TEXT: &'static str = "text";
}

/// JSON Schema enforcing an object root with arbitrary contents — the
/// grammar for `{"type":"json_object"}`. `additionalProperties:true` is
/// explicit because the host compiler defaults to strict mode (no extra
/// properties), which would otherwise collapse a bare `{"type":"object"}`
/// to the empty object `{}` alone.
const JSON_OBJECT_ROOT_SCHEMA: &str = r#"{"type":"object","additionalProperties":true}"#;

/// True when the request asks for JSON-constrained output (`json_object`
/// OR `json_schema`). Centralizes the predicate so the validation, the
/// speculation gate, and the two-phase decode all read one test.
fn json_mode(req: &ChatCompletionsRequest) -> bool {
    req.response_format.as_ref().is_some_and(|rf| {
        rf.kind == ResponseFormat::JSON_OBJECT || rf.kind == ResponseFormat::JSON_SCHEMA
    })
}

/// The JSON Schema string driving the Phase-2 grammar, or `None` when the
/// request is not in JSON mode. `json_object` maps to the object-root
/// schema; `json_schema` serializes the caller's `schema`. Pure — the
/// grammar compile (which can fail on a malformed schema) happens in
/// [`build_json_constraint`].
fn json_constraint_schema(req: &ChatCompletionsRequest) -> Option<String> {
    let rf = req.response_format.as_ref()?;
    match rf.kind.as_str() {
        ResponseFormat::JSON_OBJECT => Some(JSON_OBJECT_ROOT_SCHEMA.to_string()),
        ResponseFormat::JSON_SCHEMA => rf
            .json_schema
            .as_ref()
            .and_then(|j| j.schema.as_ref())
            .map(|s| s.to_string()),
        _ => None,
    }
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
    /// Optional request-thread identity for per-chat Cacheback n-gram
    /// persistence. Absent keeps the preexisting per-request behavior.
    pub thread_id: Option<String>,
    /// Optional profile identity; included in the sidecar key so a
    /// profile switch with the same model does not reuse incompatible
    /// learned followers.
    pub profile_id: Option<String>,
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
    #[serde(default, deserialize_with = "deserialize_message_content")]
    pub content: Option<String>,
    #[serde(default)]
    pub tool_call_id: Option<serde_json::Value>,
    #[serde(default)]
    pub tool_calls: Option<serde_json::Value>,
}

impl ChatMessage {
    pub(crate) fn content_str(&self) -> Option<&str> {
        self.content.as_deref()
    }

    pub(crate) fn has_tool_calls(&self) -> bool {
        tool_calls_array(self).is_some_and(|calls| !calls.is_empty())
    }
}

/// OpenAI content-part shape (`{"type":"text","text":"..."}`); other part
/// types (image_url, etc.) are accepted but contribute no text.
#[derive(Deserialize)]
struct ContentPart {
    #[serde(default)]
    text: Option<String>,
}

/// `messages[].content` accepts either the simple string form or the
/// multi-part array form (`[{"type":"text","text":"..."}, ...]`) that many
/// OpenAI-compatible clients send (e.g. for retries/multi-modal turns).
/// The array form is flattened into a single string by concatenating each
/// part's `text` field, so every downstream consumer keeps treating
/// `content` as a plain `String`.
fn deserialize_message_content<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Content {
        Null,
        Text(String),
        Parts(Vec<ContentPart>),
    }

    match Content::deserialize(deserializer)? {
        Content::Null => Ok(None),
        Content::Text(s) => Ok(Some(s)),
        Content::Parts(parts) => Ok(Some(parts
            .into_iter()
            .filter_map(|p| p.text)
            .collect::<Vec<_>>()
            .join(""))),
    }
}

pub type RequestToolCall = serde_json::Value;

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
    /// Populated only on the final usage-summary chunk emitted when the
    /// request set `stream_options.include_usage: true` (see [`Usage`]).
    /// Every other chunk (role/content/reasoning/tool-call deltas, the
    /// `finish_reason` chunk) leaves this `None` so the wire shape is
    /// unchanged for clients that don't ask for it.
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<Usage>,
}

/// OpenAI-shape token accounting, attached to every non-streaming
/// response and to the optional final streaming chunk
/// (`stream_options.include_usage: true`).
#[derive(Serialize, Clone)]
struct Usage {
    prompt_tokens: usize,
    completion_tokens: usize,
    total_tokens: usize,
    /// #522 prefix-cache hit accounting, surfaced the same way OpenAI's
    /// own prompt-caching does. `cached_tokens` is the portion of
    /// `prompt_tokens` reused from a KV snapshot (0 when the cache
    /// directive is absent, disabled, or missed).
    prompt_tokens_details: PromptTokensDetails,
}

#[derive(Serialize, Clone)]
struct PromptTokensDetails {
    cached_tokens: usize,
}

impl Usage {
    fn build(prompt_tokens: usize, completion_tokens: usize, cached_tokens: usize) -> Self {
        Self {
            prompt_tokens,
            completion_tokens,
            total_tokens: prompt_tokens + completion_tokens,
            prompt_tokens_details: PromptTokensDetails { cached_tokens },
        }
    }
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
    /// doc). Skipped from serialization when empty.
    #[serde(skip_serializing_if = "Option::is_none")]
    warnings: Option<Vec<NonStreamWarning<'a>>>,
    /// chat-apc extension: speculative-decode metrics. Present only when
    /// the request included a `speculation` block, so normal responses
    /// stay byte-identical. Carries draft accounting + throughput, plus
    /// `fallback_reason` when speculation was requested but inactive.
    #[serde(skip_serializing_if = "Option::is_none")]
    spec_metrics: Option<SpecMetricsReport>,
    /// OpenAI `usage` block — always present on non-streaming responses
    /// (including partial/error bodies with `finish_reason:"error"`),
    /// matching stock OpenAI-compatible servers.
    usage: Usage,
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
    /// n-gram cache effectiveness (#591): `draft()` lookups that hit a
    /// follower vs returned empty (cold leader / chain ran dry), the
    /// derived hit rate, and the end-of-turn cache size. Distinguishes
    /// "drafter rarely proposes (cold cache)" from "proposes but rejected".
    cache_hits: usize,
    cache_misses: usize,
    cache_hit_rate: f64,
    cache_size: usize,
    /// Accepted-prefix length distribution behind `avg_tokens_per_step`
    /// (#591): index `k` = decode steps that committed exactly `k` accepted
    /// draft tokens (index 0 = free pick only — cold or fully-rejected step).
    accepted_prefix_len_histogram: Vec<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ngram_sidecar_status: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ngram_sidecar_leaders: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ngram_sidecars_expired: Option<usize>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SidecarMetricStatus {
    Fresh,
    Reused,
    DecodeFailed,
    LineageForked,
}

impl SidecarMetricStatus {
    fn as_str(self) -> &'static str {
        match self {
            SidecarMetricStatus::Fresh => "fresh",
            SidecarMetricStatus::Reused => "reused",
            SidecarMetricStatus::DecodeFailed => "decode_failed",
            SidecarMetricStatus::LineageForked => "lineage_forked",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SidecarMetrics {
    status: SidecarMetricStatus,
    ngram_leaders: usize,
    expired: usize,
}

struct SidecarLease {
    key: SidecarKey,
    lineage: Lineage,
    cache: Arc<Mutex<super::spec::cache::NgramCache>>,
}

#[derive(Serialize)]
struct GenerationMetricsSse {
    event: &'static str,
    output_tokens: usize,
    elapsed_s: f64,
    tokens_per_sec: f64,
}

impl GenerationMetricsSse {
    fn build(output_tokens: usize, elapsed: Duration) -> Option<Self> {
        let elapsed_s = elapsed.as_secs_f64();
        if output_tokens == 0 || elapsed_s <= 0.0 {
            return None;
        }
        Some(Self {
            event: "generation_metrics",
            output_tokens,
            elapsed_s,
            tokens_per_sec: output_tokens as f64 / elapsed_s,
        })
    }
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
        sidecar: Option<SidecarMetrics>,
    ) -> Self {
        let secs = elapsed.as_secs_f64();
        let cache_lookups = spec.cache_hits + spec.cache_misses;
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
            cache_hits: spec.cache_hits,
            cache_misses: spec.cache_misses,
            cache_hit_rate: if cache_lookups > 0 {
                spec.cache_hits as f64 / cache_lookups as f64
            } else {
                0.0
            },
            cache_size: spec.cache_size,
            accepted_prefix_len_histogram: spec.accepted_prefix_hist,
            ngram_sidecar_status: sidecar.map(|s| s.status.as_str()),
            ngram_sidecar_leaders: sidecar.map(|s| s.ngram_leaders),
            ngram_sidecars_expired: sidecar.map(|s| s.expired),
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
             decode_tokens_per_sec={:.2} cache_hits={} cache_misses={} \
             cache_hit_rate={:.3} cache_size={} prefix_hist={:?} \
             sidecar={} sidecar_leaders={} sidecars_expired={}",
            self.enabled,
            self.fallback_reason.unwrap_or("none"),
            self.generated_tokens,
            self.decode_steps,
            self.proposed_draft_tokens,
            self.accepted_draft_tokens,
            self.rejected_draft_tokens,
            self.avg_tokens_per_step,
            self.decode_tokens_per_sec,
            self.cache_hits,
            self.cache_misses,
            self.cache_hit_rate,
            self.cache_size,
            self.accepted_prefix_len_histogram,
            self.ngram_sidecar_status.unwrap_or("none"),
            self.ngram_sidecar_leaders.unwrap_or(0),
            self.ngram_sidecars_expired.unwrap_or(0),
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
///
/// `json_mode` gates speculation OFF for the same reason (#572): the JSON
/// phase runs a grammar-constrained sampler, which the drafter's verify
/// must not run against. Checked first (alongside forced-tool) so a
/// JSON+greedy request reports `json_constrained`, not speculative.
/// JSON mode and forced tool_choice are mutually exclusive (rejected at
/// the 400 boundary), so their order relative to each other is moot.
fn plan_strategy(
    spec: Option<&SpecRequest>,
    greedy: bool,
    forced_tool: bool,
    json_mode: bool,
) -> (DecodeStrategy, Option<&'static str>, bool, (usize, usize)) {
    match spec {
        None => (DecodeStrategy::Plain, None, false, (0, 0)),
        Some(s) if s.enabled && json_mode => {
            (DecodeStrategy::Plain, Some("json_constrained"), true, (0, 0))
        }
        Some(s) if s.enabled && forced_tool => {
            (DecodeStrategy::Plain, Some("tool_choice_forced"), true, (0, 0))
        }
        Some(s) if s.enabled && greedy => {
            let cfg = s.to_config();
            let dims = (cfg.leader_len, cfg.draft_len);
            (DecodeStrategy::Speculative(cfg), None, true, dims)
        }
        Some(s) if s.enabled => (
            DecodeStrategy::Plain,
            Some("non_greedy_sampling"),
            true,
            (0, 0),
        ),
        Some(_) => (DecodeStrategy::Plain, Some("disabled"), true, (0, 0)),
    }
}

/// Stand-alone tokenization of the prompt to seed the drafter's dynamic
/// table. Exact chat-template alignment isn't required — accepted tokens
/// grow the cache as generation proceeds (see `super::spec`).
fn seed_tokens_from(model: &Model, messages: &[ChatMessage]) -> Vec<u32> {
    let joined = messages
        .iter()
        .map(|m| m.content_str().unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n");
    model.tokenizer().encode(&joined)
}

// =============================================================================
// JSON Think — two-phase constrained decode (#572/#619)
// =============================================================================
//
// "JSON Think" runs TWO sequential generations on the SAME `Context` so a
// thinking model can reason freely and still answer in grammar-valid JSON:
//
//   · Phase 1 (reasoning): unconstrained. Emit `reasoning_content`,
//     SUPPRESS visible content. Stop the instant the reasoning block
//     closes (`reasoning::Event::End`) OR the first visible-content batch
//     appears (non-thinking models never enter a `<think>` block) OR the
//     model stops / hits the cap.
//   · Phase 2 (answer): the request's JSON-mode `GrammarConstraint` is
//     attached (an object root for `json_object`, the caller's schema for
//     `json_schema` — see `build_json_constraint`), so every
//     newly sampled token is masked to valid JSON. Emit content, no
//     reasoning. Phase 1's tail (the `</think>` batch, or a single
//     discarded answer-start token on a non-thinking model) is flushed
//     into Phase 2's first forward pass as plain context — it conditions
//     the answer but is never emitted and is not subject to the grammar,
//     so Phase 2's output is pure JSON.
//
// No second `fill_context`/`cue()` runs between the phases, so the
// assistant turn stays open and the model never re-opens `<think>`. The
// helper is sink-parameterized so the streaming and non-streaming handlers
// share ONE decode loop, called once per phase.
//
// Budget (#572 F2): the request's `max_tokens` is a single ceiling SHARED
// across both phases, not a per-phase grant. Phase 1 runs against the full
// ceiling; Phase 2 receives `json_phase2_budget(max_tokens, phase1_generated)`
// — the remainder, floored at `JSON_PHASE2_MIN_TOKENS` so a thinking model
// that burns the whole budget before `</think>` can still emit a value. This
// keeps a JSON request's total generated tokens (hence cost/latency/KV) bound
// by what the caller asked for instead of silently doubling it.

/// Where a JSON-phase decode loop sends its decoded text.
enum JsonSink<'a> {
    /// Streaming: each delta becomes an SSE `chat.completion.chunk`.
    Stream {
        em: &'a mut Emitter,
        id: &'a str,
        created: i64,
        model: &'a str,
    },
    /// Non-streaming: deltas accumulate into the final `ChatCompletion`.
    Buffer {
        content: &'a mut String,
        reasoning: &'a mut String,
    },
}

impl JsonSink<'_> {
    async fn reasoning_delta(&mut self, text: &str) -> Result<(), EmitError> {
        match self {
            JsonSink::Stream { em, id, created, model } => {
                let chunk = ChatCompletionChunk {
                    id,
                    object: "chat.completion.chunk",
                    created: *created,
                    model,
                    choices: vec![ChunkChoice {
                        index: 0,
                        delta: ChunkDelta {
                            reasoning_content: Some(text),
                            ..Default::default()
                        },
                        finish_reason: None,
                    }],
                    usage: None,
                };
                em.emit_json(&chunk).await
            }
            JsonSink::Buffer { reasoning, .. } => {
                reasoning.push_str(text);
                Ok(())
            }
        }
    }

    async fn content_delta(&mut self, text: &str) -> Result<(), EmitError> {
        match self {
            JsonSink::Stream { em, id, created, model } => {
                let chunk = ChatCompletionChunk {
                    id,
                    object: "chat.completion.chunk",
                    created: *created,
                    model,
                    choices: vec![ChunkChoice {
                        index: 0,
                        delta: ChunkDelta {
                            content: Some(text),
                            ..Default::default()
                        },
                        finish_reason: None,
                    }],
                    usage: None,
                };
                em.emit_json(&chunk).await
            }
            JsonSink::Buffer { content, .. } => {
                content.push_str(text);
                Ok(())
            }
        }
    }
}

/// Per-phase knobs for [`run_json_phase`].
struct JsonPhaseOpts {
    /// Forward reasoning text to the sink (Phase 1 only). Drives the
    /// reasoning demux.
    emit_reasoning: bool,
    /// Forward visible content to the sink (Phase 2 only).
    emit_content: bool,
    /// Phase-1 semantics: stop the moment the reasoning block closes OR the
    /// first visible-content batch appears (so a non-thinking model yields
    /// to the constrained phase immediately). Drives the reasoning demux.
    stop_after_reasoning: bool,
    /// Phase-2 semantics: emit EVERY decoded chat delta as content without
    /// the `content_visible` reasoning gate. Phase 2 runs under a JSON
    /// grammar that cannot emit a `<think>` block, so its output is
    /// definitionally the answer — there is nothing to suppress. This is
    /// load-bearing: when Phase 1 ends mid-`<think>` (a thinking model that
    /// exhausts its budget before `</think>`), the reasoning gate would
    /// otherwise stay latched and silently swallow the entire JSON answer.
    raw_content: bool,
    /// Hard cap on tokens generated in **this phase**. The two phases SHARE
    /// the request's `max_tokens` ceiling (#572 F2): Phase 1 runs against the
    /// full ceiling and Phase 2 receives [`json_phase2_budget`] of what Phase
    /// 1 left (floored at [`JSON_PHASE2_MIN_TOKENS`]), so a JSON request never
    /// silently spends ~2× the caller's cost/latency/KV bound.
    max_tokens: usize,
}

/// Result of one JSON-phase decode loop.
struct JsonPhaseResult {
    outcome: Outcome,
    error_diag: Option<(&'static str, String)>,
    /// The streaming peer closed mid-phase; the caller should finalize the
    /// SSE response without emitting further frames.
    disconnected: bool,
    /// Tokens generated in this phase (`Generator::tokens_generated`). Read
    /// once at phase exit so the caller can share the request's `max_tokens`
    /// budget across both phases (#572 F2) rather than handing each phase an
    /// independent full budget.
    tokens_generated: usize,
    /// Whether this phase emitted at least one visible-content delta. Phase 2
    /// uses this to detect a contractually-empty JSON answer (#572 F3): a
    /// `json_object` request that ends Natural/MaxTokens with no content is a
    /// failure (the empty string is not valid JSON), not a 200 success.
    produced_content: bool,
}

/// Drive one generation phase to completion, demuxing reasoning vs visible
/// content exactly like the canonical loop (`content_visible`) and routing
/// each through `sink`. `stream` is consumed (dropped on return) so the
/// caller can build the next phase's generator on the same `Context`.
/// `in_reasoning` carries the reasoning-block gate across phases.
async fn run_json_phase(
    mut stream: inferlet::Generator<'_>,
    chat_dec: &mut chat::Decoder,
    reason_dec: &mut ReasoningDecoder,
    sink: &mut JsonSink<'_>,
    in_reasoning: &mut bool,
    opts: JsonPhaseOpts,
) -> JsonPhaseResult {
    // Each loop branch breaks the `'phase` loop with its terminal triple;
    // `tokens_generated` / `produced_content` are read once after the loop so
    // every exit path reports them uniformly (the generator outlives the loop).
    let mut produced_content = false;
    let (outcome, error_diag, disconnected): (Outcome, Option<(&'static str, String)>, bool) =
        'phase: loop {
            macro_rules! emit_or_bail {
                ($call:expr) => {
                    match $call.await {
                        Ok(()) => {}
                        Err(EmitError::Disconnected) => break 'phase (Outcome::Aborted, None, true),
                        Err(EmitError::Serialize(e)) => {
                            // Same static chunk schema as the proven canonical
                            // path, so this is unreachable in practice; log to
                            // pie-server's capture and end the phase rather than
                            // shipping corruption.
                            eprintln!("[chat-apc] json-phase chunk serialize bug: {e}");
                            break 'phase (
                                Outcome::Aborted,
                                Some(("serialize_bug", e.to_string())),
                                false,
                            );
                        }
                    }
                };
            }

            let step = match stream.next() {
                Ok(None) => {
                    let outcome = if stream.tokens_generated() >= opts.max_tokens {
                        Outcome::MaxTokens
                    } else {
                        Outcome::Natural
                    };
                    break 'phase (outcome, None, false);
                }
                Ok(Some(s)) => s,
                Err(e) => {
                    // #470/#485 F1: classify the forward error so an
                    // over-capacity KV-acquire timeout (the `server_busy:`
                    // sentinel) surfaces as the retryable `server_busy` code
                    // exactly like the canonical loops — not a flat
                    // `forward_pass_failed`.
                    let m = e.to_string();
                    break 'phase (Outcome::Aborted, Some((classify_forward_error(&m), m)), false);
                }
            };
            let out = match step.execute().await {
                Ok(o) => o,
                Err(e) => {
                    let m = e.to_string();
                    break 'phase (Outcome::Aborted, Some((classify_forward_error(&m), m)), false);
                }
            };
            if forward_pass_starved(&out.raw().slots) {
                break 'phase (
                    Outcome::Aborted,
                    Some((STARVED_CODE, STARVED_MESSAGE.to_string())),
                    false,
                );
            }

            // Reasoning demux — only the reasoning phase needs it (to emit
            // reasoning and to detect the </think> / first-visible stop). Phase
            // 2 skips it entirely: it emits raw JSON content (see below), and
            // feeding the host reasoning decoder there would mis-latch on the
            // leftover mid-`<think>` state from a budget-truncated Phase 1.
            let mut visible = true;
            if opts.emit_reasoning || opts.stop_after_reasoning {
                let was_in_reasoning = *in_reasoning;
                let mut reason_idle = false;
                let mut reasoning_ended = false;
                match reason_dec.feed(&out.tokens) {
                    Ok(inferlet::reasoning::Event::Start) => *in_reasoning = true,
                    Ok(inferlet::reasoning::Event::Delta(s)) => {
                        *in_reasoning = true;
                        if opts.emit_reasoning {
                            emit_or_bail!(sink.reasoning_delta(&s));
                        }
                    }
                    Ok(inferlet::reasoning::Event::End(_)) => {
                        *in_reasoning = false;
                        reasoning_ended = true;
                    }
                    Ok(inferlet::reasoning::Event::Idle) => reason_idle = true,
                    Err(e) => {
                        break 'phase (
                            Outcome::Aborted,
                            Some(("reasoning_decode_failed", e.to_string())),
                            false,
                        );
                    }
                }
                visible = content_visible(reason_idle, was_in_reasoning);

                // Phase 1 stops as soon as reasoning ends OR the first visible
                // batch appears (covers thinking AND non-thinking models). The
                // visible batch is intentionally NOT emitted here (emit_content
                // is false in Phase 1); its tokens are already staged in the
                // context buffer and flow into Phase 2 as plain conditioning
                // context.
                if opts.stop_after_reasoning && (reasoning_ended || visible) {
                    break 'phase (Outcome::Natural, None, false);
                }
            }

            match chat_dec.feed(&out.tokens) {
                Ok(chat::Event::Delta(s)) if opts.emit_content && (opts.raw_content || visible) => {
                    produced_content = true;
                    emit_or_bail!(sink.content_delta(&s));
                }
                Ok(chat::Event::Delta(_)) => {}
                Ok(chat::Event::Done(_)) => break 'phase (Outcome::Natural, None, false),
                Ok(chat::Event::Interrupt(id)) => {
                    break 'phase (
                        Outcome::Aborted,
                        Some((
                            "chat_template_interrupt",
                            format!("control token {id} from chat template"),
                        )),
                        false,
                    );
                }
                Ok(chat::Event::Idle) => continue,
                Err(e) => {
                    break 'phase (Outcome::Aborted, Some(("decode_failed", e.to_string())), false);
                }
            }
        };

    JsonPhaseResult {
        outcome,
        error_diag,
        disconnected,
        tokens_generated: stream.tokens_generated(),
        produced_content,
    }
}

/// Distinct code/HTTP status for a JSON Phase-2 that ended cleanly
/// (`Natural`/`MaxTokens`) yet emitted zero content (#572 F3). For a
/// `json_object` request the empty string is not valid JSON, so this is a
/// contract failure — analogous to the canonical `tool_call_not_produced`
/// reclassification — not a deceptive `200 / finish_reason:"stop" / ""`.
const JSON_EMPTY_OUTPUT_CODE: &str = "json_empty_output";
const JSON_EMPTY_OUTPUT_MESSAGE: &str =
    "JSON-constrained generation produced no content; the model emitted no answer tokens \
     under the JSON grammar (raise max_tokens or verify the model supports constrained decoding)";

/// Minimum token budget handed to Phase 2 after Phase 1's generation is
/// debited from the request ceiling (#572 F2). The floor guarantees a
/// thinking model that exhausts the whole budget before `</think>` still has
/// room to emit a complete JSON value rather than being starved to zero.
const JSON_PHASE2_MIN_TOKENS: usize = 64;

/// #572 F2: share the request's `max_tokens` ceiling across the two phases.
/// Phase 1 (reasoning) runs against the full ceiling; Phase 2 (answer) gets
/// what Phase 1 left, floored at [`JSON_PHASE2_MIN_TOKENS`] so the constrained
/// answer is never budgeted to zero. Without this each phase received an
/// independent full budget, silently doubling the caller's cost/latency/KV
/// bound for a JSON request.
fn json_phase2_budget(max_tokens: usize, phase1_generated: usize) -> usize {
    max_tokens.saturating_sub(phase1_generated).max(JSON_PHASE2_MIN_TOKENS)
}

/// #572 F3: finalize a JSON Phase-2 result, reclassifying a clean-but-empty
/// answer as an explicit `json_empty_output` error. Returns the terminal
/// `(outcome, error_diag, disconnected)` triple the handlers emit. A phase
/// that already errored, disconnected, or produced content passes through
/// unchanged.
fn json_phase2_finalize(r2: JsonPhaseResult) -> (Outcome, Option<(&'static str, String)>, bool) {
    if r2.error_diag.is_none()
        && !r2.produced_content
        && matches!(r2.outcome, Outcome::Natural | Outcome::MaxTokens)
    {
        return (
            Outcome::Aborted,
            Some((JSON_EMPTY_OUTPUT_CODE, JSON_EMPTY_OUTPUT_MESSAGE.to_string())),
            r2.disconnected,
        );
    }
    (r2.outcome, r2.error_diag, r2.disconnected)
}

/// HTTP status for a JSON-mode pure-failure (no partial body): an
/// over-capacity `server_busy` is a retryable 503, everything else a 500 —
/// mirrors the canonical non-streaming branch (#470/#485 F1).
fn json_pure_failure_status(code: &str) -> u16 {
    if code == SERVER_BUSY_CODE {
        503
    } else {
        500
    }
}

fn cacheback_sidecars() -> &'static Mutex<SidecarStore> {
    static STORE: OnceLock<Mutex<SidecarStore>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(SidecarStore::new(CACHEBACK_SIDECAR_TTL)))
}

fn tools_digest(tools: Option<&[ToolSchema]>) -> u64 {
    let envelopes = tools.map(|t| tool_envelopes(t, None)).unwrap_or_default();
    let mut hasher = DefaultHasher::new();
    envelopes.hash(&mut hasher);
    hasher.finish()
}

fn lineage_from(messages: &[ChatMessage]) -> Lineage {
    let turns = messages
        .iter()
        .map(|m| (m.role.as_str(), m.content_str().unwrap_or("")))
        .collect::<Vec<_>>();
    Lineage::from_turns(&turns)
}

fn sidecar_for_request(
    model: &str,
    tools: Option<&[ToolSchema]>,
    messages: &[ChatMessage],
    spec: Option<&SpecRequest>,
    cfg: &SpecConfig,
) -> (Option<SidecarLease>, Option<SidecarMetrics>) {
    let Some(spec) = spec.filter(|s| s.enabled) else {
        return (None, None);
    };
    let Some(thread_id) = spec
        .thread_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return (None, None);
    };
    let key = SidecarKey::new(
        thread_id,
        model,
        spec.profile_id.as_deref(),
        tools_digest(tools),
        cfg.leader_len,
        cfg.draft_len,
    );
    let lineage = lineage_from(messages);
    let persisted = match inferlet::blob_store::open_blob(&key.blob_name()) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("[chat-apc] cacheback sidecar open failed: {e}");
            None
        }
    };
    let checkout = cacheback_sidecars()
        .lock()
        .unwrap()
        .checkout_with_persisted(
            monotonic_nanos_since_anchor() / 1_000_000,
            key.clone(),
            lineage.clone(),
            persisted,
        );
    let status = match checkout.status {
        SidecarStatus::Fresh => SidecarMetricStatus::Fresh,
        SidecarStatus::Reused => SidecarMetricStatus::Reused,
        SidecarStatus::DecodeFailed => SidecarMetricStatus::DecodeFailed,
        SidecarStatus::LineageForked => SidecarMetricStatus::LineageForked,
    };
    if let Some(diagnostic) = &checkout.diagnostic {
        eprintln!(
            "[chat-apc] cacheback sidecar non-reuse status={}: {diagnostic}",
            status.as_str()
        );
    }
    if checkout.delete_persisted {
        if let Err(e) = inferlet::blob_store::delete_blob(&key.blob_name()) {
            eprintln!("[chat-apc] cacheback sidecar delete failed: {e}");
        }
    }
    let cache = checkout.cache;
    (
        Some(SidecarLease {
            key,
            lineage,
            cache,
        }),
        Some(SidecarMetrics {
            status,
            ngram_leaders: checkout.ngram_leaders,
            expired: checkout.expired,
        }),
    )
}

fn persist_sidecar(lease: Option<&SidecarLease>, terminal_turn: Option<(&str, &str)>) {
    let Some(lease) = lease else {
        return;
    };
    let Some((role, content)) = terminal_turn else {
        return;
    };
    let Ok(cache) = lease.cache.lock() else {
        eprintln!("[chat-apc] cacheback sidecar cache lock poisoned; skipping save");
        return;
    };
    let persisted_lineage = lease.lineage.with_turn(role, content);
    let bytes = match encode_sidecar_blob(&persisted_lineage, &cache) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("[chat-apc] cacheback sidecar encode failed: {e}");
            return;
        }
    };
    let ttl_ms = CACHEBACK_SIDECAR_TTL
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX);
    if let Err(e) = inferlet::blob_store::save_blob(&lease.key.blob_name(), &bytes, ttl_ms) {
        eprintln!("[chat-apc] cacheback sidecar save failed: {e}");
    }
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
const STARVED_MESSAGE: &str = "engine produced no tokens for a decode step (device failure, per-batch \
     timeout, or KV eviction); generation cannot continue";

// =============================================================================
// Over-capacity / backpressure classification (#470)
// =============================================================================

/// Stable sentinel the pie runtime prefixes onto a KV-page **acquisition
/// timeout** (`runtime::context::reserve_working_pages`). When concurrent
/// requests exceed the engine's KV slot count, a reservation defers on the
/// scheduler's alloc/restore queues with no timer of its own; the host now
/// bounds that wait and fails the call with this prefix. The chat-apc
/// handler matches it to surface backpressure as `server_busy` + HTTP 503
/// instead of a generic `forward_pass_failed` 500 — so an over-capacity
/// client gets an explicit, retryable signal rather than a hung connection.
///
/// The trailing colon is load-bearing: `GenStep::execute` errors are an
/// opaque free-text channel that also carries verbatim device/driver text,
/// so a bare `server_busy` substring could appear in an unrelated fatal
/// error and get mislabeled retryable. The host's contract is the
/// colon-suffixed prefix (`"server_busy: …"`); bind to exactly that. (The
/// real fix is a structured WIT error code — tracked as a follow-up.)
const SERVER_BUSY_SENTINEL: &str = "server_busy:";

/// Distinct terminal/error code for the over-capacity case.
const SERVER_BUSY_CODE: &str = "server_busy";

/// Classify a `Generator::next` / `GenStep::execute` error string into a
/// stable terminal code. An over-capacity acquisition timeout (carrying the
/// [`SERVER_BUSY_SENTINEL`]) maps to [`SERVER_BUSY_CODE`]; everything else
/// is a generic `forward_pass_failed`.
fn classify_forward_error(msg: &str) -> &'static str {
    if msg.contains(SERVER_BUSY_SENTINEL) {
        SERVER_BUSY_CODE
    } else {
        "forward_pass_failed"
    }
}

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

/// Closing reasoning delimiter. The reasoning/content channels are demuxed per
/// batch, but the `</think>` boundary can fall MID-batch: under speculative
/// decode a single generation step is a multi-token burst, so the closing
/// delimiter and the first answer tokens can arrive together. On that step the
/// reasoning decoder fires `End` (so [`content_visible`] is false) while the
/// chat decoder lumps the whole step into ONE delta
/// `…reasoning</think>answer-head`. The per-batch gate would then suppress the
/// entire delta and silently DROP the answer that rode the same batch as the
/// close (#600). The reasoning half of the same straddle is recovered separately
/// via the `End(s)` residual (#466); this is the complementary content half.
const THINK_CLOSE: &str = "</think>";

/// Recover the visible answer that followed `</think>` inside the chat delta of
/// the batch where the reasoning block closed. Returns `None` when the delta is
/// the bare delimiter (plain decode — the answer arrives on the NEXT batch and
/// streams normally) or when the model's close delimiter is not `THINK_CLOSE`
/// (no regression: the prior behavior dropped the whole delta anyway). Splits on
/// the FIRST `</think>` — the reasoning tail before it cannot contain the close
/// delimiter, so an answer that itself mentions the tag stays intact. Leading
/// newlines are trimmed to mirror the chat template's `content.lstrip('\n')`.
fn answer_after_close(chat_delta: &str) -> Option<&str> {
    chat_delta
        .split_once(THINK_CLOSE)
        .map(|(_, answer)| answer.trim_start_matches('\n'))
        .filter(|answer| !answer.is_empty())
}

/// The visible-content slice to emit for a chat-decoder `Delta` on this batch,
/// given the reasoning-gate state. `""` means suppress. This is the single
/// demux decision shared by the streaming and non-streaming loops (and exercised
/// directly by the unit tests), so both paths treat the `</think>` straddle
/// identically:
///
/// * `forced_tool` → always suppressed: the whole generation IS the tool call,
///   which rides only the terminal `tool_calls` delta.
/// * batch landed entirely outside reasoning ([`content_visible`]) → the full
///   delta is visible content.
/// * the reasoning block closed ON this batch (`reason_ended`) → recover the
///   answer-head that shared the close batch ([`answer_after_close`]); the
///   reasoning tail + delimiter ahead of it stay suppressed.
/// * otherwise (inside the block, or the opening delimiter) → suppressed.
fn visible_content<'a>(
    chat_delta: &'a str,
    reason_idle: bool,
    was_in_reasoning: bool,
    reason_ended: bool,
    forced_tool: bool,
) -> &'a str {
    if forced_tool {
        ""
    } else if content_visible(reason_idle, was_in_reasoning) {
        chat_delta
    } else if reason_ended {
        answer_after_close(chat_delta).unwrap_or("")
    } else {
        ""
    }
}

// =============================================================================
// Launch-diagnostics registry (N1/N2 — OnceLock immutable snapshot)
// =============================================================================

/// One in-band-deliverable diagnostic produced by infrastructure
/// detection (id_seed entropy fallback, now_unix_secs clock-skew,
/// monotonic-clock stub/coarse) that would otherwise live only in
/// `eprintln!` and be dropped in the pie-mac production deployment
/// (see `crate::sse::emit_done_logged` doc).
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
        diags.push(LaunchDiag {
            code: CODE_CLOCK_SKEW,
            message: msg,
        });
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
            return fallback_serialize_failed_payload(Some(diags.len()), None, None, None);
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
            if let Ok(sentinel) = wstd::http::HeaderValue::from_str("encoding_failed") {
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
    let candidate = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
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
                let mixed = skew_nanos.rotate_left(17)
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
                diags.push(LaunchDiag {
                    code: CODE_ENTROPY_DEGRADED,
                    message: msg,
                });
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

/// Handle a request whose body was parsed upstream — used by normal
/// `/v1/chat/completions` requests and by the retained raw `/v1/inferlet`
/// chat-apc arm without re-serializing.
pub async fn handle_parsed(request: ChatCompletionsRequest, res: Responder) -> Finished {
    // N1/M1: force the OnceLock initialization at the very top, ABOVE
    // all validation. A health-probe shape like `curl -d 'broken'
    // /v1/chat/completions` only ever hits a 400 — but the
    // `with_launch_diags_header` wrappers below still attach the
    // immutable diag snapshot to the error response, so operators
    // see launch-scope state even on a launch whose only request is
    // malformed. Idempotent past the first call (OnceLock fast path).
    let _ = launch_diags();

    if let Some(inferlet) = request.inferlet.as_deref() {
        let messages = if request.messages.is_empty() {
            None
        } else {
            Some(request.messages)
        };
        return match inferlet {
            "tree-of-thought" => {
                crate::tot::dispatch(request.input, messages, request.stream, res).await
            }
            "best-of-n" => {
                crate::bestofn::dispatch(request.input, messages, request.stream, res).await
            }
            other => {
                res.respond(with_launch_diags_header(sse::json_error(
                    404,
                    "inferlet_not_found",
                    &format!(
                        "Inferlet '{other}' not available on /v1/chat/completions. \
                         Advanced profile dispatch supports 'tree-of-thought' and \
                         'best-of-n'; use a normal chat-completions body for chat-apc."
                    ),
                )))
                .await
            }
        };
    }

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
    if let Err(err) = validate_messages(&request.messages) {
        return res
            .respond(with_launch_diags_header(json_error_param(
                400,
                err.code,
                &err.message,
                &err.param,
            )))
            .await;
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

    // #572/#619: validate `response_format` before opening any stream.
    // `json_object` and `json_schema` (constrained) and `text` (no-op) are
    // honored; any other `type` is rejected loudly rather than silently
    // ignored. JSON mode + a forced `tool_choice` both constrain
    // the sampler to different grammars, so they cannot combine. The
    // `role:"tool"` handling that lived here moved into `validate_messages`
    // (main now supports tool turns with ids/ordering), so it is not
    // re-checked inline.
    if let Err((code, msg, param)) = validate_response_format(&request) {
        return res
            .respond(with_launch_diags_header(json_error_param(
                400, code, &msg, param,
            )))
            .await;
    }

    let registered = runtime::models();
    if let Some(err) = model_registration_error(&request.model, &registered) {
        return res
            .respond(with_launch_diags_header(sse::json_error(
                err.status,
                err.code,
                &err.message,
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

struct ModelRegistrationError {
    status: u16,
    code: &'static str,
    message: String,
}

fn model_registration_error(
    requested: &str,
    registered: &[String],
) -> Option<ModelRegistrationError> {
    if registered.iter().any(|m| m == requested) {
        return None;
    }
    if registered.is_empty() {
        return Some(ModelRegistrationError {
            status: 404,
            code: "model_not_found",
            message: format!("Model '{requested}' not registered with this engine"),
        });
    }
    Some(ModelRegistrationError {
        status: 409,
        code: "target_mismatch",
        message: format!(
            "Requested model '{requested}' does not match this engine's resident model '{}'; retry after synchronizing the engine target or use the model from /v1/models",
            registered[0]
        ),
    })
}

// =============================================================================
// Validation (F7)
// =============================================================================

/// Roles the chat/template replay path supports. Unknown roles remain an
/// OpenAI-compatibility error (#468).
const SUPPORTED_ROLES: [&str; 4] = ["system", "user", "assistant", "tool"];

/// Single source of truth for the role policy. `None` = fillable;
/// `Some(code)` = rejected with that 400 envelope `code`. Unknown roles —
/// typo, `developer`, `function`, … — are `unsupported_role`. Used by both
/// `validate_messages` (the early request gate) and `build_prompt_tokens`
/// (the callee guard), so the two can't drift.
fn role_error_code(role: &str) -> Option<&'static str> {
    if SUPPORTED_ROLES.contains(&role) {
        None
    } else {
        Some("unsupported_role")
    }
}

/// Build the 400-envelope message for a rejected role at index `i`.
fn role_error_message(i: usize, role: &str, code: &str) -> String {
    let _ = code;
    format!(
        "messages[{i}].role={role:?} is not a supported role (expected one of: system, user, assistant, tool)"
    )
}

/// Error `code`s emitted by the role policy (vs. internal failures like
/// `tool_equip_failed`). A `fill_context` `Err` carrying one of these is
/// a client error (400); anything else is an internal 500. Callers that
/// surface `fill_context` failures (e.g. `tot::dispatch`) use this to
/// pick the status.
pub(crate) fn is_role_error_code(code: &str) -> bool {
    matches!(code, "unsupported_role" | "tool_role_unsupported")
}

/// Validate message roles against the supported set. Returns the
/// offending message index plus the 400 envelope `code`/`message`.
///
/// This is the early request gate ([`handle_parsed`]); [`fill_context`]
/// guards the same policy at the callee so any non-completions caller
/// (e.g. the tree-of-thought dispatch path) also rejects rather than
/// silently demoting an unknown role to `user`.
#[cfg(test)]
fn validate_roles(messages: &[ChatMessage]) -> Result<(), (usize, &'static str, String)> {
    for (i, m) in messages.iter().enumerate() {
        if let Some(code) = role_error_code(&m.role) {
            return Err((i, code, role_error_message(i, &m.role, code)));
        }
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MessageValidationError {
    pub(crate) code: &'static str,
    pub(crate) message: String,
    pub(crate) param: String,
}

impl MessageValidationError {
    pub(crate) fn new(
        code: &'static str,
        message: impl Into<String>,
        param: impl Into<String>,
    ) -> Self {
        Self {
            code,
            message: message.into(),
            param: param.into(),
        }
    }
}

pub(crate) fn validate_messages(messages: &[ChatMessage]) -> Result<(), MessageValidationError> {
    let mut seen_tool_call_ids = HashSet::<String>::new();
    let mut known_tool_names = HashMap::<String, String>::new();
    let mut pending_tool_call_ids = VecDeque::<String>::new();

    for (i, msg) in messages.iter().enumerate() {
        if msg.role != "assistant" && msg.tool_calls.is_some() {
            return Err(MessageValidationError::new(
                "malformed_tool_calls",
                "tool_calls are only valid on assistant messages",
                format!("messages[{i}].tool_calls"),
            ));
        }
        if msg.role != "tool" && msg.tool_call_id.is_some() {
            return Err(MessageValidationError::new(
                "malformed_tool_calls",
                "tool_call_id is only valid on tool messages",
                format!("messages[{i}].tool_call_id"),
            ));
        }

        match msg.role.as_str() {
            "system" | "user" => {
                if !pending_tool_call_ids.is_empty() {
                    return Err(MessageValidationError::new(
                        "invalid_tool_order",
                        "tool result messages must immediately follow the assistant tool_calls they answer",
                        format!("messages[{i}].role"),
                    ));
                }
                validate_text_content(msg, i, false)?;
            }
            "assistant" => {
                if !pending_tool_call_ids.is_empty() {
                    return Err(MessageValidationError::new(
                        "invalid_tool_order",
                        "tool result messages must immediately follow the assistant tool_calls they answer",
                        format!("messages[{i}].role"),
                    ));
                }
                let calls = validate_tool_calls_container(msg, i)?;
                validate_text_content(msg, i, calls.is_some_and(|calls| !calls.is_empty()))?;
                if let Some(calls) = calls {
                    for (j, call) in calls.iter().enumerate() {
                        validate_tool_call(call, i, j)?;
                        let id = tool_call_id(call).expect("validated tool call id");
                        let name = tool_call_function_name(call)
                            .expect("validated tool call function name");
                        if !seen_tool_call_ids.insert(id.to_string()) {
                            return Err(MessageValidationError::new(
                                "duplicate_tool_call_id",
                                format!("tool_call_id '{id}' appears more than once"),
                                format!("messages[{i}].tool_calls[{j}].id"),
                            ));
                        }
                        known_tool_names.insert(id.to_string(), name.to_string());
                        pending_tool_call_ids.push_back(id.to_string());
                    }
                }
            }
            "tool" => {
                validate_text_content(msg, i, false)?;
                let tool_call_id = validate_tool_call_id(msg, i)?;
                if !known_tool_names.contains_key(tool_call_id) {
                    return Err(MessageValidationError::new(
                        "unknown_tool_call_id",
                        format!("tool_call_id '{tool_call_id}' does not match a preceding assistant tool_call"),
                        format!("messages[{i}].tool_call_id"),
                    ));
                }
                match pending_tool_call_ids.front() {
                    Some(expected) if expected == tool_call_id => {
                        pending_tool_call_ids.pop_front();
                    }
                    Some(expected) => {
                        return Err(MessageValidationError::new(
                            "invalid_tool_order",
                            format!(
                                "tool_call_id '{tool_call_id}' answered out of order; expected '{expected}'"
                            ),
                            format!("messages[{i}].tool_call_id"),
                        ));
                    }
                    None => {
                        return Err(MessageValidationError::new(
                            "invalid_tool_order",
                            format!("tool_call_id '{tool_call_id}' was already answered or is not pending"),
                            format!("messages[{i}].tool_call_id"),
                        ));
                    }
                }
            }
            other => {
                if !pending_tool_call_ids.is_empty() {
                    return Err(MessageValidationError::new(
                        "invalid_tool_order",
                        "tool result messages must immediately follow the assistant tool_calls they answer",
                        format!("messages[{i}].role"),
                    ));
                }
                validate_text_content(msg, i, false)?;
                let code = role_error_code(other).unwrap_or("unsupported_role");
                return Err(MessageValidationError::new(
                    code,
                    role_error_message(i, other, code),
                    format!("messages[{i}].role"),
                ));
            }
        }
    }

    if let Some(id) = pending_tool_call_ids.iter().next() {
        return Err(MessageValidationError::new(
            "missing_tool_result",
            format!("assistant tool_call '{id}' is missing a matching tool result message"),
            "messages",
        ));
    }

    Ok(())
}

fn validate_text_content(
    msg: &ChatMessage,
    i: usize,
    allow_empty_or_null: bool,
) -> Result<(), MessageValidationError> {
    match msg.content.as_deref() {
        Some(content) => {
            if content.trim().is_empty() && !allow_empty_or_null {
                return Err(MessageValidationError::new(
                    "invalid_request",
                    "message content must be a non-empty, non-whitespace string",
                    format!("messages[{i}].content"),
                ));
            }
        }
        None if allow_empty_or_null => {}
        None => {
            return Err(MessageValidationError::new(
                "invalid_request",
                "message content must be a non-empty string",
                format!("messages[{i}].content"),
            ));
        }
    }
    Ok(())
}

fn tool_calls_array(msg: &ChatMessage) -> Option<&[RequestToolCall]> {
    msg.tool_calls.as_ref()?.as_array().map(Vec::as_slice)
}

fn validate_tool_calls_container(
    msg: &ChatMessage,
    i: usize,
) -> Result<Option<&[RequestToolCall]>, MessageValidationError> {
    let Some(value) = msg.tool_calls.as_ref() else {
        return Ok(None);
    };
    let Some(calls) = value.as_array() else {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must be a list of objects",
            format!("messages[{i}].tool_calls"),
        ));
    };
    if calls.iter().any(|call| !call.is_object()) {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must be a list of objects",
            format!("messages[{i}].tool_calls"),
        ));
    }
    Ok(Some(calls))
}

fn validate_tool_call_id(msg: &ChatMessage, i: usize) -> Result<&str, MessageValidationError> {
    let Some(value) = msg.tool_call_id.as_ref() else {
        return Err(MessageValidationError::new(
            "missing_tool_call_id",
            "tool messages must include tool_call_id",
            format!("messages[{i}].tool_call_id"),
        ));
    };
    let Some(tool_call_id) = value.as_str() else {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "tool_call_id must be a string",
            format!("messages[{i}].tool_call_id"),
        ));
    };
    if tool_call_id.trim().is_empty() {
        return Err(MessageValidationError::new(
            "missing_tool_call_id",
            "tool messages must include a non-empty tool_call_id",
            format!("messages[{i}].tool_call_id"),
        ));
    }
    Ok(tool_call_id)
}

fn tool_call_id(call: &RequestToolCall) -> Option<&str> {
    call.as_object()?.get("id")?.as_str()
}

fn tool_call_kind(call: &RequestToolCall) -> Option<&str> {
    call.as_object()?.get("type")?.as_str()
}

fn tool_call_function_object(
    call: &RequestToolCall,
) -> Option<&serde_json::Map<String, serde_json::Value>> {
    call.as_object()?.get("function")?.as_object()
}

fn tool_call_function_name(call: &RequestToolCall) -> Option<&str> {
    tool_call_function_object(call)?.get("name")?.as_str()
}

fn tool_call_function_arguments(call: &RequestToolCall) -> Option<&serde_json::Value> {
    tool_call_function_object(call)?.get("arguments")
}

fn validate_tool_call(
    call: &RequestToolCall,
    i: usize,
    j: usize,
) -> Result<(), MessageValidationError> {
    let Some(id) = tool_call_id(call) else {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must include a non-empty id",
            format!("messages[{i}].tool_calls[{j}].id"),
        ));
    };
    if id.trim().is_empty() {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must include a non-empty id",
            format!("messages[{i}].tool_calls[{j}].id"),
        ));
    }
    if tool_call_kind(call) != Some("function") {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must include type=\"function\"",
            format!("messages[{i}].tool_calls[{j}].type"),
        ));
    }
    if tool_call_function_object(call).is_none() {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must include function",
            format!("messages[{i}].tool_calls[{j}].function"),
        ));
    }
    let Some(name) = tool_call_function_name(call) else {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must include a non-empty function.name",
            format!("messages[{i}].tool_calls[{j}].function.name"),
        ));
    };
    if name.trim().is_empty() {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls must include a non-empty function.name",
            format!("messages[{i}].tool_calls[{j}].function.name"),
        ));
    }
    let Some(arguments) = tool_call_function_arguments(call) else {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls[].function.arguments must be a string",
            format!("messages[{i}].tool_calls[{j}].function.arguments"),
        ));
    };
    if !arguments.is_string() {
        return Err(MessageValidationError::new(
            "malformed_tool_calls",
            "assistant tool_calls[].function.arguments must be a string",
            format!("messages[{i}].tool_calls[{j}].function.arguments"),
        ));
    }
    Ok(())
}

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
    let effective_max_tokens = match req.max_tokens.or(req.max_completion_tokens) {
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
                    format!(
                        "speculation.leader_len must be in [{MIN_LEADER_LEN}, {MAX_LEADER_LEN}]"
                    ),
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

/// Validate `response_format` (#572/#619). Returns `Err((code, message,
/// param))` for an unsupported shape. Outcomes:
///   · absent / `{"type":"text"}` → Ok (unconstrained, the default).
///   · `{"type":"json_object"}` → Ok (constrained to a JSON object).
///   · `{"type":"json_schema","json_schema":{"schema":{"type":"object",…}}}`
///     → Ok, constrained to the caller's schema. The `schema` must have an
///     OBJECT root per the host compiler's semantics (see
///     [`json_schema_non_object_reason`]); anything that would compile to a
///     grammar a bare scalar satisfies → 400 `invalid_request`. This honors
///     #619 on the json_schema path.
///   · any constrained mode AND a forced `tool_choice` → 400
///     `invalid_request` (the two constrain the sampler to different
///     grammars and cannot compose).
///   · any other `type` → 400 `response_format_unsupported`, naming the
///     offending value.
///
/// The schema's grammar-compilability is checked later in
/// [`build_json_constraint`] (it needs a host call); this stays pure.
/// Root keywords the host schema compiler (`visit_schema`) honors BEFORE
/// the declared `type`, each short-circuiting to a non-object grammar a
/// bare scalar can satisfy. A root carrying any of these is NOT an object
/// root even when it also declares `"type":"object"` (#619 review F1).
/// Order mirrors `Vendor/pie/runtime/src/inference/structured/json_schema.rs`
/// `visit_schema`.
const JSON_SCHEMA_NON_OBJECT_ROOT_KEYWORDS: [&str; 6] =
    ["$ref", "const", "enum", "anyOf", "oneOf", "allOf"];

/// `None` when the host compiler would constrain this `json_schema.schema`
/// to a JSON **object** root (#619); otherwise a 400 reason explaining why
/// it would not. Mirrors `visit_schema`'s precedence:
///   1. a composition/literal keyword (`$ref`/`const`/`enum`/`anyOf`/
///      `oneOf`/`allOf`) wins over `type` → not an object root,
///   2. `type` is the string `"object"` → object root,
///   3. `type` is an array → a union. Accepted ONLY when every alternative
///      is `"object"` or `"null"`. This is a DELIBERATE asymmetry (#619
///      review v3 F1): a nullable-object union (`["object","null"]`) is
///      honored because the caller explicitly opted into a `null` answer —
///      the compiler emits `(object | "null")`, so a bare `null` is a
///      permitted output here, but no other bare scalar is. A union mixing
///      object with a non-`null` scalar (`["object","string"]`) is rejected
///      so a bare string/number cannot slip through. (`json_object` mode is
///      unaffected — it stays strictly object-root, never nullable.)
///   4. `type` absent → object root only when an object-implying keyword
///      (`properties`/`required`/`minProperties`/`maxProperties`) is present
///      (the same inference `visit_schema` makes).
fn json_schema_non_object_reason(schema: Option<&serde_json::Value>) -> Option<String> {
    let Some(schema) = schema else {
        return Some(
            "response_format \"json_schema\" requires a json_schema.schema object".to_string(),
        );
    };
    let Some(obj) = schema.as_object() else {
        return Some(
            "response_format \"json_schema\".schema must be a JSON object with an object root \
             (\"type\":\"object\")"
                .to_string(),
        );
    };
    if let Some(kw) = JSON_SCHEMA_NON_OBJECT_ROOT_KEYWORDS
        .iter()
        .find(|k| obj.contains_key(**k))
    {
        return Some(format!(
            "response_format \"json_schema\".schema root keyword \"{kw}\" overrides \
             \"type\":\"object\" with a non-object (bare-scalar) grammar; the answer must be \
             constrained to a JSON object"
        ));
    }
    let is_object_root = match obj.get("type") {
        Some(serde_json::Value::String(t)) => t == "object",
        Some(serde_json::Value::Array(types)) => {
            // #619 review v3 F1 (deliberate): a nullable-object union
            // (`["object","null"]`) is honored — the caller explicitly opted
            // into a `null` answer, so `null` is the ONLY non-object scalar
            // allowed. Any other scalar alternative (e.g. `["object","string"]`)
            // is rejected so a bare string/number cannot satisfy the grammar.
            types.iter().any(|t| t.as_str() == Some("object"))
                && types
                    .iter()
                    .all(|t| matches!(t.as_str(), Some("object") | Some("null")))
        }
        Some(_) => false,
        None => ["properties", "required", "minProperties", "maxProperties"]
            .iter()
            .any(|k| obj.contains_key(*k)),
    };
    if is_object_root {
        None
    } else {
        Some(
            "response_format \"json_schema\".schema must constrain the answer to a JSON object: \
             declare \"type\":\"object\" (or an object-implying root such as a \"properties\" map)"
                .to_string(),
        )
    }
}

fn validate_response_format(
    req: &ChatCompletionsRequest,
) -> Result<(), (&'static str, String, &'static str)> {
    let Some(rf) = req.response_format.as_ref() else {
        return Ok(());
    };
    // A constrained answer pins the sampler to a JSON grammar; a forced
    // tool_choice pins it to the tool-call grammar. They are mutually
    // exclusive — reject rather than silently letting one win.
    let reject_forced_tool = |mode: &str| -> Result<(), (&'static str, String, &'static str)> {
        if !matches!(forced_tool_choice(req.tool_choice.as_ref()), ForcedToolChoice::No) {
            return Err((
                "invalid_request",
                format!(
                    "response_format \"{mode}\" cannot combine with a forced tool_choice \
                     (the two constrain decoding to different grammars); send one or the other"
                ),
                "response_format",
            ));
        }
        Ok(())
    };
    match rf.kind.as_str() {
        ResponseFormat::TEXT | "" => Ok(()),
        ResponseFormat::JSON_OBJECT => reject_forced_tool(ResponseFormat::JSON_OBJECT),
        ResponseFormat::JSON_SCHEMA => {
            // #619 F1/F2: require the host compiler to route this schema's
            // ROOT to an object grammar — a non-object root (incl. one whose
            // `type:"object"` is overridden by a higher-precedence
            // composition/literal keyword) compiles to a grammar a bare
            // scalar satisfies, the exact hole #619 closes.
            if let Some(reason) =
                json_schema_non_object_reason(rf.json_schema.as_ref().and_then(|j| j.schema.as_ref()))
            {
                return Err(("invalid_request", reason, "response_format"));
            }
            reject_forced_tool(ResponseFormat::JSON_SCHEMA)
        }
        other => Err((
            "response_format_unsupported",
            format!(
                "response_format.type=\"{other}\" is not supported; supported values are \
                 \"json_object\", \"json_schema\", and \"text\" (unconstrained)"
            ),
            "response_format",
        )),
    }
}

/// Compile the Phase-2 JSON grammar constraint for a json-mode request,
/// or `Ok(None)` when the request is not in JSON mode (#619). Built BEFORE
/// the SSE stream opens (mirrors [`build_forced_tool_constraint`]) so a
/// malformed `json_schema` returns a clean `400` envelope instead of a
/// half-open stream that errors mid-flight.
fn build_json_constraint(
    model: &Model,
    req: &ChatCompletionsRequest,
) -> Result<Option<GrammarConstraint>, (u16, &'static str, String)> {
    let Some(schema) = json_constraint_schema(req) else {
        return Ok(None);
    };
    GrammarConstraint::from_json_schema(&schema, model)
        .map(Some)
        .map_err(|e| {
            (
                400,
                "invalid_json_schema",
                format!("response_format json schema failed to compile into a grammar: {e}"),
            )
        })
}

/// Build an OpenAI-shape error JSON with a populated `param` field.
pub(crate) fn json_error_param(
    status: u16,
    code: &str,
    message: &str,
    param: &str,
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
    if let Err(err) = validate_tool_replay_for_model(&req.messages, &model) {
        return res
            .respond(with_launch_diags_header(json_error_param(
                400,
                err.code,
                &err.message,
                &err.param,
            )))
            .await;
    }
    // #522: cross-request KV prefix cache. Engaged only for an enabled
    // `cache` directive; absent/disabled/bypass falls through to the
    // legacy full-rebuild path below (byte-identical to pre-#522).
    let cache_plan: Option<ReusePlan> = match req.cache.clone() {
        Some(d) if d.enabled() => {
            match prefix_cache::plan(&model, &req.model, &req.messages, req.tools.as_deref(), d) {
                Ok(p) => Some(p),
                Err((code, msg)) => {
                    return res
                        .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
                        .await;
                }
            }
        }
        _ => None,
    };
    let _cache_guard = cache_plan.as_ref().map(|plan| prefix_cache::protect(&model, plan));
    let (mut ctx, mut cache_diag): (Context, Option<CacheDiag>) = match &cache_plan {
        Some(plan) => match prefix_cache::acquire(&model, plan) {
            Ok((ctx, diag)) => (ctx, Some(diag)),
            Err((code, msg)) => {
                return res
                    .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
                    .await;
            }
        },
        None => {
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
            if let Err((code, msg)) =
                fill_context(&mut ctx, &model, &req.messages, req.tools.as_deref(), true)
            {
                return res
                    .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
                    .await;
            }
            (ctx, None)
        }
    };
    // Usage accounting (OpenAI `usage` block): `ctx.seq_len()` only counts
    // committed/working tokens already flushed to the KV cache, NOT the
    // buffered prompt tokens `fill_context`/cache-acquire just queued —
    // those are flushed lazily by `forward()`/`generate()`. Add
    // `ctx.buffer().len()` to get the full prompt length covering both
    // the legacy full-rebuild path and the #522 reuse path (reused prefix
    // + appended suffix). `cached_tokens` mirrors `CacheDiag::base_boundary`,
    // which is already documented as "0 on a miss" — correct with or
    // without an active cache plan.
    let prompt_tokens = ctx.seq_len() as usize + ctx.buffer().len();
    let cached_tokens = cache_diag.as_ref().map_or(0, |d| d.base_boundary);

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
                .respond(with_launch_diags_header(sse::json_error(
                    status, code, &msg,
                )))
                .await;
        }
    };
    let forced_tool = tool_constraint.is_some();

    // #619: compile the JSON-mode grammar BEFORE the Emitter, for the same
    // reason as the tool constraint — a malformed `json_schema` returns a
    // clean 400 rather than a half-open stream. `None` for non-JSON
    // requests (the canonical loop ignores it).
    let mut json_constraint = match build_json_constraint(&model, &req) {
        Ok(c) => c,
        Err((status, code, msg)) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    status, code, &msg,
                )))
                .await;
        }
    };

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
        usage: None,
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
    let json_constrained = json_mode(&req);
    let (strategy, fallback_reason, want_metrics, dims) =
        plan_strategy(req.speculation.as_ref(), greedy, forced_tool, json_constrained);

    // #572: JSON Think runs the dedicated two-phase constrained path and
    // returns its own terminal frames. The single-loop path below is left
    // byte-identical for every non-JSON request (normal / Repeat Boost /
    // ToT / tool_choice). JSON mode is mutually exclusive with a forced
    // tool_choice (400-rejected upstream), so `tool_constraint` is None
    // here and the tool surface is irrelevant.
    if json_constrained {
        let mut in_reasoning = false;
        let mut reason_dec = ReasoningDecoder::new(&model);
        let (outcome, error_diag, disconnected, completion_tokens) = {
            let mut sink = JsonSink::Stream {
                em: &mut em,
                id: &id,
                created,
                model: &req.model,
            };
            // Phase 1: capture reasoning, suppress content, stop when the
            // thinking block closes (or the first content batch on a
            // non-thinking model).
            let mut chat_dec1 = chat::Decoder::new(&model);
            let gen1 = ctx
                .generate(generate::resolve_sampler(temperature, top_p))
                .max_tokens(max_tokens)
                .stop(&stop_tokens);
            let r1 = run_json_phase(
                gen1,
                &mut chat_dec1,
                &mut reason_dec,
                &mut sink,
                &mut in_reasoning,
                JsonPhaseOpts {
                    emit_reasoning: true,
                    emit_content: false,
                    stop_after_reasoning: true,
                    raw_content: false,
                    max_tokens,
                },
            )
            .await;
            if r1.disconnected {
                (Outcome::Aborted, None, true, r1.tokens_generated)
            } else if let Some(diag) = r1.error_diag {
                (Outcome::Aborted, Some(diag), false, r1.tokens_generated)
            } else {
                // Phase 2: JSON-grammar-constrained answer. The fresh chat
                // decoder + fresh generator continue the open assistant
                // turn; Phase 1's tail is flushed into this generator's
                // first forward pass as context (never re-emitted).
                let phase2_budget = json_phase2_budget(max_tokens, r1.tokens_generated);
                let mut chat_dec2 = chat::Decoder::new(&model);
                let gen2 = ctx
                    .generate(generate::resolve_sampler(temperature, top_p))
                    .max_tokens(phase2_budget)
                    .stop(&stop_tokens)
                    .constrain(
                        json_constraint
                            .take()
                            .expect("json mode implies a compiled JSON constraint"),
                    );
                let r2 = run_json_phase(
                    gen2,
                    &mut chat_dec2,
                    &mut reason_dec,
                    &mut sink,
                    &mut in_reasoning,
                    JsonPhaseOpts {
                        emit_reasoning: false,
                        emit_content: true,
                        stop_after_reasoning: false,
                        raw_content: true,
                        max_tokens: phase2_budget,
                    },
                )
                .await;
                // F3: a clean-but-empty JSON answer is a contract failure.
                // Capture both phases' generated counts before `r2` is moved
                // into the finalizer — the usage block needs the full
                // completion total (mirrors `handle_non_streaming`).
                let r1_tokens = r1.tokens_generated;
                let r2_tokens = r2.tokens_generated;
                let (outcome, error_diag, disconnected) = json_phase2_finalize(r2);
                (outcome, error_diag, disconnected, r1_tokens + r2_tokens)
            }
        };
        if disconnected {
            return em.finish();
        }
        let final_chunk = ChatCompletionChunk {
            id: &id,
            object: "chat.completion.chunk",
            created,
            model: &req.model,
            choices: vec![ChunkChoice {
                index: 0,
                delta: ChunkDelta::default(),
                finish_reason: Some(outcome.finish_reason()),
            }],
            usage: None,
        };
        if let Err(EmitError::Serialize(e)) = em.emit_json(&final_chunk).await {
            eprintln!("[chat-apc] json final-chunk serialize bug: {e}");
        }
        if let Some((code, message)) = &error_diag {
            if let Err(EmitError::Serialize(e)) =
                em.emit_json(&SseError::new(code, message)).await
            {
                eprintln!("[chat-apc] json error-meta serialize bug: {e}");
            }
        }
        // Only when the caller ALSO sent a speculation block (uncommon for
        // a JSON profile) do we surface why drafting didn't engage —
        // `json_constrained`. A normal JSON Think request is byte-clean.
        if want_metrics {
            let report = SpecMetricsReport::build(
                false,
                fallback_reason,
                dims,
                SpecMetrics::default(),
                0,
                0,
                Duration::ZERO,
                // JSON Think runs Plain/json_constrained with speculation
                // gated off, so there is no Cacheback sidecar to report.
                None,
            );
            report.log_spec_stats();
            let frame = SpecMetricsSse {
                event: "spec_metrics",
                report: &report,
            };
            if let Err(EmitError::Serialize(e)) = em.emit_json(&frame).await {
                eprintln!("[chat-apc] json spec_metrics serialize bug: {e}");
            }
        }
        // OpenAI `stream_options.include_usage: true` — the JSON Think path
        // returns its own terminal frames above, so the shared usage-chunk
        // emit below is unreachable here; mirror it so structured-output
        // streaming honors the opt-in too (completion = phase1 + phase2).
        if req.stream_options.as_ref().is_some_and(|o| o.include_usage) {
            let usage_chunk = ChatCompletionChunk {
                id: &id,
                object: "chat.completion.chunk",
                created,
                model: &req.model,
                choices: Vec::new(),
                usage: Some(Usage::build(prompt_tokens, completion_tokens, cached_tokens)),
            };
            if let Err(EmitError::Serialize(e)) = em.emit_json(&usage_chunk).await {
                eprintln!("[chat-apc] json usage-chunk serialize bug: {e}");
            }
        }
        // #711: engine-true context meter on the JSON-constrained path too,
        // mirroring the plain stream exit. Always emitted (the app's meter
        // reads this, independent of the OpenAI `include_usage` opt-in above).
        {
            let window = ctx.max_tokens();
            let frame = sse::SseUsage::new(
                prompt_tokens as u32,
                completion_tokens as u32,
                (window > 0).then_some(window),
            );
            if let Err(EmitError::Serialize(e)) = em.emit_json(&frame).await {
                eprintln!("[chat-apc] json usage meta-frame serialize bug: {e}");
            }
        }
        sse::emit_done_logged(&mut em, "json_stream_exit").await;
        return em.finish();
    }

    let spec_enabled = matches!(strategy, DecodeStrategy::Speculative(_));
    let (sidecar_lease, sidecar_metrics) = match &strategy {
        DecodeStrategy::Speculative(cfg) => sidecar_for_request(
            &req.model,
            req.tools.as_deref(),
            &req.messages,
            req.speculation.as_ref(),
            cfg,
        ),
        DecodeStrategy::Plain => (None, None),
    };
    let sampler = generate::resolve_sampler(temperature, top_p);
    let seed_tokens = if spec_enabled {
        seed_tokens_from(&model, &req.messages)
    } else {
        Vec::new()
    };
    let generate::GenSession {
        generator: mut stream,
        metrics: spec_metrics_handle,
    } = generate::start(
        &mut ctx,
        sampler,
        max_tokens,
        &stop_tokens,
        strategy,
        &seed_tokens,
        sidecar_lease.as_ref().map(|lease| Arc::clone(&lease.cache)),
    );
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
    let mut sidecar_assistant_content = String::new();
    let mut in_reasoning = false;
    // #466: reasoning text already streamed as `reasoning_content` deltas.
    // On a reasoning `End(s)` we emit only the un-streamed suffix so text
    // that arrived in the SAME multi-token batch as the closing boundary
    // (one `End` event, no prior `Delta`) is not dropped.
    let mut reasoning_streamed = String::new();
    // #522: visible assistant text, captured so the prefix cache can save
    // the canonical next-turn boundary. Only used when `cache_plan` is
    // engaged.
    let mut full_text = String::new();

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
            Err(e) => {
                let m = e.to_string();
                break (Outcome::Aborted, Some((classify_forward_error(&m), m)));
            }
        };
        let out = match step.execute().await {
            Ok(o) => o,
            Err(e) => {
                let m = e.to_string();
                break (Outcome::Aborted, Some((classify_forward_error(&m), m)));
            }
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
            break (
                Outcome::Aborted,
                Some((STARVED_CODE, STARVED_MESSAGE.to_string())),
            );
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
        // #600: true when the reasoning block closes ON this batch, so the chat
        // delta below can recover the answer-head that rode the `</think>` close
        // (speculative straddle) instead of dropping it.
        let mut reason_ended = false;
        match reason_dec.feed(&out.tokens) {
            Ok(inferlet::reasoning::Event::Start) => {
                in_reasoning = true;
            }
            Ok(inferlet::reasoning::Event::Delta(s)) => {
                in_reasoning = true;
                reasoning_streamed.push_str(&s);
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
                    usage: None,
                };
                try_emit!(em, &chunk, "reasoning_delta");
            }
            Ok(inferlet::reasoning::Event::End(s)) => {
                in_reasoning = false;
                reason_ended = true;
                // #466: a multi-token speculative batch can carry the
                // reasoning text AND the closing boundary in one feed, so
                // the decoder reports it only via `End(s)` with no prior
                // `Delta`. Emit the un-streamed suffix so that text is not
                // dropped; if `End(s)` disagrees with the streamed deltas
                // (detok re-segmentation) trust the deltas (F5 parity).
                if let Some(residual) = s.strip_prefix(reasoning_streamed.as_str()) {
                    if !residual.is_empty() {
                        let chunk = ChatCompletionChunk {
                            id: &id,
                            object: "chat.completion.chunk",
                            created,
                            model: &req.model,
                            choices: vec![ChunkChoice {
                                index: 0,
                                delta: ChunkDelta {
                                    reasoning_content: Some(residual),
                                    ..Default::default()
                                },
                                finish_reason: None,
                            }],
                            usage: None,
                        };
                        reasoning_streamed.push_str(residual);
                        try_emit!(em, &chunk, "reasoning_delta");
                    }
                }
            }
            Ok(inferlet::reasoning::Event::Idle) => {
                reason_idle = true;
            }
            Err(e) => {
                break (
                    Outcome::Aborted,
                    Some(("reasoning_decode_failed", e.to_string())),
                );
            }
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
            // Demux the chat delta through `visible_content`: the full delta
            // when the batch is outside reasoning; the recovered answer-head
            // when `</think>` closed on this (speculative) batch (#600); ""
            // when suppressed (inside reasoning, the delimiter, or a forced
            // tool call — `forced_tool` makes the whole generation the call,
            // which rides only the terminal `tool_calls` delta).
            Ok(chat::Event::Delta(s)) => {
                let visible = visible_content(&s, reason_idle, was_in_reasoning, reason_ended, forced_tool);
                if !visible.is_empty() {
                    // #522: mirror the visible text the App persists, so the
                    // save gate can compare it against the generated tokens.
                    full_text.push_str(visible);
                    sidecar_assistant_content.push_str(visible);
                    let chunk = ChatCompletionChunk {
                        id: &id,
                        object: "chat.completion.chunk",
                        created,
                        model: &req.model,
                        choices: vec![ChunkChoice {
                            index: 0,
                            delta: ChunkDelta {
                                content: Some(visible),
                                ..Default::default()
                            },
                            finish_reason: None,
                        }],
                        usage: None,
                    };
                    // Non-terminal delta frame: disconnect = silently
                    // abandon (no client to push to); serialize-bug =
                    // emit inline error frame + [DONE] before bailing,
                    // so any client still attached gets a signal.
                    try_emit!(em, &chunk, "content_delta");
                }
                // Otherwise suppressed: this batch is reasoning-channel material —
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
                    Some((
                        "chat_template_interrupt",
                        format!("control token {id} from chat template"),
                    )),
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

    // #711: engine-true context accounting for the terminal `usage` frame.
    // `stream` borrows `&mut ctx`, so capture the completion count and drop
    // it before reading the context's page state. Occupancy is `seq_len +
    // buffer` (committed + working + buffered tokens) — engine-true, and
    // preferred over re-counting the re-sent transcript. `max_tokens` is
    // the effective KV-page-budget window; 0 when the budget is unknown.
    let usage_completion = stream.tokens_generated() as u32;
    drop(stream);
    let usage_window = ctx.max_tokens();
    let usage_used = ctx.seq_len() + ctx.buffer().len() as u32;
    let usage_prompt = usage_used.saturating_sub(usage_completion);
    let usage_window = (usage_window > 0).then_some(usage_window);

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
        usage: None,
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
    // OpenAI `stream_options.include_usage: true` — emit one extra
    // `chat.completion.chunk` with empty `choices` and a populated
    // `usage` block immediately after the finish_reason chunk, matching
    // the vLLM/OpenAI convention. Absent the opt-in, streams stay
    // byte-identical to before this feature.
    if req.stream_options.as_ref().is_some_and(|o| o.include_usage) {
        let usage_chunk = ChatCompletionChunk {
            id: &id,
            object: "chat.completion.chunk",
            created,
            model: &req.model,
            choices: Vec::new(),
            usage: Some(Usage::build(prompt_tokens, spec_generated, cached_tokens)),
        };
        if let Err(EmitError::Serialize(e)) = em.emit_json(&usage_chunk).await {
            eprintln!("[chat-apc] usage-chunk serialize bug: {e}");
        }
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
        let frame =
            SseError::new("tool_decode_disabled", &rendered).with_dedup_counts(distinct, overflow);
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
    // Terminal generation-throughput frame for UI/benchmark consumers.
    // The counter is engine-side generated output tokens (including
    // reasoning tokens); the timer is decode-loop elapsed, so this is
    // throughput, not prefill latency / TTFT. Failed/tool-call partials do
    // not emit a metric until a reliable display policy exists.
    if matches!(outcome, Outcome::Natural | Outcome::MaxTokens) {
        if let Some(frame) = GenerationMetricsSse::build(spec_generated, spec_start.elapsed()) {
            if let Err(EmitError::Serialize(e)) = em.emit_json(&frame).await {
                eprintln!("[chat-apc] generation_metrics serialize bug: {e}");
            }
        }
    }
    let sidecar_terminal_turn = match (outcome, error_diag.is_none()) {
        (Outcome::Natural | Outcome::MaxTokens, true) => {
            Some(("assistant", sidecar_assistant_content.as_str()))
        }
        _ => None,
    };
    persist_sidecar(sidecar_lease.as_ref(), sidecar_terminal_turn);
    // #418: terminal spec_metrics frame (only when the caller opted into
    // the speculation surface, so normal streams are byte-identical).
    if want_metrics {
        let spec = spec_metrics_handle
            .map(|h| h.lock().unwrap().clone())
            .unwrap_or_default();
        let report = SpecMetricsReport::build(
            spec_enabled,
            fallback_reason,
            dims,
            spec,
            spec_generated,
            spec_steps,
            spec_start.elapsed(),
            sidecar_metrics,
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
    // #522: save the next reusable boundary on a clean completion and emit
    // the cache diagnostics frame. Saving is gated on a real assistant turn
    // (Natural/MaxTokens) — a cancelled/aborted/tool-call turn must not
    // advance the stable boundary. `finalize` builds the boundary in its
    // own context, so the generator's borrow of `ctx` is irrelevant here.
    if let (Some(plan), Some(mut diag)) = (cache_plan.as_ref(), cache_diag.take()) {
        if matches!(outcome, Outcome::Natural | Outcome::MaxTokens) {
            prefix_cache::finalize(plan, &full_text, &model, &mut diag).await;
        }
        if let Err(EmitError::Serialize(e)) = em.emit_json(&diag).await {
            eprintln!("[chat-apc] cache diag serialize bug: {e}");
        }
    }
    // #711: engine-true token meter for the conversation context. Always
    // emitted (cheap) so the GUI renders used/window on every turn.
    {
        let frame = sse::SseUsage::new(usage_prompt, usage_completion, usage_window);
        if let Err(EmitError::Serialize(e)) = em.emit_json(&frame).await {
            eprintln!("[chat-apc] usage meta-frame serialize bug: {e}");
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
    if let Err(err) = validate_tool_replay_for_model(&req.messages, &model) {
        return res
            .respond(with_launch_diags_header(json_error_param(
                400,
                err.code,
                &err.message,
                &err.param,
            )))
            .await;
    }
    // #522: cross-request KV prefix cache (see handle_streaming). Legacy
    // callers (no enabled `cache` directive) take the unchanged rebuild
    // path below.
    let cache_plan: Option<ReusePlan> = match req.cache.clone() {
        Some(d) if d.enabled() => {
            match prefix_cache::plan(&model, &req.model, &req.messages, req.tools.as_deref(), d) {
                Ok(p) => Some(p),
                Err((code, msg)) => {
                    return res
                        .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
                        .await;
                }
            }
        }
        _ => None,
    };
    let _cache_guard = cache_plan.as_ref().map(|plan| prefix_cache::protect(&model, plan));
    let (mut ctx, mut cache_diag): (Context, Option<CacheDiag>) = match &cache_plan {
        Some(plan) => match prefix_cache::acquire(&model, plan) {
            Ok((ctx, diag)) => (ctx, Some(diag)),
            Err((code, msg)) => {
                return res
                    .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
                    .await;
            }
        },
        None => {
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
            if let Err((code, msg)) =
                fill_context(&mut ctx, &model, &req.messages, req.tools.as_deref(), true)
            {
                return res
                    .respond(with_launch_diags_header(sse::json_error(500, code, &msg)))
                    .await;
            }
            (ctx, None)
        }
    };
    // Usage accounting (see handle_streaming for the rationale).
    let prompt_tokens = ctx.seq_len() as usize + ctx.buffer().len();
    let cached_tokens = cache_diag.as_ref().map_or(0, |d| d.base_boundary);

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
                .respond(with_launch_diags_header(sse::json_error(
                    status, code, &msg,
                )))
                .await;
        }
    };
    let forced_tool = tool_constraint.is_some();
    // #619: compile the JSON-mode grammar up front so a malformed
    // `json_schema` returns a clean 400 (mirrors handle_streaming).
    let mut json_constraint = match build_json_constraint(&model, &req) {
        Ok(c) => c,
        Err((status, code, msg)) => {
            return res
                .respond(with_launch_diags_header(sse::json_error(
                    status, code, &msg,
                )))
                .await;
        }
    };
    let stop_tokens = chat::stop_tokens(&model);
    // #418: plain vs speculative decode (see handle_streaming for the
    // greedy + forced-tool gate rationale).
    let greedy = temperature <= 0.0;
    let json_constrained = json_mode(&req);
    let (strategy, fallback_reason, want_metrics, dims) =
        plan_strategy(req.speculation.as_ref(), greedy, forced_tool, json_constrained);

    // #572: JSON Think two-phase constrained path (mirrors handle_streaming).
    // The canonical loop below is untouched for every non-JSON request.
    if json_constrained {
        let mut full_text = String::new();
        let mut reasoning_text = String::new();
        let mut in_reasoning = false;
        let mut reason_dec = ReasoningDecoder::new(&model);
        let (outcome, error_diag, completion_tokens): (Outcome, Option<(&str, String)>, usize) = {
            let mut sink = JsonSink::Buffer {
                content: &mut full_text,
                reasoning: &mut reasoning_text,
            };
            // Phase 1: reasoning only, suppress content.
            let mut chat_dec1 = chat::Decoder::new(&model);
            let gen1 = ctx
                .generate(generate::resolve_sampler(temperature, top_p))
                .max_tokens(max_tokens)
                .stop(&stop_tokens);
            let r1 = run_json_phase(
                gen1,
                &mut chat_dec1,
                &mut reason_dec,
                &mut sink,
                &mut in_reasoning,
                JsonPhaseOpts {
                    emit_reasoning: true,
                    emit_content: false,
                    stop_after_reasoning: true,
                    raw_content: false,
                    max_tokens,
                },
            )
            .await;
            if let Some(diag) = r1.error_diag {
                (Outcome::Aborted, Some(diag), r1.tokens_generated)
            } else {
                // Phase 2: JSON-grammar-constrained answer.
                let phase2_budget = json_phase2_budget(max_tokens, r1.tokens_generated);
                let mut chat_dec2 = chat::Decoder::new(&model);
                let gen2 = ctx
                    .generate(generate::resolve_sampler(temperature, top_p))
                    .max_tokens(phase2_budget)
                    .stop(&stop_tokens)
                    .constrain(
                        json_constraint
                            .take()
                            .expect("json mode implies a compiled JSON constraint"),
                    );
                let r2 = run_json_phase(
                    gen2,
                    &mut chat_dec2,
                    &mut reason_dec,
                    &mut sink,
                    &mut in_reasoning,
                    JsonPhaseOpts {
                        emit_reasoning: false,
                        emit_content: true,
                        stop_after_reasoning: false,
                        raw_content: true,
                        max_tokens: phase2_budget,
                    },
                )
                .await;
                // F3: a clean-but-empty JSON answer is a contract failure
                // (Buffer sink never disconnects, so the flag is unused here).
                let r1_tokens = r1.tokens_generated;
                let r2_tokens = r2.tokens_generated;
                let (outcome, error_diag, _) = json_phase2_finalize(r2);
                (outcome, error_diag, r1_tokens + r2_tokens)
            }
        };

        // Pure failure (no content AND no reasoning produced) → 500, or a
        // retryable 503 for over-capacity `server_busy` (#470/#485 F1) — same
        // as the canonical no-tokens-produced branch.
        let has_partial = !full_text.is_empty() || !reasoning_text.is_empty();
        if error_diag.is_some() && !has_partial {
            let (code, msg) = error_diag.unwrap();
            let status = json_pure_failure_status(code);
            return res
                .respond(with_launch_diags_header(sse::json_error(status, code, &msg)))
                .await;
        }

        let id = next_id();
        let reasoning_opt = if reasoning_text.is_empty() {
            None
        } else {
            Some(reasoning_text.as_str())
        };
        let error_block = error_diag.as_ref().map(|(code, msg)| PartialError {
            kind: "server_error",
            code,
            message: msg.as_str(),
            param: None,
            distinct_modes: None,
            overflow_modes: None,
        });
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
        // Surface why drafting didn't engage only when the caller also
        // sent a speculation block (`json_constrained`); a plain JSON
        // request is byte-clean.
        let spec_metrics = if want_metrics {
            let report = SpecMetricsReport::build(
                false,
                fallback_reason,
                dims,
                SpecMetrics::default(),
                0,
                0,
                Duration::ZERO,
                // JSON Think runs Plain/json_constrained with speculation
                // gated off, so there is no Cacheback sidecar to report.
                None,
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
                    tool_calls: None,
                },
                finish_reason: outcome.finish_reason(),
            }],
            error: error_block,
            warnings: warnings_vec,
            spec_metrics,
            usage: Usage::build(prompt_tokens, completion_tokens, cached_tokens),
        };
        let json = serde_json::to_string(&body).expect("ChatCompletion must serialize");
        let (status, partial_kind) = match &error_diag {
            Some(_) => (502u16, Some("fatal")),
            None => (200u16, None),
        };
        let mut builder = Response::builder()
            .status(status)
            .header("Content-Type", "application/json");
        if let Some(kind) = partial_kind {
            builder = builder.header("X-ChatAPC-Partial-Error", kind);
        }
        let response = builder.body(json.into_body()).unwrap();
        return res.respond(with_launch_diags_header(response)).await;
    }

    let spec_enabled = matches!(strategy, DecodeStrategy::Speculative(_));
    let (sidecar_lease, sidecar_metrics) = match &strategy {
        DecodeStrategy::Speculative(cfg) => sidecar_for_request(
            &req.model,
            req.tools.as_deref(),
            &req.messages,
            req.speculation.as_ref(),
            cfg,
        ),
        DecodeStrategy::Plain => (None, None),
    };
    let sampler = generate::resolve_sampler(temperature, top_p);
    let seed_tokens = if spec_enabled {
        seed_tokens_from(&model, &req.messages)
    } else {
        Vec::new()
    };
    let generate::GenSession {
        generator: mut stream,
        metrics: spec_metrics_handle,
    } = generate::start(
        &mut ctx,
        sampler,
        max_tokens,
        &stop_tokens,
        strategy,
        &seed_tokens,
        sidecar_lease.as_ref().map(|lease| Arc::clone(&lease.cache)),
    );
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
            Err(e) => {
                let m = e.to_string();
                break (Outcome::Aborted, Some((classify_forward_error(&m), m)));
            }
        };
        let out = match step.execute().await {
            Ok(o) => o,
            Err(e) => {
                let m = e.to_string();
                break (Outcome::Aborted, Some((classify_forward_error(&m), m)));
            }
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
            break (
                Outcome::Aborted,
                Some((STARVED_CODE, STARVED_MESSAGE.to_string())),
            );
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
        // #600: true when the reasoning block closes ON this batch (mirrors the
        // streaming branch), so the chat delta below recovers the answer-head
        // that rode the `</think>` close batch instead of dropping it.
        let mut reason_ended = false;
        match reason_dec.feed(&out.tokens) {
            Ok(inferlet::reasoning::Event::Start) => in_reasoning = true,
            Ok(inferlet::reasoning::Event::Delta(s)) => {
                in_reasoning = true;
                reasoning_text.push_str(&s);
            }
            // #466: recover reasoning text that arrived in the SAME
            // multi-token batch as the closing boundary. A warmed
            // speculative cache can make the engine accept the reasoning
            // token(s) and `</think>` together, so the decoder reports
            // them only via `End(s)` with no prior `Delta` and the
            // delta-stitched `reasoning_text` would miss them. Append only
            // the un-streamed suffix. If `End(s)` disagrees with the
            // accumulated deltas (detok re-segmentation) trust the deltas,
            // which keeps stream + non-stream byte-identical (F5 parity:
            // the streaming branch applies the identical suffix rule).
            Ok(inferlet::reasoning::Event::End(s)) => {
                in_reasoning = false;
                reason_ended = true;
                if s.starts_with(reasoning_text.as_str()) {
                    reasoning_text = s;
                }
            }
            Ok(inferlet::reasoning::Event::Idle) => {
                reason_idle = true;
            }
            Err(e) => {
                break (
                    Outcome::Aborted,
                    Some(("reasoning_decode_failed", e.to_string())),
                );
            }
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
            // Demux through the shared `visible_content` (see handle_streaming):
            // full delta when outside reasoning; recovered answer-head when
            // `</think>` closed on this speculative batch (#600); "" when
            // suppressed (inside reasoning, the delimiter, or a forced tool call
            // whose content rides only the terminal tool_calls delta).
            Ok(chat::Event::Delta(s)) => {
                let visible =
                    visible_content(&s, reason_idle, was_in_reasoning, reason_ended, forced_tool);
                full_text.push_str(visible);
            }
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
        // #470: over-capacity backpressure is a retryable 503, not a 500.
        // The reservation timed out before any token was produced (the
        // common over-subscription case lands here, with no partial body),
        // so the client should back off and retry rather than treat it as a
        // hard server fault. Every other abort stays a 500.
        let status = if code == SERVER_BUSY_CODE { 503 } else { 500 };
        // N1: pure-failure 5xx attaches launch diags via header —
        // the snapshot is immutable, so the next request gets the
        // same diags regardless.
        return res
            .respond(with_launch_diags_header(sse::json_error(status, code, &msg)))
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
                .map(|d| NonStreamWarning {
                    code: d.code,
                    message: d.message.as_str(),
                })
                .collect(),
        )
    };
    let sidecar_terminal_turn = match (outcome, error_diag.is_none()) {
        (Outcome::Natural | Outcome::MaxTokens, true) => Some(("assistant", full_text.as_str())),
        _ => None,
    };
    persist_sidecar(sidecar_lease.as_ref(), sidecar_terminal_turn);
    // #418: speculation metrics, only when the caller opted into the
    // surface (so normal responses are byte-identical).
    let spec_metrics = if want_metrics {
        let spec = spec_metrics_handle
            .map(|h| h.lock().unwrap().clone())
            .unwrap_or_default();
        let report = SpecMetricsReport::build(
            spec_enabled,
            fallback_reason,
            dims,
            spec,
            spec_generated,
            spec_steps,
            spec_start.elapsed(),
            sidecar_metrics,
        );
        report.log_spec_stats();
        Some(report)
    } else {
        None
    };
    // #522: save the next reusable boundary (gated on a real assistant
    // turn — never on a cancelled/aborted/tool-call turn) and stash the
    // cache diagnostics for the `X-ChatAPC-Cache` response header.
    // `finalize` builds the boundary in its own context.
    let cache_header: Option<String> = if let (Some(plan), Some(mut diag)) =
        (cache_plan.as_ref(), cache_diag.take())
    {
        if matches!(outcome, Outcome::Natural | Outcome::MaxTokens) {
            prefix_cache::finalize(plan, &full_text, &model, &mut diag).await;
        }
        Some(serde_json::to_string(&diag).expect("CacheDiag must serialize"))
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
        usage: Usage::build(prompt_tokens, spec_generated, cached_tokens),
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
    if let Some(h) = &cache_header {
        builder = builder.header("X-ChatAPC-Cache", h.as_str());
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
    let Some(v) = tc else {
        return ForcedToolChoice::No;
    };
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
                Some(n) => {
                    format!("tool_choice names function '{n}' but it is not present in tools[]")
                }
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
/// Enforces the role policy at the callee (#468): an unknown role returns
/// `Err((code, message))` rather than being silently demoted to `user`.
/// Both user-reachable callers — `handle_parsed` (which also gates early
/// via `validate_roles`) and the tree-of-thought `tot::dispatch` — go
/// through here, so no caller can forget the check. The `code` is a role
/// policy code ([`is_role_error_code`]); callers map it to a 400.
pub(crate) fn fill_context(
    ctx: &mut Context,
    model: &Model,
    messages: &[ChatMessage],
    tools: Option<&[ToolSchema]>,
    cue: bool,
) -> Result<(), (&'static str, String)> {
    let tokens = build_prompt_tokens(model, messages, tools, cue)?;
    ctx.append(&tokens);
    Ok(())
}

/// Tokenize the same prompt [`fill_context`] would build, returning the raw
/// token sequence instead of mutating a context. The cross-request prefix
/// cache ([`super::prefix_cache`]) needs the exact token ids to
/// content-address snapshots; routing both `fill_context` and the cache
/// through this one function keeps the prefill bytes identical, which is
/// the invariant the snapshot keys depend on.
pub(crate) fn build_prompt_tokens(
    model: &Model,
    messages: &[ChatMessage],
    tools: Option<&[ToolSchema]>,
    cue: bool,
) -> Result<Vec<u32>, (&'static str, String)> {
    let mut out = Vec::new();
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
            out.extend_from_slice(&prefix);
        }
    }
    let mut tool_names_by_id = HashMap::<String, String>::new();
    for (i, msg) in messages.iter().enumerate() {
        match msg.role.as_str() {
            "system" => out.extend(chat::system(model, msg.content_str().unwrap_or(""))),
            "assistant" => {
                let content = assistant_replay_content(msg);
                out.extend(chat::assistant(model, &content));
                if let Some(calls) = tool_calls_array(msg) {
                    for call in calls {
                        let id = tool_call_id(call).expect("validated tool call id");
                        let name = tool_call_function_name(call)
                            .expect("validated tool call function name");
                        tool_names_by_id.insert(id.to_string(), name.to_string());
                    }
                }
            }
            "tool" => {
                let tool_call_id = msg
                    .tool_call_id
                    .as_ref()
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| {
                        ("invalid_tool_history", "tool message missing tool_call_id".to_string())
                    })?;
                let name = tool_names_by_id.get(tool_call_id).ok_or_else(|| {
                    (
                        "invalid_tool_history",
                        format!(
                            "tool_call_id '{tool_call_id}' has no matching assistant tool_call"
                        ),
                    )
                })?;
                out.extend(inferlet::tools::answer_prefix(
                    model,
                    name,
                    msg.content_str().unwrap_or(""),
                ));
            }
            // The first message of a fresh prompt must open the sequence with
            // the model's BOS (e.g. gemma's `<bos>`, llama3's
            // `<|begin_of_text|>`): `first_user` prepends it, plain `user` does
            // not. A preceding `system` turn already emits BOS, so branch on
            // whether anything has been buffered yet. Omitting BOS is benign
            // for BOS-agnostic templates (qwen/ChatML) but degenerates
            // BOS-sensitive ones (gemma4: no BOS → looping / channel salad).
            "user" => {
                let content = msg.content_str().unwrap_or("");
                if out.is_empty() {
                    out.extend(chat::first_user(model, content));
                } else {
                    out.extend(chat::user(model, content));
                }
            }
            // #468: reject any other role here rather than demoting it to
            // `user`. This is the root-cause guard — every caller goes
            // through `fill_context` / `build_prompt_tokens`, so the
            // tree-of-thought and prefix-cache paths can't bypass the
            // policy.
            other => {
                let code = role_error_code(other).unwrap_or("unsupported_role");
                return Err((code, role_error_message(i, other, code)));
            }
        }
    }
    // The trailing cue opens the assistant turn the generator fills.
    // Single-shot chat callers commit it with the prompt; tree-of-thought
    // defers it to each forked branch (so a freshly forked, fully-flushed
    // context still has tokens to process — an empty forward pass spins
    // the generator), so it is opt-out here.
    if cue {
        out.extend(chat::cue(model));
    }
    Ok(out)
}


fn assistant_replay_content(msg: &ChatMessage) -> String {
    let content = msg.content_str().unwrap_or("");
    match tool_calls_array(msg) {
        Some(calls) if !calls.is_empty() => {
            let rendered = render_assistant_tool_calls(calls);
            if content.is_empty() {
                rendered
            } else {
                format!("{content}\n{rendered}")
            }
        }
        _ => content.to_string(),
    }
}

fn render_assistant_tool_calls(calls: &[RequestToolCall]) -> String {
    calls
        .iter()
        .map(render_assistant_tool_call)
        .collect::<Vec<_>>()
        .join("\n")
}

fn render_assistant_tool_call(call: &RequestToolCall) -> String {
    let name = tool_call_function_name(call).expect("validated tool call function name");
    let raw_arguments = tool_call_function_arguments(call)
        .and_then(serde_json::Value::as_str)
        .expect("validated tool call arguments");
    let arguments = serde_json::from_str::<serde_json::Value>(raw_arguments)
        .unwrap_or_else(|_| serde_json::Value::String(raw_arguments.to_string()));
    format!(
        "<tool_call>\n{}\n</tool_call>",
        serde_json::json!({
            "name": name,
            "arguments": arguments,
        })
    )
}

fn validate_tool_replay_with<F>(
    messages: &[ChatMessage],
    parse_rendered: F,
) -> Result<(), MessageValidationError>
where
    F: Fn(&str) -> Option<(String, String)>,
{
    for (i, msg) in messages.iter().enumerate() {
        let Some(calls) = tool_calls_array(msg) else {
            continue;
        };
        for call in calls {
            let rendered = render_assistant_tool_call(call);
            let Some((parsed_name, parsed_args)) = parse_rendered(&rendered) else {
                return Err(MessageValidationError::new(
                    "tool_call_replay_unsupported",
                    "assistant tool_calls cannot be replayed with this model's native tool-call parser",
                    format!("messages[{i}].tool_calls"),
                ));
            };
            let expected_name = tool_call_function_name(call)
                .expect("validated tool call function name");
            let expected_args = tool_call_function_arguments(call)
                .and_then(serde_json::Value::as_str)
                .expect("validated tool call arguments");
            if parsed_name != expected_name || !same_json_arguments(&parsed_args, expected_args) {
                return Err(MessageValidationError::new(
                    "tool_call_replay_unsupported",
                    "assistant tool_calls do not round-trip through this model's native tool-call parser",
                    format!("messages[{i}].tool_calls"),
                ));
            }
        }
    }
    Ok(())
}

fn validate_tool_replay_for_model(
    messages: &[ChatMessage],
    model: &Model,
) -> Result<(), MessageValidationError> {
    validate_tool_replay_with(messages, |rendered| parse_rendered_tool_call(model, rendered))
}

fn same_json_arguments(left: &str, right: &str) -> bool {
    match (
        serde_json::from_str::<serde_json::Value>(left),
        serde_json::from_str::<serde_json::Value>(right),
    ) {
        (Ok(a), Ok(b)) => a == b,
        _ => left == right,
    }
}

fn parse_rendered_tool_call(model: &Model, rendered: &str) -> Option<(String, String)> {
    let tokens = model.tokenizer().encode(rendered);
    let mut decoder = inferlet::tools::Decoder::new(model);
    for token in tokens {
        match decoder.feed(&[token]).ok()? {
            inferlet::tools::Event::Call(name, arguments) => return Some((name, arguments)),
            inferlet::tools::Event::Start => {}
        }
    }
    None
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

    #[test]
    fn generation_metrics_frame_field_names_and_boundaries_are_stable() {
        assert!(GenerationMetricsSse::build(0, Duration::from_millis(500)).is_none());
        assert!(GenerationMetricsSse::build(3, Duration::ZERO).is_none());

        let frame = GenerationMetricsSse::build(21, Duration::from_millis(500))
            .expect("positive token count and elapsed time should emit metrics");
        let json = serde_json::to_value(frame).expect("generation metrics serialize");

        assert_eq!(json["event"].as_str(), Some("generation_metrics"));
        assert_eq!(json["output_tokens"].as_u64(), Some(21));
        assert_eq!(json["elapsed_s"].as_f64(), Some(0.5));
        assert_eq!(json["tokens_per_sec"].as_f64(), Some(42.0));
    }

    #[test]
    fn model_registration_error_reports_target_mismatch_for_wrong_resident_model() {
        let err = model_registration_error("selected", &["resident".to_string()])
            .expect("wrong model should produce a preflight error");

        assert_eq!(err.status, 409);
        assert_eq!(err.code, "target_mismatch");
        assert!(err.message.contains("selected"));
        assert!(err.message.contains("resident"));
        assert!(err.message.contains("/v1/models"));
    }

    #[test]
    fn model_registration_error_allows_the_resident_model() {
        assert!(model_registration_error("resident", &["resident".to_string()]).is_none());
    }

    // ─── Multi-part message content (#115) ─────────────────

    fn parse_message(json: &str) -> Result<ChatMessage, serde_json::Error> {
        serde_json::from_str(json)
    }

    #[test]
    fn content_plain_string_unchanged() {
        let m = parse_message(r#"{"role":"user","content":"hello"}"#).unwrap();
        assert_eq!(m.content.as_deref(), Some("hello"));
    }

    #[test]
    fn content_single_text_part_flattens() {
        let m = parse_message(r#"{"role":"user","content":[{"type":"text","text":"hello"}]}"#)
            .unwrap();
        assert_eq!(m.content.as_deref(), Some("hello"));
    }

    #[test]
    fn content_multiple_text_parts_concatenate_in_order() {
        let m = parse_message(
            r#"{"role":"user","content":[
                {"type":"text","text":"a"},
                {"type":"text","text":"b"},
                {"type":"text","text":"c"}
            ]}"#,
        )
        .unwrap();
        assert_eq!(m.content.as_deref(), Some("abc"));
    }

    #[test]
    fn content_empty_array_yields_empty_string() {
        // Flattens to "" — downstream the blank-content 400 gate in
        // `handle_parsed` rejects it, same as `content:""`.
        let m = parse_message(r#"{"role":"user","content":[]}"#).unwrap();
        assert_eq!(m.content.as_deref(), Some(""));
    }

    #[test]
    fn content_non_text_parts_contribute_nothing() {
        // image_url and other part types are accepted but textless.
        let m = parse_message(
            r#"{"role":"user","content":[
                {"type":"image_url","image_url":{"url":"http://x/y.png"}},
                {"type":"text","text":"caption"}
            ]}"#,
        )
        .unwrap();
        assert_eq!(m.content.as_deref(), Some("caption"));
    }

    #[test]
    fn content_part_with_null_text_is_skipped() {
        let m = parse_message(
            r#"{"role":"user","content":[{"type":"text","text":null},{"type":"text","text":"x"}]}"#,
        )
        .unwrap();
        assert_eq!(m.content.as_deref(), Some("x"));
    }

    #[test]
    fn content_rejects_non_string_non_array() {
        assert!(parse_message(r#"{"role":"user","content":42}"#).is_err());
        assert!(parse_message(r#"{"role":"user","content":{"text":"x"}}"#).is_err());
        let m = parse_message(r#"{"role":"user","content":null}"#).unwrap();
        assert_eq!(m.content, None);
    }

    #[test]
    fn content_rejects_array_with_non_object_part() {
        // One malformed part poisons the whole array → 400 at the
        // request boundary, never a silently dropped part.
        assert!(parse_message(r#"{"role":"user","content":["bare string"]}"#).is_err());
        assert!(
            parse_message(r#"{"role":"user","content":[{"type":"text","text":"ok"}, 7]}"#)
                .is_err()
        );
    }

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
        assert!(!forward_pass_starved(&[
            SlotOutput::Token(5),
            SlotOutput::Token(6)
        ]));
    }

    #[test]
    fn not_starved_when_token_leads_non_token_slots() {
        // A decode step with the auto-sampler at slot 0 plus probe slots:
        // the leading Token means the engine produced a pick.
        assert!(!forward_pass_starved(&[
            SlotOutput::Token(5),
            SlotOutput::Entropy(0.5)
        ]));
    }

    #[test]
    fn starved_when_slots_carry_no_token() {
        // Probe-only output with no sampled token still counts as
        // starvation for a decode step (the loop always attaches the
        // auto-sampler, so a missing Token slot is the host producing none).
        assert!(forward_pass_starved(&[SlotOutput::Entropy(0.5)]));
    }

    // ─── Over-capacity backpressure classification (#470) ──

    #[test]
    fn server_busy_sentinel_classifies_as_server_busy() {
        // The host wraps the acquisition-timeout message; the SDK then
        // prefixes its own context ("GenStep::execute reserve: ..."). The
        // sentinel survives both wraps as a substring.
        let host = "server_busy: KV page acquisition timed out after 120s; \
                    engine is over capacity";
        let sdk_wrapped = format!("GenStep::execute reserve: {host}");
        assert_eq!(classify_forward_error(host), SERVER_BUSY_CODE);
        assert_eq!(classify_forward_error(&sdk_wrapped), SERVER_BUSY_CODE);
    }

    #[test]
    fn generic_forward_error_classifies_as_forward_pass_failed() {
        assert_eq!(
            classify_forward_error("device RPC returned an error"),
            "forward_pass_failed"
        );
        assert_eq!(classify_forward_error(""), "forward_pass_failed");
    }

    #[test]
    fn bare_server_busy_token_in_device_error_is_not_backpressure() {
        // The host's contract is the colon-suffixed `server_busy:` prefix.
        // A verbatim device/driver error that merely contains the bare token
        // `server_busy` (no colon) must stay a fatal `forward_pass_failed`,
        // not get mislabeled as retryable backpressure (a 503 a client would
        // retry forever against a genuinely dead engine).
        let device_err =
            "GenStep::execute forward: driver reported server_busy flag set on dead queue";
        assert_eq!(classify_forward_error(device_err), "forward_pass_failed");
    }

    // ─── Reasoning/content channel demux ──────────────────

    /// Reasoning-decoder event kind for one generation step, paired with
    /// the chat decoder's text for the same token batch. Models what the
    /// host decoders return without the wasm host.
    enum Step {
        ThinkStart(&'static str), // reasoning Start; chat surfaces the `<think>` text
        Reason(&'static str),     // reasoning Delta; chat surfaces the same text
        // reasoning End/Complete. `.0` is the decoder's FULL accumulated
        // reasoning text for the block (what `End(s)` carries); `.1` is the
        // chat `</think>` delimiter surfaced on the suppressed chat channel.
        // A multi-token speculative batch that contains reasoning text AND
        // the boundary arrives as a single `End(s)` with no prior `Delta`,
        // so `.0` can be longer than the streamed `Reason` deltas.
        ThinkEnd(&'static str, &'static str),
        Content(&'static str), // reasoning Idle (outside); chat surfaces visible content
    }

    /// Replays the generation loop's reasoning/content demux as
    /// `handle_streaming` / `handle_non_streaming` do: capture
    /// `was_in_reasoning`, feed reasoning (updating `in_reasoning` /
    /// `reason_idle` / `reason_ended` + the `End(s)` reasoning recovery), then
    /// route the chat delta through the SAME production `visible_content` the
    /// real loops call — so this exercises the real demux decision, not a
    /// reimplementation. Returns `(visible_content, reasoning)`.
    fn demux(steps: &[Step]) -> (String, String) {
        let mut content = String::new();
        let mut reasoning = String::new();
        let mut in_reasoning = false;
        for step in steps {
            let was_in_reasoning = in_reasoning;
            let mut reason_idle = false;
            let mut reason_ended = false;
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
                Step::ThinkEnd(end_s, close) => {
                    in_reasoning = false;
                    reason_ended = true;
                    // Mirror the production End arm: recover reasoning text
                    // that arrived in the SAME batch as the boundary by
                    // appending only the un-streamed suffix; fall back to
                    // trusting the streamed deltas if `End(s)` disagrees.
                    if let Some(residual) = end_s.strip_prefix(reasoning.as_str()) {
                        reasoning.push_str(residual);
                    }
                    *close
                }
                Step::Content(t) => {
                    reason_idle = true;
                    *t
                }
            };
            // Route through the real production demux unit (no `forced_tool` in
            // these scenarios). The `</think>` straddle recovery (#600) lives in
            // `visible_content`, so this harness fails if that recovery breaks.
            content.push_str(visible_content(
                chat_text,
                reason_idle,
                was_in_reasoning,
                reason_ended,
                false,
            ));
        }
        (content, reasoning)
    }

    #[test]
    fn think_delimiters_never_leak_into_visible_content() {
        // A canonical Qwen reasoning turn: <think> reasoning </think> answer.
        // End(s) carries the full accumulated reasoning, already streamed
        // via the Reason delta, so the End residual is empty.
        let (content, reasoning) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("the user said hi"),
            Step::ThinkEnd("the user said hi", "</think>"),
            Step::Content("Hello!"),
        ]);
        assert_eq!(content, "Hello!", "only the answer reaches visible content");
        assert_eq!(reasoning, "the user said hi");
        // The specific symptom: the CLOSING tag must not leak.
        assert!(
            !content.contains("</think>"),
            "closing delimiter leaked: {content:?}"
        );
        assert!(
            !content.contains("<think>"),
            "opening delimiter leaked: {content:?}"
        );
    }

    #[test]
    fn reasoning_in_same_batch_as_close_is_not_dropped() {
        // Speculative regression (#466): a warmed n-gram cache can make the
        // engine accept the reasoning token(s) AND the closing boundary in a
        // single multi-token batch. The reasoning decoder then fires only
        // `End(s)` (one event per feed) with no prior `Delta`, so trusting
        // the streamed deltas alone drops the reasoning text. The empty
        // `/no_think` block (`<think>\n\n</think>`) is the minimal trigger.
        let (content, reasoning) = demux(&[
            Step::ThinkStart("<think>"),
            // No Reason delta: the `\n\n` and the close arrive together, so
            // the decoder reports the reasoning only inside End(s).
            Step::ThinkEnd("\n\n", "</think>"),
            Step::Content("\n\nred blue green"),
        ]);
        assert_eq!(
            reasoning, "\n\n",
            "same-batch reasoning text must survive the close boundary"
        );
        assert_eq!(content, "\n\nred blue green");
    }

    #[test]
    fn partial_streamed_reasoning_recovers_only_the_unstreamed_suffix() {
        // The last reasoning token shares the batch with the close: part of
        // the reasoning streamed via Delta, the rest rides End(s). Only the
        // un-streamed suffix is appended — no duplication of the streamed
        // prefix, and the dropped tail is recovered.
        let (_content, reasoning) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("the user "),
            Step::ThinkEnd("the user said hi", "</think>"),
            Step::Content("answer"),
        ]);
        assert_eq!(reasoning, "the user said hi");
    }

    #[test]
    fn end_payload_disagreeing_with_streamed_deltas_is_discarded() {
        // F5 invariant: if End(s) is NOT a clean superset of the streamed
        // deltas (detokenization re-segmentation), trust the deltas so
        // stream and non-stream stay byte-identical.
        let (_content, reasoning) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("the user said hi"),
            Step::ThinkEnd("DIFFERENT accumulated text", "</think>"),
            Step::Content("answer"),
        ]);
        assert_eq!(reasoning, "the user said hi");
    }

    #[test]
    fn answer_in_same_batch_as_close_is_not_dropped() {
        // #600: the content sibling of `reasoning_in_same_batch_as_close...`.
        // Under speculative decode the `</think>` close and the first answer
        // tokens land in ONE batch, so the chat decoder surfaces a combined
        // `</think>answer-head` on the close step. `content_visible` is false
        // there (End ≠ Idle), so without recovery the answer is dropped and the
        // turn persists empty content.
        let (content, reasoning) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("user wants the capital of France"),
            // Whole tail of the turn rides one speculative burst.
            Step::ThinkEnd(
                "user wants the capital of France",
                "</think>\n\nThe capital of France is **Paris**.",
            ),
        ]);
        assert_eq!(
            content, "The capital of France is **Paris**.",
            "answer-head riding the close batch must reach visible content"
        );
        assert_eq!(reasoning, "user wants the capital of France");
        assert!(
            !content.contains("</think>"),
            "closing delimiter leaked: {content:?}"
        );
    }

    #[test]
    fn straddle_answer_head_then_streams_rest() {
        // The close batch carries the answer-head; later batches stream the
        // rest as ordinary visible content. Both concatenate into the reply.
        let (content, _r) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("thinking"),
            Step::ThinkEnd("thinking", "</think>Paris"),
            Step::Content(" is the capital."),
        ]);
        assert_eq!(content, "Paris is the capital.");
    }

    #[test]
    fn plain_decode_close_batch_emits_no_content() {
        // Plain (non-speculative) decode: `</think>` is its own batch and the
        // answer arrives on the next. The bare-delimiter close must suppress
        // (no leak) and recover nothing — the answer streams via the next
        // batch, so there is no double-emit.
        let (content, _r) = demux(&[
            Step::ThinkStart("<think>"),
            Step::Reason("thinking"),
            Step::ThinkEnd("thinking", "</think>"),
            Step::Content("Paris"),
        ]);
        assert_eq!(content, "Paris");
    }

    #[test]
    fn answer_after_close_extracts_post_delimiter_text() {
        assert_eq!(answer_after_close("</think>Paris"), Some("Paris"));
        assert_eq!(
            answer_after_close("reasoning tail</think>\n\nParis"),
            Some("Paris")
        );
        // Bare delimiter (plain decode close batch) → nothing to recover.
        assert_eq!(answer_after_close("</think>"), None);
        assert_eq!(answer_after_close("</think>\n\n"), None);
        // No close delimiter → None (not a close-batch shape).
        assert_eq!(answer_after_close("just content"), None);
        // Split on the FIRST close, so an answer mentioning the tag stays whole.
        assert_eq!(
            answer_after_close("</think>see </think> below"),
            Some("see </think> below")
        );
    }

    #[test]
    fn visible_content_demuxes_every_batch_shape() {
        // This is the exact decision the real `handle_streaming` /
        // `handle_non_streaming` loops run per chat Delta.
        // Outside reasoning (reason Idle) → whole delta is content.
        assert_eq!(visible_content("answer", true, false, false, false), "answer");
        // Inside reasoning (Start/Delta batch) → suppressed.
        assert_eq!(visible_content("reasoning", false, false, false, false), "");
        // No-visible-text reasoning token (Idle while inside) → suppressed.
        assert_eq!(visible_content("", true, true, false, false), "");
        // Close batch, plain decode (bare delimiter) → nothing recovered.
        assert_eq!(visible_content("</think>", false, true, true, false), "");
        // #600 straddle: `</think>` + answer-head in ONE batch → recover answer.
        assert_eq!(
            visible_content("</think>\n\nParis", false, true, true, false),
            "Paris"
        );
        // Straddle with a reasoning tail ahead of the close → still just answer.
        assert_eq!(
            visible_content("tail</think>Paris", false, true, true, false),
            "Paris"
        );
        // forced_tool suppresses on EVERY shape (content rides tool_calls only).
        assert_eq!(visible_content("answer", true, false, false, true), "");
        assert_eq!(
            visible_content("</think>Paris", false, true, true, true),
            ""
        );
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
        let (content, reasoning) = demux(&[Step::Content("Plain "), Step::Content("answer.")]);
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
    fn speculation_parses_optional_sidecar_identity() {
        let r: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "temperature":0,
                "speculation":{"enabled":true,
                               "thread_id":"chat-1",
                               "profile_id":"fast-think"}}"#,
        )
        .unwrap();
        let s = r.speculation.expect("speculation present");
        assert_eq!(s.thread_id.as_deref(), Some("chat-1"));
        assert_eq!(s.profile_id.as_deref(), Some("fast-think"));
    }

    #[test]
    fn chat_completions_accepts_advanced_dispatch_envelope() {
        let r: ChatCompletionsRequest = serde_json::from_str(
            r#"{
                "inferlet":"tree-of-thought",
                "stream":true,
                "input":{
                    "model":"m",
                    "messages":[{"role":"user","content":"hi"}],
                    "breadth":2,
                    "depth":1,
                    "beam_width":1,
                    "max_tokens_per_node":16
                }
            }"#,
        )
        .expect("advanced profile dispatch should parse on /v1/chat/completions");
        assert_eq!(r.inferlet.as_deref(), Some("tree-of-thought"));
        assert!(r.stream);
        assert!(r.input.is_some());
        assert!(r.model.is_empty(), "dispatch envelope need not duplicate input.model");
        assert!(r.messages.is_empty(), "dispatch envelope carries messages inside input");
    }

    #[test]
    fn spec_metrics_reports_sidecar_reuse_state() {
        let report = SpecMetricsReport::build(
            true,
            None,
            (1, 3),
            SpecMetrics {
                proposed: 6,
                accepted: 4,
                rejected: 2,
                steps: 2,
                generated: 6,
                cache_hits: 0,
                cache_misses: 0,
                cache_size: 0,
                accepted_prefix_hist: Vec::new(),
            },
            6,
            2,
            Duration::from_secs(1),
            Some(SidecarMetrics {
                status: SidecarMetricStatus::Reused,
                ngram_leaders: 42,
                expired: 1,
            }),
        );
        let json = serde_json::to_value(&report).expect("metrics serialize");
        assert_eq!(json["ngram_sidecar_status"], "reused");
        assert_eq!(json["ngram_sidecar_leaders"], 42);
        assert_eq!(json["ngram_sidecars_expired"], 1);
    }

    #[test]
    fn spec_metrics_reports_sidecar_non_reuse_reasons() {
        for (status, expected) in [
            (SidecarMetricStatus::DecodeFailed, "decode_failed"),
            (SidecarMetricStatus::LineageForked, "lineage_forked"),
        ] {
            let report = SpecMetricsReport::build(
                true,
                None,
                (1, 3),
                SpecMetrics::default(),
                0,
                0,
                Duration::from_secs(1),
                Some(SidecarMetrics {
                    status,
                    ngram_leaders: 0,
                    expired: 0,
                }),
            );
            let json = serde_json::to_value(&report).expect("metrics serialize");
            assert_eq!(json["ngram_sidecar_status"], expected);
        }
    }

    #[test]
    fn absent_speculation_is_none() {
        let r: ChatCompletionsRequest =
            serde_json::from_str(r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#)
                .unwrap();
        assert!(r.speculation.is_none());
    }

    #[test]
    fn openai_assistant_tool_call_history_accepts_null_content() {
        let r: ChatCompletionsRequest = serde_json::from_str(
            r#"{
                "model":"m",
                "messages":[
                    {"role":"user","content":"What is 2+2?"},
                    {
                        "role":"assistant",
                        "content":null,
                        "tool_calls":[{
                            "id":"call_calc",
                            "type":"function",
                            "function":{"name":"calculator","arguments":"{\"expr\":\"2+2\"}"}
                        }]
                    },
                    {"role":"tool","tool_call_id":"call_calc","content":"4"}
                ]
            }"#,
        )
        .expect("OpenAI SDK tool-call continuation history should parse");
        assert_eq!(r.messages.len(), 3);
    }

    fn parsed_messages(json: &str) -> Vec<ChatMessage> {
        serde_json::from_str::<ChatCompletionsRequest>(json)
            .expect("request should deserialize")
            .messages
    }

    #[test]
    fn openai_tool_result_sequence_validates_linkage() {
        let messages = parsed_messages(
            r#"{
                "model":"m",
                "messages":[
                    {"role":"user","content":"What is 2+2?"},
                    {
                        "role":"assistant",
                        "content":"",
                        "tool_calls":[{
                            "id":"call_calc",
                            "type":"function",
                            "function":{"name":"calculator","arguments":"{\"expr\":\"2+2\"}"}
                        }]
                    },
                    {"role":"tool","tool_call_id":"call_calc","content":"4"}
                ]
            }"#,
        );

        validate_messages(&messages).expect("assistant tool_calls followed by matching tool result should validate");
    }

    #[test]
    fn tool_message_without_matching_assistant_call_is_rejected_with_param() {
        let messages = parsed_messages(
            r#"{
                "model":"m",
                "messages":[
                    {"role":"user","content":"What is 2+2?"},
                    {"role":"tool","tool_call_id":"call_missing","content":"4"}
                ]
            }"#,
        );

        let err = validate_messages(&messages).expect_err("orphan tool result should fail");
        assert_eq!(err.code, "unknown_tool_call_id");
        assert_eq!(err.param, "messages[1].tool_call_id");
    }

    #[test]
    fn duplicate_assistant_tool_call_ids_are_rejected_with_param() {
        let messages = parsed_messages(
            r#"{
                "model":"m",
                "messages":[
                    {"role":"user","content":"call twice"},
                    {
                        "role":"assistant",
                        "content":null,
                        "tool_calls":[
                            {"id":"call_dup","type":"function","function":{"name":"a","arguments":"{}"}},
                            {"id":"call_dup","type":"function","function":{"name":"b","arguments":"{}"}}
                        ]
                    }
                ]
            }"#,
        );

        let err = validate_messages(&messages).expect_err("duplicate ids should fail");
        assert_eq!(err.code, "duplicate_tool_call_id");
        assert_eq!(err.param, "messages[1].tool_calls[1].id");
    }

    #[test]
    fn malformed_tool_continuation_sequences_report_specific_params() {
        let cases = [
            (
                r#"{"model":"m","messages":[
                    {"role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":"calculator","arguments":"{}"}}
                    ]},
                    {"role":"tool","content":"4"}
                ]}"#,
                "missing_tool_call_id",
                "messages[1].tool_call_id",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"type":"function","function":{"name":"calculator","arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].id",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","function":{"name":"calculator","arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].type",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function"}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].function",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].function.name",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":"calculator"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].function.arguments",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":"calculator","arguments":{}}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].function.arguments",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":123,"type":"function","function":{"name":"calculator","arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].id",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":7,"function":{"name":"calculator","arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].type",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":[]}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].function",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":{},"arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls[0].function.name",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"user","content":"hi","tool_call_id":"call_x"
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_call_id",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":"hi","tool_call_id":"call_x"
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_call_id",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"future","content":"hi","tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":"calculator","arguments":"{}"}}
                    ]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"user","content":"hi","tool_call_id":123
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_call_id",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":{}
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[null]
                }]}"#,
                "malformed_tool_calls",
                "messages[0].tool_calls",
            ),
            (
                r#"{"model":"m","messages":[
                    {"role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":"calculator","arguments":"{}"}}
                    ]},
                    {"role":"user","content":"interrupt"},
                    {"role":"tool","tool_call_id":"call_x","content":"4"}
                ]}"#,
                "invalid_tool_order",
                "messages[1].role",
            ),
            (
                r#"{"model":"m","messages":[{
                    "role":"assistant","content":null,"tool_calls":[
                        {"id":"call_x","type":"function","function":{"name":"calculator","arguments":"{}"}}
                    ]
                }]}"#,
                "missing_tool_result",
                "messages",
            ),
        ];

        for (json, code, param) in cases {
            let messages = parsed_messages(json);
            let err = validate_messages(&messages).expect_err(json);
            assert_eq!(err.code, code, "{json}");
            assert_eq!(err.param, param, "{json}");
        }
    }

    #[test]
    fn tool_results_must_follow_assistant_declared_order() {
        let messages = parsed_messages(
            r#"{
                "model":"m",
                "messages":[
                    {"role":"assistant","content":null,"tool_calls":[
                        {"id":"call_a","type":"function","function":{"name":"calculator","arguments":"{\"expr\":\"2+2\"}"}},
                        {"id":"call_b","type":"function","function":{"name":"calculator","arguments":"{\"expr\":\"3+3\"}"}}
                    ]},
                    {"role":"tool","tool_call_id":"call_b","content":"6"},
                    {"role":"tool","tool_call_id":"call_a","content":"4"}
                ]
            }"#,
        );

        let err = validate_messages(&messages).expect_err("out-of-order tool results should fail");
        assert_eq!(err.code, "invalid_tool_order");
        assert_eq!(err.param, "messages[1].tool_call_id");
    }

    #[test]
    fn assistant_tool_replay_requires_native_parser_confirmation() {
        let messages = parsed_messages(
            r#"{
                "model":"m",
                "messages":[{
                    "role":"assistant",
                    "content":null,
                    "tool_calls":[{
                        "id":"call_calc",
                        "type":"function",
                        "function":{"name":"calculator","arguments":"{\"expr\":\"2+2\"}"}
                    }]
                }]
            }"#,
        );

        let err = validate_tool_replay_with(&messages, |_rendered| None)
            .expect_err("unsupported native replay should fail closed");
        assert_eq!(err.code, "tool_call_replay_unsupported");
        assert_eq!(err.param, "messages[0].tool_calls");
    }

    #[test]
    fn assistant_tool_calls_replay_as_native_tool_call_payload() {
        let messages = parsed_messages(
            r#"{
                "model":"m",
                "messages":[{
                    "role":"assistant",
                    "content":null,
                    "tool_calls":[{
                        "id":"call_calc",
                        "type":"function",
                        "function":{"name":"calculator","arguments":"{\"expr\":\"2+2\"}"}
                    }]
                }]
            }"#,
        );
        let rendered = render_assistant_tool_calls(tool_calls_array(&messages[0]).unwrap());

        assert!(rendered.contains("<tool_call>"), "{rendered}");
        assert!(rendered.contains("</tool_call>"), "{rendered}");
        assert!(rendered.contains("\"name\":\"calculator\""), "{rendered}");
        assert!(rendered.contains("\"arguments\":{\"expr\":\"2+2\"}"), "{rendered}");
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

    fn test_msg(role: &str, content: &str) -> ChatMessage {
        ChatMessage {
            role: role.into(),
            content: Some(content.into()),
            tool_call_id: None,
            tool_calls: None,
        }
    }

    #[test]
    fn validate_roles_accepts_supported_set() {
        let msgs = vec![
            test_msg("system", "s"),
            test_msg("user", "u"),
            test_msg("assistant", "a"),
            test_msg("user", "u2"),
        ];
        assert!(validate_roles(&msgs).is_ok());
    }

    #[test]
    fn validate_roles_accepts_tool_role_for_valid_continuations() {
        let msgs = vec![test_msg("tool", "t")];
        assert!(validate_roles(&msgs).is_ok());
    }

    #[test]
    fn validate_roles_rejects_unknown_role() {
        // #468: a typo'd / unsupported role is a 400, not a silent
        // demotion to `user` that generates a mis-templated completion.
        for role in ["banana", "developer", "function", "User", ""] {
            let msgs = vec![test_msg(role, "c")];
            let (i, code, msg) = validate_roles(&msgs).unwrap_err();
            assert_eq!(i, 0, "role={role:?}");
            assert_eq!(code, "unsupported_role", "role={role:?}");
            assert!(msg.contains("messages[0].role"), "role={role:?}: {msg}");
        }
    }

    #[test]
    fn is_role_error_code_splits_client_from_internal() {
        // Role-policy codes are client errors (400); internal failures
        // (e.g. tool_equip_failed) are not — the tot::dispatch status
        // split (400 vs 500) keys on this.
        assert!(is_role_error_code("unsupported_role"));
        assert!(is_role_error_code("tool_role_unsupported"));
        assert!(!is_role_error_code("tool_equip_failed"));
    }

    #[test]
    fn validate_roles_reports_first_offending_index() {
        let msgs = vec![
            test_msg("user", "u"),
            test_msg("assistant", "a"),
            test_msg("banana", "b"),
        ];
        let (i, _code, _msg) = validate_roles(&msgs).unwrap_err();
        assert_eq!(i, 2);
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
    fn max_completion_tokens_is_max_tokens_fallback() {
        // OpenAI/Codex-style clients send `max_completion_tokens` and omit
        // `max_tokens`. The effective budget must come from the alias
        // rather than silently collapsing to DEFAULT_MAX_TOKENS.
        let req: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "max_completion_tokens":2048}"#,
        )
        .unwrap();
        assert_eq!(validate_sampling(&req, 8192).unwrap(), 2048);
        // Still range-checked against the runtime ceiling like `max_tokens`.
        assert_eq!(validate_sampling(&req, 1024).unwrap_err().0, "max_tokens");

        // When both are present, `max_tokens` wins (the alias is only a
        // fallback for its absence).
        let both: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "max_tokens":256,"max_completion_tokens":2048}"#,
        )
        .unwrap();
        assert_eq!(validate_sampling(&both, 8192).unwrap(), 256);
    }

    #[test]
    fn usage_block_shape_and_totals() {
        // `total_tokens` is the sum of prompt + completion, and
        // `cached_tokens` nests under `prompt_tokens_details` exactly like
        // OpenAI's prompt-caching shape.
        let usage = Usage::build(100, 40, 30);
        assert_eq!(usage.total_tokens, 140);
        let v = serde_json::to_value(&usage).unwrap();
        assert_eq!(v["prompt_tokens"], 100);
        assert_eq!(v["completion_tokens"], 40);
        assert_eq!(v["total_tokens"], 140);
        assert_eq!(v["prompt_tokens_details"]["cached_tokens"], 30);
    }

    #[test]
    fn stream_options_include_usage_parses_and_defaults_off() {
        // Opt-in flag round-trips; absence of `stream_options` leaves the
        // stream byte-identical (no usage chunk emitted).
        let on: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "stream":true,"stream_options":{"include_usage":true}}"#,
        )
        .unwrap();
        assert!(on.stream_options.as_ref().is_some_and(|o| o.include_usage));

        let off: ChatCompletionsRequest = serde_json::from_str(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true}"#,
        )
        .unwrap();
        assert!(off.stream_options.is_none());
    }

    #[test]
    fn plan_strategy_gates_on_greedy_and_enabled() {
        // requested + greedy + no forced tool + no json -> speculative, no fallback
        let s = SpecRequest {
            enabled: true,
            leader_len: None,
            draft_len: None,
            thread_id: None,
            profile_id: None,
        };
        let (st, fb, want, _) = plan_strategy(Some(&s), true, false, false);
        assert!(matches!(st, DecodeStrategy::Speculative(_)));
        assert!(fb.is_none());
        assert!(want);
        // requested + non-greedy -> plain, fallback reason
        let (st, fb, want, _) = plan_strategy(Some(&s), false, false, false);
        assert!(matches!(st, DecodeStrategy::Plain));
        assert_eq!(fb, Some("non_greedy_sampling"));
        assert!(want);
        // requested + greedy BUT a tool call is forced -> plain, gated off
        // with a distinct reason (checked before the greedy gate).
        let (st, fb, want, _) = plan_strategy(Some(&s), true, true, false);
        assert!(matches!(st, DecodeStrategy::Plain));
        assert_eq!(fb, Some("tool_choice_forced"));
        assert!(want);
        // enabled:false -> plain, disabled
        let off = SpecRequest {
            enabled: false,
            leader_len: None,
            draft_len: None,
            thread_id: None,
            profile_id: None,
        };
        let (_, fb, want, _) = plan_strategy(Some(&off), true, false, false);
        assert_eq!(fb, Some("disabled"));
        assert!(want);
        // absent -> plain, no metrics surface
        let (_, fb, want, _) = plan_strategy(None, true, false, false);
        assert!(fb.is_none());
        assert!(!want);
    }

    #[test]
    fn plan_strategy_json_mode_gates_speculation_off() {
        // #572: JSON mode runs a grammar-constrained sampler, so the
        // drafter must not engage even when requested + greedy. The
        // fallback reason names the JSON gate, distinct from the
        // tool-choice gate, and is checked first.
        let s = SpecRequest {
            enabled: true,
            leader_len: None,
            draft_len: None,
            thread_id: None,
            profile_id: None,
        };
        let (st, fb, want, _) = plan_strategy(Some(&s), true, false, true);
        assert!(matches!(st, DecodeStrategy::Plain));
        assert_eq!(fb, Some("json_constrained"));
        assert!(want, "a requested-but-inactive run still surfaces metrics");
        // json_mode wins the precedence even if forced_tool were somehow
        // also set (they are 400-rejected upstream, but the gate is
        // defensive): the reported reason is `json_constrained`.
        let (_, fb, _, _) = plan_strategy(Some(&s), true, true, true);
        assert_eq!(fb, Some("json_constrained"));
    }

    // ─── response_format (#572) ───────────────────────────────

    fn req_with_response_format(body: &str) -> ChatCompletionsRequest {
        serde_json::from_str(body).expect("valid request JSON")
    }

    #[test]
    fn json_mode_detected_for_object_and_schema() {
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_object"}}"#,
        );
        assert!(json_mode(&r));

        // #619: json_schema is also a constrained mode.
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema",
                "json_schema":{"schema":{"type":"object"}}}}"#,
        );
        assert!(json_mode(&r));

        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"text"}}"#,
        );
        assert!(!json_mode(&r));

        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
        );
        assert!(!json_mode(&r), "absent response_format is not JSON mode");
        assert!(r.response_format.is_none());
    }

    #[test]
    fn json_constraint_schema_maps_each_mode() {
        // #619: json_object → object-root schema, never a bare scalar.
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_object"}}"#,
        );
        assert_eq!(
            json_constraint_schema(&r).as_deref(),
            Some(JSON_OBJECT_ROOT_SCHEMA)
        );

        // json_schema → the caller's schema, serialized.
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema",
                "json_schema":{"name":"answer",
                "schema":{"type":"object","properties":{"answer":{"type":"string"}}}}}}"#,
        );
        let schema = json_constraint_schema(&r).expect("json_schema yields a schema");
        let parsed: serde_json::Value = serde_json::from_str(&schema).unwrap();
        assert_eq!(parsed["type"], "object");
        assert_eq!(parsed["properties"]["answer"]["type"], "string");

        // text / absent → no constraint schema.
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"text"}}"#,
        );
        assert!(json_constraint_schema(&r).is_none());
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
        );
        assert!(json_constraint_schema(&r).is_none());
    }

    #[test]
    fn json_object_root_schema_forbids_bare_scalar() {
        // #619 contract: the object-root schema is a JSON object whose
        // type is "object" with additionalProperties allowed — so a bare
        // scalar (the bug) cannot satisfy the compiled grammar, while
        // arbitrary object contents still can.
        let v: serde_json::Value = serde_json::from_str(JSON_OBJECT_ROOT_SCHEMA).unwrap();
        assert_eq!(v["type"], "object");
        assert_eq!(v["additionalProperties"], true);
    }

    #[test]
    fn validate_response_format_accepts_supported_and_default() {
        // absent -> ok
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
        );
        assert!(validate_response_format(&r).is_ok());
        // text -> ok (explicit no-op)
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"text"}}"#,
        );
        assert!(validate_response_format(&r).is_ok());
        // json_object -> ok
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_object"}}"#,
        );
        assert!(validate_response_format(&r).is_ok());
        // #619: json_schema with a schema -> ok
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema",
                "json_schema":{"schema":{"type":"object"}}}}"#,
        );
        assert!(validate_response_format(&r).is_ok());
    }

    #[test]
    fn validate_response_format_rejects_json_schema_without_object_root() {
        // #619 F1: json_schema is accepted only when schema is a JSON object
        // with "type":"object". Anything that does NOT pin an object root
        // would compile to an accept-everything grammar (a bare scalar
        // satisfies it) — the exact hole #619 closes — so it is a 400
        // invalid_request.
        let reject = |body: &str| {
            let r = req_with_response_format(body);
            let (code, _msg, param) = validate_response_format(&r).unwrap_err();
            assert_eq!(code, "invalid_request", "body={body}");
            assert_eq!(param, "response_format", "body={body}");
        };

        // missing schema member entirely
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema"}}"#,
        );
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"name":"x"}}}"#,
        );
        // empty object schema -> non-constraining (visit_any), no object root
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{}}}}"#,
        );
        // null schema
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":null}}}"#,
        );
        // schema with keywords but no object root (type defaults to any)
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"description":"x"}}}}"#,
        );
        // scalar / array roots
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"string"}}}}"#,
        );
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"array"}}}}"#,
        );

        // #619 review F1: composition/literal keywords win over type:object
        // in the host compiler, so they reopen the bare-scalar hole and must
        // be rejected even alongside "type":"object".
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"object","enum":["a","b"]}}}}"#,
        );
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"object","oneOf":[{"type":"string"}]}}}}"#,
        );
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"object","anyOf":[{"type":"number"}]}}}}"#,
        );
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"object","const":"hi"}}}}"#,
        );
        reject(
            r##"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"object","$ref":"#/$defs/x"}}}}"##,
        );
        // #619 review v3 F1: a union mixing object with a non-`null` scalar
        // admits a bare string -> rejected (the ["object","null"] accept
        // below is the deliberate exception).
        reject(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":["object","string"]}}}}"#,
        );

        // object root -> accepted
        let accept = |body: &str| {
            let r = req_with_response_format(body);
            assert!(validate_response_format(&r).is_ok(), "body={body}");
        };
        accept(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema",
                "json_schema":{"schema":{"type":"object",
                "properties":{"answer":{"type":"string"}}}}}}"#,
        );
        // #619 review F2: array type containing object (nullable object) and
        // a typeless schema inferred as object from `properties` both route
        // to an object grammar in the compiler, so both are accepted.
        // review v3 F1 (deliberate): ["object","null"] is honored because the
        // caller explicitly opted into a `null` answer — null is the ONLY
        // non-object scalar permitted; ["object","string"] above stays
        // rejected, and json_object mode is never nullable.
        accept(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"type":["object","null"]}}}}"#,
        );
        accept(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema","json_schema":{"schema":{"properties":{"answer":{"type":"string"}}}}}}"#,
        );
    }

    #[test]
    fn validate_response_format_rejects_unknown_type() {
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"banana"}}"#,
        );
        let (code, _msg, param) = validate_response_format(&r).unwrap_err();
        assert_eq!(code, "response_format_unsupported");
        assert_eq!(param, "response_format");
    }

    #[test]
    fn validate_response_format_rejects_json_plus_forced_tool() {
        // json_object + tool_choice:"required" -> 400 invalid_request
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_object"},
                "tool_choice":"required",
                "tools":[{"type":"function","function":{"name":"f","parameters":{}}}]}"#,
        );
        let (code, _msg, param) = validate_response_format(&r).unwrap_err();
        assert_eq!(code, "invalid_request");
        assert_eq!(param, "response_format");

        // json_object + tool_choice:{named} -> rejected too
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_object"},
                "tool_choice":{"type":"function","function":{"name":"f"}}}"#,
        );
        assert_eq!(validate_response_format(&r).unwrap_err().0, "invalid_request");

        // json_object + tool_choice:"auto" -> NOT forced, so allowed
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_object"},
                "tool_choice":"auto"}"#,
        );
        assert!(validate_response_format(&r).is_ok());

        // #619: json_schema + forced tool_choice -> rejected the same way
        let r = req_with_response_format(
            r#"{"model":"m","messages":[{"role":"user","content":"hi"}],
                "response_format":{"type":"json_schema",
                "json_schema":{"schema":{"type":"object"}}},
                "tool_choice":"required",
                "tools":[{"type":"function","function":{"name":"f","parameters":{}}}]}"#,
        );
        assert_eq!(validate_response_format(&r).unwrap_err().0, "invalid_request");
    }

    // ─── two-phase JSON decode contract (#572 F1/F2/F3) ──────────
    //
    // The full `run_json_phase` loop needs a live `inferlet::Generator` +
    // chat/reasoning decoders bound to a real model, so it stays covered by
    // the dummy/HTTP e2e and the opt-in real-model smoke (incl. the
    // tiny-budget mid-`<think>` regression). The pure decision points it
    // feeds — forward-error classification, the empty-output guard, the
    // shared-budget split, and the pure-failure status — are isolated here so
    // each contract is asserted deterministically without an engine.

    fn json_phase_result(
        outcome: Outcome,
        error_diag: Option<(&'static str, String)>,
        produced_content: bool,
    ) -> JsonPhaseResult {
        JsonPhaseResult {
            outcome,
            error_diag,
            disconnected: false,
            tokens_generated: 0,
            produced_content,
        }
    }

    #[test]
    fn json_forward_error_classifies_server_busy_vs_generic() {
        // F1: the same sentinel the canonical loop honors must drive the JSON
        // path's terminal code (run_json_phase calls this on both the
        // `next()` and `execute()` error arms).
        assert_eq!(
            classify_forward_error("server_busy: KV page acquisition timed out after 120s"),
            SERVER_BUSY_CODE
        );
        assert_eq!(
            classify_forward_error("GenStep::execute forward: device queue fault"),
            "forward_pass_failed"
        );
    }

    #[test]
    fn json_pure_failure_status_maps_server_busy_to_503() {
        // F1: over-capacity backpressure is retryable (503); every other
        // pure failure is a hard 500 — mirrors the canonical branch.
        assert_eq!(json_pure_failure_status(SERVER_BUSY_CODE), 503);
        assert_eq!(json_pure_failure_status("forward_pass_failed"), 500);
        assert_eq!(json_pure_failure_status("decode_failed"), 500);
    }

    #[test]
    fn json_aborted_outcome_finishes_as_error() {
        // F4: an aborted phase must surface finish_reason "error" (the
        // streaming final-chunk + non-stream choice both read this).
        assert_eq!(Outcome::Aborted.finish_reason(), "error");
        assert_eq!(Outcome::Natural.finish_reason(), "stop");
        assert_eq!(Outcome::MaxTokens.finish_reason(), "length");
    }

    #[test]
    fn json_phase2_budget_shares_ceiling_and_floors() {
        // F2: Phase 2 gets the remainder of the shared ceiling…
        assert_eq!(json_phase2_budget(2048, 100), 1948);
        // …and total stays within the request bound when Phase 1 is cheap.
        assert!(100 + json_phase2_budget(2048, 100) <= 2048);
        // …but a Phase 1 that burned (nearly) everything still leaves a floor
        // so the constrained answer is never budgeted to zero.
        assert_eq!(json_phase2_budget(2048, 2048), JSON_PHASE2_MIN_TOKENS);
        assert_eq!(json_phase2_budget(16, 16), JSON_PHASE2_MIN_TOKENS);
        assert_eq!(json_phase2_budget(10, 9999), JSON_PHASE2_MIN_TOKENS);
    }

    #[test]
    fn json_phase2_finalize_flags_empty_output_as_error() {
        // F3: a clean phase that emitted no content is a contract failure for
        // json_object — reclassified as an explicit error, not a 200/"".
        for outcome in [Outcome::Natural, Outcome::MaxTokens] {
            let (o, diag, _) = json_phase2_finalize(json_phase_result(outcome, None, false));
            assert_eq!(o, Outcome::Aborted);
            assert_eq!(diag.unwrap().0, JSON_EMPTY_OUTPUT_CODE);
        }
    }

    #[test]
    fn json_phase2_finalize_passes_through_content_and_errors() {
        // Produced content → success passes through untouched.
        let (o, diag, _) =
            json_phase2_finalize(json_phase_result(Outcome::Natural, None, true));
        assert_eq!(o, Outcome::Natural);
        assert!(diag.is_none());

        // An existing error is preserved (never masked by the empty guard).
        let (o, diag, _) = json_phase2_finalize(json_phase_result(
            Outcome::Aborted,
            Some(("forward_pass_failed", "boom".into())),
            false,
        ));
        assert_eq!(o, Outcome::Aborted);
        assert_eq!(diag.unwrap().0, "forward_pass_failed");

        // A server_busy abort survives finalize so the 503 mapping still fires.
        let (_, diag, _) = json_phase2_finalize(json_phase_result(
            Outcome::Aborted,
            Some((SERVER_BUSY_CODE, "busy".into())),
            false,
        ));
        assert_eq!(json_pure_failure_status(diag.unwrap().0), 503);
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
        assert_eq!(
            frame["_schema_version"].as_str().unwrap(),
            HEARTBEAT_SCHEMA_VERSION
        );
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
        let frame_all = serde_json::from_str::<serde_json::Value>(&all)
            .unwrap()
            .as_array()
            .unwrap()[0]
            .clone();
        assert_eq!(frame_all["entries_lost_total_authoritative"], true);

        let partial = fallback_serialize_failed_payload(Some(5), None, None, None);
        let frame_partial = serde_json::from_str::<serde_json::Value>(&partial)
            .unwrap()
            .as_array()
            .unwrap()[0]
            .clone();
        assert_eq!(frame_partial["entries_lost_total_authoritative"], false);

        // One unmeasured slot is enough to flip the flag — even
        // if the other three are measured.
        let three_measured = fallback_serialize_failed_payload(Some(1), Some(2), Some(3), None);
        let frame_three = serde_json::from_str::<serde_json::Value>(&three_measured)
            .unwrap()
            .as_array()
            .unwrap()[0]
            .clone();
        assert_eq!(frame_three["entries_lost_total_authoritative"], false);
    }

    #[test]
    fn fallback_entries_lost_total_authoritative_wire_type_is_bool() {
        // X1: pin the wire type at JSON boolean so a future
        // accidental int/string conversion fires here instead of
        // silently breaking dashboards.
        let s = fallback_serialize_failed_payload(Some(0), Some(0), Some(0), Some(0));
        let frame = serde_json::from_str::<serde_json::Value>(&s)
            .unwrap()
            .as_array()
            .unwrap()[0]
            .clone();
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
        let unmeasured = fallback_serialize_failed_payload(Some(7), None, None, None);
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
        let observed: BTreeSet<&'static str> = STABLE_LAUNCH_DIAG_CODES.iter().copied().collect();
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
        let entry = arr[1].as_object().expect("arr[1] must be a JSON object");
        let observed: BTreeSet<&str> = entry.keys().map(String::as_str).collect();
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
        let frame = serialize_fail_sentinel(&[("monotonic_clock_stubbed", "stub".to_string())]);
        let observed: BTreeSet<&str> = frame
            .as_object()
            .expect("sentinel must be a JSON object")
            .keys()
            .map(String::as_str)
            .collect();
        let expected: BTreeSet<&str> = ["_serialize_failed", "_serialize_failed_codes"]
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
        let expected: BTreeSet<&str> =
            ["code", "_schema_version", "scope", "launched_at", "message"]
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
