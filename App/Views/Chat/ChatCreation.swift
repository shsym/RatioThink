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
    let resolvedModelID = modelID ?? debugPinnedChatModel()
    let chat = Chat(profileID: profileID, modelID: resolvedModelID)
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

  /// DEBUG-only GUI-test seam (#460): pin a fresh chat's `Chat.modelID` (the
  /// single selection authority) from `PIE_TEST_CHAT_MODEL_PIN` when the
  /// caller did not already inherit a model. This is the single-source analog
  /// of the removed `PIE_TEST_RESIDENT_MODEL` residency seam: under the single
  /// authority a profile swap keys on the chat's SELECTION, not engine
  /// residency, so a test reaches the cross-model swap popover by pinning a
  /// model that differs from the target profile's default — an EXPLICIT pin,
  /// never residency. Compiled out of Release; never consulted in production
  /// (the env var is unset).
  @MainActor
  private static func debugPinnedChatModel() -> String? {
    #if DEBUG
    let pin = ProcessInfo.processInfo.environment["PIE_TEST_CHAT_MODEL_PIN"]
    return (pin?.isEmpty == false) ? pin : nil
    #else
    return nil
    #endif
  }
}
