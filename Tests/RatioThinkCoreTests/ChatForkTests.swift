import XCTest
import SwiftData
@testable import RatioThinkCore

@available(macOS 14, *)
@MainActor
final class ChatForkTests: XCTestCase {
  /// Build a 4-row conversation: user "a" / assistant "A" / user "b" /
  /// assistant "B", with the assistant rows carrying reasoning + finish
  /// meta so the verbatim-copy assertions have something to check.
  private func makeChat(in context: ModelContext) -> (chat: Chat, editTarget: Message) {
    let chat = Chat(title: "Original", profileID: "chat")
    context.insert(chat)
    let u1 = Message(role: "user", content: "a", ts: Date(timeIntervalSinceReferenceDate: 1))
    let a1 = Message(
      role: "assistant", content: "A", reasoning: "thinking-A", tokens: 7,
      ts: Date(timeIntervalSinceReferenceDate: 2),
      meta: #"{"finish_reason":"stop"}"#.data(using: .utf8)
    )
    let u2 = Message(role: "user", content: "b", ts: Date(timeIntervalSinceReferenceDate: 3))
    let a2 = Message(
      role: "assistant", content: "B", reasoning: "thinking-B", tokens: 9,
      ts: Date(timeIntervalSinceReferenceDate: 4),
      meta: #"{"finish_reason":"stop"}"#.data(using: .utf8)
    )
    for m in [u1, a1, u2, a2] { context.insert(m); chat.messages.append(m) }
    return (chat, u2)
  }

  private func ordered(_ chat: Chat) -> [Message] {
    chat.messages.sorted { $0.ts < $1.ts }
  }

  func test_fork_copies_prefix_and_substitutes_edited_turn() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let (chat, target) = makeChat(in: context)
    try context.save()

    let status = PersistenceStatus()
    let newID = try XCTUnwrap(ChatFork.fork(
      chat: chat, at: target, newContent: "b-edited",
      in: context, persistenceStatus: status, contextLabel: "test"
    ))
    XCTAssertNil(status.lastError)

    let forked = try XCTUnwrap(try context.fetch(
      FetchDescriptor<Chat>(predicate: #Predicate { $0.id == newID })
    ).first)
    let rows = ordered(forked)

    // Prefix runs up to AND INCLUDING the edited user turn: u1, a1, u2.
    // The trailing assistant "B" (after the cut) is NOT carried over.
    XCTAssertEqual(rows.map(\.role), ["user", "assistant", "user"])
    XCTAssertEqual(rows.map(\.content), ["a", "A", "b-edited"])

    // The edited turn starts fresh: no stale reasoning / meta / tokens.
    let edited = rows[2]
    XCTAssertEqual(edited.reasoning, "")
    XCTAssertNil(edited.meta)
    XCTAssertEqual(edited.tokens, 0)

    // Fork inherits the source identity.
    XCTAssertEqual(forked.profileID, "chat")
    XCTAssertEqual(forked.title, "Original")
  }

  /// #522: the copied prefix BEFORE the edited turn must be byte-identical
  /// canonical text (role + content) so the engine's content-addressed KV
  /// snapshot reuses the cached pages; only the edited turn re-prefills.
  func test_fork_prefix_is_byte_identical_for_unchanged_rows() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let (chat, target) = makeChat(in: context)
    try context.save()

    let sourcePrefix = ordered(chat).prefix(2) // u1, a1 — rows before the edit
    let newID = try XCTUnwrap(ChatFork.fork(
      chat: chat, at: target, newContent: "b-edited",
      in: context, persistenceStatus: PersistenceStatus(), contextLabel: "test"
    ))
    let forked = try XCTUnwrap(try context.fetch(
      FetchDescriptor<Chat>(predicate: #Predicate { $0.id == newID })
    ).first)
    let copiedPrefix = ordered(forked).prefix(2)

    for (src, copy) in zip(sourcePrefix, copiedPrefix) {
      XCTAssertEqual(copy.role, src.role)
      XCTAssertEqual(copy.content, src.content) // canonical wire text
      XCTAssertEqual(copy.reasoning, src.reasoning)
      XCTAssertEqual(copy.meta, src.meta)
      // A copy, not the same row — the source must stay independent.
      XCTAssertNotEqual(copy.id, src.id)
    }
  }

  func test_fork_is_non_destructive_to_source_chat() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let (chat, target) = makeChat(in: context)
    try context.save()

    _ = ChatFork.fork(
      chat: chat, at: target, newContent: "b-edited",
      in: context, persistenceStatus: PersistenceStatus(), contextLabel: "test"
    )

    let rows = ordered(chat)
    XCTAssertEqual(rows.count, 4, "source chat must keep all four turns")
    XCTAssertEqual(rows.map(\.content), ["a", "A", "b", "B"])
    XCTAssertEqual(target.content, "b", "the edited source row must be untouched")
  }

  func test_fork_returns_nil_when_message_not_in_chat() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let (chat, _) = makeChat(in: context)
    let stranger = Message(role: "user", content: "elsewhere", ts: Date())
    context.insert(stranger)
    try context.save()

    let result = ChatFork.fork(
      chat: chat, at: stranger, newContent: "x",
      in: context, persistenceStatus: PersistenceStatus(), contextLabel: "test"
    )
    XCTAssertNil(result)
  }
}
