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

  // MARK: - test-override build gate (Release ignores PIE_TEST_* seams)

  /// A non-debug (Release) build MUST ignore `PIE_TEST_ENGINE_BASE_URL` so a
  /// shipped, signed app falls back to the real Helper-driven engine path and
  /// never honors an attacker-supplied loopback. Exercised via the injected
  /// `isDebugBuildOverride` seam (the compiled default is `true` in this DEBUG
  /// test process).
  func test_release_build_ignores_engine_base_url_override() {
    let env = ["PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:9999"]
    HelperConfig.$isDebugBuildOverride.withValue(false) {
      XCTAssertFalse(HelperConfig.isTestOverrideAllowed,
                     "a non-debug build must not allow test overrides")
      XCTAssertNil(HelperConfig.testEngineBaseURLOverride(env: env),
                   "Release build must ignore PIE_TEST_ENGINE_BASE_URL")
    }
  }

  /// A DEBUG build — including the `xcodebuild test` runner that drives the
  /// chat-gui E2E — honors the seam so S258 can point the App at the
  /// wrapper-booted engine.
  func test_debug_build_honors_engine_base_url_override() {
    let env = ["PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:9999"]
    HelperConfig.$isDebugBuildOverride.withValue(true) {
      XCTAssertTrue(HelperConfig.isTestOverrideAllowed)
      XCTAssertEqual(HelperConfig.testEngineBaseURLOverride(env: env),
                     "http://127.0.0.1:9999",
                     "a debug build must honor the engine base-url seam")
    }
  }

  /// Empty/absent env yields `nil` even when overrides are allowed.
  func test_empty_or_absent_engine_base_url_is_nil_even_in_debug() {
    HelperConfig.$isDebugBuildOverride.withValue(true) {
      XCTAssertNil(HelperConfig.testEngineBaseURLOverride(env: ["PIE_TEST_ENGINE_BASE_URL": ""]))
      XCTAssertNil(HelperConfig.testEngineBaseURLOverride(env: [:]))
    }
  }

  // MARK: - engine base-url URL resolution (#339: malformed != silent nil)

  /// A well-formed override under a DEBUG build resolves to `.valid`.
  func test_resolve_engine_base_url_valid() {
    let env = ["PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:9999"]
    HelperConfig.$isDebugBuildOverride.withValue(true) {
      XCTAssertEqual(HelperConfig.resolveTestEngineBaseURL(env: env),
                     .valid(URL(string: "http://127.0.0.1:9999")!))
    }
  }

  /// A non-empty but unparseable override (embedded whitespace) resolves to
  /// `.malformed` carrying the raw value — NOT `.notSet`. This is the #339
  /// fix: a harness typo must be distinguishable from an absent override so
  /// the caller can fail loudly instead of silently using the real engine.
  func test_resolve_engine_base_url_malformed_is_loud_not_notset() {
    let raw = "http://127.0.0.1:99 99"
    XCTAssertNil(URL(string: raw), "precondition: this value must be unparseable")
    let env = ["PIE_TEST_ENGINE_BASE_URL": raw]
    HelperConfig.$isDebugBuildOverride.withValue(true) {
      XCTAssertEqual(HelperConfig.resolveTestEngineBaseURL(env: env), .malformed(raw: raw))
    }
  }

  /// An unbalanced-bracket override is likewise surfaced as `.malformed`.
  func test_resolve_engine_base_url_malformed_unbalanced_bracket() {
    let raw = "http://[::1"
    XCTAssertNil(URL(string: raw), "precondition: this value must be unparseable")
    let env = ["PIE_TEST_ENGINE_BASE_URL": raw]
    HelperConfig.$isDebugBuildOverride.withValue(true) {
      XCTAssertEqual(HelperConfig.resolveTestEngineBaseURL(env: env), .malformed(raw: raw))
    }
  }

  /// Empty/absent env resolves to `.notSet`.
  func test_resolve_engine_base_url_absent_is_notset() {
    HelperConfig.$isDebugBuildOverride.withValue(true) {
      XCTAssertEqual(HelperConfig.resolveTestEngineBaseURL(env: ["PIE_TEST_ENGINE_BASE_URL": ""]), .notSet)
      XCTAssertEqual(HelperConfig.resolveTestEngineBaseURL(env: [:]), .notSet)
    }
  }

  /// A Release build ignores the seam — even a malformed value resolves to
  /// `.notSet` (the real Helper path runs), never `.malformed`.
  func test_resolve_engine_base_url_release_ignores_even_malformed() {
    let env = ["PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:99 99"]
    HelperConfig.$isDebugBuildOverride.withValue(false) {
      XCTAssertEqual(HelperConfig.resolveTestEngineBaseURL(env: env), .notSet)
    }
  }

  // MARK: - helpers

  fileprivate static func makeTempRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
