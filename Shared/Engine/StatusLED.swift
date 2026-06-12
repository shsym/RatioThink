import Foundation

/// One LED-style indicator element — a tinted dot or ring that may blink
/// (#412). The toolbar pip renders TWO of these: an outer ring for the
/// background-helper health and an inner dot for the engine. Pure + Equatable
/// so the whole state→visual mapping is unit-tested without SwiftUI; the view
/// maps `Tint` to a concrete appearance-adaptive `Color` and drives the blink
/// with a lifetime-bound `TimelineView`.
///
/// LED language (locked with the user): waiting → slow-blink white,
/// error → amber (blinking), success → solid green-ish white, given-up → red.
public struct StatusLED: Equatable, Sendable {
  public enum Tint: Equatable, Sendable {
    /// Dim / off — a calm idle (engine stopped, or engine state unknown while
    /// the helper is being restarted).
    case off
    /// Waiting — slow-blink white (engine starting / model loading / helper
    /// reconnecting). Like a Mac mini's sleeping power LED.
    case white
    /// Healthy success — solid green-ish white (engine running).
    case greenWhite
    /// Recoverable trouble — amber (engine failed, or helper auto-repairing).
    case amber
    /// Given up — red (helper unreachable after the repair ladder exhausted).
    case red
  }

  public var tint: Tint
  public var blink: Bool

  public init(tint: Tint, blink: Bool) {
    self.tint = tint
    self.blink = blink
  }

  /// A calm, non-blinking dim element.
  public static let dim = StatusLED(tint: .off, blink: false)

  /// Engine-dot LED for a folded `EngineIndicatorState`. #469: a model switch
  /// is now an engine restart (`.starting` → `.running`), so there is no
  /// separate `.loading` state — "loading a model" reads as the amber starting
  /// LED.
  public static func engineDot(for state: EngineIndicatorState) -> StatusLED {
    switch state {
    case .offline:  return StatusLED(tint: .off, blink: false)
    case .starting: return StatusLED(tint: .white, blink: true)
    case .running:  return StatusLED(tint: .greenWhite, blink: false)
    case .error:    return StatusLED(tint: .amber, blink: true)
    }
  }
}

/// What the inner (engine) element should render. #469: the engine element is
/// always a tinted dot now (the former model-load progress ring went with the
/// removed `/v1/models/load` UI). Kept an enum for the helper-ring composition
/// and forward-compat.
public enum IndicatorDot: Equatable, Sendable {
  /// A tinted (possibly blinking) dot.
  case led(StatusLED)
}

/// Pure mapping of `HelperHealth` → the outer helper-ring LED.
public enum HelperRingState {
  /// The ring carries the BACKGROUND-HELPER signal; `nil` means a healthy
  /// helper shows no ring at all (quiet when nothing is wrong).
  public static func ring(for health: HelperHealth) -> StatusLED? {
    switch health {
    case .healthy:
      return nil
    case .reconnecting:
      // Transient poll loss — launchd/throttle is expected to self-heal.
      return StatusLED(tint: .white, blink: true)
    case .repairing, .repairCoolingDown:
      // The App is actively restarting the helper.
      return StatusLED(tint: .amber, blink: true)
    case .unreachable:
      // Repair ladder exhausted — loud, paired with the escalation banner.
      return StatusLED(tint: .red, blink: true)
    }
  }
}

/// Folds the helper-health axis and the engine axis into the toolbar pip's two
/// elements: the outer ring (helper) and the inner dot (engine). Pure.
public enum HelperEngineIndicator {
  public static func make(
    helper: HelperHealth,
    engine: EngineIndicatorState
  ) -> (ring: StatusLED?, dot: IndicatorDot) {
    let ring = HelperRingState.ring(for: helper)
    let dot: IndicatorDot
    switch helper {
    case .healthy, .reconnecting:
      // Healthy or a transient blip: show the live engine state. During a
      // blip the engine is almost certainly still fine, so keep its dot
      // ("dot = last") rather than dimming on a single missed poll.
      dot = .led(StatusLED.engineDot(for: engine))
    case .repairing, .repairCoolingDown, .unreachable:
      // We've given up on a transient explanation and are restarting the
      // helper — the engine state it last reported is stale/unknown, so the
      // dot goes dim and the ring tells the story.
      dot = .led(.dim)
    }
    return (ring: ring, dot: dot)
  }
}
