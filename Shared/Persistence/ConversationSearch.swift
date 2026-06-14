import Foundation

/// One matched conversation. `snippet` is a short excerpt of the first
/// message whose body matched, or `nil` when only the title matched.
@available(macOS 14, *)
public struct ConversationSearchResult: Identifiable, Equatable {
  /// The matched chat's stable id (so the GUI can route a selection back
  /// through `WindowState.selectedItemID`).
  public let id: UUID
  public let title: String
  public let snippet: String?

  public init(id: UUID, title: String, snippet: String?) {
    self.id = id
    self.title = title
    self.snippet = snippet
  }
}

/// Naive, case-insensitive substring search over conversation titles and
/// message bodies. Per-keystroke cost is O(total messages) — acceptable for
/// this surface; a dedicated body-search index is a separate effort and is
/// intentionally NOT built here.
///
/// Pure (no SwiftData fetch, no AppKit) so it lives in `RatioThinkCore` and
/// is unit-testable against in-memory `Chat`/`Message` rows.
@available(macOS 14, *)
public enum ConversationSearch {
  /// Conversations whose title OR any message body contains `query`,
  /// preserving the input order (callers pass chats already sorted by
  /// recency). An empty/whitespace query yields no results.
  public static func results(in chats: [Chat], query rawQuery: String) -> [ConversationSearchResult] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    return chats.compactMap { chat in
      let titleHit = chat.title.range(of: query, options: .caseInsensitive) != nil
      let bodyHit = chat.messages.first {
        $0.content.range(of: query, options: .caseInsensitive) != nil
      }
      guard titleHit || bodyHit != nil else { return nil }
      let snippet = bodyHit.map { excerpt($0.content, around: query) }
      return ConversationSearchResult(id: chat.id, title: chat.title, snippet: snippet)
    }
  }

  /// A window of `content` centered on the first match of `needle`, padded
  /// by `radius` characters each side and ellipsized when truncated, so a
  /// result shows the hit in context rather than the whole message.
  static func excerpt(_ content: String, around needle: String, radius: Int = 40) -> String {
    guard let match = content.range(of: needle, options: .caseInsensitive) else {
      return String(content.prefix(radius * 2))
    }
    let start = content.index(match.lowerBound, offsetBy: -radius, limitedBy: content.startIndex)
      ?? content.startIndex
    let end = content.index(match.upperBound, offsetBy: radius, limitedBy: content.endIndex)
      ?? content.endIndex
    var out = String(content[start..<end])
    if start > content.startIndex { out = "…" + out }
    if end < content.endIndex { out += "…" }
    return out
  }
}
