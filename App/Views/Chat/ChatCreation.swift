import Foundation
import SwiftData

/// Shared "insert a fresh chat" path used by both the chat-list New Chat
/// affordance and the col-3 zero-state CTA. Centralizing it keeps the
/// save + rollback-on-failure behavior identical wherever a chat is
/// created — the in-memory insert is rolled back on a save error so the
/// `@Query`-backed sidebar never surfaces a row that is not on disk.
@available(macOS 14, *)
enum ChatCreation {
  /// Insert and persist a new chat, returning its id. On a save failure
  /// the insert is rolled back, the error is reported, and `nil` is
  /// returned so the caller leaves selection untouched.
  ///
  /// #460: a new chat INHERITS the active profile + concrete model from the
  /// chat the user was already in, so "New Chat" keeps the same
  /// profile/model context instead of resetting to the bare `"chat"`
  /// default. Callers pass the source chat's `profileID` / `modelID`; the
  /// defaults (used by the zero-state CTA, which has no source chat) match
  /// the old `Chat()` behavior.
  @MainActor
  static func create(
    in context: ModelContext,
    persistenceStatus: PersistenceStatus,
    contextLabel: String,
    profileID: String = "chat",
    modelID: String? = nil
  ) -> UUID? {
    let chat = Chat(profileID: profileID, modelID: modelID)
    context.insert(chat)
    do {
      try context.save()
    } catch {
      context.delete(chat)
      persistenceStatus.report(error, context: contextLabel)
      return nil
    }
    return chat.id
  }
}
