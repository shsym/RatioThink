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

  /// Outcome of a retry click after the user's intent is settled (the
  /// confirmation was accepted, or none was needed). Review v1 F1: a
  /// confirmed destructive action must never silently no-op, so every
  /// blocked branch is an explicit case the caller can surface.
  public enum Application: Equatable {
    /// Truncation applied — issue the request from the retained prefix.
    case send
    /// The transcript changed (or a stream started) between the click and
    /// now — re-planning failed. Nothing was deleted; tell the user.
    case noLongerApplies
    /// The truncation save failed. `execute` already rolled back and
    /// reported via `persistenceStatus` (the persistence banner), so no
    /// extra notice is owed — but the resend must not happen.
    case saveFailed
  }

  /// Re-validate and apply a retry click in one step. Centralized here
  /// (not in the view) so the stale-confirm path — confirm presented,
  /// transcript mutated underneath, Retry clicked — is unit-testable:
  /// it must come back `.noLongerApplies` with zero messages deleted.
  @MainActor
  public static func apply(
    retryPointID: UUID,
    chat: Chat,
    isInFlight: Bool,
    context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) -> Application {
    guard !isInFlight,
          let plan = plan(messages: chat.messages, retryPointID: retryPointID) else {
      return .noLongerApplies
    }
    guard execute(plan, chat: chat, context: context, persistenceStatus: persistenceStatus) else {
      return .saveFailed
    }
    return .send
  }

  /// IDs of every valid retry anchor in one pass over the PRE-SORTED
  /// transcript — the render-path companion of `plan` (review v1 F2:
  /// calling `plan` per row re-sorted the array per row, O(n² log n) on
  /// the render path). Same rule as `plan`'s guard: an assistant row with
  /// at least one user row before it. `plan` stays the click-path
  /// authority; a parity unit test pins the two to the same rule.
  public static func validRetryPointIDs(sortedMessages: [Message]) -> Set<UUID> {
    validRetryPointIDs(sortedRoles: sortedMessages.map { ($0.id, $0.role) })
  }

  /// Projection-friendly overload: the transcript renderer works from
  /// value rows (`TranscriptSnapshot` items), not `Message` @Model
  /// objects, so it passes pre-sorted `(id, raw role)` pairs directly.
  public static func validRetryPointIDs(sortedRoles: [(id: UUID, role: String)]) -> Set<UUID> {
    var seenUser = false
    var ids: Set<UUID> = []
    for row in sortedRoles {
      if row.role == ChatMessage.Role.user.rawValue {
        seenUser = true
      } else if seenUser, row.role == ChatMessage.Role.assistant.rawValue {
        ids.insert(row.id)
      }
    }
    return ids
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
