//! Interactive Best-of-N (#690) — a chat mode where the **user** is the
//! judge, distinct from the tree-of-thought value-scorer auto-select.
//!
//! One round forks `n` sibling candidates off a shared, flushed base context,
//! generates them concurrently (co-batched, #465/#650), streams all `n` per
//! node id, and returns WITHOUT scoring or selecting — it emits a terminal
//! `awaiting_selection` so the app can show the panes and let the user pick
//! one (and choose think-more vs stop). Each answered candidate's KV is saved
//! as a named snapshot so a later think-more round can resume from the pick.
//!
//! It reuses the tree-of-thought single-candidate generation primitive
//! ([`crate::tot::branch::generate_branch`]) and streaming sink, but owns its
//! own round loop — it never enters the beam-search / scoring / synthesis
//! machinery. `thinking` is off by default so a round does not ride the open
//! thinking-ON ToT crash path (#679).
//!
//! ## Round model
//!
//! - **Round 1** (no `resume_from`): build the base from `messages`, fork `n`,
//!   generate + stream, save each, emit `awaiting_selection{level:1}`.
//! - **Think-more round** (`resume_from` set): delete the unpicked siblings'
//!   snapshots (deterministic free), warm-start the base from the picked
//!   snapshot, append a deepen instruction, fork `n` at the next level. Idle
//!   snapshots have **no durable guest pin** and are LRU-evictable during a
//!   slow pick (see [`crate::tot::branch`] / the pie guest boundary), so an
//!   `open()` MISS is load-bearing: it falls back to re-prefilling the base
//!   from `messages` + the picked candidate's text.
//!
//! ## Resumable snapshots are reconstructed, not raw
//!
//! A candidate's snapshot is built as `base.fork()` + a template-rendered
//! `assistant(answer)` turn (which seals the turn), NOT the raw generation
//! context. This (a) closes the assistant turn so a later round can append a
//! new user turn cleanly, (b) keeps the per-branch search directive out of the
//! resumed history, and (c) makes the warm-start snapshot byte-equivalent to
//! the re-prefill fallback at every level — the same prefix-cache pattern
//! `chat::prefix_cache::finalize` uses.

use futures::future::join_all;
use futures::lock::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use wstd::http::server::{Finished, Responder};

use inferlet::Context;
use inferlet::model::Model;

use crate::chat::completions::{self, ChatMessage};
use crate::sse::{self, Emitter};
use crate::tot::branch::{
    self, emit_level, emit_tree_start, generate_branch, BranchSink, DemuxKind, Node, NodeStatus,
};

mod divergence;
mod release;
mod schema;
mod stream;

use schema::BestOfNParams;

/// Resolve the requested model (or the first registered) and load it. Shared by
/// the generation path and the lifecycle-release path. `Err((status, code,
/// message))` is an OpenAI-shape error the caller turns into a JSON envelope.
fn resolve_model(model: Option<&str>) -> Result<(Model, String), (u16, &'static str, String)> {
    let model_id = match model {
        Some(m) if !m.trim().is_empty() => m.to_string(),
        _ => inferlet::runtime::models().into_iter().next().ok_or((
            500,
            "no_model_registered",
            "Engine has no models registered; check pie config.".to_string(),
        ))?,
    };
    if !inferlet::runtime::models().iter().any(|m| m == &model_id) {
        return Err((
            404,
            "model_not_found",
            format!("Model '{model_id}' not registered with this engine"),
        ));
    }
    let model = Model::load(&model_id)
        .map_err(|e| (500, "model_load_failed", format!("Failed to load model: {e}")))?;
    Ok((model, model_id))
}

/// Monotonic id source for round + candidate identifiers. Best-of-n uses a
/// `bon-` prefix so its ids never collide with tree-of-thought's `tot-n*`.
static ID_COUNTER: AtomicU64 = AtomicU64::new(0);

fn new_request_id() -> String {
    format!("bon-{}", ID_COUNTER.fetch_add(1, Ordering::Relaxed))
}

fn new_candidate_id() -> String {
    format!("bon-n{}", ID_COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// Parent id of a round's candidates. Matches the tree-of-thought synthetic
/// root id so the app's `ToTTree.rootChildren` (`children(of: "root")`) picks
/// the candidates up unchanged.
const ROOT_ID: &str = "root";

/// The deepen instruction appended (as a user turn) to the base of a
/// think-more round so the next level's candidates build further on the
/// picked reply instead of repeating it. Best-of-N's own per-branch
/// divergence directive ([`divergence::candidate_directive`]) then adds each
/// sibling's distinct stance on top.
const DEEPEN_DIRECTIVE: &str = "The selected reply above is the current best answer. Build on it: \
    produce a deeper, more refined answer that adds a consideration, correction, or detail it did \
    not cover. Do not repeat its wording.";

/// Dispatch a `inferlet:"best-of-n"` request. Mirrors `tot::dispatch`'s
/// pre-generation contract: every validation / model-resolution / context
/// failure returns the OpenAI-shape JSON envelope BEFORE any SSE header is
/// committed, so a doomed request never opens a misleading stream.
pub async fn dispatch(
    input: Option<serde_json::Value>,
    messages: Option<Vec<ChatMessage>>,
    _stream: bool,
    res: Responder,
) -> Finished {
    let input: schema::BestOfNInput = match input {
        Some(v) => match serde_json::from_value(v) {
            Ok(p) => p,
            Err(e) => {
                return res
                    .respond(sse::json_error(
                        400,
                        "invalid_request",
                        &format!("Invalid `input` payload for best-of-n: {e}"),
                    ))
                    .await;
            }
        },
        None => schema::BestOfNInput::default(),
    };

    // Lifecycle release: a terminal-cleanup request carries `release` (snapshot
    // names to drop) and NO messages. Handle it before any message/generation
    // contract — it frees the round's KV pages and acks the accounting. Fired
    // by the app on stop/commit and on abandon (the no-next-round terminals);
    // think-more frees its prior round through the resume path instead.
    if let Some(names) = input.release.as_ref().filter(|n| !n.is_empty()) {
        let names = names.clone();
        let (model, _model_id) = match resolve_model(input.model.as_deref()) {
            Ok(m) => m,
            Err((status, code, msg)) => {
                return res.respond(sse::json_error(status, code, &msg)).await;
            }
        };
        return release::dispatch_release(&model, &names, res).await;
    }

    let is_resume = input.resume_from.is_some();

    let mut messages = match (input.messages.clone(), messages) {
        (Some(m), _) => m,
        (None, Some(m)) => m,
        (None, None) => {
            return res
                .respond(sse::json_error(
                    400,
                    "invalid_request",
                    "Provide either top-level `messages` or `input.messages` (the dispatch \
                     surface accepts both; `input.messages` wins on overlap).",
                ))
                .await;
        }
    };
    if messages.is_empty() {
        return res
            .respond(completions::json_error_param(
                400,
                "invalid_request",
                "messages must be a non-empty list",
                "messages",
            ))
            .await;
    }
    if let Some((i, _)) = messages.iter().enumerate().find(|(_, m)| {
        m.content_str().is_none_or(|content| content.trim().is_empty())
    }) {
        return res
            .respond(sse::json_error(
                400,
                "invalid_request",
                &format!("messages[{i}].content must be a non-empty, non-whitespace string"),
            ))
            .await;
    }
    // A think-more round must carry the picked candidate's text so the base can
    // be re-prefilled if its snapshot was evicted during the pick.
    if is_resume
        && input
            .picked_text
            .as_deref()
            .is_none_or(|t| t.trim().is_empty())
    {
        return res
            .respond(completions::json_error_param(
                400,
                "invalid_request",
                "picked_text (the chosen candidate's content) is required with resume_from so the \
                 round can recover if the snapshot was evicted",
                "picked_text",
            ))
            .await;
    }

    let params = match schema::resolve(&input) {
        Ok(p) => p,
        Err((field, msg)) => {
            return res
                .respond(completions::json_error_param(400, "invalid_request", &msg, field))
                .await;
        }
    };

    // Like tree-of-thought: when thinking is off, key Qwen3-style models off a
    // `/no_think` on the last user turn (the per-branch directive + cue prefill
    // also carry it). Inert on a non-reasoning model.
    if !params.thinking {
        if let Some(last) = messages.iter_mut().rev().find(|m| m.role == "user") {
            if let Some(content) = last.content.as_mut() {
                content.push_str(" /no_think");
            }
        }
    }

    let (model, model_id) = match resolve_model(input.model.as_deref()) {
        Ok(m) => m,
        Err((status, code, msg)) => {
            return res.respond(sse::json_error(status, code, &msg)).await;
        }
    };

    // Build the flushed, cue-free base the round's candidates fork from. Round
    // 1 = the conversation prefix; a think-more round = the picked candidate's
    // resumed (or re-prefilled) context plus the deepen turn.
    let base = if is_resume {
        let mut ops = InferletResumeOps { model: &model };
        let picked = input.resume_from.as_deref().unwrap_or_default();
        let picked_text = input.picked_text.as_deref().unwrap_or_default();
        let unpicked = input.unpicked.clone().unwrap_or_default();
        match resume_base_with(&mut ops, picked, picked_text, &messages, &unpicked) {
            Ok((mut ctx, _warm)) => {
                if let Err(e) = ctx.flush().await {
                    return res
                        .respond(sse::json_error(
                            500,
                            "context_flush_failed",
                            &format!("Failed to flush resume base: {e}"),
                        ))
                        .await;
                }
                ctx
            }
            Err((code, msg)) => return res.respond(sse::json_error(500, code, &msg)).await,
        }
    } else {
        let mut root_ctx = match inferlet::Context::new(&model) {
            Ok(c) => c,
            Err(e) => {
                return res
                    .respond(sse::json_error(
                        500,
                        "context_create_failed",
                        &format!("Failed to create context: {e}"),
                    ))
                    .await;
            }
        };
        // cue:false — the assistant turn is opened per branch in
        // `generate_branch`, so the shared prefix stays cue-free and its KV
        // pages are shared across the forked candidates.
        if let Err((code, msg)) =
            completions::fill_context(&mut root_ctx, &model, &messages, None, false)
        {
            let status = if completions::is_role_error_code(code) { 400 } else { 500 };
            return res.respond(sse::json_error(status, code, &msg)).await;
        }
        if let Err(e) = root_ctx.flush().await {
            return res
                .respond(sse::json_error(
                    500,
                    "context_flush_failed",
                    &format!("Failed to flush root context: {e}"),
                ))
                .await;
        }
        root_ctx
    };

    // Best-of-N always streams its candidates (the N-pane UI consumes the
    // per-node deltas); the dispatch `stream` flag is not meaningful here.
    let request_id = new_request_id();
    run_round(base, &params, &model, &model_id, &request_id, res).await
}

/// Generate, stream, and persist one round of `n` candidates forked off
/// `base_ctx` (already flushed + cue-free), then emit the terminal
/// `awaiting_selection` (or an `error` terminal when no candidate survived).
async fn run_round(
    base_ctx: inferlet::Context,
    params: &BestOfNParams,
    model: &Model,
    model_id: &str,
    request_id: &str,
    res: Responder,
) -> Finished {
    let gen_params = branch::round_params(
        params.n,
        params.max_tokens_per_candidate,
        params.max_reasoning_tokens,
        params.temperature,
        params.top_p,
        params.thinking,
    );

    let mut em = Emitter::start(res);
    // Open with the verbatim tree-of-thought `tree_start` so the app renders
    // the round in its existing tree view; `depth = 1`, `beam_width = 1` are
    // the inert round_params bounds (Best-of-N does not prune).
    if emit_tree_start(&mut em, request_id, model_id, &gen_params)
        .await
        .is_err()
    {
        return em.finish();
    }

    // Fork n candidate contexts off the shared, flushed, cue-free base.
    let mut metas: Vec<(String, usize)> = Vec::with_capacity(params.n);
    let mut ctxs: Vec<inferlet::Context> = Vec::with_capacity(params.n);
    let mut fork_errors: Vec<(String, usize, String)> = Vec::new();
    for idx in 0..params.n {
        let node_id = new_candidate_id();
        match base_ctx.fork() {
            Ok(c) => {
                ctxs.push(c);
                metas.push((node_id, idx));
            }
            Err(e) => fork_errors.push((node_id, idx, e.to_string())),
        }
    }

    // Best-of-N's OWN per-sibling divergence directives (#690), computed up
    // front. Each is passed as a per-fork `&str` parameter INTO the single
    // `join_all` below — it is not a serialization point, so all `n` candidates
    // still decode in flight and the engine co-batches their forward passes
    // (#465/#650), exactly as before this divergence refactor. The stance set
    // lives in `divergence`, decoupled from the ToT diversity directives, so a
    // Best-of-N round never rides `tot::search::branch_directive`.
    // The second divergence axis is the per-fork sampling seed: the candidates
    // sample with stochastic `TopP` (no seed), so the engine gives each fork an
    // independent PCG32 stream (#683). That only diverges them when sampling is
    // actually stochastic; warn once if a caller drove temperature to 0 (the
    // directive axis still separates them, but the seed axis goes inert).
    if !divergence::requires_stochastic_sampling(params.temperature) {
        eprintln!(
            "[chat-apc] best-of-n: temperature is 0 — candidates diverge by directive only; \
             per-fork seed independence is inert at greedy decode"
        );
    }
    let directives: Vec<(String, String)> = metas
        .iter()
        .map(|(_, idx)| {
            (
                divergence::candidate_directive(*idx, params.thinking),
                divergence::candidate_retry_directive(*idx),
            )
        })
        .collect();

    // Concurrent generation: all siblings decode in flight so the engine
    // co-batches their forward passes (#465/#650); the Copy BranchSink
    // interleaves their per-node `node_delta` frames on the one stream, each
    // routed by id. No scoring, no auto-select — that is the whole point.
    let gens: Vec<(inferlet::Context, branch::Demux)> = {
        let shared = Mutex::new(&mut em);
        let sink = BranchSink::new(&shared);
        join_all(metas.iter().zip(ctxs).zip(directives.iter()).map(
            |(((node_id, idx), c), (first_directive, retry_directive))| {
                generate_branch(
                    c,
                    model,
                    &gen_params,
                    Some(sink),
                    node_id,
                    ROOT_ID,
                    params.level,
                    *idx,
                    // Best-of-N has no cross-sibling token penalty; its only
                    // divergence lever is the per-candidate directive pair.
                    &[],
                    first_directive,
                    retry_directive,
                )
            },
        ))
        .await
    };

    // Persist each answered candidate's KV under a content-addressed name so a
    // later think-more round can resume from the user's pick. The snapshot is
    // reconstructed cleanly (`base.fork()` + a template assistant turn) rather
    // than saved from the raw generation context — see the module header. Each
    // candidate is projected onto a tree-of-thought `Node` (depth = level,
    // parent = root, no score — there is no scorer) so it streams on the
    // reused `node_complete` / `level_pruned` wire.
    let mut nodes: Vec<Node> = Vec::with_capacity(params.n);
    let mut picks: Vec<stream::Pick> = Vec::new();
    let mut kept: Vec<String> = Vec::new();
    for ((_gen_ctx, demux), (node_id, idx)) in gens.into_iter().zip(metas.iter()) {
        let node = match demux.kind {
            DemuxKind::Answered => {
                let snapshot_name = format!("bon/{request_id}/{}/{}", params.level, idx);
                let saved =
                    save_candidate_snapshot(&base_ctx, &demux.answer, &snapshot_name).await;
                if saved {
                    kept.push(node_id.clone());
                    picks.push(stream::Pick {
                        id: node_id.clone(),
                        branch_index: *idx,
                        snapshot_name,
                    });
                    candidate_node(node_id, *idx, params.level, demux.answer, demux.reasoning)
                } else {
                    // Answered but unsaveable → not pickable; surface as an error node.
                    error_node(
                        node_id,
                        *idx,
                        params.level,
                        demux.reasoning,
                        "candidate KV could not be saved for resume",
                    )
                }
            }
            DemuxKind::Incomplete => incomplete_node(node_id, *idx, params.level, demux.reasoning),
            DemuxKind::Aborted(msg) => {
                error_node(node_id, *idx, params.level, demux.reasoning, &msg)
            }
        };
        nodes.push(node);
    }
    for (node_id, idx, err) in &fork_errors {
        nodes.push(error_node(node_id, *idx, params.level, String::new(), err));
    }

    // Stream every candidate's `node_complete`, then `level_pruned` with the
    // pickable (saved) ids as the "kept" set — Best-of-N keeps all answers; the
    // beam state simply marks which are selectable.
    let _ = emit_level(&mut em, params.level, &nodes, &kept).await;

    if picks.is_empty() {
        // No pickable candidate: emit the documented terminal `error` rather
        // than a success-shaped `awaiting_selection` with an empty list.
        let _ = em
            .emit_json(&sse::SseError::new(
                stream::NO_CANDIDATES_CODE,
                stream::NO_CANDIDATES_MESSAGE,
            ))
            .await;
    } else if let Err(e) =
        stream::emit_awaiting_selection(&mut em, params.level, &picks).await
    {
        // #703 F5 (widened, review F2): delivery of the pick list failed. The
        // orphan condition is identical for BOTH `EmitError` variants —
        // `Disconnected` (client dropped) and `Serialize` (a host-visible
        // programmer error) — the client never received the list either way, so
        // these just-saved candidates can never be picked or app-released (the
        // app's abandon sweep keys on a materialized round a never-delivered
        // terminal lacks). Free them now rather than leak them until engine
        // teardown, regardless of cause; bounded to this round's `n` snapshots,
        // freed through the same path the app-driven release uses. `e` is
        // logged so a `Serialize` cause is captured, not silently dropped.
        let names: Vec<String> = picks.iter().map(|p| p.snapshot_name.clone()).collect();
        let report = release::release_snapshots(model, &names);
        eprintln!(
            "[chat-apc] best-of-n: awaiting_selection delivery failed ({e:?}); \
             freed {}/{} orphaned candidate snapshots (request {request_id})",
            report.released, report.requested
        );
    }
    sse::emit_done_logged(&mut em, "bon_terminal").await;
    em.finish()
}

/// A pickable (answered + saved) candidate as a tree-of-thought node. No
/// score — Best-of-N has no value scorer; the user is the judge.
fn candidate_node(
    id: &str,
    branch_index: usize,
    level: usize,
    content: String,
    reasoning: String,
) -> Node {
    Node {
        id: id.to_string(),
        parent_id: Some(ROOT_ID.to_string()),
        depth: level,
        branch_index: Some(branch_index),
        content,
        reasoning,
        score: None,
        status: NodeStatus::Ok,
        error: None,
        score_error: None,
        children: Vec::new(),
    }
}

/// A candidate that reasoned but produced no answer (not pickable).
fn incomplete_node(id: &str, branch_index: usize, level: usize, reasoning: String) -> Node {
    Node {
        id: id.to_string(),
        parent_id: Some(ROOT_ID.to_string()),
        depth: level,
        branch_index: Some(branch_index),
        content: String::new(),
        reasoning,
        score: None,
        status: NodeStatus::Incomplete,
        error: Some("candidate produced no answer".to_string()),
        score_error: None,
        children: Vec::new(),
    }
}

/// A candidate whose fork/generation/save failed (not pickable).
fn error_node(id: &str, branch_index: usize, level: usize, reasoning: String, err: &str) -> Node {
    Node {
        id: id.to_string(),
        parent_id: Some(ROOT_ID.to_string()),
        depth: level,
        branch_index: Some(branch_index),
        content: String::new(),
        reasoning,
        score: None,
        status: NodeStatus::Error,
        error: Some(err.to_string()),
        score_error: None,
        children: Vec::new(),
    }
}

/// Reconstruct + save one candidate's resumable snapshot: fork the round's
/// shared base, append the answer as a sealed template assistant turn, flush,
/// and save under `name`. Returns whether the snapshot was persisted (a
/// best-effort failure leaves the candidate non-pickable, not the round dead).
///
/// A failure at any of fork/flush/save logs the underlying engine error to
/// stderr before collapsing to `false` (#703 F6): the caller turns `false`
/// into a fixed "could not be saved" node that loses the cause, so a SYSTEMIC
/// snapshot-store problem (e.g. page-store exhaustion) is invisible without
/// this breadcrumb. The error rides the inferlet stderr-event channel.
async fn save_candidate_snapshot(base_ctx: &Context, answer: &str, name: &str) -> bool {
    let mut snap = match base_ctx.fork() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[chat-apc] best-of-n: fork for snapshot {name} failed: {e}");
            return false;
        }
    };
    snap.assistant(answer);
    if let Err(e) = snap.flush().await {
        eprintln!("[chat-apc] best-of-n: flush for snapshot {name} failed: {e}");
        return false;
    }
    match snap.save(name) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("[chat-apc] best-of-n: save of snapshot {name} failed: {e}");
            false
        }
    }
}

/// Engine operations a think-more round needs, abstracted so the
/// open()-miss → re-prefill fallback is unit-testable without a live engine
/// (the real impl below uses the inferlet `Context`; the test uses a mock that
/// forces an open miss). Mirrors the tot `BranchDriver` seam.
trait ResumeOps {
    type Ctx;
    /// Best-effort delete of a saved snapshot (already-evicted is fine).
    fn delete_snapshot(&mut self, name: &str);
    /// Warm-start: open the saved snapshot, or `None` on a miss (evicted).
    fn open(&mut self, name: &str) -> Option<Self::Ctx>;
    /// Re-prefill fallback: rebuild the base from the conversation plus the
    /// picked candidate appended as an assistant turn.
    fn reprefill(&mut self, messages: &[ChatMessage], picked_text: &str)
        -> Result<Self::Ctx, (&'static str, String)>;
    /// Append the deepen instruction as a user turn.
    fn append_deepen(&mut self, ctx: &mut Self::Ctx);
}

/// Build the think-more base: delete the unpicked siblings (deterministic
/// free), warm-start from the picked snapshot or re-prefill on a miss, then
/// append the deepen turn. Returns `(base, warm)`. Pure over [`ResumeOps`] so
/// both the open-hit and open-miss paths are unit-tested.
fn resume_base_with<O: ResumeOps>(
    ops: &mut O,
    picked: &str,
    picked_text: &str,
    messages: &[ChatMessage],
    unpicked: &[String],
) -> Result<(O::Ctx, bool), (&'static str, String)> {
    // 1. Deterministic free: drop the unpicked siblings now. Best-effort — a
    //    sibling may already have been LRU-evicted.
    for name in unpicked {
        ops.delete_snapshot(name);
    }

    // 2. Warm-start, or re-prefill on an open() miss. The miss path is
    //    load-bearing: an idle snapshot has no durable guest pin and can be
    //    evicted under memory pressure during a slow pick.
    let (mut base, warm) = match ops.open(picked) {
        Some(ctx) => (ctx, true),
        None => (ops.reprefill(messages, picked_text)?, false),
    };

    // 3. Deepen instruction for the next level.
    ops.append_deepen(&mut base);

    // 4. On the warm path the named picked snapshot is now redundant (we hold a
    //    live fork of it and will save fresh per-candidate snapshots), so free
    //    it deterministically too.
    if warm {
        ops.delete_snapshot(picked);
    }

    Ok((base, warm))
}

/// Real [`ResumeOps`] over the inferlet engine `Context`.
struct InferletResumeOps<'a> {
    model: &'a Model,
}

impl ResumeOps for InferletResumeOps<'_> {
    type Ctx = Context;

    fn delete_snapshot(&mut self, name: &str) {
        let _ = Context::delete(self.model, name);
    }

    fn open(&mut self, name: &str) -> Option<Context> {
        match Context::open(self.model, name) {
            Ok(ctx) => Some(ctx),
            Err(e) => {
                // A miss is normally benign LRU eviction, but the same `None`
                // also hides a genuine engine fault or a never-persisting
                // snapshot regression — which would make every think-more round
                // silently re-prefill and leave the warm-resume path dead.
                // Log so the two are distinguishable; the fallback is unchanged.
                eprintln!("[chat-apc] best-of-n: snapshot open miss for {name}: {e}; re-prefilling");
                None
            }
        }
    }

    fn reprefill(
        &mut self,
        messages: &[ChatMessage],
        picked_text: &str,
    ) -> Result<Context, (&'static str, String)> {
        let mut ctx = Context::new(self.model)
            .map_err(|e| ("context_create_failed", e.to_string()))?;
        // cue:false — the shared prefix stays cue-free; per-branch cues happen
        // in `generate_branch`.
        completions::fill_context(&mut ctx, self.model, messages, None, false)
            .map_err(|(code, msg)| (code, msg))?;
        // Append the picked candidate as a sealed assistant turn so the
        // re-prefilled base matches the warm snapshot exactly.
        ctx.assistant(picked_text);
        Ok(ctx)
    }

    fn append_deepen(&mut self, ctx: &mut Context) {
        ctx.user(DEEPEN_DIRECTIVE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Records every engine op so a test can assert which resume path ran.
    #[derive(Default)]
    struct MockCtx {
        /// Ops applied to this context, in order, e.g. "open:NAME",
        /// "reprefill", "deepen".
        log: Vec<String>,
    }

    struct MockOps {
        /// When true, `open()` misses (forces the re-prefill fallback).
        open_misses: bool,
        calls: RefCell<Vec<String>>,
    }

    impl ResumeOps for MockOps {
        type Ctx = MockCtx;

        fn delete_snapshot(&mut self, name: &str) {
            self.calls.borrow_mut().push(format!("delete:{name}"));
        }

        fn open(&mut self, name: &str) -> Option<MockCtx> {
            self.calls.borrow_mut().push(format!("open:{name}"));
            if self.open_misses {
                None
            } else {
                Some(MockCtx { log: vec![format!("open:{name}")] })
            }
        }

        fn reprefill(
            &mut self,
            messages: &[ChatMessage],
            picked_text: &str,
        ) -> Result<MockCtx, (&'static str, String)> {
            self.calls
                .borrow_mut()
                .push(format!("reprefill:{}msgs:{picked_text}", messages.len()));
            Ok(MockCtx {
                log: vec![format!("reprefill:{picked_text}")],
            })
        }

        fn append_deepen(&mut self, ctx: &mut MockCtx) {
            ctx.log.push("deepen".to_string());
            self.calls.borrow_mut().push("deepen".to_string());
        }
    }

    fn msg(role: &str, content: &str) -> ChatMessage {
        ChatMessage {
            role: role.to_string(),
            content: Some(content.to_string()),
            tool_call_id: None,
            tool_calls: None,
        }
    }

    #[test]
    fn warm_start_opens_drops_unpicked_and_the_picked_snapshot() {
        let mut ops = MockOps { open_misses: false, calls: RefCell::new(Vec::new()) };
        let messages = vec![msg("user", "2+2?")];
        let (base, warm) = resume_base_with(
            &mut ops,
            "bon/r0/1/2",
            "It is 4.",
            &messages,
            &["bon/r0/1/0".to_string(), "bon/r0/1/1".to_string()],
        )
        .expect("warm resume");

        assert!(warm, "open() hit should report a warm start");
        // Warm path opened, never re-prefilled.
        assert_eq!(base.log, vec!["open:bon/r0/1/2", "deepen"]);
        let calls = ops.calls.borrow();
        assert!(!calls.iter().any(|c| c.starts_with("reprefill")), "warm path must not re-prefill");
        // Unpicked siblings dropped first, then deepen, then the now-redundant
        // picked snapshot dropped too.
        assert_eq!(
            *calls,
            vec![
                "delete:bon/r0/1/0",
                "delete:bon/r0/1/1",
                "open:bon/r0/1/2",
                "deepen",
                "delete:bon/r0/1/2",
            ]
        );
    }

    #[test]
    fn open_miss_falls_back_to_reprefill_from_messages_and_picked_text() {
        let mut ops = MockOps { open_misses: true, calls: RefCell::new(Vec::new()) };
        let messages = vec![msg("user", "2+2?")];
        let (base, warm) = resume_base_with(
            &mut ops,
            "bon/r0/1/2",
            "It is 4.",
            &messages,
            &["bon/r0/1/0".to_string()],
        )
        .expect("reprefill fallback");

        assert!(!warm, "open() miss should report a cold (re-prefilled) start");
        // The base was rebuilt from messages + picked text, then deepened.
        assert_eq!(base.log, vec!["reprefill:It is 4.", "deepen"]);
        let calls = ops.calls.borrow();
        // Unpicked dropped, open attempted + missed, then re-prefill ran with
        // the conversation and the picked text.
        assert_eq!(
            *calls,
            vec![
                "delete:bon/r0/1/0",
                "open:bon/r0/1/2",
                "reprefill:1msgs:It is 4.",
                "deepen",
            ]
        );
        // On a miss there is no live picked snapshot to free (it was evicted),
        // so the picked name is NOT deleted a second time.
        assert!(
            !calls.iter().skip(1).any(|c| c == "delete:bon/r0/1/2"),
            "miss path must not delete the (already-evicted) picked snapshot"
        );
    }
}
