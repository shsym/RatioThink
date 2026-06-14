import Foundation

@available(macOS 14, *)
public enum ChatListPresentation {
  /// Filter + rank the chat list for the sidebar (#577). An empty query
  /// returns every chat in pinned-first, then most-recent order. A non-empty
  /// query matches both the conversation TITLE and any message BODY
  /// (`Message.content`), so a chat surfaces by what was said in it — not just
  /// its title. Title matches rank ABOVE body-only matches; within each group
  /// the pinned-first/recency order is preserved. The two groups are carved
  /// out of the already-sorted list, so ordering is inherited rather than
  /// recomputed.
  public static func visibleChats(_ chats: [Chat], searchText: String) -> [Chat] {
    let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let ordered = sortedChats(chats)
    guard !trimmedQuery.isEmpty else { return ordered }

    var titleHits: [Chat] = []
    var bodyHits: [Chat] = []
    for chat in ordered {
      if chat.title.localizedCaseInsensitiveContains(trimmedQuery) {
        titleHits.append(chat)
      } else if chat.messages.contains(where: {
        $0.content.localizedCaseInsensitiveContains(trimmedQuery)
      }) {
        bodyHits.append(chat)
      }
    }
    return titleHits + bodyHits
  }

  private static func sortedChats(_ chats: [Chat]) -> [Chat] {
    chats.sorted { lhs, rhs in
      if lhs.pinned != rhs.pinned { return lhs.pinned }
      return lhs.updatedAt > rhs.updatedAt
    }
  }
}
