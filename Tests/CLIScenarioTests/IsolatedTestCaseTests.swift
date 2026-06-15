import XCTest
import Darwin
import RatioThinkCore

/// Verifies the contract that `IsolatedTestCase` provides to downstream
/// scenario tests. Runs as `IsolatedTestCase` itself so each method
/// exercises the same invokeTest/setUp/tearDown path production
/// scenarios use.
final class IsolatedTestCaseTests: IsolatedTestCase {
  func test_tempPieHome_lives_under_NSTemporaryDirectory() {
    XCTAssertTrue(tempPieHome.path.hasPrefix(NSTemporaryDirectory()),
                  "tempPieHome not under NSTemporaryDirectory: \(tempPieHome.path)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempPieHome.path))
  }

  func test_PieDirs_homeOverride_routes_through_tempPieHome() throws {
    XCTAssertEqual(PieDirs.homeOverride?.standardizedFileURL.path,
                   tempPieHome.standardizedFileURL.path)
    XCTAssertEqual(try PieDirs.applicationSupport().standardizedFileURL.path,
                   tempPieHome.standardizedFileURL.path)
  }

  func test_HelperConfig_overrides_route_through_xpc_and_testMode() {
    XCTAssertEqual(HelperConfig.xpcServiceName, xpcService)
    XCTAssertTrue(HelperConfig.isTestMode)
  }

  func test_shmem_name_unique_and_posix_safe() {
    XCTAssertTrue(shmemName.hasPrefix("/pie_t_"),
                  "POSIX shm names must start with '/'; got \(shmemName!)")
    XCTAssertLessThanOrEqual(shmemName.count, 31,
                             "shmem name too long for macOS (PSHMNAMLEN=31): \(shmemName!)")
  }

  func test_xpc_service_is_test_namespaced() {
    XCTAssertTrue(xpcService.hasPrefix("com.ratiothink.helper.test."),
                  "xpc service must live in the test namespace; got \(xpcService!)")
    XCTAssertNotEqual(xpcService, HelperConfig.defaultXPCService)
  }

  func test_subprocessEnvironment_carries_full_isolation_set() {
    let env = subprocessEnvironment
    XCTAssertEqual(env["PIE_HOME"],        tempPieHome.path)
    XCTAssertEqual(env["PIE_SHMEM_NAME"],  shmemName)
    XCTAssertEqual(env["PIE_HTTP_LISTEN"], "127.0.0.1:0")
    XCTAssertEqual(env["PIE_XPC_SERVICE"], xpcService)
    XCTAssertEqual(env["PIE_TEST_MODE"],   "1")
  }

  /// F4 regression: parent-shell `PIE_*` / `RUST_*` / `DYLD_*` /
  /// `MTL_*` keys must not flow into the spawned pie child.
  /// `subprocessEnvironment` filters them out before overlaying the
  /// canonical 5. Drive via a fresh subprocess so we don't have to
  /// touch the parent's env to "set" PIE_LOG_LEVEL — we just probe
  /// the filter logic directly.
  func test_subprocessEnvironment_strips_parent_PIE_keys() {
    let env = subprocessEnvironment
    // None of the stripped prefixes should match a key in env aside
    // from the canonical isolation 5.
    let isolated: Set<String> = [
      "PIE_HOME", "PIE_SHMEM_NAME", "PIE_HTTP_LISTEN", "PIE_XPC_SERVICE", "PIE_TEST_MODE",
    ]
    for key in env.keys {
      for prefix in IsolatedTestCase.subprocessEnvStripPrefixes
      where key.hasPrefix(prefix) && !isolated.contains(key) {
        XCTFail("subprocessEnvironment leaked prefix-stripped key \(key)")
      }
    }
  }

  /// F4 regression, second angle: assert the stripper actually runs
  /// by seeding a fake parent env and reproducing the overlay logic.
  /// (We can't mutate ProcessInfo.processInfo.environment in-process,
  /// so we exercise the published prefix list against a known input.)
  /// Pins `subprocessEnvironment` to the SAME function it claims to
  /// be: `SpawnEnvSanitizer.sanitize(parentEnv).merging(overlay)
  /// { _, o in o }`. Earlier versions of this test enforced one
  /// downstream rule at a time (canonical-5 overlay, then no leaked
  /// strip-prefix key);  F4 collapses both into a single
  /// equality so a sanitizer-policy or overlay-list change can only
  /// be made in one place. Detailed sanitizer behavior lives in
  /// `Tests/RatioThinkCoreTests/SpawnEnvSanitizerTests.swift`; this test
  /// only protects the delegation contract.
  func test_subprocessEnvironment_delegates_to_SpawnEnvSanitizer() {
    let overlay: [String: String] = [
      "PIE_HOME":        tempPieHome.path,
      "PIE_SHMEM_NAME":  shmemName,
      "PIE_HTTP_LISTEN": "127.0.0.1:0",
      "PIE_XPC_SERVICE": xpcService,
      "PIE_TEST_MODE":   "1",
    ]
    let expected = SpawnEnvSanitizer
      .sanitize(ProcessInfo.processInfo.environment)
      .merging(overlay) { _, o in o }
    XCTAssertEqual(subprocessEnvironment, expected,
                   "subprocessEnvironment diverged from `sanitize(parent).merging(overlay)` — overlay list, sanitizer call, or merge resolution drifted")
  }

  func test_process_env_is_NOT_mutated_by_invokeTest() {
    // Guards the F1 invariant: invokeTest must not touch process env.
    XCTAssertNil(ProcessInfo.processInfo.environment["PIE_HOME"],
                 "PIE_HOME leaked into process env — IsolatedTestCase must not setenv")
    XCTAssertNil(ProcessInfo.processInfo.environment["PIE_SHMEM_NAME"],
                 "PIE_SHMEM_NAME leaked into process env")
    XCTAssertNil(ProcessInfo.processInfo.environment["PIE_XPC_SERVICE"],
                 "PIE_XPC_SERVICE leaked into process env")
  }

  func test_trackSubprocess_with_short_lived_real_process_reaps_cleanly() throws {
    // Spawn a process we control (sleeps 60s), register its pid, and
    // verify post-test reap SIGKILLs + waitpids cleanly without
    // XCTFail. End-to-end check of F3 + F6 from Review v1.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    proc.arguments = ["60"]
    try proc.run()
    trackSubprocess(proc.processIdentifier)
    // No assertion — success is "post-test cleanup doesn't XCTFail".
  }

  func test_trackSubprocess_is_thread_safe_under_concurrent_registration() {
    // `pidSink` fires on the async launch thread while the XCTest
    // thread later drains the array — concurrent appends to a plain
    // `[pid_t]` lose updates or tear a reallocation. Hammer
    // `trackSubprocess` from many threads and assert every registration
    // landed; without `pidLock` this either crashes or under-counts (#388).
    //
    // Sentinel pid -1 (non-positive) so the post-test reap loop's
    // `where pid > 0` filter skips it — no real process is signalled.
    let count = 2_000
    let before = trackedSubprocessCountForTesting
    DispatchQueue.concurrentPerform(iterations: count) { _ in
      self.trackSubprocess(-1)
    }
    XCTAssertEqual(trackedSubprocessCountForTesting - before, count,
                   "concurrent trackSubprocess lost registrations — pidLock not serializing appends")
  }

  func test_boundHTTPPort_times_out_when_pie_engine_side_not_wired() async {
    // F7: until pie writes $PIE_HOME/http.port on bind, this helper
    // must time out cleanly with a descriptive IsolationError instead
    // of hanging forever.
    do {
      _ = try await boundHTTPPort(timeout: 0.15)
      XCTFail("expected timeout, got a port")
    } catch let err as IsolationError {
      switch err {
      case .boundPortTimeout: break  // expected
      case .boundPortMalformed:
        XCTFail("unexpected variant: \(err)")
      }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func test_boundHTTPPort_returns_port_when_file_present_and_valid() async throws {
    try "54321\n".write(to: boundPortFile, atomically: true, encoding: .utf8)
    let port = try await boundHTTPPort(timeout: 1.0)
    XCTAssertEqual(port, 54321)
  }

  /// F5 regression (review v7): `invokeTest` is synchronous and
  /// wraps `super.invokeTest()` in `PieDirs.$homeOverride.withValue`
  /// / `HelperConfig.$overrides.withValue`. XCTest's async-test
  /// driver runs the body inside a Task spawned from the sync
  /// invokeTest stack — for the @TaskLocal contract to hold, that
  /// Task must inherit the bindings (i.e. XCTest uses
  /// `Task { … }` not `Task.detached { … }`). If a future XCTest
  /// switches to detached, `PieDirs.homeOverride` would read nil
  /// inside async test bodies and fall back to `$PIE_HOME` env or
  /// the system default — silent isolation breakage. This test
  /// reads the bindings from inside an `async` body to pin the
  /// assumption.
  func test_TaskLocal_overrides_propagate_into_async_body() async {
    XCTAssertEqual(PieDirs.homeOverride?.standardizedFileURL.path,
                   tempPieHome.standardizedFileURL.path,
                   "@TaskLocal PieDirs.homeOverride did not propagate from sync invokeTest into async test body — XCTest may be using Task.detached")
    XCTAssertEqual(HelperConfig.xpcServiceName, xpcService,
                   "@TaskLocal HelperConfig.overrides.xpcServiceName did not propagate into async test body")
    XCTAssertTrue(HelperConfig.isTestMode,
                  "@TaskLocal HelperConfig.overrides.testMode did not propagate into async test body")
    // Also confirm a nested child Task inherits, since the body might
    // spawn its own concurrency.
    await Task { @MainActor in
      XCTAssertEqual(PieDirs.homeOverride?.standardizedFileURL.path,
                     tempPieHome.standardizedFileURL.path,
                     "@TaskLocal did not propagate into a nested Task spawned from the async test body")
    }.value
  }

  /// F3: lock the propagation contract across every
  /// structured-concurrency entry point a future scenario might
  /// reach for. Documents three invariants:
  ///   1. `Task { ... }` (child) inherits the bindings.
  ///   2. `Task.detached { ... }` does NOT inherit — by language
  ///      design. Tests that detach MUST restore overrides
  ///      explicitly or accept the env-fallback path.
  ///   3. `withTaskGroup` / `TaskGroup.addTask` child tasks DO
  ///      inherit — `addTask` is the structured form and propagates
  ///      task-local bindings from the group's parent context.
  /// If Swift concurrency ever changes (1) or (3), or if (2) starts
  /// inheriting (which would mask isolation breakage rather than
  /// surface it), this test pins the contract red.
  func test_TaskLocal_overrides_across_structured_concurrency_entry_points() async throws {
    let expectedHome = tempPieHome.standardizedFileURL.path
    let expectedXPC  = xpcService!

    // (1) Child Task inherits.
    let childHome = await Task { PieDirs.homeOverride?.standardizedFileURL.path }.value
    XCTAssertEqual(childHome, expectedHome,
                   "child `Task { ... }` did not inherit PieDirs.homeOverride — base contract regressed")

    // (2) Detached Task does NOT inherit. The actual contract is
    // "detached sees nil @TaskLocal"; review v1 F8 caught that an
    // earlier `XCTAssertNotEqual(detached, expectedHome)` passed for
    // the WRONG reason if a developer had `PIE_HOME` exported in
    // their shell (PieDirs.homeOverride is the @TaskLocal slot only,
    // but a different-non-nil could still differ from expectedHome
    // and mask a contract change). Read the raw @TaskLocal here so
    // env fallback isn't in the picture.
    //
    // Precondition (caveat for future runners): the shell launching
    // these tests must NOT export PIE_HOME — PieDirs.homeOverride
    // reads the @TaskLocal directly, so this assertion is robust to
    // env, but other tests in the suite rely on the env-free
    // contract. Documented here so a future flake gets blamed at
    // the right layer.
    let detachedOverride: URL? = await Task.detached { PieDirs.$homeOverride.get() }.value
    XCTAssertNil(detachedOverride,
                 "`Task.detached` unexpectedly inherited @TaskLocal PieDirs.homeOverride — Swift contract changed; revisit isolation strategy (callers may no longer need to re-bind in detached scopes)")

    // (3) withTaskGroup children inherit. Spawn N=3 to also confirm
    // each addTask child reads the SAME value (not just whichever
    // one happens to grab it first).
    let groupHomes = await withTaskGroup(of: String?.self) { group -> [String?] in
      for _ in 0..<3 {
        group.addTask { PieDirs.homeOverride?.standardizedFileURL.path }
      }
      var out: [String?] = []
      for await result in group { out.append(result) }
      return out
    }
    XCTAssertEqual(groupHomes.count, 3, "task group did not produce 3 results")
    for (i, seen) in groupHomes.enumerated() {
      XCTAssertEqual(seen, expectedHome,
                     "withTaskGroup child #\(i) did not inherit PieDirs.homeOverride")
    }

    // Throwing variant — same invariant, separate code path. Review
    // v1 F9: `try?` swallowed any throw into nil, then blamed the
    // resulting nil on broken inheritance instead of surfacing the
    // real error. Use `try await` so a future refactor that adds a
    // throw to HelperConfig.xpcServiceName or to withThrowingTaskGroup
    // iteration fails this test with the underlying error.
    let throwingGroupXPC = try await withThrowingTaskGroup(of: String?.self) { group -> [String?] in
      for _ in 0..<2 {
        group.addTask { HelperConfig.xpcServiceName }
      }
      var out: [String?] = []
      for try await result in group { out.append(result) }
      return out
    }
    XCTAssertEqual(throwingGroupXPC, [expectedXPC, expectedXPC],
                   "withThrowingTaskGroup children did not inherit HelperConfig.xpcServiceName")
  }

  /// F11 regression: malformed `http.port` contents must surface
  /// immediately as `boundPortMalformed`, not collapse into the
  /// retry/timeout path that misattributes engine-side bugs as
  /// flake/slow-start.
  func test_boundHTTPPort_surfaces_malformed_immediately_not_as_timeout() async throws {
    try "not-a-port".write(to: boundPortFile, atomically: true, encoding: .utf8)
    let start = Date()
    do {
      _ = try await boundHTTPPort(timeout: 5.0)
      XCTFail("expected malformed throw")
    } catch let err as IsolationError {
      let elapsed = Date().timeIntervalSince(start)
      switch err {
      case .boundPortMalformed:
        XCTAssertLessThan(elapsed, 1.0,
                          "malformed should surface fast, not after the 5s timeout (elapsed=\(elapsed))")
      case .boundPortTimeout:
        XCTFail("malformed should NOT collapse into timeout (elapsed=\(elapsed))")
      }
    }
  }
}

/// Independent verification that two methods in a row receive distinct
/// `tempPieHome` roots — confirms UUIDs aren't being recycled.
final class IsolatedTestCaseDistinctnessTests: IsolatedTestCase {
  static var firstHome: String?

  func test_each_test_gets_a_fresh_root_part1() {
    Self.firstHome = tempPieHome.path
  }

  func test_each_test_gets_a_fresh_root_part2() throws {
    try XCTSkipIf(Self.firstHome == nil,
                  "part1 must run first; XCTest runs methods alphabetically")
    XCTAssertNotEqual(Self.firstHome, tempPieHome.path,
                      "two test methods got the same tempPieHome — UUIDs collided")
  }
}

/// F1 regression: per-task isolation via @TaskLocal must let two
/// concurrent tasks see disjoint `PieDirs.homeOverride` values. Drives
/// `withValue` on two concurrent Tasks and asserts each task reads
/// only its own value. If `homeOverride` regressed to a plain `static
/// var`, this would race.
final class TaskLocalHomeOverrideTests: XCTestCase {
  func test_two_concurrent_tasks_see_disjoint_homeOverride() async {
    let urlA = URL(fileURLWithPath: "/tmp/pie-test-task-A")
    let urlB = URL(fileURLWithPath: "/tmp/pie-test-task-B")

    async let seenA: URL? = PieDirs.$homeOverride.withValue(urlA) {
      // sleep briefly so the two withValue scopes are alive concurrently
      try? await Task.sleep(nanoseconds: 50_000_000)
      return PieDirs.homeOverride
    }
    async let seenB: URL? = PieDirs.$homeOverride.withValue(urlB) {
      try? await Task.sleep(nanoseconds: 50_000_000)
      return PieDirs.homeOverride
    }

    let (a, b) = await (seenA, seenB)
    XCTAssertEqual(a, urlA, "task A saw \(String(describing: a)) instead of its own override")
    XCTAssertEqual(b, urlB, "task B saw \(String(describing: b)) instead of its own override")
  }
}
