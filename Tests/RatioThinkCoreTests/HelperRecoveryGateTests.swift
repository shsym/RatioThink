import XCTest
@testable import RatioThinkCore

/// Exhaustive coverage of the `HelperRecoveryGate` reducer — the pure decision
/// behind #496's chat-body helper-recovery overlay. The matrix is helper-ladder
/// state × `engineRunning`; the rules are (1) a running engine always hides the
/// overlay, (2) a healthy helper on an idle engine hides it (the no-model gate
/// owns that), (3) every active-recovery ladder state shows the bounded wait,
/// (4) only `.unreachable` escalates.
final class HelperRecoveryGateTests: XCTestCase {

  // MARK: - engineRunning hides the overlay for EVERY helper state

  func test_engineRunning_hides_overlay_regardless_of_helper() {
    let states: [HelperHealth] = [
      .healthy,
      .reconnecting(consecutiveFailures: 3),
      .repairing(attempt: 1),
      .repairCoolingDown(attempt: 1, failuresSinceRepair: 2),
      .unreachable,
    ]
    for helper in states {
      XCTAssertEqual(
        HelperRecoveryGate.evaluate(helper: helper, engineRunning: true),
        .hidden,
        "a running engine must never be covered (helper=\(helper))"
      )
    }
  }

  // MARK: - engine not running: helper axis drives the overlay

  func test_healthy_helper_idle_engine_hides_overlay() {
    // Helper fine, engine idle → the normal "Load default?" gate owns this,
    // NOT the helper overlay (and nothing auto-starts — #286).
    XCTAssertEqual(
      HelperRecoveryGate.evaluate(helper: .healthy, engineRunning: false),
      .hidden
    )
  }

  func test_reconnecting_shows_bounded_wait_immediately() {
    // Included so app start shows "Starting background helper…" from the first
    // failed poll instead of an inert missing-helper chat.
    XCTAssertEqual(
      HelperRecoveryGate.evaluate(helper: .reconnecting(consecutiveFailures: 1), engineRunning: false),
      .startingHelper
    )
    XCTAssertEqual(
      HelperRecoveryGate.evaluate(helper: .reconnecting(consecutiveFailures: 9), engineRunning: false),
      .startingHelper
    )
  }

  func test_repairing_shows_bounded_wait() {
    XCTAssertEqual(
      HelperRecoveryGate.evaluate(helper: .repairing(attempt: 2), engineRunning: false),
      .startingHelper
    )
  }

  func test_cooling_down_shows_bounded_wait() {
    XCTAssertEqual(
      HelperRecoveryGate.evaluate(
        helper: .repairCoolingDown(attempt: 1, failuresSinceRepair: 3),
        engineRunning: false
      ),
      .startingHelper
    )
  }

  func test_unreachable_escalates() {
    XCTAssertEqual(
      HelperRecoveryGate.evaluate(helper: .unreachable, engineRunning: false),
      .unreachable
    )
  }

  // MARK: - copy: helper-framed, never engine-framed (#496 core fix)

  func test_hidden_has_no_copy() {
    XCTAssertNil(HelperRecoveryGate.copy(for: .hidden))
  }

  func test_startingHelper_copy_is_a_bounded_helper_wait_not_engine_framed() {
    let copy = HelperRecoveryGate.copy(for: .startingHelper)
    XCTAssertEqual(copy?.title, "Starting background helper…")
    // The subject is the HELPER, never the engine — that misattribution is the
    // bug #496 fixes (the old chat-body framing read "Starting the engine…").
    XCTAssertFalse(copy?.title.localizedCaseInsensitiveContains("engine") ?? true)
    XCTAssertTrue(copy?.message.localizedCaseInsensitiveContains("background") ?? false)
  }

  func test_unreachable_copy_names_the_helper_and_the_full_recovery_menu() {
    let copy = HelperRecoveryGate.copy(for: .unreachable)
    XCTAssertEqual(copy?.title, "Background helper isn’t responding")
    let message = copy?.message ?? ""
    XCTAssertTrue(message.localizedCaseInsensitiveContains("restart"))
    XCTAssertTrue(message.localizedCaseInsensitiveContains("login items"))
    XCTAssertTrue(message.localizedCaseInsensitiveContains("diagnostics"))
  }
}
