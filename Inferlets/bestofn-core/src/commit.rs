//! The §6.2 commit operation.
//!
//! ## Why it has to exist
//!
//! A generation process cannot know which candidate becomes the answer — the
//! user picks, minutes later, in the app. And chat-apc's terminal request
//! carries only `{model, release: [names]}` (`bestofn/release.rs`), with no
//! messages, no boundary directive and no answer. `Inferlets/chat-apc/src/
//! bestofn/` contains **zero** `conv/` writes; its only `Context::save` is
//! `save_candidate_snapshot` under `bon/`. So a committed Best-of-N round left
//! nothing for the next chat turn to reuse, and Best-of-N → chat would fall
//! back to a shorter ladder rung — contradicting both "entry and exit" and
//! "final answer only".
//!
//! Commit is where the accepted answer becomes a durable `conv/` boundary.
//!
//! ## Ordering, and the one place it must not be best-effort
//!
//! ```text
//! validate            (nothing mutated yet — every failure is an HTTP status)
//! open_canonical
//! save_boundary       <- MUST have actually landed
//! release round KV    <- only then
//! acknowledge         <- the ack IS the return value, so it cannot precede either
//! ```
//!
//! `run_tot` makes its save best-effort and logs on failure, because there the
//! save is a cache optimization: losing it costs the next turn a re-prefill.
//! Here it is the entire purpose of the operation AND the release that follows
//! is irreversible — the candidate snapshots are the only recovery state. So
//! commit diverges deliberately: a save that did not land aborts before
//! anything is deleted, and the client keeps its snapshots for a retry.
//!
//! That gate is only meaningful because `save_boundary` now reports what
//! landed. Its `Result` does not: it returns `Err` for fork/flush faults only,
//! while `save_one` swallows every `ctx.save` error, and the whole function
//! short-circuits to `Ok` when reuse is disabled. Gating a destructive release
//! on `save_boundary(...).await?` would free the round's KV after writing
//! nothing — which is why [`gen_core::boundary::SaveOutcome`] exists.

use gen_core::boundary::{self, BoundaryDirective};
use gen_core::{GenError, schema::ChatMessage};
use inferlet::{Context, model::Model};
use ratio_names::may_delete;
use serde::{Deserialize, Serialize};

use crate::release::{ReleaseOps, ReleaseReport, release_all};
use crate::schema::CommitInput;

/// What the client gets back. Not an OpenAI object — the gateway owns those.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitAck {
    pub object: &'static str,
    /// The RESOLVED model id whose tokens were hashed into the boundary name.
    pub model: String,
    /// Whether the boundary the next chat turn will look for actually landed.
    /// When false, nothing was deleted.
    pub boundary_saved: bool,
    #[serde(flatten)]
    pub release: ReleaseReport,
}

struct EngineRelease<'a> {
    model: &'a Model,
}

impl ReleaseOps for EngineRelease<'_> {
    fn delete_snapshot(&mut self, name: &str) -> bool {
        // Reached ONLY for names `may_delete` has already authorized.
        Context::delete(self.model, name).is_ok()
    }
}

/// Validate the commit payload. Split out so the rules are host-testable
/// without an engine — they are the destructive path's entire safety story.
pub fn validate(
    commit: &CommitInput,
    round_id: Option<&str>,
    messages: &[ChatMessage],
) -> Result<(String, String, String), GenError> {
    if messages.is_empty() {
        return Err(GenError::new("invalid_request", "messages must not be empty")
            .with_param("messages"));
    }
    let round_id = round_id
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            // Without a round id there is no authorization scope, and the only
            // available fallback — "does it look like a bon/ name" — authorizes
            // every round of every chat. Refusing is the honest outcome.
            GenError::new(
                "invalid_request",
                "round_id is required to commit: it is the authorization scope for \
                 the round's snapshot deletes",
            )
            .with_param("round_id")
        })?
        .to_string();

    let snapshot_name = commit
        .snapshot_name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            GenError::new("invalid_request", "commit.snapshot_name is required")
                .with_param("commit.snapshot_name")
        })?
        .to_string();

    // The selected candidate must be one this round minted. This is an
    // authorization check, not a formatting one — hence a hard 400 rather than
    // a degrade.
    may_delete(&snapshot_name, &round_id).map_err(|_| {
        GenError::new(
            "snapshot_not_in_round",
            format!("{snapshot_name:?} was not minted by round {round_id:?}"),
        )
        .with_param("commit.snapshot_name")
    })?;

    let answer = commit
        .answer
        .as_deref()
        .filter(|a| !a.trim().is_empty())
        .ok_or_else(|| {
            // The boundary is `messages + assistant(answer)`. A blank answer
            // would name a boundary the next turn never asks for.
            GenError::new(
                "invalid_request",
                "commit.answer is required: the boundary is built from it, and it must be \
                 byte-identical to the text persisted as the assistant message",
            )
            .with_param("commit.answer")
        })?
        .to_string();

    Ok((round_id, snapshot_name, answer))
}

/// Run one commit. `model_id` must be the resolved, membership-checked id — it
/// is hashed into the boundary name, so a trim or case difference from what
/// chat digests silently orphans the boundary.
pub async fn run(
    model: &Model,
    model_id: &str,
    directive: &BoundaryDirective,
    messages: &[ChatMessage],
    commit: &CommitInput,
    round_id: Option<&str>,
) -> Result<CommitAck, GenError> {
    let (round_id, _snapshot_name, answer) = validate(commit, round_id, messages)?;

    let canonical = boundary::open_canonical(model, model_id, directive, messages).await?;
    let outcome = boundary::save_boundary(&canonical, model, model_id, directive, &answer).await?;

    // THE GATE. `full_saved` is the history+answer boundary — the one the next
    // turn's ladder actually hits. Nothing is deleted unless it landed.
    if !outcome.full_saved {
        return Ok(CommitAck {
            object: "best_of_n.commit",
            model: model_id.to_string(),
            boundary_saved: false,
            release: ReleaseReport { requested: commit.release.len(), ..Default::default() },
        });
    }

    let mut ops = EngineRelease { model };
    let release = release_all(&mut ops, &commit.release, &round_id);

    Ok(CommitAck {
        object: "best_of_n.commit",
        model: model_id.to_string(),
        boundary_saved: true,
        release,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratio_names::SnapshotName;

    fn msgs() -> Vec<ChatMessage> {
        serde_json::from_value(serde_json::json!([{"role": "user", "content": "hi"}])).unwrap()
    }

    fn name(round: &str) -> String {
        SnapshotName::bon_candidate(round, 1, 0, "qwen", &[1, 2], "picked")
            .as_str()
            .to_string()
    }

    fn input(round: &str) -> CommitInput {
        CommitInput {
            snapshot_name: Some(name(round)),
            answer: Some("picked".into()),
            release: vec![name(round)],
        }
    }

    #[test]
    fn a_well_formed_commit_validates() {
        let (r, n, a) = validate(&input("r1"), Some("r1"), &msgs()).unwrap();
        assert_eq!(r, "r1");
        assert_eq!(n, name("r1"));
        assert_eq!(a, "picked");
    }

    /// Without a round id there is no authorization scope at all, and the only
    /// available fallback would authorize every round of every chat.
    #[test]
    fn a_commit_without_a_round_id_is_refused() {
        let e = validate(&input("r1"), None, &msgs()).unwrap_err();
        assert_eq!(e.param.as_deref(), Some("round_id"));
    }

    /// The selected candidate must be one THIS round minted.
    #[test]
    fn committing_another_rounds_candidate_is_refused() {
        let e = validate(&input("their-round"), Some("my-round"), &msgs()).unwrap_err();
        assert_eq!(e.code, "snapshot_not_in_round");
        assert_eq!(e.param.as_deref(), Some("commit.snapshot_name"));
    }

    /// A `conv/` name in the selected slot must not be able to reach the
    /// release path at all.
    #[test]
    fn a_conv_name_cannot_be_the_selected_candidate() {
        let victim = SnapshotName::conv("other-chat", "1", "qwen", &[1]).as_str().to_string();
        let c = CommitInput {
            snapshot_name: Some(victim),
            answer: Some("x".into()),
            release: vec![],
        };
        assert_eq!(validate(&c, Some("r1"), &msgs()).unwrap_err().code, "snapshot_not_in_round");
    }

    #[test]
    fn a_blank_answer_is_refused() {
        let mut c = input("r1");
        c.answer = Some("   ".into());
        assert_eq!(validate(&c, Some("r1"), &msgs()).unwrap_err().param.as_deref(), Some("commit.answer"));
    }

    #[test]
    fn empty_messages_are_refused() {
        assert_eq!(
            validate(&input("r1"), Some("r1"), &[]).unwrap_err().param.as_deref(),
            Some("messages")
        );
    }

    /// The ack must reconcile: a failed save reports zero of everything, so a
    /// client can tell "nothing happened" from "freed some".
    #[test]
    fn a_failed_save_reports_nothing_released() {
        let ack = CommitAck {
            object: "best_of_n.commit",
            model: "qwen".into(),
            boundary_saved: false,
            release: ReleaseReport { requested: 5, ..Default::default() },
        };
        let v = serde_json::to_value(&ack).unwrap();
        assert_eq!(v["boundary_saved"], serde_json::json!(false));
        assert_eq!(v["requested"], serde_json::json!(5));
        assert_eq!(v["released"], serde_json::json!(0));
    }
}
