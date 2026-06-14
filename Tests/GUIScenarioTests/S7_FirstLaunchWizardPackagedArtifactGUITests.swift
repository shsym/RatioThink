import XCTest

/// Package-backed first-launch proof for . Unlike the fast S7
/// scenario, this test launches the Release-built .app path recorded by the
/// wrapper script rather than resolving RatioThink by bundle identifier.
final class S7_FirstLaunchWizardPackagedArtifactGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_packaged_app_first_launch_flow_persists_after_relaunch() async throws {
    let config = try Self.loadConfig()
    let appPath = try XCTUnwrap(
      config["PIE_TEST_APP_PATH"],
      "\(Self.configPath) must define PIE_TEST_APP_PATH"
    )
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME"
    )
    let preferencesSuite = try XCTUnwrap(
      config["PIE_APP_PREFERENCES_SUITE"],
      "\(Self.configPath) must define PIE_APP_PREFERENCES_SUITE"
    )
    let initialProbePath = try XCTUnwrap(
      config["PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE"],
      "\(Self.configPath) must define PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE"
    )
    let relaunchProbePath = try XCTUnwrap(
      config["PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE"],
      "\(Self.configPath) must define PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE"
    )

    let app = try packagedApp(
      appPath: appPath,
      pieHome: pieHome,
      preferencesSuite: preferencesSuite,
      probePath: initialProbePath
    )
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Packaged Rational.app did not reach runningForeground")
    app.activate()
    try assertLaunchedArtifact(probePath: initialProbePath, expectedAppPath: appPath)

    XCTAssertTrue(app.staticTexts["Welcome to Rational"].waitForExistence(timeout: 5))
    app.buttons["Continue"].click()

    XCTAssertTrue(app.staticTexts["Keep Rational ready in the menu bar"].waitForExistence(timeout: 5))
    app.buttons["Register Rational Helper"].click()
    XCTAssertTrue(app.staticTexts["Rational Helper is registered"].waitForExistence(timeout: 5))

    // : no model step — login registration leads straight to
    // the main shell.
    app.buttons["Open Rational"].click()
    XCTAssertTrue(app.buttons["chats.newButton"].waitForExistence(timeout: 5))

    app.terminate()

    let relaunched = try packagedApp(
      appPath: appPath,
      pieHome: pieHome,
      preferencesSuite: preferencesSuite,
      probePath: relaunchProbePath
    )
    relaunched.launch()
    defer { relaunched.terminate() }

    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10),
              "Packaged Rational.app did not relaunch")
    relaunched.activate()
    try assertLaunchedArtifact(probePath: relaunchProbePath, expectedAppPath: appPath)

    XCTAssertTrue(relaunched.buttons["chats.newButton"].waitForExistence(timeout: 5))
    XCTAssertFalse(relaunched.staticTexts["Welcome to Rational"].waitForExistence(timeout: 2),
                   "First-launch wizard reappeared after completion")
  }

  private func packagedApp(
    appPath: String,
    pieHome: String,
    preferencesSuite: String,
    probePath: String
  ) throws -> XCUIApplication {
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
    app.launchEnvironment["PIE_TEST_ARTIFACT_PATH_PROBE_FILE"] = probePath
    return app
  }

  private func assertLaunchedArtifact(probePath: String, expectedAppPath: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: probePath) {
        break
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: probePath),
                  "Packaged artifact probe was not written at \(probePath)")

    let actual = try canonicalPath(String(contentsOfFile: probePath, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines))
    let expected = try canonicalPath(expectedAppPath)
    XCTAssertEqual(actual, expected,
                   "XCUITest launched \(actual), not requested artifact \(expected)")
  }

  private static let configPath = "/tmp/pie-first-launch-package-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" package-backed GUI E2E config missing at \(configPath); run Scripts/run-first-launch-package-e2e.sh")
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

  private func canonicalPath(_ path: String) throws -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}
