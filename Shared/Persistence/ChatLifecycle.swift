import Foundation
import SwiftData

/// Chat lifecycle rules (#512): a freshly-created chat is a transient
/// draft until it holds real conversation. Empty drafts are pruned when
/// the user navigates away (`pruneIfEmpty`, hooked on selection change)
/// and at launch (`pruneAllEmptyChats`, reconciling shells left by quit
/// or by builds that predate pruning). Centralized here so the
/// empty-vs-real boundary is a single, unit-tested definition.
@available(macOS 14, *)
public enum ChatLifecycle {
  /// A chat is a prunable empty shell when nothing about it carries user
  /// intent: never pinned, never titled away from the default, and no
  /// message with real content. Profile/model metadata alone does not
  /// make a conversation real — every new chat carries those.
  ///
  /// Kept deliberately conservative: a chat with a user-authored message
  /// survives even if the send failed or was cancelled (the user started
  /// a turn), and ANY message row with content/reasoning/tree data —
  /// whatever its role — counts as real, so unexpected data is never
  /// deleted.
  public static func isPrunableEmpty(_ chat: Chat) -> Bool {
    guard !chat.pinned else { return false }
    guard chat.title == Chat.defaultTitle else { return false }
    return !chat.messages.contains(where: isRealContent)
  }

  /// Whether a message row makes its chat a real conversation: any
  /// non-whitespace content (a user turn, a streamed/failed assistant
  /// answer), reasoning text, or a tree-of-thought snapshot.
  static func isRealContent(_ message: Message) -> Bool {
    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    if !message.reasoning.isEmpty { return true }
    if message.tot != nil { return true }
    return false
  }

  /// Delete `chatID` if it is a prunable empty shell. Safe to call with
  /// a stale/unknown id (no-op). On a save failure the pending delete is
  /// rolled back and reported — the row stays visible, mirroring
  /// `ChatListView.delete`.
  @MainActor
  public static func pruneIfEmpty(
    chatID: UUID,
    in context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) {
    let descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
    guard let chat = (try? context.fetch(descriptor))?.first,
          isPrunableEmpty(chat) else { return }
    delete([chat], in: context, persistenceStatus: persistenceStatus,
           reportContext: "ChatLifecycle.pruneIfEmpty")
  }

  /// Launch-time reconcile: prune every persisted empty shell (old
  /// builds accumulated them; quitting with an empty chat selected
  /// leaves one). `excluding` protects the currently-selected chat —
  /// pruning never deletes what the user is looking at.
  @MainActor
  public static func pruneAllEmptyChats(
    in context: ModelContext,
    excluding selectedID: UUID? = nil,
    persistenceStatus: PersistenceStatus
  ) {
    guard let chats = try? context.fetch(FetchDescriptor<Chat>()) else { return }
    let shells = chats.filter { $0.id != selectedID && isPrunableEmpty($0) }
    guard !shells.isEmpty else { return }
    delete(shells, in: context, persistenceStatus: persistenceStatus,
           reportContext: "ChatLifecycle.pruneAllEmptyChats")
  }

  @MainActor
  private static func delete(
    _ chats: [Chat],
    in context: ModelContext,
    persistenceStatus: PersistenceStatus,
    reportContext: String
  ) {
    for chat in chats { context.delete(chat) }
    do {
      try context.save()
    } catch {
      // `delete` mutates the in-memory graph immediately; roll the
      // pending deletes back so the sidebar and the on-disk store stay
      // in sync (same recovery as ChatListView.delete).
      context.rollback()
      persistenceStatus.report(error, context: reportContext)
    }
  }
}

/// Deterministic local auto-title (#512 v1): derive a sidebar title from
/// the first user message. Instant, private, offline — no engine call.
/// Pure so the trim/collapse/cap contract is unit-tested directly.
public enum ChatAutoTitle {
  /// Title length cap. Long enough to be useful, short enough for a
  /// sidebar row (#511 handles layout for realistic generated titles).
  public static let maxLength = 60

  /// Collapse all whitespace/newlines to single spaces, then cap at
  /// `maxLength` on a word boundary (falling back to a hard cut when the
  /// leading word itself overflows), appending an ellipsis when
  /// truncated. Returns nil when the text has no meaningful content —
  /// the caller keeps the existing title.
  public static func derive(from text: String) -> String? {
    let collapsed = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    guard collapsed.count > maxLength else { return collapsed }

    let hardCut = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
    let prefix = collapsed[..<hardCut]
    // Cut at the last word boundary inside the cap unless that would
    // leave a uselessly short stub (a single enormous first token).
    if let lastSpace = prefix.lastIndex(of: " "),
       collapsed.distance(from: collapsed.startIndex, to: lastSpace) >= maxLength / 2 {
      return String(prefix[..<lastSpace]) + "…"
    }
    return String(prefix) + "…"
  }
}
