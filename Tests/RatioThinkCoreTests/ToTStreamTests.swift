import XCTest
@testable import RatioThinkCore

/// Wire-format decode tests for the tree-of-thought streaming frames
/// (#413). Pure: drives `decodeToTFrame` / `toTEventStream` with synthetic
/// `data:` payloads, no engine.
final class ToTStreamTests: XCTestCase {

  private func frame(_ json: String) -> Data { Data(json.utf8) }

  // MARK: - decodeToTFrame

  func test_decodes_tree_start_with_bounds() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":3,"depth":2,"beam_width":2}"#
    ))
    XCTAssertEqual(e, .treeStart(id: "tot-1", model: "qwen", breadth: 3, depth: 2, beamWidth: 2))
  }

  func test_decodes_node_complete_flat_with_snake_case_keys() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"node_complete","node":{"id":"tot-n3","parent_id":"root","depth":1,"branch_index":0,"content":"4","score":8,"status":"ok"}}"#
    ))
    guard case let .nodeComplete(node) = e else { return XCTFail("want nodeComplete, got \(String(describing: e))") }
    XCTAssertEqual(node.id, "tot-n3")
    XCTAssertEqual(node.parentID, "root")
    XCTAssertEqual(node.depth, 1)
    XCTAssertEqual(node.branchIndex, 0)
    XCTAssertEqual(node.score, 8)
    XCTAssertEqual(node.status, .ok)
    XCTAssertNil(node.error)
    XCTAssertNil(node.scoreError)
  }

  func test_decodes_node_complete_error_and_score_error() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"node_complete","node":{"id":"tot-n9","parent_id":"tot-n1","depth":2,"branch_index":1,"content":"","score":null,"status":"error","error":"fork failed: gone"}}"#
    ))
    guard case let .nodeComplete(node) = e else { return XCTFail("want nodeComplete") }
    XCTAssertEqual(node.status, .error)
    XCTAssertEqual(node.error, "fork failed: gone")
    XCTAssertNil(node.score)

    let e2 = try decodeToTFrame(frame(
      #"{"event":"node_complete","node":{"id":"tot-n4","parent_id":"root","depth":1,"branch_index":0,"content":"ans","score":null,"status":"ok","score_error":"score fork failed: boom"}}"#
    ))
    guard case let .nodeComplete(node2) = e2 else { return XCTFail("want nodeComplete") }
    XCTAssertEqual(node2.status, .ok)
    XCTAssertNil(node2.score)
    XCTAssertEqual(node2.scoreError, "score fork failed: boom")
  }

  func test_decodes_node_complete_with_reasoning() throws {
    // #413/#437: a thinking node carries its demuxed reasoning beside the
    // (clean) answer.
    let e = try decodeToTFrame(frame(
      #"{"event":"node_complete","node":{"id":"tot-n3","parent_id":"root","depth":1,"branch_index":0,"content":"4","reasoning":"2+2 is 4 because…","score":8,"status":"ok"}}"#
    ))
    guard case let .nodeComplete(node) = e else { return XCTFail("want nodeComplete") }
    XCTAssertEqual(node.reasoning, "2+2 is 4 because…")
    XCTAssertEqual(node.content, "4")
  }

  func test_node_complete_without_reasoning_defaults_empty() throws {
    // The wire omits `reasoning` when empty (non-reasoning model / thinking
    // off); decode must default it rather than fail the frame.
    let e = try decodeToTFrame(frame(
      #"{"event":"node_complete","node":{"id":"tot-n3","parent_id":"root","depth":1,"branch_index":0,"content":"4","score":8,"status":"ok"}}"#
    ))
    guard case let .nodeComplete(node) = e else { return XCTFail("want nodeComplete") }
    XCTAssertEqual(node.reasoning, "")
  }

  func test_decodes_incomplete_status_with_partial_reasoning() throws {
    // #434: a reasoned-but-unanswered node streams as status "incomplete"
    // with its partial reasoning and an empty answer.
    let e = try decodeToTFrame(frame(
      #"{"event":"node_complete","node":{"id":"tot-n7","parent_id":"tot-n1","depth":2,"branch_index":0,"content":"","reasoning":"I was still working through the cases","score":null,"status":"incomplete","error":"no answer"}}"#
    ))
    guard case let .nodeComplete(node) = e else { return XCTFail("want nodeComplete") }
    XCTAssertEqual(node.status, .incomplete)
    XCTAssertEqual(node.reasoning, "I was still working through the cases")
    XCTAssertEqual(node.content, "")
    XCTAssertEqual(node.error, "no answer")
  }

  func test_decodes_node_start() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"node_start","id":"tot-n4","parent_id":"tot-n1","depth":2,"branch_index":1}"#
    ))
    guard case let .nodeStart(id, parentID, depth, branchIndex) = e else {
      return XCTFail("want nodeStart, got \(String(describing: e))")
    }
    XCTAssertEqual(id, "tot-n4")
    XCTAssertEqual(parentID, "tot-n1")
    XCTAssertEqual(depth, 2)
    XCTAssertEqual(branchIndex, 1)
  }

  func test_decodes_node_delta_reasoning_then_answer() throws {
    let r = try decodeToTFrame(frame(
      #"{"event":"node_delta","id":"tot-n4","kind":"reasoning","text":"weigh A"}"#
    ))
    guard case let .nodeDelta(id, channel, text) = r else { return XCTFail("want nodeDelta") }
    XCTAssertEqual(id, "tot-n4")
    XCTAssertEqual(channel, .reasoning)
    XCTAssertEqual(text, "weigh A")

    let a = try decodeToTFrame(frame(
      #"{"event":"node_delta","id":"tot-n4","kind":"answer","text":"The answer"}"#
    ))
    guard case let .nodeDelta(_, channel2, text2) = a else { return XCTFail("want nodeDelta") }
    XCTAssertEqual(channel2, .answer)
    XCTAssertEqual(text2, "The answer")
  }

  func test_unknown_delta_channel_is_dropped() throws {
    // Forward-compat: a newer engine channel must not kill the stream.
    XCTAssertNil(try decodeToTFrame(frame(
      #"{"event":"node_delta","id":"tot-n4","kind":"future_channel","text":"x"}"#
    )))
  }

  func test_decodes_level_pruned() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"level_pruned","level":1,"kept":["tot-n1","tot-n2"]}"#
    ))
    XCTAssertEqual(e, .levelPruned(level: 1, kept: ["tot-n1", "tot-n2"]))
  }

  func test_decodes_level_pruned_empty_beam() throws {
    let e = try decodeToTFrame(frame(#"{"event":"level_pruned","level":2,"kept":[]}"#))
    XCTAssertEqual(e, .levelPruned(level: 2, kept: []))
  }

  func test_decodes_tree_complete_with_selection() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"tree_complete","selected_node_id":"tot-n3","final_answer":"4"}"#
    ))
    XCTAssertEqual(e, .treeComplete(selectedNodeID: "tot-n3", finalAnswer: "4"))
  }

  func test_decodes_tree_complete_null_selection() throws {
    let e = try decodeToTFrame(frame(
      #"{"event":"tree_complete","selected_node_id":null,"final_answer":null}"#
    ))
    XCTAssertEqual(e, .treeComplete(selectedNodeID: nil, finalAnswer: nil))
  }

  func test_decodes_final_delta() throws {
    // #523 Part A: streamed chunk of the synthesized final answer.
    let e = try decodeToTFrame(frame(
      #"{"event":"final_delta","text":"the answer is "}"#
    ))
    XCTAssertEqual(e, .finalDelta(text: "the answer is "))
  }

  func test_final_delta_missing_text_is_malformed() {
    XCTAssertThrowsError(try decodeToTFrame(frame(#"{"event":"final_delta"}"#))) { err in
      guard case .malformedFrame = (err as? ToTStreamError) else {
        return XCTFail("expected malformedFrame, got \(err)")
      }
    }
  }

  func test_error_frame_throws_stream_error() {
    XCTAssertThrowsError(try decodeToTFrame(frame(
      #"{"event":"error","code":"serialize_bug","message":"boom"}"#
    ))) { err in
      XCTAssertEqual(err as? ToTStreamError, .stream(code: "serialize_bug", message: "boom"))
    }
  }

  func test_unknown_event_is_tolerated_as_nil() throws {
    // Forward-compat: a newer engine frame must not kill the stream.
    XCTAssertNil(try decodeToTFrame(frame(#"{"event":"future_frame","x":1}"#)))
  }

  func test_malformed_frame_throws() {
    XCTAssertThrowsError(try decodeToTFrame(frame("not json"))) { err in
      guard case .malformedFrame = (err as? ToTStreamError) else {
        return XCTFail("want malformedFrame, got \(err)")
      }
    }
  }

  func test_tree_start_missing_field_is_malformed() {
    XCTAssertThrowsError(try decodeToTFrame(frame(
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":3}"#
    ))) { err in
      guard case .malformedFrame = (err as? ToTStreamError) else {
        return XCTFail("want malformedFrame")
      }
    }
  }

  // MARK: - toTEventStream adapter

  func test_event_stream_maps_frames_and_drops_unknown() async throws {
    let frames: [Data] = [
      frame(#"{"event":"tree_start","id":"tot-1","model":"m","breadth":2,"depth":1,"beam_width":1}"#),
      frame(#"{"event":"future_frame"}"#),  // dropped
      frame(#"{"event":"node_complete","node":{"id":"tot-n2","parent_id":"root","depth":1,"branch_index":0,"content":"a","score":5,"status":"ok"}}"#),
      frame(#"{"event":"level_pruned","level":1,"kept":["tot-n2"]}"#),
      frame(#"{"event":"tree_complete","selected_node_id":"tot-n2","final_answer":"a"}"#),
    ]
    let source = AsyncThrowingStream<Data, Error> { c in
      for f in frames { c.yield(f) }
      c.finish()
    }
    var got: [ToTEvent] = []
    for try await e in toTEventStream(from: source) { got.append(e) }
    XCTAssertEqual(got, [
      .treeStart(id: "tot-1", model: "m", breadth: 2, depth: 1, beamWidth: 1),
      .nodeComplete(ToTNode(id: "tot-n2", parentID: "root", depth: 1, branchIndex: 0, content: "a", score: 5, status: .ok)),
      .levelPruned(level: 1, kept: ["tot-n2"]),
      .treeComplete(selectedNodeID: "tot-n2", finalAnswer: "a"),
    ])
  }

  func test_event_stream_throws_on_error_frame() async {
    let source = AsyncThrowingStream<Data, Error> { c in
      c.yield(self.frame(#"{"event":"tree_start","id":"x","model":"m","breadth":1,"depth":1,"beam_width":1}"#))
      c.yield(self.frame(#"{"event":"error","code":"boom","message":"bad"}"#))
      c.finish()
    }
    do {
      for try await _ in toTEventStream(from: source) {}
      XCTFail("expected throw on error frame")
    } catch {
      XCTAssertEqual(error as? ToTStreamError, .stream(code: "boom", message: "bad"))
    }
  }
}
