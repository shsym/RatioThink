import XCTest
import Foundation
import Darwin
import RatioThinkCore

/// Base XCTest class that gives each test method its own RatioThink state so
/// parallel suites don't collide on:
///   · `~/Library/Application Support/RatioThink/` (profiles.sqlite, models/, logs/)
///   · POSIX shmem `/pie_shmem_g{N}`
///   · Default pie WS/HTTP port 8080
///   · Mach service `com.ratiothink.helper` (XPC listener singleton)
///   · `SMAppService.loginItem` registration (system-wide singleton)
///
/// Per-test setup allocates an ephemeral PIE_HOME under
/// `NSTemporaryDirectory()/pie-test-<pid>-<uuid>/`, picks unique shmem +
/// XPC service names keyed on PID + UUID, requests port `:0` (OS-picked),
/// and sets `PIE_TEST_MODE=1` on the subprocess env so SMAppService
/// registration is skipped.
///
/// Isolation strategy: per-task injection via `@TaskLocal`. The test
/// body runs inside `PieDirs.$homeOverride.withValue(temp) { ... }` and
/// `HelperConfig.$overrides.withValue(...) { ... }`. Two concurrent
/// XCTest tasks see disjoint values, so the prior process-global
/// hazard (setenv races, static-var clobber) is structurally
/// eliminated. The subprocess child receives the same view via
/// `subprocessEnvironment` passed to `Process.environment`.
///
/// Belt-and-braces: `setUpWithError` precondition-traps if
/// `PieDirs.homeOverride` is already non-nil at entry (someone leaked
/// it, or a concurrent test is aliasing the same task). `Scripts/run-
/// swift-test.sh` refuses `--parallel`/`--num-workers=N>1` to keep
/// process-env reads (HelperConfig env fallback) serial-within-bundle
/// regardless.
///
/// See  for the design rationale.
open class IsolatedTestCase: XCTestCase {
  /// Ephemeral root for this test's RatioThink state. Populated by
  /// `invokeTest` before the test body runs; nil between methods.
  public private(set) var tempPieHome: URL!

  /// Unique POSIX shmem name (`/pie_t_<pid>_<short-uuid>`). POSIX
  /// shm names must start with `/`, are global per-host, and capped at
  /// 31 chars by macOS (PSHMNAMLEN) — keep the prefix short.
  public private(set) var shmemName: String!

  /// Unique mach service for the test helper instance.
  public private(set) var xpcService: String!

  /// HTTP/WS listen spec; `127.0.0.1:0` asks the OS for a free port.
  /// See `boundHTTPPort()` for the feedback channel that lets tests
  /// discover the actual bound port ( finding F7).
  public let httpListen = "127.0.0.1:0"

  /// PIDs of pie subprocesses spawned during this test. CLIRunner
  /// (and any other subprocess launcher) MUST register the pid via
  /// `trackSubprocess(_:)` so tearDown can SIGKILL+reap stragglers.
  private var trackedPIDs: [pid_t] = []

  /// Where pie is expected to write its bound HTTP port on `:0`.
  /// `boundHTTPPort()` polls this with a timeout. The pie engine
  /// hasn't implemented the write side yet ( deferred §F7);
  /// the contract is defined here so the test side is ready.
  public var boundPortFile: URL { tempPieHome.appendingPathComponent("http.port") }

  // MARK: - lifecycle

  open override func invokeTest() {
    // Runtime guard: refuse to run if XCTest parallel-testing is on.
    // The wrapper script (Scripts/run-swift-test.sh) blocks the swift
    // test entry, but xcodebuild and the Xcode IDE bypass it. Catch
    // those entry points here so the invariant is enforced regardless
    // of who launches the bundle (review v4 F6).
    Self.refuseParallelTesting()

    // Allocate state OUTSIDE the test body so we can clean it up even
    // if XCTest throws. invokeTest is the single per-method entry
    // point in XCTest's lifecycle.
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let pid  = ProcessInfo.processInfo.processIdentifier
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-test-\(pid)-\(uuid)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    } catch {
      XCTFail("IsolatedTestCase: cannot create \(temp.path): \(error)")
      return
    }
    self.tempPieHome = temp
    self.shmemName   = "/pie_t_\(pid)_\(uuid)"
    self.xpcService  = "com.ratiothink.helper.test.\(pid).\(uuid)"

    let helperOverrides = HelperConfig.Overrides(
      xpcServiceName: xpcService,
      testMode:       true
    )

    // Per-task injection — concurrent test tasks see disjoint values.
    PieDirs.$homeOverride.withValue(temp) {
      HelperConfig.$overrides.withValue(helperOverrides) {
        super.invokeTest()
      }
    }

    // Post-test cleanup runs after super.invokeTest returns (after
    // tearDown). We do FS + subprocess cleanup here rather than in
    // tearDownWithError so it always runs even if tearDown throws.
    reapTrackedSubprocesses()
    cleanupTempPieHome()

    tempPieHome = nil
    shmemName   = nil
    xpcService  = nil
  }

  open override func setUpWithError() throws {
    try super.setUpWithError()
    // PRIMARY DEFENSE against parallel test execution. invokeTest
    // pushed `PieDirs.homeOverride` to this case's `tempPieHome`;
    // if setUp sees a different value (or nil), either:
    //   · someone subclassed and bypassed invokeTest, or
    //   · a concurrent IsolatedTestCase has clobbered the
    //     process-global @TaskLocal binding by sharing the same
    //     task scope (e.g. xcodebuild fanned out into worker
    //     processes that share the bundle's main task).
    // This tripwire fires after `refuseParallelTesting()`
    // (a fast-fail optimization on known env markers) and
    // unconditionally catches the actual failure mode regardless
    // of which marker the harness used. Env-marker check is
    // best-effort coverage of Xcode + xcodebuild today; this
    // precondition is the safety net (review v7 F7).
    precondition(PieDirs.homeOverride?.standardizedFileURL == tempPieHome?.standardizedFileURL,
                 "IsolatedTestCase: PieDirs.homeOverride out of sync with tempPieHome — concurrent setUp, leaked override, or invokeTest bypass")
  }

  // MARK: - subprocess support

  /// Record a pid so the post-test reap loop SIGKILLs + waitpids it.
  public func trackSubprocess(_ pid: pid_t) {
    trackedPIDs.append(pid)
  }

  /// Count of pids currently queued for the post-test reap. Test-only
  /// observability (mirrors `PieEngineHost.observerCountForTesting`) so a
  /// subclass can assert it actually routed its spawned engine pid into
  /// the reap net via `trackSubprocess(_:)` — engine-free, no real spawn
  /// required (the pid-reap wiring guard).
  internal var trackedSubprocessCountForTesting: Int { trackedPIDs.count }

  /// Build env for spawning the pie binary. Callers MUST pass this to
  /// `Process.environment` (never inherit). The base is the parent
  /// process env passed through `SpawnEnvSanitizer.sanitize` — single
  /// shared policy with `ResolveProbe` so both entry points strip the
  /// same set of leaky keys (review v6 F2). The canonical 5 isolation
  /// keys are overlaid last.
  public var subprocessEnvironment: [String: String] {
    var env = SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment)
    env["PIE_HOME"]        = tempPieHome.path
    env["PIE_SHMEM_NAME"]  = shmemName
    env["PIE_HTTP_LISTEN"] = httpListen
    env["PIE_XPC_SERVICE"] = xpcService
    env["PIE_TEST_MODE"]   = "1"
    return env
  }

  /// Backwards-compat aliases. The lint-self-test fixture + existing
  /// regression tests reference these names directly; forwarding to
  /// the shared sanitizer keeps the test API stable while the policy
  /// lives in one place.
  public static var subprocessEnvStripPrefixes: [String] { SpawnEnvSanitizer.stripPrefixes }
  public static var subprocessEnvStripExactKeys: Set<String> { SpawnEnvSanitizer.stripExactKeys }

  /// Polls `$PIE_HOME/http.port` for up to `timeout` seconds. Tests
  /// that want to connect back to the pie engine read the OS-picked
  /// port here rather than parsing stdout. The pie engine's write
  /// side ("on bind, atomic-write the port to `$PIE_HOME/http.port`")
  /// is deferred to the same follow-up commit that adds
  /// `--shmem-name` ( deferred deliverable §4) — until
  /// then this helper times out, which is the desired behavior: any
  /// scenario relying on it must wait for the engine-side support.
  public func boundHTTPPort(timeout: TimeInterval = 10) async throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      do {
        return try readBoundPort()
      } catch IsolationError.boundPortMalformed {
        // Engine wrote something that isn't a valid port — surface
        // immediately so the test attributes blame correctly instead
        // of looping into a timeout that looks like flake (review v4
        // F11).
        throw IsolationError.boundPortMalformed(path: boundPortFile.path)
      } catch {
        // File-not-found / read-during-write — retry until deadline.
      }
      try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }
    throw IsolationError.boundPortTimeout(path: boundPortFile.path,
                                          timeout: timeout)
  }

  // MARK: - parallel-testing guard

  /// FAST-FAIL optimization on known env markers. This is NOT the
  /// primary defense — that's `setUpWithError`'s precondition that
  /// the actual `PieDirs.homeOverride` matches the case's
  /// `tempPieHome`. The precondition unconditionally catches
  /// parallel runs regardless of which marker (if any) the
  /// harness used (review v7 F7); this env check exists to give a
  /// clearer error message earlier in the lifecycle when the
  /// harness uses a known-named flag, and to short-circuit before
  /// per-case state allocation.
  ///
  /// Known markers (must keep in sync with Xcode/macOS updates):
  ///   · `XCTestParallelizationEnabled` set by `xcodebuild test
  ///     -parallel-testing-enabled YES` (observed macOS 14–15).
  ///   · `XCTEST_PARALLEL_WORKER_NUMBER` set by xctest worker
  ///     processes when fanned out.
  ///   · `XCTestClassParallelization` — additional indirect marker
  ///     seen on Xcode 26.
  /// TODO( follow-up): subscribe via `XCTestObservation` and
  /// read run state from the public-API path so we don't depend on
  /// undocumented env-marker names. Until then, the
  /// `setUpWithError` tripwire is the load-bearing safety net.
  ///
  /// A prior version added a reflection layer that probed
  /// `XCTestObservationCenter._currentTestRun.isParallelizing` —
  /// dropped (review v6 F3): the property doesn't exist on
  /// `XCTestObservationCenter`, and `isParallelizing` is a
  /// primitive-return selector that `NSObject.perform(_:)`
  /// reinterprets as an object pointer (nondeterministic, can trap).
  ///
  /// `swift test --parallel` runs each test bundle in its own
  /// process, so a single-process bundle is by definition serial;
  /// the wrapper script blocks that flag at the cmdline boundary.
  private static func refuseParallelTesting() {
    let env = ProcessInfo.processInfo.environment
    let markers = [
      "XCTestParallelizationEnabled",
      "XCTEST_PARALLEL_WORKER_NUMBER",
      "XCTestClassParallelization",
    ]
    for marker in markers {
      if let value = env[marker], value != "0", value.uppercased() != "NO" {
        fatalError("IsolatedTestCase: \(marker)=\(value) — CLIScenarioTests must run serial-within-bundle ( F1/F6). Disable parallel testing in the scheme or pass `-parallel-testing-enabled NO` to xcodebuild.")
      }
    }
  }

  // MARK: - private

  private func readBoundPort() throws -> Int {
    let data = try Data(contentsOf: boundPortFile)
    guard let str = String(data: data, encoding: .utf8),
          let port = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)),
          (1...65535).contains(port)
    else {
      throw IsolationError.boundPortMalformed(path: boundPortFile.path)
    }
    return port
  }

  /// Fail loudly on cleanup failure rather than leaking /tmp dirs
  /// across CI runs. Failure usually means a tracked subprocess still
  /// holds an fd inside tempPieHome — exactly the leak the tracking
  /// is supposed to prevent, so the test should be marked red.
  private func cleanupTempPieHome() {
    guard let temp = tempPieHome else { return }
    do {
      try FileManager.default.removeItem(at: temp)
    } catch CocoaError.fileNoSuchFile {
      // mkdir failed earlier in invokeTest; nothing to clean.
    } catch {
      XCTFail("IsolatedTestCase: cleanup of \(temp.path) failed: \(error)")
    }
  }

  /// Drop the existence probe (TOCTOU + macOS recycles pids quickly
  /// under load) and unconditionally signal + reap. ESRCH on either
  /// SIGKILL or waitpid means the process already exited cleanly —
  /// fine. Anything else fails the test loudly so we don't claim
  /// clean teardown while leaking a pie subprocess into the next
  /// test's namespace.
  private func reapTrackedSubprocesses() {
    for pid in trackedPIDs where pid > 0 {
      let killRC = kill(pid, SIGKILL)
      if killRC != 0 && errno != ESRCH {
        XCTFail("IsolatedTestCase: kill(\(pid), SIGKILL) failed with errno=\(errno) (\(String(cString: strerror(errno))))")
        continue
      }
      // Brief wait — waitpid works because tests spawn pids as
      // Process subprocesses, so we are the parent. WNOHANG + bounded
      // retry beats waitpid blocking forever if some other code
      // already reaped this pid.
      var status: Int32 = 0
      var reaped = false
      for _ in 0..<50 {  // up to 500ms
        let rc = waitpid(pid, &status, WNOHANG)
        if rc == pid { reaped = true; break }
        if rc == -1 && errno == ECHILD { reaped = true; break }
        usleep(10_000)
      }
      if !reaped {
        XCTFail("IsolatedTestCase: pid \(pid) survived SIGKILL + 500ms waitpid window")
      }
    }
    trackedPIDs.removeAll()
  }
}

public enum IsolationError: Error, CustomStringConvertible {
  case boundPortTimeout(path: String, timeout: TimeInterval)
  case boundPortMalformed(path: String)

  public var description: String {
    switch self {
    case let .boundPortTimeout(path, timeout):
      return "bound port file \(path) not written within \(timeout)s — pie engine `--http-listen :0` feedback contract not yet wired ( §F7)"
    case let .boundPortMalformed(path):
      return "bound port file \(path) is not a valid 1-65535 integer"
    }
  }
}
