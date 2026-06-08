import Foundation
import Combine
import os

/// `@MainActor ObservableObject` that owns the App-side helper-restart ladder
/// (#412). It folds the stream of `engineStatus()` poll outcomes (fed from
/// `EngineStatusStore.onPollOutcome`) through the pure `HelperHealthReducer`,
/// runs the runtime registration repair when the reducer asks, and publishes
/// the resulting `HelperHealth` so the toolbar ring + the escalation banner
/// can render it.
///
/// The repair itself is injected as a closure (`() async -> Bool`) so the
/// controller carries NO `ServiceManagement` dependency and stays in
/// RatioThinkCore, unit-tested with a fake repair. The App wraps
/// `HelperRegistrationRepair.repairAndReportReachable` (and substitutes a
/// no-op in a test launch so a GUI run never mutates the real machine's
/// background-item registration).
@MainActor
public final class HelperHealthController: ObservableObject {
  /// The App's current view of the background Helper. Drives the toolbar
  /// helper-ring and the escalation banner. `@Published` and change-guarded
  /// so a healthy 1 Hz poll stream does not re-render observers every tick.
  @Published public private(set) var health: HelperHealth = .healthy

  private let policy: HelperHealthPolicy
  private let repair: () async -> Bool
  /// In-flight repair. The reducer transitions to `.repairing` and THIS task
  /// owns the matching `repairFinished` event; a new repair / a recovery
  /// cancels it so attempts never overlap.
  private var repairTask: Task<Void, Never>?
  /// Whether a chat / tree-of-thought generation is currently streaming
  /// (mirrors `ChatSendController.isInFlight`, wired from the chat view). While
  /// true, a FAILED `engineStatus()` poll is held rather than advanced through
  /// the ladder — see `ingestPollOutcome`.
  private var isGenerating = false
  /// Failed polls absorbed by the generation gate this stream. Logged once on
  /// release so a run shows the ladder was held (not silently disabled).
  private var heldPollsDuringGeneration = 0
  private nonisolated static let log = Logger(subsystem: "com.ratiothink.app", category: "helper-health")

  public init(policy: HelperHealthPolicy = HelperHealthPolicy(),
              repair: @escaping () async -> Bool) {
    self.policy = policy
    self.repair = repair
  }

  /// Feed one background `engineStatus()` poll outcome (true = the XPC call
  /// returned a value; false = it threw a transport error). Wired from
  /// `EngineStatusStore.onPollOutcome`.
  ///
  /// #413 root cause: the helper-restart ladder treats a FAILED poll as the
  /// helper being unreachable. But a failed poll is most often an XPC reply
  /// *timeout*, which means the helper was too busy to answer within the 2 s
  /// reply window — NOT that it is dead. A long tree-of-thought search
  /// saturates the poll path (the live tree floods the MainActor that receives
  /// the XPC reply, and/or the helper drains a busy engine's output), so ~12
  /// consecutive polls time out, the ladder crosses `transientThreshold`, and
  /// its registration reconcile (`unregister()` + `register()`) bounces the
  /// Helper — killing the in-flight engine and closing the SSE with no
  /// terminal frame (the operator's "engine closed the connection" at ~58 s).
  ///
  /// Fix: while a generation is streaming, HOLD failed polls instead of
  /// advancing the ladder. A busy helper is not a dead one. Genuine death is
  /// still caught — the Helper-side liveness monitor detects real engine-
  /// process exit independently, and a Helper that truly dies drops the
  /// stream's connection, which ENDS the generation and releases this gate, so
  /// the next failed poll advances the ladder normally. A SUCCEEDED poll always
  /// recovers, even mid-generation.
  public func ingestPollOutcome(succeeded: Bool) {
    if !succeeded, isGenerating {
      heldPollsDuringGeneration += 1
      return
    }
    apply(succeeded ? .pollSucceeded : .pollFailed)
  }

  /// Open/close the generation gate (wired from `ChatSendController.isInFlight`
  /// via the chat view). While open, failed polls are held — see
  /// `ingestPollOutcome`. Toggling it does not itself touch the ladder, so a
  /// helper that recovered on its own during the stream stays `.healthy`.
  public func setGenerating(_ active: Bool) {
    guard active != isGenerating else { return }
    if !active, heldPollsDuringGeneration > 0 {
      // One summary breadcrumb per stream: proof the ladder was held (and how
      // many busy-timeouts it absorbed) instead of bouncing the engine.
      Diag.app.event("helper.health", [
        ("state", "busy_hold_released"),
        ("held", String(heldPollsDuringGeneration)),
      ])
      heldPollsDuringGeneration = 0
    }
    isGenerating = active
  }

  /// User-triggered "Restart helper" from the escalation surface. Resets the
  /// ladder and fires a fresh repair attempt regardless of current state.
  public func restartHelperManually() {
    Self.log.notice("user requested Restart Helper")
    apply(.manualRestart)
  }

  private func apply(_ event: HelperHealthEvent) {
    let (next, action) = HelperHealthReducer.reduce(health, event, policy: policy)
    if next != health { health = next }
    // A reachable helper makes any in-flight repair moot — drop it so a stale
    // `repairFinished(reachable: false)` can't drag a recovered helper down
    // (the reducer also ignores that stale event, but cancelling is tidier
    // and frees the probe early).
    if case .healthy = next {
      repairTask?.cancel()
      repairTask = nil
    }
    perform(action)
  }

  private func perform(_ action: HelperHealthAction) {
    switch action {
    case .none:
      break
    case .recovered:
      Self.log.notice("helper recovered → healthy")
      Diag.app.event("helper.health", [("state", "recovered")])
    case .escalate:
      Self.log.error("helper unreachable — repair ladder exhausted; surfacing escalation")
      Diag.app.event("helper.health", [("state", "unreachable")])
    case .startRepair(let attempt):
      startRepair(attempt: attempt)
    }
  }

  private func startRepair(attempt: Int) {
    repairTask?.cancel()
    Self.log.notice("helper runtime repair attempt \(attempt, privacy: .public)")
    Diag.app.event("helper.health", [("state", "repairing"), ("attempt", String(attempt))])
    let repair = self.repair
    repairTask = Task { [weak self] in
      let reachable = await repair()
      if Task.isCancelled { return }
      self?.apply(.repairFinished(reachable: reachable))
    }
  }

  // MARK: - Test seams

  /// Await the in-flight repair so a test can deterministically observe the
  /// post-repair transition without polling the clock.
  internal func awaitRepairForTesting() async {
    await repairTask?.value
  }
}
