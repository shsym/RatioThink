import XCTest
@testable import RatioThinkCore

/// Reducer tests for the live tree-of-thought accumulator (#413). Pure:
/// folds `ToTEvent`s and asserts the rendered state — beam highlighting,
/// hierarchy assembly, terminal selection — with no engine or view.
final class ToTTreeTests: XCTestCase {

  private func node(
    _ id: String, parent: String, depth: Int, branch: Int,
    content: String = "x", score: Int? = nil, status: ToTNodeStatus = .ok
  ) -> ToTNode {
    ToTNode(id: id, parentID: parent, depth: depth, branchIndex: branch,
            content: content, score: score, status: status)
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
}
