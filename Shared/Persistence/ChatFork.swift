import Foundation
import SwiftData

/// Non-destructive "edit a prior user turn and re-run from there" fork
/// (#624). Editing a message does NOT rewrite the live chat — it copies
/// the conversation up to and including the edited turn into a brand-new
/// `Chat` (substituting the edited content), leaving the original chat
/// fully intact, like duplicate-then-edit.
///
/// Prefix-cache fidelity (#522): the copied rows BEFORE the edited turn
/// carry byte-identical `role` + `content`, so the engine's
/// content-addressed KV snapshot reuses the cached pages for the
/// unchanged prefix; only the edited turn onward re-prefills. The copy is
/// therefore verbatim (same `content`, `reasoning`, `meta`, `tokens`,
/// `ts`) for every prior row — only the edited turn's `content` differs.
@available(macOS 14, *)
enum ChatFork {
  /// Fork `chat` at `message` (which must be a user turn living in
  /// `chat.messages`): create a new chat carrying a faithful copy of every
  /// message up to and including `message`, with `message`'s content
  /// replaced by `newContent`. Persist and return the new chat's id, or
  /// `nil` on a save failure (the in-memory insert is rolled back so the
  /// `@Query`-backed sidebar never shows a row that isn't on disk).
  @MainActor
  static func fork(
    chat: Chat,
    at message: Message,
    newContent: String,
    in context: ModelContext,
    persistenceStatus: PersistenceStatus,
    contextLabel: String
  ) -> UUID? {
    // Order by the SAME (ts, id) tiebreak `ChatSendController.makeRequest`
    // uses, so "up to and including" matches the exact wire-history cut.
    let ordered = chat.messages.sorted { lhs, rhs in
      if lhs.ts == rhs.ts { return lhs.id.uuidString < rhs.id.uuidString }
      return lhs.ts < rhs.ts
    }
    guard let cut = ordered.firstIndex(where: { $0.id == message.id }) else {
      return nil
    }
    let prefix = ordered[...cut]

    // Inherit the source chat's identity so the fork opens configured exactly
    // like the original: profile (drives model/system-prompt/speculation
    // resolution), the pinned model authority (#460 `modelID`), the title, and
    // its user-titled flag (a copied title carries the same provenance).
    let newChat = Chat(
      title: chat.title,
      profileID: chat.profileID,
      modelID: chat.modelID,
      userTitled: chat.userTitled
    )
    context.insert(newChat)
    for source in prefix {
      let isEdited = source.id == message.id
      let copy = Message(
        role: source.role,
        content: isEdited ? newContent : source.content,
        // Edited turn starts a fresh turn: drop the original's reasoning /
        // finish meta / token count. Prior rows copy verbatim so the
        // transcript renders identically and the KV prefix stays byte-equal.
        reasoning: isEdited ? "" : source.reasoning,
        tokens: isEdited ? 0 : source.tokens,
        ts: source.ts,
        meta: isEdited ? nil : source.meta,
        // Carry a prior assistant turn's tree-of-thought (#413) so the forked
        // transcript renders identically; the edited user turn never has one.
        tot: isEdited ? nil : source.tot
      )
      context.insert(copy)
      newChat.messages.append(copy)
    }
    // The fork's recency = its last copied turn, so it sorts into the
    // sidebar just under the source chat rather than jumping to "now".
    newChat.updatedAt = prefix.last?.ts ?? newChat.createdAt

    do {
      try context.save()
    } catch {
      context.delete(newChat) // cascade-deletes the copied messages
      persistenceStatus.report(error, context: contextLabel)
      return nil
    }
    return newChat.id
  }
}
