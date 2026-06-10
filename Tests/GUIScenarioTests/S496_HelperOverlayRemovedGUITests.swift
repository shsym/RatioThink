import AppKit
import XCTest

/// #496 regression — the INVERSE of the shipped window-lock bug.
///
/// The old chat-body `HelperRecoveryOverlay` used a full-bleed
/// `maxHeight: .infinity` frame that exploded the `RootView` layout (~2176px)
/// and rendered the ENTIRE window non-interactive whenever the background Helper
/// was unreachable — the sidebar, chat list, toolbar nav, composer, and even
/// Cmd-, Settings all went dead. Measured: control(healthy)=interactive PASS vs
/// unreachable(overlay)=all-dead FAIL.
///
/// The fix deletes that overlay; the Helper state now reads on the bounded
/// window-level `UnifiedStatusBanner`. This test PINS that the window stays
/// fully interactive while the Helper is unreachable, that the overlay never
/// comes back, and that the banner carries the full Helper recovery menu
/// (Force Restart / Login Items / Collect Diagnostics).
///
/// Driven by the DEBUG `PIE_TEST_PIN_HELPER_HEALTH` seam, which short-circuits
/// the health poll so the unreachable state renders deterministically without a
/// real helper.
final class S496_HelperOverlayRemovedGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws { try guardSeatedGUI() }

  override func tearDown() {
    for home in tempHomes { try? FileManager.default.removeItem(atPath: home) }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  private func launchIntoChat(pinHelperHealth: String) -> XCUIApplication {
    let pieHome = "/tmp/pie-s496-overlay-removed-" + UUID().uuidString
    tempHomes.append(pieHome)
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = pinHelperHealth
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()
    openFreshChat(in: app)
    // A SECOND app launch in the same xcodebuild run (after a prior test's
    // terminate) can come up foreground-but-not-key, which XCUITest reports as
    // an empty `Disabled` tree. Re-assert frontmost and wait for a live control
    // so the assertions below don't race a startup focus blip.
    app.activate()
    _ = waitForHittable(app.buttons["chats.newButton"], timeout: 10)
    return app
  }

  /// Wait (retrying) until `element` is hittable — survives the transient
  /// not-key focus blips a multi-launch xcodebuild run produces, unlike a
  /// single-shot `.isHittable` read.
  @MainActor
  private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  /// Assert the window chrome is interactive via successful ACTIONS (more robust
  /// than single-element hittability snapshots, which race the not-key focus
  /// blips a multi-launch xcodebuild run produces): the sidebar new-chat button
  /// is hittable, the sidebar nav actually switches the detail column to
  /// LocalAPIView, and Cmd-, opens the separate Settings window. Before the fix
  /// the full-bleed overlay made every one of these dead.
  @MainActor
  private func assertWindowIsInteractive(_ app: XCUIApplication, context: String) {
    // Sidebar new-chat button responds (the window is not locked).
    let newButton = app.buttons["chats.newButton"]
    XCTAssertTrue(newButton.waitForExistence(timeout: 8), "[\(context)] sidebar new-chat button missing")
    XCTAssertTrue(waitForHittable(newButton, timeout: 12),
      "[\(context)] sidebar New Chat must be HITTABLE; app tree: \(app.debugDescription)")

    // Sidebar nav is LIVE: clicking API Endpoints switches the detail column to
    // LocalAPIView (a successful click + render proves both the nav and the
    // detail column accept input).
    let apiNav = app.descendants(matching: .any).matching(identifier: "API Endpoints").firstMatch
    XCTAssertTrue(apiNav.waitForExistence(timeout: 8), "[\(context)] sidebar 'API Endpoints' nav row missing")
    XCTAssertTrue(waitForHittable(apiNav, timeout: 12), "[\(context)] sidebar nav must be hittable")
    apiNav.click()
    let localAPI = app.descendants(matching: .any).matching(identifier: "LocalAPIView").firstMatch
    XCTAssertTrue(localAPI.waitForExistence(timeout: 8),
      "[\(context)] navigating to API Endpoints must render LocalAPIView; app tree: \(app.debugDescription)")

    // Settings opens via Cmd-, (a separate window; an app-wide freeze or a
    // full-bleed main-window overlay would both prevent it).
    let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 8),
      "[\(context)] Cmd-, must open the Settings window; app tree: \(app.debugDescription)")
    app.typeKey("w", modifierFlags: .command)
  }

  /// THE regression: with the Helper unreachable, the window stays interactive,
  /// the deleted overlay is absent, and the window banner carries the recovery
  /// menu. Before the fix every assertion in `assertWindowIsInteractive` failed.
  @MainActor
  func test_window_stays_interactive_when_helper_unreachable() async throws {
    let app = launchIntoChat(pinHelperHealth: "unreachable")
    defer { app.terminate() }

    // The full-bleed chat-body overlay must be GONE — its unique Restart button
    // was the "overlay is up" marker.
    XCTAssertFalse(app.buttons["helperRecovery.restart"].exists,
      "the deleted chat-body helper overlay must never reappear")

    // Accessibility gate + the core regression's first proof: the sidebar
    // new-chat button is hittable while the helper is unreachable (before the
    // fix the whole window — including this — was non-interactive).
    let newButton = app.buttons["chats.newButton"]
    XCTAssertTrue(newButton.waitForExistence(timeout: 10), "sidebar new-chat button missing")
    XCTAssertTrue(waitForHittable(newButton, timeout: 10),
      "window must be interactive (sidebar hittable) while the helper is unreachable; app tree: \(app.debugDescription)")

    // The Helper state now reads on the bounded window-level status banner,
    // carrying the full recovery menu ported from the overlay.
    XCTAssertTrue(app.buttons["status.banner.forceRestart"].waitForExistence(timeout: 5),
      "window status banner must surface Force Restart while the helper is unreachable; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.buttons["status.banner.loginItems"].exists,
      "the unreachable banner must offer Open Login Items (ported from the overlay)")
    XCTAssertTrue(app.buttons["status.banner.diagnostics"].exists,
      "the unreachable banner must offer Collect Diagnostics (ported from the overlay)")

    // The rest of the window chrome is live too (chat row, sidebar nav, Cmd-,).
    assertWindowIsInteractive(app, context: "helper unreachable")
  }

  /// Control: with the Helper healthy the window is likewise interactive and no
  /// banner recovery menu shows. Isolates any future failure of the treatment to
  /// the unreachable path rather than a harness/inactive-window artifact.
  @MainActor
  func test_control_window_interactive_and_no_recovery_menu_when_healthy() async throws {
    let app = launchIntoChat(pinHelperHealth: "healthy")
    defer { app.terminate() }

    XCTAssertFalse(app.buttons["helperRecovery.restart"].exists,
      "no helper overlay in the healthy state")
    XCTAssertFalse(app.buttons["status.banner.forceRestart"].exists,
      "no Force Restart banner when the helper is healthy")

    assertWindowIsInteractive(app, context: "helper healthy")
  }
}
