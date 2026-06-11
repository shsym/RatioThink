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
//! ## pie save/open semantics (verified against Vendor/pie @ 2e080d8)
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
//! ## Save (next boundary)
//!
//! After a successful natural/length completion the KV holds
//! `prompt_no_cue ‖ cue ‖ gen` (the sampled stop token is never fed back,
//! so it is absent from both `gen` and the KV). The next turn's reusable
//! prefix is `prompt_no_cue ‖ assistant(gen_content)`, which a chat
//! template renders as `cue ‖ retokenize(gen_content) ‖ seal`. We save iff
//! `cue ‖ gen ‖ seal == assistant(gen_content)` — i.e. the generated
//! tokens round-trip through the template exactly. When they do, we append
//! `seal`, flush, and save under the canonical next-prefix name; the saved
//! KV is then *exactly* what the next turn will request. When they don't
//! (round-trip drift, or a thinking model whose reasoning tokens are not
//! replayed into history), we skip the save and the next turn is a clean
//! miss. Either way: never corruption.
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
//!   request carries that key+prefix) — an "explicit miss". Reclaiming the
//!   pages is smart-retention work owned by #524.
//! - **policy = bypass**: never open, never save (privacy / ephemeral).
//!
//! ## Phase 1 / Phase 2 split
//!
//! Phase 1 (this module) is correctness-first: whole-snapshot
//! save/open/delete and explicit miss/rebuild only. No global LRU, no
//! page-pressure eviction, no committed-tail truncation — those wait on
//! #517's authoritative global KV accounting and land in #524.

use serde::{Deserialize, Serialize};

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
}

impl CacheDirective {
    /// Reuse is active only for an `auto` directive with a non-empty key.
    pub fn enabled(&self) -> bool {
        self.policy == Policy::Auto && !self.key.is_empty()
    }
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

/// Stable 128-bit content hash (two independent FNV-1a lanes) rendered as
/// 32 lowercase hex chars. No external crate — deterministic across builds
/// and platforms, which a snapshot name keyed across processes requires.
///
/// The probability that two *different* token sequences collide here is
/// ~2⁻¹²⁸; a collision is the only way a hit could return wrong KV, so the
/// wide digest is deliberate.
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
// Save decision (pure gate)
// =============================================================================

/// Outcome of the post-generation save gate.
#[derive(Debug, PartialEq, Eq)]
pub enum SaveDecision {
    /// The generated turn round-trips through the chat template exactly;
    /// append `seal` and save the canonical next-prefix snapshot.
    Save,
    /// Do not save; the `&'static str` is the diagnostic reason.
    Skip(&'static str),
}

/// Decide whether the just-finished turn can be saved as a reusable
/// boundary. Pure over token vectors so it is exhaustively unit-testable
/// without an engine.
///
/// `cue` / `gen` / `seal` are the generation header, the generated tokens
/// (no stop — pie never feeds the sampled stop back), and the turn-closing
/// tokens. `assistant` is `chat::assistant(model, gen_content)` — how the
/// *next* request will render this turn from its persisted text. They match
/// iff the generated tokens round-trip, which is the exact condition under
/// which the live KV equals the next request's reusable prefix.
pub fn decide_save(cue: &[u32], gen_tokens: &[u32], seal: &[u32], assistant: &[u32]) -> SaveDecision {
    if gen_tokens.is_empty() {
        return SaveDecision::Skip("empty_generation");
    }
    if cue.len() + gen_tokens.len() + seal.len() != assistant.len() {
        return SaveDecision::Skip("noncanonical_generation");
    }
    let matches = assistant[..cue.len()] == *cue
        && assistant[cue.len()..cue.len() + gen_tokens.len()] == *gen_tokens
        && assistant[cue.len() + gen_tokens.len()..] == *seal;
    if matches {
        SaveDecision::Save
    } else {
        SaveDecision::Skip("noncanonical_generation")
    }
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

    // ─── decide_save gate ─────────────────────────────────────

    #[test]
    fn save_when_generation_round_trips() {
        // cue ‖ gen ‖ seal == assistant(gen_content) → safe to save.
        let cue = vec![100u32];
        let gen_tokens = vec![5u32, 6, 7];
        let seal = vec![200u32];
        let assistant = vec![100u32, 5, 6, 7, 200];
        assert_eq!(decide_save(&cue, &gen_tokens, &seal, &assistant), SaveDecision::Save);
    }

    #[test]
    fn skip_when_content_tokens_drift() {
        // Re-tokenizing the decoded text yields different ids than the
        // generated stream (a round-trip failure) → conservative skip,
        // never a corrupt snapshot.
        let cue = vec![100u32];
        let gen_tokens = vec![5u32, 6, 7];
        let seal = vec![200u32];
        let assistant = vec![100u32, 5, 99, 7, 200]; // middle id differs
        assert_eq!(
            decide_save(&cue, &gen_tokens, &seal, &assistant),
            SaveDecision::Skip("noncanonical_generation")
        );
    }

    #[test]
    fn skip_when_length_differs() {
        // Thinking model: reasoning tokens live in the KV/gen but are not
        // replayed into history, so assistant() is shorter → skip.
        let cue = vec![100u32];
        let gen_tokens = vec![5u32, 6, 7, 8, 9];
        let seal = vec![200u32];
        let assistant = vec![100u32, 5, 6, 200];
        assert_eq!(
            decide_save(&cue, &gen_tokens, &seal, &assistant),
            SaveDecision::Skip("noncanonical_generation")
        );
    }

    #[test]
    fn skip_when_generation_empty() {
        let cue = vec![100u32];
        let seal = vec![200u32];
        let assistant = vec![100u32, 200];
        assert_eq!(
            decide_save(&cue, &[], &seal, &assistant),
            SaveDecision::Skip("empty_generation")
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
        assert_eq!(retry_lookup, after_turn1, "retry hits the valid earlier boundary");
        assert_ne!(retry_lookup, after_turn2, "stale suffix boundary is unreachable");
    }

    // ─── directive gating ─────────────────────────────────────

    #[test]
    fn directive_enabled_only_for_auto_with_key() {
        let mut d = CacheDirective {
            key: "c".to_string(),
            turn: 0,
            compat: "1".to_string(),
            policy: Policy::Auto,
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
}
