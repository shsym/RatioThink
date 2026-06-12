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
    // Scheme and host are case-insensitive per RFC 3986; the matcher
    // normalises both. Uses the canonical authority spelling, whose parsing
    // is stable across Foundation versions.
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "ratiothink://SETTINGS")!))
    XCTAssertTrue(SettingsDeepLink.isSettings(URL(string: "ratiothink://Settings")!))
  }

  func test_models_settings_url_selects_models_tab() {
    let route = SettingsDeepLink.route(for: SettingsDeepLink.modelsSettingsURL)
    XCTAssertEqual(SettingsDeepLink.modelsSettingsURL.absoluteString, "ratiothink://settings?tab=models")
    XCTAssertEqual(route, .settings(tab: .models))
  }

  func test_plain_settings_url_has_no_requested_tab() {
    XCTAssertEqual(SettingsDeepLink.route(for: SettingsDeepLink.settingsURL), .settings(tab: nil))
  }

  func test_other_scheme_does_not_match() {
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "https://settings")!))
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "ratiothinkx://settings")!))
  }

  func test_other_host_does_not_match() {
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "ratiothink://models")!))
    XCTAssertFalse(SettingsDeepLink.isSettings(URL(string: "ratiothink://")!))
  }

  // MARK: - quit (#448)

  func test_quit_url_is_canonical_scheme_and_host() {
    XCTAssertEqual(SettingsDeepLink.quitURL.absoluteString, "ratiothink://quit")
    XCTAssertEqual(SettingsDeepLink.quitHost, "quit")
  }

  func test_quit_matcher_pins_canonical_and_case_insensitive() {
    XCTAssertTrue(SettingsDeepLink.isQuit(SettingsDeepLink.quitURL))
    XCTAssertTrue(SettingsDeepLink.isQuit(URL(string: "ratiothink://quit")!))
    XCTAssertTrue(SettingsDeepLink.isQuit(URL(string: "ratiothink://QUIT")!))
  }

  func test_quit_and_settings_routes_are_disjoint() {
    // A drift that aliased the two hosts would make ⌘-clicking Settings quit
    // the app (or vice-versa) — pin them mutually exclusive.
    XCTAssertFalse(SettingsDeepLink.isQuit(SettingsDeepLink.settingsURL))
    XCTAssertFalse(SettingsDeepLink.isSettings(SettingsDeepLink.quitURL))
    XCTAssertFalse(SettingsDeepLink.isQuit(URL(string: "https://quit")!))
    XCTAssertFalse(SettingsDeepLink.isQuit(URL(string: "ratiothink://")!))
  }
}
