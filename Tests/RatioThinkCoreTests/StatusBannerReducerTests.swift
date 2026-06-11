import XCTest
@testable import RatioThinkCore

/// The unified 3-tier, source-labeled status banner: ONE poll-count policy
/// drives both the helper axis (`HelperHealth`) and the engine axis
/// (`EngineStatus`). Pure, so the whole tier/source/copy/Force-Restart
/// mapping is pinned without SwiftUI.
final class StatusBannerReducerTests: XCTestCase {
  private let policy = StatusTierPolicy(tier1Polls: 15, tier2Polls: 30)

  private func banner(engine: EngineStatus = .running(EngineSessionSnapshot(port: 8080, profileID: "chat")),
                      wasEverRunning: Bool = true,
                      helper: HelperHealth = .healthy,
                      engineGonePolls: Int = 0) -> UnifiedStatusBanner? {
    StatusBannerReducer.make(engine: engine, wasEverRunning: wasEverRunning,
                             helper: helper, engineGonePolls: engineGonePolls, policy: policy)
  }

  // MARK: - Tier 0 (silent)

  func test_running_or_stopped_or_starting_with_healthy_helper_is_silent() {
    XCTAssertNil(banner(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat"))))
    XCTAssertNil(banner(engine: .stopped))
    XCTAssertNil(banner(engine: .starting, wasEverRunning: false))
  }

  func test_helper_reconnecting_transient_window_is_silent() {
    // Transient window (pre-repair) shows no banner — the pip stays calm.
    XCTAssertNil(banner(helper: .reconnecting(consecutiveFailures: 3)))
  }

  // MARK: - Tier 1 (calm, source-labeled)

  func test_helper_repairing_is_tier1_reconnecting_helper() {
    let b = banner(helper: .repairing(attempt: 1))
    XCTAssertEqual(b?.tier, .reconnecting)
    XCTAssertEqual(b?.source, .helper)
    XCTAssertEqual(b?.forceRestart, ForceRestartTarget.none)
    XCTAssertTrue(b?.title.localizedCaseInsensitiveContains("helper") == true)
  }

  func test_engineGone_under_threshold_is_tier1_reconnecting_engine() {
    let b = banner(engine: .failed(code: .engineGone, message: "exit 1"),
                   engineGonePolls: 5)
    XCTAssertEqual(b?.tier, .reconnecting)
    XCTAssertEqual(b?.source, .engine)
    XCTAssertEqual(b?.forceRestart, ForceRestartTarget.none)
    XCTAssertTrue(b?.title.localizedCaseInsensitiveContains("engine") == true)
  }

  // MARK: - Tier 2 (loud + source-aware Force Restart)

  func test_helper_unreachable_is_tier2_force_restart_helper() {
    let b = banner(helper: .unreachable)
    XCTAssertEqual(b?.tier, .error)
    XCTAssertEqual(b?.source, .helper)
    XCTAssertEqual(b?.forceRestart, .helper)
  }

  func test_engineGone_over_threshold_is_tier2_force_restart_engine() {
    let b = banner(engine: .failed(code: .engineGone, message: "exit 1"),
                   engineGonePolls: 30)
    XCTAssertEqual(b?.tier, .error)
    XCTAssertEqual(b?.source, .engine)
    XCTAssertEqual(b?.forceRestart, .engine)
  }

  func test_explicit_nonEngineGone_failure_is_immediate_tier2_engine() {
    // spawnFailed / modelMissing etc. are real failures — loud at once.
    for code in [EngineErrorCode.spawnFailed, .modelMissing, .memoryRisk] {
      let b = banner(engine: .failed(code: code, message: "boom"))
      XCTAssertEqual(b?.tier, .error, "\(code) must be Tier 2")
      XCTAssertEqual(b?.source, .engine)
    }
    // #477: Force Restart only where the taxonomy says a restart is the
    // fix — a model-choice fault would re-fail on restart, so it offers
    // none (the indicator banner carries the Model-menu hint instead).
    XCTAssertEqual(
      banner(engine: .failed(code: .spawnFailed, message: "boom"))?.forceRestart, .engine)
    for code in [EngineErrorCode.modelMissing, .memoryRisk] {
      XCTAssertEqual(
        banner(engine: .failed(code: code, message: "boom"))?.forceRestart,
        ForceRestartTarget.none,
        "\(code) is a model-choice fault; Force Restart would re-fail")
    }
  }

  // MARK: - precedence + first-load gate

  func test_helper_axis_outranks_engine_axis() {
    // Helper unreachable makes the reported engine status stale → helper wins.
    let b = banner(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")), helper: .unreachable)
    XCTAssertEqual(b?.source, .helper)
    XCTAssertEqual(b?.tier, .error)
  }

  func test_tierForLostContact_first_load_never_escalates_before_tier2() {
    // First load (never running): silent below tier2, even past tier1.
    XCTAssertEqual(StatusBannerReducer.tierForLostContact(lostPolls: 20, wasEverRunning: false, policy: policy), .silent)
    XCTAssertEqual(StatusBannerReducer.tierForLostContact(lostPolls: 30, wasEverRunning: false, policy: policy), .error)
    // From-healthy: tier1 at the boundary, tier2 past it.
    XCTAssertEqual(StatusBannerReducer.tierForLostContact(lostPolls: 14, wasEverRunning: true, policy: policy), .silent)
    XCTAssertEqual(StatusBannerReducer.tierForLostContact(lostPolls: 15, wasEverRunning: true, policy: policy), .reconnecting)
    XCTAssertEqual(StatusBannerReducer.tierForLostContact(lostPolls: 30, wasEverRunning: true, policy: policy), .error)
  }
}
