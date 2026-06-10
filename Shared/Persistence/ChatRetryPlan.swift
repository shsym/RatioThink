import Foundation
import SwiftData

/// Retry-from-a-prior-turn semantics (#513): retrying an assistant turn
/// truncates the conversation from that turn onward, then re-issues a new
/// request from the retained prefix. Destructive by design — there is no
/// branch/fork history; later turns (and any engine KV built on them) are
/// dropped, and the engine sees only the retained prefix because every
/// request rebuilds context from the persisted messages
/// (`ChatSendController.makeRequest`).
///
/// Split into a pure `plan` (what would be deleted, and whether the user
/// must confirm) and an atomic `execute` (single save, rollback on
/// failure) so the destructive decision is unit-testable without a view
/// host and the UI can ask "does this need a confirmation?" before
/// mutating anything.
@available(macOS 14, *)
public enum ChatRetryPlan {
  public struct Plan: Equatable {
    /// The retry-point assistant row plus every later message, in
    /// transcript order. Deleting the stale assistant itself is what keeps
    /// a latest-turn retry from accumulating duplicate assistant turns.
    public let deleteMessageIDs: [UUID]
    /// True when the deletion reaches BEYOND the retry-point assistant —
    /// i.e. later conversation exists and the UI must confirm the erase.
    /// A latest-turn retry (only the stale assistant goes) skips it.
    public let requiresConfirmation: Bool
  }

  /// Plan a retry anchored at the assistant message `retryPointID`.
  /// Returns nil when retry is not valid there: the id is missing, the row
  /// is not an assistant turn, or no user turn precedes it (an empty
  /// retained prefix has nothing to resend).
  public static func plan(messages: [Message], retryPointID: UUID) -> Plan? {
    let sorted = messages.sorted(by: Message.transcriptPrecedes)
    guard let index = sorted.firstIndex(where: { $0.id == retryPointID }),
          sorted[index].role == ChatMessage.Role.assistant.rawValue,
          sorted[..<index].contains(where: { $0.role == ChatMessage.Role.user.rawValue })
    else { return nil }
    return Plan(
      deleteMessageIDs: sorted[index...].map(\.id),
      requiresConfirmation: sorted.count - index > 1
    )
  }

  /// Apply the truncation atomically: one save covers every deletion, and
  /// a failed save rolls the context back so no half-truncated transcript
  /// survives. Returns false (after reporting) when the save failed — the
  /// caller must NOT issue the retry request in that case, or the engine
  /// would see a prefix the store does not hold.
  @MainActor
  @discardableResult
  public static func execute(
    _ plan: Plan,
    chat: Chat,
    context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) -> Bool {
    let doomedIDs = Set(plan.deleteMessageIDs)
    let doomed = chat.messages.filter { doomedIDs.contains($0.id) }
    chat.messages.removeAll { doomedIDs.contains($0.id) }
    doomed.forEach(context.delete)
    do {
      try context.save()
      return true
    } catch {
      context.rollback()
      persistenceStatus.report(error, context: "ChatRetryPlan.execute")
      return false
    }
  }
}
