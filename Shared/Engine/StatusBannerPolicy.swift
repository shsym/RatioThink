import Foundation

/// Single source of truth for the unified engine/helper status banner's
/// poll-count thresholds. The SAME counting drives BOTH axes — the helper
/// axis (App→helper transport, `HelperHealth`) and the engine axis (a
/// reachable helper reporting `.failed(.engineGone)`) — so the two never
/// drift. Replaces `EngineStatusStore`'s former standalone ~5-poll
/// transport-loss timing.
///
/// Counts are POLLS (the App polls `engineStatus()` at 1 Hz), so at the
/// default cadence the tiers are ~15 s (calm) and ~30 s (loud).
public struct StatusTierPolicy: Equatable, Sendable {
  /// Sustained lost-contact polls, FROM a previously-healthy/running state,
  /// before the calm Tier-1 "reconnecting" banner appears. A first load
  /// (never healthy) stays Tier 0 regardless of count — it is never escalated
  /// on a timer alone.
  public var tier1Polls: Int
  /// Sustained lost-contact polls (or ladder exhaustion) before the loud
  /// Tier-2 error banner + Force Restart appears.
  public var tier2Polls: Int
  /// During a FIRST load (engine never `.running` this session, still
  /// `.starting`), hold a transient explicit `.failed(.spawnFailed /
  /// .engineGone)` for this many consecutive polls before surfacing it —
  /// so a momentary handshake mis-classification (#2) reads as Tier-0
  /// "Starting…" rather than a red flash, while a genuinely persistent
  /// failure still surfaces after the short grace.
  public var firstLoadFailureGracePolls: Int

  public init(tier1Polls: Int = 15, tier2Polls: Int = 30,
              firstLoadFailureGracePolls: Int = 5) {
    self.tier1Polls = max(1, tier1Polls)
    self.tier2Polls = max(tier1Polls + 1, tier2Polls)
    self.firstLoadFailureGracePolls = max(1, firstLoadFailureGracePolls)
  }
}

/// The three escalation tiers the unified banner renders.
public enum StatusTier: Equatable, Sendable {
  /// Silent / progress: no banner. First-load "Starting… (Ns)" lives here;
  /// the toolbar pip carries the elapsed chip.
  case silent
  /// Calm "reconnecting" — a mid-session drop from a previously-healthy
  /// state. Gray/neutral banner, source-labeled, no destructive action.
  case reconnecting
  /// Loud error — sustained loss / ladder exhausted. Red banner + a
  /// source-aware Force Restart.
  case error
}

/// Which subsystem the banner is about — drives the copy and the Force
/// Restart target so "helper unreachable" and "engine failed" never get
/// the same generic message.
public enum StatusSource: Equatable, Sendable {
  case helper
  case engine
}

/// The Force Restart action a Tier-2 banner offers (none below Tier 2).
public enum ForceRestartTarget: Equatable, Sendable {
  case none
  /// Helper unreachable → reload its launchd registration + restart it.
  case helper
  /// Engine failed but helper alive → restart the engine on the active profile.
  case engine
}

/// The rendered, source-labeled banner model. `nil` from the reducer means
/// Tier 0 (no banner). Pure value type so the whole tier/copy/action mapping
/// is unit-tested without SwiftUI.
public struct UnifiedStatusBanner: Equatable, Sendable {
  public let tier: StatusTier
  public let source: StatusSource
  public let title: String
  public let message: String
  public let forceRestart: ForceRestartTarget

  public init(tier: StatusTier, source: StatusSource, title: String,
              message: String, forceRestart: ForceRestartTarget) {
    self.tier = tier
    self.source = source
    self.title = title
    self.message = message
    self.forceRestart = forceRestart
  }
}

/// Pure unified reducer: folds the helper axis (`HelperHealth`) and the
/// engine axis (`EngineStatus` + recovery counts) into one source-labeled,
/// 3-tier banner. Helper-unreachability outranks the engine axis: a poll
/// that can't reach the helper makes its reported `EngineStatus` stale, so
/// the helper banner wins.
public enum StatusBannerReducer {
  /// - Parameters:
  ///   - engine: the helper's last reported `EngineStatus`.
  ///   - wasEverRunning: has the engine reached `.running` this session? A
  ///     first load (false) never escalates a transient/starting state.
  ///   - helper: the App-side helper transport health. Its own ladder
  ///     (`HelperHealthPolicy`) supplies the helper-axis tier boundaries;
  ///     they are mapped onto the same three tiers here so both axes read
  ///     as one banner.
  ///   - engineGonePolls: consecutive polls a reachable helper reported
  ///     `.failed(.engineGone)` (the engine-axis recovery count).
  public static func make(
    engine: EngineStatus,
    wasEverRunning: Bool,
    helper: HelperHealth,
    engineGonePolls: Int,
    policy: StatusTierPolicy = StatusTierPolicy()
  ) -> UnifiedStatusBanner? {
    // 1) Helper axis first — a helper we can't reach makes `engine` stale.
    if let banner = helperBanner(helper: helper) {
      return banner
    }
    // 2) Engine axis — helper is reachable; trust its `EngineStatus`.
    return engineBanner(engine: engine, wasEverRunning: wasEverRunning,
                        engineGonePolls: engineGonePolls, policy: policy)
  }

  // MARK: - helper axis

  /// Map the helper transport ladder onto the three tiers:
  ///   · `.healthy`                       → Tier 0 (no banner)
  ///   · `.reconnecting` (transient win)  → Tier 0 (silent; pip stays calm)
  ///   · `.repairing` / `.repairCoolingDown` (past the transient window,
  ///      actively repairing)             → Tier 1 calm "Reconnecting…"
  ///   · `.unreachable` (ladder exhausted)→ Tier 2 loud + Force Restart helper
  private static func helperBanner(helper: HelperHealth) -> UnifiedStatusBanner? {
    switch helper {
    case .healthy, .reconnecting:
      return nil
    case .repairing, .repairCoolingDown:
      return UnifiedStatusBanner(
        tier: .reconnecting, source: .helper,
        title: "Reconnecting to the helper…",
        message: "The background helper dropped; reconnecting.",
        forceRestart: .none)
    case .unreachable:
      return UnifiedStatusBanner(
        tier: .error, source: .helper,
        title: "Can’t reach the engine helper",
        message: "The background helper isn’t responding. Use Force Restart to reload it.",
        forceRestart: .helper)
    }
  }

  // MARK: - engine axis

  private static func engineBanner(
    engine: EngineStatus,
    wasEverRunning: Bool,
    engineGonePolls: Int,
    policy: StatusTierPolicy
  ) -> UnifiedStatusBanner? {
    switch engine {
    case .stopped, .running, .stopping, .starting:
      // `.starting` is Tier 0 (the pip shows "Starting… (Ns)"); the #2 hold
      // in EngineStatusStore keeps a transient explicit `.failed` AS
      // `.starting` during the first-load window, so it never reaches here.
      return nil
    case let .failed(code, message):
      // #477: banner copy comes from the shared `EngineProblem` taxonomy —
      // the status `message` is a raw diagnostic (stderr tails, resolver
      // traces) and never primary copy.
      let problem = EngineProblem(statusCode: code, rawMessage: message)
      if code == .engineGone {
        // Engine died after a good launch; the Helper-side relaunch ladder is
        // retrying. Calm "reconnecting" until the recovery count exhausts.
        let tier = tierForLostContact(lostPolls: engineGonePolls,
                                      wasEverRunning: wasEverRunning, policy: policy)
        switch tier {
        case .silent, .reconnecting:
          return UnifiedStatusBanner(
            tier: .reconnecting, source: .engine,
            title: "Engine connection lost — reconnecting…",
            message: "The engine stopped responding; reconnecting.",
            forceRestart: .none)
        case .error:
          return UnifiedStatusBanner(
            tier: .error, source: .engine,
            title: problem.title,
            message: problem.message,
            forceRestart: .engine)
        }
      }
      // Any other explicit failure (spawn / model-missing / memory-risk /
      // kill-rejected) is a real, immediate Tier-2 error — never a transient
      // reconnect. (#2's hold only defers `.spawnFailed`/`.engineGone` during
      // the first-load window, upstream in the store.) Force Restart is
      // offered only where the taxonomy says a restart is the fix — a
      // model-choice fault (missing / too-large / profile) or a refused
      // kill would not be solved by one.
      let forceRestart: ForceRestartTarget
      switch problem.recovery {
      case .restartEngine: forceRestart = .engine
      case .restartHelper: forceRestart = .helper
      default:             forceRestart = .none
      }
      return UnifiedStatusBanner(
        tier: .error, source: .engine,
        title: problem.title,
        message: problem.message,
        forceRestart: forceRestart)
    }
  }

  // MARK: - shared tiering

  /// Map a sustained lost-contact poll count to a tier under one policy.
  /// A first load (never running) is pinned to `.silent` — #1's "never red
  /// on a timer alone for a first load".
  static func tierForLostContact(
    lostPolls: Int,
    wasEverRunning: Bool,
    policy: StatusTierPolicy
  ) -> StatusTier {
    if lostPolls >= policy.tier2Polls { return .error }
    guard wasEverRunning else { return .silent }
    if lostPolls >= policy.tier1Polls { return .reconnecting }
    return .silent
  }
}
