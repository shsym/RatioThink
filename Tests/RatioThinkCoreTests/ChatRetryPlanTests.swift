import XCTest
import SwiftData
@testable import RatioThinkCore

/// #513 — retry-from-a-prior-turn semantics. The pure `plan` decides what a
/// retry would delete and whether it needs the destructive confirmation; the
/// `execute` + `ChatSendController.send` pairing proves the persisted
/// truncation is atomic and the resent request carries ONLY the retained
/// prefix (later turns and the stale assistant never reach the engine).
@available(macOS 14, *)
@MainActor
final class ChatRetryPlanTests: XCTestCase {
  // MARK: - plan

  func test_plan_latest_turn_deletes_only_stale_assistant_without_confirmation() throws {
    let (chat, _) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
    ])
    let assistant = try message(chat, content: "a1")

    let plan = try XCTUnwrap(ChatRetryPlan.plan(messages: chat.messages, retryPointID: assistant.id))

    XCTAssertEqual(plan.deleteMessageIDs, [assistant.id],
                   "latest-turn retry deletes the stale assistant itself — that is what prevents duplicate assistant turns")
    XCTAssertFalse(plan.requiresConfirmation,
                   "no later conversation exists, so no destructive confirmation")
  }

  func test_plan_earlier_turn_deletes_suffix_and_requires_confirmation() throws {
    let (chat, _) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
      ("user", "q2", 3), ("assistant", "a2", 4),
    ])
    let a1 = try message(chat, content: "a1")
    let q2 = try message(chat, content: "q2")
    let a2 = try message(chat, content: "a2")

    let plan = try XCTUnwrap(ChatRetryPlan.plan(messages: chat.messages, retryPointID: a1.id))

    XCTAssertEqual(plan.deleteMessageIDs, [a1.id, q2.id, a2.id],
                   "retry from an earlier assistant erases that turn plus everything after, in transcript order")
    XCTAssertTrue(plan.requiresConfirmation,
                  "later conversation exists — the UI must confirm the erase")
  }

  func test_plan_rejects_user_rows_unknown_ids_and_assistant_without_preceding_user() throws {
    let (chat, _) = try makeChat(turns: [
      ("assistant", "orphan", 1),
      ("user", "q1", 2), ("assistant", "a1", 3),
    ])
    let user = try message(chat, content: "q1")
    let orphan = try message(chat, content: "orphan")

    XCTAssertNil(ChatRetryPlan.plan(messages: chat.messages, retryPointID: user.id),
                 "retry anchors on assistant turns only")
    XCTAssertNil(ChatRetryPlan.plan(messages: chat.messages, retryPointID: UUID()),
                 "unknown retry point is invalid")
    XCTAssertNil(ChatRetryPlan.plan(messages: chat.messages, retryPointID: orphan.id),
                 "an assistant with no preceding user turn has no retained prefix to resend")
  }

  func test_plan_breaks_timestamp_ties_with_the_shared_id_order() throws {
    // Two assistants share one timestamp. The transcript comparator breaks
    // the tie by id — the plan must treat the id-later row as "after" the
    // retry point, exactly as `makeRequest` and `TranscriptView` order it.
    let ts = Date(timeIntervalSinceReferenceDate: 5)
    let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let highID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "q", ts: Date(timeIntervalSinceReferenceDate: 1)))
    chat.messages.append(Message(id: lowID, role: "assistant", content: "first", ts: ts))
    chat.messages.append(Message(id: highID, role: "assistant", content: "second", ts: ts))
    try context.save()

    let plan = try XCTUnwrap(ChatRetryPlan.plan(messages: chat.messages, retryPointID: lowID))
    XCTAssertEqual(plan.deleteMessageIDs, [lowID, highID])
    XCTAssertTrue(plan.requiresConfirmation)

    let tailPlan = try XCTUnwrap(ChatRetryPlan.plan(messages: chat.messages, retryPointID: highID))
    XCTAssertEqual(tailPlan.deleteMessageIDs, [highID])
    XCTAssertFalse(tailPlan.requiresConfirmation)
  }

  // MARK: - execute + resend

  func test_execute_then_send_rebuilds_context_from_retained_prefix_only() async throws {
    let (chat, context) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
      ("user", "q2", 3), ("assistant", "a2", 4),
    ])
    let a1 = try message(chat, content: "a1")
    let q1 = try message(chat, content: "q1")
    let q1TS = q1.ts

    let plan = try XCTUnwrap(ChatRetryPlan.plan(messages: chat.messages, retryPointID: a1.id))
    let status = PersistenceStatus()
    XCTAssertTrue(ChatRetryPlan.execute(plan, chat: chat, context: context, persistenceStatus: status))

    // Truncation is atomic and complete: only the retained prefix survives.
    XCTAssertEqual(chat.messages.map(\.content), ["q1"],
                   "later messages (q2, a2) and the stale a1 are gone; the manual user message is preserved")
    XCTAssertEqual(q1.ts, q1TS, "retained user message rides through unchanged")
    XCTAssertNil(status.lastError)

    // Resend from the retained prefix — the engine sees q1 only; the
    // erased turns can never re-enter context (so no later KV is reused).
    let engine = ImmediateRetryEngine(events: [
      .delta(role: .assistant, content: "fresh"),
      .finish(reason: .stop),
    ])
    let controller = ChatSendController()
    controller.send(
      chat: chat, context: context, engine: engine,
      modelLoadCenter: ModelLoadCenter(), persistenceStatus: status,
      options: ChatSendRequestOptions(modelID: "m1")
    )
    try await waitUntil("retry stream finishes") { !controller.isInFlight }

    XCTAssertEqual(engine.requests.count, 1)
    XCTAssertEqual(engine.requests.first?.messages,
                   [ChatMessage(role: .user, content: "q1")],
                   "request context is rebuilt from the retained prefix only")
    // No duplicate user rows; exactly one fresh assistant turn.
    XCTAssertEqual(chat.messages.filter { $0.role == "user" }.map(\.content), ["q1"])
    let assistants = chat.messages.filter { $0.role == "assistant" }
    XCTAssertEqual(assistants.map(\.content), ["fresh"],
                   "retry accumulates no duplicate/stale assistant turns")
  }

  func test_execute_failed_retry_records_removed_with_rest_of_suffix() async throws {
    // A cancelled assistant after the retry point is part of "later
    // history" — it goes with the rest of the suffix.
    let (chat, context) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
      ("user", "q2", 3),
    ])
    let cancelled = Message(role: "assistant", content: "partial",
                            ts: Date(timeIntervalSinceReferenceDate: 4),
                            meta: #"{"finish_reason":"cancelled"}"#.data(using: .utf8))
    chat.messages.append(cancelled)
    try context.save()

    let a1 = try message(chat, content: "a1")
    let plan = try XCTUnwrap(ChatRetryPlan.plan(messages: chat.messages, retryPointID: a1.id))
    XCTAssertTrue(ChatRetryPlan.execute(plan, chat: chat, context: context,
                                        persistenceStatus: PersistenceStatus()))
    XCTAssertEqual(chat.messages.map(\.content), ["q1"])
  }

  // MARK: - apply (review v1 F1: no silent no-op after a confirmed retry)

  func test_apply_returns_noLongerApplies_without_deleting_when_transcript_changed_under_confirm() throws {
    let (chat, context) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
      ("user", "q2", 3), ("assistant", "a2", 4),
    ])
    let a1 = try message(chat, content: "a1")
    // Confirm was presented for a1, then the transcript changed underneath:
    // the retry point itself is gone (e.g. another window already retried).
    chat.messages.removeAll { $0.id == a1.id }
    context.delete(a1)
    try context.save()
    let before = chat.messages.map(\.content).sorted()

    let outcome = ChatRetryPlan.apply(
      retryPointID: a1.id, chat: chat, isInFlight: false,
      context: context, persistenceStatus: PersistenceStatus()
    )

    XCTAssertEqual(outcome, .noLongerApplies,
                   "a confirmed retry that no longer applies must be reported, never a silent return")
    XCTAssertEqual(chat.messages.map(\.content).sorted(), before,
                   "nothing may be deleted on the stale-confirm path")
  }

  func test_apply_returns_noLongerApplies_when_a_stream_is_in_flight() throws {
    let (chat, context) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
    ])
    let a1 = try message(chat, content: "a1")

    let outcome = ChatRetryPlan.apply(
      retryPointID: a1.id, chat: chat, isInFlight: true,
      context: context, persistenceStatus: PersistenceStatus()
    )

    XCTAssertEqual(outcome, .noLongerApplies)
    XCTAssertEqual(chat.messages.count, 2, "an in-flight chat must not be truncated")
  }

  func test_apply_valid_point_truncates_and_returns_send() throws {
    let (chat, context) = try makeChat(turns: [
      ("user", "q1", 1), ("assistant", "a1", 2),
    ])
    let a1 = try message(chat, content: "a1")

    let outcome = ChatRetryPlan.apply(
      retryPointID: a1.id, chat: chat, isInFlight: false,
      context: context, persistenceStatus: PersistenceStatus()
    )

    XCTAssertEqual(outcome, .send)
    XCTAssertEqual(chat.messages.map(\.content), ["q1"])
  }

  // MARK: - render-path validity (review v1 F2)

  func test_validRetryPointIDs_matches_plan_validity_row_for_row() throws {
    // Parity pin: the one-pass render-path set and the click-path `plan`
    // must agree on every row, including the orphan-assistant edge.
    let (chat, _) = try makeChat(turns: [
      ("assistant", "orphan", 1),
      ("user", "q1", 2), ("assistant", "a1", 3),
      ("system", "meta", 4),
      ("user", "q2", 5), ("assistant", "a2", 6),
    ])
    let sorted = chat.messages.sorted(by: Message.transcriptPrecedes)

    let rendered = ChatRetryPlan.validRetryPointIDs(sortedMessages: sorted)
    let planned = Set(sorted.map(\.id).filter {
      ChatRetryPlan.plan(messages: chat.messages, retryPointID: $0) != nil
    })

    XCTAssertEqual(rendered, planned)
    XCTAssertEqual(rendered, Set([try message(chat, content: "a1").id,
                                  try message(chat, content: "a2").id]))
  }

  // MARK: - helpers

  private func makeChat(turns: [(role: String, content: String, ts: Double)]) throws -> (Chat, ModelContext) {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    for turn in turns {
      chat.messages.append(Message(role: turn.role, content: turn.content,
                                   ts: Date(timeIntervalSinceReferenceDate: turn.ts)))
    }
    try context.save()
    return (chat, context)
  }

  private func message(_ chat: Chat, content: String) throws -> Message {
    try XCTUnwrap(chat.messages.first { $0.content == content })
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

/// Local copy of the immediate-stream engine (the sibling in
/// `ChatSendControllerTests` is file-private).
private final class ImmediateRetryEngine: EngineClient, @unchecked Sendable {
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
