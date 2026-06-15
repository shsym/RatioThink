import XCTest

/// S7 — fresh GUI install runs the first-launch wizard before the
/// main content shell.  reduced the wizard to helper
/// orientation + login-item registration; model choice/download moved
/// to Settings → Models, so this scenario proves helper setup,
/// orientation, that no model step is forced, and that completing the
/// wizard opens the main shell. Uses an env-backed fake for login-item
/// registration so the test never mutates the developer machine's
/// Login Items database.
///
/// Relaunch persistence of the completion flag is covered by
/// `AppPreferencesTests` (write → reopen sees the flag) and the
/// packaged-artifact RC test; it is deliberately not re-proven here.
/// The sandboxed XCUITest runner cannot read the non-sandboxed app's
/// preferences suite, and an immediate terminate→relaunch races
/// cfprefsd propagation — which is why every relaunch-style GUI test in
/// this repo re-injects completion via `PIE_TEST_FIRST_LAUNCH_COMPLETED`
/// rather than relying on cross-launch persistence.
final class S7_FirstLaunchWizardGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_first_launch_full_flow_registers_helper_then_opens_pie() async throws {
    let suite = "com.ratiothink.app.gui.s7." + UUID().uuidString
    let app = makeApp(suite: suite, loginStatus: "notRegistered")
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    XCTAssertTrue(app.staticTexts["Welcome to Rational"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Step 1 of 2"].waitForExistence(timeout: 2),
                  "wizard must advertise the reduced two-step flow")
    // : step 1 leads with the user-facing value proposition.
    XCTAssertTrue(
      app.staticTexts["Run AI models locally on your Mac — private and offline."].waitForExistence(timeout: 5),
      "step 1 must lead with the local/private value proposition"
    )
    app.buttons["Continue"].click()

    XCTAssertTrue(app.staticTexts["Keep Rational ready in the menu bar"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["Rational Helper must run in the menu bar for Rational to work. Register it as a login item so macOS can launch the helper."].waitForExistence(timeout: 5),
      "step 2 must frame Rational Helper registration as required"
    )
    XCTAssertFalse(
      app.buttons["Open Rational"].isEnabled,
      "Open Rational must not look actionable before helper registration succeeds"
    )
    let statusIndicator = app.images["FirstLaunchLoginStatusIndicator"]
    XCTAssertTrue(statusIndicator.waitForExistence(timeout: 2),
                  "helper status row must expose a non-clickable status indicator")
    XCTAssertEqual(statusIndicator.label, "Helper registration required")

    app.buttons["Register Rational Helper"].click()
    XCTAssertTrue(app.staticTexts["Rational Helper is registered"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Open Rational"].isEnabled)
    XCTAssertEqual(statusIndicator.label, "Helper registered")

    // : the wizard never forces a model download — there is
    // no model step between login-item registration and the main shell.
    XCTAssertFalse(app.staticTexts["Choose a default model"].exists,
                   "first-launch wizard must not include a model download step")

    app.buttons["Open Rational"].click()
    XCTAssertTrue(app.buttons["chats.newButton"].waitForExistence(timeout: 5),
                  "main shell must open after the two-step wizard completes")
  }

  @MainActor
  func test_requires_approval_blocks_opening_pie() async throws {
    let app = makeApp(suite: "com.ratiothink.app.gui.s7." + UUID().uuidString,
                      loginStatus: "requiresApproval")
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    XCTAssertTrue(app.staticTexts["Welcome to Rational"].waitForExistence(timeout: 5))
    app.buttons["Continue"].click()

    XCTAssertTrue(app.staticTexts["Rational Helper needs approval in System Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Open System Settings → General → Login Items and approve Rational Helper, then return here."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Open Rational"].isEnabled)
  }

  @MainActor
  func test_debug_menu_resets_onboarding_state_for_retesting() async throws {
    let app = makeApp(suite: "com.ratiothink.app.gui.s7." + UUID().uuidString,
                      loginStatus: "enabled")
    app.launchEnvironment["PIE_TEST_FIRST_LAUNCH_COMPLETED"] = "1"
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()
    XCTAssertTrue(app.buttons["chats.newButton"].waitForExistence(timeout: 5))

    let menuBar = app.menuBars.firstMatch
    XCTAssertTrue(menuBar.waitForExistence(timeout: 5), "main menu bar missing")

    let debugMenu = menuBar.menuBarItems["Debug"]
    XCTAssertTrue(debugMenu.waitForExistence(timeout: 2),
                  "Debug builds must expose a developer-only reset menu")
    let resetOnboarding = debugMenu.menuItems["Reset Onboarding State"]
    XCTAssertTrue(resetOnboarding.waitForExistence(timeout: 2),
                  "Debug menu must include onboarding reset for setup-flow retesting")
    resetOnboarding.click()

    XCTAssertTrue(app.staticTexts["Welcome to Rational"].waitForExistence(timeout: 5),
                  "debug reset should return the running app to the onboarding wizard")
  }

  @MainActor
  private func makeApp(suite: String, loginStatus: String) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_APP_PREFERENCES_SUITE"] = suite
    app.launchEnvironment["PIE_TEST_LOGIN_ITEM_STATUS"] = loginStatus
    return app
  }
}
