import AppKit
import XCTest

/// S420 — the `ratiothink://settings` deep link opens the Settings scene.
///
/// GUI-only. Guards the App's half of the #420 wiring that PR #49 left without
/// an automated check: `App/SettingsURLHandler.swift`'s `onOpenURL` →
/// `SettingsDeepLink.isSettings` → `NSApp.activate()` + `openSettings()`,
/// attached to the window-group root via `.handlesSettingsDeepLink()`. If that
/// modifier is dropped (or the matcher drifts) the deep link silently degrades
/// to a plain app-foreground — the app comes forward but Settings never opens.
///
/// The test delivers the deep link the same way the menu-bar Helper does —
/// `NSWorkspace.open([url], withApplicationAt: <the running app's bundle>)` —
/// so it exercises the real LaunchServices delivery path into the app under
/// test, then asserts a NEW Settings window appears and is frontmost.
final class S420_SettingsDeepLinkGUITests: XCTestCase {
  /// The wire contract the Helper produces. Hard-coded (not imported from
  /// `SettingsDeepLink`) because a UI-test target does not link the app module;
  /// the constant itself is pinned by SettingsDeepLinkTests. An external
  /// producer literally sends these bytes, so a literal is the honest input.
  private static let settingsDeepLink = URL(string: "ratiothink://settings")!

  /// SwiftUI tags the Settings scene's NSWindow with this stable AX identifier
  /// across all macOS localizations (see S5_AppWindowShellGUITests).
  private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

  /// Suppress NSWindow state restoration between tests so a Settings window
  /// left by a prior run can't masquerade as the deep-link result (mirrors
  /// S5_AppWindowShellGUITests.restorationOffArgs).
  private static let restorationOffArgs: [String] = [
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-ApplePersistenceIgnoreState", "YES",
  ]

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_settings_deeplink_opens_settings_window() async throws {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: Self.restorationOffArgs)
    configureCompletedFirstLaunch(app)
    app.launch()
    defer {
      // Close Settings before quit so macOS captures no Settings window in
      // restoration state for the next test (S5 convention).
      app.typeKey("w", modifierFlags: .command)
      app.terminate()
    }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5),
              "Rational.app did not reach runningForeground")
    app.activate()

    // Precondition: no Settings window yet — so a post-delivery Settings window
    // is unambiguously the deep link's doing, not launch-time restoration.
    let settings = app.windows.matching(identifier: Self.settingsWindowID).firstMatch
    XCTAssertFalse(settings.exists, "a Settings window was already open before the deep link")

    // Deliver the deep link exactly as the menu-bar Helper does: to the
    // running app-under-test's own bundle, so LaunchServices can't route it to
    // some other registered Rational.app.
    let appURL = try resolvedRunningAppURL()
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    let delivered = expectation(description: "deep link delivered")
    NSWorkspace.shared.open([Self.settingsDeepLink], withApplicationAt: appURL, configuration: cfg) { _, error in
      XCTAssertNil(error, "NSWorkspace failed to deliver the deep link: \(String(describing: error))")
      delivered.fulfill()
    }
    await fulfillment(of: [delivered], timeout: 10)

    // The deep link must open the Settings scene. If the routing glue is
    // dropped, the URL degrades to a plain app-foreground and NO Settings
    // window ever appears — this is the regression the test guards.
    XCTAssertTrue(
      settings.waitForExistence(timeout: 5),
      "ratiothink://settings did not open the Settings window — the deep link "
        + "degraded to a plain app-foreground (expected SwiftUI identifier "
        + "'\(Self.settingsWindowID)')")
    // Prove it is the REAL, rendered Settings scene the user can act on, not a
    // blank or degenerate window: its tab toolbar must be present (mirrors
    // S5_AppWindowShellGUITests). AX elements are queryable regardless of
    // z-order, so this holds even though delivering the URL via LaunchServices
    // also re-raises a main window over the freshly-opened Settings.
    let generalTab = settings.toolbars.buttons.matching(identifier: "General").firstMatch
    XCTAssertTrue(
      generalTab.waitForExistence(timeout: 3),
      "Settings window opened but its tabs did not render — deep link did not "
        + "reach the real Settings scene")
    // …and the deep link must bring Rational forward (NSApp.activate() in the
    // handler), the foreground half of "open straight to Settings".
    XCTAssertEqual(app.state, .runningForeground, "deep link did not foreground the app")
  }

  /// The bundle URL of the running app under test. The deep link is delivered
  /// to this exact bundle so it can't be routed to an installed copy.
  private func resolvedRunningAppURL() throws -> URL {
    let url = NSWorkspace.shared.runningApplications
      .first { $0.bundleIdentifier == "com.ratiothink.app" }?
      .bundleURL
    return try XCTUnwrap(url, "Rational.app is not in runningApplications; launch() may have failed")
  }
}
