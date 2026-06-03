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

/// Stable-sort `(id, score)` by score descending (`None` ranks lowest),
/// returning the ids of the top `m`. Stable so equal scores keep input
/// order (deterministic beam + best-leaf selection).
pub fn select_beam(mut scored: Vec<(String, Option<u8>)>, m: usize) -> Vec<String> {
    // `Option<u8>` orders `None < Some(_)`, so `b.cmp(a)` puts the
    // highest scores first and `None` entries last.
    scored.sort_by(|a, b| b.1.cmp(&a.1));
    scored.into_iter().take(m).map(|(id, _)| id).collect()
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
    fn beam_keeps_top_m_none_last() {
        let scored = vec![
            ("a".to_string(), Some(3)),
            ("b".to_string(), None),
            ("c".to_string(), Some(9)),
            ("d".to_string(), Some(5)),
        ];
        assert_eq!(select_beam(scored, 2), vec!["c", "d"]);
    }

    #[test]
    fn beam_all_none_is_deterministic() {
        let scored = vec![("a".to_string(), None), ("b".to_string(), None)];
        // Stable sort keeps the first input on ties.
        assert_eq!(select_beam(scored, 1), vec!["a"]);
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
