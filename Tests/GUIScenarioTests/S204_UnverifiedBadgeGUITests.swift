import XCTest

///  F10 — the durable "Unverified" marker is visible on the
/// Installed-models row after a rescan/restart, not just on the live
/// download row.
///
/// The wrapper stages two GGUFs under the shared PIE_HOME/models before
/// launch: one with a `<file>.unverified` sidecar and one clean. The
/// app rescans on the Models tab; this test asserts the unverified row
/// carries the `InstalledRow-Unverified-<id>` badge and the clean row
/// does NOT — proving the marker survives a fresh scan (no live
/// download in this test) and does not false-positive.
///
/// Needs the SettingsRoot a11y fix so Models-tab content is
/// driveable. No network/engine — pure rescan of staged files.
final class S204_UnverifiedBadgeGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_installed_row_flags_unverified_after_rescan() async throws {
    let config = try Self.loadConfig()
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let unverifiedID = config["PIE_TEST_UNVERIFIED_ID"] ?? "u/unverified.gguf"
    let cleanID = config["PIE_TEST_CLEAN_ID"] ?? "c/clean.gguf"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear; app: \(app.debugDescription)")
    let modelsTab = settings.toolbars.buttons["Models"]
    XCTAssertTrue(modelsTab.waitForExistence(timeout: 10),
                  "Models tab missing; window: \(settings.debugDescription)")
    modelsTab.click()

    // The staged rows render on rescan; wait for the unverified badge.
    let unverifiedBadge = "InstalledRow-Unverified-\(unverifiedID)"
    let cleanBadge = "InstalledRow-Unverified-\(cleanID)"
    guard waitForBadge(unverifiedBadge, in: settings, timeout: 15) else {
      XCTFail("Installed row for \(unverifiedID) did not show the Unverified badge; window: \(settings.debugDescription)")
      return
    }
    XCTAssertFalse(badgeExists(cleanBadge, in: settings),
                   "the clean model \(cleanID) must NOT show an Unverified badge")
  }

  private func waitForBadge(_ id: String, in settings: XCUIElement,
                            timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if badgeExists(id, in: settings) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  /// The badge is an `Image` with an `.accessibilityIdentifier` inside a
  /// SwiftUI `Table` cell; query the types it could surface as without
  /// `descendants(.any)` (SIGBUS-prone).
  private func badgeExists(_ id: String, in settings: XCUIElement) -> Bool {
    settings.images[id].exists
      || settings.otherElements[id].exists
      || settings.staticTexts[id].exists
  }

  private static let configPath = "/tmp/pie-unverified-badge.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" unverified-badge config missing at \(configPath); run Scripts/run-unverified-badge-e2e.sh")
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
