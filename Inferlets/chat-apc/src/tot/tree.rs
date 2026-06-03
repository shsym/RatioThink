//! Pure tree data model + helpers for the tree-of-thought mode.
//!
//! No WIT calls live here, so this module is unit-tested natively via
//! `cargo test --lib` (the wasm-only generation path lives in
//! [`super::search`]).

use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};

/// One node in the generated thought tree.
///
/// * `status` is `"root"`, `"ok"`, or `"error"`.
/// * `score` is the value-evaluator rating (1–10), or `null` when scoring
///   failed or could not be parsed.
/// * `error` carries a per-node diagnostic on partial failure (omitted
///   from the wire otherwise) — this is how the response represents
///   per-node failures while the rest of the tree still returns.
#[derive(Serialize, Clone, Debug)]
pub struct Node {
    pub id: String,
    pub parent_id: Option<String>,
    pub depth: usize,
    pub branch_index: Option<usize>,
    pub content: String,
    pub score: Option<u8>,
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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
            score: None,
            status: "root",
            error: None,
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

/// Parse the first integer in `[1, 10]` out of value-evaluator output.
/// Returns `None` for no-digit text or an out-of-range value.
pub fn parse_score(text: &str) -> Option<u8> {
    let mut digits = String::new();
    for ch in text.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else if !digits.is_empty() {
            break;
        }
    }
    let v: u16 = digits.parse().ok()?;
    if (1..=10).contains(&v) {
        Some(v as u8)
    } else {
        None
    }
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

    fn cand(id: &str, score: Option<u8>, ok: bool) -> Candidate {
        Candidate {
            id: id.to_string(),
            score,
            ok,
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
    fn assemble_links_children() {
        let flat = vec![
            Node::root(),
            Node {
                id: "x".to_string(),
                parent_id: Some("root".to_string()),
                depth: 1,
                branch_index: Some(0),
                content: "c".to_string(),
                score: Some(5),
                status: "ok",
                error: None,
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
                score: None,
                status: "ok",
                error: None,
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
        // `error` is omitted when None.
        assert!(root.get("error").is_none(), "error should be omitted when None");
    }
}
