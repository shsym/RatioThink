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

use futures::future::join_all;
use inferlet::sample::Sampler;
use inferlet::Context;

use super::schema::TotParams;
use super::tree::{
    assemble, best_leaf, error_leaf, new_node_id, parse_score, select_beam, Candidate, Node,
    NodeStatus,
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
    content: String,
    score: Option<u8>,
    score_error: Option<String>,
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
pub async fn run(root_ctx: Context, params: &TotParams) -> SearchOutcome {
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

        let results = join_all(ctxs.into_iter().map(|c| {
            expand(
                c,
                params.temperature,
                params.top_p,
                params.max_tokens_per_node,
            )
        }))
        .await;

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
        let is_error = b.outcome.status == NodeStatus::Error;
        // A generation error carries its message in `content`; move it to
        // the node's `error` field and blank `content` (wire contract).
        let error = if is_error && !b.outcome.content.is_empty() {
            Some(b.outcome.content.clone())
        } else {
            None
        };
        candidates.push(Candidate {
            id: b.id.clone(),
            score: b.outcome.score,
            ok: !is_error,
        });
        nodes.push(Node {
            id: b.id,
            parent_id: Some(b.parent_id),
            depth: level,
            branch_index: Some(b.branch_index),
            content: if is_error {
                String::new()
            } else {
                b.outcome.content
            },
            score: b.outcome.score,
            status: b.outcome.status,
            error,
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

/// Expand one forked context: generate a continuation, then value-score
/// it. The context is moved back out (paired with a Context-free
/// [`NodeOutcome`]) so a surviving node can be expanded at the next level.
async fn expand(
    mut ctx: Context,
    temperature: f32,
    top_p: f32,
    max_tokens: usize,
) -> (Context, NodeOutcome) {
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
    let outcome = match result {
        Ok(text) => {
            let (score, score_error) = score_node(&ctx).await.into_parts();
            NodeOutcome {
                status: NodeStatus::Ok,
                content: text,
                score,
                score_error,
            }
        }
        // Carry the error message in `content`; `materialize_level` moves
        // it to the node's `error` field and blanks `content`.
        Err(e) => NodeOutcome {
            status: NodeStatus::Error,
            content: e,
            score: None,
            score_error: None,
        },
    };
    (ctx, outcome)
}

/// Value evaluator: fork the answered context, ask for a 1–10 rating,
/// greedy-decode a few tokens, and parse the integer. The three outcomes
/// are kept distinct so an infra failure (fork/generate) is not mistaken
/// for a benign unparseable score — see [`ScoreOutcome`].
async fn score_node(ctx: &Context) -> ScoreOutcome {
    let mut sctx = match ctx.fork() {
        Ok(c) => c,
        Err(e) => return ScoreOutcome::Failed(format!("score fork failed: {e}")),
    };
    sctx.user(SCORE_PROMPT);
    sctx.cue();
    let text = match sctx
        .generate(Sampler::TopP { temperature: 0.0, p: 1.0 }) // greedy
        .max_tokens(SCORE_MAX_TOKENS)
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
            score,
            score_error: None,
        }
    }

    fn ok_outcome_score_failed(content: &str, err: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Ok,
            content: content.to_string(),
            score: None,
            score_error: Some(err.to_string()),
        }
    }

    fn err_outcome(msg: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Error,
            content: msg.to_string(),
            score: None,
            score_error: None,
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
