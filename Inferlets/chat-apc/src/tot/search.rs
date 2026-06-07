//! Tree-of-Thought BFS beam search orchestration (Yao et al. 2023).
//!
//! For each of `depth` levels: every frontier node forks `breadth`
//! children from its common prefix (KV-cache sharing), each child
//! generates a candidate continuation, and a value evaluator scores it
//! 1–10. The top `beam_width` candidates by score survive as the next
//! frontier. The best-scoring leaf at the deepest level that produced a
//! surviving (beam-kept) candidate is the final answer — earlier levels
//! are preserved when a later level fully fails (see `fold_level` / F7).
//!
//! Branches at a level are generated concurrently via
//! `futures::future::join_all`. The WIT-backed engine calls
//! (`Context`/`generate`/`fork`) live in [`run`], [`expand`], and
//! [`score_node`] and are exercised by the real-engine e2e. The
//! Context-free bookkeeping — node materialization, pruning, the
//! empty-frontier break, and final-answer selection — is split into the
//! pure helpers [`materialize_level`], [`fold_level`], and [`finalize`],
//! which are unit-tested natively via `cargo test --lib`.

use inferlet::model::Model;
use inferlet::sample::Sampler;
use inferlet::{chat, reasoning};
use inferlet::Context;

use crate::sse::Emitter;

use super::schema::TotParams;
use super::stream;
use super::tree::{
    assemble, best_leaf, error_leaf, new_node_id, parse_score, select_beam, Candidate, Node,
    NodeStatus,
};

/// Built-in expansion instruction appended before forking at levels > 1.
/// Level-1 children answer the conversation directly (sibling diversity
/// comes from sampling temperature).
///
/// Reasoning-aware (#413/#437): a node generates a `<think>` block then an
/// answer, which [`generate_demuxed`] splits apart — reasoning IS the point
/// of a tree-of-thought search, so the candidate keeps its thought trace
/// while the beam and the scorer see only the clean answer. The instruction
/// carries no `/no_think`; [`with_thinking`] appends one only when the
/// search runs with `thinking:false`.
const REFINE_INSTRUCTION: &str = "Critique your previous answer, then give a distinct, \
     improved continuation toward correctly answering the original question. Be concise.";

/// Value-evaluator prompt (independent per-node scoring). The node already
/// did its reasoning; the scorer is a value HEAD that rates the resulting
/// ANSWER (#437), so it always runs with `/no_think` appended (see
/// [`score_node`]) to emit a bare integer cheaply — a thinking scorer burns
/// its budget restating the problem and lands no parseable integer at deeper
/// levels (observed: depth-2 scores all null → input-order pruning, and ~2×
/// slower). This is orthogonal to the node-generation `thinking` knob, which
/// stays on. The directive is inert on a non-reasoning model, and the score
/// output is demuxed regardless so a stray empty think block can't swallow
/// the integer.
const SCORE_PROMPT: &str = "On a scale of 1 to 10, rate how promising the assistant's \
     latest answer is toward correctly and completely answering the original question. \
     Respond with only a single integer from 1 to 10.";

/// Token budget for a scoring generation — enough for a suppressed empty
/// `<think></think>` plus the integer. The scorer is NOT demuxed (see
/// [`score_node`]), so this is the whole budget.
const SCORE_MAX_TOKENS: usize = 32;

/// Append the `/no_think` directive when reasoning is disabled for this
/// search (`thinking:false`). On a Qwen3-style model this suppresses the
/// `<think>` block; on a non-reasoning model it is an inert token.
fn with_thinking(base: &str, thinking: bool) -> String {
    if thinking {
        base.to_string()
    } else {
        format!("{base} /no_think")
    }
}

/// A generated batch is visible answer content only when it lands entirely
/// outside a reasoning block (mirrors `chat::completions::content_visible`):
/// the reasoning decoder reported `Idle` for it AND we were not already
/// inside a `<think>` block before this batch — so the closing `</think>`
/// delimiter (which the chat decoder still surfaces as a Delta on the End
/// batch) stays off the answer channel.
fn content_visible(reason_idle: bool, was_in_reasoning: bool) -> bool {
    reason_idle && !was_in_reasoning
}

/// How [`generate_demuxed`] resolved one assistant-turn generation.
enum DemuxKind {
    /// A non-empty answer was produced (after any reasoning).
    Answered,
    /// Reasoning ran but no usable answer followed — truncated mid-thought
    /// (the reasoning budget elapsed before `</think>`) or an empty/closed
    /// think block with nothing after it (#434).
    Incomplete,
    /// The generator or a decoder failed mid-generation.
    Aborted(String),
}

/// One generation, demuxed into its reasoning trace and its answer.
struct Demux {
    reasoning: String,
    answer: String,
    kind: DemuxKind,
}

/// Generate one assistant turn with two-phase budgeting and `<think>` demux.
///
/// Phase 1 (reasoning) runs until the model closes its think block or
/// `reasoning_budget` tokens elapse; phase 2 (answer) then runs until the
/// chat template completes or `answer_budget` tokens elapse — so an
/// over-long thought can never starve the answer (#434), because the answer
/// always gets its own budget once reasoning has closed. Reasoning text is
/// collected from the reasoning decoder; the answer is the chat-decoder
/// content that falls outside any think block (#437 — the beam and scorer
/// see only this clean answer, never the thought trace). The caller owns
/// `cue`/forking/scoring; this only drives `generate`.
async fn generate_demuxed(
    ctx: &mut Context,
    model: &Model,
    sampler: Sampler,
    reasoning_budget: usize,
    answer_budget: usize,
    stops: &[u32],
    mut emitter: Option<&mut Emitter>,
    node_id: &str,
) -> Demux {
    let mut reason_dec = reasoning::Decoder::new(model);
    let mut chat_dec = chat::Decoder::new(model);
    let mut generator = ctx
        .generate(sampler)
        .max_tokens(reasoning_budget + answer_budget)
        .stop(stops);

    let mut reasoning = String::new();
    let mut answer = String::new();
    let mut in_reasoning = false;
    let mut reasoning_done = false;
    let mut reasoning_tokens = 0usize;
    let mut answer_tokens = 0usize;

    let kind = loop {
        let step = match generator.next() {
            Ok(None) => break DemuxKind::Answered, // max-tokens; reclassified by answer below
            Ok(Some(s)) => s,
            Err(e) => break DemuxKind::Aborted(format!("forward pass failed: {e}")),
        };
        let out = match step.execute().await {
            Ok(o) => o,
            Err(e) => break DemuxKind::Aborted(format!("forward pass failed: {e}")),
        };

        // Capture the gate state BEFORE feeding the reasoning decoder: `feed`
        // flips `in_reasoning` as it consumes a boundary token, but the chat
        // decoder must be gated on this batch's channel, not the post-flip
        // state (the canonical chat-completions demux).
        let was_in_reasoning = in_reasoning;
        let mut reason_idle = false;
        match reason_dec.feed(&out.tokens) {
            Ok(reasoning::Event::Start) => in_reasoning = true,
            Ok(reasoning::Event::Delta(s)) => {
                in_reasoning = true;
                reasoning.push_str(&s);
                // #413 token stream: live-fill this node's reasoning channel.
                if let Some(em) = emitter.as_deref_mut() {
                    let _ = stream::emit_node_delta(em, node_id, stream::DELTA_REASONING, &s).await;
                }
            }
            Ok(reasoning::Event::End(_)) => {
                in_reasoning = false;
                reasoning_done = true;
            }
            Ok(reasoning::Event::Idle) => reason_idle = true,
            Err(e) => break DemuxKind::Aborted(format!("reasoning decode failed: {e}")),
        }
        match chat_dec.feed(&out.tokens) {
            Ok(chat::Event::Delta(s)) if content_visible(reason_idle, was_in_reasoning) => {
                answer.push_str(&s);
                // #413 token stream: live-fill this node's answer channel.
                if let Some(em) = emitter.as_deref_mut() {
                    let _ = stream::emit_node_delta(em, node_id, stream::DELTA_ANSWER, &s).await;
                }
            }
            Ok(chat::Event::Delta(_)) | Ok(chat::Event::Idle) => {}
            Ok(chat::Event::Done(_)) => break DemuxKind::Answered,
            Ok(chat::Event::Interrupt(_)) => {
                break DemuxKind::Aborted("chat template interrupt".to_string())
            }
            Err(e) => break DemuxKind::Aborted(format!("chat decode failed: {e}")),
        }

        // Phase accounting: a batch is answer-phase once reasoning has closed
        // (or the model never opened a think block and is already emitting
        // visible content). Reasoning that overruns its budget before closing
        // ends the node Incomplete — there is no answer phase to enter.
        let answering =
            reasoning_done || (!in_reasoning && !was_in_reasoning && !answer.is_empty());
        if answering {
            answer_tokens += out.tokens.len();
            if answer_tokens >= answer_budget {
                break DemuxKind::Answered;
            }
        } else {
            reasoning_tokens += out.tokens.len();
            if reasoning_tokens >= reasoning_budget && !reasoning_done {
                break DemuxKind::Incomplete;
            }
        }
    };

    // A clean stop (chat Done / max-tokens) that produced no answer text is
    // still Incomplete: an empty or closed-but-unanswered think block (#434).
    let kind = match kind {
        DemuxKind::Answered if answer.trim().is_empty() => DemuxKind::Incomplete,
        other => other,
    };
    Demux {
        reasoning,
        answer,
        kind,
    }
}

/// Outcome of the value evaluator for one node. Distinguishes the three
/// classes the old bare `Option<u8>` collapsed together: a parsed score,
/// a benign unparseable result (the model emitted no in-range integer —
/// common for reasoning models), and an infra failure (the scoring fork
/// or generation itself failed). Only the last surfaces as a node
/// `score_error`, so an infra scorer collapse is no longer mistaken for a
/// benign null and the silent degradation to input-order pruning becomes
/// observable.
enum ScoreOutcome {
    Scored(u8),
    Unparseable,
    Failed(String),
}

impl ScoreOutcome {
    /// Split into a node's `(score, score_error)`. Pure → unit-tested.
    fn into_parts(self) -> (Option<u8>, Option<String>) {
        match self {
            ScoreOutcome::Scored(v) => (Some(v), None),
            ScoreOutcome::Unparseable => (None, None),
            ScoreOutcome::Failed(msg) => (None, Some(msg)),
        }
    }
}

/// Context-free result of expanding one forked branch — everything
/// [`materialize_level`] needs to build a [`Node`], with no engine handle.
/// [`expand`] returns this paired with the moved-back [`Context`] so a
/// surviving node can be expanded at the next level.
#[derive(Clone, Debug)]
struct NodeOutcome {
    status: NodeStatus,
    /// The clean answer (empty for `Error`/`Incomplete`).
    content: String,
    /// The demuxed `<think>` trace (present for a thinking `Ok` node and for
    /// an `Incomplete` node that thought but never answered).
    reasoning: String,
    score: Option<u8>,
    score_error: Option<String>,
    /// Per-node diagnostic for a non-`Ok` node (`None` for `Ok`).
    error: Option<String>,
}

/// One forked branch ready to materialize: its caller-assigned id + tree
/// position + Context-free outcome.
struct Branch {
    id: String,
    parent_id: String,
    branch_index: usize,
    outcome: NodeOutcome,
}

/// Pure materialization of one search level: the tree nodes to append,
/// the scored candidates, and the beam (surviving node ids).
struct LevelMaterialized {
    nodes: Vec<Node>,
    candidates: Vec<Candidate>,
    keep: Vec<String>,
}

/// A live frontier entry: a context ready to expand + its tree-node id.
struct Frontier {
    ctx: Context,
    node_id: String,
}

pub struct SearchOutcome {
    pub root: Node,
    pub selected_node_id: Option<String>,
    pub final_answer: Option<String>,
}

/// Run the beam search. `root_ctx` must already be filled (system +
/// messages) **and flushed, but NOT cued** — the assistant turn is
/// opened per branch in [`expand`]. A cue committed into the shared
/// prefix would be duplicated across every fork and waste the zero-token
/// forward pass that the level-1 spin fix removed.
///
/// When `emitter` is `Some`, the search streams (#413): each node emits a
/// `node_start`, then its reasoning + answer stream live as `node_delta`
/// chunks while it generates ([`generate_demuxed`]), then the level's nodes
/// are emitted as `node_complete` frames (full node + score) followed by the
/// `level_pruned` beam selection — the single source of search orchestration
/// drives both the non-streaming response and the streamed one, so they can
/// never diverge (the non-stream path simply passes `None` and emits no
/// deltas, ending at a byte-identical tree). Emit errors are deliberately
/// swallowed: a peer disconnect (the common case) just means no one is
/// listening, and the bounded search (≤ `MAX_NODES`) finishes either way; the
/// returned [`SearchOutcome`] is identical regardless of whether anyone
/// received the frames.
pub async fn run(
    root_ctx: Context,
    params: &TotParams,
    model: &Model,
    mut emitter: Option<&mut Emitter>,
) -> SearchOutcome {
    let mut flat: Vec<Node> = vec![Node::root()];
    let mut frontier: Vec<Frontier> = vec![Frontier {
        ctx: root_ctx,
        node_id: "root".to_string(),
    }];
    // Candidates at the deepest level that produced a surviving leaf — the
    // pool the final answer is chosen from. Carried across levels by
    // `fold_level` so a late all-fail level can't null an answer that
    // earlier levels legitimately produced (F7).
    let mut last_level: Vec<Candidate> = Vec::new();

    for level in 1..=params.depth {
        // Index into `flat` of this level's first node. Every node appended
        // below — refine-flush error leaves, fork error leaves, and the
        // materialized candidates — lands in `flat[level_start..]`, the
        // exact slice the streaming sink replays as `node_complete` frames.
        let level_start = flat.len();

        // Levels > 1 refine the parent before forking: append the refine
        // user-turn and flush it into the shared prefix. The assistant
        // turn itself is opened per child in `expand` (every level cues
        // its own fork), so the shared prefix stays cue-free and KV pages
        // are shared across the branches. Sequential (≤ beam_width
        // parents; flush is light).
        //
        // A flush failure here is NOT best-effort: `Context::flush` takes
        // the token buffer before its fallible forward pass, so on error
        // the REFINE_INSTRUCTION tokens are discarded while `seq_len` is
        // left unchanged — and `fork()` clones that now-empty buffer.
        // Forking such a parent would silently generate a re-roll of its
        // PRE-refine answer and record it as `status:"ok"`: an invisible
        // downgrade, since this flush is the only thing that makes a
        // level a refinement rather than a re-roll. So drop the parent and
        // record error leaves for its children, mirroring the fork-failure
        // path below.
        if level > 1 {
            let mut refined: Vec<Frontier> = Vec::with_capacity(frontier.len());
            let refine = with_thinking(REFINE_INSTRUCTION, params.thinking);
            for mut f in frontier {
                f.ctx.user(&refine);
                match f.ctx.flush().await {
                    Ok(()) => refined.push(f),
                    Err(e) => {
                        for b in 0..params.breadth {
                            flat.push(error_leaf(
                                &f.node_id,
                                level,
                                b,
                                format!("refine flush failed: {e}"),
                            ));
                        }
                    }
                }
            }
            frontier = refined;
        }

        // Fork every child. A fork failure has no context to carry → record
        // it as an inline error leaf (shared with the refine-flush path); a
        // successful fork's context is expanded (generate + score)
        // concurrently below.
        let mut metas: Vec<(String, String, usize)> = Vec::new(); // (id, parent_id, branch_index)
        let mut ctxs: Vec<Context> = Vec::new();
        for f in frontier.iter() {
            for b in 0..params.breadth {
                match f.ctx.fork() {
                    Ok(child) => {
                        metas.push((new_node_id(), f.node_id.clone(), b));
                        ctxs.push(child);
                    }
                    Err(e) => {
                        flat.push(error_leaf(&f.node_id, level, b, format!("fork failed: {e}")))
                    }
                }
            }
        }

        // Sequential generation (#413 phase B): each node streams its own
        // node_start + token deltas to the single SSE emitter with exclusive
        // access, so the live tree fills a node at a time. Concurrency was
        // ~23% faster here but the engine batches forks only weakly, and a
        // sequential per-node stream reads as more responsive than a level
        // appearing all at once; the id on every frame keeps routing robust.
        let mut results: Vec<(Context, NodeOutcome)> = Vec::with_capacity(ctxs.len());
        for (meta, c) in metas.iter().zip(ctxs.into_iter()) {
            let (id, parent_id, branch_index) = (meta.0.as_str(), meta.1.as_str(), meta.2);
            if let Some(em) = emitter.as_deref_mut() {
                let _ = stream::emit_node_start(em, id, parent_id, level, branch_index).await;
            }
            results.push(
                expand(
                    c,
                    model,
                    params.temperature,
                    params.top_p,
                    params.max_reasoning_tokens,
                    params.max_tokens_per_node,
                    emitter.as_deref_mut(),
                    id,
                )
                .await,
            );
        }

        // Pair each expansion with its meta: keep the moved-back context as
        // a potential survivor, and hand the Context-free outcome to the
        // pure materializer.
        let mut survivors: Vec<Frontier> = Vec::with_capacity(metas.len());
        let mut branches: Vec<Branch> = Vec::with_capacity(metas.len());
        for ((id, parent_id, branch_index), (ctx, outcome)) in metas.into_iter().zip(results) {
            survivors.push(Frontier {
                ctx,
                node_id: id.clone(),
            });
            branches.push(Branch {
                id,
                parent_id,
                branch_index,
                outcome,
            });
        }

        let LevelMaterialized {
            nodes,
            candidates,
            keep,
        } = materialize_level(level, branches, params.beam_width);
        flat.extend(nodes);

        // Carry only the beam survivors (ok-only) as the next frontier; a
        // failed branch never survives to be re-expanded, and its
        // partially-advanced context is dropped here.
        frontier = survivors
            .into_iter()
            .filter(|f| keep.contains(&f.node_id))
            .collect();

        // F7: update the final-answer pool only when this level survived,
        // and stop early on an empty frontier — there is nothing left to
        // expand, and overwriting with the empty/all-error level would
        // null an answer earlier levels produced.
        let (pool, stop) = fold_level(last_level, candidates, &keep);
        last_level = pool;

        // #413: stream this level (all of its nodes, then the beam) once
        // it is fully resolved. Emitted before the `stop` break so a
        // search-ending final level still streams its nodes + empty beam.
        if let Some(em) = emitter.as_deref_mut() {
            let _ = stream::emit_level(em, level, &flat[level_start..], &keep).await;
        }

        if stop {
            break;
        }
    }

    finalize(flat, &last_level)
}

/// Materialize one level's **successfully forked** branches into tree
/// nodes + scored candidates + the beam, with no engine context so it is
/// unit-tested natively. Fork and refine-flush failures never reach here —
/// [`run`] records those as [`error_leaf`] nodes directly, since they have
/// no content to score or context to expand. A successful branch becomes
/// an `ok`/`error` leaf; an `ok` leaf may still carry a `score_error` when
/// the scorer infra failed (F4). Pruning reuses [`select_beam`], which
/// keeps only the top `beam_width` **ok** candidates. Node ids are
/// caller-assigned (paired with the engine contexts), so the returned
/// `keep` ids map straight back to surviving [`Frontier`] entries.
fn materialize_level(level: usize, branches: Vec<Branch>, beam_width: usize) -> LevelMaterialized {
    let mut nodes: Vec<Node> = Vec::with_capacity(branches.len());
    let mut candidates: Vec<Candidate> = Vec::with_capacity(branches.len());
    for b in branches {
        // Only an `Ok` node (a non-empty answer) is beam-eligible; both
        // `Error` (generation failed) and `Incomplete` (reasoned but never
        // answered) are excluded from survival and final-answer selection,
        // so the beam never keeps a node that has no answer — and a
        // think-only candidate can no longer win the search (#437).
        let is_ok = b.outcome.status == NodeStatus::Ok;
        candidates.push(Candidate {
            id: b.id.clone(),
            score: b.outcome.score,
            ok: is_ok,
        });
        nodes.push(Node {
            id: b.id,
            parent_id: Some(b.parent_id),
            depth: level,
            branch_index: Some(b.branch_index),
            content: b.outcome.content,
            reasoning: b.outcome.reasoning,
            score: b.outcome.score,
            status: b.outcome.status,
            error: b.outcome.error,
            score_error: b.outcome.score_error,
            children: Vec::new(),
        });
    }

    let keep = select_beam(&candidates, beam_width);
    LevelMaterialized {
        nodes,
        candidates,
        keep,
    }
}

/// F7: carry the deepest level that produced a surviving (beam-kept)
/// candidate as the final-answer pool. When a level yields no survivor —
/// every fork failed, or every generation errored, so `keep` is empty —
/// retain the *previous* pool and signal `stop`: there is nothing to
/// expand next level, and overwriting with the empty/all-error level
/// would null a `final_answer` that earlier levels legitimately produced.
/// Pure → unit-tested.
fn fold_level(
    prev: Vec<Candidate>,
    this: Vec<Candidate>,
    keep: &[String],
) -> (Vec<Candidate>, bool) {
    if keep.is_empty() {
        (prev, true) // no survivor → retain prior pool, stop the search
    } else {
        (this, false) // this level advances → it is the new deepest pool
    }
}

/// Assemble the final [`SearchOutcome`] from the flat node list and the
/// deepest surviving level's candidates. The best **ok** leaf (errors
/// excluded, `None` scores last, stable on ties) is the selected node +
/// final answer; both honestly null out when no ok leaf exists. Pure →
/// unit-tested.
fn finalize(flat: Vec<Node>, last_level: &[Candidate]) -> SearchOutcome {
    let best = best_leaf(last_level);
    let final_answer = best
        .as_ref()
        .and_then(|id| flat.iter().find(|n| &n.id == id).map(|n| n.content.clone()));
    let root = assemble(&flat, "root");
    SearchOutcome {
        root,
        selected_node_id: best,
        final_answer,
    }
}

/// Expand one forked context: generate a reasoning+answer continuation
/// ([`generate_demuxed`]), then value-score an answered node. The context is
/// moved back out (paired with a Context-free [`NodeOutcome`]) so a
/// surviving node can be expanded at the next level. Classification:
/// `Answered` → `Ok` (scored); `Incomplete` → kept out of the beam with its
/// partial reasoning preserved (#434); `Aborted` → `Error`. Only an `Ok`
/// node is scored — a node with no answer has nothing to rate.
async fn expand(
    mut ctx: Context,
    model: &Model,
    temperature: f32,
    top_p: f32,
    reasoning_budget: usize,
    answer_budget: usize,
    emitter: Option<&mut Emitter>,
    node_id: &str,
) -> (Context, NodeOutcome) {
    // Open the assistant turn for this branch. The forked context shares a
    // fully-flushed, cue-free prefix, so without this the first forward
    // pass would carry zero new tokens and spin the generator.
    ctx.cue();
    let stops = chat::stop_tokens(model);
    // Streams this node's reasoning + answer chunks as node_delta frames when
    // an emitter is present (#413 token stream); None on the non-stream path.
    let demux = generate_demuxed(
        &mut ctx,
        model,
        Sampler::TopP { temperature, p: top_p },
        reasoning_budget,
        answer_budget,
        &stops,
        emitter,
        node_id,
    )
    .await;
    let outcome = match demux.kind {
        DemuxKind::Answered => {
            let (score, score_error) = score_node(&ctx, model).await.into_parts();
            NodeOutcome {
                status: NodeStatus::Ok,
                content: demux.answer,
                reasoning: demux.reasoning,
                score,
                score_error,
                error: None,
            }
        }
        DemuxKind::Incomplete => NodeOutcome {
            status: NodeStatus::Incomplete,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(
                "no answer: the node ran out of reasoning budget before producing one".to_string(),
            ),
        },
        DemuxKind::Aborted(e) => NodeOutcome {
            status: NodeStatus::Error,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(e),
        },
    };
    (ctx, outcome)
}

/// Value evaluator: fork the answered context, ask for a 1–10 rating, and
/// parse the first in-range integer. The node already did its reasoning, so
/// the scorer is a cheap value HEAD — it always runs `/no_think` (NOT the
/// node `thinking` knob) to emit a bare integer rather than re-reasoning the
/// problem; a thinking scorer burns its budget restating the question and
/// lands no parseable integer at deeper levels (→ unscored, input-order
/// pruning, ~2× slower). Unlike node generation this does NOT demux: it reads
/// the raw text and lets [`parse_score`] find the integer anywhere in it
/// (skipping the empty `<think></think>` `/no_think` leaves), which is
/// robust to the integer landing in the same token batch as `</think>` — a
/// case the content-channel gate would drop. The three outcomes stay distinct
/// so an infra failure (fork/generate) is not mistaken for a benign
/// unparseable score — see [`ScoreOutcome`].
async fn score_node(ctx: &Context, model: &Model) -> ScoreOutcome {
    let mut sctx = match ctx.fork() {
        Ok(c) => c,
        Err(e) => return ScoreOutcome::Failed(format!("score fork failed: {e}")),
    };
    sctx.user(&with_thinking(SCORE_PROMPT, false));
    sctx.cue();
    let stops = chat::stop_tokens(model);
    let text = match sctx
        .generate(Sampler::TopP { temperature: 0.0, p: 1.0 }) // greedy
        .max_tokens(SCORE_MAX_TOKENS)
        .stop(&stops)
        .collect_text()
        .await
    {
        Ok(t) => t,
        Err(e) => return ScoreOutcome::Failed(format!("score generate failed: {e}")),
    };
    match parse_score(&text) {
        Some(v) => ScoreOutcome::Scored(v),
        None => ScoreOutcome::Unparseable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok_outcome(content: &str, score: Option<u8>) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Ok,
            content: content.to_string(),
            reasoning: String::new(),
            score,
            score_error: None,
            error: None,
        }
    }

    fn ok_outcome_score_failed(content: &str, err: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Ok,
            content: content.to_string(),
            reasoning: String::new(),
            score: None,
            score_error: Some(err.to_string()),
            error: None,
        }
    }

    fn err_outcome(msg: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Error,
            content: String::new(),
            reasoning: String::new(),
            score: None,
            score_error: None,
            error: Some(msg.to_string()),
        }
    }

    fn incomplete_outcome(reasoning: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Incomplete,
            content: String::new(),
            reasoning: reasoning.to_string(),
            score: None,
            score_error: None,
            error: Some("no answer".to_string()),
        }
    }

    fn branch(id: &str, parent: &str, b: usize, outcome: NodeOutcome) -> Branch {
        Branch {
            id: id.to_string(),
            parent_id: parent.to_string(),
            branch_index: b,
            outcome,
        }
    }

    fn cand(id: &str, score: Option<u8>, ok: bool) -> Candidate {
        Candidate {
            id: id.to_string(),
            score,
            ok,
        }
    }

    // ── ScoreOutcome (F4): the three classes the old Option<u8> merged ──

    #[test]
    fn score_outcome_splits_into_score_and_error() {
        assert_eq!(ScoreOutcome::Scored(7).into_parts(), (Some(7), None));
        assert_eq!(ScoreOutcome::Unparseable.into_parts(), (None, None));
        assert_eq!(
            ScoreOutcome::Failed("score fork failed: x".to_string()).into_parts(),
            (None, Some("score fork failed: x".to_string()))
        );
    }

    // ── materialize_level (F4 + F6) ──

    #[test]
    fn materialize_ok_branches_build_ok_nodes_sorted_beam() {
        let m = materialize_level(
            1,
            vec![
                branch("n0", "root", 0, ok_outcome("a", Some(5))),
                branch("n1", "root", 1, ok_outcome("b", Some(8))),
            ],
            2,
        );
        assert_eq!(m.nodes.len(), 2);
        assert!(m.nodes.iter().all(|n| n.status == NodeStatus::Ok));
        assert_eq!(m.nodes[0].content, "a");
        assert_eq!(m.candidates.iter().filter(|c| c.ok).count(), 2);
        // beam_width 2 keeps both, highest score first.
        assert_eq!(m.keep, vec!["n1", "n0"]);
    }

    #[test]
    fn materialize_generation_error_blanks_content_sets_error_excludes_from_beam() {
        let m = materialize_level(2, vec![branch("n0", "p", 0, err_outcome("boom"))], 2);
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Error);
        assert_eq!(n.content, "");
        assert_eq!(n.error.as_deref(), Some("boom"));
        assert_eq!(n.score_error, None);
        assert!(!m.candidates[0].ok);
        assert!(m.keep.is_empty());
    }

    #[test]
    fn materialize_surfaces_score_error_on_ok_node() {
        // F4: an ok node whose scorer infra failed carries score_error and
        // stays ok (eligible, ranked last by its None score) — distinct
        // from a benign unparseable null with no score_error.
        let m = materialize_level(
            1,
            vec![branch(
                "n0",
                "root",
                0,
                ok_outcome_score_failed("ans", "score fork failed: x"),
            )],
            2,
        );
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Ok);
        assert_eq!(n.score, None);
        assert_eq!(n.score_error.as_deref(), Some("score fork failed: x"));
        assert!(m.candidates[0].ok);
        assert_eq!(m.keep, vec!["n0"]);
    }

    #[test]
    fn materialize_incomplete_preserves_reasoning_blanks_answer_excludes_from_beam() {
        // #434/#437: a node that reasoned but never answered is kept in the
        // tree (so the UI can show the partial thought) but excluded from the
        // beam — it has no answer to select.
        let m = materialize_level(
            2,
            vec![branch(
                "n0",
                "p",
                0,
                incomplete_outcome("step 1: consider the base case…"),
            )],
            2,
        );
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Incomplete);
        assert_eq!(n.content, "");
        assert_eq!(n.reasoning, "step 1: consider the base case…");
        assert_eq!(n.error.as_deref(), Some("no answer"));
        assert!(!m.candidates[0].ok);
        assert!(m.keep.is_empty());
    }

    #[test]
    fn materialize_ok_node_carries_reasoning_and_stays_beam_eligible() {
        let m = materialize_level(
            1,
            vec![{
                let mut o = ok_outcome("the answer", Some(8));
                o.reasoning = "because X then Y".to_string();
                branch("n0", "root", 0, o)
            }],
            2,
        );
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Ok);
        assert_eq!(n.content, "the answer");
        assert_eq!(n.reasoning, "because X then Y");
        assert!(m.candidates[0].ok);
        assert_eq!(m.keep, vec!["n0"]);
    }

    #[test]
    fn with_thinking_appends_no_think_only_when_disabled() {
        assert_eq!(with_thinking("rate it", true), "rate it");
        assert_eq!(with_thinking("rate it", false), "rate it /no_think");
    }

    #[test]
    fn content_visible_only_outside_a_reasoning_block() {
        // Idle batch outside reasoning → visible answer content.
        assert!(content_visible(true, false));
        // The closing `</think>` batch: reasoning decoder is NOT Idle and we
        // WERE in reasoning → suppressed.
        assert!(!content_visible(false, true));
        // Inside reasoning (Idle never set there) → suppressed.
        assert!(!content_visible(false, false));
    }

    #[test]
    fn materialize_all_none_scores_keep_input_order() {
        // all-None path: ok nodes with no parseable score fall back to
        // deterministic input-order selection.
        let m = materialize_level(
            1,
            vec![
                branch("n0", "root", 0, ok_outcome("a", None)),
                branch("n1", "root", 1, ok_outcome("b", None)),
            ],
            1,
        );
        assert_eq!(m.keep, vec!["n0"]);
    }

    #[test]
    fn materialize_empty_level_is_empty() {
        // empty path: no forks succeeded (run records any failures as
        // error_leaf nodes directly, not through this helper).
        let m = materialize_level(1, vec![], 2);
        assert!(m.nodes.is_empty());
        assert!(m.candidates.is_empty());
        assert!(m.keep.is_empty());
    }

    // ── fold_level (F7) ──

    #[test]
    fn fold_advances_pool_when_level_has_survivors() {
        let prev = vec![cand("old", Some(1), true)];
        let this = vec![cand("new", Some(9), true)];
        let (pool, stop) = fold_level(prev, this, &["new".to_string()]);
        assert!(!stop);
        assert_eq!(pool.len(), 1);
        assert_eq!(pool[0].id, "new");
    }

    #[test]
    fn fold_empty_frontier_retains_prev_and_stops() {
        // F7: a level where every fork failed (no candidates, empty keep)
        // must NOT overwrite the pool and must stop the search.
        let prev = vec![cand("good", Some(7), true)];
        let (pool, stop) = fold_level(prev, vec![], &[]);
        assert!(stop);
        assert_eq!(pool[0].id, "good");
    }

    #[test]
    fn fold_all_error_level_retains_prev_and_stops() {
        // A level that forked but every generation errored: candidates
        // exist but none ok → keep empty → retain prior pool, stop.
        let prev = vec![cand("good", Some(7), true)];
        let this = vec![cand("e0", None, false), cand("e1", None, false)];
        let (pool, stop) = fold_level(prev, this, &[]);
        assert!(stop);
        assert_eq!(pool[0].id, "good");
    }

    // ── finalize (F6/F7 end to end) ──

    fn ok_leaf(id: &str, content: &str, score: Option<u8>) -> Node {
        Node {
            id: id.to_string(),
            parent_id: Some("root".to_string()),
            depth: 1,
            branch_index: Some(0),
            content: content.to_string(),
            reasoning: String::new(),
            score,
            status: NodeStatus::Ok,
            error: None,
            score_error: None,
            children: Vec::new(),
        }
    }

    #[test]
    fn finalize_picks_best_ok_leaf_content() {
        let flat = vec![
            Node::root(),
            ok_leaf("a", "answer-a", Some(3)),
            ok_leaf("b", "answer-b", Some(9)),
        ];
        let last = vec![cand("a", Some(3), true), cand("b", Some(9), true)];
        let out = finalize(flat, &last);
        assert_eq!(out.selected_node_id.as_deref(), Some("b"));
        assert_eq!(out.final_answer.as_deref(), Some("answer-b"));
    }

    #[test]
    fn finalize_all_error_last_level_nulls_answer() {
        let flat = vec![Node::root()];
        let last = vec![cand("e0", None, false), cand("e1", Some(8), false)];
        let out = finalize(flat, &last);
        assert!(out.selected_node_id.is_none());
        assert!(out.final_answer.is_none());
    }

    #[test]
    fn finalize_empty_last_level_nulls_answer() {
        let out = finalize(vec![Node::root()], &[]);
        assert!(out.selected_node_id.is_none());
        assert!(out.final_answer.is_none());
    }

    #[test]
    fn f7_late_full_failure_keeps_earlier_level_answer() {
        // End-to-end F7 regression: level 1 produces an ok leaf; level 2
        // fully fails (every fork dies → `run` pushes error_leaf nodes and
        // materialize sees no successful branch). The fold keeps level 1 as
        // the pool, so the final answer is level 1's best — not null, even
        // though the deepest *attempted* level had no leaf.
        let mut flat = vec![Node::root()];

        let LevelMaterialized {
            nodes,
            candidates,
            keep,
        } = materialize_level(
            1,
            vec![branch("n0", "root", 0, ok_outcome("L1-best", Some(6)))],
            2,
        );
        flat.extend(nodes);
        let (pool1, stop1) = fold_level(Vec::new(), candidates, &keep);
        assert!(!stop1);

        // Level 2: every fork failed → `run` records the failure as an
        // error leaf directly (here via tree::error_leaf), and the
        // materializer sees no successful branch.
        flat.push(error_leaf("n0", 2, 0, "fork failed: gone".to_string()));
        let LevelMaterialized {
            nodes,
            candidates,
            keep,
        } = materialize_level(2, vec![], 2);
        flat.extend(nodes);
        let (pool2, stop2) = fold_level(pool1, candidates, &keep);
        assert!(stop2);

        let out = finalize(flat, &pool2);
        assert_eq!(out.selected_node_id.as_deref(), Some("n0"));
        assert_eq!(out.final_answer.as_deref(), Some("L1-best"));
    }
}
