import XCTest

///  deterministic history/resume proof:
/// Rational.app → ComposerView → HTTPEngineClient → deterministic HTTP harness,
/// with every chat request body recorded so the test can assert the
/// exact ordered message history sent on turns 2 and 3.
final class S275_MultiTurnResumeGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_multi_turn_history_survives_relaunch_and_is_sent_to_engine() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(
      config["PIE_TEST_ENGINE_BASE_URL"],
      "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL"
    )
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME"
    )
    let requestLog = try XCTUnwrap(
      config["PIE_TEST_REQUEST_LOG"],
      "\(Self.configPath) must define PIE_TEST_REQUEST_LOG"
    )
    let model = config["PIE_TEST_CHAT_MODEL"] ?? "resume-deterministic"

    let user1 = "Remember this code word: cerulean-275"
    let assistant1 = "I will remember cerulean-275."
    let user2 = "What code word did I give you?"
    let assistant2 = "The code word is cerulean-275."
    let user3 = "Repeat the code word again."

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome, baseURL: baseURL, model: model)
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    try createChatAndSend(user1, in: app)
    XCTAssertTrue(waitForStaticTextContaining(assistant1, in: app, timeout: 15),
                  "assistant turn 1 did not render; app tree: \(app.debugDescription)")

    try sendPrompt(user2, in: app)
    XCTAssertTrue(waitForStaticTextContaining(assistant2, in: app, timeout: 15),
                  "assistant turn 2 did not render; app tree: \(app.debugDescription)")

    let turn2 = try waitForRecordedRequest(at: 1, requestLog: requestLog, timeout: 10)
    XCTAssertEqual(turn2.messages, [
      .init(role: "user", content: user1),
      .init(role: "assistant", content: assistant1),
      .init(role: "user", content: user2),
    ], "turn-2 request must include ordered in-session history")

    app.terminate()

    let relaunched = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(relaunched, pieHome: pieHome, baseURL: baseURL, model: model)
    relaunched.launch()
    defer { relaunched.terminate() }

    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not relaunch")
    relaunched.activate()
    try selectPersistedChat(in: relaunched)

    try sendPrompt(user3, in: relaunched)
    XCTAssertTrue(waitForStaticTextContaining("Again: cerulean-275.", in: relaunched, timeout: 15),
                  "assistant turn 3 did not render; app tree: \(relaunched.debugDescription)")

    let turn3 = try waitForRecordedRequest(at: 2, requestLog: requestLog, timeout: 10)
    XCTAssertEqual(turn3.messages, [
      .init(role: "user", content: user1),
      .init(role: "assistant", content: assistant1),
      .init(role: "user", content: user2),
      .init(role: "assistant", content: assistant2),
      .init(role: "user", content: user3),
    ], "turn-3 request must include ordered persisted history after relaunch")
  }

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
    try sendPrompt(prompt, in: app)
  }

  private func sendPrompt(_ prompt: String, in app: XCUIApplication) throws {
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10),
                  "composer.text missing; app tree: \(app.debugDescription)")
    composer.click()
    composer.typeText(prompt)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5),
                  "composer.send missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(send.isEnabled, "composer.send was disabled after typing prompt")
    send.click()
  }

  private func selectPersistedChat(in app: XCUIApplication) throws {
    let chatTitle = app.staticTexts["New Chat"].firstMatch
    XCTAssertTrue(chatTitle.waitForExistence(timeout: 10),
                  "persisted chat row 'New Chat' missing after relaunch; app tree: \(app.debugDescription)")
    chatTitle.click()
  }

  private func waitForStaticTextContaining(
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
      if app.descendants(matching: .staticText).matching(predicate).count >= 1 {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private func waitForRecordedRequest(
    at index: Int,
    requestLog: String,
    timeout: TimeInterval
  ) throws -> RecordedChatRequest {
    let deadline = Date().addingTimeInterval(timeout)
    var last: Error?
    while Date() < deadline {
      do {
        let requests = try Self.readRecordedRequests(at: requestLog)
        if requests.count > index { return requests[index] }
      } catch {
        last = error
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    if let last { throw last }
    throw NSError(
      domain: "S275_MultiTurnResumeGUITests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "timed out waiting for request #\(index + 1) in \(requestLog)"]
    )
  }

  private static let configPath = "/tmp/pie-resume-gui-history-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" GUI history E2E config missing at \(configPath); run Scripts/run-resume-gui-history-e2e.sh")
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

  private static func readRecordedRequests(at path: String) throws -> [RecordedChatRequest] {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text
      .split(separator: "\n")
      .map { line in
        let data = Data(line.utf8)
        return try JSONDecoder().decode(RecordedChatRequest.self, from: data)
      }
  }
}

private struct RecordedChatRequest: Decodable, Equatable {
  struct Message: Decodable, Equatable {
    let role: String
    let content: String
  }

  let messages: [Message]
}
