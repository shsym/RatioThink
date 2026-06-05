import XCTest

/// Download "Discard?" inline confirm, driven through the real GUI.
///
/// Cancelling a download arms an inline confirm (Keep / Discard); Keep keeps
/// it downloading, Discard hard-cancels it to `.cancelled`. Driven by the
/// fake downloader (`PIE_TEST_FAKE_DOWNLOADS`), which holds at `.downloading`
/// and emits `.cancelled` on cancel.
///
/// (An earlier sibling test covered an engine-boot "Stop Engine" affordance;
/// that path is superseded by the engine-status pip's start-on-demand +
/// Retry flow and was dropped.)
///
/// Narrow type queries only — `descendants(matching: .any)` can SIGBUS on a
/// degraded session (GUI-test convention).
final class S218_CancelAffordancesGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_download_cancel_confirm_keep_then_discard() throws {
    let pieHome = "/tmp/pie-s218b-" + UUID().uuidString
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // Fake downloader: holds at `.downloading`, emits `.cancelled` on cancel.
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOADS"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()

    // Settings → Models → Add Model… → a curated Add enqueues a download.
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings window missing after ⌘,")
    let modelsTab = settings.toolbars.buttons["Models"]
    XCTAssertTrue(modelsTab.waitForExistence(timeout: 10), "Models settings tab missing")
    modelsTab.click()

    let addButton = settings.buttons["AddModelButton"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 10), "AddModelButton missing")
    addButton.click()

    let curated = app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "CuratedAdd-")).firstMatch
    XCTAssertTrue(curated.waitForExistence(timeout: 10),
                  "no curated Add button; app: \(app.debugDescription)")
    curated.click()

    // The download row's Cancel arms the inline confirm (does NOT cancel yet).
    let cancel = settings.buttons["DownloadRow-Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                  "download row Cancel missing — download did not start; window: \(settings.debugDescription)")
    cancel.click()

    let keep = settings.buttons["DownloadRow-KeepDownloading"].firstMatch
    let discard = settings.buttons["DownloadRow-ConfirmCancel"].firstMatch
    XCTAssertTrue(keep.waitForExistence(timeout: 5),
                  "Keep missing after Cancel — confirm did not arm; window: \(settings.debugDescription)")
    XCTAssertTrue(discard.exists, "Discard missing after Cancel")

    // Keep backs out: confirm clears, the row stays downloading (Cancel returns).
    keep.click()
    XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                  "Keep did not restore the Cancel button — confirm stuck; window: \(settings.debugDescription)")
    XCTAssertFalse(discard.exists, "Discard still present after Keep")
    XCTAssertFalse(badgeExists("Cancelled", in: settings),
                   "row was cancelled by Keep — Keep must NOT cancel")

    // Re-arm and Discard: hard cancel → row reaches Cancelled.
    cancel.click()
    let discard2 = settings.buttons["DownloadRow-ConfirmCancel"].firstMatch
    XCTAssertTrue(discard2.waitForExistence(timeout: 5),
                  "Discard missing on re-arm; window: \(settings.debugDescription)")
    discard2.click()
    XCTAssertTrue(waitForBadge("Cancelled", in: settings, timeout: 10),
                  "download did not reach Cancelled after Discard; window: \(settings.debugDescription)")
  }

  // MARK: - helpers (narrow queries only)

  /// The `.cancelled` badge is a SwiftUI `Label` — XCUITest may surface it
  /// as `staticTexts` OR `otherElements` depending on how the Label
  /// collapses (mirrors S204's badge query).
  private func badgeExists(_ text: String, in settings: XCUIElement) -> Bool {
    settings.staticTexts[text].exists || settings.otherElements[text].exists
  }

  private func waitForBadge(_ text: String, in settings: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if badgeExists(text, in: settings) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    return false
  }
}
