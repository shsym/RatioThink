//! Transport-independent Best-of-N.
//!
//! Ported from `chat-apc/src/bestofn/` (1,914 lines with the HTTP server and
//! SSE emitter interleaved). Three things change beyond the transport:
//!
//! 1. **Rounds write a `conv/` boundary at commit.** chat-apc's Best-of-N
//!    contains zero `conv/` writes, so a committed round left nothing for the
//!    next chat turn — Best-of-N → chat always fell back to a shorter rung.
//!    See [`commit`].
//! 2. **Candidate names are content-addressed**, so a resume can recompute the
//!    digest and refuse a stale or mismatched `(resume_from, picked_text)`
//!    pair instead of silently opening one candidate while the UI believes it
//!    picked another. See [`resume`].
//! 3. **Deletes are guarded.** chat-apc passed every client-supplied name
//!    straight to `Context::delete`. See [`release`].
//!
//! Generation itself is NOT reimplemented: rounds call
//! `tot_core::search::generate_branch`, the same primitive tree search uses.
//! chat-apc had the identical arrangement, so this is the port rather than a
//! redesign — only the per-candidate divergence directives differ, and those
//! live in [`divergence`] exactly as they did.

pub mod commit;
pub mod divergence;
pub mod release;
pub mod resume;
pub mod round;
pub mod schema;

use gen_core::{GenError, schema::ChatMessage};
use inferlet::{model::Model, runtime};
use ratio_wire::EventSink;
use schema::BestOfNInput;
use serde::Serialize;

/// What the guest returns, tagged so the gateway and the app can tell a
/// generative round from a control op without inspecting shapes.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Outcome {
    Round(round::RoundResult),
    Commit(commit::CommitAck),
    Release(ReleaseAck),
}

#[derive(Debug, Serialize)]
pub struct ReleaseAck {
    pub object: &'static str,
    #[serde(flatten)]
    pub release: release::ReleaseReport,
}

/// Whether this request generates. Control ops return JSON and emit no events,
/// so the gateway must not open an SSE stream for them.
pub fn is_generative(input: &BestOfNInput) -> bool {
    input.commit.is_none() && input.release.as_ref().is_none_or(|r| r.is_empty())
}

/// Resolve and membership-check the model.
///
/// The resolved id is hashed into both the `conv/` boundary name and every
/// candidate digest, so it must be the SAME string chat digests — a trim or
/// case difference silently orphans the boundary and invalidates every resume.
fn resolve_model(requested: Option<&str>) -> Result<(Model, String), GenError> {
    let models = runtime::models();
    let requested = requested.unwrap_or("").trim().to_string();
    let id = if requested.is_empty() {
        models
            .first()
            .cloned()
            .ok_or_else(|| GenError::new("model_not_found", "engine serves no models"))?
    } else {
        requested
    };
    if !models.iter().any(|m| m == &id) {
        return Err(GenError::new(
            "model_not_found",
            format!("model {id:?} is not served by this engine"),
        )
        .with_param("model"));
    }
    let model = Model::load(&id).map_err(|e| GenError::new("model_load_failed", e))?;
    Ok((model, id))
}

fn validate_messages(messages: &[ChatMessage]) -> Result<(), GenError> {
    if messages.is_empty() {
        return Err(
            GenError::new("invalid_request", "messages must not be empty").with_param("messages")
        );
    }
    for (i, m) in messages.iter().enumerate() {
        if let Some(code) = gen_core::prompt::role_error_code(&m.role) {
            return Err(
                GenError::new(code, gen_core::prompt::role_error_message(i, &m.role, code))
                    .with_param(format!("messages[{i}].role")),
            );
        }
    }
    Ok(())
}

/// Dispatch one Best-of-N request.
///
/// Branch order is chat-apc's, and it is load-bearing: the control ops are
/// checked BEFORE any message or generation contract, so a release does not
/// have to satisfy rules that only make sense for a round.
pub async fn run(input: BestOfNInput, sink: &dyn EventSink) -> Result<Outcome, GenError> {
    // ---- 1. commit: save the accepted answer's boundary, THEN free the round
    if let Some(c) = &input.commit {
        let messages = input.messages.clone().unwrap_or_default();
        validate_messages(&messages)?;
        let (model, model_id) = resolve_model(input.model.as_deref())?;
        let directive = input.boundary.clone().unwrap_or_default();
        let ack = commit::run(
            &model,
            &model_id,
            &directive,
            &messages,
            c,
            input.round_id.as_deref(),
        )
        .await?;
        return Ok(Outcome::Commit(ack));
    }

    // ---- 2. release: free a round the user abandoned. No generation.
    if let Some(names) = input.release.as_ref().filter(|n| !n.is_empty()) {
        let (model, _id) = resolve_model(input.model.as_deref())?;
        // A release without a round id has no authorization scope. chat-apc
        // deleted whatever it was handed; the only available fallback here
        // would authorize every round of every chat, so refusing is the honest
        // outcome — the names simply age out.
        let round_id = input
            .round_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                GenError::new(
                    "invalid_request",
                    "round_id is required to release: it is the authorization scope for \
                     the deletes",
                )
                .with_param("round_id")
            })?;
        let mut ops = EngineOps { model: &model };
        let report = release::release_all(&mut ops, names, round_id);
        return Ok(Outcome::Release(ReleaseAck {
            object: "best_of_n.release",
            release: report,
        }));
    }

    // ---- 3. otherwise: a generative round
    let messages = input.messages.clone().unwrap_or_default();
    validate_messages(&messages)?;
    let (model, model_id) = resolve_model(input.model.as_deref())?;
    let params = schema::resolve(&input)
        .map_err(|(field, msg)| GenError::new("invalid_request", msg).with_param(field))?;
    let directive = input.boundary.clone().unwrap_or_default();
    let level = input.level.unwrap_or(1).max(1);

    let is_resume = input
        .resume_from
        .as_deref()
        .is_some_and(|n| !n.trim().is_empty());

    let (base, tokens, entry, resume_info) = if is_resume {
        let round_id = input
            .round_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                GenError::new(
                    "invalid_request",
                    "round_id is required to resume: it is the authorization scope for the \
                     prior round's deletes",
                )
                .with_param("round_id")
            })?;
        // Mandatory, and not merely a nicety: it is what a mismatch rebuilds
        // from, so without it there is no safe fallback.
        let picked_text = input
            .picked_text
            .as_deref()
            .filter(|t| !t.trim().is_empty())
            .ok_or_else(|| {
                GenError::new(
                    "invalid_request",
                    "picked_text is required with resume_from: it is what the base is rebuilt \
                     from when the snapshot was evicted or cannot be verified",
                )
                .with_param("picked_text")
            })?;
        let b = resume::build(
            &model,
            &model_id,
            round_id,
            input.resume_from.as_deref().unwrap_or_default(),
            picked_text,
            input.selected_comment.as_deref(),
            &messages,
            input.unpicked.as_deref().unwrap_or_default(),
        )
        .await?;
        let info = round::ResumeInfo::of(&b);
        (b.ctx, b.tokens, Default::default(), Some(info))
    } else {
        let (ctx, tokens, outcome) =
            round::cold_base(&model, &model_id, &directive, &messages).await?;
        (ctx, tokens, outcome, None)
    };

    // The round id scopes every name it mints, so it is required even on
    // round 1 — a round whose candidates carry no scope could never be
    // released or resumed safely afterwards.
    let round_id = input
        .round_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            GenError::new(
                "invalid_request",
                "round_id is required: it scopes every snapshot this round mints",
            )
            .with_param("round_id")
        })?;

    let pickable = round::run(
        base, &tokens, &params, &model, &model_id, round_id, level, sink,
    )
    .await;

    Ok(Outcome::Round(round::RoundResult {
        model: model_id,
        level,
        n: params.n,
        pickable,
        boundary_found: entry.found,
        reused_tokens: entry.reused_tokens as u32,
        resume: resume_info,
    }))
}

struct EngineOps<'a> {
    model: &'a Model,
}

impl release::ReleaseOps for EngineOps<'_> {
    fn delete_snapshot(&mut self, name: &str) -> bool {
        inferlet::Context::delete(self.model, name).is_ok()
    }
}
