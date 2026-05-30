import XCTest
@testable import RatioThink

/// Guard the `PIE_TEST_ENGINE_BASE_URL` engine-client override so it can
/// NEVER take effect in a shipped Release build. The override swaps the
/// production engine client (Helper XPC → `EngineStatusStore` →
/// `LaunchSpecResolver` → `PieControlLauncher` → `pie serve`) for a
/// direct base-URL `HTTPEngineClient`. Honoring it unconditionally let a
/// shipped `RatioThink.app` be pointed at a foreign URL AND let a "real
/// binary" scenario silently run on a fake engine. The gate mirrors
/// `HelperXPCListener.isAnonymousModeAllowed` for the
/// `PIE_ALLOW_UNSIGNED_CALLERS` bypass.
final class EngineBaseURLOverrideGateTests: XCTestCase {

  /// `PIE_TEST_MODE=1` is an explicit test harness — the override is
  /// allowed regardless of build configuration (this branch is what
  /// keeps the gate meaningful in a Release test build).
  func test_override_allowed_when_test_mode_is_set() {
    XCTAssertTrue(
      RatioThinkApp.isEngineBaseURLOverrideAllowed(environment: ["PIE_TEST_MODE": "1"]),
      "PIE_TEST_MODE=1 must permit the PIE_TEST_ENGINE_BASE_URL override"
    )
  }

  /// `PIE_TEST_MODE` set to anything other than "1" is not a test
  /// harness — the override falls through to the build-configuration
  /// gate (true under DEBUG where this suite runs).
  func test_override_falls_through_to_build_gate_when_test_mode_absent() {
    // This suite compiles DEBUG, so the build gate returns true. Pins the
    // DEBUG branch here so a regression that drops the testMode allow
    // (breaking GUI base-URL suites) is caught. The production assertion
    // (Release => false) lives in `isEngineBaseURLOverrideAllowed`'s
    // delegate, `HelperConfig.isTestOverrideAllowed`, and is exercised
    // directly by `HelperConfigTests`
    // `.test_isTestOverrideAllowed_releaseBuild_refusesUnlessTestMode`
    // via an injected `isDebugBuild: false` — the seam that replaced the
    // old `#if DEBUG` compile gate this suite couldn't reach.
    XCTAssertTrue(
      RatioThinkApp.isEngineBaseURLOverrideAllowed(environment: [:]),
      "DEBUG builds must still honor the override so GUI base-URL suites run"
    )
    XCTAssertTrue(
      RatioThinkApp.isEngineBaseURLOverrideAllowed(environment: ["PIE_TEST_MODE": "0"]),
      "PIE_TEST_MODE=0 is not a harness; DEBUG build gate still applies here"
    )
  }
}
