import XCTest

/// #496: the chat-body helper-recovery overlay. When the background Helper is
/// being brought up — or the restart ladder has given up — the chat surface
/// shows a HELPER-framed bounded recovery state instead of an engine-framed
/// gate, and a running engine is never covered by it.
///
/// Driven by the DEBUG `PIE_TEST_PIN_HELPER_HEALTH` seam (sibling of
/// `PIE_TEST_PIN_ENGINE_RUNNING`): it pins `HelperHealthController.health` so
/// the overlay's states render deterministically without a real helper. The
/// pure state×copy matrix is exhaustively proven in `HelperRecoveryGateTests`
/// (SPM); this scenario proves the live SwiftUI rendering, the engineRunning
/// gate, and the recovery-driven auto-dismiss.
final class S496_HelperRecoveryOverlayGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  override func tearDown() {
    for home in tempHomes { try? FileManager.default.removeItem(atPath: home) }
    tempHomes.removeAll()
    super.tearDown()
  }

  // MARK: - launch

  /// Launch into a completed-first-launch app with an isolated PIE_HOME and the
  /// helper-health pin set. `extraEnv` adds the engine pin for the gate case.
  @MainActor
  private func launch(pinHelperHealth: String,
                      extraEnv: [String: String] = [:]) -> XCUIApplication {
    let pieHome = "/tmp/pie-s496-" + UUID().uuidString
    tempHomes.append(pieHome)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = pinHelperHealth
    for (k, v) in extraEnv { app.launchEnvironment[k] = v }
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()
    openFreshChat(in: app)
    return app
  }

  /// The overlay's title is queried by its visible copy. SwiftUI exposes a
  /// `Text`'s string in the XCUIElement `value` (not `label`) here, so the
  /// predicate matches on `value` via a substring so the ellipsis / curly
  /// apostrophe in the copy can't make the query brittle. The copy itself is
  /// the state marker. Restricted to `.staticText` so the toolbar pip (a
  /// Button that also reflects helper health) is never mistaken for the overlay.
  private func overlayTitle(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts
      .matching(NSPredicate(format: "value CONTAINS[c] %@", fragment))
      .firstMatch
  }

  // MARK: - state 1: starting helper → calm bounded wait

  @MainActor
  func test_startingHelper_shows_bounded_wait_overlay() async throws {
    let app = launch(pinHelperHealth: "starting")
    defer { app.terminate() }

    // HELPER-framed bounded wait — never "Starting the engine…".
    let title = overlayTitle(containing: "Starting background helper", in: app)
    XCTAssertTrue(title.waitForExistence(timeout: 8),
                  "helper-starting must raise the HELPER-framed recovery overlay; app tree: \(app.debugDescription)")
    // A bounded wait offers no actions (no premature escalation).
    XCTAssertFalse(app.buttons["helperRecovery.restart"].exists,
                   "the calm starting state must not show recovery buttons")
  }

  // MARK: - state 2: unreachable → recovery actions, and Restart auto-dismisses

  @MainActor
  func test_unreachable_shows_recovery_actions_then_restart_dismisses() async throws {
    let app = launch(pinHelperHealth: "unreachable")
    defer { app.terminate() }

    // The overlay is uniquely identified by its recovery buttons: the app-wide
    // status banner shows a similar helper message but its Force Restart carries
    // a DIFFERENT id (`status.banner.forceRestart`), so the overlay's own
    // buttons — not the shared copy — are the unambiguous "overlay is up" marker.
    let restart = app.buttons["helperRecovery.restart"]
    XCTAssertTrue(restart.waitForExistence(timeout: 8),
                  "helper-unreachable must raise the recovery overlay; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.buttons["helperRecovery.loginItems"].exists, "Open Login Items action missing")
    XCTAssertTrue(app.buttons["helperRecovery.diagnostics"].exists, "Collect Diagnostics action missing")
    // …and the overlay's copy is HELPER-framed ("Background helper isn't
    // responding", matched up to the apostrophe).
    XCTAssertTrue(overlayTitle(containing: "Background helper isn", in: app).exists,
                  "overlay copy must name the helper")

    // Restart Helper simulates the repair succeeding (pinned seam) → the helper
    // comes back healthy → the overlay AUTO-DISMISSES into the normal surface.
    restart.click()
    XCTAssertTrue(waitForNonExistence(restart, timeout: 8),
                  "overlay must auto-dismiss once the helper recovers; app tree: \(app.debugDescription)")
    // Recovery lands the user back on the usable chat body.
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 3),
                  "composer must be reachable after recovery")
  }

  // MARK: - the engineRunning gate: a live engine is never covered

  @MainActor
  func test_running_engine_is_not_covered_by_overlay() async throws {
    // Same unreachable helper pin as the positive control above, BUT with the
    // engine pinned `.running`. The overlay must stay hidden — a working chat
    // is never covered by a transient helper-poll state.
    let app = launch(
      pinHelperHealth: "unreachable",
      extraEnv: [
        "PIE_TEST_ENGINE_BASE_URL": "http://127.0.0.1:9999",
        "PIE_TEST_PIN_ENGINE_RUNNING": "1",
      ]
    )
    defer { app.terminate() }

    // The chat body (composer) must be present and uncovered.
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 8),
                  "running-engine chat body must render; app tree: \(app.debugDescription)")
    // And the helper OVERLAY must NOT be up (the gate hides it on a live
    // engine). Keyed on the overlay-unique Restart button — the positive
    // control (test_unreachable_…) proves it WOULD appear without the engine
    // pin. The app-wide status banner may still note the helper; that is a
    // different surface (different id) and is not the chat-body overlay.
    XCTAssertFalse(app.buttons["helperRecovery.restart"].exists,
                   "a running engine must not be covered by the helper overlay; app tree: \(app.debugDescription)")
  }
}

/// Poll-based wait for an element to LEAVE the tree (XCUIElement has no
/// built-in `waitForNonExistence` on this toolchain). Returns true once gone.
@MainActor
private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if !element.exists { return true }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  }
  return !element.exists
}
