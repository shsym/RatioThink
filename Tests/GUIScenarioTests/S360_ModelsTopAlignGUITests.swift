import XCTest

/// S360 — *Settings → Models* keeps its content top-aligned in the
/// empty state instead of floating at the vertical center of the pane.
///
/// Regression guard for the layout bug fixed in `ModelsSettingsTab`:
/// the pane only expanded to fill the 520-tall Settings tab when it held
/// a greedy child (the populated `Table`). The empty / loading / error
/// states sized to their content, so `TabView` centered the whole block
/// vertically and the "Installed Models" header + empty-state box drifted
/// to mid-pane. The fix pins the pane with
/// `.frame(maxHeight: .infinity, alignment: .topLeading)`, matching the
/// other Settings tabs.
///
/// Mirrors the S285 chat empty-state top-align assertion: the empty-state
/// box must live in the upper half of the Settings window, not centered.
/// Needs the SettingsRoot a11y fix (#204) so Models-tab content is
/// driveable, and an isolated empty `PIE_HOME` so no installed models
/// flip the pane into its (already top-aligned) populated `Table` state.
final class S360_ModelsTopAlignGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws { try guardSeatedGUI() }

  override func tearDown() {
    for home in tempHomes {
      try? FileManager.default.removeItem(atPath: home)
    }
    tempHomes.removeAll()
    super.tearDown()
  }

  private func makeApp() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    configureCompletedFirstLaunch(app)
    // Real shared /tmp path, NOT NSTemporaryDirectory(): the XCUITest
    // runner is sandboxed, so NSTemporaryDirectory() resolves to the
    // runner's container the non-sandboxed Rational.app cannot write.
    // A fresh dir gives an empty `PIE_HOME/models`, so the Models tab
    // renders its empty state rather than the populated `Table`.
    let home = "/tmp/pie-s360-" + UUID().uuidString
    tempHomes.append(home)
    app.launchEnvironment["PIE_HOME"] = home
    // Isolate the HF cache too: `CachedModelScan` surfaces HF-cached models in
    // the pane (`HFCacheCatalog.scan(LaunchSpecResolver.defaultHFHome())`), so
    // a populated dev cache (`~/.cache/huggingface`) would hide the empty
    // state. An empty `HF_HOME` makes the cache scan find nothing.
    app.launchEnvironment["HF_HOME"] = home + "/hf-empty"
    return app
  }

  @MainActor
  func test_models_empty_state_is_top_aligned() async throws {
    let app = makeApp()
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

    let emptyState = settings.staticTexts["No models installed yet"]
    XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                  "Models empty state missing (empty PIE_HOME/models expected); " +
                  "window: \(settings.debugDescription)")

    let addButton = settings.buttons["AddModelButton"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 5),
                  "Add Model header button missing")

    // Top-aligned: the empty-state box lives in the upper half of the
    // Settings window. A vertically-centered pane (the bug) would push
    // the box's bottom edge past the window's midline.
    XCTAssertLessThan(emptyState.frame.maxY, settings.frame.midY,
                      "Models empty state must be top-aligned in the pane, " +
                      "not vertically centered")
    // And it stays below the "Installed Models" header, preserving the
    // top-down reading order.
    XCTAssertGreaterThan(emptyState.frame.minY, addButton.frame.minY,
                         "empty-state box must sit below the Installed Models header")
  }
}
