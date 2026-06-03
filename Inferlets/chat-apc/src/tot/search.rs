//! Tree-of-Thought BFS beam search orchestration (Yao et al. 2023).
//!
//! For each of `depth` levels: every frontier node forks `breadth`
//! children from its common prefix (KV-cache sharing), each child
//! generates a candidate continuation, and a value evaluator scores it
//! 1–10. The top `beam_width` candidates by score survive as the next
//! frontier. The best-scoring leaf at the deepest level is the final
//! answer.
//!
//! Branches at a level are generated concurrently via
//! `futures::future::join_all`. This module calls WIT-backed SDK APIs
//! (`Context`/`generate`), so it is exercised by the real-engine e2e
//! rather than native unit tests.

use futures::future::join_all;
use inferlet::sample::Sampler;
use inferlet::Context;

use super::schema::TotParams;
use super::tree::{assemble, new_node_id, parse_score, select_beam, Node};

/// Built-in expansion instruction appended before forking at levels > 1.
/// Level-1 children answer the conversation directly (sibling diversity
/// comes from sampling temperature).
const REFINE_INSTRUCTION: &str = "Critique your previous answer, then give a distinct, \
     improved continuation toward correctly answering the original question. Be concise.";

/// Value-evaluator prompt (independent per-node scoring).
const SCORE_PROMPT: &str = "On a scale of 1 to 10, rate how promising the assistant's \
     latest answer is toward correctly and completely answering the original question. \
     Respond with only a single integer from 1 to 10.";

/// Token budget for a scoring generation — just enough for an integer.
const SCORE_MAX_TOKENS: usize = 16;

/// Outcome of one node expansion: the context (moved back so a surviving
/// node can be expanded next level), generated content, status, and score.
struct Expanded {
    ctx: Context,
    content: String,
    status: &'static str,
    score: Option<u8>,
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
/// messages) and cued.
pub async fn run(root_ctx: Context, params: &TotParams) -> SearchOutcome {
    let mut flat: Vec<Node> = vec![Node::root()];
    let mut frontier: Vec<Frontier> = vec![Frontier {
        ctx: root_ctx,
        node_id: "root".to_string(),
    }];
    // Scores at the deepest level reached — used to pick the best leaf.
    let mut last_level_scored: Vec<(String, Option<u8>)> = Vec::new();

    for level in 1..=params.depth {
        // Levels > 1 refine the parent before forking: append the refine
        // user-turn, then `cue()` to open the assistant turn the children
        // will generate into (mirrors the pie tree-of-thought example).
        // Level 1 needs no prep — the root's cue is already committed via
        // `fill_context` + the root flush, and is shared into every fork.
        // Sequential (≤ beam_width parents; flush is light). A flush
        // failure is best-effort.
        if level > 1 {
            for f in frontier.iter_mut() {
                f.ctx.user(REFINE_INSTRUCTION);
                f.ctx.cue();
                let _ = f.ctx.flush().await;
            }
        }

        // Fork every child; generate + score successful forks concurrently.
        let mut metas: Vec<(String, usize)> = Vec::new();
        let mut futs = Vec::new();
        for f in frontier.iter() {
            for b in 0..params.breadth {
                match f.ctx.fork() {
                    Ok(child) => {
                        metas.push((f.node_id.clone(), b));
                        futs.push(expand(
                            child,
                            params.temperature,
                            params.top_p,
                            params.max_tokens_per_node,
                        ));
                    }
                    Err(e) => {
                        // No context to carry → record an error leaf inline.
                        flat.push(Node {
                            id: new_node_id(),
                            parent_id: Some(f.node_id.clone()),
                            depth: level,
                            branch_index: Some(b),
                            content: String::new(),
                            score: None,
                            status: "error",
                            error: Some(format!("fork failed: {e}")),
                            children: Vec::new(),
                        });
                    }
                }
            }
        }
        let results = join_all(futs).await;

        // Materialize nodes + collect survivors for pruning.
        let mut scored: Vec<(String, Option<u8>)> = Vec::new();
        let mut survivors: Vec<Frontier> = Vec::new();
        for ((parent_id, branch_index), ex) in metas.into_iter().zip(results) {
            let id = new_node_id();
            let is_error = ex.status == "error";
            let error = if is_error && !ex.content.is_empty() {
                Some(ex.content.clone())
            } else {
                None
            };
            flat.push(Node {
                id: id.clone(),
                parent_id: Some(parent_id),
                depth: level,
                branch_index: Some(branch_index),
                content: if is_error { String::new() } else { ex.content },
                score: ex.score,
                status: ex.status,
                error,
                children: Vec::new(),
            });
            scored.push((id.clone(), ex.score));
            survivors.push(Frontier {
                ctx: ex.ctx,
                node_id: id,
            });
        }

        // Prune to the top `beam_width` for the next level.
        let keep = select_beam(scored.clone(), params.beam_width);
        frontier = survivors
            .into_iter()
            .filter(|f| keep.contains(&f.node_id))
            .collect();
        last_level_scored = scored;
    }

    // Best leaf at the deepest level (None scores rank lowest; all-None
    // → first by stable order).
    let best = select_beam(last_level_scored, 1).into_iter().next();
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

/// Expand one forked context: generate a continuation, then value-score
/// it. The context is moved back out so a surviving node can be expanded
/// at the next level.
async fn expand(mut ctx: Context, temperature: f32, top_p: f32, max_tokens: usize) -> Expanded {
    let stops = inferlet::chat::stop_tokens(ctx.model());
    let result = ctx
        .generate(Sampler::TopP { temperature, p: top_p })
        .max_tokens(max_tokens)
        .stop(&stops)
        .collect_text()
        .await;
    match result {
        Ok(text) => {
            let score = score_node(&ctx).await;
            Expanded {
                ctx,
                content: text,
                status: "ok",
                score,
            }
        }
        // Carry the error message in `content`; `run` moves it to the
        // node's `error` field and leaves `content` empty.
        Err(e) => Expanded {
            ctx,
            content: e,
            status: "error",
            score: None,
        },
    }
}

/// Value evaluator: fork the answered context, ask for a 1–10 rating,
/// greedy-decode a few tokens, and parse the integer. Any failure → `None`.
async fn score_node(ctx: &Context) -> Option<u8> {
    let mut sctx = ctx.fork().ok()?;
    sctx.user(SCORE_PROMPT);
    sctx.cue();
    let text = sctx
        .generate(Sampler::TopP { temperature: 0.0, p: 1.0 }) // greedy
        .max_tokens(SCORE_MAX_TOKENS)
        .collect_text()
        .await
        .ok()?;
    parse_score(&text)
}
