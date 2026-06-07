import XCTest

/// Captures README landing-page screenshots of the REAL app driven into a
/// populated, offline state.
///
/// The app is pointed at `Scripts/readme-screenshot-harness.py` (a mock pie
/// engine, no real engine / no model download) via `PIE_TEST_ENGINE_BASE_URL`,
/// and `PIE_TEST_CHAT_MODEL` satisfies the composer send-gate
/// (`ChatScaffoldView.currentModelID()`), so a sent prompt streams a canned
/// assistant reply. Models tab is populated by dummy `.gguf` files the wrapper
/// drops in `$PIE_HOME/models`. Each test attaches one window screenshot
/// (`.keepAlways`); `Scripts/capture-readme-screenshots.sh` exports them from
/// the `.xcresult` into `docs/assets/`.
///
/// Real screenshots of the real SwiftUI views — only the engine and the
/// installed-model files are mocked. Driven by the wrapper, which writes the
/// config file below; the suite XCTSkips (not fails) when run without it so a
/// plain `make test` never reds on the absence of a seated GUI / harness.
final class ReadmeScreenshotsGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  // MARK: - Tests (one screenshot each)

  @MainActor
  func test_capture_chat() async throws {
    let cfg = try Self.loadConfig()
    let app = Self.makeApp(cfg)
    app.launch()
    defer { app.terminate() }
    Self.activate(app)

    try createChatAndSend("What makes Rational different from a cloud chatbot?", in: app)
    XCTAssertTrue(
      waitForStaticTextContaining("OpenAI-compatible", in: app, timeout: 30),
      "canned assistant reply did not render; app: \(app.debugDescription)"
    )
    Self.settle()
    attach(Self.mainWindow(app).screenshot(), name: "chat")
  }

  @MainActor
  func test_capture_endpoint() async throws {
    let cfg = try Self.loadConfig()
    let app = Self.makeApp(cfg)
    app.launch()
    defer { app.terminate() }
    Self.activate(app)

    // #422: the API Endpoints section is a single live `LocalAPIView` (no
    // per-endpoint creation). Select the sidebar row and screenshot it. Its
    // read-only security section always renders; the base-URL/curl rows show
    // when the harness reports the engine running.
    let navRow = app.descendants(matching: .any)
      .matching(identifier: "API Endpoints").firstMatch
    XCTAssertTrue(navRow.waitForExistence(timeout: 15),
                  "API Endpoints nav row missing; app: \(app.debugDescription)")
    navRow.click()

    let view = app.descendants(matching: .any)
      .matching(identifier: "LocalAPIView").firstMatch
    XCTAssertTrue(view.waitForExistence(timeout: 10),
                  "LocalAPIView did not render; app: \(app.debugDescription)")
    Self.settle()
    attach(Self.mainWindow(app).screenshot(), name: "endpoint")
  }

  @MainActor
  func test_capture_models() async throws {
    let cfg = try Self.loadConfig()
    let app = Self.makeApp(cfg)
    app.launch()
    defer { app.terminate() }
    Self.activate(app)

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear after ⌘,; app: \(app.debugDescription)")
    let modelsTab = settings.toolbars.buttons["Models"]
    XCTAssertTrue(modelsTab.waitForExistence(timeout: 10),
                  "Models settings tab missing; window: \(settings.debugDescription)")
    modelsTab.click()

    // Wait for a seeded installed-model row (the wrapper drops dummy
    // `.gguf` files) so the screenshot shows a populated table.
    XCTAssertTrue(settings.buttons["AddModelButton"].waitForExistence(timeout: 10),
                  "Models tab did not render; window: \(settings.debugDescription)")
    Self.settle()
    attach(settings.screenshot(), name: "models")
  }

  // MARK: - Steps

  private func createChatAndSend(_ prompt: String, in app: XCUIApplication) throws {
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app: \(app.debugDescription)")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10),
                  "composer.text missing; app: \(app.debugDescription)")
    composer.click()
    composer.typeText(prompt)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled, "composer.send disabled (PIE_TEST_CHAT_MODEL not honored?)")
    send.click()
  }

  // MARK: - Helpers

  private func attach(_ screenshot: XCUIScreenshot, name: String) {
    let att = XCTAttachment(screenshot: screenshot)
    att.name = name
    att.lifetime = .keepAlways
    add(att)
  }

  private static func makeApp(_ cfg: [String: String]) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    if let pieHome = cfg["PIE_TEST_GUI_HOME"] { app.launchEnvironment["PIE_HOME"] = pieHome }
    if let baseURL = cfg["PIE_TEST_ENGINE_BASE_URL"] {
      app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    }
    app.launchEnvironment["PIE_TEST_CHAT_MODEL"] = cfg["PIE_TEST_CHAT_MODEL"] ?? "Qwen3-8B-Instruct"
    configureCompletedFirstLaunch(
      app, suiteName: stablePreferenceSuiteName(cfg["PIE_TEST_GUI_HOME"] ?? "readme"))
    return app
  }

  private static func activate(_ app: XCUIApplication) {
    XCTAssert(app.wait(for: .runningForeground, timeout: 15),
              "Rational.app did not reach runningForeground")
    app.activate()
  }

  /// The main app window (the only non-Settings window). Settings is a
  /// separate scene; chat/endpoint shots run before it opens.
  private static func mainWindow(_ app: XCUIApplication) -> XCUIElement {
    let main = app.windows
      .matching(NSPredicate(format: "identifier != %@", "com_apple_SwiftUI_Settings_window"))
      .firstMatch
    return main.exists ? main : app.windows.firstMatch
  }

  /// Let the final frame (streaming reply / list rows) paint before capture.
  private static func settle() {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.8))
  }

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

  private static let configPath = "/tmp/pie-readme-screenshots.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("README screenshot config missing at \(configPath); " +
                    "run Scripts/capture-readme-screenshots.sh")
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n").reduce(into: [:]) { result, line in
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return }
      let key = String(parts[0])
      if !key.isEmpty { result[key] = String(parts[1]) }
    }
  }
}
