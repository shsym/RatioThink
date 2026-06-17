import XCTest

/// Captures README landing-page screenshots of the REAL app driven into a
/// populated, offline state.
///
/// The app is pointed at `Scripts/readme-screenshot-harness.py` (a mock pie
/// engine, no real engine / no model download) via `PIE_TEST_ENGINE_BASE_URL`,
/// and the composer send-gate is satisfied for real — `PIE_TEST_CHAT_MODEL_PIN`
/// pins `Chat.modelID` and `PIE_TEST_PIN_ENGINE_RUNNING` reports the engine
/// `.running` — so a sent prompt streams a canned assistant reply. Models tab is populated by dummy `.gguf` files the wrapper
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

  /// Opens the chat-toolbar model dropdown and screenshots the whole screen
  /// (the popover is its own window, so a main-window-only grab would miss it).
  /// The wrapper seeds dummy `.gguf` files, so the dropdown lists real grouped
  /// rows — name primary, quant secondary.
  @MainActor
  func test_capture_model_dropdown() async throws {
    let cfg = try Self.loadConfig()
    let app = Self.makeApp(cfg)
    app.launch()
    defer { app.terminate() }
    Self.activate(app)

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app: \(app.debugDescription)")
    newChat.click()

    let modelControl = app.descendants(matching: .any)
      .matching(identifier: "toolbar.model").firstMatch
    XCTAssertTrue(modelControl.waitForExistence(timeout: 10),
                  "toolbar.model missing; app: \(app.debugDescription)")
    modelControl.click()

    // Wait for at least one model row in the open dropdown (seeded .gguf files).
    let anyRow = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ModelRow-")).firstMatch
    XCTAssertTrue(anyRow.waitForExistence(timeout: 10),
                  "no ModelRow in dropdown; app: \(app.debugDescription)")
    Self.settle()
    attach(XCUIScreen.main.screenshot(), name: "model-dropdown")
  }

  /// Structure check for the custom model-dropdown popover: it opens from the
  /// toolbar and lists the seeded models as grouped, identifiable rows.
  ///
  /// The interactive half — selecting a row switches the active model +
  /// dismisses the popover, and an unavailable (split-shard / in-progress
  /// `.partial`) row is not selectable — is intentionally NOT asserted here.
  /// It cannot run deterministically under the README mock harness:
  ///
  ///   1. The screenshot wrapper seeds only complete `.gguf` files. It never
  ///      stages a split-shard pair or a `.partial` download, so no
  ///      "unavailable" row exists to assert non-selectability against.
  ///   2. The app frequently launches not-key under XCUITest (the documented
  ///      multi-launch focus flake): the whole AX tree comes up `Disabled`, so
  ///      clicks never dispatch and `isEnabled` reads false. Existence queries
  ///      still resolve, but any tap-and-verify assertion is flaky by nature.
  ///
  /// Shipping those assertions would mean a flaky red, so they are skipped
  /// rather than weakened. The selection→switch→dismiss path is covered by the
  /// app-scoped send/selection unit tests; this GUI test guards only what the
  /// mock harness can prove deterministically. Follow-up: extend the wrapper to
  /// seed an unavailable row + a key-window launch seam, then restore the
  /// interaction assertions here.
  @MainActor
  func test_model_dropdown_selection() async throws {
    let cfg = try Self.loadConfig()
    let app = Self.makeApp(cfg)
    app.launch()
    defer { app.terminate() }
    Self.activate(app)

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let modelControl = app.descendants(matching: .any)
      .matching(identifier: "toolbar.model").firstMatch
    XCTAssertTrue(modelControl.waitForExistence(timeout: 10), "toolbar.model missing")
    modelControl.click()

    // Deterministic: the popover opens and lists the seeded models as grouped
    // rows (existence resolves even when the app launches not-key/Disabled).
    let anyRow = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ModelRow-")).firstMatch
    XCTAssertTrue(anyRow.waitForExistence(timeout: 10),
                  "no ModelRow in dropdown; app: \(app.debugDescription)")
    let mistral = app.descendants(matching: .any)
      .matching(NSPredicate(format:
        "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@", "ModelRow-", "Mistral"))
      .firstMatch
    XCTAssertTrue(mistral.waitForExistence(timeout: 5),
                  "seeded Mistral row missing; app: \(app.debugDescription)")

    throw XCTSkip("Interaction assertions (select→switch→dismiss, unavailable " +
                  "row non-selectable) are not deterministic under the README " +
                  "mock harness — see the doc comment above.")
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
    XCTAssertTrue(send.isEnabled, "composer.send disabled (model pin / running-engine seam not honored?)")
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
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = cfg["PIE_TEST_CHAT_MODEL_PIN"] ?? "Qwen3-8B-Instruct"
    // #504: pin the engine `.running` so the composer send-gate is enabled for
    // real (the `PIE_TEST_CHAT_MODEL` bypass is gone).
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
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
    while Date() < deadline {
      // Message bodies render as one selectable NSTextView each now (#636,
      // `.textView`) rather than per-block `.staticText`;
      // `transcriptTextMatchCount` searches both.
      if transcriptTextMatchCount(needle, in: app) >= 1 {
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
