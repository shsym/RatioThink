import Foundation
import ServiceManagement

/// App-side helper-registration repair primitive (#412).
///
/// Wraps a `LoginItemRegistering` + a bounded reachability probe into a
/// `HelperRegistrationReconciler` so the probe → `unregister()` +
/// `register()` reconcile runs from EVERY path that needs it, not just app
/// launch:
///   · the launch-time self-heal (`RatioThinkApp.reconcileHelperRegistrationIfNeeded`),
///   · the runtime `HelperHealthController` restart ladder, and
///   · the user's "Restart helper" escalation action.
///
/// Before #412 the reconcile was inlined in `RatioThinkApp` and ran ONCE at
/// launch, so a Helper that became unreachable at runtime (a launchd job
/// launchd's own KeepAlive could not self-heal — e.g. a stale job after an
/// in-place bundle replacement) needed a full app restart to recover. This
/// type is that same wiring, made callable on demand.
struct HelperRegistrationRepair {
  /// Builds the registrar per call — the `SMAppService.agent` handle is
  /// cheap and stateless. Injected so tests supply `EnvironmentLoginItemRegistrar`
  /// instead of mutating the real machine's background-item registration.
  private let makeRegistrar: @Sendable () -> LoginItemRegistering
  /// One bounded compatibility probe (a helper protocol-version poll with
  /// retry/backoff). Injected so tests don't open a real XPC connection.
  /// A merely reachable old helper is not enough after app upgrades that add
  /// required selectors such as `restartEngine(profileID:)`.
  private let probeReachable: @Sendable () async -> Bool

  init(
    makeRegistrar: @escaping @Sendable () -> LoginItemRegistering = { LoginItemRegistrarFactory.make() },
    probeReachable: @escaping @Sendable () async -> Bool = { await HelperRegistrationRepair.probeHelperReachable() }
  ) {
    self.makeRegistrar = makeRegistrar
    self.probeReachable = probeReachable
  }

  /// Run one reconcile pass. Probes first; repairs (unregister+register) only
  /// when the Helper is unreachable or protocol-incompatible, leaving a
  /// healthy/current background service untouched. The decision table lives in
  /// the pure `HelperRegistrationReconciler`.
  func reconcile() async -> HelperRegistrationReconciler.Outcome {
    let registrar = makeRegistrar()
    let reconciler = HelperRegistrationReconciler(
      probeReachable: probeReachable,
      currentState: { registrar.status.reconcilerState },
      register: { try registrar.register().reconcilerState },
      unregister: { try registrar.unregister() }
    )
    return await reconciler.reconcile()
  }

  /// The `HelperHealthController.repair` seam: run a reconcile and report
  /// whether the Helper is reachable afterwards. A `.needsApproval` outcome
  /// additionally opens System Settings → Login Items (the only path that
  /// clears the macOS consent gate) and reports NOT reachable, so the ladder
  /// escalates rather than treating the gated helper as recovered.
  @MainActor
  func repairAndReportReachable() async -> Bool {
    let outcome = await reconcile()
    Diag.app.event("helper.runtime_repair", [("outcome", "\(outcome)")])
    if outcome.requiresUserApproval {
      SMAppService.openSystemSettingsLoginItems()
    }
    return outcome.helperReachable
  }

  /// Default bounded compatibility probe: a `helperProtocolVersion()` poll
  /// retried over ~5s so a just-(re)launched on-demand Helper has time to
  /// publish its mach service. This intentionally checks a capability/version
  /// selector instead of only `engineStatus()`: after an app update, a previous
  /// build's helper can still answer `engineStatus` while lacking newly-required
  /// selectors such as strict `restartEngine(profileID:)`.
  /// Defaults come from `HelperReconcileProbeBudget` (RatioThinkCore) so the
  /// probe's wall time and the chat-recovery ceiling that depends on it share
  /// ONE definition and cannot drift (#412 re-F1).
  static func probeHelperReachable(
    attempts: Int = HelperReconcileProbeBudget.attempts,
    delayMilliseconds: UInt64 = UInt64(HelperReconcileProbeBudget.delaySeconds * 1000)
  ) async -> Bool {
    let client = HelperXPCClient()
    for attempt in 0..<attempts {
      if await HelperProtocolCompatibility.isCompatible(client: client) { return true }
      if attempt < attempts - 1 {
        try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
      }
    }
    return false
  }
}
