import XCTest
import SwiftData
@testable import RatioThinkCore

@available(macOS 14, *)
@MainActor
final class ChatSendControllerTests: XCTestCase {
  func test_send_builds_request_streams_assistant_and_routes_model_meta() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hello", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ImmediateChatEngine(events: [
      .modelLoading(loadedBytes: 5, totalBytes: 10, etaSeconds: 1.5),
      .modelReady,
      .delta(role: .assistant, content: "Hi"),
      .delta(role: nil, content: " there"),
      .finish(reason: .stop),
    ])
    let center = ModelLoadCenter()
    let status = PersistenceStatus()
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: center,
      persistenceStatus: status,
      options: ChatSendRequestOptions(
        modelID: "override-model",
        sampling: ChatSampling(temperature: 0.2, topP: 0.8, maxTokens: 64),
        systemPromptOverride: "Be concise."
      )
    )

    try await waitUntil("stream finishes") { !controller.isInFlight }

    XCTAssertEqual(engine.requests, [
      ChatRequest(
        model: "override-model",
        messages: [
          ChatMessage(role: .system, content: "Be concise."),
          ChatMessage(role: .user, content: "hello"),
        ],
        sampling: ChatSampling(temperature: 0.2, topP: 0.8, maxTokens: 64)
      )
    ])
    XCTAssertEqual(chat.messages.count, 2)
    let assistant = try XCTUnwrap(chat.messages.first { $0.role == ChatMessage.Role.assistant.rawValue })
    XCTAssertEqual(assistant.content, "Hi there")
    XCTAssertEqual(assistant.meta.map { String(data: $0, encoding: .utf8) } ?? nil,
                   #"{"finish_reason":"stop"}"#)
    XCTAssertEqual(center.residentModelID, "override-model")
    XCTAssertNil(status.lastError)
  }

  func test_new_send_cancels_stale_stream_so_late_events_do_not_clobber_new_turn() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "first", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ManualChatEngine()
    let center = ModelLoadCenter()
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: center,
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1")
    )
    try await waitUntil("first request starts") { engine.requests.count == 1 && self.assistantMessages(in: chat).count == 1 }
    let firstAssistant = try XCTUnwrap(assistantMessages(in: chat).first)

    chat.messages.append(Message(role: "user", content: "second", ts: Date(timeIntervalSinceReferenceDate: 2)))
    try context.save()
    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: center,
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m2")
    )
    try await waitUntil("second request starts") { engine.requests.count == 2 && self.assistantMessages(in: chat).count == 1 }
    let secondAssistant = try XCTUnwrap(assistantMessages(in: chat).last)

    engine.yield(.delta(role: .assistant, content: "stale"), at: 0)
    engine.finish(at: 0)
    engine.yield(.delta(role: .assistant, content: "fresh"), at: 1)
    engine.yield(.finish(reason: .stop), at: 1)
    engine.finish(at: 1)

    try await waitUntil("second stream finishes") { !controller.isInFlight }

    XCTAssertFalse(
      chat.messages.contains { $0.id == firstAssistant.id },
      "blank preallocated assistant from the cancelled stale stream must be removed"
    )
    XCTAssertEqual(
      engine.requests[1].messages,
      [
        ChatMessage(role: .user, content: "first"),
        ChatMessage(role: .user, content: "second"),
      ],
      "the next request must not replay the cancelled blank assistant turn"
    )
    XCTAssertEqual(secondAssistant.content, "fresh")
    XCTAssertEqual(engine.terminationCount, 2)
  }

  func test_cancel_before_send_task_runs_does_not_insert_phantom_assistant_or_start_engine_request() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hello", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ManualChatEngine()
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1")
    )
    controller.cancel()

    await Task.yield()

    XCTAssertFalse(controller.isInFlight)
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertTrue(assistantMessages(in: chat).isEmpty)
  }

  func test_cancel_after_partial_flush_marks_cancelled_assistant_and_excludes_it_from_next_request() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "first", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ManualChatEngine()
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1")
    )
    try await waitUntil("first request starts") { engine.requests.count == 1 && self.assistantMessages(in: chat).count == 1 }
    let cancelledAssistant = try XCTUnwrap(assistantMessages(in: chat).first)

    engine.yield(.delta(role: .assistant, content: "partial"), at: 0)
    engine.yield(.modelReady, at: 0)
    try await waitUntil("partial assistant flushes") { cancelledAssistant.content == "partial" }

    controller.cancel()

    chat.messages.append(Message(role: "user", content: "second", ts: Date(timeIntervalSinceReferenceDate: 2)))
    try context.save()
    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m2")
    )
    try await waitUntil("second request starts") { engine.requests.count == 2 }

    XCTAssertEqual(cancelledAssistant.content, "partial")
    XCTAssertEqual(
      cancelledAssistant.meta.map { String(data: $0, encoding: .utf8) },
      #"{"finish_reason":"cancelled"}"#
    )
    XCTAssertEqual(
      engine.requests[1].messages,
      [
        ChatMessage(role: .user, content: "first"),
        ChatMessage(role: .user, content: "second"),
      ],
      "cancelled partial assistant output can remain visible but must not be replayed as prompt history"
    )

    controller.cancel()
  }

  func test_engineNotReady_failure_assistant_bubble_preserves_helper_detail() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hello", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let detail = "Helper unreachable: engineStatus timed out after 2.0s"
    let engine = FailingChatEngine(error: HTTPEngineError.engineNotReady(detail: detail))
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1")
    )

    try await waitUntil("engineNotReady assistant failure is persisted") {
      self.assistantMessages(in: chat).contains { $0.content.contains(detail) }
    }

    let assistant = try XCTUnwrap(assistantMessages(in: chat).first)
    XCTAssertTrue(
      assistant.content.contains(detail),
      "assistant failure bubble must preserve helper lifecycle diagnostic; got: \(assistant.content)"
    )
  }

  private func assistantMessages(in chat: Chat) -> [Message] {
    chat.messages
      .filter { $0.role == ChatMessage.Role.assistant.rawValue }
      .sorted { $0.ts < $1.ts }
  }

  // MARK: - speculation injection (#426 Fast Think)

  /// Drive `send` and return the single `ChatRequest` the engine saw.
  private func capturedRequest(
    speculation: Profile.Speculation?,
    sampling: ChatSampling = ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 100)
  ) async throws -> ChatRequest {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ImmediateChatEngine(events: [.delta(role: .assistant, content: "ok"), .finish(reason: .stop)])
    let controller = ChatSendController()
    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m", sampling: sampling, speculation: speculation)
    )
    try await waitUntil("stream finishes") { !controller.isInFlight }
    return try XCTUnwrap(engine.requests.first)
  }

  func test_send_enabledSpeculation_attaches_field_and_forces_greedy_temp() async throws {
    let req = try await capturedRequest(
      speculation: Profile.Speculation(enabled: true, leaderLen: 2, draftLen: 5))
    XCTAssertEqual(req.speculation, ChatSpeculation(enabled: true, leaderLen: 2, draftLen: 5))
    XCTAssertEqual(req.sampling.temperature, 0, "enabled speculation must force greedy decode")
    XCTAssertEqual(req.sampling.topP, 0.9, "other sampling knobs preserved")
    XCTAssertEqual(req.sampling.maxTokens, 100)
  }

  func test_send_nilSpeculation_no_field_and_temp_unchanged() async throws {
    let req = try await capturedRequest(speculation: nil)
    XCTAssertNil(req.speculation, "no profile speculation → byte-identical normal chat")
    XCTAssertEqual(req.sampling.temperature, 0.7, "temperature untouched without speculation")
  }

  func test_send_disabledSpeculation_no_field_and_temp_unchanged() async throws {
    let req = try await capturedRequest(speculation: Profile.Speculation(enabled: false))
    XCTAssertNil(req.speculation, "disabled speculation must not attach the field")
    XCTAssertEqual(req.sampling.temperature, 0.7)
  }

  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
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

private final class ImmediateChatEngine: EngineClient, @unchecked Sendable {
  private let events: [ChatEvent]
  private(set) var requests: [ChatRequest] = []

  init(events: [ChatEvent]) {
    self.events = events
  }

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func loadModel(_ id: String) -> AsyncThrowingStream<LoadEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    requests.append(req)
    let events = self.events
    return AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

private final class ManualChatEngine: EngineClient, @unchecked Sendable {
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  private(set) var requests: [ChatRequest] = []
  private(set) var terminationCount = 0

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func loadModel(_ id: String) -> AsyncThrowingStream<LoadEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
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

private final class FailingChatEngine: EngineClient, @unchecked Sendable {
  let error: Error

  init(error: Error) {
    self.error = error
  }

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func loadModel(_ id: String) -> AsyncThrowingStream<LoadEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let error = self.error
    return AsyncThrowingStream { continuation in
      continuation.finish(throwing: error)
    }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
