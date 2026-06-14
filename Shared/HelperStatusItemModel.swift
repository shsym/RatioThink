import Foundation

/// Pure-data projection of `EngineStatus` onto the helper menu-bar
/// status item. Lives in RatioThinkCore (no AppKit) so RatioThinkCoreTests can pin
/// the state→UI mapping without instantiating an `NSStatusBar` —
/// matches the `HelperDegradedSurface` testability pattern.
///
/// The view (HelperMain) renders the model into AppKit:
///   · `dot` → brand triangle glyph (fill + error badge) + tint color
///   · `engineLabel` → disabled menu item title (the
///     "current model/profile/port" slot from Phase 2.3)
///   · `pauseResume.{title,enabled,action}` → toggle menu item
///
/// Degraded mode is NOT modeled here. `setupStatusItemIfNeeded` keeps
/// its existing `degradedReason != nil → setupDegradedStatusItem`
/// short-circuit so a helper that cannot reach its state directory
/// never publishes a green dot through the supervisor pipeline.
public struct HelperStatusItemModel: Equatable, Sendable {

  /// Semantic dot state. The view (HelperMain) renders the brand mark —
  /// a rounded down-pointing triangle (the app-icon glyph, #424) — and
  /// maps `Dot` to its AppKit template mask. The SHAPE decisions (filled
  /// vs outline, error badge, motion) live here so they are testable
  /// without an `NSStatusBar` (#396/#424).
  public enum Dot: String, Equatable, Sendable {
    /// Outline triangle, dim grey. Supervisor is `.stopped`.
    case stopped
    /// Outline triangle, white, pulsing. Supervisor is `.starting` or
    /// `.stopping` — transitional, not yet steady-state.
    case loading
    /// Filled triangle, green. Supervisor is `.running`.
    case running
    /// Filled triangle with an exclamation knockout, amber. Supervisor
    /// is `.failed`.
    case error

    /// Whether the brand triangle is rendered as a filled mask (`true`) or a
    /// thick rounded OUTLINE (`false`). Outline = idle/working
    /// (stopped, loading); filled = steady engine presence (running,
    /// error). Running's renderer additionally knocks out the center so the
    /// native menu-bar mark stays hollow-centered rather than blob-solid.
    /// This fill difference — not tint — is what distinguishes
    /// `.loading` from `.running` without color, the #396 invariant
    /// (the old amber-vs-green pair was an "ambiguous dot"
    /// accessibility gap).
    public var isFilled: Bool {
      switch self {
      case .stopped, .loading: return false
      case .running, .error:   return true
      }
    }

    /// Whether an exclamation mark is knocked out of the filled triangle.
    /// Only `.error` carries it — this badge (a shape cue, not just the
    /// amber tint) is what distinguishes `.error` from `.running`
    /// without color (#396 invariant); the filled triangle plus
    /// the "!" reads as the universal warning sign.
    public var showsErrorBadge: Bool { self == .error }

    /// Whether the view should drive a repeating animation on the dot.
    /// Only the transitional `.loading` state (engine starting/stopping)
    /// is an in-flight async operation, so only it animates — a running
    /// async op is never represented solely by a *static* colored dot
    /// (#396 invariant 1). Steady states (stopped/running/error) hold
    /// still.
    public var isAnimated: Bool { self == .loading }

    /// Human-readable engine state for the menu-bar button's
    /// accessibility label (#424 acceptance: AX describes the app AND
    /// current status). The view composes "Rational engine <word>".
    ///
    /// `.loading` is deliberately SUB-STATE-NEUTRAL ("changing state"):
    /// it collapses BOTH `.starting` and `.stopping` into one visual state
    /// (white outline + pulse), and this word is the only channel that
    /// could distinguish them on the status button — so it must not claim
    /// a direction (announcing "starting" during a stop would be wrong).
    /// The precise sub-state still rides the menu's `engineLabel`
    /// ("Engine: stopping…").
    public var accessibilityWord: String {
      switch self {
      case .stopped: return "stopped"
      case .loading: return "changing state"
      case .running: return "running"
      case .error:   return "failed"
      }
    }
  }

  /// Pause/Resume toggle. The supervisor has one canonical
  /// transition pair — `.start(spec)` and `.stop()` — so the menu
  /// item morphs label + action based on which one is meaningful in
  /// the current state.
  public struct PauseResume: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
      /// Calls `supervisor.stop()`.
      case pause
      /// Calls `supervisor.start(spec)`. Disabled until 
      /// wires `ProfileStore` into `HelperExportedAPI` — the helper
      /// has no LaunchSpec resolver yet, so a "Resume" with no
      /// profile would silently no-op.
      case resume
      /// Transitional state (e.g. `.stopping`) — nothing to do.
      case none
    }
    public var title: String
    public var enabled: Bool
    public var action: Action
  }

  public var dot: Dot
  /// Single disabled label that absorbs "Engine: stopped" plus the
  /// Phase 2.3 "current model/profile/port" slot. Folded into one
  /// item so the S4 GUI test's `Engine: stopped` assertion keeps
  /// holding; running state appends profile + port.
  public var engineLabel: String
  public var pauseResume: PauseResume

  public init(dot: Dot, engineLabel: String, pauseResume: PauseResume) {
    self.dot = dot
    self.engineLabel = engineLabel
    self.pauseResume = pauseResume
  }

  /// Build the model from a live `EngineStatus`. Pure function — no
  /// AppKit, no logging side effects.
  public static func make(from status: EngineStatus) -> HelperStatusItemModel {
    switch status {
    case .stopped:
      return HelperStatusItemModel(
        dot: .stopped,
        engineLabel: "Engine: stopped",
        // ProfileStore + LaunchSpec resolver are now wired,
        // so Resume is actionable: HelperResumeAction.run resolves the
        // active profile and starts the engine. It is internally
        // nil-safe (returns .resolverMissing / .noActiveProfile and logs
        // rather than crashing) on a degraded boot, so enabling here
        // cannot fire into a nil resolver. Leaving it disabled stranded
        // the engine "stopped" with no way to start it, so every model
        // load deferred forever on engineNotReady ( follow-up).
        pauseResume: PauseResume(title: "Resume Engine",
                                 enabled: true,
                                 action: .resume)
      )
    case .starting:
      return HelperStatusItemModel(
        dot: .loading,
        engineLabel: "Engine: starting…",
        pauseResume: PauseResume(title: "Pause Engine",
                                 enabled: true,
                                 action: .pause)
      )
    case .running(let snapshot):
      return HelperStatusItemModel(
        dot: .running,
        engineLabel: "Engine: running — \(snapshot.profileID) @ port \(snapshot.port)",
        pauseResume: PauseResume(title: "Pause Engine",
                                 enabled: true,
                                 action: .pause)
      )
    case .stopping:
      return HelperStatusItemModel(
        dot: .loading,
        engineLabel: "Engine: stopping…",
        pauseResume: PauseResume(title: "Pause Engine",
                                 enabled: false,
                                 action: .none)
      )
    case .failed(let code, let message):
      // #477: the menu line is user copy — render the taxonomy's curated
      // message, not the raw status diagnostic (its durable sinks are
      // helper.log / DiagnosticLog at the producers). The `failed (code)`
      // prefix stays: it is the menu's operator discriminator and the
      // S4 GUI suite keys on it. Truncation guards menu width — the wire
      // already caps the payload at `EngineStatus.failedMessageCap`.
      let problem = EngineProblem(statusCode: code, rawMessage: message)
      let trimmed = HelperStatusItemModel.truncate(problem.message, to: 120)
      return HelperStatusItemModel(
        dot: .error,
        engineLabel: "Engine: failed (\(code.rawValue)) — \(trimmed)",
        // Resume is enabled for recoverable failures so the user can fix
        // the underlying cause (e.g. download a `modelMissing` model)
        // and retry, instead of being stranded with the engine failed.
        // `memoryRisk` / `killRejected` stay disabled — a blind retry of
        // the same action re-fails or is unsafe (see
        // `EngineErrorCode.invitesResumeRetry` + test_memoryRiskFailure).
        pauseResume: PauseResume(title: "Resume Engine",
                                 enabled: code.invitesResumeRetry,
                                 action: .resume)
      )
    }
  }

  /// Bounded-width truncation for menu-item labels. Walks character
  /// boundaries so a multi-byte glyph never gets sliced in half.
  static func truncate(_ s: String, to maxChars: Int) -> String {
    guard s.count > maxChars else { return s }
    let prefix = s.prefix(maxChars)
    return prefix + "…"
  }
}
