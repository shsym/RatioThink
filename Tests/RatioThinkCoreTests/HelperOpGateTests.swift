import XCTest
@testable import RatioThinkCore

/// `HelperOpGate` (#496): the pure decision that refuses an engine MUTATION
/// (start / stop / restart) while the background Helper transport isn't healthy.
/// Mirrors the `StatusBannerReducer` test style — value-only, no engine/XPC.
///
/// Contract: `.healthy` allows (nil); every NON-healthy ladder state refuses —
/// the in-progress states (`reconnecting` / `repairing` / `repairCoolingDown`)
/// with the calm `.starting` reason, and the terminal `.unreachable` with the
/// loud `.unreachable` reason. The mapping is exhaustive so adding a
/// `HelperHealth` case forces a decision here.
final class HelperOpGateTests: XCTestCase {

  func test_healthy_allows_the_op() {
    XCTAssertNil(HelperOpGate.evaluate(.healthy),
                 "a healthy helper must allow every engine mutation")
  }

  func test_reconnecting_refuses_with_starting() {
    // Even a single transient blip refuses (no fallback) — the op succeeds once
    // a poll recovers the helper.
    XCTAssertEqual(HelperOpGate.evaluate(.reconnecting(consecutiveFailures: 1)), .starting)
    XCTAssertEqual(HelperOpGate.evaluate(.reconnecting(consecutiveFailures: 9)), .starting)
  }

  func test_repairing_and_coolingDown_refuse_with_starting() {
    XCTAssertEqual(HelperOpGate.evaluate(.repairing(attempt: 1)), .starting)
    XCTAssertEqual(HelperOpGate.evaluate(.repairing(attempt: 2)), .starting)
    XCTAssertEqual(
      HelperOpGate.evaluate(.repairCoolingDown(attempt: 1, failuresSinceRepair: 3)),
      .starting)
  }

  func test_unreachable_refuses_with_unreachable() {
    XCTAssertEqual(HelperOpGate.evaluate(.unreachable), .unreachable)
  }

  /// The refusal carries helper-framed copy — never engine-framed — so a Helper
  /// state can never read as an engine fault at the call site (#496 core).
  func test_copy_is_helper_framed_not_engine_framed() {
    for reason in [HelperUnavailable.starting, .unreachable] {
      let msg = reason.message
      XCTAssertTrue(msg.lowercased().contains("helper"),
                    "refusal copy must name the helper: \(msg)")
      XCTAssertFalse(msg.lowercased().contains("engine"),
                     "refusal copy must NOT frame the helper state as an engine fault: \(msg)")
    }
  }

  /// `helperOwnsBanner` (the suppression axis the chat body reads) and
  /// `HelperOpGate` are two facets of the same "helper is the live fault"
  /// judgement, but they are deliberately NOT identical: the gate refuses on the
  /// first transient blip (`reconnecting`), while the window banner stays calm
  /// (silent) until the ladder is actively repairing. This pins that intended
  /// relationship so neither drifts silently.
  func test_relationship_to_helperOwnsBanner() {
    // Banner-owning states always refuse the op…
    for h in [HelperHealth.repairing(attempt: 1),
              .repairCoolingDown(attempt: 1, failuresSinceRepair: 0),
              .unreachable] {
      XCTAssertTrue(StatusBannerReducer.helperOwnsBanner(h))
      XCTAssertNotNil(HelperOpGate.evaluate(h))
    }
    // …and `reconnecting` is the asymmetric case: gate refuses, banner silent.
    XCTAssertFalse(StatusBannerReducer.helperOwnsBanner(.reconnecting(consecutiveFailures: 1)))
    XCTAssertNotNil(HelperOpGate.evaluate(.reconnecting(consecutiveFailures: 1)))
    // Healthy: both agree it is fine.
    XCTAssertFalse(StatusBannerReducer.helperOwnsBanner(.healthy))
    XCTAssertNil(HelperOpGate.evaluate(.healthy))
  }
}
