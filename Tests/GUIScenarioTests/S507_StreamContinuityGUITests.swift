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
///      cancelled partial),
///   4. sends a second held turn and cancels it via the composer's STOP
///      button (#507's user-reachable cancel — review v1 F1), asserting the
///      partial bubble is kept as a cancelled turn, and
///   5. sends a final turn to prove the composer recovered after the stop.
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
    let (app, baseURL) = try launchConfiguredApp()
    defer { app.terminate() }

    // Send a turn the mock will stream partially and then hold open.
    openFreshChat(in: app)
    typeComposerText("Generate a very long answer.", in: app)
    sendComposerDraft(in: app)

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

    // 3) Return to the original chat: the bubble holds partial + released
    //    tail, persisted while unmounted. Both rows are titled "New Chat"
    //    and the sidebar's recency order is not part of this contract, so
    //    select by CONTENT — click rows until the streamed transcript shows.
    let rows = app.staticTexts.matching(identifier: "New Chat")
    XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5),
                  "expected two chat rows; app tree: \(app.debugDescription)")
    var foundOriginal = false
    for index in 0..<rows.count {
      rows.element(boundBy: index).click()
      if waitForStaticTextContaining(holdToken, in: app, timeout: 3) {
        foundOriginal = true
        break
      }
    }
    XCTAssertTrue(foundOriginal,
                  "partial delta lost after background completion; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForStaticTextContaining(releasedReply, in: app, timeout: 10),
                  "released tail '\(releasedReply)' missing — the backgrounded stream was cancelled instead of finishing; app tree: \(app.debugDescription)")

    // 4) STOP affordance (review v1 F1): the second send holds too
    //    (--hold-count 2); mid-stream the composer's trailing control is the
    //    stop button — click it and the partial bubble must survive as a
    //    cancelled turn (kept visible, stream torn down, composer back to
    //    send).
    typeComposerText("Second held turn to stop.", in: app)
    sendComposerDraft(in: app)
    XCTAssertTrue(waitForCountOfStaticTextsContaining(holdToken, in: app, count: 2, timeout: 20),
                  "second held stream's partial never rendered; app tree: \(app.debugDescription)")
    let stop = app.buttons["composer.stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5),
                  "composer.stop missing while a turn streams; app tree: \(app.debugDescription)")
    stop.click()
    let sendBack = app.buttons["composer.send"]
    XCTAssertTrue(sendBack.waitForExistence(timeout: 10),
                  "composer did not return to send after stop; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForCountOfStaticTextsContaining(holdToken, in: app, count: 2, timeout: 5),
                  "stopped partial bubble was discarded instead of kept as a cancelled turn; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitUntilGone(rowSpinner, timeout: 10),
                  "streaming row indicator did not clear after stop; app tree: \(app.debugDescription)")

    // 5) The composer recovered after the stop — a fresh send (request 3,
    //    past --hold-count) streams a normal reply to completion.
    typeComposerText("Follow up after the stop.", in: app)
    sendComposerDraft(in: app)
    XCTAssertTrue(waitForCountOfStaticTextsContaining(releasedReply, in: app, count: 2, timeout: 20),
                  "follow-up reply never rendered after stop; app tree: \(app.debugDescription)")
  }

  /// Five chats streaming AT ONCE (#507 acceptance: independent in-flight
  /// sends across chats, scaled past the pairwise case). Starts a held
  /// stream in 5 separate chats, asserts the sidebar shows FIVE
  /// `chats.row.streaming` indicators simultaneously (counted, not
  /// firstMatch), releases all held streams (5 atomic credits — #518), and
  /// verifies every indicator clears and every chat persisted its full
  /// reply (rows selected by content, as row order is not a contract).
  @MainActor
  func test_five_chats_stream_concurrently_with_per_row_indicators() async throws {
    let chatCount = 5
    let (app, baseURL) = try launchConfiguredApp()
    defer { app.terminate() }

    // Start a held stream in each of 5 fresh chats. The first chat comes
    // from the empty-state affordance; subsequent ones from the header's
    // New Chat button. Each send must reach the harness (its partial
    // renders) before creating the next chat, so all 5 requests land in
    // hold slots deterministically.
    openFreshChat(in: app)
    for index in 1...chatCount {
      if index > 1 {
        let newChat = app.buttons["chats.newButton"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5), "chats.newButton missing")
        newChat.click()
        let composer = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5),
                      "chat \(index) composer missing; app tree: \(app.debugDescription)")
      }
      typeComposerText("Concurrent stream \(index).", in: app)
      sendComposerDraft(in: app)
      XCTAssertTrue(waitForStaticTextContaining(holdToken, in: app, timeout: 20),
                    "chat \(index)'s held partial never rendered; app tree: \(app.debugDescription)")
    }

    // All 5 chats in flight at once: one spinner PER streaming row.
    XCTAssertTrue(waitForStreamingIndicatorCount(chatCount, in: app, timeout: 15),
                  "expected \(chatCount) simultaneous chats.row.streaming indicators; app tree: \(app.debugDescription)")

    // Release every held stream while most chats are backgrounded — each
    // credit finishes exactly one held stream (#518 atomic consumption).
    try await Self.releaseHeldStream(baseURL: baseURL, count: chatCount)
    XCTAssertTrue(waitForStreamingIndicatorCount(0, in: app, timeout: 20),
                  "streaming indicators did not all clear after releasing \(chatCount) streams; app tree: \(app.debugDescription)")

    // Every chat persisted partial + released tail. Row order is not a
    // contract — visit each row and check its transcript.
    let rows = app.staticTexts.matching(identifier: "New Chat")
    XCTAssertTrue(rows.element(boundBy: chatCount - 1).waitForExistence(timeout: 5),
                  "expected \(chatCount) chat rows; app tree: \(app.debugDescription)")
    var chatsWithFullReply = 0
    for index in 0..<chatCount {
      rows.element(boundBy: index).click()
      if waitForStaticTextContaining(holdToken, in: app, timeout: 5),
         waitForStaticTextContaining(releasedReply, in: app, timeout: 5) {
        chatsWithFullReply += 1
      }
    }
    XCTAssertEqual(chatsWithFullReply, chatCount,
                   "every concurrently-streaming chat must persist partial + released tail; app tree: \(app.debugDescription)")
  }

  // MARK: - helpers

  /// Shared launch path for both scenarios: read the wrapper's env config,
  /// launch with the engine base-URL + helper-health pin seams, and
  /// normalize the window into the visible screen.
  @MainActor
  private func launchConfiguredApp() throws -> (XCUIApplication, String) {
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
    // #504: the send-gate bypass (`PIE_TEST_CHAT_MODEL`) is retired — pass
    // the REAL gate instead: new chats are pinned to the mock's model id
    // (`ChatCreation` seeds `Chat.modelID` from the PIN seam) and the
    // engine is pinned `.running` on the mock's port.
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = model
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    // #496 seam: there is no real background helper in this harness — pin
    // the health ladder healthy so it never escalates mid-test. Chat
    // traffic goes straight to the mock via PIE_TEST_ENGINE_BASE_URL and
    // never touches the helper.
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    normalizeWindowToVisibleScreen(in: app)
    return (app, baseURL)
  }

  /// Wait until the sidebar shows exactly `count` per-row streaming
  /// indicators — counted across the whole list, so five concurrent
  /// streams require five simultaneous spinners (not just a firstMatch).
  private func waitForStreamingIndicatorCount(_ count: Int,
                                              in app: XCUIApplication,
                                              timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if app.descendants(matching: .any).matching(identifier: "chats.row.streaming").count == count {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  /// The app restores its last window frame from the operator's real
  /// defaults domain; a frame saved under a different display arrangement
  /// can span past the current screen's edges, where XCUITest hit-testing
  /// fails for the offscreen controls (composer at the bottom, sidebar
  /// header at the top). Window ▸ Zoom snaps the window to the visible
  /// screen — the menu bar itself is always hittable.
  private func normalizeWindowToVisibleScreen(in app: XCUIApplication) {
    let windowMenu = app.menuBarItems["Window"]
    guard windowMenu.waitForExistence(timeout: 5) else { return }
    windowMenu.click()
    let zoom = app.menuItems["Zoom"]
    if zoom.waitForExistence(timeout: 2), zoom.isEnabled {
      zoom.click()
    } else {
      app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }
  }

  /// Submit the focused composer draft. Gates on the send button being
  /// enabled (the real product affordance), then sends with the composer's
  /// Enter shortcut: on tall windows the bottom-anchored send button can sit
  /// below the visible screen, where `click()` fails hit-testing even though
  /// the element is valid — keyboard delivery is geometry-independent.
  private func sendComposerDraft(in app: XCUIApplication) {
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing; app tree: \(app.debugDescription)")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
  }

  /// `POST /control/release?n=count` — grants `count` release credits;
  /// each finishes exactly one held stream with the normal reply + stop
  /// frame (#518 atomic consumption).
  private static func releaseHeldStream(baseURL: String, count: Int = 1) async throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(baseURL)/control/release?n=\(count)")))
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
