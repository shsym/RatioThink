//! Cross-request KV **prefix cache** (#522 "APC" — *automatic
//! prefix/context* reuse). This is unrelated to the Adaptive
//! Personality/Capability decoders in [`super::apc`]; the ticket reuses
//! the "APC" letters for a different concept, so this module avoids that
//! name entirely.
//!
//! # Architecture note (acceptance criterion for #522)
//!
//! ## Request-local baseline
//!
//! Today every chat turn rebuilds the whole context: the App posts all
//! persisted messages, [`super::completions`] does `Context::new(model)`,
//! fills the entire prompt, generates, and the per-request wasm instance
//! drops. The history is re-prefilled on every turn — O(history) work per
//! request.
//!
//! ## pie save/open semantics (verified against Vendor/pie @ e742a1cb)
//!
//! - `Context::save(name)` snapshots the context's committed + working KV
//!   pages under `name`. The SDK-side `buffer()` of un-flushed tokens is
//!   **not** captured, so a caller must `flush()` before `save`.
//! - `Context::open(model, name)` looks the snapshot up and **forks** it
//!   (snapshot stays immutable); a miss returns `Err`, never panics.
//! - Snapshots live in a long-lived per-model `ContextManager` actor keyed
//!   by `(username, name)`. `username` is the session user — stable across
//!   the short-lived per-request wasm instances — so a snapshot saved by
//!   request N is found by request N+1. Engine restart / model unload wipes
//!   the actor, so those become natural misses.
//! - `save` rejects a duplicate name; an already-present name means an
//!   identical snapshot already exists (same content hash ⇒ same KV), so we
//!   treat `AlreadyExists` as a benign no-op.
//!
//! ## Key schema (content-addressed ⇒ provably correct)
//!
//! ```text
//! name = "apc/{chat_key}/{compat}/{hex(hash(model_id ‖ template ‖ prefix_token_ids))}"
//! ```
//!
//! The hash covers the **exact token sequence** the snapshot's KV
//! represents. Therefore a *hit* (name match) means identical tokens for
//! the same model ⇒ identical KV. Any divergence — different model,
//! tokenizer/template, system prompt, tools schema, or history — changes
//! the token sequence ⇒ changes the hash ⇒ a clean miss. **A false hit
//! that returns wrong KV is impossible.** Sampling/speculation are *not*
//! in the key (they do not affect prefix tokens), so a same-model profile
//! switch that only changes sampling still hits. `chat_key` and `compat`
//! are namespace components: per-chat attribution, and an app-schema /
//! template-drift kill-switch the App bumps to force misses.
//!
//! ## Reuse mechanic (the inferlet is stateless across requests)
//!
//! - `prefix_tokens` = tokens for `messages[..last]` (no cue) — everything
//!   a prior turn already computed and may have saved.
//! - `suffix` = the trailing new user message + cue.
//! - On a hit, `open` the prefix snapshot and append only `suffix`, then
//!   generate — the long history prefill is skipped. On a miss, rebuild the
//!   full prompt.
//!
//! ## Save (next boundary — canonical rebuild)
//!
//! The next turn does not resend this turn's reasoning: a thinking model's
//! `<think>…</think>` tokens live in the generation KV but are dropped from
//! the persisted/resent history. So the boundary we save is *not* the
//! generation KV — it is the **canonical text rendering** the next request
//! will actually send: `prompt_no_cue ‖ assistant(visible_content)`. We
//! materialize that KV cheaply by re-opening the same prefix snapshot used
//! for generation (an immutable fork) and appending only this turn's tail
//! (the last user message + `assistant(visible_content)`) — a single
//! forward pass over one turn, not the whole history. On a miss (no prefix
//! snapshot) we rebuild the full boundary, which is unavoidable there but
//! only happens on the first turn or after an engine restart, where the
//! history is short. The snapshot is named by the exact `next_prefix`
//! tokens, so the next turn recomputes the identical name and hits. This is
//! correct for thinking *and* non-thinking models: we never reuse the
//! reasoning-bearing generation KV, only the canonical history KV.
//!
//! ## Lifecycle / invalidation
//!
//! - **Retry / truncate**: snapshots are content-addressed, so a snapshot
//!   that included an erased suffix has an unreachable name; the resent
//!   request recomputes the *earlier* still-valid boundary name and hits
//!   it. No explicit deletion needed and no stale suffix can leak.
//! - **Engine restart / model unload / profile-prompt drift**: natural
//!   misses (snapshot gone or name changed).
//! - **Chat delete**: the chat's snapshots become unreachable (no future
//!   request carries that key+prefix) — an "explicit miss". Phase 2
//!   retention reclaims inactive unreachable snapshots under runtime KV
//!   pressure.
//! - **policy = bypass**: never open, never save (privacy / ephemeral).
//!
//! ## Phase 2 retention
//!
//! The App may attach authoritative #517 runtime KV counters as a
//! `cache.retention` budget. The inferlet passes that budget to pie's
//! long-lived host `ContextManager`, which owns snapshot listing,
//! per-request active protection, LRU selection, and deletion. Retention
//! state intentionally does **not** live in WASM guest statics because the
//! daemon creates a fresh component instance for each HTTP request.

use serde::{Deserialize, Serialize};
#[cfg(test)]
use std::collections::{HashMap, HashSet};

// =============================================================================
// Request directive
// =============================================================================

/// Reuse policy carried by the request's `cache` directive.
#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "lowercase")]
pub enum Policy {
    /// Open the matching prefix snapshot on a hit and save the new
    /// boundary on success.
    #[default]
    Auto,
    /// Never open, never save. Byte-identical to the pre-#522 rebuild
    /// path; for ephemeral / privacy-sensitive chats.
    Bypass,
}

/// Per-chat cache directive (`"cache"` object on a chat-completions
/// request). Absent ⇒ reuse disabled (legacy callers stay byte-identical).
#[derive(Deserialize, Clone, Debug, Default)]
pub struct CacheDirective {
    /// Local thread / cache key — the App's chat id. Empty ⇒ disabled.
    #[serde(default)]
    pub key: String,
    /// Expected turn boundary (message count at send time). Diagnostics
    /// only in Phase 1; the content hash is the load-bearing identity.
    #[serde(default)]
    pub turn: u64,
    /// Compatibility / version marker. Namespace component; the App bumps
    /// it to invalidate everything on schema or template drift.
    #[serde(default)]
    pub compat: String,
    #[serde(default)]
    pub policy: Policy,
    /// Optional Phase-2 retention budget supplied by the App from #517's
    /// authoritative pie `model_status` counters. Absent means "do not evict
    /// on this request" rather than guessing from tokens.
    #[serde(default)]
    pub retention: Option<RetentionBudget>,
}

impl CacheDirective {
    /// Reuse is active only for an `auto` directive with a non-empty key.
    pub fn enabled(&self) -> bool {
        self.policy == Policy::Auto && !self.key.is_empty()
    }
}

// =============================================================================
// Smart retention / LRU eviction
// =============================================================================

const DEFAULT_SOFT_PERCENT: u8 = 70;
const DEFAULT_EVICT_PERCENT: u8 = 80;
const DEFAULT_HARD_PERCENT: u8 = 95;

fn default_soft_percent() -> u8 {
    DEFAULT_SOFT_PERCENT
}

fn default_evict_percent() -> u8 {
    DEFAULT_EVICT_PERCENT
}

fn default_hard_percent() -> u8 {
    DEFAULT_HARD_PERCENT
}

/// Runtime-provided global KV pressure for the served model. These counters
/// deliberately mirror #517's `KVUsageSnapshot` / pie `model_status` names;
/// callers must pass runtime counters, not app-side token estimates.
#[derive(Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetentionBudget {
    pub kv_pages_used: u32,
    pub kv_pages_total: u32,
    #[serde(default = "default_soft_percent")]
    pub soft_percent: u8,
    #[serde(default = "default_evict_percent")]
    pub evict_percent: u8,
    #[serde(default = "default_hard_percent")]
    pub hard_percent: u8,
}

impl Default for RetentionBudget {
    fn default() -> Self {
        Self {
            kv_pages_used: 0,
            kv_pages_total: 0,
            soft_percent: DEFAULT_SOFT_PERCENT,
            evict_percent: DEFAULT_EVICT_PERCENT,
            hard_percent: DEFAULT_HARD_PERCENT,
        }
    }
}

#[cfg(test)]
impl RetentionBudget {
    fn coherent(&self) -> bool {
        self.kv_pages_total > 0
            && self.kv_pages_used <= self.kv_pages_total
            && self.soft_percent <= 100
            && self.evict_percent <= 100
            && self.hard_percent <= 100
            && self.soft_percent <= self.evict_percent
            && self.evict_percent <= self.hard_percent
    }

    fn threshold_pages(&self, percent: u8) -> u32 {
        ((self.kv_pages_total as u64 * percent as u64) / 100) as u32
    }

    fn soft_pages(&self) -> u32 {
        self.threshold_pages(self.soft_percent)
    }

    fn evict_pages(&self) -> u32 {
        self.threshold_pages(self.evict_percent)
    }

    fn hard_pages(&self) -> u32 {
        self.threshold_pages(self.hard_percent)
    }
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RetentionReason {
    RetainedBelowSoftLimit,
    RetainedBelowEvictionLimit,
    EvictedPressure,
    HardCapStillExceeded,
    RetentionDeleteFailed,
    ProtectedActive,
    NoInactiveSnapshots,
    SkippedUncertainAccounting,
}

#[cfg(test)]
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RetentionReport {
    pub evicted_names: Vec<String>,
    pub pages_reclaimed: u32,
    pub protected_active_pages: u32,
    pub retained_snapshot_count: usize,
    pub delete_failed_count: u32,
    pub reason: RetentionReason,
}

impl Default for RetentionReason {
    fn default() -> Self {
        Self::RetainedBelowSoftLimit
    }
}

fn map_host_retention_reason(reason: HostRetentionReason) -> RetentionReason {
    match reason {
        HostRetentionReason::RetainedBelowSoftLimit => RetentionReason::RetainedBelowSoftLimit,
        HostRetentionReason::RetainedBelowEvictionLimit => RetentionReason::RetainedBelowEvictionLimit,
        HostRetentionReason::EvictedPressure => RetentionReason::EvictedPressure,
        HostRetentionReason::HardCapStillExceeded => RetentionReason::HardCapStillExceeded,
        HostRetentionReason::RetentionDeleteFailed => RetentionReason::RetentionDeleteFailed,
        HostRetentionReason::ProtectedActive => RetentionReason::ProtectedActive,
        HostRetentionReason::NoInactiveSnapshots => RetentionReason::NoInactiveSnapshots,
        HostRetentionReason::SkippedUncertainAccounting => RetentionReason::SkippedUncertainAccounting,
    }
}

#[cfg(test)]
#[derive(Clone, Debug)]
struct SnapshotRecord {
    name: String,
    key: String,
    model_id: String,
    pages: u32,
    last_used_tick: u64,
}

#[cfg(test)]
#[derive(Default, Debug)]
pub struct RetentionRegistry {
    records: HashMap<String, SnapshotRecord>,
}

#[cfg(test)]
impl RetentionRegistry {
    pub fn record_saved(
        &mut self,
        name: impl Into<String>,
        key: impl Into<String>,
        model_id: impl Into<String>,
        pages: u32,
        last_used_tick: u64,
    ) {
        let name = name.into();
        self.records.insert(
            name.clone(),
            SnapshotRecord {
                name,
                key: key.into(),
                model_id: model_id.into(),
                pages,
                last_used_tick,
            },
        );
    }

    #[cfg(test)]
    pub fn contains(&self, name: &str) -> bool {
        self.records.contains_key(name)
    }

    pub fn enforce(
        &mut self,
        model_id: &str,
        budget: RetentionBudget,
        protected_names: &[&str],
    ) -> RetentionReport {
        let retained_snapshot_count = self
            .records
            .values()
            .filter(|record| record.model_id == model_id)
            .count();
        if !budget.coherent() {
            return RetentionReport {
                retained_snapshot_count,
                reason: RetentionReason::SkippedUncertainAccounting,
                ..Default::default()
            };
        }

        let protected: HashSet<&str> = protected_names.iter().copied().collect();
        let protected_active_pages = self
            .records
            .values()
            .filter(|record| {
                record.model_id == model_id && protected.contains(record.name.as_str())
            })
            .map(|record| record.pages)
            .sum();
        let target = budget.evict_pages();
        if budget.kv_pages_used <= budget.soft_pages() {
            return RetentionReport {
                retained_snapshot_count,
                protected_active_pages,
                reason: RetentionReason::RetainedBelowSoftLimit,
                ..Default::default()
            };
        }
        if budget.kv_pages_used <= target {
            return RetentionReport {
                retained_snapshot_count,
                protected_active_pages,
                reason: RetentionReason::RetainedBelowEvictionLimit,
                ..Default::default()
            };
        }

        let mut candidates: Vec<SnapshotRecord> = self
            .records
            .values()
            .filter(|record| {
                record.model_id == model_id && !protected.contains(record.name.as_str())
            })
            .cloned()
            .collect();
        candidates.sort_by(|a, b| {
            a.last_used_tick
                .cmp(&b.last_used_tick)
                .then_with(|| a.key.cmp(&b.key))
                .then_with(|| a.name.cmp(&b.name))
        });

        let mut projected = budget.kv_pages_used;
        let mut evicted_names = Vec::new();
        let mut pages_reclaimed = 0u32;
        for record in candidates {
            if projected <= target {
                break;
            }
            projected = projected.saturating_sub(record.pages);
            pages_reclaimed = pages_reclaimed.saturating_add(record.pages);
            evicted_names.push(record.name.clone());
            self.records.remove(&record.name);
        }

        let reason = if !evicted_names.is_empty() {
            if projected > budget.hard_pages() {
                RetentionReason::HardCapStillExceeded
            } else {
                RetentionReason::EvictedPressure
            }
        } else if protected_active_pages > 0 {
            RetentionReason::ProtectedActive
        } else {
            RetentionReason::NoInactiveSnapshots
        };

        let retained_snapshot_count = self
            .records
            .values()
            .filter(|record| record.model_id == model_id)
            .count();
        RetentionReport {
            evicted_names,
            pages_reclaimed,
            protected_active_pages,
            retained_snapshot_count,
            delete_failed_count: 0,
            reason,
        }
    }
}

/// RAII guard for snapshots used by an in-flight generation. The deletion
/// pass also receives the just-saved snapshot name, so both active streams
/// and the current foreground generation are protected from LRU eviction.
pub struct ActiveSnapshotGuard<'a> {
    model: &'a Model,
    names: Vec<String>,
}

impl Drop for ActiveSnapshotGuard<'_> {
    fn drop(&mut self) {
        for name in &self.names {
            Context::release_snapshot(self.model, name);
        }
    }
}

pub fn protect<'a>(model: &'a Model, plan: &ReusePlan) -> ActiveSnapshotGuard<'a> {
    let names: Vec<String> = plan.open_name.iter().cloned().collect();
    for name in &names {
        if let Err(e) = Context::retain_snapshot(model, name) {
            eprintln!("[chat-apc] prefix-cache retain snapshot failed for {name}: {e}");
        }
    }
    ActiveSnapshotGuard { model, names }
}

// =============================================================================
// Content-addressed naming
// =============================================================================

const FNV64_OFFSET_A: u64 = 0xcbf2_9ce4_8422_2325;
const FNV64_OFFSET_B: u64 = 0x1000_0000_0000_01b3; // distinct basis for lane B
const FNV64_PRIME: u64 = 0x0000_0100_0000_01b3;

#[inline]
fn fnv64(mut h: u64, bytes: &[u8]) -> u64 {
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(FNV64_PRIME);
    }
    h
}

/// Stable wide (128-bit-rendered) content digest from two FNV-1a lanes,
/// emitted as 32 lowercase hex chars. No external crate — deterministic
/// across builds and platforms, which a snapshot name keyed across
/// processes requires.
///
/// The lanes share [`FNV64_PRIME`] and differ only in offset basis, so they
/// are correlated rather than two independent hash functions — the
/// effective collision resistance is wider than a single 64-bit lane (the
/// XOR-before-multiply step makes the lane differential input-dependent, so
/// lane B adds real bits) but is NOT a proven 2⁻¹²⁸. That margin is ample
/// here: a collision can only mislead within the same `(chat_key, compat,
/// model)` namespace, i.e. two *distinct* histories the same user actually
/// sends — for which 64+ effective bits is already far beyond reach.
pub fn content_hash(model_id: &str, template_marker: &str, prefix_tokens: &[u32]) -> String {
    // Domain separators (0xFF is not a valid UTF-8 continuation lead, so it
    // cannot appear inside the model/template strings) prevent field-shift
    // ambiguity, e.g. ("ab","c") vs ("a","bc").
    let sep = [0xFFu8];
    let mut a = fnv64(FNV64_OFFSET_A, model_id.as_bytes());
    let mut b = fnv64(FNV64_OFFSET_B, model_id.as_bytes());
    a = fnv64(a, &sep);
    b = fnv64(b, &sep);
    a = fnv64(a, template_marker.as_bytes());
    b = fnv64(b, template_marker.as_bytes());
    a = fnv64(a, &sep);
    b = fnv64(b, &sep);
    for &t in prefix_tokens {
        let le = t.to_le_bytes();
        a = fnv64(a, &le);
        b = fnv64(b, &le);
    }
    format!("{a:016x}{b:016x}")
}

/// Full snapshot name: `apc/{key}/{compat}/{content_hash}`.
pub fn snapshot_name(
    key: &str,
    compat: &str,
    model_id: &str,
    template_marker: &str,
    prefix_tokens: &[u32],
) -> String {
    let h = content_hash(model_id, template_marker, prefix_tokens);
    let compat = if compat.is_empty() { "0" } else { compat };
    format!("apc/{key}/{compat}/{h}")
}

/// Short, non-reversible tag for a string (chat key) used in diagnostics so
/// the raw key never rides the wire.
pub fn short_tag(s: &str) -> String {
    let h = fnv64(FNV64_OFFSET_A, s.as_bytes());
    format!("{h:016x}")
}

// =============================================================================
// Prefix / suffix split
// =============================================================================

/// Given the full prompt-token length and the reusable-prefix length,
/// return the suffix start index, or `None` when the prefix is not a strict
/// prefix of the full prompt (a tokenizer-non-monotonicity bug — callers
/// must fall back to a full rebuild rather than trust a bad split).
pub fn suffix_start(full_len: usize, prefix_len: usize) -> Option<usize> {
    (prefix_len <= full_len).then_some(prefix_len)
}

// =============================================================================
// Diagnostics
// =============================================================================

/// Structured cache diagnostics emitted per request (SSE `cache` frame on
/// the streaming path, `X-ChatAPC-Cache` header on the non-streaming path).
/// Unknown values are represented explicitly (`Option` → `null`) rather
/// than guessed — the ticket forbids treating unknown KV usage as known.
#[derive(Serialize, Default, Clone, Debug)]
pub struct CacheDiag {
    pub event: &'static str,
    /// `hit` | `miss` | `bypass` | `disabled`.
    pub outcome: &'static str,
    /// Short tag of the chat key (raw key never sent).
    pub key_tag: String,
    /// The boundary turn the request expected (echoed from the directive).
    pub turn: u64,
    /// Content-hash portion of the opened prefix name (empty when none).
    pub prefix_hash: String,
    /// Prefix tokens reused from the snapshot (0 on a miss).
    pub base_boundary: usize,
    /// Tokens appended after the reused prefix (suffix on a hit, full
    /// prompt on a miss).
    pub appended: usize,
    /// Committed KV pages after generation, when the engine reports them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub committed_pages: Option<u32>,
    /// Working KV pages after generation, when the engine reports them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_pages: Option<u32>,
    /// `saved` | `exists` | `skipped:<reason>` | `failed:<reason>` | `none`.
    pub save_result: String,
    /// Content-hash portion of the saved next-prefix name (empty when none).
    pub save_hash: String,
    /// Number of same-model snapshots still tracked after retention.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retained_snapshot_count: Option<usize>,
    /// Number of whole inactive snapshots evicted by the retention pass.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evicted_snapshot_count: Option<usize>,
    /// KV pages reclaimed by whole-snapshot LRU eviction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pages_reclaimed: Option<u32>,
    /// Host-side delete failures observed during the retention pass.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delete_failed_count: Option<u32>,
    /// Pages attributed to protected active/current snapshots.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub protected_active_pages: Option<u32>,
    /// Retention decision reason (`evicted_pressure`,
    /// `protected_active`, `skipped_uncertain_accounting`, ...).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eviction_reason: Option<RetentionReason>,
}

impl CacheDiag {
    pub fn new(outcome: &'static str, key: &str) -> Self {
        Self {
            event: "cache",
            outcome,
            key_tag: short_tag(key),
            save_result: "none".to_string(),
            ..Default::default()
        }
    }
}

// =============================================================================
// Engine glue (calls WIT host imports; not unit-tested — covered by the
// real-engine e2e suite. The correctness lives in the pure helpers above.)
// =============================================================================

use super::completions::{ChatMessage, ToolSchema, build_prompt_tokens};
use inferlet::{
    Context, RetentionBudget as HostRetentionBudget, RetentionReason as HostRetentionReason,
};
use inferlet::chat;
use inferlet::model::Model;

/// Inferlet/template version folded into every snapshot name. A chat-apc
/// build bump (which can change templating, tokenization wrappers, or the
/// generation loop) invalidates every prior snapshot — the "inferlet
/// version" the ticket's key schema calls for, on top of the per-token
/// content hash.
const TEMPLATE_MARKER: &str = concat!("chat-apc-", env!("CARGO_PKG_VERSION"));

/// Trailing content-hash segment of a snapshot name, for diagnostics
/// (the raw key never rides the wire — see [`short_tag`]).
fn name_hash_part(name: &str) -> String {
    name.rsplit('/').next().unwrap_or_default().to_string()
}

/// Everything the request handler needs to open a prefix snapshot, rebuild
/// on a miss, and save the next boundary. Built once per request.
pub struct ReusePlan {
    pub directive: CacheDirective,
    pub model_id: String,
    /// All messages tokenized, no trailing cue.
    pub prompt_no_cue: Vec<u32>,
    /// The generation cue (assistant-turn opener).
    pub cue: Vec<u32>,
    /// `messages[..last]` tokenized, no cue — the reusable-prefix basis.
    pub prefix_tokens: Vec<u32>,
    /// Snapshot name to open on a hit; `None` when the prefix is empty
    /// (nothing worth reusing).
    pub open_name: Option<String>,
}

/// Build the reuse plan for an enabled directive. Tokenizes the prompt via
/// the same [`build_prompt_tokens`] the rebuild path uses, so the cached
/// and rebuilt prefills are bit-identical.
pub fn plan(
    model: &Model,
    model_id: &str,
    messages: &[ChatMessage],
    tools: Option<&[ToolSchema]>,
    directive: CacheDirective,
) -> Result<ReusePlan, (&'static str, String)> {
    let prompt_no_cue = build_prompt_tokens(model, messages, tools, false)?;
    let cue = chat::cue(model);
    let last = messages.len().saturating_sub(1);
    let prefix_tokens = build_prompt_tokens(model, &messages[..last], tools, false)?;
    let open_name = if !prefix_tokens.is_empty() {
        Some(snapshot_name(
            &directive.key,
            &directive.compat,
            model_id,
            TEMPLATE_MARKER,
            &prefix_tokens,
        ))
    } else {
        None
    };
    Ok(ReusePlan {
        directive,
        model_id: model_id.to_string(),
        prompt_no_cue,
        cue,
        prefix_tokens,
        open_name,
    })
}

/// Acquire a context for generation: open the prefix snapshot and append
/// only the suffix on a hit, otherwise create a fresh context and append
/// the full prompt. Returns the context plus the diagnostics seeded with
/// the hit/miss outcome (the handler fills in save_result / page counts via
/// [`finalize`]).
pub fn acquire(
    model: &Model,
    plan: &ReusePlan,
) -> Result<(Context, CacheDiag), (&'static str, String)> {
    let mut diag = CacheDiag::new("miss", &plan.directive.key);
    diag.turn = plan.directive.turn;

    if let Some(name) = &plan.open_name {
        if let Ok(mut ctx) = Context::open(model, name) {
            match suffix_start(plan.prompt_no_cue.len(), plan.prefix_tokens.len()) {
                Some(s) => {
                    // Hit: the snapshot already holds `prefix_tokens`; append
                    // only the trailing new-user turn + cue.
                    let mut suffix = plan.prompt_no_cue[s..].to_vec();
                    suffix.extend_from_slice(&plan.cue);
                    diag.outcome = "hit";
                    diag.prefix_hash = name_hash_part(name);
                    diag.base_boundary = plan.prefix_tokens.len();
                    diag.appended = suffix.len();
                    ctx.append(&suffix);
                    return Ok((ctx, diag));
                }
                None => {
                    // Non-monotone tokenization (prefix longer than the full
                    // prompt) — a tokenizer bug. Drop the fork (scope-drop
                    // releases the context) and fall through to a clean
                    // rebuild rather than trust the split.
                }
            }
        }
        // Err / non-monotone → miss (outcome already "miss").
    }

    // Miss / nothing to open: full rebuild.
    let mut ctx = Context::new(model).map_err(|e| {
        (
            "context_create_failed",
            format!("Failed to create context: {e}"),
        )
    })?;
    let mut full = plan.prompt_no_cue.clone();
    full.extend_from_slice(&plan.cue);
    diag.base_boundary = 0;
    diag.appended = full.len();
    ctx.append(&full);
    Ok((ctx, diag))
}

/// After a successful turn, build and save the next reusable boundary —
/// the canonical text KV the *next* request will send,
/// `prompt_no_cue ‖ assistant(visible_content)`. Builds it in a dedicated
/// context (cheap fork+tail on a hit, full rebuild on a miss) so the saved
/// KV never carries this turn's reasoning. Mutates `diag` with the result.
///
/// `gen_content` is the visible assistant text the App persists and resends.
pub async fn finalize(plan: &ReusePlan, gen_content: &str, model: &Model, diag: &mut CacheDiag) {
    let assistant = chat::assistant(model, gen_content);
    if assistant.is_empty() {
        // Nothing to commit as history (e.g. an all-reasoning turn cut off
        // before any visible content). No boundary to save.
        diag.save_result = "skipped:empty_turn".to_string();
        return;
    }
    // The boundary the next request will recompute and look up.
    let mut next_prefix = plan.prompt_no_cue.clone();
    next_prefix.extend_from_slice(&assistant);
    let name = snapshot_name(
        &plan.directive.key,
        &plan.directive.compat,
        &plan.model_id,
        TEMPLATE_MARKER,
        &next_prefix,
    );

    // Cheap path: re-open the prefix snapshot we generated against (an
    // immutable fork) and append only this turn's tail — one forward pass
    // over a single turn. Fall back to a full rebuild on a miss.
    let reused = match (
        plan.open_name.as_deref(),
        suffix_start(plan.prompt_no_cue.len(), plan.prefix_tokens.len()),
    ) {
        (Some(n), Some(s)) => Context::open(model, n).ok().map(|mut ctx| {
            let mut tail = plan.prompt_no_cue[s..].to_vec();
            tail.extend_from_slice(&assistant);
            ctx.append(&tail);
            ctx
        }),
        _ => None,
    };
    let mut save_ctx = match reused {
        Some(ctx) => ctx,
        None => match Context::new(model) {
            Ok(mut ctx) => {
                ctx.append(&next_prefix);
                ctx
            }
            Err(e) => {
                eprintln!("[chat-apc] prefix-cache boundary ctx failed: {e}");
                diag.save_result = "failed:ctx".to_string();
                return;
            }
        },
    };
    if let Err(e) = save_ctx.flush().await {
        eprintln!("[chat-apc] prefix-cache boundary flush failed: {e}");
        diag.save_result = "failed:flush".to_string();
        return;
    }
    // Authoritative engine state — emit, never guess.
    let committed_pages = save_ctx.inner().committed_page_count();
    let working_pages = save_ctx.inner().working_page_count();
    diag.committed_pages = Some(committed_pages);
    diag.working_pages = Some(working_pages);
    match save_ctx.save(&name) {
        Ok(()) => {
            diag.save_result = "saved".to_string();
            diag.save_hash = name_hash_part(&name);
        }
        Err(e) => {
            let es = e.to_string();
            if es.contains("already exists") {
                // Same content hash already saved — identical KV, benign,
                // still a valid future hit.
                diag.save_result = "exists".to_string();
                diag.save_hash = name_hash_part(&name);
            } else {
                eprintln!("[chat-apc] prefix-cache save failed: {es}");
                diag.save_result = "failed:save".to_string();
            }
        }
    }
    if let Some(budget) = plan.directive.retention {
        match Context::enforce_retention(
            model,
            "apc/",
            &name,
            HostRetentionBudget {
                kv_pages_used: budget.kv_pages_used,
                kv_pages_total: budget.kv_pages_total,
                soft_percent: budget.soft_percent,
                evict_percent: budget.evict_percent,
                hard_percent: budget.hard_percent,
            },
        ) {
            Ok(report) => {
                diag.retained_snapshot_count = Some(report.retained_snapshot_count as usize);
                diag.evicted_snapshot_count = Some(report.evicted_names.len());
                diag.pages_reclaimed = Some(report.pages_reclaimed);
                diag.protected_active_pages = Some(report.protected_active_pages);
                diag.delete_failed_count = Some(report.delete_failed_count);
                diag.eviction_reason = Some(map_host_retention_reason(report.reason));
            }
            Err(e) => {
                eprintln!("[chat-apc] prefix-cache host retention failed: {e}");
                diag.eviction_reason = Some(RetentionReason::SkippedUncertainAccounting);
                diag.delete_failed_count = Some(1);
            }
        }
    }
    // `save_ctx` drops here, releasing the context resource (the snapshot it
    // saved is independent and survives).
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── content_hash / snapshot_name identity ────────────────

    #[test]
    fn same_inputs_same_name() {
        let a = snapshot_name("chat-1", "1", "qwen", "tmpl-v1", &[1, 2, 3]);
        let b = snapshot_name("chat-1", "1", "qwen", "tmpl-v1", &[1, 2, 3]);
        assert_eq!(a, b);
    }

    #[test]
    fn different_models_never_share() {
        // Core safety: a different model id must change the name so two
        // models can never alias the same physical KV.
        let a = snapshot_name("chat-1", "1", "qwen-0.6b", "tmpl-v1", &[1, 2, 3]);
        let b = snapshot_name("chat-1", "1", "llama-8b", "tmpl-v1", &[1, 2, 3]);
        assert_ne!(a, b);
    }

    #[test]
    fn template_drift_changes_name() {
        let a = snapshot_name("chat-1", "1", "qwen", "tmpl-v1", &[1, 2, 3]);
        let b = snapshot_name("chat-1", "1", "qwen", "tmpl-v2", &[1, 2, 3]);
        assert_ne!(a, b);
    }

    #[test]
    fn prompt_change_changes_name() {
        // A changed system prompt / tools schema / history shows up as
        // different prefix tokens → different name → miss.
        let a = snapshot_name("chat-1", "1", "qwen", "tmpl", &[1, 2, 3]);
        let b = snapshot_name("chat-1", "1", "qwen", "tmpl", &[1, 2, 9]);
        assert_ne!(a, b);
    }

    #[test]
    fn compat_bump_changes_name() {
        let a = snapshot_name("chat-1", "1", "qwen", "tmpl", &[1, 2, 3]);
        let b = snapshot_name("chat-1", "2", "qwen", "tmpl", &[1, 2, 3]);
        assert_ne!(a, b);
    }

    #[test]
    fn distinct_chats_do_not_share() {
        let a = snapshot_name("chat-1", "1", "qwen", "tmpl", &[1, 2, 3]);
        let b = snapshot_name("chat-2", "1", "qwen", "tmpl", &[1, 2, 3]);
        assert_ne!(a, b);
    }

    #[test]
    fn sampling_change_is_a_hit() {
        // Sampling/speculation are not inputs to the name, so a same-model
        // profile switch that only changes sampling reuses the prefix.
        // (Modeled by identical prefix tokens producing an identical name.)
        let cold = snapshot_name("chat-1", "1", "qwen", "tmpl", &[1, 2, 3]);
        let warm = snapshot_name("chat-1", "1", "qwen", "tmpl", &[1, 2, 3]);
        assert_eq!(cold, warm);
    }

    #[test]
    fn model_switch_misses_but_switch_back_recovers_original_name() {
        // Cross-profile safety matrix:
        // - switching to a different model must miss because physical KV is
        //   model-specific;
        // - switching back to the original model with the same rendered
        //   prefix must recompute the original name and hit.
        let before = snapshot_name("chat-1", "1", "qwen-0.6b", "tmpl", &[1, 2, 3]);
        let other_model = snapshot_name("chat-1", "1", "llama-8b", "tmpl", &[1, 2, 3]);
        let switched_back = snapshot_name("chat-1", "1", "qwen-0.6b", "tmpl", &[1, 2, 3]);
        assert_ne!(before, other_model);
        assert_eq!(before, switched_back);
    }

    #[test]
    fn empty_compat_normalizes() {
        // An empty compat must not collide with a literal "0" caller and
        // must still be stable.
        let a = snapshot_name("c", "", "qwen", "tmpl", &[1]);
        let b = snapshot_name("c", "", "qwen", "tmpl", &[1]);
        assert_eq!(a, b);
        assert!(a.contains("apc/c/0/"));
    }

    #[test]
    fn field_shift_does_not_alias() {
        // Domain separators stop ("ab","c") from hashing the same as
        // ("a","bc").
        let a = content_hash("ab", "c", &[]);
        let b = content_hash("a", "bc", &[]);
        assert_ne!(a, b);
    }

    // ─── suffix split ─────────────────────────────────────────

    #[test]
    fn suffix_split_reconstructs_full() {
        let prefix = vec![10u32, 11, 12];
        let suffix = vec![20u32, 21];
        let full: Vec<u32> = prefix.iter().chain(&suffix).copied().collect();
        let start = suffix_start(full.len(), prefix.len()).unwrap();
        assert_eq!(&full[start..], suffix.as_slice());
    }

    #[test]
    fn suffix_split_rejects_overlong_prefix() {
        // A non-monotone tokenizer (prefix longer than full) must be
        // caught, not silently sliced.
        assert_eq!(suffix_start(3, 5), None);
    }

    // ─── next-boundary ↔ next-turn-prefix identity ────────────

    #[test]
    fn saved_boundary_matches_next_turn_prefix_lookup() {
        // Turn N saves a boundary named by `prompt_no_cue ‖ assistant`.
        // Turn N+1, before its new user message, computes its reusable
        // prefix as exactly those same tokens (canonical text rendering,
        // reasoning excluded) and must recompute the identical name → hit.
        let prompt_no_cue = vec![1u32, 2, 3]; // sys + user_N
        let assistant = vec![10u32, 11]; // assistant(visible_content_N)
        let mut saved = prompt_no_cue.clone();
        saved.extend_from_slice(&assistant);
        let save_name = snapshot_name("c", "1", "m", "t", &saved);

        // Turn N+1: history prefix (everything before the new user turn) is
        // the same token sequence the boundary was named by.
        let lookup_prefix = saved.clone();
        let open_name = snapshot_name("c", "1", "m", "t", &lookup_prefix);
        assert_eq!(
            open_name, save_name,
            "next turn must hit the saved boundary"
        );
    }

    // ─── retry / truncate invalidation (reasoning over names) ──

    #[test]
    fn retry_cannot_reuse_erased_suffix_boundary() {
        // Turn 2 saved a boundary covering [sys,u1,a1,u2,a2]. The user then
        // retries turn 2: the resent request's history is [sys,u1,a1] (a2/u2
        // erased), so it recomputes the [sys,u1,a1] boundary name — which
        // equals the boundary turn 1 saved (a valid hit) and is *different*
        // from the now-stale [..a2] name (which is never requested again).
        let after_turn1 = snapshot_name("c", "1", "m", "t", &[1, 2, 3]); // sys,u1,a1
        let after_turn2 = snapshot_name("c", "1", "m", "t", &[1, 2, 3, 4, 5]); // ..u2,a2
        let retry_lookup = snapshot_name("c", "1", "m", "t", &[1, 2, 3]); // erased back to a1
        assert_eq!(
            retry_lookup, after_turn1,
            "retry hits the valid earlier boundary"
        );
        assert_ne!(
            retry_lookup, after_turn2,
            "stale suffix boundary is unreachable"
        );
    }

    #[test]
    fn retry_in_one_chat_cannot_reach_other_chats_boundary() {
        // Dedicated no-contamination guard: even if two chats have identical
        // rendered history, their snapshot names differ by chat key, so a
        // retry in chat A can only hit chat A's valid earlier boundary.
        let chat_a_after_turn1 = snapshot_name("chat-a", "1", "m", "t", &[1, 2, 3]);
        let chat_a_stale_after_turn2 = snapshot_name("chat-a", "1", "m", "t", &[1, 2, 3, 4, 5]);
        let chat_b_after_turn1_same_tokens = snapshot_name("chat-b", "1", "m", "t", &[1, 2, 3]);
        let chat_a_retry_lookup = snapshot_name("chat-a", "1", "m", "t", &[1, 2, 3]);

        assert_eq!(chat_a_retry_lookup, chat_a_after_turn1);
        assert_ne!(chat_a_retry_lookup, chat_a_stale_after_turn2);
        assert_ne!(chat_a_retry_lookup, chat_b_after_turn1_same_tokens);
    }

    // ─── directive gating ─────────────────────────────────────

    #[test]
    fn directive_enabled_only_for_auto_with_key() {
        let mut d = CacheDirective {
            key: "c".to_string(),
            turn: 0,
            compat: "1".to_string(),
            policy: Policy::Auto,
            retention: None,
        };
        assert!(d.enabled());
        d.policy = Policy::Bypass;
        assert!(!d.enabled());
        d.policy = Policy::Auto;
        d.key.clear();
        assert!(!d.enabled());
    }

    #[test]
    fn policy_deserializes_lowercase() {
        let d: CacheDirective =
            serde_json::from_str(r#"{"key":"c","compat":"1","policy":"bypass"}"#).unwrap();
        assert_eq!(d.policy, Policy::Bypass);
        // Absent policy defaults to auto.
        let d2: CacheDirective = serde_json::from_str(r#"{"key":"c"}"#).unwrap();
        assert_eq!(d2.policy, Policy::Auto);
        assert!(d2.enabled());
    }

    // ─── smart retention / LRU eviction ──────────────────────

    #[test]
    fn retention_budget_deserializes_authoritative_runtime_usage() {
        let d: CacheDirective = serde_json::from_str(
            r#"{
                "key":"chat-a",
                "turn":3,
                "retention":{
                    "kv_pages_used":90,
                    "kv_pages_total":100,
                    "soft_percent":70,
                    "evict_percent":80,
                    "hard_percent":95
                }
            }"#,
        )
        .unwrap();

        let retention = d.retention.expect("retention directive should decode");
        assert_eq!(retention.kv_pages_used, 90);
        assert_eq!(retention.kv_pages_total, 100);
        assert_eq!(retention.soft_percent, 70);
        assert_eq!(retention.evict_percent, 80);
        assert_eq!(retention.hard_percent, 95);
    }

    #[test]
    fn retention_ignores_uncertain_or_incoherent_usage_accounting() {
        let mut registry = RetentionRegistry::default();
        registry.record_saved("apc/old/1/hash-old", "old", "m", 10, 1);

        let report = registry.enforce(
            "m",
            RetentionBudget {
                kv_pages_used: 120,
                kv_pages_total: 0,
                ..RetentionBudget::default()
            },
            &[],
        );

        assert!(report.evicted_names.is_empty());
        assert_eq!(report.reason, RetentionReason::SkippedUncertainAccounting);
    }

    #[test]
    fn retention_evicts_inactive_snapshots_by_lru_until_under_pressure() {
        let mut registry = RetentionRegistry::default();
        registry.record_saved("apc/oldest/1/hash-a", "oldest", "m", 8, 1);
        registry.record_saved("apc/middle/1/hash-b", "middle", "m", 9, 2);
        registry.record_saved("apc/recent/1/hash-c", "recent", "m", 25, 3);

        let report = registry.enforce(
            "m",
            RetentionBudget {
                kv_pages_used: 95,
                kv_pages_total: 100,
                evict_percent: 80,
                ..RetentionBudget::default()
            },
            &["apc/recent/1/hash-c"],
        );

        assert_eq!(
            report.evicted_names,
            vec!["apc/oldest/1/hash-a", "apc/middle/1/hash-b"]
        );
        assert_eq!(report.pages_reclaimed, 17);
        assert_eq!(report.protected_active_pages, 25);
        assert_eq!(report.reason, RetentionReason::EvictedPressure);
        assert!(registry.contains("apc/recent/1/hash-c"));
        assert!(!registry.contains("apc/oldest/1/hash-a"));
        assert!(!registry.contains("apc/middle/1/hash-b"));
    }

    #[test]
    fn retention_preserves_recent_compatible_chat_when_one_lru_evict_satisfies_budget() {
        let mut registry = RetentionRegistry::default();
        registry.record_saved("apc/cold/1/hash-a", "cold", "m", 10, 1);
        registry.record_saved("apc/warm/1/hash-b", "warm", "m", 10, 9);

        let report = registry.enforce(
            "m",
            RetentionBudget {
                kv_pages_used: 85,
                kv_pages_total: 100,
                evict_percent: 80,
                ..RetentionBudget::default()
            },
            &[],
        );

        assert_eq!(report.evicted_names, vec!["apc/cold/1/hash-a"]);
        assert!(registry.contains("apc/warm/1/hash-b"));
    }

    #[test]
    fn retention_reports_protected_when_pressure_cannot_be_reclaimed_safely() {
        let mut registry = RetentionRegistry::default();
        registry.record_saved("apc/active/1/hash-a", "active", "m", 40, 1);

        let report = registry.enforce(
            "m",
            RetentionBudget {
                kv_pages_used: 95,
                kv_pages_total: 100,
                evict_percent: 80,
                hard_percent: 90,
                ..RetentionBudget::default()
            },
            &["apc/active/1/hash-a"],
        );

        assert!(report.evicted_names.is_empty());
        assert_eq!(report.protected_active_pages, 40);
        assert_eq!(report.reason, RetentionReason::ProtectedActive);
        assert!(registry.contains("apc/active/1/hash-a"));
    }
}
