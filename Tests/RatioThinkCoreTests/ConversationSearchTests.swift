import XCTest
import SwiftData
@testable import RatioThinkCore

/// Unit tests for the naive title + body conversation search. All exercise
/// the in-memory `ModelContainer` so they never touch the real store.
@available(macOS 14, *)
@MainActor
final class ConversationSearchTests: XCTestCase {
  private func makeContext() throws -> ModelContext {
    ModelContext(try RatioThinkModelContainer.makeInMemory())
  }

  private func makeChat(
    in context: ModelContext,
    title: String,
    bodies: [String] = []
  ) -> Chat {
    let chat = Chat(title: title)
    context.insert(chat)
    for body in bodies {
      chat.messages.append(Message(chat: chat, role: "user", content: body))
    }
    return chat
  }

  func test_empty_query_returns_no_results() throws {
    let context = try makeContext()
    _ = makeChat(in: context, title: "Anything")
    try context.save()

    XCTAssertTrue(ConversationSearch.results(in: [], query: "x").isEmpty)
    let chats = try context.fetch(FetchDescriptor<Chat>())
    XCTAssertTrue(ConversationSearch.results(in: chats, query: "").isEmpty)
    XCTAssertTrue(ConversationSearch.results(in: chats, query: "   ").isEmpty)
  }

  func test_title_match_is_case_insensitive_and_carries_no_snippet() throws {
    let context = try makeContext()
    let chat = makeChat(in: context, title: "Rust Borrow Checker")
    try context.save()

    let results = ConversationSearch.results(in: [chat], query: "borrow")
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.id, chat.id)
    XCTAssertEqual(results.first?.title, "Rust Borrow Checker")
    XCTAssertNil(results.first?.snippet, "title-only match should not carry a body snippet")
  }

  func test_body_match_returns_snippet() throws {
    let context = try makeContext()
    let chat = makeChat(
      in: context,
      title: "Untitled",
      bodies: ["The quick brown fox jumps over the lazy dog"]
    )
    try context.save()

    let results = ConversationSearch.results(in: [chat], query: "brown fox")
    XCTAssertEqual(results.count, 1)
    XCTAssertNotNil(results.first?.snippet)
    XCTAssertTrue(results.first?.snippet?.localizedCaseInsensitiveContains("brown fox") ?? false)
  }

  func test_no_match_excludes_chat() throws {
    let context = try makeContext()
    let chat = makeChat(in: context, title: "Alpha", bodies: ["beta gamma"])
    try context.save()

    XCTAssertTrue(ConversationSearch.results(in: [chat], query: "omega").isEmpty)
  }

  func test_preserves_input_order() throws {
    let context = try makeContext()
    let first = makeChat(in: context, title: "match one")
    let second = makeChat(in: context, title: "match two")
    let third = makeChat(in: context, title: "match three")
    try context.save()

    let results = ConversationSearch.results(in: [first, second, third], query: "match")
    XCTAssertEqual(results.map(\.id), [first.id, second.id, third.id])
  }

  func test_excerpt_ellipsizes_a_long_body_around_the_match() {
    let body = String(repeating: "a", count: 80) + "NEEDLE" + String(repeating: "b", count: 80)
    let excerpt = ConversationSearch.excerpt(body, around: "needle", radius: 10)
    XCTAssertTrue(excerpt.hasPrefix("…"), "leading truncation should be marked")
    XCTAssertTrue(excerpt.hasSuffix("…"), "trailing truncation should be marked")
    XCTAssertTrue(excerpt.localizedCaseInsensitiveContains("NEEDLE"))
    XCTAssertLessThan(excerpt.count, body.count)
  }
}
