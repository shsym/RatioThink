import XCTest
@testable import RatioThinkCore

/// Unit tests for `SettingsDeepLink`: the `ratiothink://settings` contract
/// shared by the menu-bar Helper (producer) and the App (`onOpenURL`
/// router). A drift here silently turns the menu-bar "Settings…" deep link
/// back into a plain app-foreground, so the matcher is pinned both ways.
final class SettingsDeepLinkTests: XCTestCase {
  func test_settings_url_is_canonical_scheme_and_host() {
    XCTAssertEqual(SettingsDeepLink.settingsURL.absoluteString, "ratiothink://settings")
    XCTAssertEqual(SettingsDeepLink.scheme, "ratiothink")
    XCTAssertEqual(SettingsDeepLink.settingsHost, "settings")
  }

  func test_canonical_url_matches() {
    XCTAssertTrue(SettingsDeepLink.isSettings(SettingsDeepLink.settingsURL))
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "ratiothink://settings")!))
  }

  func test_case_insensitive_scheme_and_host() {
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "RatioThink://Settings")!))
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "RATIOTHINK://SETTINGS")!))
  }

  func test_path_spellings_match() {
    // LaunchServices / a producer typo may reshape the host into a path.
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "ratiothink:settings")!))
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "ratiothink:///settings")!))
  }

  func test_other_scheme_does_not_match() {
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "https://settings")!))
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "ratiothinkx://settings")!))
  }

  func test_other_host_does_not_match() {
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "ratiothink://models")!))
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "ratiothink://")!))
  }
}
