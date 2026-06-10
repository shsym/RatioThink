import Foundation

/// Pure decision for the chat-body **helper-recovery overlay** (#496).
///
/// At app start the background Helper may not be running or reachable yet. The
/// always-on `UnifiedStatusBanner` already maps the `HelperHealth` ladder to a
/// calm→loud bar, but the chat BODY (transcript + composer) still read as an
/// ENGINE problem — `ChatScaffoldView`'s send gate is driven by `ChatStartGate`,
/// which is blind to the helper axis, so a helper that simply hadn't answered
/// yet surfaced as "Starting the engine…" and then (after the transport-loss
/// escalation) the engine-framed "Engine stopped unexpectedly" + an engine
/// Retry — the wrong subject AND the wrong recovery for a Helper that never came
/// up.
///
/// This reducer drives a dedicated full-bleed overlay over the chat body so a
/// Helper being brought up — or one the bounded restart ladder has given up on —
/// reads as a HELPER state. It folds the same `HelperHealth` axis the banner
/// uses, gated by `engineRunning` so a momentary mid-session helper poll blip on
/// a live engine never flashes the overlay over a working chat: the overlay is
/// scoped to the start/idle case where the engine is not serving and the Helper
/// is the thing the user is actually waiting on.
///
/// It never starts the engine or loads a model — the bounded wait reflects the
/// existing helper registration/restart reconciliation, and the escalation
/// offers only Helper-level recovery — so #286's no-hidden-fallback /
/// no-surprise-memory policy holds.
///
/// Pure + value-only so the whole matrix is unit-tested in the fast
/// `RatioThinkCoreTests` (SPM) tier without an engine, XPC, or SwiftUI.
public enum HelperRecoveryGate {

  /// What the chat-body overlay should render.
  public enum State: Equatable, Sendable {
    /// No overlay. Either the engine is usable, or the Helper is healthy and
    /// the engine is merely idle (the normal "Load default?" gate owns that).
    case hidden
    /// The Helper is being (re)started: a launchd respawn, the launch-time
    /// registration reconcile, or the App-side restart ladder is in flight.
    /// Calm, bounded "Starting background helper…" wait — no actions, and
    /// crucially no engine start.
    case startingHelper
    /// The bounded restart ladder is exhausted and the Helper is still
    /// unreachable. Loud, action-oriented recovery (Restart Helper / Open
    /// Login Items / Collect Diagnostics).
    case unreachable
  }

  /// The source-of-truth copy for each visible overlay state. Lives in the
  /// pure reducer (mirroring how `StatusBannerReducer` owns the banner copy)
  /// so the wording — and crucially its HELPER framing, never the engine — is
  /// unit-tested in the SPM tier without a SwiftUI view host.
  public struct Copy: Equatable, Sendable {
    public let title: String
    public let message: String
    public init(title: String, message: String) {
      self.title = title
      self.message = message
    }
  }

  /// Copy for a visible state; `nil` for `.hidden`.
  public static func copy(for state: State) -> Copy? {
    switch state {
    case .hidden:
      return nil
    case .startingHelper:
      return Copy(
        title: "Starting background helper…",
        message: "Bringing up the background service that runs your models. This usually takes a few seconds."
      )
    case .unreachable:
      return Copy(
        title: "Background helper isn’t responding",
        message: "Rational couldn’t restart its background engine helper, so the engine can’t run. Try restarting it, re-enable it in Login Items, or collect diagnostics."
      )
    }
  }

  /// Fold the helper axis into the overlay state.
  ///
  /// - Parameters:
  ///   - helper: the App-side `HelperHealthController.health` ladder state —
  ///     the SAME signal the `UnifiedStatusBanner` consumes, so the two
  ///     surfaces never disagree about whether the Helper is up.
  ///   - engineRunning: is the engine currently `.running`? A running engine
  ///     means the chat body is usable, so the overlay stays hidden even on a
  ///     transient helper poll blip — it must never cover a working chat.
  public static func evaluate(helper: HelperHealth, engineRunning: Bool) -> State {
    // A usable engine wins outright — never cover a working chat body, even if
    // a single poll blipped the helper ladder off `.healthy`.
    if engineRunning { return .hidden }

    switch helper {
    case .healthy:
      // Helper is fine; the engine is simply idle. The engine no longer
      // auto-starts at launch (#286), so the normal no-model / "Load default?"
      // gate owns this — not the helper overlay.
      return .hidden
    case .reconnecting, .repairing, .repairCoolingDown:
      // Helper is coming up or being repaired → bounded wait. `.reconnecting`
      // is included so app start shows the wait IMMEDIATELY rather than an
      // inert missing-helper chat for the first transient window.
      return .startingHelper
    case .unreachable:
      return .unreachable
    }
  }
}
