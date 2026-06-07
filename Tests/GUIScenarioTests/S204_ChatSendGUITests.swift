import XCTest

/// chat send/persist leg against the acquired model.
///
/// Phase B of the full real-model E2E (Phase A = S204_ModelAcquisition
/// downloads the GGUF via Settings). The engine harness loads THAT
/// downloaded GGUF via the portable driver; this test connects Rational.app
/// to it, sends a prompt, and verifies the real assistant answer is
/// visible and persists across relaunch.
///
/// Distinct from S258 because the curated  model
/// (`qwen2.5-0.5b-instruct-q4_k_m`) is INSTRUCT-tuned: given "The
/// capital of France is" it answers "Paris" rather than echoing the
/// prompt prefix the way the base Qwen3-0.6B does. So the assertion
/// waits for the answer token ("Paris"), not a prompt echo.
final class S204_ChatSendGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_chat_send_streams_real_assistant_and_persists_after_relaunch() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let model = config["PIE_TEST_CHAT_MODEL"] ?? "default"

    let prompt = "The capital of France is"
    let answer = "Paris"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome, baseURL: baseURL, model: model)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    try createChatAndSend(prompt, in: app)
    guard waitForStaticTextContaining(answer, in: app, timeout: 120) else {
      XCTFail("assistant answer '\(answer)' did not become visible; app tree: \(app.debugDescription)")
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

    try selectPersistedChat(in: relaunched)
    guard waitForStaticTextContaining(answer, in: relaunched, timeout: 15) else {
      XCTFail("assistant answer '\(answer)' not visible after relaunch (PIE_HOME=\(pieHome)); app tree: \(relaunched.debugDescription)")
      return
    }
  }

  // MARK: - Steps (mirror S258's proven GUI interactions)

  private func configure(_ app: XCUIApplication, pieHome: String, baseURL: String, model: String) {
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL"] = model
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
  }

  private func createChatAndSend(_ prompt: String, in app: XCUIApplication) throws {
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10),
                  "composer.text missing after creating chat; app tree: \(app.debugDescription)")
    composer.click()
    composer.typeText(prompt)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled, "composer.send was disabled after typing prompt")
    send.click()
  }

  private func selectPersistedChat(in app: XCUIApplication) throws {
    let chatTitle = app.staticTexts["New Chat"].firstMatch
    XCTAssertTrue(chatTitle.waitForExistence(timeout: 10),
                  "persisted chat row 'New Chat' missing after relaunch; app tree: \(app.debugDescription)")
    chatTitle.click()
  }

  /// Wait for any rendered static text whose label OR value contains
  /// `needle`. MarkdownUI exposes assistant runs via `value`, so the
  /// predicate checks both (same approach S258 uses for its echo
  /// check). Narrow `.staticText` query — not `descendants(.any)`.
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

  private static let configPath = "/tmp/pie-chat-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" chat E2E config missing at \(configPath); run Scripts/run-full-e2e.sh")
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
