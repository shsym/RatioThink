import XCTest
@testable import RatioThinkCore

/// Pins the launch-time Helper registration self-heal decision logic
/// ( robustness). The reconciler must (a) never disturb a healthy
/// Helper, (b) force unregister→register only when an `.enabled` status
/// is stale (Helper unreachable), (c) register fresh when not
/// registered, and (d) surface `.requiresApproval` without claiming
/// success.
final class HelperRegistrationReconcilerTests: XCTestCase {

  /// Records calls + scripts probe results so each decision branch is
  /// deterministic. `@unchecked Sendable`: XCTest runs serially and the
  /// reconciler awaits each closure in order, so the unsynchronized
  /// mutation is safe here.
  private final class Harness: @unchecked Sendable {
    var probeResults: [HelperRegistrationProbeResult]
    var state: HelperRegistrationState
    var registerResult: HelperRegistrationState
    var registerError: Error?
    var unregisterError: Error?

    private(set) var probeCalls = 0
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(probeResults: [HelperRegistrationProbeResult],
         state: HelperRegistrationState,
         registerResult: HelperRegistrationState = .enabled,
         registerError: Error? = nil,
         unregisterError: Error? = nil) {
      self.probeResults = probeResults
      self.state = state
      self.registerResult = registerResult
      self.registerError = registerError
      self.unregisterError = unregisterError
    }

    func makeReconciler() -> HelperRegistrationReconciler {
      HelperRegistrationReconciler(
        probeReachable: { [self] in
          probeCalls += 1
          return probeResults.isEmpty ? .unreachable : probeResults.removeFirst()
        },
        currentState: { [self] in state },
        register: { [self] in
          registerCalls += 1
          if let registerError { throw registerError }
          return registerResult
        },
        unregister: { [self] in
          unregisterCalls += 1
          if let unregisterError { throw unregisterError }
        }
      )
    }
  }

  private struct StubError: Error {}

  // MARK: - F1: test-launch guard (no real SMAppService mutation)

  func test_isTestLaunch_true_for_each_test_seam() {
    let seams: [[String: String]] = [
      ["PIE_TEST_LOGIN_ITEM_STATUS": "enabled"],
      ["PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:9"],
      ["PIE_APP_PREFERENCES_SUITE": "test.suite"],     // every GUI test sets this
      ["PIE_TEST_FAKE_DOWNLOADS": "1"],
      ["PIE_TEST_FIRST_LAUNCH_COMPLETED": "1"],          // GUI configureCompletedFirstLaunch
      ["PIE_TEST_SKIP_HELPER_RECONCILE": "1"],
      // #412: the app code runs IN-PROCESS inside a unit-test host, where
      // XCTest sets this — must suppress SMAppService side effects + the
      // runtime helper-restart ladder so a plain `xcodebuild test` never
      // mutates the machine's background-item registration.
      ["XCTestConfigurationFilePath": "/tmp/Foo.xctestconfiguration"],
    ]
    for env in seams {
      XCTAssertTrue(HelperRegistrationReconciler.isTestLaunch(env),
                    "must treat \(env.keys.first!) as a test launch (no SMAppService side effects)")
    }
  }

  func test_isTestLaunch_false_for_production_env() {
    XCTAssertFalse(HelperRegistrationReconciler.isTestLaunch([:]))
    XCTAssertFalse(HelperRegistrationReconciler.isTestLaunch(["HOME": "/Users/x", "PATH": "/usr/bin"]))
    // Empty values must not count as set.
    XCTAssertFalse(HelperRegistrationReconciler.isTestLaunch(["PIE_APP_PREFERENCES_SUITE": ""]))
    XCTAssertFalse(HelperRegistrationReconciler.isTestLaunch(["PIE_TEST_FIRST_LAUNCH_COMPLETED": "0"]))
  }

  func test_healthyHelper_isLeftUntouched() async {
    let h = Harness(probeResults: [.healthy], state: .enabled)
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .healthy)
    XCTAssertEqual(h.probeCalls, 1)
    XCTAssertEqual(h.registerCalls, 0, "a reachable Helper must not be re-registered")
    XCTAssertEqual(h.unregisterCalls, 0, "a reachable Helper must not be unregistered")
  }

  func test_reachableButWrongHelperIdentity_forcesUnregisterThenRegister() async {
    // Upgrade/rename blocker: an old RatioThinkHelper can still answer on the
    // preserved com.ratiothink.helper mach service. Reachability alone must
    // not be treated as healthy; mismatched identity must force a launchd
    // reload so the registered job points at RationalHelper.
    let h = Harness(probeResults: [.identityMismatch("executable=RatioThinkHelper"), .healthy],
                    state: .enabled,
                    registerResult: .enabled)
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(h.unregisterCalls, 1, "wrong-but-reachable Helper must be unregistered")
    XCTAssertEqual(h.registerCalls, 1, "wrong-but-reachable Helper must be registered again")
    XCTAssertEqual(h.probeCalls, 2, "repair must re-probe and confirm the expected Helper identity")
  }

  func test_enabledButUnreachable_forcesUnregisterThenRegister() async {
    // The stale-after-update case: BTM enabled, Helper unreachable, then
    // reachable once the job is reloaded.
    let h = Harness(probeResults: [.unreachable, .healthy], state: .enabled, registerResult: .enabled)
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(h.unregisterCalls, 1, "must force a reload via unregister")
    XCTAssertEqual(h.registerCalls, 1)
  }

  func test_notRegistered_registersFresh() async {
    let h = Harness(probeResults: [.unreachable, .healthy], state: .notRegistered, registerResult: .enabled)
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .registered)
    XCTAssertEqual(h.unregisterCalls, 0, "fresh registration must not unregister first")
    XCTAssertEqual(h.registerCalls, 1)
  }

  func test_requiresApproval_surfacedNotClaimedHealthy() async {
    let h = Harness(probeResults: [.unreachable], state: .requiresApproval)
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .needsApproval)
  }

  func test_registerReportsRequiresApproval_surfacesNeedsApproval() async {
    // register() itself can land in requiresApproval after a code change.
    let h = Harness(probeResults: [.unreachable], state: .enabled, registerResult: .requiresApproval)
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .needsApproval)
  }

  func test_registerSucceedsButStillUnreachable_reportsRepairFailed() async {
    let h = Harness(probeResults: [.unreachable, .unreachable], state: .enabled, registerResult: .enabled)
    let outcome = await h.makeReconciler().reconcile()
    guard case .repairFailed = outcome else {
      return XCTFail("expected .repairFailed, got \(outcome)")
    }
  }

  func test_registerSucceedsButStillWrongIdentity_reportsIdentityMismatch() async {
    let h = Harness(probeResults: [.identityMismatch("executable=RatioThinkHelper"),
                                   .identityMismatch("executable=RatioThinkHelper")],
                    state: .enabled,
                    registerResult: .enabled)
    let outcome = await h.makeReconciler().reconcile()
    guard case let .repairFailed(msg) = outcome else {
      return XCTFail("expected .repairFailed, got \(outcome)")
    }
    XCTAssertTrue(msg.contains("identity mismatch after register"),
                  "repair failure must distinguish wrong identity from unreachable; got: \(msg)")
    XCTAssertTrue(msg.contains("executable=RatioThinkHelper"),
                  "repair failure must preserve identity evidence; got: \(msg)")
    XCTAssertFalse(msg.contains("helper unreachable after register"),
                   "wrong-but-reachable helper must not be reported as unreachable; got: \(msg)")
  }

  func test_registerThrows_reportsRepairFailed() async {
    let h = Harness(probeResults: [.unreachable], state: .notRegistered, registerError: StubError())
    let outcome = await h.makeReconciler().reconcile()
    guard case .repairFailed = outcome else {
      return XCTFail("expected .repairFailed, got \(outcome)")
    }
  }

  func test_unregisterThrows_andRepairFails_surfacesUnregisterError() async {
    // F3: when unregister() throws AND the repair never recovers, the
    // failure must name the unregister error (the root operation), not
    // just "unreachable after register".
    struct NamedError: Error, CustomStringConvertible { var description = "boom-unregister-42" }
    let h = Harness(probeResults: [.unreachable, .unreachable], state: .enabled,
                    registerResult: .enabled, unregisterError: NamedError())
    let outcome = await h.makeReconciler().reconcile()
    guard case let .repairFailed(msg) = outcome else {
      return XCTFail("expected .repairFailed, got \(outcome)")
    }
    XCTAssertTrue(msg.contains("boom-unregister-42"),
                  "repairFailed must surface the unregister root cause; got: \(msg)")
  }

  func test_unregisterThrowsButRegisterRecovers_stillRepairs() async {
    // unregister() throwing (item already gone) is benign — register still runs.
    let h = Harness(probeResults: [.unreachable, .healthy], state: .enabled,
                    registerResult: .enabled, unregisterError: StubError())
    let outcome = await h.makeReconciler().reconcile()
    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(h.registerCalls, 1)
  }

  // MARK: - Outcome → reachable mapping (#412, runtime repair ladder)

  func test_outcome_helperReachable_mapping() {
    // The signal HelperHealthController feeds back as repairFinished(reachable:).
    XCTAssertTrue(HelperRegistrationReconciler.Outcome.healthy.helperReachable)
    XCTAssertTrue(HelperRegistrationReconciler.Outcome.repaired.helperReachable)
    XCTAssertTrue(HelperRegistrationReconciler.Outcome.registered.helperReachable)
    XCTAssertFalse(HelperRegistrationReconciler.Outcome.needsApproval.helperReachable,
                   "needsApproval is a user-consent gate, NOT a recovered helper — the ladder must escalate")
    XCTAssertFalse(HelperRegistrationReconciler.Outcome.repairFailed("x").helperReachable)
  }

  func test_outcome_requiresUserApproval_only_for_needsApproval() {
    XCTAssertTrue(HelperRegistrationReconciler.Outcome.needsApproval.requiresUserApproval)
    for o: HelperRegistrationReconciler.Outcome in [.healthy, .repaired, .registered, .repairFailed("x")] {
      XCTAssertFalse(o.requiresUserApproval, "\(o) must not route to System Settings")
    }
  }
}
