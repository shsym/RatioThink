import Foundation

/// #516 — the pending-send contract behind the chat send gate.
///
/// When a send is blocked because no model resolves, the gate sheet's copy
/// promises the message will send once the model is ready ("Load X to send
/// your message?", "your message will send once it's ready"). This value
/// is what makes that promise true: it captures the blocked send's context
/// (which chat, which load target, what text) at gate-raise time, and the
/// pure `verdict` decides — on every later model-resolution edge — whether
/// the original send should now fire, keep waiting, or be dropped because
/// the context went stale.
///
/// Pure + value-only so the whole once-and-only-once matrix (success,
/// failure, cancellation, chat/model/profile switches, duplicate-send
/// guards) is unit-testable in the fast SPM tier without SwiftUI or an
/// engine. The view layer owns WHEN to arm (a blocked send), WHEN to
/// evaluate (model-resolution edges), and HOW to submit (the composer's
/// normal submit path, so the auto-send shares the manual send's exact
/// persistence + in-flight lifecycle); this type owns only the decision.
public struct PendingAutoSend: Equatable, Sendable {
  /// The chat the blocked send belonged to. A resolution observed while a
  /// different chat is frontmost must never fire the stale send.
  public let chatID: UUID
  /// The load target the gate named when the send was blocked (the chat's
  /// pin else the profile default — `ModelTarget`). The auto-send fires
  /// only when THIS model resolves; anything else resolving means the
  /// user switched model/profile and the pending send is stale.
  public let targetModelID: String
  /// The blocked draft, trimmed. The composer re-checks its live draft
  /// against this before submitting, so an edit made while the model was
  /// loading cancels the auto-send instead of sending text the user is
  /// still rewriting.
  public let messageText: String

  public enum Verdict: Equatable, Sendable {
    /// Nothing resolved yet (engine still starting / model still loading,
    /// or a load failure left nothing resolvable) — stay armed. A failure
    /// keeps the pending send alive deliberately: the gate shows recovery,
    /// and a successful retry still owes the user their message.
    case hold
    /// The intended model resolved for the same chat — submit exactly once.
    case fire
    /// The context went stale (different chat, or a different model
    /// resolved after a model/profile switch) — drop without sending.
    case disarm
  }

  /// Arm only when there is a real message and a concrete load target.
  /// Returns nil otherwise — e.g. the launch-time engine-start prompt
  /// raises the same gate with an empty composer, and a `.noDefault`
  /// block has no target the gate could promise to load.
  public static func arm(chatID: UUID,
                         targetModelID: String?,
                         messageText: String) -> PendingAutoSend? {
    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let target = targetModelID, !target.isEmpty else { return nil }
    return PendingAutoSend(chatID: chatID, targetModelID: target, messageText: text)
  }

  /// Fold a model-resolution observation into a decision. `resolvedModelID`
  /// is the same value the send path itself resolves (`currentModelID`),
  /// so "fire" can never pass a model the send would then reject.
  ///
  /// `isSending` — review v1 F2: the composer's `submit()` bails (silently)
  /// while a send is in flight, so a fire delivered then would be swallowed
  /// with the pending already cleared. Hold instead; the in-flight-cleared
  /// edge re-evaluates and delivers the deferred fire. No default (review
  /// v2 F7): a verdict computed without in-flight state re-opens that hole,
  /// so every caller must pass it explicitly.
  public func verdict(chatID: UUID, resolvedModelID: String?,
                      isSending: Bool) -> Verdict {
    guard chatID == self.chatID else { return .disarm }
    guard let resolved = resolvedModelID, !resolved.isEmpty else { return .hold }
    guard resolved == targetModelID else { return .disarm }
    return isSending ? .hold : .fire
  }
}
