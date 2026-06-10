import XCTest

/// #379 — the packaged first-launch **model-download → Load-default chat**
/// chain that no other suite covers end to end. The #373 audit removed a
/// phantom `S7_FirstLaunchWizardPackagedModelDownloadGUITests` entry from the
/// catalog and filed the missing coverage as #379; this is that suite.
///
/// What is already covered elsewhere (and why this is distinct):
/// - `S7_FirstLaunchWizardPackagedArtifactGUITests` runs the packaged wizard +
///   relaunch persistence but forces **no** model step.
/// - `S326_FreshInstallModelDownloadGUITests` drives the no-model gate's inline
///   download against the *fake* downloader (no file lands, no chat).
/// - `S381_NoModelLoadDefaultGUITests` drives the no-model gate's Load-default
///   path but with the default **pre-staged** on disk — no download, no wizard,
///   not packaged.
///
/// This suite stitches them: launch the **packaged (Debug-configured) `.app`**
/// (Debug, not Release — see the wrapper's Design note: `PIE_TEST_ENGINE_BASE_URL`
/// is gated off in Release by `HelperConfig.isTestOverrideAllowed`, #325) on a
/// fresh `PIE_HOME`, complete the **first-launch wizard**, **download** the
/// seeded default curated GGUF through Settings (the deterministic
/// `EnvironmentFixtureModelDownloader`), then prove the chat resolves the
/// **persisted default**: opening a chat raises the no-model gate, which —
/// *because the just-downloaded default is on disk and the persisted profile
/// default names it* — offers **Load** (not Download); driving Load brings up
/// the deterministic `PIE_TEST_ENGINE_START_TO_RUNNING` stub engine and a send
/// streams a real reply that survives a relaunch.
///
/// Deliberately **no `PIE_TEST_CHAT_MODEL`**: the request model is not injected,
/// so the chat genuinely resolves the persisted default through the gate's
/// `needsDefaultLoad(profileDefault)` → Load path. If the persisted profile
/// default were broken, the gate would have no Load affordance and this suite
/// would fail at `noModel.load`.
final class S7_FirstLaunchWizardPackagedModelDownloadGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_first_launch_download_then_load_default_resolves_and_send_succeeds() async throws {
    let config = try Self.loadConfig()
    let appPath = try XCTUnwrap(config["PIE_TEST_APP_PATH"],
                                "\(Self.configPath) must define PIE_TEST_APP_PATH")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let preferencesSuite = try XCTUnwrap(config["PIE_APP_PREFERENCES_SUITE"],
                                         "\(Self.configPath) must define PIE_APP_PREFERENCES_SUITE")
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let curatedID = try XCTUnwrap(config["PIE_TEST_CURATED_MODEL_ID"],
                                  "\(Self.configPath) must define PIE_TEST_CURATED_MODEL_ID")
    let probePath = try XCTUnwrap(config["PIE_TEST_MODEL_DOWNLOAD_PROBE_FILE"],
                                  "\(Self.configPath) must define PIE_TEST_MODEL_DOWNLOAD_PROBE_FILE")
    let replyNeedle = config["PIE_TEST_CHAT_REPLY_NEEDLE"] ?? "bluejay-379"

    // ---- Launch 1: fresh first launch (wizard runs) --------------------
    let app = try packagedApp(appPath: appPath, pieHome: pieHome,
                              preferencesSuite: preferencesSuite, baseURL: baseURL,
                              probePath: probePath, firstLaunchCompleted: false)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Packaged Rational.app did not reach runningForeground")
    app.activate()

    try completeFirstLaunchWizard(in: app)

    // ---- Download the seeded default model through Settings ------------
    // The fixture downloader writes the curated file under PIE_HOME/models.
    // The model was absent on this fresh PIE_HOME, so this is the "downloaded
    // during first launch" step that turns the gate's offer from Download into
    // Load. Done BEFORE the first chat opens, so the launch start-prompt
    // (maybePromptEngineStartOnLaunch, evaluated once on first chat scaffold)
    // sees the model present.
    try downloadDefaultModelViaSettings(curatedID, in: app)

    // ---- The persisted default resolves via the Load-default gate -------
    openFreshChat(in: app)
    let load = app.buttons["noModel.load"]
    XCTAssertTrue(load.waitForExistence(timeout: 15),
                  "no-model gate must offer Load (the downloaded persisted default is on disk); app tree: \(app.debugDescription)")
    XCTAssertFalse(app.buttons["missingModel.download"].exists,
                   "gate must offer Load, not Download, once the default model has been downloaded")
    try driveLoadUntilDismissed(load, in: app)

    typeComposerText("Confirm the persisted default is loaded.", in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled,
                  "composer.send disabled after Load resolved the persisted default; app tree: \(app.debugDescription)")
    send.click()
    guard waitForStaticTextContaining(replyNeedle, in: app, timeout: 30) else {
      XCTFail("assistant reply '\(replyNeedle)' never rendered after Load; app tree: \(app.debugDescription)")
      return
    }

    app.terminate()

    // ---- Launch 2: relaunch reuses the persisted default + history -----
    // Skip the wizard deterministically (its persistence is S7-packaged's job);
    // prove the downloaded model + chat reply survived the relaunch.
    let relaunched = try packagedApp(appPath: appPath, pieHome: pieHome,
                                     preferencesSuite: preferencesSuite, baseURL: baseURL,
                                     probePath: probePath, firstLaunchCompleted: true)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10),
              "Packaged Rational.app did not relaunch")
    relaunched.activate()

    // The relaunch lands in the main shell, not the wizard. (Assert the shell's
    // New Chat affordance, NOT the absence of "Welcome to Rational" — that copy
    // is also the zero-state EmptyStateView headline.)
    XCTAssertTrue(relaunched.buttons["chats.newButton"].waitForExistence(timeout: 5),
                  "relaunch did not reach the main shell; app tree: \(relaunched.debugDescription)")

    try selectPersistedChat(in: relaunched)
    // Selecting the chat re-raises the once-per-launch start prompt (engine
    // idle); dismiss it without loading so the persisted transcript shows.
    dismissNoModelGateIfPresent(in: relaunched)
    guard waitForStaticTextContaining(replyNeedle, in: relaunched, timeout: 15) else {
      XCTFail("assistant reply '\(replyNeedle)' not visible after relaunch with PIE_HOME=\(pieHome); app tree: \(relaunched.debugDescription)")
      return
    }
  }

  // MARK: - Steps

  private func completeFirstLaunchWizard(in app: XCUIApplication) throws {
    XCTAssertTrue(app.staticTexts["Welcome to Rational"].waitForExistence(timeout: 10),
                  "first-launch wizard did not appear; app tree: \(app.debugDescription)")
    app.buttons["Continue"].click()

    XCTAssertTrue(app.staticTexts["Keep Rational ready in the menu bar"].waitForExistence(timeout: 5))
    app.buttons["Register Rational Helper"].click()
    XCTAssertTrue(app.staticTexts["Rational Helper is registered"].waitForExistence(timeout: 5),
                  "helper did not register (PIE_TEST_LOGIN_ITEM_STATUS faked)")

    app.buttons["Open Rational"].click()
    XCTAssertTrue(app.buttons["chats.newButton"].waitForExistence(timeout: 5),
                  "main shell did not appear after onboarding; app tree: \(app.debugDescription)")
  }

  private func downloadDefaultModelViaSettings(_ curatedID: String, in app: XCUIApplication) throws {
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear after ⌘,; app: \(app.debugDescription)")
    let modelsTab = settings.toolbars.buttons["Models"]
    XCTAssertTrue(modelsTab.waitForExistence(timeout: 10),
                  "Models settings tab missing; window: \(settings.debugDescription)")
    modelsTab.click()

    let addButton = settings.buttons["AddModelButton"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 10),
                  "AddModelButton missing on Models tab; window: \(settings.debugDescription)")
    addButton.click()

    let curatedAdd = app.buttons["CuratedAdd-\(curatedID)"]
    XCTAssertTrue(curatedAdd.waitForExistence(timeout: 10),
                  "curated Add button 'CuratedAdd-\(curatedID)' missing; app: \(app.debugDescription)")
    // Enqueues the (fixture) download AND dismisses the sheet.
    curatedAdd.click()

    // The fixture downloader yields `.completed` with `.notAdvertised`
    // verification, so the row settles on the Unverified badge; a real verified
    // download would show Done. Accept either terminal completion — this proves
    // the download ran in-session and the file landed.
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if badgeExists("ModelRow-State-Done", in: settings) { break }
      if badgeExists("ModelRow-State-Unverified", in: settings) { break }
      if settings.staticTexts["Failed"].exists {
        XCTFail("fixture download row reported Failed; window: \(settings.debugDescription)")
        return
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    XCTAssertTrue(badgeExists("ModelRow-State-Done", in: settings)
                  || badgeExists("ModelRow-State-Unverified", in: settings),
                  "download did not reach a terminal completed badge; window: \(settings.debugDescription)")

    closeWindow(settings, in: app)
  }

  /// Drive the gate's Load button until the gate dismisses (the model
  /// resolved). Re-click defends against a dropped sheet-button action under
  /// XCUITest (the hazard `openFreshChat` documents).
  private func driveLoadUntilDismissed(_ load: XCUIElement, in app: XCUIApplication) throws {
    let deadline = Date().addingTimeInterval(40)
    var clicks = 0
    while Date() < deadline {
      if !load.exists { break }
      if load.isHittable {
        load.click()
        clicks += 1
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2))
    }
    XCTAssertFalse(load.exists,
                   "Load did not resolve the persisted default (gate still up after \(clicks) click(s)); app tree: \(app.debugDescription)")
  }

  private func selectPersistedChat(in app: XCUIApplication) throws {
    let chatTitle = app.staticTexts["New Chat"].firstMatch
    XCTAssertTrue(chatTitle.waitForExistence(timeout: 10),
                  "persisted chat row 'New Chat' missing after relaunch; app tree: \(app.debugDescription)")
    chatTitle.click()
  }

  private func dismissNoModelGateIfPresent(in app: XCUIApplication) {
    let cancel = app.buttons["noModel.cancel"]
    if cancel.waitForExistence(timeout: 5), cancel.isHittable {
      cancel.click()
    }
  }

  // MARK: - Helpers

  /// Wait for any rendered static text whose label OR value contains `needle`
  /// (MarkdownUI exposes assistant runs via `value`). Narrow `.staticText`
  /// query — `descendants(.any)` can SIGBUS on a degraded session.
  private func waitForStaticTextContaining(_ needle: String,
                                           in app: XCUIApplication,
                                           timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                needle, needle)
    while Date() < deadline {
      if app.descendants(matching: .staticText).matching(predicate).count >= 1 {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  private func badgeExists(_ identifier: String, in settings: XCUIElement) -> Bool {
    settings.staticTexts[identifier].exists || settings.otherElements[identifier].exists
  }

  private func closeWindow(_ window: XCUIElement, in app: XCUIApplication) {
    let close = window.buttons[XCUIIdentifierCloseWindow]
    if close.exists {
      close.click()
    } else {
      app.typeKey("w", modifierFlags: .command)
    }
  }

  private func packagedApp(appPath: String,
                           pieHome: String,
                           preferencesSuite: String,
                           baseURL: String,
                           probePath: String,
                           firstLaunchCompleted: Bool) throws -> XCUIApplication {
    let appURL = URL(fileURLWithPath: appPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path),
                  "Packaged app artifact missing at \(appURL.path)")
    let app = XCUIApplication(url: appURL)
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_APP_PREFERENCES_SUITE"] = preferencesSuite
    app.launchEnvironment["PIE_TEST_LOGIN_ITEM_STATUS"] = "notRegistered"
    // Deterministic helperless engine: starts STOPPED and flips to RUNNING when
    // Load calls startEngine — no real Helper / pie. Pointed at the mock the
    // wrapper started (which serves the default slug). NO PIE_TEST_CHAT_MODEL:
    // the model must resolve through the persisted-default Load path.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_ENGINE_START_TO_RUNNING"] = "1"
    // Deterministic fixture downloader: lands the curated file under
    // PIE_HOME/models + writes the probe the wrapper asserts.
    app.launchEnvironment["PIE_TEST_FIXTURE_DOWNLOADS"] = "1"
    app.launchEnvironment["PIE_TEST_MODEL_DOWNLOAD_PROBE_FILE"] = probePath
    if firstLaunchCompleted {
      app.launchEnvironment["PIE_TEST_FIRST_LAUNCH_COMPLETED"] = "1"
    }
    return app
  }

  private static let configPath = "/tmp/pie-first-launch-package-model-download-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("#379 package model-download GUI E2E config missing at \(configPath); run Scripts/run-first-launch-package-model-download-e2e.sh")
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text
      .split(separator: "\n")
      .reduce(into: [:]) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let key = String(parts[0])
        let value = String(parts[1])
        if !key.isEmpty { result[key] = value }
      }
  }
}
