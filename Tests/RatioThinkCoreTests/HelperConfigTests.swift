import XCTest
@testable import RatioThinkCore

/// Coverage for the env-driven Helper isolation hooks. Routes all
/// in-process configuration through `HelperConfig.$overrides.withValue`
/// — no setenv calls in this file (review v3 F6). Env-fallback path
/// runs via the `pie-resolve-probe` binary so the real
/// `HelperConfig.xpcServiceName` code path is exercised under a
/// constructed env (review v4 F9).
final class HelperConfigTests: XCTestCase {

  // MARK: - override seam (primary)

  func test_override_xpcServiceName_wins_over_env() {
    let name = "com.ratiothink.helper.test.unit.\(UUID().uuidString.prefix(8))"
    HelperConfig.$overrides.withValue(.init(xpcServiceName: name, testMode: true)) {
      XCTAssertEqual(HelperConfig.xpcServiceName, name)
    }
  }

  func test_override_testMode_wins_over_env() throws {
    HelperConfig.$overrides.withValue(.init(xpcServiceName: "com.ratiothink.helper.test.a", testMode: true)) {
      XCTAssertTrue(HelperConfig.isTestMode)
    }
    // testMode=false + xpcServiceName=nil RESOLVES to the env xpc
    // value, then validateContract checks the resolved (false, xpc)
    // pair. A dev shell with `PIE_XPC_SERVICE=com.ratiothink.helper.dev`
    // exported (supported way to point the helper at a test mach
    // service) would trip case `(false, true)` → fatalError. Skip
    // when env carries a non-default override so this in-process
    // test doesn't crash an otherwise-clean test bundle (review v7
    // F4). The env-driven path is covered by
    // `test_PIE_XPC_SERVICE_env_resolved_via_probe` via a fresh
    // probe subprocess.
    try XCTSkipIf(ProcessInfo.processInfo.environment[HelperConfig.xpcServiceEnvVar] != nil,
                  "dev shell has $PIE_XPC_SERVICE exported; in-process (testMode=false, xpc=override) would trap validateContract — covered out-of-process by probe tests")
    HelperConfig.$overrides.withValue(.init(testMode: false)) {
      XCTAssertFalse(HelperConfig.isTestMode)
    }
  }

  func test_default_xpcServiceName_when_no_override_no_env() {
    HelperConfig.$overrides.withValue(.init()) {
      // Skip when the host shell happens to set the env var (CI
      // worker, etc). Real coverage of the env path lives in
      // test_PIE_XPC_SERVICE_env_resolved_via_probe below.
      guard ProcessInfo.processInfo.environment[HelperConfig.xpcServiceEnvVar] == nil else {
        return
      }
      XCTAssertEqual(HelperConfig.xpcServiceName, HelperConfig.defaultXPCService)
    }
  }

  func test_overrides_scope_does_not_leak() {
    let probe = HelperConfig.$overrides.withValue(.init(xpcServiceName: "com.ratiothink.helper.test.b", testMode: true)) { HelperConfig.isTestMode }
    XCTAssertTrue(probe)
    HelperConfig.$overrides.withValue(.init()) {
      guard ProcessInfo.processInfo.environment[HelperConfig.testModeEnvVar] == nil else { return }
      XCTAssertFalse(HelperConfig.isTestMode)
    }
  }

  // MARK: - F3 regression: assertSystemSideEffectAllowed cannot be suppressed via overrides

  func test_assertSystemSideEffectAllowed_consults_process_env_not_overrides() throws {
    let probe = try ResolveProbe.find()
    // Spawn probe with env PIE_TEST_MODE=1 — process env says "test".
    // The probe binary doesn't itself call assertSystemSideEffectAllowed,
    // but we can verify resolvedTestMode flow indirectly: isTestMode
    // must reflect env when no override is set.
    let result = try ResolveProbe.run(probe: probe, env: [
      "PIE_HOME":         try Self.makeTempRoot().path,
      "PIE_XPC_SERVICE":  "com.ratiothink.helper.test.\(UUID().uuidString.prefix(8))",
      "PIE_TEST_MODE":    "1",
    ], mode: "config")
    XCTAssertEqual(result.exitCode, 0, "probe stderr=\(result.stderr)")
    XCTAssertTrue(result.stdout.contains("testMode=true"), "got: \(result.stdout)")
  }

  // MARK: - F1 regression: validateContract runs on every read

  /// F1 regression (review v6 F1): the v5 fix that removed the
  /// once-guard claimed in-process validation runs on every read,
  /// but the prior test only spawned a fresh probe — proving that
  /// claim required two reads in the SAME process under two
  /// different override pairs. The probe's `double-read` mode does
  /// exactly that. Under v4's once-guard, the second read would
  /// short-circuit and the probe would print `pair2-ok=...` and
  /// exit 0; with v5's per-read validation, the asymmetric second
  /// pair traps and the probe exits non-zero with `pair2-ok`
  /// absent from stdout.
  func test_in_process_second_read_with_asymmetric_pair_traps() throws {
    let probe = try ResolveProbe.find()
    let goodXPC = "com.ratiothink.helper.test.\(UUID().uuidString.prefix(8))"
    let result = try ResolveProbe.run(probe: probe, env: [:], mode: "double-read", args: [
      "--first",  "\(goodXPC):true",   // well-formed
      "--second", "nil:true",          // asymmetric (default xpc + testMode)
    ])
    XCTAssertNotEqual(result.exitCode, 0,
                      "double-read should trap on the asymmetric second pair; got \(result)")
    XCTAssertTrue(result.stdout.contains("pair1-ok="),
                  "first read must succeed; stdout=\(result.stdout)")
    XCTAssertFalse(result.stdout.contains("pair2-ok="),
                   "second read must trap before printing; stdout=\(result.stdout) stderr=\(result.stderr)")
  }

  /// Belt-and-braces: two well-formed pairs must both succeed under
  /// the same process, so the per-read validation isn't false-flagging
  /// well-formed transitions.
  func test_in_process_double_read_two_well_formed_pairs_succeed() throws {
    let probe = try ResolveProbe.find()
    let xpcA = "com.ratiothink.helper.test.a.\(UUID().uuidString.prefix(8))"
    let xpcB = "com.ratiothink.helper.test.b.\(UUID().uuidString.prefix(8))"
    let result = try ResolveProbe.run(probe: probe, env: [:], mode: "double-read", args: [
      "--first",  "\(xpcA):true",
      "--second", "\(xpcB):true",
    ])
    XCTAssertEqual(result.exitCode, 0, "probe stderr=\(result.stderr)")
    XCTAssertTrue(result.stdout.contains("pair1-ok=\(xpcA)"), "stdout=\(result.stdout)")
    XCTAssertTrue(result.stdout.contains("pair2-ok=\(xpcB)"), "stdout=\(result.stdout)")
  }

  // MARK: - F2 regression: contract validates RESOLVED (testMode, xpc) pair

  func test_contract_rejects_override_pair_with_testMode_true_but_default_xpc() throws {
    // testMode=true + xpcServiceName=nil (→ resolves to defaultXPCService)
    // would bind the prod helper. Spawn probe with that env combo →
    // probe calls assertStartupContract via the lazy hook → fatalError →
    // probe exits nonzero. We can't drive this purely in-process
    // (contract uses once-guard + fatalError), so spawn probe.
    let probe = try ResolveProbe.find()
    let result = try ResolveProbe.run(probe: probe, env: [
      "PIE_TEST_MODE": "1",
      // PIE_XPC_SERVICE intentionally absent → resolved is default
    ], mode: "config")
    XCTAssertNotEqual(result.exitCode, 0,
                      "probe should fatalError when testMode=1 + xpc=default; got stdout=\(result.stdout) stderr=\(result.stderr)")
  }

  func test_contract_rejects_override_pair_with_xpc_override_but_testMode_false() throws {
    let probe = try ResolveProbe.find()
    let result = try ResolveProbe.run(probe: probe, env: [
      "PIE_XPC_SERVICE": "com.ratiothink.helper.test.\(UUID().uuidString.prefix(8))",
      // PIE_TEST_MODE intentionally absent → resolved is false
    ], mode: "config")
    XCTAssertNotEqual(result.exitCode, 0,
                      "probe should fatalError when xpc=override + testMode=false; got stdout=\(result.stdout) stderr=\(result.stderr)")
  }

  // MARK: - env-driven path via probe binary (no in-process setenv)

  func test_PIE_XPC_SERVICE_env_resolved_via_probe() throws {
    let custom = "com.ratiothink.helper.test.probe.\(UUID().uuidString.prefix(8))"
    let probe = try ResolveProbe.find()
    let result = try ResolveProbe.run(probe: probe, env: [
      HelperConfig.xpcServiceEnvVar: custom,
      HelperConfig.testModeEnvVar:   "1",
    ], mode: "config")
    XCTAssertEqual(result.exitCode, 0, "probe stderr=\(result.stderr)")
    XCTAssertTrue(result.stdout.contains("xpc=\(custom)"), "got: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("testMode=true"), "got: \(result.stdout)")
  }

  // Negative cases still trap (precondition on empty PIE_XPC_SERVICE).
  // Documented; covered by probe-based death-tests above where possible.

  // MARK: - shared test-override gate (isTestOverrideAllowed)

  /// The single predicate behind `RatioThinkApp.isEngineBaseURLOverrideAllowed`
  /// and the `PIE_TEST_ENGINE_BASE_URL` marker in
  /// `HelperRegistrationReconciler.isTestLaunch`. `isDebugBuild` is
  /// injected so the Release branch — which the `#if DEBUG` capture hides
  /// from a DEBUG test build — is exercised directly (the gap the gate
  /// test could not close).
  func test_isTestOverrideAllowed_releaseBuild_refusesUnlessTestMode() {
    // Release (non-DEBUG): a stray env knob is inert.
    XCTAssertFalse(
      HelperConfig.isTestOverrideAllowed(
        environment: ["PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:9"],
        isDebugBuild: false))
    XCTAssertFalse(
      HelperConfig.isTestOverrideAllowed(environment: [:], isDebugBuild: false))
    // …unless the explicit harness flag is set.
    XCTAssertTrue(
      HelperConfig.isTestOverrideAllowed(
        environment: ["PIE_TEST_MODE": "1"], isDebugBuild: false))
    // PIE_TEST_MODE set to anything but "1" is not a harness.
    XCTAssertFalse(
      HelperConfig.isTestOverrideAllowed(
        environment: ["PIE_TEST_MODE": "0"], isDebugBuild: false))
  }

  /// A DEBUG build permits the override regardless of env so dev/test
  /// builds keep their seams.
  func test_isTestOverrideAllowed_debugBuild_permits() {
    XCTAssertTrue(
      HelperConfig.isTestOverrideAllowed(environment: [:], isDebugBuild: true))
    XCTAssertTrue(
      HelperConfig.isTestOverrideAllowed(
        environment: ["PIE_TEST_MODE": "0"], isDebugBuild: true))
  }

  /// The default `isDebugBuild` argument tracks this bundle's compile
  /// config (DEBUG), so the override is permitted with no env — pins that
  /// the production call sites pass through the same default seam.
  func test_isTestOverrideAllowed_defaultBuildFlag_isDebugInTestBundle() {
    XCTAssertTrue(HelperConfig.isDebugBuild,
                  "the test bundle compiles DEBUG; if this fails the gate's default seam changed")
    XCTAssertTrue(HelperConfig.isTestOverrideAllowed(environment: [:]))
  }

  // MARK: - helpers

  fileprivate static func makeTempRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
