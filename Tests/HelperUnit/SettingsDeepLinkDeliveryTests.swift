import XCTest
@testable import RatioThinkHelper

/// #440: guards the menu-bar Helper's half of the Settings deep-link wiring.
///
/// PR #49 (#420) unit-tested the `SettingsDeepLink.isSettings` matcher and the
/// App bundle's URL-scheme registration, but the Helper's delivery path —
/// `openSettings()` → `openPieApp(delivering:)` → `NSWorkspace.open(urls,
/// withApplicationAt:)` — had no automated guard. That is exactly the wiring
/// that silently degrades the deep link to a plain app-foreground on a
/// refactor: drop the `delivering:` argument (or the array) and the menu item
/// still foregrounds the app, just without ever opening Settings.
///
/// The test drives the real `openSettings()` on a `HelperAppDelegate` and
/// substitutes the live `NSWorkspace` launch with the `workspaceOpenOverride`
/// seam so it can assert the exact `(urls, appURL)` pair the click would hand
/// LaunchServices — without launching anything.
final class SettingsDeepLinkDeliveryTests: XCTestCase {
  func test_openSettings_delivers_settings_deeplink_to_resolved_app() throws {
    let delegate = HelperAppDelegate()
    var captured: (urls: [URL], appURL: URL)?
    delegate.workspaceOpenOverride = { urls, appURL in
      captured = (urls, appURL)
    }

    delegate.openSettings()

    let got = try XCTUnwrap(
      captured,
      "openSettings() did not route through openPieApp's workspace-open seam; "
        + "the menu-bar Settings click would have launched the app instead of "
        + "delivering the deep link")
    // The one URL delivered must be the canonical open-Settings deep link.
    // A bare app-foreground (the pre-#420 behavior) delivers nothing, so an
    // empty array here is the regression this test exists to catch.
    XCTAssertEqual(
      got.urls, [SettingsDeepLink.settingsURL],
      "menu-bar Settings… must deliver exactly [ratiothink://settings]; got \(got.urls)")
    // …and it must target the resolved parent bundle (the "launch MY install"
    // guarantee), not whichever RatioThink.app LaunchServices would pick for a
    // bare scheme open.
    XCTAssertEqual(
      got.appURL, delegate.resolvedPieAppURL(),
      "deep link must be delivered to the resolved parent RatioThink.app bundle")
  }

  /// The non-deep-link entry point (`showPie()` / "Show RatioThink") must keep
  /// delivering NO urls, so a future change that always attaches the Settings
  /// URL can't silently turn every menu click into a Settings open.
  func test_showPie_delivers_no_urls() throws {
    let delegate = HelperAppDelegate()
    var captured: (urls: [URL], appURL: URL)?
    delegate.workspaceOpenOverride = { urls, appURL in
      captured = (urls, appURL)
    }

    delegate.showPie()

    let got = try XCTUnwrap(captured, "showPie() did not route through the workspace-open seam")
    XCTAssertEqual(got.urls, [], "Show RatioThink must foreground the app with no deep link; got \(got.urls)")
  }
}
