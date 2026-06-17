import XCTest
@testable import RatioThinkCore

/// Reducer tests for the live tree-of-thought accumulator (#413). Pure:
/// folds `ToTEvent`s and asserts the rendered state — beam highlighting,
/// hierarchy assembly, terminal selection — with no engine or view.
final class ToTTreeTests: XCTestCase {

  private func node(
    _ id: String, parent: String, depth: Int, branch: Int,
    content: String = "x", reasoning: String = "", score: Int? = nil,
    status: ToTNodeStatus = .ok
  ) -> ToTNode {
    ToTNode(id: id, parentID: parent, depth: depth, branchIndex: branch,
            content: content, reasoning: reasoning, score: score, status: status)
  }

  func test_initial_state_is_idle() {
    let t = ToTTree()
    XCTAssertEqual(t.status, .idle)
    XCTAssertTrue(t.nodes.isEmpty)
    XCTAssertNil(t.selectedNodeID)
  }

  func test_tree_start_records_bounds_and_searching() {
    var t = ToTTree()
    t.apply(.treeStart(id: "tot-1", model: "qwen", breadth: 3, depth: 2, beamWidth: 2))
    XCTAssertEqual(t.status, .searching)
    XCTAssertEqual(t.id, "tot-1")
    XCTAssertEqual(t.breadth, 3)
    XCTAssertEqual(t.depth, 2)
    XCTAssertEqual(t.beamWidth, 2)
  }

  func test_node_complete_appends_in_arrival_order_as_pending() {
    var t = ToTTree()
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0)))
    t.apply(.nodeComplete(node("tot-n2", parent: "root", depth: 1, branch: 1)))
    XCTAssertEqual(t.nodes.map(\.id), ["tot-n1", "tot-n2"])
    XCTAssertTrue(t.nodes.allSatisfy { $0.beam == .pending })
  }

  func test_level_pruned_marks_kept_and_pruned() {
    var t = ToTTree()
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0, score: 8)))
    t.apply(.nodeComplete(node("tot-n2", parent: "root", depth: 1, branch: 1, score: 3)))
    t.apply(.levelPruned(level: 1, kept: ["tot-n1"]))

    let n1 = t.nodes.first { $0.id == "tot-n1" }
    let n2 = t.nodes.first { $0.id == "tot-n2" }
    XCTAssertEqual(n1?.beam, .kept)
    XCTAssertEqual(n2?.beam, .pruned)
    XCTAssertTrue(t.prunedLevels.contains(1))
  }

  func test_level_pruned_only_touches_its_own_depth() {
    var t = ToTTree()
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0)))
    t.apply(.nodeComplete(node("tot-n3", parent: "tot-n1", depth: 2, branch: 0)))
    // Prune level 1 only.
    t.apply(.levelPruned(level: 1, kept: ["tot-n1"]))
    XCTAssertEqual(t.nodes.first { $0.id == "tot-n1" }?.beam, .kept)
    // The depth-2 node is untouched (its level hasn't pruned).
    XCTAssertEqual(t.nodes.first { $0.id == "tot-n3" }?.beam, .pending)
  }

  func test_tree_complete_records_selection_and_completes() {
    var t = ToTTree()
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0, content: "4", score: 9)))
    t.apply(.levelPruned(level: 1, kept: ["tot-n1"]))
    t.apply(.treeComplete(selectedNodeID: "tot-n1", finalAnswer: "4"))
    XCTAssertEqual(t.status, .complete)
    XCTAssertEqual(t.selectedNodeID, "tot-n1")
    XCTAssertEqual(t.finalAnswer, "4")
    XCTAssertEqual(t.selectedNode?.content, "4")
  }

  func test_final_delta_accumulates_then_tree_complete_is_authoritative() {
    // #523 Part A: the synthesized answer streams as final_delta chunks; the
    // terminal tree_complete overwrites with the authoritative full text.
    var t = ToTTree()
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0, content: "raw", score: 9)))
    t.apply(.levelPruned(level: 1, kept: ["tot-n1"]))
    t.apply(.finalDelta(text: "The "))
    t.apply(.finalDelta(text: "final answer."))
    XCTAssertEqual(t.finalAnswer, "The final answer.")
    t.apply(.treeComplete(selectedNodeID: "tot-n1", finalAnswer: "The final answer."))
    XCTAssertEqual(t.finalAnswer, "The final answer.")
    XCTAssertEqual(t.status, .complete)
  }

  func test_tree_complete_null_selection_is_honest() {
    var t = ToTTree()
    t.apply(.treeStart(id: "x", model: "m", breadth: 1, depth: 1, beamWidth: 1))
    t.apply(.treeComplete(selectedNodeID: nil, finalAnswer: nil))
    XCTAssertEqual(t.status, .complete)
    XCTAssertNil(t.selectedNodeID)
    XCTAssertNil(t.selectedNode)
  }

  func test_fail_sets_failed_status() {
    var t = ToTTree()
    t.apply(.treeStart(id: "x", model: "m", breadth: 1, depth: 1, beamWidth: 1))
    t.fail("engine stream error (boom)")
    XCTAssertEqual(t.status, .failed("engine stream error (boom)"))
  }

  func test_children_and_root_children_assemble_hierarchy() {
    var t = ToTTree()
    // Stream out of branch order to prove the sort.
    t.apply(.nodeComplete(node("tot-n2", parent: "root", depth: 1, branch: 1)))
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0)))
    t.apply(.nodeComplete(node("tot-n3", parent: "tot-n1", depth: 2, branch: 0)))

    XCTAssertEqual(t.rootChildren.map(\.id), ["tot-n1", "tot-n2"])  // sorted by branchIndex
    XCTAssertEqual(t.children(of: "tot-n1").map(\.id), ["tot-n3"])
    XCTAssertTrue(t.children(of: "tot-n2").isEmpty)
  }

  func test_full_two_level_search_folds_consistently() {
    var t = ToTTree()
    t.apply(.treeStart(id: "tot-1", model: "qwen", breadth: 2, depth: 2, beamWidth: 1))
    // level 1
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0, score: 7)))
    t.apply(.nodeComplete(node("tot-n2", parent: "root", depth: 1, branch: 1, score: 4)))
    t.apply(.levelPruned(level: 1, kept: ["tot-n1"]))
    // level 2 (only the kept frontier expands)
    t.apply(.nodeComplete(node("tot-n5", parent: "tot-n1", depth: 2, branch: 0, score: 9)))
    t.apply(.nodeComplete(node("tot-n6", parent: "tot-n1", depth: 2, branch: 1, score: 6)))
    t.apply(.levelPruned(level: 2, kept: ["tot-n5"]))
    t.apply(.treeComplete(selectedNodeID: "tot-n5", finalAnswer: "answer"))

    XCTAssertEqual(t.status, .complete)
    XCTAssertEqual(t.prunedLevels, [1, 2])
    XCTAssertEqual(t.nodes.first { $0.id == "tot-n2" }?.beam, .pruned)
    XCTAssertEqual(t.nodes.first { $0.id == "tot-n1" }?.beam, .kept)
    XCTAssertEqual(t.nodes.first { $0.id == "tot-n6" }?.beam, .pruned)
    XCTAssertEqual(t.selectedNode?.id, "tot-n5")
    // Hierarchy: n1 → n5,n6 ; n2 childless (pruned).
    XCTAssertEqual(t.children(of: "tot-n1").map(\.id), ["tot-n5", "tot-n6"])
    XCTAssertTrue(t.children(of: "tot-n2").isEmpty)
  }

  func test_node_complete_carries_reasoning_into_tree() {
    // #413/#437: the demuxed reasoning rides the node into the live tree.
    var t = ToTTree()
    t.apply(.nodeComplete(
      node("tot-n1", parent: "root", depth: 1, branch: 0,
           content: "the answer", reasoning: "first weigh A vs B")))
    XCTAssertEqual(t.nodes.first?.reasoning, "first weigh A vs B")
    XCTAssertEqual(t.nodes.first?.content, "the answer")
  }

  func test_incomplete_node_round_trips_through_persistence() throws {
    var t = ToTTree()
    t.apply(.treeStart(id: "tot-1", model: "qwen", breadth: 1, depth: 1, beamWidth: 1))
    t.apply(.nodeComplete(
      node("tot-n1", parent: "root", depth: 1, branch: 0,
           content: "", reasoning: "still thinking…", status: .incomplete)))
    let data = try JSONEncoder().encode(t)
    let back = try JSONDecoder().decode(ToTTree.self, from: data)
    XCTAssertEqual(back.nodes.first?.status, .incomplete)
    XCTAssertEqual(back.nodes.first?.reasoning, "still thinking…")
  }

  func test_persisted_tree_missing_reasoning_key_decodes_with_empty() throws {
    // A ToTTree persisted (Message.tot) before `reasoning` existed must still
    // load — the renderer treats a decode failure as no tree, so a required
    // new key would silently drop a reloaded search. Simulate the old shape
    // by stripping the key from a real encoding.
    var t = ToTTree()
    t.apply(.nodeComplete(
      node("tot-n1", parent: "root", depth: 1, branch: 0,
           content: "4", reasoning: "legacy thought", score: 9)))
    var json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
    // Drop `"reasoning":"legacy thought"` plus one adjacent comma, whichever
    // side it sits on, so the remaining object is still valid JSON.
    json = json.replacingOccurrences(of: #","reasoning":"legacy thought""#, with: "")
    json = json.replacingOccurrences(of: #""reasoning":"legacy thought","#, with: "")
    XCTAssertFalse(json.contains("reasoning"), "precondition: key removed")
    let back = try JSONDecoder().decode(ToTTree.self, from: Data(json.utf8))
    XCTAssertEqual(back.nodes.first?.reasoning, "")
    XCTAssertEqual(back.nodes.first?.content, "4")
  }

  // ── #413 phase B: token-level streaming ──

  func test_node_start_then_deltas_live_fill_then_complete_reconciles() {
    var t = ToTTree()
    t.apply(.treeStart(id: "tot-1", model: "qwen", breadth: 1, depth: 1, beamWidth: 1))
    // node_start creates a provisional, empty node.
    t.apply(.nodeStart(id: "tot-n1", parentID: "root", depth: 1, branchIndex: 0))
    XCTAssertEqual(t.nodes.count, 1)
    XCTAssertEqual(t.nodes.first?.content, "")
    XCTAssertEqual(t.nodes.first?.reasoning, "")
    XCTAssertEqual(t.rootChildren.map(\.id), ["tot-n1"])  // placed in the tree

    // reasoning streams first, then the answer (the demux order).
    t.apply(.nodeDelta(id: "tot-n1", channel: .reasoning, text: "first "))
    t.apply(.nodeDelta(id: "tot-n1", channel: .reasoning, text: "weigh A vs B"))
    XCTAssertEqual(t.nodes.first?.reasoning, "first weigh A vs B")
    XCTAssertEqual(t.nodes.first?.content, "")
    t.apply(.nodeDelta(id: "tot-n1", channel: .answer, text: "Pick "))
    t.apply(.nodeDelta(id: "tot-n1", channel: .answer, text: "A."))
    XCTAssertEqual(t.nodes.first?.content, "Pick A.")
    XCTAssertEqual(t.nodes.count, 1, "deltas fill the existing node, never duplicate")

    // node_complete reconciles to the authoritative node (adds the score).
    t.apply(.nodeComplete(
      node("tot-n1", parent: "root", depth: 1, branch: 0,
           content: "Pick A.", reasoning: "first weigh A vs B", score: 8)))
    XCTAssertEqual(t.nodes.count, 1)
    XCTAssertEqual(t.nodes.first?.score, 8)
    XCTAssertEqual(t.nodes.first?.content, "Pick A.")
  }

  func test_node_delta_before_its_start_is_dropped() {
    var t = ToTTree()
    t.apply(.nodeDelta(id: "ghost", channel: .answer, text: "x"))
    XCTAssertTrue(t.nodes.isEmpty)
  }

  // ── #650: concurrent sibling decode — deltas multiplexed by branch id ──

  /// Before #650 the streaming search generated branches sequentially, so a
  /// node's start + deltas + complete never interleaved with a sibling's. Now
  /// siblings decode in flight and their `node_delta` frames interleave on the
  /// one SSE stream, each tagged by node id. This proves the consumer routes
  /// interleaved frames to the right node purely by id — the UI guarantee that
  /// lets concurrent branches animate filling at once.
  func test_interleaved_sibling_deltas_route_by_id() {
    var t = ToTTree()
    t.apply(.treeStart(id: "tot-1", model: "qwen", breadth: 2, depth: 1, beamWidth: 1))
    // Both siblings announce before either streams (concurrent start), and the
    // second sibling's node_start lands AFTER the first sibling's first delta —
    // an ordering the old sequential path never produced.
    t.apply(.nodeStart(id: "tot-n1", parentID: "root", depth: 1, branchIndex: 0))
    t.apply(.nodeDelta(id: "tot-n1", channel: .reasoning, text: "A1 "))
    t.apply(.nodeStart(id: "tot-n2", parentID: "root", depth: 1, branchIndex: 1))
    // Interleave the two branches' deltas chunk-by-chunk.
    t.apply(.nodeDelta(id: "tot-n2", channel: .reasoning, text: "B1 "))
    t.apply(.nodeDelta(id: "tot-n1", channel: .answer, text: "Ans-A "))
    t.apply(.nodeDelta(id: "tot-n2", channel: .answer, text: "Ans-B "))
    t.apply(.nodeDelta(id: "tot-n1", channel: .reasoning, text: "A2"))
    t.apply(.nodeDelta(id: "tot-n2", channel: .answer, text: "Ans-B2"))

    // Each node accumulated ONLY its own channel chunks, in per-node order,
    // with zero cross-talk between the interleaved siblings.
    let n1 = t.nodes.first { $0.id == "tot-n1" }
    let n2 = t.nodes.first { $0.id == "tot-n2" }
    XCTAssertEqual(n1?.reasoning, "A1 A2")
    XCTAssertEqual(n1?.content, "Ans-A ")
    XCTAssertEqual(n2?.reasoning, "B1 ")
    XCTAssertEqual(n2?.content, "Ans-B Ans-B2")
    XCTAssertEqual(t.nodes.count, 2, "interleaved deltas never duplicate a node")
    // Display order stays (branchIndex, id) regardless of frame arrival order.
    XCTAssertEqual(t.rootChildren.map(\.id), ["tot-n1", "tot-n2"])
  }

  // MARK: - live phase (#413 scoring indicator)

  func test_live_phase_generating_then_scoring_then_complete() {
    var t = ToTTree()
    t.apply(.nodeStart(id: "tot-n1", parentID: "root", depth: 1, branchIndex: 0))
    XCTAssertEqual(t.nodes.first?.livePhase, .generating, "provisional node is generating")
    t.apply(.nodeDelta(id: "tot-n1", channel: .answer, text: "4"))
    XCTAssertEqual(t.nodes.first?.livePhase, .generating, "still generating while content streams")
    t.apply(.nodeScoring(id: "tot-n1"))
    XCTAssertEqual(t.nodes.first?.livePhase, .scoring, "node_scoring flips to scoring")
    XCTAssertEqual(t.nodes.first?.content, "4", "scoring does not disturb the streamed content")
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0, content: "4", score: 8)))
    XCTAssertEqual(t.nodes.first?.livePhase, .complete, "node_complete reconciles to complete")
    XCTAssertEqual(t.nodes.first?.score, 8)
  }

  func test_node_scoring_for_unknown_id_is_ignored() {
    var t = ToTTree()
    t.apply(.nodeScoring(id: "ghost"))
    XCTAssertTrue(t.nodes.isEmpty, "a scoring frame for an unknown node is a no-op")
  }

  func test_node_complete_only_path_defaults_live_phase_complete() {
    // The non-stream path emits only node_complete (no node_start/node_scoring);
    // such a node is authoritative and renders as complete, not generating.
    var t = ToTTree()
    t.apply(.nodeComplete(node("tot-n1", parent: "root", depth: 1, branch: 0, score: 7)))
    XCTAssertEqual(t.nodes.first?.livePhase, .complete)
  }
}
