import Foundation
import os

/// Compile-time defaults + runtime env overrides for the helper. Lets
/// integration tests point the helper at a unique mach
/// service name and skip system-wide SMAppService registration so a
/// parallel test run doesn't fight the dev install.
///
/// Production behavior is unchanged — when no env var is set, the
/// helper uses the canonical mach service and registers as a login
/// item normally.
public enum HelperConfig {
  /// Default mach service name (matches `CFBundleIdentifier`-derived
  /// XPC label for the production helper).
  public static let defaultXPCService = "com.ratiothink.helper"

  /// Env var consulted at launch for an override mach service name.
  public static let xpcServiceEnvVar  = "PIE_XPC_SERVICE"

  /// Env var that, when set to "1", instructs the helper to skip every
  /// system-wide side effect (SMAppService.loginItem, etc). Tests flip
  /// this so parallel runs never touch the system login-item database.
  public static let testModeEnvVar    = "PIE_TEST_MODE"

  /// In-process overrides keyed per task. Tests use this seam instead
  /// of mutating the process env (which is shared mutable state across
  /// concurrent test methods). Each `withValue { … }` scope sees its
  /// own view; the env-based fallback remains the production path.
  public struct Overrides: Sendable {
    public var xpcServiceName: String?
    public var testMode: Bool?
    public init(xpcServiceName: String? = nil, testMode: Bool? = nil) {
      self.xpcServiceName = xpcServiceName
      self.testMode       = testMode
    }
  }

  @TaskLocal public static var overrides: Overrides = Overrides()

  /// Resolved mach service name for this helper process.
  ///
  ///  · Reads `overrides.xpcServiceName` first (per-task test seam).
  ///  · Falls back to `$PIE_XPC_SERVICE` (precondition-trap on empty).
  ///  · Otherwise returns `defaultXPCService`.
  ///
  /// Validates the resolved (testMode, xpcServiceName) pair on EVERY
  /// read — the prior process-wide once-guard let the first
  /// well-formed read disarm the gate, so any subsequent in-process
  /// override pair with a mismatched (testMode, xpc) silently bypassed
  /// the contract (review v5 F1). Validation is a handful of env
  /// reads and a dict lookup; the once-guard's only justification was
  /// log-spam control, not correctness.
  public static var xpcServiceName: String {
    let resolved = resolvedXPCServiceName()
    validateContract()
    let source = overrides.xpcServiceName != nil ? "override" : "env"
    logResolutionOnce(resolved, source: source)
    return resolved
  }

  /// Whether the helper is running under a test harness.
  ///
  ///  · Reads `overrides.testMode` first (per-task test seam).
  ///  · Falls back to `$PIE_TEST_MODE`.
  ///
  /// Side-effecting helper subsystems MUST route through
  /// `assertSystemSideEffectAllowed` rather than reading this directly —
  /// that choke point is greppable and prevents new code from silently
  /// clobbering prod state.
  public static var isTestMode: Bool {
    let value = resolvedTestMode()
    validateContract()
    return value
  }

  /// Single greppable choke point for any helper code path that would
  /// touch system-wide state (login items, keychain, IOPM assertions,
  /// global mach service binding, etc). Call BEFORE performing the
  /// side effect. Traps when `$PIE_TEST_MODE=1` is set in the
  /// **process env** — overrides cannot suppress this gate (review v4
  /// F3). The `Scripts/lint-helper-side-effects.sh` CI check greps
  /// for known side-effect APIs without an adjacent call to this
  /// function.
  public static func assertSystemSideEffectAllowed(_ subsystem: String) {
    if envTestMode {
      fatalError("HelperConfig.assertSystemSideEffectAllowed(\(subsystem)): PIE_TEST_MODE=1 in process env, refusing system-wide side effect (override seam cannot suppress this gate)")
    }
  }

  /// Cross-check that the resolved (testMode, xpcServiceName) pair is
  /// internally consistent. Invoked on every read of either getter
  /// (no once-guard, review v5 F1) so a caller (helper boot, future
  /// XPC client init, CLI sharing the bundle) that switches override
  /// pairs across `withValue` scopes always re-validates. Cheap —
  /// dict lookups + a switch.
  public static func assertStartupContract() {
    validateContract()
  }

  // MARK: - Test-override build gate

  /// Compiled build configuration. Gates the engine-base-URL test seam (see
  /// `testEngineBaseURLOverride`): a Release build ignores it so a shipped,
  /// signed app never redirects its engine endpoint to an attacker-supplied
  /// URL; a DEBUG build — including the `xcodebuild test` runner — honors it.
  /// NOTE: this gate currently covers ONLY that seam. Other App-side
  /// `PIE_TEST_*` reads (prefs suite, first-launch flag, fake/fixture
  /// downloads, artifact-path probe) still read the env directly and stay
  /// live in Release; routing them through this gate is a separate follow-up.
  #if DEBUG
  public static let defaultIsDebugBuild = true
  #else
  public static let defaultIsDebugBuild = false
  #endif

  /// Injectable seam so the Release branch is exercisable from a DEBUG test
  /// process. `nil` ⇒ use the compiled `defaultIsDebugBuild`.
  @TaskLocal public static var isDebugBuildOverride: Bool?

  /// Effective build configuration (override-aware).
  public static var isDebugBuild: Bool { isDebugBuildOverride ?? defaultIsDebugBuild }

  /// Whether the engine-base-URL test seam may activate. `false` in Release.
  /// (The only `PIE_TEST_*` seam currently gated — see `defaultIsDebugBuild`.)
  public static var isTestOverrideAllowed: Bool { isDebugBuild }

  /// Resolve the `PIE_TEST_ENGINE_BASE_URL` test seam — honored only when test
  /// overrides are allowed. A Release build returns `nil` regardless of the
  /// env var, so the App falls back to the real Helper-driven engine path
  /// instead of an attacker-supplied loopback. Pure + parameterized so the
  /// gate is unit-testable.
  public static func testEngineBaseURLOverride(
    env: [String: String] = ProcessInfo.processInfo.environment,
    allowed: Bool = isTestOverrideAllowed
  ) -> String? {
    guard allowed, let raw = env["PIE_TEST_ENGINE_BASE_URL"], !raw.isEmpty else {
      return nil
    }
    return raw
  }

  /// Outcome of resolving the `PIE_TEST_ENGINE_BASE_URL` seam to a concrete
  /// `URL`. Distinguishes a *malformed* (set-but-unparseable) override from an
  /// absent/ignored one so the caller can fail loudly on a harness typo rather
  /// than silently falling back to the real engine (#339).
  public enum TestEngineBaseURL: Equatable {
    /// Override absent, empty, or ignored (Release build).
    case notSet
    /// Override set, honored, and parsed to a usable `URL`.
    case valid(URL)
    /// Override set + honored but `URL(string:)` rejected it (bad scheme,
    /// embedded whitespace, unbalanced bracket, …). Never silently dropped.
    case malformed(raw: String)
  }

  /// Resolve `PIE_TEST_ENGINE_BASE_URL` to a `URL`, surfacing a malformed value
  /// explicitly instead of collapsing it to `nil`. A non-empty but unparseable
  /// override otherwise becomes `nil` and the caller silently builds the real
  /// production engine client — a test author's typo'd URL would run against
  /// the wrong engine and fail far downstream (#339). Pure + parameterized so
  /// the parse is unit-testable; the loud-failure policy lives at the call
  /// site.
  public static func resolveTestEngineBaseURL(
    env: [String: String] = ProcessInfo.processInfo.environment,
    allowed: Bool = isTestOverrideAllowed
  ) -> TestEngineBaseURL {
    guard let raw = testEngineBaseURLOverride(env: env, allowed: allowed) else {
      return .notSet
    }
    guard let url = URL(string: raw) else {
      return .malformed(raw: raw)
    }
    return .valid(url)
  }

  // MARK: - internals

  private static let log = Logger(subsystem: "com.ratiothink.app.helper", category: "config")
  private static let resolutionState = OSAllocatedUnfairLock<Bool>(initialState: false)

  /// True iff `$PIE_TEST_MODE=1` in the process env. **Bypasses
  /// overrides** so the gate cannot be suppressed by wrapping prod
  /// code in `HelperConfig.$overrides.withValue(.init(testMode: false))`.
  private static var envTestMode: Bool {
    ProcessInfo.processInfo.environment[testModeEnvVar] == "1"
  }

  private static func envXPCServiceName() -> String {
    guard let env = ProcessInfo.processInfo.environment[xpcServiceEnvVar] else {
      return defaultXPCService
    }
    precondition(!env.isEmpty,
                 "PIE_XPC_SERVICE was set to an empty string — likely broken interpolation in the test harness")
    return env
  }

  private static func resolvedXPCServiceName() -> String {
    overrides.xpcServiceName ?? envXPCServiceName()
  }

  private static func resolvedTestMode() -> Bool {
    overrides.testMode ?? envTestMode
  }

  /// Validate the RESOLVED view: a non-default xpc must imply
  /// testMode, and testMode must imply a non-default xpc. Catches
  /// env-only, override-only, and mixed configurations. Called on
  /// every getter read — see review v5 F1 for why the prior
  /// once-guard was wrong.
  private static func validateContract() {
    let xpc = resolvedXPCServiceName()
    let test = resolvedTestMode()
    let xpcIsOverride = xpc != defaultXPCService
    switch (test, xpcIsOverride) {
    case (true, false):
      fatalError("HelperConfig: testMode=true without a non-default xpcServiceName — would still bind \(defaultXPCService) and collide with prod helper")
    case (false, true):
      fatalError("HelperConfig: xpcServiceName=\(xpc) is non-default without testMode=true — refusing to register system side effects under a test mach name")
    default:
      break
    }
  }

  private static func logResolutionOnce(_ resolved: String, source: String) {
    let shouldLog = resolutionState.withLock { state -> Bool in
      if state { return false }
      state = true
      return true
    }
    if shouldLog {
      log.info("HelperConfig resolved xpcService=\(resolved, privacy: .public) source=\(source, privacy: .public) testMode=\(resolvedTestMode(), privacy: .public) envTestMode=\(envTestMode, privacy: .public)")
    }
  }

  /// Test-only: reset the once-guards so a unit test can re-exercise
  /// the lazy contract/logging path. Public because RatioThinkCoreTests lives
  /// in a separate module; **not** part of the production API.
  public static func _resetOnceStateForTesting() {
    resolutionState.withLock { $0 = false }
  }
}
