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
use super::tree::{
    Candidate, Node, assemble, best_leaf, error_leaf, new_node_id, parse_score, select_beam,
};

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
/// messages) **and flushed, but NOT cued** — the assistant turn is
/// opened per branch in [`expand`]. A cue committed into the shared
/// prefix would be duplicated across every fork and waste the zero-token
/// forward pass that the level-1 spin fix removed.
pub async fn run(root_ctx: Context, params: &TotParams) -> SearchOutcome {
    let mut flat: Vec<Node> = vec![Node::root()];
    let mut frontier: Vec<Frontier> = vec![Frontier {
        ctx: root_ctx,
        node_id: "root".to_string(),
    }];
    // Candidates at the deepest level reached — used to pick the best
    // (ok-only) leaf.
    let mut last_level: Vec<Candidate> = Vec::new();

    for level in 1..=params.depth {
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
            for mut f in frontier {
                f.ctx.user(REFINE_INSTRUCTION);
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
                        flat.push(error_leaf(
                            &f.node_id,
                            level,
                            b,
                            format!("fork failed: {e}"),
                        ));
                    }
                }
            }
        }
        let results = join_all(futs).await;

        // Materialize nodes + collect candidates/survivors for pruning.
        let mut scored: Vec<Candidate> = Vec::new();
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
            scored.push(Candidate {
                id: id.clone(),
                score: ex.score,
                ok: !is_error,
            });
            survivors.push(Frontier {
                ctx: ex.ctx,
                node_id: id,
            });
        }

        // Prune to the top `beam_width` for the next level. `select_beam`
        // excludes error nodes, so a failed branch never survives to be
        // re-expanded (its partially-advanced context is dropped here).
        let keep = select_beam(&scored, params.beam_width);
        frontier = survivors
            .into_iter()
            .filter(|f| keep.contains(&f.node_id))
            .collect();
        last_level = scored;
    }

    // Best ok leaf at the deepest level (error leaves excluded; None
    // scores rank lowest; all-None-ok → first by stable order). When no
    // ok leaf exists, `final_answer`/`selected_node_id` honestly null out
    // — matching the all-fork-fail path.
    let best = best_leaf(&last_level);
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
    // Open the assistant turn for this branch. The forked context shares a
    // fully-flushed, cue-free prefix, so without this the first forward
    // pass would carry zero new tokens and spin the generator.
    ctx.cue();
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
