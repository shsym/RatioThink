import Foundation

/// The App's view of the background **Helper process**, derived from the
/// SEQUENCE of `engineStatus()` poll outcomes — NOT from `EngineStatus`.
///
/// `EngineStatus` is what a *live* helper reports about the engine; a dead
/// or unreachable helper reports nothing, so its own death can never appear
/// as an `EngineStatus` case. Helper-health is therefore a separate,
/// App-side-derived axis: it answers "can the App reach the helper at all",
/// orthogonal to "what is the engine doing".
///
/// Single-clock design (#412): every transition is driven by a 1 Hz poll
/// outcome (`pollSucceeded` / `pollFailed`), plus the async repair
/// completion (`repairFinished`) and the user's `manualRestart`. There is no
/// second backoff timer — the gap between repair attempts is counted in
/// failed polls (`HelperHealthPolicy.repairGap`), so the whole ladder is a
/// deterministic function of the poll stream and is exhaustively unit-tested
/// without XPC or SwiftUI. Mirrors `PieEngineHost.RelaunchPolicy`, the
/// Helper-side engine-death ladder this complements.
public enum HelperHealth: Equatable, Sendable {
  /// A recent poll succeeded — the helper is reachable.
  case healthy
  /// `1 ..< transientThreshold` consecutive failed polls. Transient:
  /// launchd's `KeepAlive` respawn (~0.15s), an on-demand mach-service
  /// relaunch, or a respawn-throttle window (~10s) is expected to self-heal.
  /// Calm UI ("Reconnecting…") — never the loud escalation.
  case reconnecting(consecutiveFailures: Int)
  /// A runtime registration repair (reconcile: probe → `unregister()` +
  /// `register()`) is in flight for `attempt`. Amber UI.
  case repairing(attempt: Int)
  /// Between repair attempts: the last reconcile did not restore
  /// reachability, and we wait `repairGap` more failed polls before the next
  /// attempt (poll-cadence backoff).
  case repairCoolingDown(attempt: Int, failuresSinceRepair: Int)
  /// The repair ladder is exhausted and the helper is still unreachable.
  /// Loud, actionable escalation (in-window banner + red). Terminal until a
  /// poll succeeds (recovered) or the user triggers a manual restart.
  case unreachable
}

/// Bounded App-side helper-restart ladder, mirroring
/// `PieEngineHost.RelaunchPolicy` (the Helper-side engine ladder).
public struct HelperHealthPolicy: Equatable, Sendable {
  /// Consecutive failed polls before the FIRST repair fires. Default 12
  /// (~12s @1Hz): longer than launchd's ~10s respawn-throttle window so the
  /// App does not fight launchd's own self-heal with a redundant
  /// `unregister()`+`register()`. (#320 measured: unclean respawn ~0.15s,
  /// throttle defers up to ~10s.)
  public var transientThreshold: Int
  /// Max runtime repair attempts before escalating to `.unreachable`. `0`
  /// disables auto-repair (escalate immediately past the transient window).
  public var maxRepairAttempts: Int
  /// Failed polls to wait between repair attempts (poll-cadence backoff).
  public var repairGap: Int

  public init(transientThreshold: Int = 12,
              maxRepairAttempts: Int = 2,
              repairGap: Int = 5) {
    self.transientThreshold = max(1, transientThreshold)
    self.maxRepairAttempts = max(0, maxRepairAttempts)
    self.repairGap = max(1, repairGap)
  }
}

/// Worst-case duration of ONE reconcile reachability probe
/// (`HelperRegistrationRepair.probeHelperReachable`). Single source of truth,
/// in RatioThinkCore so BOTH the App-side probe (which can't be referenced
/// from Core) AND the Core-side chat-recovery ceiling derive from the same
/// numbers — there is no second place to drift (#412 re-F1). The probe lives
/// in the App target; only its TIMING BUDGET is policy and lives here.
public enum HelperReconcileProbeBudget {
  /// Reachability poll attempts per probe.
  public static let attempts = 8
  /// Backoff between attempts.
  public static let delaySeconds: TimeInterval = 0.6
  /// Worst-case probe wall time (`attempts × delaySeconds`). The XPC call
  /// itself fails fast when the helper is down, so the delays dominate.
  public static var seconds: TimeInterval { Double(attempts) * delaySeconds }
}

/// Inputs to `HelperHealthReducer`.
public enum HelperHealthEvent: Equatable, Sendable {
  /// A background `engineStatus()` poll returned a value (helper reachable).
  case pollSucceeded
  /// A background `engineStatus()` poll threw a transport error.
  case pollFailed
  /// An in-flight repair finished; `reachable` = did the helper answer after.
  case repairFinished(reachable: Bool)
  /// The user pressed "Restart helper" on the escalation surface.
  case manualRestart
}

/// Side-effect the controller must perform after a transition. Kept as data
/// (not a closure) so the reducer stays pure and the controller owns all I/O.
public enum HelperHealthAction: Equatable, Sendable {
  case none
  /// Run a registration repair (reconcile) for this attempt number.
  case startRepair(attempt: Int)
  /// Publish the loud escalation (banner + red dot).
  case escalate
  /// Helper came back — clear any escalation UI.
  case recovered
}

/// Pure reducer: folds `(state, event) → (next state, action)`. Deterministic
/// and exhaustive so the entire helper-restart ladder is unit-tested without
/// XPC or SwiftUI.
public enum HelperHealthReducer {
  public static func reduce(
    _ state: HelperHealth,
    _ event: HelperHealthEvent,
    policy: HelperHealthPolicy
  ) -> (HelperHealth, HelperHealthAction) {
    switch event {
    case .pollSucceeded:
      // Any reachable poll is recovery. Emit `.recovered` only when LEAVING a
      // non-healthy state so the controller doesn't re-clear the UI every
      // healthy tick. A single success returns to `.healthy` (mirrors
      // `PieEngineHost`'s "one `.alive` resets the counter") — if instability
      // flaps, the next failure simply restarts `reconnecting`.
      if case .healthy = state { return (.healthy, .none) }
      return (.healthy, .recovered)

    case .manualRestart:
      // User forced a restart from the escalation surface — jump straight to
      // attempt 1 regardless of current state. With auto-repair disabled the
      // only honest response is to (re-)escalate.
      guard policy.maxRepairAttempts > 0 else { return (.unreachable, .escalate) }
      return (.repairing(attempt: 1), .startRepair(attempt: 1))

    case .repairFinished(let reachable):
      if reachable { return (.healthy, .recovered) }
      // A failed attempt only advances the ladder when it matches the
      // in-flight `.repairing` state; a completion that arrives after a live
      // poll already recovered (state moved off `.repairing`) is stale and
      // must not drag a healthy helper back down.
      guard case .repairing(let attempt) = state else { return (state, .none) }
      if attempt >= policy.maxRepairAttempts { return (.unreachable, .escalate) }
      return (.repairCoolingDown(attempt: attempt, failuresSinceRepair: 0), .none)

    case .pollFailed:
      return reducePollFailed(state, policy: policy)
    }
  }

  private static func reducePollFailed(
    _ state: HelperHealth,
    policy: HelperHealthPolicy
  ) -> (HelperHealth, HelperHealthAction) {
    switch state {
    case .healthy:
      return advanceReconnecting(consecutiveFailures: 1, policy: policy)
    case .reconnecting(let n):
      return advanceReconnecting(consecutiveFailures: n + 1, policy: policy)
    case .repairing:
      // Reconcile still in flight — keep waiting for `repairFinished`; failed
      // polls during the attempt are expected and must not double-fire.
      return (state, .none)
    case .repairCoolingDown(let attempt, let k):
      let next = k + 1
      guard next >= policy.repairGap else {
        return (.repairCoolingDown(attempt: attempt, failuresSinceRepair: next), .none)
      }
      let nextAttempt = attempt + 1
      return (.repairing(attempt: nextAttempt), .startRepair(attempt: nextAttempt))
    case .unreachable:
      return (.unreachable, .none)
    }
  }

  private static func advanceReconnecting(
    consecutiveFailures n: Int,
    policy: HelperHealthPolicy
  ) -> (HelperHealth, HelperHealthAction) {
    guard n >= policy.transientThreshold else {
      return (.reconnecting(consecutiveFailures: n), .none)
    }
    // Crossed the transient window → first repair (or escalate if disabled).
    guard policy.maxRepairAttempts > 0 else { return (.unreachable, .escalate) }
    return (.repairing(attempt: 1), .startRepair(attempt: 1))
  }
}
