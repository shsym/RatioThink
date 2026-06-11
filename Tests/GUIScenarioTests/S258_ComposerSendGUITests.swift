import XCTest

/// full GUI send path:
/// Rational.app → ChatListView → ComposerView → HTTPEngineClient →
/// real pie engine stream → MessageStreamWriter → SwiftData persistence.
final class S258_ComposerSendGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_composer_send_streams_real_assistant_and_persists_after_relaunch() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(
      config["PIE_TEST_ENGINE_BASE_URL"],
      "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL"
    )
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME"
    )
    let model = config["PIE_TEST_CHAT_MODEL_PIN"] ?? "Qwen/Qwen3-0.6B"

    let prompt = "The capital of France is"
    let visibleAssistantEcho = "The capital of Fra"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome, baseURL: baseURL, model: model)
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    try createChatAndSend(prompt, in: app)
    guard waitForAssistantEchoInAssistantBubble(visibleAssistantEcho, in: app, timeout: 120) else {
      XCTFail("assistant response did not become visible through the GUI; app tree: \(app.debugDescription)")
      return
    }

    app.terminate()

    let relaunched = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(relaunched, pieHome: pieHome, baseURL: baseURL, model: model)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not relaunch")
    relaunched.activate()

    selectPersistedChat(titled: prompt, in: relaunched)
    guard waitForAssistantEchoInAssistantBubble(visibleAssistantEcho, in: relaunched, timeout: 15) else {
      XCTFail("assistant response was not visible after relaunch with PIE_HOME=\(pieHome); app tree: \(relaunched.debugDescription)")
      return
    }
  }

  private func configure(_ app: XCUIApplication, pieHome: String, baseURL: String, model: String) {
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = model
    // #504: pin the engine `.running` so the real send-gate passes (the
    // `PIE_TEST_CHAT_MODEL` bypass is gone); the actual send still hits
    // `PIE_TEST_ENGINE_BASE_URL`, whose port the pin is derived from.
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
  }

  private func createChatAndSend(_ prompt: String, in app: XCUIApplication) throws {
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10),
                  "composer.text missing after creating chat; app tree: \(app.debugDescription)")
    composer.click()
    composer.typeText(prompt)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5),
                  "composer.send missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(send.isEnabled, "composer.send was disabled after typing prompt")
    send.click()
  }

  /// MarkdownUI may fragment a single message into multiple Accessibility
  /// static-text runs, and the prompt text also appears in the user bubble
  /// plus the auto-titled sidebar row. Scope the visibility assertion to the
  /// assistant message container so a fragmented user bubble can never make
  /// this pass with zero assistant output. The wrapper script still performs
  /// the semantic/persistence assertion against SwiftData after XCUITest
  /// returns.
  private func waitForAssistantEchoInAssistantBubble(
    _ needle: String,
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicate = NSPredicate(
      format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
      needle,
      needle
    )
    while Date() < deadline {
      let assistantMessages = app.descendants(matching: .any)
        .matching(identifier: "message.assistant")
      for index in 0..<assistantMessages.count {
        if assistantMessages.element(boundBy: index)
          .descendants(matching: .staticText)
          .matching(predicate)
          .firstMatch
          .exists {
          return true
        }
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  /// `xcodebuild test` does not reliably pass ad-hoc shell env vars
  /// through to the UI-test runner on all local Xcode builds. The
  ///  wrapper script writes this fixed config file after
  /// its engine harness has a live loopback URL, and the test uses
  /// those values to populate `XCUIApplication.launchEnvironment`.
  private static let configPath = "/tmp/pie-chat-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" GUI E2E config missing at \(configPath); run Scripts/run-chat-gui-e2e.sh")
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
