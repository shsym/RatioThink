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
  /// intent: never pinned, never user-titled, never titled away from the
  /// default, and no message with real content. Profile/model metadata
  /// alone does not make a conversation real — every new chat carries
  /// those.
  ///
  /// `userTitled` is the authoritative manual-rename signal: a user who
  /// renamed a chat — even to exactly the "New Chat" placeholder text —
  /// keeps it. The textual `title == defaultTitle` check stays alongside
  /// it for migration safety: a chat renamed on a pre-`userTitled` build
  /// backfills `userTitled == false`, and only the text check protects it.
  ///
  /// Kept deliberately conservative: a chat with a user-authored message
  /// survives even if the send failed or was cancelled (the user started
  /// a turn), and ANY message row with content/reasoning/tree data —
  /// whatever its role — counts as real, so unexpected data is never
  /// deleted.
  public static func isPrunableEmpty(_ chat: Chat) -> Bool {
    guard !chat.pinned, !chat.userTitled else { return false }
    guard chat.title == Chat.defaultTitle else { return false }
    return !chat.messages.contains(where: isRealContent)
  }

  /// Whether the first-message auto-title may run: only a chat the user
  /// has never titled, still carrying the placeholder. A manual rename
  /// (`userTitled`) wins permanently — including a rename to the literal
  /// "New Chat" text, which without the flag would re-enter the
  /// auto-title regime.
  public static func shouldAutoTitle(_ chat: Chat) -> Bool {
    !chat.userTitled && chat.title == Chat.defaultTitle
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
    pruneIfEmpty(in: context, persistenceStatus: persistenceStatus,
                 fetchChat: { try context.fetch(descriptor).first })
  }

  /// Fetch seam for the prune-on-leave path (review F1): a store fetch
  /// failure must be REPORTED, not silently skipped — `try?` here would
  /// make pruning appear to work while never running. Internal so the
  /// report-and-bail contract is unit-testable (an in-memory SwiftData
  /// store cannot be made to throw on demand).
  @MainActor
  static func pruneIfEmpty(
    in context: ModelContext,
    persistenceStatus: PersistenceStatus,
    fetchChat: () throws -> Chat?
  ) {
    let chat: Chat?
    do {
      chat = try fetchChat()
    } catch {
      persistenceStatus.report(error, context: "ChatLifecycle.pruneIfEmpty.fetch")
      return
    }
    guard let chat, isPrunableEmpty(chat) else { return }
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
    pruneAllEmptyChats(in: context, excluding: selectedID,
                       persistenceStatus: persistenceStatus,
                       fetchChats: { try context.fetch(FetchDescriptor<Chat>()) })
  }

  /// Fetch seam for the launch reconcile (review F1): a fetch failure
  /// (corrupt store, migration mismatch) is reported and the reconcile
  /// bails — never a silent no-op that looks like a clean run.
  @MainActor
  static func pruneAllEmptyChats(
    in context: ModelContext,
    excluding selectedID: UUID?,
    persistenceStatus: PersistenceStatus,
    fetchChats: () throws -> [Chat]
  ) {
    let chats: [Chat]
    do {
      chats = try fetchChats()
    } catch {
      persistenceStatus.report(error, context: "ChatLifecycle.pruneAllEmptyChats.fetch")
      return
    }
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
