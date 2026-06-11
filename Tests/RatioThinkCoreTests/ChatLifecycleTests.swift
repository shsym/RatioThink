import XCTest
import SwiftData
@testable import RatioThinkCore

/// #512: the empty-vs-real chat boundary, the prune paths, and the
/// auto-title heuristic. All on the in-memory container flavor.
@available(macOS 14, *)
@MainActor
final class ChatLifecycleTests: XCTestCase {
  private func makeContext() throws -> ModelContext {
    ModelContext(try RatioThinkModelContainer.makeInMemory())
  }

  @discardableResult
  private func insertChat(
    _ context: ModelContext,
    title: String = Chat.defaultTitle,
    pinned: Bool = false
  ) throws -> Chat {
    let chat = Chat(title: title, pinned: pinned)
    context.insert(chat)
    try context.save()
    return chat
  }

  private func append(
    _ context: ModelContext, to chat: Chat,
    role: String, content: String = "", reasoning: String = "", tot: Data? = nil
  ) throws {
    let message = Message(role: role, content: content, reasoning: reasoning, tot: tot)
    context.insert(message)
    chat.messages.append(message)
    try context.save()
  }

  // MARK: - empty-vs-real boundary

  func test_fresh_default_chat_is_prunable() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    XCTAssertTrue(ChatLifecycle.isPrunableEmpty(chat))
  }

  func test_model_and_profile_metadata_alone_do_not_make_chat_real() throws {
    let context = try makeContext()
    let chat = Chat(profileID: "fast-think", modelID: "org/Repo/M-Q8.gguf")
    context.insert(chat)
    try context.save()
    XCTAssertTrue(ChatLifecycle.isPrunableEmpty(chat),
                  "profile/model metadata is not conversation")
  }

  func test_pinned_empty_chat_is_kept() throws {
    let context = try makeContext()
    let chat = try insertChat(context, pinned: true)
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat), "pinning is user intent")
  }

  func test_non_default_title_is_kept() throws {
    let context = try makeContext()
    let chat = try insertChat(context, title: "My research thread")
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat), "a title is user intent")
  }

  func test_user_message_makes_chat_real() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    try append(context, to: chat, role: "user", content: "hello")
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat))
  }

  func test_failed_send_chat_is_kept() throws {
    // A failed engine response after a user message must not be pruned:
    // user turn persisted + the ⚠️-marked assistant row.
    let context = try makeContext()
    let chat = try insertChat(context)
    try append(context, to: chat, role: "user", content: "hello")
    try append(context, to: chat, role: "assistant", content: "⚠️ Engine is not running.")
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat))
  }

  func test_reasoning_only_assistant_makes_chat_real() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    try append(context, to: chat, role: "assistant", reasoning: "pondering")
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat))
  }

  func test_tot_only_assistant_makes_chat_real() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    try append(context, to: chat, role: "assistant", tot: Data("{}".utf8))
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat))
  }

  func test_whitespace_only_content_is_not_real() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    try append(context, to: chat, role: "assistant", content: " \n\t ")
    XCTAssertTrue(ChatLifecycle.isPrunableEmpty(chat),
                  "an all-whitespace row carries no conversation")
  }

  // MARK: - manual rename (userTitled)

  /// The sentinel edge: renaming a chat to exactly the "New Chat"
  /// placeholder must NOT re-enter the prunable regime — `userTitled`
  /// is the authoritative manual-rename signal, not the title text.
  func test_userTitled_chat_named_exactly_default_is_kept() throws {
    let context = try makeContext()
    let chat = Chat(title: Chat.defaultTitle, userTitled: true)
    context.insert(chat)
    try context.save()
    XCTAssertFalse(ChatLifecycle.isPrunableEmpty(chat),
                   "a manual rename to the literal placeholder is still user intent")
  }

  func test_shouldAutoTitle_skips_userTitled_chat_even_with_default_text() throws {
    let context = try makeContext()
    let renamed = Chat(title: Chat.defaultTitle, userTitled: true)
    context.insert(renamed)
    try context.save()
    XCTAssertFalse(ChatLifecycle.shouldAutoTitle(renamed),
                   "manual rename wins permanently — auto-title must never overwrite it")
  }

  func test_shouldAutoTitle_applies_only_to_untouched_placeholder() throws {
    let context = try makeContext()
    let fresh = try insertChat(context)
    XCTAssertTrue(ChatLifecycle.shouldAutoTitle(fresh))
    fresh.title = "Derived title"
    XCTAssertFalse(ChatLifecycle.shouldAutoTitle(fresh),
                   "once titled (auto or otherwise), never re-titled")
  }

  // MARK: - pruneIfEmpty

  func test_pruneIfEmpty_deletes_empty_shell_and_cascades() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    ChatLifecycle.pruneIfEmpty(
      chatID: chat.id, in: context, persistenceStatus: PersistenceStatus())
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chat>()), 0)
  }

  func test_pruneIfEmpty_keeps_real_chat() throws {
    let context = try makeContext()
    let chat = try insertChat(context)
    try append(context, to: chat, role: "user", content: "keep me")
    ChatLifecycle.pruneIfEmpty(
      chatID: chat.id, in: context, persistenceStatus: PersistenceStatus())
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chat>()), 1)
  }

  func test_pruneIfEmpty_unknown_id_is_noop() throws {
    let context = try makeContext()
    try insertChat(context)
    ChatLifecycle.pruneIfEmpty(
      chatID: UUID(), in: context, persistenceStatus: PersistenceStatus())
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chat>()), 1)
  }

  // MARK: - pruneAllEmptyChats (launch reconcile)

  func test_pruneAllEmptyChats_removes_only_empty_shells() throws {
    let context = try makeContext()
    let real = try insertChat(context)
    try append(context, to: real, role: "user", content: "hi")
    let pinned = try insertChat(context, pinned: true)
    let titled = try insertChat(context, title: "Renamed")
    try insertChat(context)
    try insertChat(context)

    ChatLifecycle.pruneAllEmptyChats(in: context, persistenceStatus: PersistenceStatus())

    let remaining = try context.fetch(FetchDescriptor<Chat>())
    XCTAssertEqual(Set(remaining.map(\.id)), Set([real.id, pinned.id, titled.id]))
  }

  func test_pruneAllEmptyChats_excludes_selected_chat() throws {
    let context = try makeContext()
    let selected = try insertChat(context)
    try insertChat(context)

    ChatLifecycle.pruneAllEmptyChats(
      in: context, excluding: selected.id, persistenceStatus: PersistenceStatus())

    let remaining = try context.fetch(FetchDescriptor<Chat>())
    XCTAssertEqual(remaining.map(\.id), [selected.id],
                   "reconcile must never delete the chat the user is looking at")
  }

  // MARK: - fetch-failure reporting (review F1)

  private enum StubError: Error { case fetchFailed }

  func test_pruneIfEmpty_reports_fetch_failure_and_deletes_nothing() throws {
    let context = try makeContext()
    try insertChat(context)
    let status = PersistenceStatus()

    ChatLifecycle.pruneIfEmpty(in: context, persistenceStatus: status,
                               fetchChat: { throw StubError.fetchFailed })

    XCTAssertEqual(status.lastError?.context, "ChatLifecycle.pruneIfEmpty.fetch",
                   "a store fetch failure must be reported, never silently skipped")
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chat>()), 1,
                   "a failed fetch must not delete anything")
  }

  func test_pruneAllEmptyChats_reports_fetch_failure_and_deletes_nothing() throws {
    let context = try makeContext()
    try insertChat(context)
    let status = PersistenceStatus()

    ChatLifecycle.pruneAllEmptyChats(in: context, excluding: nil,
                                     persistenceStatus: status,
                                     fetchChats: { throw StubError.fetchFailed })

    XCTAssertEqual(status.lastError?.context, "ChatLifecycle.pruneAllEmptyChats.fetch",
                   "the launch reconcile must report a fetch failure, not no-op forever")
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chat>()), 1,
                   "a failed fetch must not delete anything")
  }

  // MARK: - ChatAutoTitle heuristic

  func test_autoTitle_trims_and_passes_short_text_through() {
    XCTAssertEqual(ChatAutoTitle.derive(from: "  Hello world  "), "Hello world")
  }

  func test_autoTitle_collapses_newlines_and_runs_of_whitespace() {
    XCTAssertEqual(
      ChatAutoTitle.derive(from: "first line\n\nsecond\t line"),
      "first line second line")
  }

  func test_autoTitle_caps_length_at_word_boundary_with_ellipsis() {
    let words = Array(repeating: "word", count: 30).joined(separator: " ")
    let title = try! XCTUnwrap(ChatAutoTitle.derive(from: words))
    XCTAssertLessThanOrEqual(title.count, ChatAutoTitle.maxLength + 1)
    XCTAssertTrue(title.hasSuffix("…"))
    XCTAssertFalse(title.dropLast().hasSuffix(" "), "cut lands on a word boundary")
    XCTAssertTrue(title.dropLast().split(separator: " ").allSatisfy { $0 == "word" },
                  "no half-words: \(title)")
  }

  func test_autoTitle_hard_cuts_single_enormous_token() {
    let token = String(repeating: "x", count: 200)
    let title = try! XCTUnwrap(ChatAutoTitle.derive(from: token))
    XCTAssertEqual(title.count, ChatAutoTitle.maxLength + 1)
    XCTAssertTrue(title.hasSuffix("…"))
  }

  func test_autoTitle_returns_nil_for_whitespace_only() {
    XCTAssertNil(ChatAutoTitle.derive(from: "   \n\t  "))
    XCTAssertNil(ChatAutoTitle.derive(from: ""))
  }
}
