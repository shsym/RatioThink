import XCTest
@testable import RatioThinkCore

@available(macOS 14, *)
@MainActor
final class ChatListPresentationTests: XCTestCase {
  func test_filtering_matches_visible_title_and_preserves_pinned_first_recent_order() {
    let oldPinned = Chat(
      title: "Project Alpha kickoff",
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 10),
      pinned: true
    )
    let recentUnpinned = Chat(
      title: "Alpha launch follow-up",
      createdAt: Date(timeIntervalSince1970: 20),
      updatedAt: Date(timeIntervalSince1970: 40),
      pinned: false
    )
    let oldUnpinned = Chat(
      title: "alpha architecture notes",
      createdAt: Date(timeIntervalSince1970: 30),
      updatedAt: Date(timeIntervalSince1970: 30),
      pinned: false
    )
    let nonMatch = Chat(
      title: "Budget review",
      createdAt: Date(timeIntervalSince1970: 50),
      updatedAt: Date(timeIntervalSince1970: 50),
      pinned: true
    )

    let result = ChatListPresentation.visibleChats(
      [recentUnpinned, nonMatch, oldUnpinned, oldPinned],
      searchText: " alpha "
    )

    XCTAssertEqual(
      result.map(\.id),
      [oldPinned.id, recentUnpinned.id, oldUnpinned.id],
      "search must match visible titles case-insensitively while preserving pinned-first then recency ordering"
    )
  }

  func test_search_matches_message_body_when_title_does_not() {
    let titleMiss = Chat(
      title: "Untitled notes",
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let body = Message(role: "user", content: "How do I configure the KV cache?", ts: Date())
    titleMiss.messages.append(body)

    let result = ChatListPresentation.visibleChats([titleMiss], searchText: "kv cache")

    XCTAssertEqual(
      result.map(\.id), [titleMiss.id],
      "a chat must surface when the query matches a message body even if the title does not"
    )
  }

  func test_title_hits_rank_above_body_only_hits() {
    // The body-only hit is MORE recent than the title hit, proving the
    // title-above-body grouping overrides raw recency.
    let titleHit = Chat(
      title: "Cache strategy",
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let bodyHit = Chat(
      title: "Weekend plans",
      createdAt: Date(timeIntervalSince1970: 20),
      updatedAt: Date(timeIntervalSince1970: 40)
    )
    bodyHit.messages.append(Message(role: "user", content: "let's discuss the cache", ts: Date()))

    let result = ChatListPresentation.visibleChats([bodyHit, titleHit], searchText: "cache")

    XCTAssertEqual(
      result.map(\.id), [titleHit.id, bodyHit.id],
      "title matches must rank above body-only matches regardless of recency"
    )
  }

  func test_empty_query_returns_all_in_pinned_recency_order() {
    let pinned = Chat(title: "Pinned", updatedAt: Date(timeIntervalSince1970: 10), pinned: true)
    let recent = Chat(title: "Recent", updatedAt: Date(timeIntervalSince1970: 50))
    let old = Chat(title: "Old", updatedAt: Date(timeIntervalSince1970: 20))

    let result = ChatListPresentation.visibleChats([recent, old, pinned], searchText: "  ")

    XCTAssertEqual(result.map(\.id), [pinned.id, recent.id, old.id])
  }
}
