//! Event emission for tree search.
//!
//! Ported from `chat-apc/src/tot/stream.rs` (770 lines), which was mostly an
//! SSE emitter. What survives is the ORDERING contract; the framing is gone.
//!
//! ## What the new sink deletes
//!
//! chat-apc needed `BranchSink` — a `futures::lock::Mutex<&'a mut Emitter>`
//! shared `Copy` handle (`stream.rs:44-121`) — because emitting was
//! `&mut self` and `.await`ed, so N in-flight branch futures had no exclusive
//! writer. Its doc comment spends 25 lines explaining that the lock must be
//! held only for the frame write and never across a forward pass, and that a
//! `RefCell` would panic the single-threaded guest the instant a second branch
//! is polled.
//!
//! `EventSink::emit` is `&self` and synchronous — `session::send` neither
//! awaits nor returns an error — so concurrent branches share one `&dyn
//! EventSink` with no lock, no mutex, and no await-point inside emission. The
//! entire class of bug that comment guards against cannot occur here.
//!
//! ## The ordering contract that DOES survive
//!
//! Read off the captured stream (`ratio-wire/tests/fixtures/tot_stream.sse`),
//! because it is observable and the source is not:
//!
//! 1. `tree_start` once, first.
//! 2. Every `node_start` for a level precedes any `node_delta` of that level,
//!    and sibling deltas INTERLEAVE — that interleaving is the evidence the
//!    branches ran concurrently, and a sequential port produces a stream that
//!    decodes identically and compares differently.
//! 3. `node_scoring` for a node lands between other nodes' deltas: scoring
//!    starts as soon as that branch finishes, not after all of them do.
//! 4. `node_complete` is **batched**, not emitted when each branch finishes:
//!    all of a level's nodes arrive together, in `branch_index` order,
//!    immediately before `level_pruned`. [`emit_level`] is the single writer
//!    for both, and it runs on the sequential level loop after the branch
//!    futures join. Emitting each `node_complete` from its own branch future
//!    is the natural port and it is wrong — it reorders the stream and makes
//!    it non-deterministic under concurrency.
//! 5. Exactly one terminal: `tree_complete` on success, or `error`. Never both,
//!    and never a `tree_complete` carrying nulls — see [`terminal_error`].

use crate::tree::{GenerationMetrics, Node, NodeStatus};
use ratio_wire::event::{Channel, NodeView};
use ratio_wire::{Event, EventSink};

/// `Node` (owned, `usize`) → `NodeView` (the wire shape, `u32`).
///
/// Field order here is load-bearing: `serde_json` emits in declaration order
/// and the golden test compares bytes. `NodeView`'s own skip rules mean a clean
/// node never shows `reasoning`/`error`/`score_error`, which is why no capture
/// contains them.
pub fn node_view(n: &Node) -> NodeView {
    NodeView {
        id: n.id.clone(),
        parent_id: n.parent_id.clone(),
        depth: n.depth as u32,
        branch_index: n.branch_index.map(|i| i as u32),
        content: n.content.clone(),
        reasoning: n.reasoning.clone(),
        score: n.score,
        // `NodeStatus` stays a four-variant enum here and becomes a free String
        // on the wire. It must not gain a fifth value: the app decodes
        // `ToTNodeStatus` as a closed 4-case Swift enum, non-optionally, on
        // every node_complete — an unknown string throws and kills the turn.
        status: status_wire(n.status).to_string(),
        error: n.error.clone(),
        score_error: n.score_error.clone(),
    }
}

fn status_wire(s: NodeStatus) -> &'static str {
    match s {
        NodeStatus::Root => "root",
        NodeStatus::Ok => "ok",
        NodeStatus::Error => "error",
        NodeStatus::Incomplete => "incomplete",
    }
}

/// Opens the stream. Carries no id and no model: both are gateway-owned, and a
/// guest-minted tree id is exactly the `bon-0` collision (a per-request wasm
/// instance restarts its counter every time).
///
/// NOTE the `depth` overload on this wire: here it is the search BOUND (max
/// levels), while on `node_start`/`node_complete` it is that node's own level,
/// and `level_pruned` calls the same number `level`. All three read `1` in the
/// captured fixture, so the confusion is invisible there and only bites at
/// depth > 1.
pub fn tree_start(sink: &dyn EventSink, breadth: usize, depth: usize, beam_width: usize) {
    sink.emit(Event::TreeStart {
        breadth: breadth as u32,
        depth: depth as u32,
        beam_width: beam_width as u32,
    });
}

/// A branch announces itself before its first delta, so the client has a
/// provisional node to route deltas into regardless of arrival order.
pub fn node_start(sink: &dyn EventSink, id: &str, parent_id: &str, depth: usize, branch_index: usize) {
    sink.emit(Event::NodeStart {
        id: id.to_string(),
        parent_id: parent_id.to_string(),
        depth: depth as u32,
        branch_index: branch_index as u32,
    });
}

pub fn node_delta(sink: &dyn EventSink, id: &str, channel: Channel, text: &str) {
    sink.emit(Event::NodeDelta { id: id.to_string(), channel, text: text.to_string() });
}

pub fn node_scoring(sink: &dyn EventSink, id: &str) {
    sink.emit(Event::NodeScoring { id: id.to_string() });
}

/// One level's terminal burst: every node generated on the level — ok,
/// generation-error and fork error-leaf alike, so the client sees the full
/// breadth attempted — then the beam selection.
///
/// The batching is the contract (see the module docs, point 4). Callers pass
/// the slice appended this level; ordering by `branch_index` is the caller's
/// responsibility because a concurrent join resolves in completion order.
pub fn emit_level(sink: &dyn EventSink, level: usize, nodes: &[Node], kept: &[String]) {
    for n in nodes {
        sink.emit(Event::NodeComplete { node: node_view(n) });
    }
    sink.emit(Event::LevelPruned { level: level as u32, kept: kept.to_vec() });
}

/// Synthesis text, streamed after the beam settles.
///
/// Carries no node id: this is a SEPARATE generation grounded on the original
/// conversation fork, not a replay of the winning node's deltas. In the
/// captured fixture the synthesized answer happens to equal the selected
/// node's content, so a "replay the winner" port reproduces those bytes by
/// coincidence — and diverges the moment synthesis actually rewrites anything.
pub fn final_delta(sink: &dyn EventSink, text: &str) {
    sink.emit(Event::FinalDelta { text: text.to_string() });
}

/// Total generated-token throughput. Branch reasoning + answers + scorer
/// generations + synthesis — decode tokens only, never prompt tokens.
///
/// Only the guest can produce this number; the gateway has no way to derive it
/// from a `Usage` event (a tree stream sends none, and the chat path's
/// completion count would report the synthesis alone).
pub fn generation_metrics(sink: &dyn EventSink, m: &GenerationMetrics) {
    sink.emit(Event::GenerationMetrics {
        output_tokens: m.output_tokens as u32,
        elapsed_s: m.elapsed_s,
        // Recomputed by the renderer from the pair above; sent for completeness.
        tokens_per_sec: m.tokens_per_sec,
    });
}

pub fn tree_complete(
    sink: &dyn EventSink,
    selected_node_id: Option<String>,
    final_answer: Option<String>,
    synthesized: bool,
) {
    sink.emit(Event::TreeComplete { selected_node_id, final_answer, synthesized });
}

// ---------------------------------------------------------------------------
// The F1 terminal gate
// ---------------------------------------------------------------------------

pub const NO_ANSWER_CODE: &str = "no_answer";
pub const NO_ANSWER_MESSAGE: &str =
    "tree-of-thought search produced no answer: every branch failed to generate";
pub const FINAL_ANSWER_UNAVAILABLE_CODE: &str = "final_answer_unavailable";
pub const FINAL_ANSWER_UNAVAILABLE_MESSAGE: &str =
    "tree-of-thought search selected an inspection node but produced no final answer";

/// Whether a finished search totally failed. `select_beam` keeps the best ok
/// leaf whenever ANY ok node exists, so `None` means every branch failed across
/// every level — never a legitimate empty answer.
pub fn is_total_failure(selected_node_id: &Option<String>) -> bool {
    selected_node_id.is_none()
}

/// The terminal-boundary check, ported verbatim in spirit from
/// `chat-apc/src/tot/stream.rs:464-479`.
///
/// A ToT success requires a final ANSWER, not merely an inspection node. A
/// retained intermediate candidate may stay selected so the client can see how
/// far the search got, but if synthesis produced nothing the terminal must be
/// `error`, not `tree_complete`.
///
/// This is the F1 rule and it is easy to lose: appending a `tree_complete` with
/// null fields on the failure path turns a failed search into a success-shaped
/// blank turn on the client. The node_complete frames are still emitted either
/// way, so a failed search still renders its tree AND surfaces the failure.
pub fn terminal_error(
    selected_node_id: &Option<String>,
    final_answer: &Option<String>,
) -> Option<(&'static str, &'static str)> {
    if is_total_failure(selected_node_id) {
        Some((NO_ANSWER_CODE, NO_ANSWER_MESSAGE))
    } else if final_answer.is_none() {
        Some((FINAL_ANSWER_UNAVAILABLE_CODE, FINAL_ANSWER_UNAVAILABLE_MESSAGE))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratio_wire::VecSink;

    fn node(id: &str, branch_index: usize, status: NodeStatus, score: Option<u8>) -> Node {
        Node {
            id: id.into(),
            parent_id: Some("root".into()),
            depth: 1,
            branch_index: Some(branch_index),
            content: format!("answer {id}"),
            reasoning: String::new(),
            score,
            status,
            error: None,
            score_error: None,
            children: Vec::new(),
        }
    }

    /// The batching contract: every node_complete, THEN level_pruned — one
    /// burst, not interleaved with the branches that produced them.
    #[test]
    fn a_level_emits_every_node_then_the_beam() {
        let sink = VecSink::default();
        let nodes = [
            node("tot-n1", 0, NodeStatus::Ok, Some(7)),
            node("tot-n2", 1, NodeStatus::Ok, Some(5)),
        ];
        emit_level(&sink, 1, &nodes, &["tot-n1".to_string()]);

        let evs = sink.take();
        assert_eq!(evs.len(), 3);
        assert!(matches!(&evs[0], Event::NodeComplete { node } if node.id == "tot-n1"));
        assert!(matches!(&evs[1], Event::NodeComplete { node } if node.id == "tot-n2"));
        match &evs[2] {
            Event::LevelPruned { level, kept } => {
                assert_eq!(*level, 1);
                assert_eq!(kept, &["tot-n1".to_string()]);
            }
            other => panic!("expected level_pruned, got {other:?}"),
        }
    }

    /// A failed branch still gets a node_complete, so the client renders the
    /// full breadth that was attempted rather than a silently smaller tree.
    #[test]
    fn failed_nodes_are_still_reported() {
        let sink = VecSink::default();
        let mut bad = node("tot-n2", 1, NodeStatus::Error, None);
        bad.content = String::new();
        bad.error = Some("fork failed: boom".into());
        emit_level(&sink, 1, &[node("tot-n1", 0, NodeStatus::Ok, Some(7)), bad], &["tot-n1".into()]);
        assert_eq!(sink.take().len(), 3, "the error node must still be completed");
    }

    #[test]
    fn node_view_renders_the_captured_shape() {
        let n = node("tot-n1", 0, NodeStatus::Ok, Some(7));
        let v = serde_json::to_string(&node_view(&n)).unwrap();
        // score is an integer, never 7.0; reasoning/error/score_error are
        // skipped when empty, which is why no capture shows them.
        assert!(v.contains(r#""score":7"#), "got {v}");
        assert!(!v.contains("reasoning"), "empty reasoning must be skipped: {v}");
        assert!(!v.contains("score_error"), "got {v}");
        assert!(v.contains(r#""status":"ok""#), "got {v}");
        assert!(v.contains(r#""parent_id":"root""#), "got {v}");
    }

    /// `parent_id` is `null`, not skipped, on the root — bestofn_stream.sse
    /// relies on the explicit null being present.
    #[test]
    fn root_parent_id_serializes_as_null() {
        let root = Node::root();
        let v = serde_json::to_string(&node_view(&root)).unwrap();
        assert!(v.contains(r#""parent_id":null"#), "got {v}");
        assert!(v.contains(r#""score":null"#), "got {v}");
    }

    #[test]
    fn every_status_has_a_stable_wire_string() {
        // The app decodes these into a closed 4-case Swift enum, non-optionally.
        // Adding a fifth value here kills the turn client-side.
        for (s, want) in [
            (NodeStatus::Root, "root"),
            (NodeStatus::Ok, "ok"),
            (NodeStatus::Error, "error"),
            (NodeStatus::Incomplete, "incomplete"),
        ] {
            assert_eq!(status_wire(s), want);
        }
    }

    #[test]
    fn no_selection_is_a_total_failure() {
        assert_eq!(terminal_error(&None, &None), Some((NO_ANSWER_CODE, NO_ANSWER_MESSAGE)));
    }

    /// The F1 rule: a selected inspection node with no synthesized answer is
    /// still a failure. Emitting `tree_complete` here would render a blank
    /// successful turn.
    #[test]
    fn selected_node_without_an_answer_is_still_an_error() {
        assert_eq!(
            terminal_error(&Some("tot-n1".into()), &None),
            Some((FINAL_ANSWER_UNAVAILABLE_CODE, FINAL_ANSWER_UNAVAILABLE_MESSAGE))
        );
    }

    #[test]
    fn a_selected_node_with_an_answer_succeeds() {
        assert_eq!(terminal_error(&Some("tot-n1".into()), &Some("42".into())), None);
    }

    /// Nothing in the emit layer awaits, which is what removes chat-apc's
    /// `futures::lock::Mutex<&mut Emitter>` and its held-across-await hazard.
    #[test]
    fn concurrent_branches_share_one_sink_without_a_lock() {
        let sink = VecSink::default();
        let s: &dyn EventSink = &sink;
        // Two "branches" holding the same &dyn and interleaving writes.
        node_start(s, "tot-n1", "root", 1, 0);
        node_start(s, "tot-n2", "root", 1, 1);
        node_delta(s, "tot-n1", Channel::Answer, "One");
        node_delta(s, "tot-n2", Channel::Answer, "One");
        node_scoring(s, "tot-n1");
        node_delta(s, "tot-n2", Channel::Answer, " prime");
        assert_eq!(sink.take().len(), 6);
    }
}
