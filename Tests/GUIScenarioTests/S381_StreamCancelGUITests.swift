import XCTest

/// #381 part 1 — cancelling an IN-FLIGHT chat stream.
///
/// The only happy-path send suites (S204/S258/S275) all stream to a clean
/// finish; none stops a generation mid-stream. This drives:
///   Rational.app → ComposerView → HTTPEngineClient → a deterministic mock that
/// streams ONE partial delta and then HOLDS the connection open with no finish
/// frame. While the stream is in flight the test navigates away (the shipped
/// cancel path: `ChatScaffoldView.onDisappear` → `ChatSendController.cancel`),
/// then asserts the two things the audit flagged as unproven:
///   1. the PARTIAL assistant bubble survives the cancel (a cancelled, non-empty
///      turn is kept — `recordCancelledAssistant`), and
///   2. the composer RECOVERS — a fresh send on the same chat streams a normal
///      reply to completion.
///
/// Engine-free of a real model: the mock (`Scripts/gui-chat-stream-harness.py`,
/// `--mode hold`) makes the mid-stream window deterministic, which a real engine
/// answering a short prompt cannot.
final class S381_StreamCancelGUITests: XCTestCase {
  /// Must match `Scripts/run-stream-cancel-gui-e2e.sh` (the harness defaults).
  private let holdToken = "PARTIAL-HOLD-381"
  private let recoveryReply = "Recovered reply after cancel."

  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_cancel_mid_stream_keeps_partial_bubble_and_recovers_composer() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let model = config["PIE_TEST_CHAT_MODEL_PIN"] ?? "gui-stream-deterministic"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
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
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    // Send a turn the mock will stream partially and then hold open.
    openFreshChat(in: app)
    typeComposerText("Generate a very long answer.", in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing; app tree: \(app.debugDescription)")
    send.click()

    // The partial delta renders only after the stream writer flushes it to the
    // row — so its visibility PROVES we are genuinely mid-stream (the mock has
    // sent no finish frame).
    XCTAssertTrue(waitForStaticTextContaining(holdToken, in: app, timeout: 20),
                  "partial assistant delta '\(holdToken)' never rendered; app tree: \(app.debugDescription)")

    // Cancel the in-flight stream the shipped way: navigate to a new chat,
    // whose selection tears down the streaming chat's view → onDisappear →
    // ChatSendController.cancel().
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 5), "chats.newButton missing")
    newChat.click()
    // Confirm we landed on the fresh, empty chat (a new composer, no partial).
    let composer = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5), "new chat composer missing after navigate-away")

    // Return to the original chat. It is the OLDER row (the new chat was created
    // last → sorts to the top by recency), so it is the second "New Chat" title.
    let originalRow = app.staticTexts.matching(identifier: "New Chat").element(boundBy: 1)
    XCTAssertTrue(originalRow.waitForExistence(timeout: 5),
                  "original chat row missing; app tree: \(app.debugDescription)")
    originalRow.click()

    // 1) The partial bubble survived the cancel (kept as a cancelled turn).
    XCTAssertTrue(waitForStaticTextContaining(holdToken, in: app, timeout: 10),
                  "partial bubble did not survive cancel; app tree: \(app.debugDescription)")

    // 2) The composer recovered — a fresh send streams a full reply.
    typeComposerText("Try again after the cancel.", in: app)
    let send2 = app.buttons["composer.send"]
    XCTAssertTrue(send2.waitForExistence(timeout: 5))
    XCTAssertTrue(send2.isEnabled, "composer.send did not re-enable after cancel; app tree: \(app.debugDescription)")
    send2.click()
    XCTAssertTrue(waitForStaticTextContaining(recoveryReply, in: app, timeout: 20),
                  "recovery reply '\(recoveryReply)' never rendered after cancel; app tree: \(app.debugDescription)")
  }

  // MARK: - helpers

  private func waitForStaticTextContaining(_ needle: String,
                                           in app: XCUIApplication,
                                           timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", needle, needle)
    while Date() < deadline {
      if app.descendants(matching: .staticText).matching(predicate).count >= 1 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private static let configPath = "/tmp/pie-stream-cancel-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("stream-cancel GUI E2E config missing at \(configPath); run Scripts/run-stream-cancel-gui-e2e.sh")
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
