import Foundation
import SwiftData

/// Construction helpers for new chats. User-facing creation begins with
/// `makeDraft`; the composer persists that draft's values with the first
/// message. `create` remains the explicit immediate-persistence primitive for
/// callers that already have durable chat content to attach.
@available(macOS 14, *)
enum ChatCreation {
  /// Build a chat without inserting it. New-conversation surfaces use this
  /// until the first user message can be saved atomically with the chat.
  @MainActor
  static func makeDraft(
    profileID: String = "chat",
    modelID: String? = nil
  ) -> Chat {
    Chat(
      profileID: profileID,
      modelID: modelID ?? debugPinnedChatModel()
    )
  }

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
    // #577 review v2 F4: DEBUG-only seam to force a create failure so a GUI
    // test can exercise the new-chat draft-retention contract (a failed create
    // must keep the typed text). Mirrors a real `save()` failure: nothing
    // persists and `nil` is returned. Compiled out of Release; the env var is
    // unset in production.
    #if DEBUG
    if ProcessInfo.processInfo.environment["PIE_TEST_FORCE_CHAT_CREATE_FAILURE"] == "1" {
      return nil
    }
    #endif
    let chat = makeDraft(profileID: profileID, modelID: modelID)
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
