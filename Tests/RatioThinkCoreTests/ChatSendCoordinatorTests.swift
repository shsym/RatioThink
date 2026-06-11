import XCTest
import SwiftData
@testable import RatioThinkCore

/// #507: app-scoped per-chat send pipelines. Chat generation lifetime is
/// independent of the detail view: controllers are stable per chat id,
/// different chats stream concurrently, the per-chat in-flight set drives
/// the sidebar indicators, and same-chat supersede stays scoped to its
/// own chat.
@available(macOS 14, *)
@MainActor
final class ChatSendCoordinatorTests: XCTestCase {
  func test_controller_identity_is_stable_per_chat_and_distinct_across_chats() {
    let coordinator = ChatSendCoordinator()
    let a = UUID()
    let b = UUID()
    XCTAssertTrue(coordinator.controller(for: a) === coordinator.controller(for: a),
                  "same chat must reuse its controller across view rebuilds")
    XCTAssertFalse(coordinator.controller(for: a) === coordinator.controller(for: b),
                   "different chats must own independent controllers")
  }

  func test_two_chats_stream_concurrently_and_inFlight_tracks_each() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chatA = Chat()
    let chatB = Chat()
    context.insert(chatA)
    context.insert(chatB)
    chatA.messages.append(Message(role: "user", content: "a", ts: Date(timeIntervalSinceReferenceDate: 1)))
    chatB.messages.append(Message(role: "user", content: "b", ts: Date(timeIntervalSinceReferenceDate: 2)))
    try context.save()

    let engine = ManualCoordinatorChatEngine()
    let coordinator = ChatSendCoordinator()
    var edges: [Bool] = []
    coordinator.onAnyInFlightChange = { edges.append($0) }

    send(coordinator.controller(for: chatA.id), chat: chatA, context: context, engine: engine, model: "mA")
    send(coordinator.controller(for: chatB.id), chat: chatB, context: context, engine: engine, model: "mB")
    try await waitUntil("both requests start") { engine.requests.count == 2 }

    XCTAssertTrue(coordinator.isInFlight(chatA.id))
    XCTAssertTrue(coordinator.isInFlight(chatB.id))
    XCTAssertEqual(coordinator.inFlightChatIDs, [chatA.id, chatB.id])
    XCTAssertEqual(edges, [true], "aggregate edge fires once when the first stream starts")

    // Both streams write deltas while BOTH are in flight — concurrent, not
    // serialized behind one view-scoped controller.
    engine.yield(.delta(role: .assistant, content: "alpha"), at: 0)
    engine.yield(.modelReady, at: 0)
    engine.yield(.delta(role: .assistant, content: "beta"), at: 1)
    engine.yield(.modelReady, at: 1)
    try await waitUntil("both deltas persist") {
      self.assistantContents(in: chatA) == ["alpha"] && self.assistantContents(in: chatB) == ["beta"]
    }

    // Finish A: only A's indicator clears; the aggregate stays open for B.
    engine.yield(.finish(reason: .stop), at: 0)
    engine.finish(at: 0)
    try await waitUntil("chat A stream finishes") { !coordinator.isInFlight(chatA.id) }
    XCTAssertTrue(coordinator.isInFlight(chatB.id))
    XCTAssertEqual(edges, [true])

    engine.yield(.finish(reason: .stop), at: 1)
    engine.finish(at: 1)
    try await waitUntil("chat B stream finishes") { !coordinator.isInFlight(chatB.id) }
    XCTAssertTrue(coordinator.inFlightChatIDs.isEmpty)
    XCTAssertEqual(edges, [true, false], "aggregate edge closes once when the last stream ends")
  }

  func test_same_chat_supersede_does_not_disturb_other_chats_stream() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chatA = Chat()
    let chatB = Chat()
    context.insert(chatA)
    context.insert(chatB)
    chatA.messages.append(Message(role: "user", content: "a1", ts: Date(timeIntervalSinceReferenceDate: 1)))
    chatB.messages.append(Message(role: "user", content: "b1", ts: Date(timeIntervalSinceReferenceDate: 2)))
    try context.save()

    let engine = ManualCoordinatorChatEngine()
    let coordinator = ChatSendCoordinator()

    send(coordinator.controller(for: chatA.id), chat: chatA, context: context, engine: engine, model: "mA")
    send(coordinator.controller(for: chatB.id), chat: chatB, context: context, engine: engine, model: "mB")
    try await waitUntil("both requests start") { engine.requests.count == 2 }
    engine.yield(.delta(role: .assistant, content: "b-partial"), at: 1)
    engine.yield(.modelReady, at: 1)
    try await waitUntil("chat B partial persists") { self.assistantContents(in: chatB) == ["b-partial"] }

    // Sending a NEW turn in chat A supersedes A's stream (request 3 replaces
    // request 1) and leaves B streaming untouched.
    chatA.messages.append(Message(role: "user", content: "a2", ts: Date(timeIntervalSinceReferenceDate: 3)))
    try context.save()
    send(coordinator.controller(for: chatA.id), chat: chatA, context: context, engine: engine, model: "mA")
    try await waitUntil("superseding request starts") { engine.requests.count == 3 }
    try await waitUntil("first stream torn down") { engine.terminationCount >= 1 }

    XCTAssertTrue(coordinator.isInFlight(chatA.id), "supersede keeps chat A in flight on the new turn")
    XCTAssertTrue(coordinator.isInFlight(chatB.id), "chat B's stream must survive chat A's supersede")
    XCTAssertEqual(assistantContents(in: chatB), ["b-partial"])

    engine.yield(.finish(reason: .stop), at: 2)
    engine.finish(at: 2)
    engine.yield(.finish(reason: .stop), at: 1)
    engine.finish(at: 1)
    try await waitUntil("both streams finish") { coordinator.inFlightChatIDs.isEmpty }
  }

  func test_forget_cancels_in_flight_stream_and_drops_controller() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ManualCoordinatorChatEngine()
    let coordinator = ChatSendCoordinator()
    var edges: [Bool] = []
    coordinator.onAnyInFlightChange = { edges.append($0) }
    let controller = coordinator.controller(for: chat.id)
    send(controller, chat: chat, context: context, engine: engine, model: "m")
    try await waitUntil("request starts") { engine.requests.count == 1 }
    XCTAssertTrue(coordinator.isInFlight(chat.id))

    coordinator.forget(chatID: chat.id)

    XCTAssertFalse(coordinator.isInFlight(chat.id))
    // Review v1 F5: deleting a streaming chat must close the any-in-flight
    // aggregate so the #413 helper-health gate is released — guarded here
    // against a future async cancel breaking the cancel→sink ordering.
    XCTAssertEqual(edges, [true, false],
                   "forget of the only streaming chat must edge-fire the aggregate closed")
    try await waitUntil("stream torn down") { engine.terminationCount == 1 }
    XCTAssertFalse(coordinator.controller(for: chat.id) === controller,
                   "forget must drop the controller so a deleted chat's id gets a fresh one")
  }

  func test_cancel_is_user_intent_cancel_for_one_chat_only() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chatA = Chat()
    let chatB = Chat()
    context.insert(chatA)
    context.insert(chatB)
    chatA.messages.append(Message(role: "user", content: "a", ts: Date(timeIntervalSinceReferenceDate: 1)))
    chatB.messages.append(Message(role: "user", content: "b", ts: Date(timeIntervalSinceReferenceDate: 2)))
    try context.save()

    let engine = ManualCoordinatorChatEngine()
    let coordinator = ChatSendCoordinator()
    send(coordinator.controller(for: chatA.id), chat: chatA, context: context, engine: engine, model: "mA")
    send(coordinator.controller(for: chatB.id), chat: chatB, context: context, engine: engine, model: "mB")
    try await waitUntil("both requests start") { engine.requests.count == 2 }

    coordinator.cancel(chatID: chatA.id)

    XCTAssertFalse(coordinator.isInFlight(chatA.id))
    XCTAssertTrue(coordinator.isInFlight(chatB.id))

    engine.yield(.finish(reason: .stop), at: 1)
    engine.finish(at: 1)
    try await waitUntil("chat B finishes") { coordinator.inFlightChatIDs.isEmpty }
  }

  // MARK: - helpers

  private func send(
    _ controller: ChatSendController,
    chat: Chat,
    context: ModelContext,
    engine: EngineClient,
    model: String
  ) {
    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: model)
    )
  }

  private func assistantContents(in chat: Chat) -> [String] {
    chat.messages
      .filter { $0.role == ChatMessage.Role.assistant.rawValue }
      .sorted { $0.ts < $1.ts }
      .map(\.content)
  }

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

/// Per-request manually-driven stream stub (sibling of the private
/// `ManualChatEngine` in `ChatSendControllerTests`): each `chatCompletion`
/// registers a continuation the test drives by request index.
private final class ManualCoordinatorChatEngine: EngineClient, @unchecked Sendable {
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  private(set) var requests: [ChatRequest] = []
  private(set) var terminationCount = 0

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    requests.append(req)
    return AsyncThrowingStream { continuation in
      continuations.append(continuation)
      continuation.onTermination = { [weak self] _ in
        self?.terminationCount += 1
      }
    }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }

  func yield(_ event: ChatEvent, at index: Int) {
    continuations[index].yield(event)
  }

  func finish(at index: Int) {
    continuations[index].finish()
  }
}
