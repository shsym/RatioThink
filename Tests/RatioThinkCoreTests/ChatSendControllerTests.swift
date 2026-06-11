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
        sampling: ChatSampling(temperature: 0.2, topP: 0.8, maxTokens: 64),
        // #522: every send carries a per-chat prefix-cache directive
        // (system override + 1 user message → boundary turn 2).
        cache: ChatCacheDirective(key: chat.id.uuidString, turn: 2)
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

  /// #474: the outgoing request's `max_tokens` is clamped DOWN to the
  /// launched engine ceiling carried on `ChatSendRequestOptions`. End-to-end
  /// through `send` so the options → `makeRequest` → wire path is exercised,
  /// not just the pure helper. A memory-squeezed launch (ceiling 512) must
  /// turn a profile value of 2048 into a 512 request — the difference between
  /// a working (shorter) reply and chat-apc's clean 400.
  func test_send_clamps_max_tokens_to_engine_ceiling() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ImmediateChatEngine(events: [
      .modelReady,
      .delta(role: .assistant, content: "ok"),
      .finish(reason: .stop),
    ])
    let controller = ChatSendController()
    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(
        modelID: "m1",
        sampling: ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 2048),
        maxOutputTokensCeiling: 512
      )
    )

    try await waitUntil("stream finishes") { !controller.isInFlight }

    XCTAssertEqual(engine.requests.count, 1)
    XCTAssertEqual(engine.requests.first?.sampling.maxTokens, 512)
    // The other sampling knobs ride through untouched.
    XCTAssertEqual(engine.requests.first?.sampling.temperature, 0.7)
    XCTAssertEqual(engine.requests.first?.sampling.topP, 0.9)
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

  func test_engineNotReady_failure_assistant_bubble_is_normalized_actionable_line() async throws {
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
      self.assistantMessages(in: chat).contains { $0.content.hasPrefix("⚠️") }
    }

    // #477: the bubble shows the normalized taxonomy line; the raw helper
    // lifecycle diagnostic stays in logs / technicalDetail, never the bubble.
    let assistant = try XCTUnwrap(assistantMessages(in: chat).first)
    XCTAssertTrue(
      assistant.content.contains("isn’t ready yet"),
      "assistant failure bubble must be the normalized not-ready line; got: \(assistant.content)"
    )
    XCTAssertFalse(
      assistant.content.contains(detail),
      "raw lifecycle diagnostic must not leak into the bubble; got: \(assistant.content)"
    )
  }

  // MARK: - #2 model-not-found copy
  // (The copy itself is owned by `EngineProblem` — exact-line assertions
  // live in EngineProblemTests; the bubble wiring is covered by the
  // failure-path tests above.)

  func test_isModelNotFound_only_matches_that_code() {
    XCTAssertTrue(HTTPEngineError.api(status: 404, code: "model_not_found", message: "").isModelNotFound)
    XCTAssertTrue(HTTPEngineError.stream(code: "model_not_found", message: "").isModelNotFound)
    XCTAssertFalse(HTTPEngineError.api(status: 500, code: "internal", message: "").isModelNotFound)
    XCTAssertFalse(HTTPEngineError.engineGone(detail: "").isModelNotFound)
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

  // #522: every send carries an auto prefix-cache directive keyed on the
  // chat id, so the inferlet can content-address and reuse the per-chat KV.
  func test_send_attaches_prefix_cache_directive_keyed_on_chat() async throws {
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
      options: ChatSendRequestOptions(modelID: "m", sampling: ChatSampling())
    )
    try await waitUntil("stream finishes") { !controller.isInFlight }

    let req = try XCTUnwrap(engine.requests.first)
    let cache = try XCTUnwrap(req.cache, "every send must carry a cache directive")
    XCTAssertEqual(cache.key, chat.id.uuidString, "thread key is the chat id")
    XCTAssertEqual(cache.policy, "auto", "default policy engages reuse")
    XCTAssertEqual(cache.compat, ChatCacheDirective.compatVersion)
    XCTAssertEqual(cache.turn, 1, "one user message → boundary turn 1")
  }

  func test_send_disabledSpeculation_no_field_and_temp_unchanged() async throws {
    let req = try await capturedRequest(speculation: Profile.Speculation(enabled: false))
    XCTAssertNil(req.speculation, "disabled speculation must not attach the field")
    XCTAssertEqual(req.sampling.temperature, 0.7)
  }

  /// End-to-end golden tie: the seeded built-in "Fast Think" profile must
  /// produce exactly the inferlet-facing body that engages the #418
  /// drafter — `speculation.enabled == true` AND a greedy top-level
  /// `temperature == 0`. Drives the real request builder with the seeded
  /// TOML's speculation and a NON-greedy toolbar sampling (0.7) to prove
  /// the chokepoint forces greedy regardless. (#426)
  func test_seeded_fast_think_profile_yields_drafting_body() async throws {
    let profile = try Profile.parse(toml: ProfileStore.defaultFastThinkTOML)
    XCTAssertEqual(profile.speculation, Profile.Speculation(enabled: true),
                   "seeded Fast Think profile must enable speculation")

    let req = try await capturedRequest(
      speculation: profile.speculation,
      sampling: ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 100))

    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(req)) as? [String: Any])
    let spec = try XCTUnwrap(body["speculation"] as? [String: Any])
    XCTAssertEqual(spec["enabled"] as? Bool, true)
    XCTAssertEqual(body["temperature"] as? Double, 0,
                   "Fast Think body must be greedy (temp 0) so the drafter engages")
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
