import XCTest

/// Settings model-acquisition leg, driven through the GUI.
///
/// Rational.app → Settings (⌘,) → Models tab → Add Model… → Curated → the
/// real in-process `ModelDownloader` (no `PIE_TEST_*_DOWNLOADS` fakes)
/// → a real Hugging Face download → the completed download row's badge.
///
/// The row distinguishes three terminal states ( F1):
/// - `ModelRow-State-Done` (green) — `.completed` with
///   `verification == .verified`, i.e. the body sha256 matched HF's
///   `X-Linked-Etag` (captured from the resolve 302 redirect, ).
/// - `ModelRow-State-Unverified` (orange) — `.completed` but
///   `.notAdvertised`: sha256 verification was SKIPPED (e.g. a resumed
///   download that never re-hit the resolve 302). The bytes are
///   installed WITHOUT an integrity check.
/// - "Failed" — a verify failure or transport error.
///
/// This test asserts the *verified* badge specifically, so a green run
/// is genuine proof the sha256 matched (the  fix) — not merely that
/// the download completed. An Unverified completion FAILS the test.
///
/// Requires the Settings TabView a11y fix in `SettingsRoot.tab()`
///: the content root is an `.accessibilityElement(children:
/// .contain)` container, so the Models-tab controls keep their own
/// identifiers instead of all reporting "Models".
///
/// Uses narrow type queries only — `descendants(matching: .any)` can
/// SIGBUS on a degraded session (GUI-test convention).
final class S204_ModelAcquisitionGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_settings_curated_download_verifies_and_completes() async throws {
    let config = try Self.loadConfig()
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let modelID = config["PIE_TEST_ACQUIRE_MODEL_ID"] ?? "qwen2.5-0.5b-instruct-q4_k_m"
    let timeout = TimeInterval(config["PIE_TEST_ACQUIRE_TIMEOUT"].flatMap(Double.init) ?? 600)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    let settings = try openModelsSettings(in: app)
    try addCuratedModel(modelID, in: app, settings: settings)

    switch waitForDownloadOutcome(in: settings, timeout: timeout) {
    case .verified:
      break
    case .unverified:
      XCTFail("download completed UNVERIFIED (ModelRow-State-Unverified) — sha256 was not checked against X-Linked-Etag ( F1); window: \(settings.debugDescription)")
    case .failed:
      XCTFail("download row reported Failed — sha256 verification rejected the bytes ( regression?); window: \(settings.debugDescription)")
    case .timedOut:
      XCTFail("download did not reach a terminal badge within \(timeout)s; window: \(settings.debugDescription)")
    }
  }

  // MARK: - Steps

  private func openModelsSettings(in app: XCUIApplication) throws -> XCUIElement {
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear after ⌘,; app: \(app.debugDescription)")
    let modelsTab = settings.toolbars.buttons["Models"]
    XCTAssertTrue(modelsTab.waitForExistence(timeout: 10),
                  "Models settings tab missing; window: \(settings.debugDescription)")
    modelsTab.click()
    return settings
  }

  private func addCuratedModel(_ modelID: String,
                               in app: XCUIApplication,
                               settings: XCUIElement) throws {
    let addButton = settings.buttons["AddModelButton"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 10),
                  "AddModelButton missing on Models tab; window: \(settings.debugDescription)")
    addButton.click()

    let curatedAdd = app.buttons["CuratedAdd-\(modelID)"]
    XCTAssertTrue(curatedAdd.waitForExistence(timeout: 10),
                  "curated Add button 'CuratedAdd-\(modelID)' missing; app: \(app.debugDescription)")
    // Clicking Add enqueues the download AND dismisses the sheet
    // (AddModelSheet.queueDownload → onClose(.queueDownload) + dismiss).
    curatedAdd.click()
  }

  // MARK: - Outcome polling (narrow staticText queries)

  private enum DownloadOutcome { case verified, unverified, failed, timedOut }

  /// Poll the row's terminal badge by its dedicated accessibility
  /// identifier ( F6) — NOT the bare label text, which would
  /// collide with AddModelSheet's `Button("Done")`. The verified and
  /// unverified states carry distinct identifiers so a skipped
  /// integrity check (F1) can never masquerade as success here.
  private func waitForDownloadOutcome(in settings: XCUIElement,
                                      timeout: TimeInterval) -> DownloadOutcome {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if settings.staticTexts["Failed"].exists { return .failed }
      if badgeExists("ModelRow-State-Unverified", in: settings) { return .unverified }
      if badgeExists("ModelRow-State-Done", in: settings) { return .verified }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2))
    }
    return .timedOut
  }

  /// F9: the badge is a SwiftUI `Label` (image + text), whose
  /// `.accessibilityIdentifier` attaches to the composite element.
  /// XCUITest may surface that as `staticTexts` OR `otherElements`
  /// depending on how the Label collapses, so query both by identifier
  /// — never rely on a single element type for the badge identifier
  /// (a mismatch would otherwise turn into an opaque `.timedOut`).
  /// Empirically `staticTexts[id]` resolved in the green E2E run; the
  /// `otherElements` fallback keeps the assertion robust if SwiftUI's
  /// exposure shifts. Narrow type queries only (no `descendants(.any)`).
  private func badgeExists(_ identifier: String, in settings: XCUIElement) -> Bool {
    settings.staticTexts[identifier].exists || settings.otherElements[identifier].exists
  }

  // MARK: - Config / launch

  private func configure(_ app: XCUIApplication, pieHome: String) {
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // No PIE_TEST_FAKE_DOWNLOADS / PIE_TEST_FIXTURE_DOWNLOADS — run the
    // real in-process ModelDownloader against live Hugging Face.
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
  }

  private static let configPath = "/tmp/pie-real-model-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" GUI E2E config missing at \(configPath); run Scripts/run-gui-e2e.sh")
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
