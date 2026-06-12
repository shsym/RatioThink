import XCTest
@testable import RatioThinkCore

final class LocalAPIAutoStartPolicyTests: XCTestCase {
  func test_disabled_policy_never_starts() {
    XCTAssertFalse(LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: false,
      status: .stopped,
      activeProfileID: "chat"))
  }

  func test_enabled_policy_starts_only_from_stopped_with_active_profile() {
    XCTAssertTrue(LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: true,
      status: .stopped,
      activeProfileID: "chat"))

    XCTAssertFalse(LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: true,
      status: .starting,
      activeProfileID: "chat"))
    XCTAssertFalse(LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: true,
      status: .running(EngineSessionSnapshot(port: 8123, profileID: "chat")),
      activeProfileID: "chat"))
    XCTAssertFalse(LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: true,
      status: .stopped,
      activeProfileID: nil))
    XCTAssertFalse(LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: true,
      status: .stopped,
      activeProfileID: ""))
  }
}
