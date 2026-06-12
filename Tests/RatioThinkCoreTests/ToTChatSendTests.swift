import XCTest
import SwiftData
@testable import RatioThinkCore

/// Integration tests for the tree-of-thought send path (#413):
/// `ChatSendController.sendTreeOfThought` consumes the `/v1/inferlet` SSE
/// tree stream, folds it into a persisted `ToTTree` snapshot on the
/// assistant row, and sets the final answer as the row's content.
@available(macOS 14, *)
@MainActor
final class ToTChatSendTests: XCTestCase {

  func test_streams_tree_persists_snapshot_and_sets_final_answer() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "What is 2+2?",
                                 ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ToTFrameEngine(frames: [
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":2,"depth":1,"beam_width":1}"#,
      #"{"event":"node_complete","node":{"id":"tot-n1","parent_id":"root","depth":1,"branch_index":0,"content":"4","score":9,"status":"ok"}}"#,
      #"{"event":"node_complete","node":{"id":"tot-n2","parent_id":"root","depth":1,"branch_index":1,"content":"5","score":3,"status":"ok"}}"#,
      #"{"event":"level_pruned","level":1,"kept":["tot-n1"]}"#,
      #"{"event":"tree_complete","selected_node_id":"tot-n1","final_answer":"4"}"#,
    ])
    let controller = ChatSendController()
    controller.sendTreeOfThought(
      chat: chat,
      context: context,
      engine: engine,
      config: ToTProfileConfig(breadth: 2, depth: 1, beamWidth: 1),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "qwen")
    )
    try await waitUntil("tot stream finishes") { !controller.isInFlight }

    let assistants = chat.messages.filter { $0.role == "assistant" }
    XCTAssertEqual(assistants.count, 1)
    let assistant = try XCTUnwrap(assistants.first)
    XCTAssertEqual(assistant.content, "4")

    let totData = try XCTUnwrap(assistant.tot, "expected a persisted ToTTree snapshot")
    let tree = try JSONDecoder().decode(ToTTree.self, from: totData)
    XCTAssertEqual(tree.status, .complete)
    XCTAssertEqual(tree.selectedNodeID, "tot-n1")
    XCTAssertEqual(tree.finalAnswer, "4")
    XCTAssertEqual(tree.nodes.count, 2)
    XCTAssertEqual(tree.nodes.first { $0.id == "tot-n1" }?.beam, .kept)
    XCTAssertEqual(tree.nodes.first { $0.id == "tot-n2" }?.beam, .pruned)

    // The dispatch routed to tree-of-thought with the bounded params.
    let req = try XCTUnwrap(engine.lastRequest)
    XCTAssertEqual(req.inferlet, "tree-of-thought")
    XCTAssertTrue(req.stream)
    let input = try JSONSerialization.jsonObject(with: req.input) as? [String: Any]
    XCTAssertEqual(input?["breadth"] as? Int, 2)
    XCTAssertEqual(input?["depth"] as? Int, 1)
    XCTAssertEqual(input?["beam_width"] as? Int, 1)
    // Transcript rides inside `input` (the dispatch envelope's top-level
    // messages stays nil; input.messages wins server-side).
    let msgs = input?["messages"] as? [[String: Any]]
    XCTAssertEqual(msgs?.first?["content"] as? String, "What is 2+2?")
  }

  func test_stream_ends_without_terminal_marks_assistant_failed_not_silent_hang() async throws {
    // The real-stall repro: the engine streamed level 1 + its beam, then
    // closed the connection mid-level-2 (per-request timeout on a slow
    // search) — NO tree_complete, NO error frame. The turn must surface a
    // failure (the partial tree preserved), not sit as a silent half-tree
    // that looks like a permanent hang.
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ToTFrameEngine(frames: [
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":3,"depth":2,"beam_width":2}"#,
      #"{"event":"node_complete","node":{"id":"tot-n1","parent_id":"root","depth":1,"branch_index":0,"content":"a","score":null,"status":"ok"}}"#,
      #"{"event":"node_complete","node":{"id":"tot-n2","parent_id":"root","depth":1,"branch_index":1,"content":"b","score":null,"status":"ok"}}"#,
      #"{"event":"node_complete","node":{"id":"tot-n3","parent_id":"root","depth":1,"branch_index":2,"content":"c","score":null,"status":"ok"}}"#,
      #"{"event":"level_pruned","level":1,"kept":["tot-n1","tot-n2"]}"#,
      // …connection closes here — no level-2 nodes, no terminal frame.
    ])
    let controller = ChatSendController()
    controller.sendTreeOfThought(
      chat: chat, context: context, engine: engine,
      config: ToTProfileConfig(breadth: 3, depth: 2, beamWidth: 2),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "qwen")
    )
    try await waitUntil("tot no-terminal stream ends") { !controller.isInFlight }

    let assistant = try XCTUnwrap(chat.messages.first { $0.role == "assistant" })
    XCTAssertTrue(assistant.content.hasPrefix("⚠️"),
                  "a no-terminal stream close must surface a failure, not a silent hang: \(assistant.content.debugDescription)")
    let tree = try JSONDecoder().decode(ToTTree.self, from: try XCTUnwrap(assistant.tot))
    guard case .failed = tree.status else { return XCTFail("expected .failed, got \(tree.status)") }
    // The partial tree (level 1) is preserved for inspection.
    XCTAssertEqual(tree.nodes.count, 3)
    XCTAssertEqual(tree.nodes.first { $0.id == "tot-n1" }?.beam, .kept)
    XCTAssertEqual(tree.nodes.first { $0.id == "tot-n3" }?.beam, .pruned)
  }

  func test_token_deltas_accumulate_into_preserved_tree_despite_throttled_encode() async throws {
    // #413 phase B: token deltas live-fill a node; the live-encode is
    // coalesced (~15 Hz) so a delta flood doesn't rebuild the view thousands
    // of times. Correctness contract: the FINAL persisted tot must reflect
    // every delta even though intermediate encodes are throttled. Drive
    // node_start + reasoning/answer deltas, then close with NO terminal — the
    // preserved partial tree must carry the fully-accumulated text.
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ToTFrameEngine(frames: [
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":1,"depth":1,"beam_width":1}"#,
      #"{"event":"node_start","id":"tot-n1","parent_id":"root","depth":1,"branch_index":0}"#,
      #"{"event":"node_delta","id":"tot-n1","kind":"reasoning","text":"weigh "}"#,
      #"{"event":"node_delta","id":"tot-n1","kind":"reasoning","text":"A vs B"}"#,
      #"{"event":"node_delta","id":"tot-n1","kind":"answer","text":"Pick "}"#,
      #"{"event":"node_delta","id":"tot-n1","kind":"answer","text":"A."}"#,
      // …connection closes here — no node_complete, no terminal.
    ])
    let controller = ChatSendController()
    controller.sendTreeOfThought(
      chat: chat, context: context, engine: engine,
      config: ToTProfileConfig(breadth: 1, depth: 1, beamWidth: 1),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "qwen")
    )
    try await waitUntil("tot delta stream ends") { !controller.isInFlight }

    let assistant = try XCTUnwrap(chat.messages.first { $0.role == "assistant" })
    XCTAssertTrue(assistant.content.hasPrefix("⚠️"), "no-terminal close surfaces a failure")
    let tree = try JSONDecoder().decode(ToTTree.self, from: try XCTUnwrap(assistant.tot))
    let node = try XCTUnwrap(tree.nodes.first { $0.id == "tot-n1" })
    // Every delta survived into the final (throttled) encode.
    XCTAssertEqual(node.reasoning, "weigh A vs B")
    XCTAssertEqual(node.content, "Pick A.")
  }

  func test_error_frame_marks_assistant_failed_and_persists_failed_tree() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ToTFrameEngine(frames: [
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":1,"depth":1,"beam_width":1}"#,
      #"{"event":"error","code":"serialize_bug","message":"boom"}"#,
    ])
    let controller = ChatSendController()
    controller.sendTreeOfThought(
      chat: chat,
      context: context,
      engine: engine,
      config: ToTProfileConfig(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "qwen")
    )
    try await waitUntil("tot stream fails") { !controller.isInFlight }

    let assistant = try XCTUnwrap(chat.messages.first { $0.role == "assistant" })
    XCTAssertTrue(assistant.content.hasPrefix("⚠️"), "failed turn should surface the error: \(assistant.content)")
    let tree = try JSONDecoder().decode(ToTTree.self, from: try XCTUnwrap(assistant.tot))
    guard case .failed = tree.status else {
      return XCTFail("expected failed status, got \(tree.status)")
    }
  }

  func test_no_ok_leaf_treeComplete_marks_assistant_failed_not_blank_success() async throws {
    // F1 (client defensive): an all-error search that terminates with
    // tree_complete{nil,nil} (no ok leaf — a total failure) must mark the
    // assistant FAILED, not persist as a blank `.complete` successful turn.
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ToTFrameEngine(frames: [
      #"{"event":"tree_start","id":"tot-1","model":"qwen","breadth":2,"depth":1,"beam_width":1}"#,
      #"{"event":"node_complete","node":{"id":"tot-n1","parent_id":"root","depth":1,"branch_index":0,"content":"","score":null,"status":"error","error":"generate failed: boom"}}"#,
      #"{"event":"node_complete","node":{"id":"tot-n2","parent_id":"root","depth":1,"branch_index":1,"content":"","score":null,"status":"error","error":"generate failed: boom"}}"#,
      #"{"event":"level_pruned","level":1,"kept":[]}"#,
      #"{"event":"tree_complete","selected_node_id":null,"final_answer":null}"#,
    ])
    let controller = ChatSendController()
    controller.sendTreeOfThought(
      chat: chat,
      context: context,
      engine: engine,
      config: ToTProfileConfig(breadth: 2, depth: 1, beamWidth: 1),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "qwen")
    )
    try await waitUntil("tot no-ok-leaf stream finishes") { !controller.isInFlight }

    let assistant = try XCTUnwrap(chat.messages.first { $0.role == "assistant" })
    XCTAssertTrue(assistant.content.hasPrefix("⚠️"),
                  "a no-ok-leaf total failure must NOT be a blank successful turn: \(assistant.content.debugDescription)")
    let tree = try JSONDecoder().decode(ToTTree.self, from: try XCTUnwrap(assistant.tot))
    guard case .failed = tree.status else {
      return XCTFail("expected .failed, got \(tree.status)")
    }
    // The streamed error tree is preserved for inspection.
    XCTAssertEqual(tree.nodes.count, 2)
    XCTAssertTrue(tree.nodes.allSatisfy { $0.status == .error })
  }

  func test_non_tot_profile_does_not_route_to_dispatch() {
    // A profile with no mode key is not a ToT profile, so the routing
    // guard in the view never calls sendTreeOfThought. This documents the
    // gate at the convention layer (full routing is covered by GUI tests).
    let p = Profile(id: "chat", name: "Chat", model: "qwen", inferlet: "chat-apc")
    XCTAssertNil(p.treeOfThought)
  }

  // MARK: - helpers

  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: @MainActor @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
  }
}

/// Mock engine whose `dispatchInferlet` replays a fixed list of SSE
/// `data:` payloads (decoded by `toTEventStream`). Records the last
/// request so the test can assert the dispatch routed correctly.
private final class ToTFrameEngine: EngineClient, @unchecked Sendable {
  private let frames: [String]
  private(set) var lastRequest: InferletRequest?

  init(frames: [String]) { self.frames = frames }

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    lastRequest = req
    let frames = self.frames
    return AsyncThrowingStream { continuation in
      for f in frames { continuation.yield(Data(f.utf8)) }
      continuation.finish()
    }
  }
}
