import XCTest

/// #514 — Add Model marks locally-available models and blocks
/// duplicate Add actions, driven through the GUI.
///
/// Rides the S365 cache-discovery fixture run
/// (`Scripts/run-cache-discovery-gui-e2e.sh`), which stages — as the
/// normal, unsandboxed user, since the XCUITest runner cannot write
/// /tmp fixtures itself —
///   - an app-managed curated install at
///     `$PIE_HOME/models/Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`
///     (the recommended-starter slug), and
///   - a complete single-GGUF HF-cache repo for the smallest curated
///     entry (`Qwen/Qwen2.5-0.5B-Instruct-GGUF`).
///
/// In *Settings → Models → Add Model… → Curated*, the first must show
/// the "Installed" state with NO Add button, the second "In library"
/// with NO Add button — proving the `ModelAvailability` classification
/// reaches the real sheet through the real `CachedModelScan` →
/// `ModelsSettingsTab.refresh()` path, which unit tests cannot cover.
///
/// Uses narrow type queries only — `descendants(matching: .any)` can
/// SIGBUS on a degraded session (GUI-test convention).
final class S514_AddModelDuplicateGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  /// Curated id of the staged app-managed install (matches the wrapper
  /// fixture + `CuratedModelCatalog.recommendedModelID`).
  private static let installedCuratedID = "qwen3-0.6b-q8_0"
  /// Curated id of the staged HF-cache mirror (smallest curated entry).
  private static let hfCacheCuratedID = "qwen2.5-0.5b-instruct-q4_k_m"

  @MainActor
  func test_add_model_marks_installed_and_hf_cache_curated_rows() async throws {
    let app = try launchApp()
    defer { app.terminate() }
    let settings = try openSettingsTab("Models", in: app)

    let addButton = settings.buttons["AddModelButton"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 15),
                  "Add Model… button missing; window: \(settings.debugDescription)")
    addButton.click()

    // Sheet content is queried APP-scoped (the S204 pattern — the sheet
    // disables its parent window, and its content does not reliably
    // surface under the window's element subtree). The control row's
    // Add button doubles as the "sheet is open" gate: a curated model
    // staged nowhere must still offer Add — the guard must not
    // over-block.
    XCTAssertTrue(app.buttons["CuratedAdd-llama-3.2-1b-instruct-q4_k_m"]
                    .waitForExistence(timeout: 15),
                  "Add Model sheet did not open with the not-installed control "
                  + "row's Add button; app: \(app.debugDescription)")

    // Leg 1: the app-managed curated install shows "Installed", no Add.
    let installedBadge = "CuratedStatus-\(Self.installedCuratedID)"
    XCTAssertTrue(badgeExists(installedBadge, in: app, timeout: 15,
                              expectedValue: "Installed"),
                  "staged app-managed curated model did not show the Installed "
                  + "state in Add Model; app: \(app.debugDescription)")
    XCTAssertFalse(app.buttons["CuratedAdd-\(Self.installedCuratedID)"].exists,
                   "an installed curated model must not offer an Add action (#514)")

    // Leg 2: the HF-cache mirror shows "In library", no Add.
    let cacheBadge = "CuratedStatus-\(Self.hfCacheCuratedID)"
    XCTAssertTrue(badgeExists(cacheBadge, in: app, timeout: 15,
                              expectedValue: "In library"),
                  "staged HF-cache curated model did not show the In-library "
                  + "state in Add Model; app: \(app.debugDescription)")
    XCTAssertFalse(app.buttons["CuratedAdd-\(Self.hfCacheCuratedID)"].exists,
                   "an HF-cache-available curated model must not offer a redundant "
                   + "Add download (#514)")
  }

  // MARK: - Launch / navigation (S365 pattern, same config file)

  @MainActor
  private func launchApp() throws -> XCUIApplication {
    let config = try Self.loadConfig()
    let hfHome = try XCTUnwrap(config["PIE_TEST_DISCOVERY_HF_HOME"],
                               "\(Self.configPath) must define PIE_TEST_DISCOVERY_HF_HOME")
    let pieHome = try XCTUnwrap(config["PIE_TEST_DISCOVERY_PIE_HOME"],
                                "\(Self.configPath) must define PIE_TEST_DISCOVERY_PIE_HOME")

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["HF_HOME"] = hfHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    return app
  }

  @MainActor
  private func openSettingsTab(_ tab: String, in app: XCUIApplication) throws -> XCUIElement {
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear after ⌘,; app: \(app.debugDescription)")
    let tabButton = settings.toolbars.buttons[tab]
    XCTAssertTrue(tabButton.waitForExistence(timeout: 10),
                  "\(tab) settings tab missing; window: \(settings.debugDescription)")
    tabButton.click()
    return settings
  }

  /// The badge is a SwiftUI `Text` whose identifier may surface as
  /// staticTexts OR otherElements depending on host-view collapse —
  /// query both (the S204/S365 badge pattern). When found, also pin the
  /// accessibility value so "Installed" vs "In library" is asserted,
  /// not just presence.
  @MainActor
  private func badgeExists(_ identifier: String,
                           in app: XCUIApplication,
                           timeout: TimeInterval,
                           expectedValue: String) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for element in [app.staticTexts[identifier],
                      app.otherElements[identifier]] where element.exists {
        let value = element.value as? String
        // Some collapses surface the text as label instead of value.
        if value == expectedValue || element.label == expectedValue { return true }
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    return false
  }

  // MARK: - Config

  private static let configPath = "/tmp/pie-cache-discovery-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("cache-discovery GUI E2E config missing at \(configPath); "
                    + "run Scripts/run-cache-discovery-gui-e2e.sh")
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
