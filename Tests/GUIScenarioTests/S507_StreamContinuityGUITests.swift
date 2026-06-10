import XCTest

/// #507 — an in-flight chat stream SURVIVES switching chats, and the sidebar
/// marks the streaming chat with a per-row indicator.
///
/// Replaces S381_StreamCancelGUITests: #381 shipped navigate-away as the
/// cancel path (`ChatScaffoldView.onDisappear` → `cancel`); #507 inverts that
/// contract — sends are owned by the app-scoped `ChatSendCoordinator`, so
/// navigation must NOT cancel. This drives:
///   Rational.app → ComposerView → HTTPEngineClient → a deterministic mock
/// that streams ONE partial delta and HOLDS the connection (no finish frame),
/// then finishes on demand via the harness's `POST /control/release`. While
/// the stream is held the test:
///   1. navigates to a NEW chat and asserts the original row shows the
///      `chats.row.streaming` indicator (per-chat in-flight state),
///   2. releases the held stream WHILE THE CHAT IS BACKGROUNDED and asserts
///      the indicator clears (the stream ran to a normal finish off-screen),
///   3. returns to the original chat and asserts the bubble holds the FULL
///      reply (partial + released tail persisted via SwiftData — not a
///      cancelled partial), and
///   4. sends a fresh turn to prove the composer is live after the
///      background completion.
///
/// Engine-free of a real model: the mock (`Scripts/gui-chat-stream-harness.py`,
/// `--mode hold`) makes the mid-stream window deterministic, which a real
/// engine answering a short prompt cannot.
final class S507_StreamContinuityGUITests: XCTestCase {
  /// Must match `Scripts/run-stream-cancel-gui-e2e.sh`. The harness streams
  /// `releasedReply` BOTH as the released tail of the held stream and as the
  /// finished reply of every subsequent request, so the follow-up send is
  /// asserted by a second occurrence.
  private let holdToken = "PARTIAL-HOLD-507"
  private let releasedReply = "Released reply after background switch."

  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_stream_survives_chat_switch_with_row_indicator_and_finishes_in_background() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let model = config["PIE_TEST_CHAT_MODEL"] ?? "gui-stream-deterministic"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL"] = model
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

    // Switch to a new chat MID-STREAM. #507: this must NOT cancel the stream.
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 5), "chats.newButton missing")
    newChat.click()
    let composer = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5), "new chat composer missing after switch")

    // 1) The backgrounded chat's row shows the per-chat streaming indicator.
    let rowSpinner = app.descendants(matching: .any).matching(identifier: "chats.row.streaming").firstMatch
    XCTAssertTrue(rowSpinner.waitForExistence(timeout: 10),
                  "streaming row indicator missing while a backgrounded chat streams; app tree: \(app.debugDescription)")

    // 2) Finish the held stream WHILE the chat is backgrounded — a cancelled
    //    stream could never consume this finish. The indicator must clear.
    try await Self.releaseHeldStream(baseURL: baseURL)
    XCTAssertTrue(waitUntilGone(rowSpinner, timeout: 15),
                  "streaming row indicator did not clear after the stream finished; app tree: \(app.debugDescription)")

    // 3) Return to the original chat (the OLDER row → second "New Chat" title):
    //    the bubble holds partial + released tail, persisted while unmounted.
    let originalRow = app.staticTexts.matching(identifier: "New Chat").element(boundBy: 1)
    XCTAssertTrue(originalRow.waitForExistence(timeout: 5),
                  "original chat row missing; app tree: \(app.debugDescription)")
    originalRow.click()
    XCTAssertTrue(waitForStaticTextContaining(holdToken, in: app, timeout: 10),
                  "partial delta lost after background completion; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForStaticTextContaining(releasedReply, in: app, timeout: 10),
                  "released tail '\(releasedReply)' missing — the backgrounded stream was cancelled instead of finishing; app tree: \(app.debugDescription)")

    // 4) The composer is live after the background completion — a fresh send
    //    streams a normal reply to completion.
    typeComposerText("Follow up after the background finish.", in: app)
    let send2 = app.buttons["composer.send"]
    XCTAssertTrue(send2.waitForExistence(timeout: 5))
    XCTAssertTrue(send2.isEnabled, "composer.send not enabled after stream finished; app tree: \(app.debugDescription)")
    send2.click()
    XCTAssertTrue(waitForCountOfStaticTextsContaining(releasedReply, in: app, count: 2, timeout: 20),
                  "follow-up reply never rendered; app tree: \(app.debugDescription)")
  }

  // MARK: - helpers

  /// `POST /control/release` — tells the harness to finish the held stream
  /// with the normal reply + stop frame.
  private static func releaseHeldStream(baseURL: String) async throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(baseURL)/control/release")))
    request.httpMethod = "POST"
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode
    XCTAssertEqual(status, 200, "harness /control/release returned \(String(describing: status))")
  }

  private func waitForStaticTextContaining(_ needle: String,
                                           in app: XCUIApplication,
                                           timeout: TimeInterval) -> Bool {
    waitForCountOfStaticTextsContaining(needle, in: app, count: 1, timeout: timeout)
  }

  private func waitForCountOfStaticTextsContaining(_ needle: String,
                                                   in app: XCUIApplication,
                                                   count: Int,
                                                   timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", needle, needle)
    while Date() < deadline {
      if app.descendants(matching: .staticText).matching(predicate).count >= count { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private static let configPath = "/tmp/pie-stream-cancel-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("stream-continuity GUI E2E config missing at \(configPath); run Scripts/run-stream-cancel-gui-e2e.sh")
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
