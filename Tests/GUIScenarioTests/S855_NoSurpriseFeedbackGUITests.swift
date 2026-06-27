import XCTest

final class S855_NoSurpriseFeedbackGUITests: XCTestCase {
  private var tempHomes: [String] = []
  private let servedModel = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"

  override func setUp() async throws { try guardSeatedGUI() }

  override func tearDown() {
    for home in tempHomes { try? FileManager.default.removeItem(atPath: home) }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  func test_local_api_external_access_restart_shows_confirm_busy_and_success_feedback() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    let external = externalAccessToggle(in: app)
    XCTAssertTrue(external.waitForExistence(timeout: 10), "external access toggle missing; app: \(app.debugDescription)")
    external.click()

    let confirm = app.buttons["LocalAPIExternalAccessConfirmRestart"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "restart confirmation missing; app: \(app.debugDescription)")
    confirm.click()

    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIExternalAccessRestarting").firstMatch.waitForExistence(timeout: 5),
                  "restart busy feedback missing; app: \(app.debugDescription)")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIExternalAccessRestartSucceeded").firstMatch.waitForExistence(timeout: 10),
                  "restart success feedback missing; app: \(app.debugDescription)")
  }

  @MainActor
  func test_banner_force_restart_and_diagnostics_show_waiting_and_completion_feedback() throws {
    let diagnosticsApp = launchHelperUnreachable()
    let diagnostics = diagnosticsApp.buttons["status.banner.diagnostics"].firstMatch
    XCTAssertTrue(diagnostics.waitForExistence(timeout: 10), "diagnostics button missing; app: \(diagnosticsApp.debugDescription)")
    diagnostics.click()
    XCTAssertTrue(diagnosticsApp.descendants(matching: .any).matching(identifier: "status.banner.action.running").firstMatch.waitForExistence(timeout: 5),
                  "diagnostics running feedback missing; app: \(diagnosticsApp.debugDescription)")
    XCTAssertTrue(diagnosticsApp.descendants(matching: .any).matching(identifier: "status.banner.action.succeeded").firstMatch.waitForExistence(timeout: 20),
                  "diagnostics completion feedback missing; app: \(diagnosticsApp.debugDescription)")
    diagnosticsApp.terminate()

    let app = launchHelperUnreachable()
    let restart = app.buttons["status.banner.forceRestart"].firstMatch
    XCTAssertTrue(restart.waitForExistence(timeout: 10), "Force Restart missing; app: \(app.debugDescription)")
    restart.click()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "status.banner.action.running").firstMatch.waitForExistence(timeout: 5),
                  "banner restart running feedback missing; app: \(app.debugDescription)")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "status.banner.action.succeeded").firstMatch.waitForExistence(timeout: 10),
                  "banner restart completion feedback missing; app: \(app.debugDescription)")
    app.terminate()
  }

  @MainActor
  func test_banner_helper_restart_failure_shows_failed_feedback_without_success() throws {
    let app = launchHelperUnreachable(pinnedRestartResult: "fail")
    defer { app.terminate() }

    let restart = app.buttons["status.banner.forceRestart"].firstMatch
    XCTAssertTrue(restart.waitForExistence(timeout: 10), "Force Restart missing; app: \(app.debugDescription)")
    restart.click()

    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "status.banner.action.failed").firstMatch.waitForExistence(timeout: 5),
                  "banner restart failure feedback missing; app: \(app.debugDescription)")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "status.banner.action.succeeded").firstMatch.waitForExistence(timeout: 1),
                   "unreachable helper restart unexpectedly showed success; app: \(app.debugDescription)")
  }

  @MainActor
  private func launchPinnedRunning() -> XCUIApplication {
    let pieHome = "/tmp/pie-s855-local-api-" + UUID().uuidString
    tempHomes.append(pieHome)
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: ["-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_SERVED_MODEL"] = servedModel
    app.launchEnvironment["PIE_TEST_LOCAL_API_EXTERNAL_ACCESS_DELAY_MS"] = "2500"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()
    return app
  }

  @MainActor
  private func launchHelperUnreachable(pinnedRestartResult: String? = nil) -> XCUIApplication {
    let pieHome = "/tmp/pie-s855-banner-" + UUID().uuidString
    tempHomes.append(pieHome)
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: ["-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "unreachable"
    if let pinnedRestartResult {
      app.launchEnvironment["PIE_TEST_PIN_HELPER_RESTART"] = pinnedRestartResult
    }
    app.launchEnvironment["PIE_TEST_DIAGNOSTICS_FAKE_ZIP"] = "/tmp/pie-s855-diagnostics.zip"
    app.launchEnvironment["PIE_TEST_DIAGNOSTICS_DELAY_MS"] = "2500"
    app.launchEnvironment["PIE_TEST_STATUS_ACTION_DELAY_MS"] = "2500"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()
    return app
  }

  @MainActor
  private func openLocalAPIPanel(in app: XCUIApplication) -> XCUIElement {
    let panel = app.descendants(matching: .any).matching(identifier: "LocalAPIView").firstMatch
    selectSidebarSection("API Endpoints", until: panel, in: app)
    XCTAssertTrue(panel.waitForExistence(timeout: 10), "LocalAPIView missing after selecting API Endpoints; app: \(app.debugDescription)")
    return panel
  }

  @MainActor
  private func externalAccessToggle(in app: XCUIApplication) -> XCUIElement {
    let toggle = app.descendants(matching: .any).matching(identifier: "LocalAPIExternalAccessToggle").firstMatch
    if toggle.waitForExistence(timeout: 2) { return toggle }

    let security = app.descendants(matching: .any).matching(identifier: "LocalAPISecurity").firstMatch
    XCTAssertTrue(security.waitForExistence(timeout: 5), "Local API security section missing before locating external access toggle; app: \(app.debugDescription)")
    for _ in 0..<6 where !toggle.exists {
      app.scrollViews.firstMatch.swipeUp()
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    return toggle
  }
}
