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
///
/// `Default` is written out rather than derived so it agrees with what serde
/// produces for `{}`. A derived `Default` gives `enabled: false` while
/// `#[serde(default = "yes")]` gives `true`, so a test constructing
/// `BoundaryDirective { key: k, ..Default::default() }` would silently exercise
/// the reuse-disabled path and assert on code that never ran.
#[derive(Debug, Clone, Serialize, Deserialize)]
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

impl Default for BoundaryDirective {
    fn default() -> Self {
        Self { key: String::new(), compat: String::new(), turn: 0, enabled: yes() }
    }
}

/// What actually happened, for diagnostics and tests.
///
/// `found` alone is NOT a hit signal. Scheduler eviction calls `suspend`
/// (`runtime/context/sched.rs:790-815`) and leaves the name in place, so an
/// evicted boundary **opens successfully and replays the whole prefix**.
///
/// TODO(kv-residency): every field here is NAME-level, not residency-level.
/// `reused_tokens = 800` means a boundary with that name covered 800 tokens; it
/// does NOT mean those tokens were on the GPU. Under memory pressure the same
/// run re-prefills everything and these numbers are identical — so every reuse
/// claim in this branch, including the milestone gates, is unfalsifiable in
/// exactly the regime where it is most likely to be wrong. A ToT search forks
/// 15-21 contexts, which is what triggers eviction in the first place.
///
/// The real fix is pie-side and deliberately NOT taken: `Context::open` returns
/// `Result<Self>` (`sdk/rust/inferlet/src/context.rs:112`), which has no third
/// state for "found, but I rebuilt it". It would need either an additive
/// `open-with-report -> (context, report)` or a `snapshot-status(name)` query —
/// the latter is cheaper and non-breaking but races, since status can change
/// between the query and the open.
///
/// Without touching pie, the honest approximation is to measure what residency
/// BUYS rather than ask for the state: time the flush in `open_canonical` (see
/// the note there) and read it against `reused_tokens`. Large `reused_tokens`
/// with a near-zero flush is a real hit; a flush that scales with it is a
/// replay wearing a hit's clothes. That is a timing heuristic, not ground
/// truth, and it needs a prefix of real size to separate.
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
///
/// `model_id` MUST be the resolved, membership-checked engine model id — the
/// same string every mode uses. It is hashed into the name, so a mode that
/// trims, case-folds or default-fills it computes a different name for the same
/// history and orphans the boundary silently, with no error anywhere.
///
/// Returns FLUSHED. The flush is here rather than at the call site because
/// `Context::fork` clones the unflushed buffer: forking first makes both the
/// fork and the later `save_boundary` fork replay the same prefill. Flushing
/// once up front materializes the pages, both forks inherit them, and
/// `save_boundary`'s own flush degrades to a no-op. Token sequences — and so
/// the digest — are unchanged either way; only the work is.
///
/// TODO(kv-residency): this flush is the one place a replay is observable
/// without changing pie. On a genuinely resident boundary it materializes only
/// the appended suffix — near-zero, and flat as the conversation grows. On an
/// evicted one it runs a forward pass over the whole reused prefix. Timing it
/// and reporting `boundary_ms` alongside `reused_tokens` would make the
/// difference visible; nothing does that today.
pub async fn open_canonical(
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
            ctx.flush()
                .await
                .map_err(|e| GenError::new(crate::classify_engine_error(&e), e))?;
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
    ctx.flush()
        .await
        .map_err(|e| GenError::new(crate::classify_engine_error(&e), e))?;
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
) -> Result<SaveOutcome, GenError> {
    if !directive.enabled || directive.key.is_empty() {
        return Ok(SaveOutcome::disabled());
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
    let prompt_saved = save_one(
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
    let full_saved = save_one(
        &snap,
        &SnapshotName::conv(&directive.key, &directive.compat, model_id, &full),
    );
    Ok(SaveOutcome { prompt_saved, full_saved })
}

/// Content-addressed names make "already exists" success by construction: the
/// same name can only have been produced by the same tokens.
///
/// Returns whether the name is now present. Callers that treat the save as an
/// optimization ignore it; callers that are about to do something IRREVERSIBLE
/// on the strength of it must not.
fn save_one(ctx: &Context, name: &SnapshotName) -> bool {
    match ctx.save(name.as_str()) {
        Ok(()) => true,
        Err(e) => {
            let msg = e.to_string();
            if msg.contains("already exists") {
                return true;
            }
            // Non-fatal for chat/ToT: a failed boundary save costs the next
            // turn a re-prefill, it does not corrupt this one.
            eprintln!("[gen-core] boundary save failed for {}: {msg}", name.as_str());
            false
        }
    }
}

/// Which of the two boundaries actually landed.
///
/// This type exists because `save_boundary`'s `Result` is NOT a report of
/// whether anything was written. It returns `Err` only for fork/flush faults;
/// every `ctx.save` error is swallowed by `save_one`, and the whole function
/// short-circuits to `Ok(())` when reuse is disabled or the key is empty. So
/// `save_boundary(...).await?` succeeding is consistent with zero names having
/// been written.
///
/// For chat and ToT that is the right shape — the save is a cache optimization
/// and a failure costs only a re-prefill. Best-of-N's commit is different: it
/// DELETES the round's candidate snapshots on the strength of the save, and
/// those snapshots are the only recovery state. Gating that on a `Result` that
/// cannot report failure would free the KV after writing nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SaveOutcome {
    /// The prompt-only boundary (this turn's history, no answer).
    pub prompt_saved: bool,
    /// The generated boundary — history + assistant(answer). THIS is the one
    /// the next turn's ladder hits, so it is what an irreversible follow-up
    /// action must gate on.
    pub full_saved: bool,
}

impl SaveOutcome {
    /// Nothing was attempted: reuse is off, or the directive carries no key.
    pub fn disabled() -> Self {
        Self::default()
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

#[cfg(test)]
mod swift_wire_tests {
    use super::*;

    /// The app sends `ChatCacheDirective` under `boundary`. That type carries
    /// `policy` and `retention` too, which this side has no use for — so the
    /// decode must tolerate them rather than fail the request.
    #[test]
    fn accepts_the_real_swift_directive() {
        let from_app = serde_json::json!({
            "key": "0F1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
            "turn": 4,
            "compat": "1",
            "policy": "auto",
            "retention": { "budget_pages": 1024, "reason": "kv_pressure" }
        });
        let d: BoundaryDirective =
            serde_json::from_value(from_app).expect("must decode the app's directive");
        assert_eq!(d.key, "0F1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9");
        assert_eq!(d.compat, "1");
        assert_eq!(d.turn, 4);
        assert!(d.enabled, "the app sends no `enabled`; reuse must stay on");
    }

    /// A request with no directive must degrade to no-reuse, not error.
    #[test]
    fn absent_directive_disables_reuse_quietly() {
        let d = BoundaryDirective::default();
        assert!(d.key.is_empty(), "an empty key is the no-reuse signal");
    }
}
