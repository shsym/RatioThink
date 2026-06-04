import XCTest

/// #218 cancel affordances, driven through the real GUI.
///
/// (A) "Stop Engine" honest load-cancel: the model-load indicator's
///     `.engineNotReady` ("Engine starting…") popover offers **Stop Engine**
///     (a11y `modelLoad.popover.stopEngine`), which terminates the boot and
///     returns the app to a clean `.idle` slate. Driven engine-free: with no
///     `PIE_TEST_ENGINE_BASE_URL` and no running Helper, `requireBaseURL()`
///     throws `engineNotReady`, so the no-model-gate Load (`loadDirect`)
///     lands `ModelLoadCenter` in `.engineNotReady`.
///     NOTE: the GUI tier proves the UI contract (the action is "Stop Engine",
///     not the old "Dismiss", and tapping it clears the boot ring). The
///     `stopEngine()` XPC termination itself needs a real Helper and is
///     covered by `EngineStatusStore` unit tests.
///
/// (B) Download "Discard?" inline confirm: cancelling a download arms an
///     inline confirm (Keep / Discard); Keep keeps it downloading, Discard
///     hard-cancels it to `.cancelled`. Driven by the fake downloader
///     (`PIE_TEST_FAKE_DOWNLOADS`), which holds at `.downloading` and emits
///     `.cancelled` on cancel.
///
/// Narrow type queries only — `descendants(matching: .any)` can SIGBUS on a
/// degraded session (GUI-test convention).
final class S218_CancelAffordancesGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  // MARK: - (A) Stop Engine on .engineNotReady

  @MainActor
  func test_engineNotReady_popover_offers_stop_engine_and_returns_to_idle() throws {
    let pieHome = "/tmp/pie-s218a-" + UUID().uuidString
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // No PIE_TEST_ENGINE_BASE_URL → baseURLProvider resolves
    // EngineStatusStore.requireBaseURL(), which throws `engineNotReady`
    // because no Helper reports `.running`.
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()

    // New chat → attempt send → no-model gate → Load the seeded profile
    // default → loadDirect → ModelLoadCenter.engineNotReady.
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer.text missing")
    composer.click()
    composer.typeText("trigger no-model gate")

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    send.click()

    // The no-model prompt's container `.accessibilityIdentifier("noModel.prompt")`
    // masks the inner button ids (same masking S302 documents for popovers),
    // so query the Load button by its visible label.
    let load = app.sheets.firstMatch.buttons
      .matching(NSPredicate(format: "label == %@", "Load")).firstMatch
    XCTAssertTrue(load.waitForExistence(timeout: 5),
                  "no-model prompt did not offer Load — seeded profile default missing? app: \(app.debugDescription)")
    load.click()

    // The load cannot reach a running engine → `.engineNotReady`; the
    // toolbar indicator surfaces "Engine starting".
    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(indicator.waitForExistence(timeout: 10),
                  "toolbar.modelLoadIndicator missing; app: \(app.debugDescription)")
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Engine starting", timeout: 10),
      "indicator never showed 'Engine starting' (.engineNotReady); label=\(indicator.label); app: \(app.debugDescription)")

    // The popover's action must be "Stop Engine" (#218), not the old
    // "Dismiss". The popover container id masks the inner button id
    // (`modelLoad.popover.stopEngine`), so query by visible label —
    // finding it by the "Stop Engine" label IS the proof the action copy
    // is correct (the old "Dismiss" label would not match).
    XCTAssertTrue(openIndicatorPopover(indicator, in: app),
                  "indicator popover did not open; app: \(app.debugDescription)")
    let stop = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Stop Engine")).firstMatch
    XCTAssertTrue(stop.waitForExistence(timeout: 5),
                  "engineNotReady popover did not offer 'Stop Engine' (#218 — regressed to 'Dismiss'?); app: \(app.debugDescription)")
    stop.click()

    // Returns to a clean idle slate — the boot ring clears (no stale
    // "Engine starting").
    XCTAssertTrue(
      waitUntilLabelClears(indicator, prefix: "Engine starting", timeout: 10),
      "indicator stayed 'Engine starting' after Stop Engine; label=\(indicator.label); app: \(app.debugDescription)")
  }

  // MARK: - (B) Download "Discard?" inline confirm

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

  @MainActor
  private func openIndicatorPopover(_ indicator: XCUIElement, in app: XCUIApplication) -> Bool {
    var attempts = 0
    while app.popovers.count == 0 && attempts < 5 {
      attempts += 1
      indicator.click()
      let deadline = Date().addingTimeInterval(2.0)
      while Date() < deadline {
        if app.popovers.count > 0 { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
      }
    }
    return app.popovers.count > 0
  }

  private func waitForLabel(_ element: XCUIElement,
                            beginsWith prefix: String,
                            timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.exists, element.label.hasPrefix(prefix) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  private func waitUntilLabelClears(_ element: XCUIElement,
                                    prefix: String,
                                    timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists || !element.label.hasPrefix(prefix) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

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
