import XCTest
@testable import RatioThink

/// Pure gating + copy for the helper-unreachable escalation banner (#412).
/// The banner is the ONE loud surface for an un-auto-recoverable background
/// helper, so it must appear iff `HelperHealth == .unreachable` and stay
/// silent while the App is still reconnecting/repairing (the toolbar ring
/// carries those).
final class HelperUnreachableBannerTests: XCTestCase {

  func test_banner_only_when_unreachable() {
    XCTAssertNil(HelperUnreachableBanner.model(for: .healthy))
    XCTAssertNil(HelperUnreachableBanner.model(for: .reconnecting(consecutiveFailures: 5)))
    XCTAssertNil(HelperUnreachableBanner.model(for: .repairing(attempt: 1)))
    XCTAssertNil(HelperUnreachableBanner.model(for: .repairCoolingDown(attempt: 1, failuresSinceRepair: 1)))
    XCTAssertNotNil(HelperUnreachableBanner.model(for: .unreachable),
                    "the loud banner must show once the restart ladder has exhausted")
  }

  func test_unreachable_copy_names_the_problem_and_recovery() {
    let model = HelperUnreachableBanner.model(for: .unreachable)
    XCTAssertEqual(model?.title, "Background helper isn’t responding")
    XCTAssertEqual(model?.message.contains("couldn’t restart"), true,
                   "the message must state what failed (auto-restart) so the user knows why the actions exist")
  }
}
