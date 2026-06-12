import Foundation

/// Pure decision for the **helper-operation gate** (#496): may an engine
/// mutation (start / stop / restart) reach the background Helper right now?
///
/// Engine mutations are routed through `EngineStatusStore`'s start/stop/restart
/// methods, which call the Helper over XPC. When the Helper transport itself is
/// not healthy — it is being (re)started, repaired, or has been declared
/// unreachable — such a call would fail at the XPC layer or race the in-flight
/// repair. This gate refuses the op AT THE CHANNEL with a helper-framed reason,
/// so the user gets an honest "the helper is starting / isn't responding"
/// instead of an engine-framed fault (the mis-attribution #496 set out to kill).
///
/// Read-only Helper traffic — the 1 Hz `engineStatus()` poll, `engineMemory`,
/// a forced `refresh()` — is deliberately NOT gated: it is exactly what drives
/// the `HelperHealth` ladder back to `.healthy`, so gating it would deadlock
/// recovery. Only the mutating ops are gated.
///
/// Pure + value-only so the whole matrix is unit-tested in the fast
/// `RatioThinkCoreTests` (SPM) tier (mirrors `StatusBannerReducer` /
/// `HelperHealthReducer`).
public enum HelperOpGate {
  /// `nil` ⇒ the op is allowed (Helper healthy). Non-nil ⇒ the op is refused;
  /// the value is the helper-framed reason the caller throws + surfaces inline.
  public static func evaluate(_ helper: HelperHealth) -> HelperUnavailable? {
    switch helper {
    case .healthy:
      return nil
    case .reconnecting, .repairing, .repairCoolingDown:
      // The Helper is coming up / being repaired — a bounded wait. Refuse with
      // the calm "starting" reason; the op succeeds once a poll recovers it.
      return .starting
    case .unreachable:
      // The bounded restart ladder is exhausted — the loud escalation.
      return .unreachable
    }
  }
}

/// Why a helper op was refused by `HelperOpGate`. Thrown by the gated
/// `EngineStatusStore` mutators and surfaced as an inline, helper-framed
/// refusal at the call site (never the engine-failure banner — routing it there
/// would re-attribute a Helper state to the engine, the exact #496 bug).
public enum HelperUnavailable: Error, Equatable, Sendable {
  /// The Helper is being (re)started or repaired — a bounded wait.
  case starting
  /// The Helper restart ladder is exhausted and it is unreachable.
  case unreachable

  /// The user-facing, helper-framed copy. The window-level
  /// `UnifiedStatusBanner` carries the authoritative helper status; this is the
  /// immediate "your tap was refused, and why" near the action.
  public var message: String {
    switch self {
    case .starting:
      return "The background helper is starting. Please wait a moment, then try again."
    case .unreachable:
      return "The background helper isn’t responding. Use Force Restart in the status bar above to reload it."
    }
  }
}
