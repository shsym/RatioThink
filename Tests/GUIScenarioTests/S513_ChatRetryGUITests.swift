import XCTest

/// #513 — retry a chat from a prior turn with a destructive truncation
/// confirm. Drives Rational.app against the deterministic mock engine
/// (`Scripts/gui-chat-stream-harness.py --mode normal --number-replies`),
/// whose numbered replies (`… [turn N]`) make erased-vs-regenerated turns
/// distinguishable. One transcript, three retry contracts:
///
///   1. EARLIER-turn retry raises the "Retry from here?" confirmation;
///      Cancel is a strict no-op (both turns stay).
///   2. Confirming erases the retry-point reply AND all later conversation
///      (the second user turn + reply), then regenerates from the retained
///      prefix — turn 3 appears, turns 1–2 and "Second question" are gone.
///   3. LATEST-turn retry skips the confirmation and replaces the stale
///      reply without accumulating duplicates.
final class S513_ChatRetryGUITests: XCTestCase {
  private let replyStem = "Deterministic reply"

  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_retry_prior_turn_confirms_truncation_and_latest_turn_skips_confirm() async throws {
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
    // No real background helper in this harness — pin the health ladder so
    // the #496 recovery overlay never covers the transcript (chat traffic
    // goes straight to the mock via PIE_TEST_ENGINE_BASE_URL).
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    normalizeWindowToVisibleScreen(in: app)

    // Two finished turns: "[turn 1]" then "[turn 2]".
    openFreshChat(in: app)
    typeComposerText("First question", in: app)
    sendComposerDraft(in: app)
    XCTAssertTrue(waitForStaticTextContaining("[turn 1]", in: app, timeout: 20),
                  "first reply never rendered; app tree: \(app.debugDescription)")
    typeComposerText("Second question", in: app)
    sendComposerDraft(in: app)
    XCTAssertTrue(waitForStaticTextContaining("[turn 2]", in: app, timeout: 20),
                  "second reply never rendered; app tree: \(app.debugDescription)")

    let retryButtons = app.buttons.matching(identifier: "transcript.retry")
    XCTAssertTrue(retryButtons.element(boundBy: 1).waitForExistence(timeout: 10),
                  "expected a retry control on both assistant turns; app tree: \(app.debugDescription)")

    // 1) Earlier-turn retry asks before erasing; Cancel is a no-op.
    retryButtons.element(boundBy: 0).click()
    let confirm = try waitForRetryConfirm(in: app)
    confirm.buttons["Cancel"].click()
    XCTAssertTrue(waitForStaticTextContaining("[turn 1]", in: app, timeout: 5),
                  "Cancel must leave the original reply in place")
    XCTAssertTrue(waitForStaticTextContaining("[turn 2]", in: app, timeout: 5),
                  "Cancel must leave the later conversation in place")

    // 2) Confirming erases the retry point + everything after, then
    //    regenerates from the retained prefix.
    retryButtons.element(boundBy: 0).click()
    let confirmAgain = try waitForRetryConfirm(in: app)
    confirmAgain.buttons["Retry"].click()
    XCTAssertTrue(waitForStaticTextContaining("[turn 3]", in: app, timeout: 20),
                  "regenerated reply never rendered; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitUntilNoStaticTextContains("[turn 2]", in: app, timeout: 10),
                  "later conversation survived a confirmed retry; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitUntilNoStaticTextContains("Second question", in: app, timeout: 5),
                  "later user turn survived a confirmed retry")
    XCTAssertTrue(waitUntilNoStaticTextContains("[turn 1]", in: app, timeout: 5),
                  "stale retry-point reply survived — duplicate assistant turns")
    XCTAssertTrue(waitForStaticTextContaining("First question", in: app, timeout: 5),
                  "retained user message must be preserved unchanged")

    // 3) Latest-turn retry: no confirmation, no duplicates — the stale
    //    reply is replaced by a fresh one.
    XCTAssertTrue(retryButtons.firstMatch.waitForExistence(timeout: 10),
                  "retry control missing on the regenerated turn")
    retryButtons.firstMatch.click()
    XCTAssertTrue(waitForStaticTextContaining("[turn 4]", in: app, timeout: 20),
                  "latest-turn retry did not regenerate (was it blocked behind a confirm?); app tree: \(app.debugDescription)")
    XCTAssertTrue(waitUntilNoStaticTextContains("[turn 3]", in: app, timeout: 10),
                  "latest-turn retry accumulated a duplicate stale assistant turn")
    XCTAssertEqual(countOfStaticTextsContaining(replyStem, in: app), 1,
                   "exactly one assistant reply must remain; app tree: \(app.debugDescription)")
  }

  // MARK: - helpers

  /// The destructive-retry confirmation container. SwiftUI `.alert` is
  /// presented as a window-modal sheet on macOS, but guard the dialog
  /// representation too so an AppKit presentation change doesn't silently
  /// turn this into a miss.
  private func waitForRetryConfirm(in app: XCUIApplication) throws -> XCUIElement {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      for container in [app.sheets.firstMatch, app.dialogs.firstMatch] where container.exists {
        if container.staticTexts["Retry from here?"].exists { return container }
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    XCTFail("'Retry from here?' confirmation never appeared; app tree: \(app.debugDescription)")
    throw XCTSkip("confirmation missing")
  }

  /// See S507: a window frame restored from another display arrangement can
  /// put bottom controls offscreen; Window ▸ Zoom snaps it back.
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

  /// See S507: keyboard send is geometry-independent where the
  /// bottom-anchored button can fail hit-testing on tall windows.
  private func sendComposerDraft(in app: XCUIApplication) {
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing; app tree: \(app.debugDescription)")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
  }

  private func waitForStaticTextContaining(_ needle: String,
                                           in app: XCUIApplication,
                                           timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if countOfStaticTextsContaining(needle, in: app) >= 1 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private func waitUntilNoStaticTextContains(_ needle: String,
                                             in app: XCUIApplication,
                                             timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if countOfStaticTextsContaining(needle, in: app) == 0 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private func countOfStaticTextsContaining(_ needle: String, in app: XCUIApplication) -> Int {
    let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", needle, needle)
    return app.descendants(matching: .staticText).matching(predicate).count
  }

  private static let configPath = "/tmp/pie-chat-retry-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("chat-retry GUI E2E config missing at \(configPath); run Scripts/run-chat-retry-gui-e2e.sh")
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
