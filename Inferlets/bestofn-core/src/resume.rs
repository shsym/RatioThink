//! Think-more: resume from the candidate the user picked.
//!
//! ## What chat-apc validated: nothing
//!
//! `resume_base_with` deletes the unpicked siblings, calls `ops.open(picked)`,
//! and uses whatever comes back (`bestofn/mod.rs:662-696`). The name is
//! positional — `bon/{request_id}/{level}/{idx}` — so it says nothing about
//! WHICH candidate's KV it holds. A stale or mismatched
//! `(resume_from, picked_text)` pair therefore opens one candidate while the UI
//! believes it picked another, and the round continues from the wrong answer
//! with no error anywhere.
//!
//! Content-addressed names close that: the digest binds the name to
//! `(base_tokens, answer, model)`, so the guest can RECOMPUTE it from
//! `picked_text` and compare.
//!
//! ## A mismatch degrades; it does not 400
//!
//! This was a deliberate choice against the obvious one. The digest covers the
//! canonical prompt tokens, which include the system turn — and the app
//! recomputes `systemPromptOverride` from the live profile store at think-more
//! time. A user editing their system prompt between picking and thinking more
//! is benign, invisible, and would turn a working round into a hard failure.
//!
//! Rejecting also buys nothing, because the safe path already exists and is
//! mandatory: `picked_text` is required precisely so the base can be rebuilt
//! when the snapshot was evicted during the pick. A mismatch takes that same
//! cold path. Neither branch ever serves unverified KV — the difference is only
//! whether we pay a re-prefill.
//!
//! `OutOfRound` is different and IS a 400: a name from another round is an
//! authorization signal, not drift.

use gen_core::schema::{ChatMessage, CueMode};
use gen_core::{GenError, classify_engine_error, prompt};
use inferlet::{Context, chat, model::Model};
use ratio_names::{DeleteRefusal, bon_digest, may_delete, parse_bon_candidate};

use crate::release::{ReleaseOps, release_all};

/// Why a resume did or did not warm-start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumeKind {
    /// The digest matched and the snapshot opened.
    Warm,
    /// The digest matched but the snapshot was gone (evicted during the pick).
    ColdEvicted,
    /// The digest did not match `picked_text` — the pair is stale or the
    /// history drifted. Rebuilt rather than trusted.
    ColdMismatch,
}

pub struct ResumeBase {
    pub ctx: Context,
    /// Canonical tokens of the conversation prefix, for the next round's
    /// candidate names.
    pub tokens: Vec<u32>,
    pub kind: ResumeKind,
    pub deleted: usize,
    pub refused: usize,
}

/// Recompute the candidate name's digest from the text the client says it
/// picked. `true` means the pair is coherent.
///
/// Pure, so the check itself is host-testable — it is the entire difference
/// between resuming the right candidate and silently resuming another.
pub fn digest_matches(
    snapshot_name: &str,
    model_id: &str,
    base_tokens: &[u32],
    picked_text: &str,
) -> bool {
    match parse_bon_candidate(snapshot_name) {
        Some(p) => p.digest == bon_digest(model_id, base_tokens, picked_text),
        None => false,
    }
}

struct EngineRelease<'a> {
    model: &'a Model,
}

impl ReleaseOps for EngineRelease<'_> {
    fn delete_snapshot(&mut self, name: &str) -> bool {
        Context::delete(self.model, name).is_ok()
    }
}

/// Build the base a think-more round forks from.
///
/// ORDER is preserved from chat-apc:
/// 1. free the unpicked siblings (deterministic, best-effort),
/// 2. warm-start from the pick or rebuild cold,
/// 3. append the deepen turn,
/// 4. free the picked snapshot — we hold a live fork and will save fresh ones.
#[allow(clippy::too_many_arguments)]
pub async fn build(
    model: &Model,
    model_id: &str,
    round_id: &str,
    picked: &str,
    picked_text: &str,
    selected_comment: Option<&str>,
    messages: &[ChatMessage],
    unpicked: &[String],
) -> Result<ResumeBase, GenError> {
    // Authorization first, before anything is freed. A name from another round
    // is a hard error, unlike a digest mismatch.
    may_delete(picked, round_id).map_err(|why| {
        let msg = match why {
            DeleteRefusal::Unparseable => "resume_from is not a digest-named candidate",
            DeleteRefusal::WrongRound => "resume_from belongs to a different round",
        };
        GenError::new("snapshot_not_in_round", msg).with_param("resume_from")
    })?;

    // The canonical tokens the pick's digest was computed over. Built directly
    // rather than through `open_canonical`: on the warm path we never use its
    // context, and materializing a second full copy of the conversation KV at
    // the moment of peak residency is exactly the wrong trade.
    let tokens = prompt::build_prompt_tokens(model, messages, CueMode::None)
        .map_err(|(c, m)| GenError::new(c, m))?;

    // 1. Free the siblings the user did not pick. Guarded, so a client cannot
    //    smuggle another round's name — or a `conv/` boundary — into the list.
    let mut ops = EngineRelease { model };
    let sib = release_all(&mut ops, unpicked, round_id);

    // 2. Warm-start only if the pick is provably the candidate whose text we
    //    were given.
    let verified = digest_matches(picked, model_id, &tokens, picked_text);
    let (mut ctx, kind) = if verified {
        match Context::open(model, picked) {
            Ok(c) => (c, ResumeKind::Warm),
            Err(_) => (cold(model, &tokens, picked_text)?, ResumeKind::ColdEvicted),
        }
    } else {
        eprintln!(
            "[bestofn] resume digest mismatch for {picked:?} — rebuilding from picked_text \
             rather than opening a snapshot we cannot prove is the picked candidate"
        );
        (cold(model, &tokens, picked_text)?, ResumeKind::ColdMismatch)
    };

    // 3. Deepen turn for the next level, plus any user guidance.
    let mut deepen = String::from(
        "Continue from the reply above. Produce a better, complete, standalone answer.",
    );
    if let Some(c) = selected_comment.map(str::trim).filter(|c| !c.is_empty()) {
        deepen.push(' ');
        deepen.push_str(c);
    }
    ctx.append(&chat::user(model, &deepen));

    // The base is forked n times for generation and n times again for the
    // candidate snapshots, so an unflushed suffix would replay `picked_text` +
    // the deepen turn 2n times. chat-apc flushed here for the same reason.
    ctx.flush()
        .await
        .map_err(|e| GenError::new(classify_engine_error(&e), e))?;

    // 4. The named pick is now redundant — we hold a live fork of it. Free it
    //    on every path where it might still exist, not only the warm one: on a
    //    mismatch the snapshot is real and openable, just not provably the
    //    right one, and skipping the delete would leak it with no later owner
    //    (the app drops the round from its sweep once the answer is committed).
    let picked_freed = if matches!(kind, ResumeKind::ColdEvicted) {
        0 // already gone; that is why we are cold
    } else {
        release_all(&mut ops, &[picked.to_string()], round_id).released
    };

    Ok(ResumeBase {
        ctx,
        tokens,
        kind,
        deleted: sib.released + picked_freed,
        refused: sib.refused,
    })
}

/// Rebuild the base from the client's `picked_text` with no snapshot at all.
fn cold(model: &Model, tokens: &[u32], picked_text: &str) -> Result<Context, GenError> {
    let mut ctx = Context::new(model).map_err(|e| GenError::new(classify_engine_error(&e), e))?;
    ctx.append(tokens);
    ctx.append(&chat::assistant(model, picked_text));
    Ok(ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratio_names::SnapshotName;

    fn name(round: &str, tokens: &[u32], answer: &str) -> String {
        SnapshotName::bon_candidate(round, 1, 0, "qwen", tokens, answer)
            .as_str()
            .to_string()
    }

    #[test]
    fn a_coherent_pair_verifies() {
        let n = name("r1", &[1, 2, 3], "the picked answer");
        assert!(digest_matches(&n, "qwen", &[1, 2, 3], "the picked answer"));
    }

    /// The bug this exists to stop: the client says it picked one text, but the
    /// name encodes another. chat-apc would have opened it regardless.
    #[test]
    fn a_stale_pair_does_not_verify() {
        let n = name("r1", &[1, 2, 3], "candidate A");
        assert!(!digest_matches(&n, "qwen", &[1, 2, 3], "candidate B"));
    }

    /// Drift in the conversation prefix (an edited system prompt, changed
    /// attachment text) also fails to verify — which is why the response is to
    /// rebuild rather than to reject.
    #[test]
    fn drifted_history_does_not_verify() {
        let n = name("r1", &[1, 2, 3], "answer");
        assert!(!digest_matches(&n, "qwen", &[9, 9, 9], "answer"));
    }

    #[test]
    fn a_different_model_does_not_verify() {
        let n = name("r1", &[1], "answer");
        assert!(!digest_matches(&n, "llama", &[1], "answer"));
    }

    #[test]
    fn a_legacy_positional_name_never_verifies() {
        assert!(!digest_matches("bon/bon-0/1/0", "qwen", &[1], "answer"));
    }

    #[test]
    fn a_conv_name_never_verifies() {
        let victim = SnapshotName::conv("other", "1", "qwen", &[1]).as_str().to_string();
        assert!(!digest_matches(&victim, "qwen", &[1], "answer"));
    }

    /// Every cold path is still a usable round, so a mismatch costs a
    /// re-prefill rather than the turn.
    #[test]
    fn both_cold_kinds_are_distinguishable_from_warm() {
        assert_ne!(ResumeKind::ColdMismatch, ResumeKind::Warm);
        assert_ne!(ResumeKind::ColdEvicted, ResumeKind::Warm);
        assert_ne!(ResumeKind::ColdEvicted, ResumeKind::ColdMismatch);
    }
}
