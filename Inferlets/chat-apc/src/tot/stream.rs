//! Tree-of-thought **streaming** wire format (ticket #413).
//!
//! `stream:true` on the `tree-of-thought` dispatch turns the search into
//! an SSE stream so the GUI can watch branches generate, get scored, and
//! the top-`beam_width` survive per level — the tree analogue of the
//! collapsible "Thinking" section chat reasoning already streams (#329).
//!
//! ## Granularity: per level, not per token
//!
//! A tree is not a token sequence, so token-by-token streaming is the
//! wrong shape. Instead we stream **a level at a time**: once a level's
//! candidates are generated, scored, and pruned, every node on that level
//! is emitted (`node_complete`) followed by the beam selection
//! (`level_pruned`). This is the "delayed streaming for a tree" the ticket
//! calls for — each frame carries a fully-resolved node (content + score +
//! status), never a half-generated one.
//!
//! ## Frames (mirrors `crate::sse` conventions)
//!
//! Every frame is `data: {json}\n\n` with a top-level `event`
//! discriminator (the pie-control convention — the SSE `event:` channel
//! itself is unused). The stream is:
//!
//! ```text
//! tree_start     {event,id,model,breadth,depth,beam_width}   // once, opens
//! node_start     {event,id,parent_id,depth,branch_index}     // per node, before its deltas (#413 token stream)
//! node_delta     {event,id,kind:"reasoning"|"answer",text}   // streamed token chunks for that node
//! node_complete  {event,node:{…}}                            // per-node terminal: full node + score + status
//! level_pruned   {event,level,kept:[id,…]}                   // per level, the beam
//! generation_metrics {event,output_tokens,elapsed_s,tokens_per_sec} // once, before success terminal (#542)
//! tree_complete  {event,selected_node_id,final_answer}       // once, terminal success
//! error          {event:"error",code,message}                // terminal failure (crate::sse::SseError)
//! [DONE]                                                     // sentinel
//! ```
//!
//! ## Token-level streaming (#413 phase B)
//!
//! A node is announced by `node_start` (its tree position), then its
//! reasoning and answer stream INCREMENTALLY as `node_delta` chunks tagged
//! by the same id (`kind:"reasoning"` while inside `<think>`, then
//! `kind:"answer"` for the visible answer — the demux in
//! [`super::search::generate_demuxed`] decides the channel). `node_complete`
//! remains the per-node terminal: it carries the FULL node (content +
//! reasoning + score + status) and is authoritative — a client live-fills
//! from the deltas, then reconciles to `node_complete` (which also lets the
//! non-streaming path, that emits no deltas, produce a byte-identical final
//! tree). Since #650 a level's siblings generate **concurrently** on the
//! streaming path too (so the engine co-batches their forward passes — the
//! #465 win now reaches the UI), so one node's `node_start` + deltas may
//! interleave with another's on the wire. The `id` on every frame is what
//! keeps routing robust: a client creates a provisional node on each
//! `node_start` and appends each `node_delta` to the node its `id` names,
//! regardless of arrival order (see [`BranchSink`]). Within a single node the
//! frames stay ordered (its own branch future writes them sequentially).
//!
//! Invariant (carried over from #407): every event identifies the node(s)
//! it concerns by stable id, and the stream ends with exactly one terminal
//! `tree_complete` (success) or `error` (failure) before `[DONE]`. The
//! terminal is the `error` frame whenever the search produced no final
//! answer: either no ok leaf was selected at all, or the selected node was
//! only an inspection/intermediate node and synthesis did not recover a
//! direct final answer. Surfacing either state as `tree_complete` would be
//! a success-shaped frame for a failed final-answer stage (a blank
//! "successful" turn on the client); [`terminal_error`] gates the terminal
//! so the documented `error` frame fires instead (F1).
//!
//! `node_complete` carries the **flat** node (no nested `children`): the
//! client assembles the tree from `parent_id` links exactly as the
//! non-streaming server does in `tree::assemble`. The node payload is
//! otherwise byte-identical to a non-streaming tree node, so a client can
//! reuse one node decoder across both shapes.
//!
//! Pre-stream failures (validation, model resolution, context build) are
//! NOT streamed — they return the same OpenAI-shape JSON 4xx/5xx envelope
//! as the non-streaming path, because the SSE response is opened only
//! after the root context is built and flushed (see [`super::dispatch`]).
//! This mirrors `chat-apc`'s `handle_streaming`: never a misleading
//! `tree_start` followed by an error frame for a request that never began.

use futures::lock::Mutex;
use serde::Serialize;

use crate::sse::{EmitError, Emitter};

/// A node-delta sink shared across **concurrent** branch futures (#650).
///
/// Before #650 the streaming search forced sequential generation: a single
/// `&mut Emitter` cannot be borrowed by N in-flight branch futures, so per-node
/// `node_delta` chunks had no exclusive writer. That left the streaming/UI path
/// without the #465 co-batch speedup *and* without a concurrent-decode
/// animation — branches filled level-by-level, one at a time.
///
/// The wire already routes every frame by node id (`node_start` / `node_delta`
/// carry `id`), so interleaving sibling deltas is wire-safe; the only obstacle
/// was the exclusive borrow. `BranchSink` lifts it by sharing the emitter behind
/// an async [`Mutex`]: a branch acquires the lock only for the brief frame write
/// between decode steps, **never across a forward pass**, so the per-device
/// scheduler still coalesces the siblings' forward passes (the #465 win) while
/// their `node_delta` frames interleave on the one SSE stream, each routed by id.
///
/// An async `Mutex` (not `RefCell`) is mandatory: the wasm guest is a single
/// cooperative execution stack, and the frame write `.await`s — a `RefCell`
/// borrow held across that await would panic the instant another branch is
/// polled and tries to emit. The async mutex instead suspends the contending
/// branch's `lock().await` until the writer releases, with no forward-pass
/// dependency either way (no deadlock).
///
/// `Copy`, so the one handle is handed to every branch future for free. The
/// inner `&mut Emitter` and the outer `&Mutex` carry distinct lifetimes because
/// `&mut` is invariant — unifying them would reject the borrow built from a
/// local `Mutex` wrapping a longer-lived emitter reference.
#[derive(Clone, Copy)]
pub struct BranchSink<'a, 'e> {
    emitter: &'a Mutex<&'e mut Emitter>,
}

impl<'a, 'e> BranchSink<'a, 'e> {
    /// Wrap a shared, mutex-guarded emitter into a Copy branch handle.
    pub fn new(emitter: &'a Mutex<&'e mut Emitter>) -> Self {
        Self { emitter }
    }

    /// Emit this branch's opening `node_start` (acquires the lock only for the
    /// write). A branch emits its own `node_start` before its first delta, so
    /// the provisional node exists client-side regardless of cross-branch order.
    pub async fn node_start(
        &self,
        id: &str,
        parent_id: &str,
        depth: usize,
        branch_index: usize,
    ) -> Result<(), EmitError> {
        let mut em = self.emitter.lock().await;
        emit_node_start(&mut **em, id, parent_id, depth, branch_index).await
    }

    /// Emit one streamed `node_delta` chunk for `id` on `kind`'s channel.
    pub async fn node_delta(
        &self,
        id: &str,
        kind: &'static str,
        text: &str,
    ) -> Result<(), EmitError> {
        let mut em = self.emitter.lock().await;
        emit_node_delta(&mut **em, id, kind, text).await
    }

    /// Emit one streamed `final_delta` chunk of the synthesized answer.
    pub async fn final_delta(&self, text: &str) -> Result<(), EmitError> {
        let mut em = self.emitter.lock().await;
        emit_final_delta(&mut **em, text).await
    }
}

use super::schema::TotParams;
use super::tree::{GenerationMetrics, Node, NodeStatus};

/// The flat projection of a [`Node`] sent on a `node_complete` frame.
/// Borrows every field from the live node so emission allocates only the
/// JSON string. Deliberately omits `children`: the streaming client
/// rebuilds the hierarchy from `parent_id`, and an empty `children: []`
/// here would falsely imply "this node is a leaf" before its level's
/// descendants have streamed. `error` / `score_error` are skipped when
/// absent, matching the non-streaming node wire exactly.
#[derive(Serialize)]
struct NodeView<'a> {
    id: &'a str,
    parent_id: Option<&'a str>,
    depth: usize,
    branch_index: Option<usize>,
    content: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    reasoning: &'a str,
    score: Option<u8>,
    status: NodeStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    score_error: Option<&'a str>,
}

impl<'a> NodeView<'a> {
    fn new(n: &'a Node) -> Self {
        NodeView {
            id: &n.id,
            parent_id: n.parent_id.as_deref(),
            depth: n.depth,
            branch_index: n.branch_index,
            content: &n.content,
            reasoning: &n.reasoning,
            score: n.score,
            status: n.status,
            error: n.error.as_deref(),
            score_error: n.score_error.as_deref(),
        }
    }
}

/// `tree_start` — opens the stream; the streaming analogue of the
/// non-streaming response envelope header (id + echoed search bounds), so
/// the UI can render the expected tree shape before any node arrives.
#[derive(Serialize)]
struct TreeStartFrame<'a> {
    event: &'static str,
    id: &'a str,
    model: &'a str,
    breadth: usize,
    depth: usize,
    beam_width: usize,
}

/// `node_complete` — one fully-resolved tree node (see [`NodeView`]).
#[derive(Serialize)]
struct NodeCompleteFrame<'a> {
    event: &'static str,
    node: NodeView<'a>,
}

/// `node_start` — announces a node + its tree position before its text
/// streams, so a client can create + place the node and route subsequent
/// `node_delta`s to it. Carries only the metadata known pre-generation;
/// content/reasoning/score arrive via deltas + the terminal `node_complete`.
#[derive(Serialize)]
struct NodeStartFrame<'a> {
    event: &'static str,
    id: &'a str,
    parent_id: &'a str,
    depth: usize,
    branch_index: usize,
}

/// `node_delta` — one streamed text chunk for a node, tagged by id and by
/// channel (`reasoning` while inside `<think>`, `answer` afterward).
#[derive(Serialize)]
struct NodeDeltaFrame<'a> {
    event: &'static str,
    id: &'a str,
    kind: &'static str,
    text: &'a str,
}

/// `node_delta` channel tags (#413). The demux routes a chunk to exactly one.
pub const DELTA_REASONING: &str = "reasoning";
pub const DELTA_ANSWER: &str = "answer";

/// `level_pruned` — the beam selection for a just-completed level: the ids
/// kept as the next frontier. An empty `kept` means the level produced no
/// surviving candidate (every branch failed) and the search stops here.
#[derive(Serialize)]
struct LevelPrunedFrame<'a> {
    event: &'static str,
    level: usize,
    kept: &'a [String],
}

/// `tree_complete` — terminal success frame: the best leaf (`null` when no
/// ok leaf survived, matching the non-streaming envelope's honesty).
#[derive(Serialize)]
struct TreeCompleteFrame<'a> {
    event: &'static str,
    selected_node_id: Option<&'a str>,
    final_answer: Option<&'a str>,
    /// `true` when `final_answer` came from the post-search synthesis, `false`
    /// when the raw best-leaf content stood — lets the client and the gated
    /// smoke assert the synthesizer actually ran (#523 Part A F1).
    synthesized: bool,
}

/// `generation_metrics` — terminal total generated-token throughput for a
/// successful ToT run (#542). Mirrors chat's compact metric payload, but the
/// token count is ToT-total (branch reasoning/answers + scorer + synthesis).
#[derive(Serialize)]
struct GenerationMetricsFrame {
    event: &'static str,
    output_tokens: usize,
    elapsed_s: f64,
    tokens_per_sec: f64,
}

impl From<&GenerationMetrics> for GenerationMetricsFrame {
    fn from(metrics: &GenerationMetrics) -> Self {
        GenerationMetricsFrame {
            event: "generation_metrics",
            output_tokens: metrics.output_tokens,
            elapsed_s: metrics.elapsed_s,
            tokens_per_sec: metrics.tokens_per_sec,
        }
    }
}

/// Emit the opening `tree_start` frame.
pub async fn emit_tree_start(
    em: &mut Emitter,
    id: &str,
    model: &str,
    params: &TotParams,
) -> Result<(), EmitError> {
    em.emit_json(&TreeStartFrame {
        event: "tree_start",
        id,
        model,
        breadth: params.breadth,
        depth: params.depth,
        beam_width: params.beam_width,
    })
    .await
}

/// Emit `node_start` for a node about to generate (#413 token stream). The
/// caller follows it with `node_delta`s (via the search's demux) and a
/// terminal `node_complete`.
pub async fn emit_node_start(
    em: &mut Emitter,
    id: &str,
    parent_id: &str,
    depth: usize,
    branch_index: usize,
) -> Result<(), EmitError> {
    em.emit_json(&NodeStartFrame {
        event: "node_start",
        id,
        parent_id,
        depth,
        branch_index,
    })
    .await
}

/// Emit one streamed `node_delta` chunk for `id` on `kind`'s channel
/// ([`DELTA_REASONING`] / [`DELTA_ANSWER`]).
pub async fn emit_node_delta(
    em: &mut Emitter,
    id: &str,
    kind: &'static str,
    text: &str,
) -> Result<(), EmitError> {
    em.emit_json(&NodeDeltaFrame {
        event: "node_delta",
        id,
        kind,
        text,
    })
    .await
}

/// `final_delta` — one streamed chunk of the final synthesized answer
/// (#523 Part A). After the search picks the best leaf, ONE synthesis
/// generation produces the final answer grounded in that leaf; its answer
/// text streams as `final_delta` chunks before the terminal
/// `tree_complete` (whose `final_answer` carries the full text as the
/// authoritative value). Additive: a client that doesn't know the event
/// ignores it and still renders `tree_complete.final_answer`.
#[derive(Serialize)]
struct FinalDeltaFrame<'a> {
    event: &'static str,
    text: &'a str,
}

/// Emit one streamed chunk of the synthesized final answer.
pub async fn emit_final_delta(em: &mut Emitter, text: &str) -> Result<(), EmitError> {
    em.emit_json(&FinalDeltaFrame {
        event: "final_delta",
        text,
    })
    .await
}

/// Emit one search level: a `node_complete` for every node generated on
/// the level (ok, generation-error, fork error-leaf — all of
/// them, so the UI sees the full breadth that was attempted), then the
/// `level_pruned` beam selection. Called by [`super::search::run`] with
/// the slice of nodes freshly appended this level and the surviving ids.
pub async fn emit_level(
    em: &mut Emitter,
    level: usize,
    nodes: &[Node],
    kept: &[String],
) -> Result<(), EmitError> {
    for n in nodes {
        em.emit_json(&NodeCompleteFrame {
            event: "node_complete",
            node: NodeView::new(n),
        })
        .await?;
    }
    em.emit_json(&LevelPrunedFrame {
        event: "level_pruned",
        level,
        kept,
    })
    .await
}

/// Emit the terminal `tree_complete` frame. The caller follows it with
/// `[DONE]`.
pub async fn emit_tree_complete(
    em: &mut Emitter,
    selected_node_id: Option<&str>,
    final_answer: Option<&str>,
    synthesized: bool,
) -> Result<(), EmitError> {
    em.emit_json(&TreeCompleteFrame {
        event: "tree_complete",
        selected_node_id,
        final_answer,
        synthesized,
    })
    .await
}

/// Emit the terminal total generated-token throughput metric. The caller only
/// invokes this after a successful `tree_complete`; failures/cancellations do
/// not receive a metric frame.
pub async fn emit_generation_metrics(
    em: &mut Emitter,
    metrics: &GenerationMetrics,
) -> Result<(), EmitError> {
    em.emit_json(&GenerationMetricsFrame::from(metrics)).await
}

/// Whether a finished search totally failed: it selected no ok leaf. The
/// beam (`select_beam`/`best_leaf`) keeps the best ok leaf whenever ANY ok
/// node exists, so a `None` selection means every fork/refine/generation
/// failed across every level — a total failure, never a legitimate empty
/// answer.
pub fn is_total_failure(selected_node_id: &Option<String>) -> bool {
    selected_node_id.is_none()
}

/// Server terminal-boundary check: a ToT success requires a final answer,
/// not merely an inspection node. A retained intermediate candidate can
/// remain selected so clients can inspect where the search got to, but if
/// final synthesis did not produce an answer, both dispatch paths must emit
/// the terminal `error` shape rather than `tree_complete`/`TreeResponse`.
pub fn terminal_error(
    selected_node_id: &Option<String>,
    final_answer: &Option<String>,
) -> Option<(&'static str, &'static str)> {
    if is_total_failure(selected_node_id) {
        Some((NO_ANSWER_CODE, NO_ANSWER_MESSAGE))
    } else if final_answer.is_none() {
        Some((
            FINAL_ANSWER_UNAVAILABLE_CODE,
            FINAL_ANSWER_UNAVAILABLE_MESSAGE,
        ))
    } else {
        None
    }
}

/// Wire `code`/`message` for the no-ok-leaf terminal failure, shared by
/// both dispatch paths so the streamed `error` frame and the non-stream
/// error envelope carry identical text.
pub const NO_ANSWER_CODE: &str = "no_answer";
pub const NO_ANSWER_MESSAGE: &str =
    "tree-of-thought search produced no answer: every branch failed to generate";
pub const FINAL_ANSWER_UNAVAILABLE_CODE: &str = "final_answer_unavailable";
pub const FINAL_ANSWER_UNAVAILABLE_MESSAGE: &str =
    "tree-of-thought search selected an inspection node but produced no final answer";
pub const METRICS_UNAVAILABLE_CODE: &str = "generation_metrics_unavailable";
pub const METRICS_UNAVAILABLE_MESSAGE: &str =
    "tree-of-thought search finished without generation metrics";

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn node(id: &str, parent: &str, status: NodeStatus) -> Node {
        Node {
            id: id.to_string(),
            parent_id: Some(parent.to_string()),
            depth: 1,
            branch_index: Some(0),
            content: "ans".to_string(),
            reasoning: String::new(),
            score: Some(7),
            status,
            error: None,
            score_error: None,
            children: Vec::new(),
        }
    }

    #[test]
    fn node_complete_frame_is_flat_with_event_and_node_id() {
        let n = node("tot-n3", "root", NodeStatus::Ok);
        let frame = NodeCompleteFrame {
            event: "node_complete",
            node: NodeView::new(&n),
        };
        let v = serde_json::to_value(&frame).unwrap();
        assert_eq!(v["event"], "node_complete");
        // #407 invariant: each event identifies the node by id.
        assert_eq!(v["node"]["id"], "tot-n3");
        assert_eq!(v["node"]["parent_id"], "root");
        assert_eq!(v["node"]["status"], "ok");
        assert_eq!(v["node"]["score"], 7);
        // Flat node: never carries `children` (client assembles via parent_id).
        assert!(v["node"].get("children").is_none());
        // Clean optionals are omitted, matching the non-streaming node wire.
        assert!(v["node"].get("error").is_none());
        assert!(v["node"].get("score_error").is_none());
        // Empty reasoning is omitted too (non-reasoning model / thinking off).
        assert!(v["node"].get("reasoning").is_none());
    }

    #[test]
    fn node_complete_frame_carries_reasoning_when_present() {
        // #413/#437: a thinking node ships its demuxed reasoning alongside the
        // answer so the client can render the per-node "Thinking" section.
        let mut n = node("tot-n6", "root", NodeStatus::Ok);
        n.reasoning = "first I weigh A vs B…".to_string();
        let v = serde_json::to_value(NodeCompleteFrame {
            event: "node_complete",
            node: NodeView::new(&n),
        })
        .unwrap();
        assert_eq!(v["node"]["reasoning"], "first I weigh A vs B…");
        assert_eq!(v["node"]["content"], "ans");
    }

    #[test]
    fn node_complete_frame_surfaces_incomplete_status() {
        // A reasoned-but-unanswered node streams as status "incomplete" with
        // its partial reasoning and an empty answer (#434).
        let mut n = node("tot-n7", "tot-n1", NodeStatus::Incomplete);
        n.content = String::new();
        n.score = None;
        n.reasoning = "I was still working through…".to_string();
        n.error = Some("no answer".to_string());
        let v = serde_json::to_value(NodeCompleteFrame {
            event: "node_complete",
            node: NodeView::new(&n),
        })
        .unwrap();
        assert_eq!(v["node"]["status"], "incomplete");
        assert_eq!(v["node"]["reasoning"], "I was still working through…");
        assert_eq!(v["node"]["content"], "");
        assert_eq!(v["node"]["error"], "no answer");
    }

    #[test]
    fn node_complete_frame_surfaces_error_and_score_error_when_present() {
        let mut n = node("tot-n4", "tot-n1", NodeStatus::Error);
        n.content = String::new();
        n.score = None;
        n.error = Some("fork failed: gone".to_string());
        n.score_error = None;
        let v = serde_json::to_value(NodeCompleteFrame {
            event: "node_complete",
            node: NodeView::new(&n),
        })
        .unwrap();
        assert_eq!(v["node"]["status"], "error");
        assert_eq!(v["node"]["error"], "fork failed: gone");
        assert!(v["node"]["score"].is_null());

        let mut ok = node("tot-n5", "root", NodeStatus::Ok);
        ok.score = None;
        ok.score_error = Some("score fork failed: boom".to_string());
        let v = serde_json::to_value(NodeCompleteFrame {
            event: "node_complete",
            node: NodeView::new(&ok),
        })
        .unwrap();
        assert_eq!(v["node"]["score_error"], "score fork failed: boom");
        assert!(v["node"]["score"].is_null());
    }

    #[test]
    fn generation_metrics_frame_field_names_and_boundaries_are_stable() {
        assert!(GenerationMetrics::build(0, std::time::Duration::from_millis(500)).is_none());
        assert!(GenerationMetrics::build(3, std::time::Duration::ZERO).is_none());

        let metrics = GenerationMetrics::build(84, std::time::Duration::from_secs(2))
            .expect("positive token count and elapsed time should emit metrics");
        let v = serde_json::to_value(GenerationMetricsFrame::from(&metrics)).unwrap();

        assert_eq!(v["event"].as_str(), Some("generation_metrics"));
        assert_eq!(v["output_tokens"].as_u64(), Some(84));
        assert_eq!(v["elapsed_s"].as_f64(), Some(2.0));
        assert_eq!(v["tokens_per_sec"].as_f64(), Some(42.0));
    }

    #[test]
    fn node_start_frame_carries_position() {
        let v = serde_json::to_value(NodeStartFrame {
            event: "node_start",
            id: "tot-n3",
            parent_id: "root",
            depth: 1,
            branch_index: 0,
        })
        .unwrap();
        assert_eq!(
            v,
            json!({"event":"node_start","id":"tot-n3","parent_id":"root","depth":1,"branch_index":0})
        );
    }

    #[test]
    fn node_delta_frame_tags_id_and_channel() {
        let r = serde_json::to_value(NodeDeltaFrame {
            event: "node_delta",
            id: "tot-n3",
            kind: DELTA_REASONING,
            text: "weigh A vs B",
        })
        .unwrap();
        assert_eq!(
            r,
            json!({"event":"node_delta","id":"tot-n3","kind":"reasoning","text":"weigh A vs B"})
        );
        let a = serde_json::to_value(NodeDeltaFrame {
            event: "node_delta",
            id: "tot-n3",
            kind: DELTA_ANSWER,
            text: "4",
        })
        .unwrap();
        assert_eq!(a["kind"], "answer");
        assert_eq!(a["text"], "4");
    }

    #[test]
    fn tree_start_frame_echoes_bounds() {
        let params = TotParams {
            breadth: 3,
            depth: 2,
            beam_width: 2,
            max_tokens_per_node: 16,
            max_reasoning_tokens: 256,
            temperature: 0.7,
            top_p: 0.95,
            thinking: true,
            exec: crate::tot::schema::ExecStrategy::default(),
        };
        let v = serde_json::to_value(TreeStartFrame {
            event: "tree_start",
            id: "tot-1",
            model: "qwen",
            breadth: params.breadth,
            depth: params.depth,
            beam_width: params.beam_width,
        })
        .unwrap();
        assert_eq!(
            v,
            json!({"event":"tree_start","id":"tot-1","model":"qwen","breadth":3,"depth":2,"beam_width":2})
        );
    }

    #[test]
    fn level_pruned_frame_carries_kept_ids() {
        let kept = vec!["tot-n1".to_string(), "tot-n2".to_string()];
        let v = serde_json::to_value(LevelPrunedFrame {
            event: "level_pruned",
            level: 1,
            kept: &kept,
        })
        .unwrap();
        assert_eq!(
            v,
            json!({"event":"level_pruned","level":1,"kept":["tot-n1","tot-n2"]})
        );
    }

    #[test]
    fn level_pruned_empty_kept_is_empty_array() {
        // A fully-failed level streams an empty beam (search stops after).
        let v = serde_json::to_value(LevelPrunedFrame {
            event: "level_pruned",
            level: 2,
            kept: &[],
        })
        .unwrap();
        assert_eq!(v["kept"], json!([]));
    }

    #[test]
    fn tree_complete_frame_carries_selection() {
        let v = serde_json::to_value(TreeCompleteFrame {
            event: "tree_complete",
            selected_node_id: Some("tot-n3"),
            final_answer: Some("4"),
            synthesized: true,
        })
        .unwrap();
        assert_eq!(
            v,
            json!({"event":"tree_complete","selected_node_id":"tot-n3","final_answer":"4","synthesized":true})
        );
    }

    #[test]
    fn total_failure_iff_no_selected_leaf() {
        // F1: a None selection is a total failure (the terminal must be the
        // `error` frame, not a success-shaped tree_complete{null,null}); a
        // Some selection is a real answer (tree_complete).
        assert!(is_total_failure(&None));
        assert!(!is_total_failure(&Some("tot-n3".to_string())));
    }

    #[test]
    fn terminal_error_when_selected_leaf_has_no_final_answer() {
        let selected = Some("tot-n3".to_string());
        let final_answer = None;
        let (code, message) = terminal_error(&selected, &final_answer)
            .expect("selected inspection node without final answer is terminal failure");

        assert_eq!(code, FINAL_ANSWER_UNAVAILABLE_CODE);
        assert!(message.contains("final answer"));
    }

    #[test]
    fn terminal_error_none_when_selected_leaf_has_final_answer() {
        let selected = Some("tot-n3".to_string());
        let final_answer = Some("4".to_string());

        assert!(terminal_error(&selected, &final_answer).is_none());
    }

    #[test]
    fn tree_complete_frame_nulls_when_no_leaf() {
        // No ok leaf survived → both fields are JSON null (present, honest),
        // mirroring the non-streaming envelope.
        let v = serde_json::to_value(TreeCompleteFrame {
            event: "tree_complete",
            selected_node_id: None,
            final_answer: None,
            synthesized: false,
        })
        .unwrap();
        assert!(v["selected_node_id"].is_null());
        assert!(v["final_answer"].is_null());
        assert_eq!(v["synthesized"], json!(false));
    }
}
