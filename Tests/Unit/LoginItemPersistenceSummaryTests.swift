import XCTest
@testable import RatioThink

/// #420: the *Settings → General → Startup* line surfaces whether
/// RatioThink keeps its menu-bar icon / helper after the app quits, driven
/// by `LoginItemRegistrationStatus.menuBarPersistenceSummary`. Pin the
/// mapping so the copy stays honest per state (a registered helper persists;
/// every other state honestly says it won't / can't yet).
final class LoginItemPersistenceSummaryTests: XCTestCase {
  func test_enabled_says_it_persists() {
    let summary = LoginItemRegistrationStatus.enabled.menuBarPersistenceSummary
    XCTAssertTrue(summary.contains("stays in your menu bar"),
                  "an enabled registration must promise persistence: \(summary)")
  }

  func test_non_enabled_states_do_not_promise_persistence() {
    for status: LoginItemRegistrationStatus in [
      .notRegistered, .requiresApproval, .notFound, .unavailable("boom"),
    ] {
      let summary = status.menuBarPersistenceSummary
      XCTAssertFalse(summary.contains("stays in your menu bar"),
                     "\(status) must not claim persistence: \(summary)")
      XCTAssertFalse(summary.isEmpty)
    }
  }

  func test_requires_approval_routes_to_system_settings() {
    XCTAssertTrue(
      LoginItemRegistrationStatus.requiresApproval.menuBarPersistenceSummary
        .contains("System Settings"))
  }

  func test_unavailable_surfaces_reason() {
    XCTAssertTrue(
      LoginItemRegistrationStatus.unavailable("xpc down").menuBarPersistenceSummary
        .contains("xpc down"))
  }
}
