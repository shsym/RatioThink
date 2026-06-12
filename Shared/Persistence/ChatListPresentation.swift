import Foundation

@available(macOS 14, *)
public enum ChatListPresentation {
  public static func visibleChats(_ chats: [Chat], searchText: String) -> [Chat] {
    let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return sortedChats(chats).filter { chat in
      trimmedQuery.isEmpty || chat.title.localizedCaseInsensitiveContains(trimmedQuery)
    }
  }

  private static func sortedChats(_ chats: [Chat]) -> [Chat] {
    chats.sorted { lhs, rhs in
      if lhs.pinned != rhs.pinned { return lhs.pinned }
      return lhs.updatedAt > rhs.updatedAt
    }
  }
}
