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
}
