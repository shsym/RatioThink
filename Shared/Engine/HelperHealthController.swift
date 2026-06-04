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
  private nonisolated static let log = Logger(subsystem: "com.ratiothink.app", category: "helper-health")

  public init(policy: HelperHealthPolicy = HelperHealthPolicy(),
              repair: @escaping () async -> Bool) {
    self.policy = policy
    self.repair = repair
  }

  /// Feed one background `engineStatus()` poll outcome (true = the XPC call
  /// returned a value; false = it threw a transport error). Wired from
  /// `EngineStatusStore.onPollOutcome`.
  public func ingestPollOutcome(succeeded: Bool) {
    apply(succeeded ? .pollSucceeded : .pollFailed)
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
