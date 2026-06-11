import Foundation

/// #516: the scaffold's pending-auto-send bookkeeping, extracted from
/// `ChatScaffoldView`'s `@State` so the view-layer transitions — arm on a
/// blocked send, the disarm triggers (gate Cancel, manual send, profile
/// switch, navigate away), and the settle-on-resolution flow — are
/// unit-testable without a view host (the `resolutionProbe` /
/// `reconcileFailureStep` pattern, applied to state instead of a decision).
///
/// The pure WHAT-should-happen lives in `PendingAutoSend.verdict`; this
/// type owns the once-only bookkeeping AROUND it: clearing the pending
/// before the fire signal is published (re-entrant edges can't double-send)
/// and ticking `autoSubmit` so equal text on a later block still triggers
/// the composer's `.onChange`.
struct PendingSendState: Equatable {
  /// The armed pending send, if any. Read by the gate sheet's
  /// `willAutoSend` copy axis.
  private(set) var pending: PendingAutoSend?
  /// The fire signal handed to the composer (tick + edit-guard text).
  private(set) var autoSubmit: ComposerAutoSubmit?

  /// Arm on a blocked send. `PendingAutoSend.arm` rejects an empty draft
  /// or a missing load target (nothing to promise).
  mutating func arm(chatID: UUID, targetModelID: String?, messageText: String) {
    pending = PendingAutoSend.arm(chatID: chatID,
                                  targetModelID: targetModelID,
                                  messageText: messageText)
  }

  /// Drop the pending without sending. The view layer calls this on every
  /// stale-context trigger: gate Cancel, a committed send (manual or
  /// fired), a profile switch, and navigation away.
  mutating func disarm() {
    pending = nil
  }

  /// End a pending flow for this chat without sending when the view has
  /// reached a terminal no-resolution state (for example, bounded resident
  /// reconciliation failed). This is distinct from `.hold`: callers use it
  /// only when no later equal-status edge is expected to provide new evidence.
  mutating func terminate(chatID: UUID) {
    guard pending?.chatID == chatID else { return }
    pending = nil
  }

  /// Fold a resolution edge: fire exactly once when the intended model
  /// resolved (pending cleared BEFORE the signal is published), drop on a
  /// stale resolution, keep holding otherwise.
  mutating func settle(chatID: UUID, resolvedModelID: String?, isSending: Bool) {
    guard let pending else { return }
    switch pending.verdict(chatID: chatID,
                           resolvedModelID: resolvedModelID,
                           isSending: isSending) {
    case .hold:
      break
    case .disarm:
      self.pending = nil
    case .fire:
      self.pending = nil
      autoSubmit = ComposerAutoSubmit(
        tick: (autoSubmit?.tick ?? 0) + 1,
        expectedText: pending.messageText)
    }
  }
}
