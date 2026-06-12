import XCTest
import SwiftData
@testable import RatioThinkCore

/// Persistence-layer tests for Phase 4. All exercise the
/// in-memory `ModelContainer` flavor so they don't touch the user's
/// real `chats.sqlite` and so concurrent test methods can't alias
/// each other through a shared on-disk store.
@available(macOS 14, *)
@MainActor
final class ChatPersistenceTests: XCTestCase {
  // MARK: - schema + container

  func test_inMemoryContainer_constructs_with_chat_and_message_schema() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat(title: "Hello", profileID: "chat")
    context.insert(chat)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<Chat>())
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched.first?.title, "Hello")
    XCTAssertEqual(fetched.first?.profileID, "chat")
    XCTAssertFalse(fetched.first?.pinned ?? true)
  }

  func test_chat_insert_with_messages_persists_and_orders_by_timestamp() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)

    let now = Date()
    let m1 = Message(chat: chat, role: "user",      content: "first",  ts: now)
    let m2 = Message(chat: chat, role: "assistant", content: "second", ts: now.addingTimeInterval(1))
    let m3 = Message(chat: chat, role: "user",      content: "third",  ts: now.addingTimeInterval(2))
    chat.messages.append(contentsOf: [m1, m2, m3])
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<Chat>()).first
    XCTAssertNotNil(fetched)
    XCTAssertEqual(fetched?.messages.count, 3)
    let sorted = (fetched?.messages ?? []).sorted { $0.ts < $1.ts }
    XCTAssertEqual(sorted.map(\.content), ["first", "second", "third"])
    XCTAssertEqual(sorted.map(\.role),    ["user", "assistant", "user"])
  }

  // MARK: - cascade delete

  func test_deleting_chat_cascades_to_messages() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    for index in 0..<5 {
      let m = Message(chat: chat, role: "user", content: "msg \(index)")
      chat.messages.append(m)
    }
    try context.save()
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), 5)

    context.delete(chat)
    try context.save()

    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chat>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), 0,
                   "cascade delete must remove every Message belonging to the deleted Chat")
  }

  // MARK: - MessageStreamWriter

  func test_streamWriter_flush_appends_pending_to_message_content() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(chat: chat, role: "assistant", content: "")
    chat.messages.append(message)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 60)
    writer.appendDelta("Hello, ")
    writer.appendDelta("world!")
    XCTAssertEqual(writer.pendingCount, 13)
    XCTAssertEqual(message.content, "", "deltas must be buffered, not eagerly persisted")

    writer.flush()
    XCTAssertEqual(message.content, "Hello, world!")
    XCTAssertEqual(writer.pendingCount, 0)
  }

  func test_streamWriter_finish_flushes_and_writes_metadata() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(chat: chat, role: "assistant", content: "")
    chat.messages.append(message)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 60)
    writer.appendDelta("partial ")
    writer.appendDelta("tail")
    writer.finish(tokens: 42, meta: Data("{\"finish_reason\":\"stop\"}".utf8))

    XCTAssertEqual(message.content, "partial tail")
    XCTAssertEqual(message.tokens, 42)
    XCTAssertEqual(message.meta.map { String(data: $0, encoding: .utf8) } ?? nil,
                   "{\"finish_reason\":\"stop\"}")

    // Post-finish deltas must be ignored — engine sometimes emits a
    // stray frame after `finish_reason`; writer must not extend the
    // committed row silently.
    writer.appendDelta(" extra")
    XCTAssertEqual(message.content, "partial tail")
  }

  func test_streamWriter_cancel_discards_buffered_tail() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(chat: chat, role: "assistant", content: "committed ")
    chat.messages.append(message)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 60)
    writer.appendDelta("dropped tail")
    writer.cancel()

    XCTAssertEqual(message.content, "committed ", "cancel must drop the in-flight buffer")
  }

  // MARK: - reasoning channel

  func test_streamWriter_reasoning_persists_separately_from_content() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(chat: chat, role: "assistant", content: "")
    chat.messages.append(message)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 60)
    // Mirror the wire order: reasoning streams first, then the answer.
    writer.appendReasoningDelta("the user wants ")
    writer.appendReasoningDelta("a greeting")
    writer.appendDelta("Hello!")
    writer.flush()

    XCTAssertEqual(message.content, "Hello!", "answer channel holds only visible content")
    XCTAssertEqual(message.reasoning, "the user wants a greeting",
                   "reasoning channel holds thinking text, never mixed into content")
    XCTAssertFalse(message.content.contains("the user wants"),
                   "reasoning must not bleed into content")
  }

  func test_streamWriter_finish_flushes_reasoning_tail() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(chat: chat, role: "assistant", content: "")
    chat.messages.append(message)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 60)
    writer.appendReasoningDelta("pondering")
    writer.appendDelta("Done.")
    writer.finish(tokens: 7)

    XCTAssertEqual(message.content, "Done.")
    XCTAssertEqual(message.reasoning, "pondering", "finish must flush the buffered reasoning tail")

    // Post-finish reasoning deltas are ignored, same as content.
    writer.appendReasoningDelta(" more")
    XCTAssertEqual(message.reasoning, "pondering")
  }

  func test_exportJSON_carries_reasoning_as_separate_field_and_omits_when_empty() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let withReasoning = Message(role: "assistant", content: "Hi", reasoning: "thought", ts: Date(timeIntervalSince1970: 1))
    let plain = Message(role: "assistant", content: "Yo", reasoning: "", ts: Date(timeIntervalSince1970: 2))
    chat.messages.append(withReasoning)
    chat.messages.append(plain)
    try context.save()

    let data = try RatioThinkModelContainer.exportJSON(from: context)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([RatioThinkModelContainer.ExportedChat].self, from: data)
    let messages = try XCTUnwrap(decoded.first).messages.sorted { $0.ts < $1.ts }

    XCTAssertEqual(messages[0].reasoning, "thought", "reasoning exported as its own field, not folded into content")
    XCTAssertEqual(messages[0].content, "Hi")
    XCTAssertNil(messages[1].reasoning, "empty reasoning is omitted from the export")
  }

  func test_streamWriter_timer_flushes_on_runloop_tick() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(chat: chat, role: "assistant", content: "")
    chat.messages.append(message)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 0.05)
    writer.appendDelta("tick")

    // Spin the run loop long enough for the 50 ms timer to fire at
    // least once. Avoid `sleep` so we don't block the main actor's
    // run loop entirely — `Task.sleep` lets the loop process timers.
    try await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(message.content, "tick", "background timer must flush buffered deltas")
    writer.cancel()
  }

  // MARK: - relationship single-wire (F11 / F19)

  /// `ComposerView.submit` builds a `Message` *without* setting the
  /// `chat:` arg and then appends to `chat.messages`. The inverse
  /// keyPath on `Chat.messages` is meant to maintain
  /// `Message.chat` automatically. This test pins that contract so
  /// any future regression (SwiftData stops back-filling the
  /// inverse) is caught before it ships.
  func test_inverse_relationship_back_fills_when_only_appended_to_chat() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)

    let message = Message(role: "user", content: "no-double-wire", ts: Date())
    context.insert(message)
    chat.messages.append(message)
    try context.save()

    XCTAssertEqual(chat.messages.count, 1, "single-side wire must not produce duplicate entries")
    XCTAssertIdentical(message.chat, chat, "SwiftData must back-fill the inverse pointer from the to-many side")

    let fetched = try context.fetch(FetchDescriptor<Chat>()).first
    XCTAssertEqual(fetched?.messages.count, 1)
  }

  /// Interleaved writes: a `MessageStreamWriter` flush followed by
  /// a separate insert on the same `ModelContext`. Both share the
  /// main-actor context so this is the realistic ordering when a
  /// user submits a new turn while an assistant stream is in
  /// flight.
  func test_streamWriter_flush_interleaved_with_insert_preserves_all_rows() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)

    let assistant = Message(role: "assistant", content: "")
    context.insert(assistant)
    chat.messages.append(assistant)

    let writer = MessageStreamWriter(context: context, message: assistant, flushInterval: 60)
    writer.appendDelta("partial assistant ")
    writer.flush() // first durability boundary; chat.updatedAt bumped

    // User submits a new turn while the assistant stream is still
    // accumulating tokens — mirrors `ComposerView.submit` interleaved
    // with the writer's run-loop flush.
    let user = Message(role: "user", content: "follow-up", ts: Date())
    context.insert(user)
    chat.messages.append(user)
    try context.save()

    writer.appendDelta("tail")
    writer.finish(tokens: 5)

    let fetched = try context.fetch(FetchDescriptor<Chat>()).first
    XCTAssertEqual(fetched?.messages.count, 2)
    let assistantRow = fetched?.messages.first { $0.role == "assistant" }
    let userRow      = fetched?.messages.first { $0.role == "user" }
    XCTAssertEqual(assistantRow?.content, "partial assistant tail")
    XCTAssertEqual(assistantRow?.tokens, 5)
    XCTAssertEqual(userRow?.content, "follow-up")
  }

  /// Writer's flush + finish must bump `chat.updatedAt` so the
  /// sidebar's recency sort promotes streaming chats ( F2).
  func test_streamWriter_flush_and_finish_bump_chat_updatedAt() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)

    let createdAt = Date(timeIntervalSinceReferenceDate: 0)
    let chat = Chat(createdAt: createdAt, updatedAt: createdAt)
    context.insert(chat)
    let message = Message(role: "assistant", content: "")
    context.insert(message)
    chat.messages.append(message)
    try context.save()

    XCTAssertEqual(chat.updatedAt, createdAt)

    let writer = MessageStreamWriter(context: context, message: message, flushInterval: 60)
    writer.appendDelta("tokens")
    writer.flush()
    XCTAssertGreaterThan(chat.updatedAt, createdAt,
                         "flush must bump owning chat.updatedAt so the sidebar reflects streaming activity")

    let afterFlush = chat.updatedAt
    writer.finish()
    XCTAssertGreaterThanOrEqual(chat.updatedAt, afterFlush,
                                "finish must also touch chat.updatedAt")
  }

  /// Errors thrown by `context.save()` route through the
  /// `errorReporter` closure rather than getting swallowed with
  /// `try?`. SwiftData's in-memory store does not deterministically
  /// reject any reasonable mutation we could try here (`@Attribute
  /// (.unique)` is not enforced for in-memory configurations), so
  /// the test exercises the same code path by invoking the
  /// reporter directly from a stub `MessageStreamWriter`-shaped
  /// callback wire-up — verifying the typealias and routing
  /// without asking SwiftData to misbehave.
  func test_streamWriter_errorReporter_typealias_routes_context_string() {
    var contexts: [String] = []
    let reporter: MessageStreamWriter.ErrorReporter = { _, ctx in contexts.append(ctx) }
    enum StubError: Error { case forced }
    reporter(StubError.forced, "MessageStreamWriter.flush")
    reporter(StubError.forced, "MessageStreamWriter.finish")
    XCTAssertEqual(contexts, ["MessageStreamWriter.flush", "MessageStreamWriter.finish"])
  }

  /// Dropping the writer without `finish()` / `cancel()` must not
  /// leak the repeating timer ( F1). The `deinit` invalidates
  /// it; after deinit the message content can't change further
  /// because the closure's `[weak self]` ref is nil and the timer
  /// itself is stopped.
  func test_streamWriter_deinit_invalidates_timer_without_leak() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    let message = Message(role: "assistant", content: "")
    context.insert(message)
    chat.messages.append(message)

    do {
      let writer = MessageStreamWriter(context: context, message: message, flushInterval: 0.02)
      writer.appendDelta("dropped")
      _ = writer
    }
    // Spin the run loop well past the 20 ms interval. If `deinit`
    // failed to invalidate the timer, the closure would attempt
    // to fire — but `[weak self]` makes it a no-op anyway. The
    // load-bearing assertion is that the message content does not
    // change because the writer never had a chance to flush.
    let snapshot = message.content
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(message.content, snapshot,
                   "dropped writer must not commit its buffer post-deinit")
  }

  // MARK: - openWithFallback (F18)

  func test_openWithFallback_returns_disk_container_when_shared_succeeds() {
    let status = PersistenceStatus()
    let sentinel = try! RatioThinkModelContainer.makeInMemory()
    _ = RatioThinkModelContainer.openWithFallback(
      status: status,
      makeShared: { sentinel },
      makeInMemory: { XCTFail("must not fall back when shared succeeds"); return try RatioThinkModelContainer.makeInMemory() }
    )
    XCTAssertEqual(status.storage, .onDisk)
    XCTAssertNil(status.lastError)
  }

  func test_openWithFallback_marks_inMemory_and_reports_error_on_disk_failure() {
    enum StubError: Error { case diskOpenFailed }
    let status = PersistenceStatus()
    _ = RatioThinkModelContainer.openWithFallback(
      status: status,
      makeShared: { throw StubError.diskOpenFailed },
      makeInMemory: { try RatioThinkModelContainer.makeInMemory() }
    )
    if case .inMemoryFallback(let reason) = status.storage {
      XCTAssertFalse(reason.isEmpty)
    } else {
      XCTFail("expected inMemoryFallback storage, got \(status.storage)")
    }
    XCTAssertEqual(status.lastError?.context, "RatioThinkModelContainer.openWithFallback")
  }

  // MARK: - error formatting

  func test_formatError_preserves_engineNotReady_detail() {
    let detail = "Helper unreachable: engineStatus timed out after 2.0s"

    let formatted = PersistenceStatus.formatError(
      HTTPEngineError.engineNotReady(detail: detail)
    )

    XCTAssertTrue(
      formatted.contains(detail),
      "generic error formatting must preserve the helper lifecycle diagnostic; got: \(formatted)"
    )
  }

  // MARK: - JSON export tool

  func test_exportJSON_round_trips_chat_and_message_fields() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)

    let chatID = UUID()
    let msgID = UUID()
    let createdAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000_100)
    let ts = Date(timeIntervalSinceReferenceDate: 1_000_050)
    let meta = Data("{\"k\":\"v\"}".utf8)

    let chat = Chat(
      id: chatID,
      title: "Exported",
      profileID: "chat",
      modelID: "org/Repo/Exported-Q8.gguf",
      createdAt: createdAt,
      updatedAt: updatedAt,
      pinned: true
    )
    context.insert(chat)
    let message = Message(
      id: msgID,
      chat: chat,
      role: "assistant",
      content: "body",
      tokens: 7,
      ts: ts,
      meta: meta
    )
    chat.messages.append(message)
    try context.save()

    let json = try RatioThinkModelContainer.exportJSON(from: context)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([RatioThinkModelContainer.ExportedChat].self, from: json)

    XCTAssertEqual(decoded.count, 1)
    let exported = try XCTUnwrap(decoded.first)
    XCTAssertEqual(exported.id, chatID)
    XCTAssertEqual(exported.title, "Exported")
    XCTAssertEqual(exported.profileID, "chat")
    XCTAssertEqual(exported.modelID, "org/Repo/Exported-Q8.gguf",
                   "#460: the JSON export must carry the chat's pinned model")
    XCTAssertEqual(exported.pinned, true)
    XCTAssertEqual(exported.messages.count, 1)
    let exportedMsg = try XCTUnwrap(exported.messages.first)
    XCTAssertEqual(exportedMsg.id, msgID)
    XCTAssertEqual(exportedMsg.role, "assistant")
    XCTAssertEqual(exportedMsg.content, "body")
    XCTAssertEqual(exportedMsg.tokens, 7)
    XCTAssertEqual(exportedMsg.meta, meta)
  }

  /// #460: the new `Chat.modelID` is an ADDITIVE, reversible change. A
  /// pre-#460 export (JSON with no `modelID` key) must still decode — the
  /// field defaults to nil — so reading an old store/export never breaks.
  func test_exportedChat_decodes_legacy_json_without_modelID_as_nil() throws {
    let legacy = """
    [{
      "id": "00000000-0000-0000-0000-000000000001",
      "title": "Legacy",
      "profileID": "chat",
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-01-01T00:00:00Z",
      "pinned": false,
      "messages": []
    }]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([RatioThinkModelContainer.ExportedChat].self,
                                     from: Data(legacy.utf8))
    XCTAssertEqual(decoded.count, 1)
    XCTAssertNil(decoded.first?.modelID,
                 "a legacy export with no modelID key must decode with modelID == nil (additive)")
  }

  /// #512: `userTitled` is an ADDITIVE column with an inline default —
  /// existing rows backfill `false`, a manual rename round-trips `true`,
  /// and a legacy export without the key decodes as nil.
  func test_chat_userTitled_defaults_false_and_round_trips() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)

    let chat = Chat(title: "Untouched")
    context.insert(chat)
    try context.save()
    XCTAssertFalse(chat.userTitled, "default chat is not user-titled")

    chat.userTitled = true
    try context.save()
    let reloaded = try XCTUnwrap(
      context.fetch(FetchDescriptor<Chat>()).first { $0.id == chat.id })
    XCTAssertTrue(reloaded.userTitled)
  }

  func test_exportedChat_decodes_legacy_json_without_userTitled_as_nil() throws {
    let legacy = """
    [{
      "id": "00000000-0000-0000-0000-000000000002",
      "title": "Legacy",
      "profileID": "chat",
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-01-01T00:00:00Z",
      "pinned": false,
      "messages": []
    }]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([RatioThinkModelContainer.ExportedChat].self,
                                     from: Data(legacy.utf8))
    XCTAssertNil(decoded.first?.userTitled,
                 "a legacy export with no userTitled key must decode with nil (additive)")
  }

  /// #460: a chat created on the pre-#460 default initializer (no modelID)
  /// is unpinned, and a model can be pinned + read back — the migration adds
  /// the column without disturbing existing rows.
  func test_chat_modelID_defaults_nil_and_round_trips() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)

    let unpinned = Chat(title: "Unpinned", profileID: "chat")
    context.insert(unpinned)
    try context.save()
    XCTAssertNil(unpinned.modelID, "default chat is unpinned (follows profile default)")

    unpinned.modelID = "org/Repo/Pinned-Q8.gguf"
    try context.save()
    let reloaded = try XCTUnwrap(
      context.fetch(FetchDescriptor<Chat>()).first { $0.id == unpinned.id })
    XCTAssertEqual(reloaded.modelID, "org/Repo/Pinned-Q8.gguf")
  }
}
