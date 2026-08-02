//! Cross-mode KV reuse: open the previous turn's canonical boundary, and leave
//! this turn's behind.
//!
//! Ported from `chat-apc/src/chat/prefix_cache.rs` (`plan` :714-765,
//! `finalize` :903-950) with three deliberate corrections:
//!
//! 1. **Names come from `ratio-names`**, so every mode computes the same name
//!    for the same history. chat-apc folds a per-crate `CARGO_PKG_VERSION` into
//!    its marker, which makes cross-inferlet reuse structurally impossible.
//! 2. **`open` verifies `full.starts_with(prefix)`.** The reference compares
//!    LENGTHS only (`prefix_cache.rs:781`), which admits a same-length but
//!    different prefix — i.e. another conversation's KV.
//! 3. **The canonical context is kept, never reconstructed.** Callers generate
//!    on a *fork* and save from the untouched canonical one, so cue, reasoning
//!    and branch tokens can never leak into a boundary.
//!
//! ## The canonical shape
//!
//! A boundary always holds `build_prompt_tokens(messages, CueMode::None)` —
//! no cue, no `/no_think`, no per-branch directive. Anything mode-specific is
//! appended *after* the fork. That is what lets a ToT turn and a chat turn
//! agree on a name.

use crate::schema::{ChatMessage, CueMode};
use crate::{GenError, prompt};
use inferlet::{Context, chat, model::Model};
use ratio_names::SnapshotName;
use serde::{Deserialize, Serialize};

/// How far back to look for a usable boundary when the exact one is absent.
/// Matches chat-apc's `LADDER_DEPTH`.
const LADDER_DEPTH: usize = 4;

/// Conversation identity plus caching policy, carried on every generative
/// request. Top-level rather than per-inferlet: ToT and Best-of-N could not
/// name a boundary at all without it.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BoundaryDirective {
    /// Opaque conversation id. Hashed into the name, never interpolated raw.
    pub key: String,
    /// Bumped by the client to deliberately orphan prior KV.
    #[serde(default)]
    pub compat: String,
    #[serde(default)]
    pub turn: u32,
    /// `false` disables reuse for this turn without changing the wire shape.
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn yes() -> bool {
    true
}

/// What actually happened, for diagnostics and tests.
///
/// `found` alone is NOT a hit signal. Scheduler eviction calls `suspend`
/// (`runtime/context/sched.rs:790-815`) and leaves the name in place, so an
/// evicted boundary **opens successfully and replays the whole prefix**. Until
/// pie surfaces residency, `reused_tokens` is what a test should assert on —
/// and a replay is invisible here, which is why the observability addition is
/// tracked separately.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpenOutcome {
    pub found: bool,
    /// Tokens the opened boundary covered.
    pub reused_tokens: usize,
    /// Tokens we had to append on top.
    pub appended_tokens: usize,
    /// True when the exact boundary was used rather than a ladder rung.
    pub exact: bool,
}

impl OpenOutcome {
    pub fn cold(total: usize) -> Self {
        Self { found: false, reused_tokens: 0, appended_tokens: total, exact: false }
    }
}

/// A context parked at exactly the canonical prompt, plus the tokens it holds.
///
/// Generate on a **fork** of `ctx`; keep this one untouched so the exit save
/// cannot pick up cue or generation tokens.
pub struct Canonical {
    pub ctx: Context,
    pub tokens: Vec<u32>,
    pub outcome: OpenOutcome,
}

/// Candidate boundaries, longest first: the exact prompt, then progressively
/// shorter message prefixes.
fn ladder(
    model: &Model,
    directive: &BoundaryDirective,
    model_id: &str,
    messages: &[ChatMessage],
) -> Vec<(Vec<u32>, SnapshotName)> {
    let mut out = Vec::new();
    let deepest = messages.len();
    let shallowest = deepest.saturating_sub(LADDER_DEPTH);
    for cut in (shallowest..=deepest).rev() {
        let Ok(tokens) = prompt::build_prompt_tokens(model, &messages[..cut], CueMode::None) else {
            continue;
        };
        if tokens.is_empty() {
            continue;
        }
        let name = SnapshotName::conv(&directive.key, &directive.compat, model_id, &tokens);
        out.push((tokens, name));
    }
    out
}

/// Entry half: a context holding the canonical prompt, reusing a saved
/// boundary when one is available.
pub fn open_canonical(
    model: &Model,
    model_id: &str,
    directive: &BoundaryDirective,
    messages: &[ChatMessage],
) -> Result<Canonical, GenError> {
    let canonical = prompt::build_prompt_tokens(model, messages, CueMode::None)
        .map_err(|(c, m)| GenError::new(c, m))?;

    if directive.enabled && !directive.key.is_empty() {
        for (prefix, name) in ladder(model, directive, model_id, messages) {
            let Ok(mut ctx) = Context::open(model, name.as_str()) else {
                continue;
            };
            // THE CHECK the reference omits. A length-only comparison would
            // accept a same-length prefix from another conversation and serve
            // its KV as ours.
            if !canonical.starts_with(&prefix) {
                continue;
            }
            let suffix = &canonical[prefix.len()..];
            if !suffix.is_empty() {
                ctx.append(suffix);
            }
            return Ok(Canonical {
                ctx,
                outcome: OpenOutcome {
                    found: true,
                    reused_tokens: prefix.len(),
                    appended_tokens: suffix.len(),
                    exact: prefix.len() == canonical.len(),
                },
                tokens: canonical,
            });
        }
    }

    let mut ctx = Context::new(model).map_err(|e| GenError::new("context_failed", e))?;
    ctx.append(&canonical);
    Ok(Canonical {
        outcome: OpenOutcome::cold(canonical.len()),
        tokens: canonical,
        ctx,
    })
}

/// Exit half: leave both canonical boundaries for the next turn, whatever mode
/// runs it.
///
/// `canonical` must be the untouched context from [`open_canonical`]. It is
/// forked, not consumed.
///
/// ORDERING: callers must complete this **before** emitting their terminal
/// event. A client that sees the terminal frame may issue the next request
/// immediately and race the save.
pub async fn save_boundary(
    canonical: &Canonical,
    model: &Model,
    model_id: &str,
    directive: &BoundaryDirective,
    answer: &str,
) -> Result<(), GenError> {
    if !directive.enabled || directive.key.is_empty() {
        return Ok(());
    }

    let mut snap = canonical
        .ctx
        .fork()
        .map_err(|e| GenError::new("boundary_fork_failed", e))?;

    // `save` cannot capture an unflushed buffer, so a save without a preceding
    // flush parks a snapshot shorter than its name claims — i.e. a name that
    // lies about its contents.
    snap.flush()
        .await
        .map_err(|e| GenError::new("boundary_flush_failed", e))?;
    save_one(
        &snap,
        &SnapshotName::conv(&directive.key, &directive.compat, model_id, &canonical.tokens),
    );

    // The generated boundary: what the NEXT turn's history will hash to, given
    // the client persists and resends exactly this visible answer.
    let assistant = chat::assistant(model, answer);
    let mut full = canonical.tokens.clone();
    full.extend_from_slice(&assistant);
    snap.append(&assistant);
    snap.flush()
        .await
        .map_err(|e| GenError::new("boundary_flush_failed", e))?;
    save_one(
        &snap,
        &SnapshotName::conv(&directive.key, &directive.compat, model_id, &full),
    );
    Ok(())
}

/// Content-addressed names make "already exists" success by construction: the
/// same name can only have been produced by the same tokens.
fn save_one(ctx: &Context, name: &SnapshotName) {
    if let Err(e) = ctx.save(name.as_str()) {
        let msg = e.to_string();
        if !msg.contains("already exists") {
            // Non-fatal: a failed boundary save costs the next turn a
            // re-prefill, it does not corrupt this one.
            eprintln!("[gen-core] boundary save failed for {}: {msg}", name.as_str());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directive_defaults_to_enabled() {
        let d: BoundaryDirective = serde_json::from_value(serde_json::json!({"key": "c1"})).unwrap();
        assert!(d.enabled, "omitting `enabled` must not silently disable reuse");
        assert_eq!(d.compat, "");
    }

    #[test]
    fn directive_can_disable_without_changing_shape() {
        let d: BoundaryDirective =
            serde_json::from_value(serde_json::json!({"key": "c1", "enabled": false})).unwrap();
        assert!(!d.enabled);
    }

    #[test]
    fn cold_outcome_reports_everything_as_appended() {
        let o = OpenOutcome::cold(120);
        assert!(!o.found && !o.exact);
        assert_eq!((o.reused_tokens, o.appended_tokens), (0, 120));
    }

    /// The guard that distinguishes reuse from serving another conversation's
    /// KV. Same length, different content, must be rejected.
    #[test]
    fn same_length_different_prefix_is_not_a_prefix() {
        let canonical = vec![1u32, 2, 3, 4];
        let impostor = vec![9u32, 9, 9];
        assert!(!canonical.starts_with(&impostor));
        assert!(canonical.starts_with(&[1u32, 2, 3]));
    }
}
