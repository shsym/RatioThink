//! Pure tree data model + helpers for the tree-of-thought mode.
//!
//! No WIT calls live here, so this module is unit-tested natively via
//! `cargo test --lib` (the wasm-only generation path lives in
//! [`super::search`]).

use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// Lifecycle status of a tree node. Serializes to the snake_case wire
/// strings `"root" | "ok" | "error"` — byte-identical to the prior
/// `&'static str` representation — so this is a pure internal tightening,
/// not a wire change. Modeling it as an enum makes illegal status values
/// unrepresentable and lets the orchestration branch on a variant instead
/// of string-comparing.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NodeStatus {
    /// The synthetic conversation-prefix root (never generated or scored).
    Root,
    /// A successfully generated candidate continuation (a non-empty answer).
    Ok,
    /// Generation — or the fork that precedes it — failed for this node.
    Error,
    /// The node generated reasoning but no usable answer — the model ran out
    /// of budget mid-`<think>` (truncated thought) or closed the block and
    /// emitted nothing after it (#434). Its `reasoning` is preserved so the
    /// UI can show the partial thought; like `Error` it is kept out of the
    /// beam and never selected as the final answer.
    Incomplete,
}

/// One node in the generated thought tree.
///
/// * `status` is a [`NodeStatus`] (`"root" | "ok" | "error"` on the wire).
/// * `score` is the value-evaluator rating (1–10), or `null` when the
///   scorer returned no usable integer or failed outright.
/// * `error` carries a per-node *generation* diagnostic on partial failure
///   (omitted from the wire otherwise) — this is how the response
///   represents per-node failures while the rest of the tree still returns.
/// * `score_error` carries a per-node *scoring-infrastructure* diagnostic
///   (a fork/generate failure inside the value evaluator), omitted when
///   absent. It distinguishes an infra scorer collapse — which silently
///   degrades the beam to input-order pruning — from a benign `null` score
///   the model simply didn't emit a parseable integer for.
#[derive(Serialize, Clone, Debug)]
pub struct Node {
    pub id: String,
    pub parent_id: Option<String>,
    pub depth: usize,
    pub branch_index: Option<usize>,
    pub content: String,
    /// The demuxed `<think>` reasoning trace for this node, separated from
    /// `content` (the answer) at generation time (#413/#437). Omitted from
    /// the wire when empty (non-reasoning model, or `thinking:false`).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub reasoning: String,
    pub score: Option<u8>,
    pub status: NodeStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub score_error: Option<String>,
    pub children: Vec<Node>,
}

impl Node {
    /// The synthetic root node (the conversation prefix). Carries no
    /// generated content and is never scored.
    pub fn root() -> Self {
        Node {
            id: "root".to_string(),
            parent_id: None,
            depth: 0,
            branch_index: None,
            content: String::new(),
            reasoning: String::new(),
            score: None,
            status: NodeStatus::Root,
            error: None,
            score_error: None,
            children: Vec::new(),
        }
    }
}

/// Top-level tree-of-thought response envelope.
#[derive(Serialize)]
pub struct TreeResponse {
    pub id: String,
    pub object: &'static str,
    pub model: String,
    pub breadth: usize,
    pub depth: usize,
    pub beam_width: usize,
    pub root: Node,
    pub selected_node_id: Option<String>,
    pub final_answer: Option<String>,
    /// `true` when `final_answer` is the post-search synthesis, `false` when
    /// the raw best-leaf content stood (#523 Part A F1) — lets a non-streaming
    /// caller (e.g. the gated smoke) assert the synthesizer actually ran.
    pub synthesized: bool,
    /// Total generated-token throughput for the completed ToT run (#542).
    /// Counts model-generated decode tokens only — branch reasoning/answers,
    /// scorer generations, and synthesis/finalization generations — never
    /// prompt/input tokens. Omitted only when a completed run somehow has no
    /// positive token/elapsed denominator, to avoid bogus UI metrics.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation_metrics: Option<GenerationMetrics>,
}

/// Total generated-token throughput for one completed tree-of-thought run.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct GenerationMetrics {
    pub output_tokens: usize,
    pub elapsed_s: f64,
    pub tokens_per_sec: f64,
}

impl GenerationMetrics {
    pub fn build(output_tokens: usize, elapsed: Duration) -> Option<Self> {
        let elapsed_s = elapsed.as_secs_f64();
        if output_tokens == 0 || elapsed_s <= 0.0 {
            return None;
        }
        Some(Self {
            output_tokens,
            elapsed_s,
            tokens_per_sec: output_tokens as f64 / elapsed_s,
        })
    }
}

static NODE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Per-process unique node id. Ids only need to be unique within one
/// response, so a monotonic counter suffices.
pub fn new_node_id() -> String {
    let n = NODE_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("tot-n{n}")
}

/// Per-process unique response id (distinct prefix from node ids).
pub fn new_tree_id() -> String {
    let n = NODE_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("tot-{n}")
}

/// An error leaf: a node whose branch failed before producing a scored
/// answer (a failed `fork()`, or a failed refine `flush()`). Empty
/// `content` and `score: None` keep it out of the beam, while `error`
/// carries the diagnostic so the failure is visible on the wire rather
/// than silently downgraded. `branch_index` orders it under its parent.
pub fn error_leaf(parent_id: &str, depth: usize, branch_index: usize, error: String) -> Node {
    Node {
        id: new_node_id(),
        parent_id: Some(parent_id.to_string()),
        depth,
        branch_index: Some(branch_index),
        content: String::new(),
        reasoning: String::new(),
        score: None,
        status: NodeStatus::Error,
        error: Some(error),
        score_error: None,
        children: Vec::new(),
    }
}

/// Parse a score in `[1, 10]` out of value-evaluator output.
///
/// The verification scorer (#555) re-solves the question as visible text — which
/// can contain out-of-range numbers like recomputed dollar amounts — and ends
/// with a `SCORE: N` verdict line. So we anchor on the LAST `score` mention and
/// read the integer that follows it; that is the rating. If the anchored value
/// is out of range the scorer mis-formatted, and we stay unscored rather than
/// grabbing a stray number from the worked check. With no `score` anchor at all
/// (back-compat for bare `"8"` / `"10/10"`) we take the LAST in-range integer in
/// the text. Returns `None` for no usable score.
pub fn parse_score(text: &str) -> Option<u8> {
    // Digits are case-invariant, so work entirely on the lowercased copy: its
    // byte offsets line up with the digit runs we slice out of it.
    let lower = text.to_lowercase();
    if let Some(pos) = lower.rfind("score") {
        // Skip the word "score" itself (5 ASCII bytes) so a stray digit inside
        // it can't ever match; read the first digit run after the anchor.
        if let Some(v) = first_digit_run_value(&lower[pos + 5..]) {
            return if (1..=10).contains(&v) {
                Some(v as u8)
            } else {
                None
            };
        }
    }
    last_in_range_integer(&lower)
}

/// Value of the first contiguous ASCII digit run in `s`, or `None` if `s`
/// contains no digits.
fn first_digit_run_value(s: &str) -> Option<u16> {
    let mut digits = String::new();
    for ch in s.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else if !digits.is_empty() {
            break;
        }
    }
    digits.parse().ok()
}

/// The last contiguous ASCII digit run in `s` whose value is in `[1, 10]`.
fn last_in_range_integer(s: &str) -> Option<u8> {
    let mut best = None;
    for run in s.split(|c: char| !c.is_ascii_digit()) {
        if run.is_empty() {
            continue;
        }
        if let Ok(v) = run.parse::<u16>() {
            if (1..=10).contains(&v) {
                best = Some(v as u8);
            }
        }
    }
    best
}

/// A scored candidate reduced to what beam selection needs. `ok` is
/// `false` for a node whose generation failed (`status:"error"`); such
/// nodes are excluded from both beam survival and final-answer
/// selection, so `final_answer`/`selected_node_id` honestly become
/// `null` when no ok leaf exists (matching the all-fork-fail path).
#[derive(Clone, Debug)]
pub struct Candidate {
    pub id: String,
    pub score: Option<u8>,
    pub ok: bool,
    /// Search depth at which this candidate was generated. The final-answer
    /// fallback uses this to avoid exposing an intermediate path step as the
    /// terminal `final_answer` when the final depth failed.
    pub depth: usize,
    /// The candidate's generated answer, used by [`select_beam_diverse`]
    /// for near-duplicate detection. Empty for non-`ok` candidates (no
    /// answer to compare) and in tests that only exercise score selection.
    pub content: String,
}

/// Ids of the top `m` **ok** candidates, score-descending (`None` ranks
/// lowest), stable on ties. Error candidates are excluded entirely, so
/// an error node is never kept in the beam.
pub fn select_beam(candidates: &[Candidate], m: usize) -> Vec<String> {
    let mut ok: Vec<&Candidate> = candidates.iter().filter(|c| c.ok).collect();
    // `Option<u8>` orders `None < Some(_)`, so `b.cmp(a)` puts the
    // highest scores first and `None` entries last. Stable → ties keep
    // input order (deterministic beam + best-leaf selection).
    ok.sort_by(|a, b| b.score.cmp(&a.score));
    ok.into_iter().take(m).map(|c| c.id.clone()).collect()
}

/// Diversity-aware beam (#523): like [`select_beam`], but when two
/// surviving siblings are near-duplicate answers (word-set Jaccard ≥
/// `threshold`, see [`super::diversity`]) the lower-scored paraphrase is
/// deferred so a *distinct* lower-scored branch can take the beam slot
/// instead. The beam width is still honored — if diversity can't fill it,
/// deferred paraphrases backfill in score order — so node counts and the
/// expand-survivors invariant are unchanged; only *which* equally-deep
/// branches survive shifts toward diversity.
///
/// This is what stops three paraphrases of one idea from filling the beam
/// and being reported as a successful multi-branch search. Non-`ok`
/// candidates are excluded exactly as in [`select_beam`]. Pure →
/// unit-tested.
pub fn select_beam_diverse(candidates: &[Candidate], m: usize, threshold: f32) -> Vec<String> {
    let mut ranked: Vec<&Candidate> = candidates.iter().filter(|c| c.ok).collect();
    ranked.sort_by(|a, b| b.score.cmp(&a.score));

    let mut kept: Vec<&Candidate> = Vec::with_capacity(m);
    let mut deferred: Vec<&Candidate> = Vec::new();
    for c in ranked {
        if kept.len() >= m {
            break;
        }
        let dup = kept
            .iter()
            .any(|k| super::diversity::is_near_duplicate(&k.content, &c.content, threshold));
        if dup {
            deferred.push(c);
        } else {
            kept.push(c);
        }
    }
    // Diversity left the beam under-full → backfill with the deferred
    // paraphrases (score order) so beam_width is still honored.
    for c in deferred {
        if kept.len() >= m {
            break;
        }
        kept.push(c);
    }
    kept.into_iter().map(|c| c.id.clone()).collect()
}

/// Id of the single best **ok** candidate (highest score, `None` last,
/// stable), or `None` when no ok candidate exists.
pub fn best_leaf(candidates: &[Candidate]) -> Option<String> {
    select_beam(candidates, 1).into_iter().next()
}

/// Assemble a nested tree from a flat node list via `parent_id` links.
/// O(n²) — fine for `n ≤ MAX_NODES`. Children are sorted by
/// `(depth, branch_index)` for deterministic output.
pub fn assemble(flat: &[Node], id: &str) -> Node {
    let mut node = flat
        .iter()
        .find(|n| n.id == id)
        .expect("node id present in flat list")
        .clone();
    let mut kids: Vec<Node> = flat
        .iter()
        .filter(|n| n.parent_id.as_deref() == Some(id))
        .map(|n| assemble(flat, &n.id))
        .collect();
    kids.sort_by_key(|n| (n.depth, n.branch_index.unwrap_or(0)));
    node.children = kids;
    node
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_score_basic() {
        assert_eq!(parse_score("Score: 7"), Some(7));
    }

    #[test]
    fn parse_score_ten() {
        assert_eq!(parse_score("10/10"), Some(10));
    }

    #[test]
    fn parse_score_zero_rejected() {
        assert_eq!(parse_score("0"), None);
    }

    #[test]
    fn parse_score_out_of_range_rejected() {
        assert_eq!(parse_score("11"), None);
        assert_eq!(parse_score("42"), None);
    }

    #[test]
    fn parse_score_no_digits() {
        assert_eq!(parse_score("no number here"), None);
    }

    #[test]
    fn parse_score_anchors_on_final_score_line_past_recomputed_numbers() {
        // The verification scorer (#555) writes its worked check first — full
        // of out-of-range numbers — then the verdict line. The anchor must read
        // the rating, not a recomputed dollar amount.
        let text = "Let me check: 4 notebooks at $3 is $12, 5 pens at $2 is $10, \
            minus $4 is $18. The reply says $17, which is wrong.\nSCORE: 2";
        assert_eq!(parse_score(text), Some(2));
    }

    #[test]
    fn parse_score_anchor_takes_last_score_mention() {
        let text = "The reply scores poorly on correctness. Final SCORE: 3";
        assert_eq!(parse_score(text), Some(3));
    }

    #[test]
    fn parse_score_anchor_out_of_range_stays_unscored() {
        // An explicit but malformed verdict is not silently rescued by grabbing
        // a stray in-range number from the worked check above it.
        let text = "I computed 8 dollars. SCORE: 42";
        assert_eq!(parse_score(text), None);
    }

    #[test]
    fn parse_score_no_anchor_falls_back_to_last_in_range_integer() {
        // Back-compat for a bare rating with no `score` word.
        assert_eq!(parse_score("8"), Some(8));
        assert_eq!(parse_score("I think 9 is right, maybe 7"), Some(7));
    }

    fn cand(id: &str, score: Option<u8>, ok: bool) -> Candidate {
        Candidate {
            id: id.to_string(),
            score,
            ok,
            depth: 1,
            content: String::new(),
        }
    }

    fn cand_text(id: &str, score: Option<u8>, content: &str) -> Candidate {
        Candidate {
            id: id.to_string(),
            score,
            ok: true,
            depth: 1,
            content: content.to_string(),
        }
    }

    #[test]
    fn beam_keeps_top_m_none_last() {
        let c = vec![
            cand("a", Some(3), true),
            cand("b", None, true),
            cand("c", Some(9), true),
            cand("d", Some(5), true),
        ];
        assert_eq!(select_beam(&c, 2), vec!["c", "d"]);
    }

    #[test]
    fn beam_all_none_is_deterministic() {
        let c = vec![cand("a", None, true), cand("b", None, true)];
        // Stable sort keeps the first input on ties.
        assert_eq!(select_beam(&c, 1), vec!["a"]);
    }

    #[test]
    fn beam_excludes_error_nodes_even_when_higher_scored() {
        // An error node carrying a (stale) high score must never be kept.
        let c = vec![
            cand("err", Some(10), false),
            cand("ok1", Some(4), true),
            cand("ok2", Some(2), true),
        ];
        assert_eq!(select_beam(&c, 3), vec!["ok1", "ok2"]);
    }

    #[test]
    fn beam_all_error_keeps_nothing() {
        let c = vec![cand("e1", None, false), cand("e2", Some(8), false)];
        assert!(select_beam(&c, 5).is_empty());
    }

    // ── select_beam_diverse (#523): paraphrase guard ──

    #[test]
    fn diverse_beam_demotes_paraphrase_for_a_distinct_branch() {
        // Two near-identical high-score paraphrases + one distinct lower
        // score. A plain top-2 beam keeps both paraphrases; the diverse
        // beam keeps the top paraphrase + the distinct branch, so
        // three-paraphrases-of-one-idea can't pass as a multi-branch search.
        let c = vec![
            cand_text(
                "p1",
                Some(9),
                "choose a date plan the party decorate food games",
            ),
            cand_text(
                "p2",
                Some(8),
                "choose the date plan a party decorate food and games",
            ),
            cand_text(
                "d",
                Some(5),
                "budget first: set spend cap then allocate per category",
            ),
        ];
        let keep = select_beam_diverse(&c, 2, super::super::diversity::DUP_THRESHOLD);
        assert_eq!(keep, vec!["p1", "d"]);
    }

    #[test]
    fn diverse_beam_backfills_when_diversity_cannot_fill_width() {
        // All three are paraphrases: the beam still fills to width 2 (node
        // counts + survivor invariants preserved), preferring higher scores.
        let c = vec![
            cand_text("p1", Some(9), "alpha beta gamma delta epsilon"),
            cand_text("p2", Some(8), "alpha beta gamma delta epsilon zeta"),
            cand_text("p3", Some(7), "alpha beta gamma delta epsilon eta"),
        ];
        let keep = select_beam_diverse(&c, 2, super::super::diversity::DUP_THRESHOLD);
        assert_eq!(keep, vec!["p1", "p2"]);
    }

    #[test]
    fn diverse_beam_matches_plain_beam_when_all_distinct() {
        let c = vec![
            cand_text("a", Some(3), "venue first approach"),
            cand_text("b", None, "guest list first approach"),
            cand_text("c", Some(9), "theme first approach"),
            cand_text("d", Some(5), "budget first approach"),
        ];
        assert_eq!(
            select_beam_diverse(&c, 2, super::super::diversity::DUP_THRESHOLD),
            vec!["c", "d"]
        );
    }

    #[test]
    fn diverse_beam_excludes_non_ok_candidates() {
        let c = vec![
            cand("err", Some(10), false),
            cand_text("ok1", Some(4), "real answer one"),
            cand_text("ok2", Some(2), "real answer two distinct"),
        ];
        assert_eq!(
            select_beam_diverse(&c, 3, super::super::diversity::DUP_THRESHOLD),
            vec!["ok1", "ok2"]
        );
    }

    #[test]
    fn best_leaf_all_error_is_none() {
        // All-error deepest level → no ok leaf → null final answer.
        let c = vec![cand("e1", None, false), cand("e2", Some(7), false)];
        assert_eq!(best_leaf(&c), None);
    }

    #[test]
    fn best_leaf_skips_error_picks_best_ok() {
        // Mixed ok/error: never selects an error node, picks the best ok.
        let c = vec![
            cand("err", Some(10), false),
            cand("ok_lo", Some(3), true),
            cand("ok_hi", Some(8), true),
        ];
        assert_eq!(best_leaf(&c), Some("ok_hi".to_string()));
    }

    #[test]
    fn best_leaf_all_ok_none_score_is_first() {
        let c = vec![cand("a", None, true), cand("b", None, true)];
        assert_eq!(best_leaf(&c), Some("a".to_string()));
    }

    #[test]
    fn error_leaf_is_wire_visible_and_beam_excludable() {
        let n = error_leaf("p1", 2, 1, "refine flush failed: boom".to_string());
        assert_eq!(n.parent_id.as_deref(), Some("p1"));
        assert_eq!(n.depth, 2);
        assert_eq!(n.branch_index, Some(1));
        assert_eq!(n.status, NodeStatus::Error);
        // Empty content + no score keep it out of the beam.
        assert!(n.content.is_empty());
        assert_eq!(n.score, None);
        // The diagnostic is serialized (not omitted) so a failed refine is
        // visible in the response instead of a silent re-roll downgrade.
        let v = serde_json::to_value(&n).unwrap();
        assert_eq!(
            v.get("error").and_then(|e| e.as_str()),
            Some("refine flush failed: boom"),
        );
    }

    #[test]
    fn assemble_links_children() {
        let flat = vec![
            Node::root(),
            Node {
                id: "x".to_string(),
                parent_id: Some("root".to_string()),
                depth: 1,
                branch_index: Some(0),
                content: "c".to_string(),
                reasoning: String::new(),
                score: Some(5),
                status: NodeStatus::Ok,
                error: None,
                score_error: None,
                children: Vec::new(),
            },
        ];
        let root = assemble(&flat, "root");
        assert_eq!(root.children.len(), 1);
        assert_eq!(root.children[0].id, "x");
    }

    #[test]
    fn assemble_sorts_children_by_branch_index() {
        let mut flat = vec![Node::root()];
        for b in [2usize, 0, 1] {
            flat.push(Node {
                id: format!("n{b}"),
                parent_id: Some("root".to_string()),
                depth: 1,
                branch_index: Some(b),
                content: String::new(),
                reasoning: String::new(),
                score: None,
                status: NodeStatus::Ok,
                error: None,
                score_error: None,
                children: Vec::new(),
            });
        }
        let root = assemble(&flat, "root");
        let order: Vec<usize> = root
            .children
            .iter()
            .map(|n| n.branch_index.unwrap())
            .collect();
        assert_eq!(order, vec![0, 1, 2]);
    }

    #[test]
    fn response_serializes_expected_keys() {
        let resp = TreeResponse {
            id: "tot-1".to_string(),
            object: "tree_of_thought",
            model: "m".to_string(),
            breadth: 3,
            depth: 2,
            beam_width: 2,
            root: Node::root(),
            selected_node_id: None,
            final_answer: None,
            synthesized: false,
            generation_metrics: None,
        };
        let v = serde_json::to_value(&resp).unwrap();
        for k in [
            "id",
            "object",
            "model",
            "breadth",
            "depth",
            "beam_width",
            "root",
            "selected_node_id",
            "final_answer",
            "synthesized",
        ] {
            assert!(v.get(k).is_some(), "response missing key {k}");
        }
        let root = v.get("root").unwrap();
        for k in [
            "id",
            "parent_id",
            "depth",
            "branch_index",
            "content",
            "score",
            "status",
            "children",
        ] {
            assert!(root.get(k).is_some(), "node missing key {k}");
        }
        // `error` / `score_error` are omitted when None.
        assert!(
            root.get("error").is_none(),
            "error should be omitted when None"
        );
        assert!(
            root.get("score_error").is_none(),
            "score_error should be omitted when None"
        );
    }

    #[test]
    fn node_status_serializes_to_stable_wire_strings() {
        // Guards the wire format a forthcoming freeze will pin: the enum
        // must stay byte-identical to the prior `&'static str`.
        assert_eq!(serde_json::to_value(NodeStatus::Root).unwrap(), "root");
        assert_eq!(serde_json::to_value(NodeStatus::Ok).unwrap(), "ok");
        assert_eq!(serde_json::to_value(NodeStatus::Error).unwrap(), "error");
        assert_eq!(
            serde_json::to_value(NodeStatus::Incomplete).unwrap(),
            "incomplete"
        );
    }

    #[test]
    fn node_reasoning_serializes_when_present_omitted_when_empty() {
        let mut n = error_leaf("root", 1, 0, "x".to_string());
        // Empty reasoning is omitted from the wire (clean default).
        let v = serde_json::to_value(&n).unwrap();
        assert!(
            v.get("reasoning").is_none(),
            "empty reasoning should be omitted"
        );
        // A present reasoning trace serializes under "reasoning".
        n.reasoning = "first, consider…".to_string();
        let v = serde_json::to_value(&n).unwrap();
        assert_eq!(
            v.get("reasoning").and_then(|r| r.as_str()),
            Some("first, consider…")
        );
    }

    #[test]
    fn node_score_error_serializes_when_present() {
        let n = Node {
            id: "x".to_string(),
            parent_id: Some("root".to_string()),
            depth: 1,
            branch_index: Some(0),
            content: "ans".to_string(),
            reasoning: String::new(),
            score: None,
            status: NodeStatus::Ok,
            error: None,
            score_error: Some("score fork failed: boom".to_string()),
            children: Vec::new(),
        };
        let v = serde_json::to_value(&n).unwrap();
        assert_eq!(v.get("score_error").unwrap(), "score fork failed: boom");
        // An ok node with a scoring failure still has a null score.
        assert!(v.get("score").unwrap().is_null());
    }
}
