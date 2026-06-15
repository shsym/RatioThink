import XCTest

/// #381 part 2 — the no-model send gate's GUI "Load default" affordance and its
/// follow-through.
///
/// S286 proves a send with nothing resolvable is BLOCKED behind the no-model
/// gate, but explicitly does NOT assert the gate's Load button or its
/// resolution — "the seated-session automation wedge blocks a reliable run".
/// The wedge was the Load action's REAL engine start: a `pie serve` launch over
/// the Helper is slow and flaky to drive from a seated XCUITest. This suite
/// removes that by driving the engine start through a deterministic helperless
/// stub (`PIE_TEST_ENGINE_START_TO_RUNNING`): the engine reports `.stopped`
/// until Load is tapped, then `.running`, pointed at a mock that serves the
/// staged default model. So the full path is now assertable:
///
///   chat opens → no-model gate raises with `Load <default>` → tap Load →
///   engine starts + serves the model → the gate auto-dismisses → a send streams
///   a real reply to completion.
///
/// The Load click is re-driven until the gate dismisses: on macOS XCUITest can
/// synthesize a sheet-button click whose SwiftUI action is dropped while the app
/// is settling (the same hazard `openFreshChat` documents) — the retry is the
/// harness half of the wedge fix.
final class S381_NoModelLoadDefaultGUITests: XCTestCase {
  /// Must match `Scripts/run-load-default-gui-e2e.sh` (the harness `--reply`).
  private let loadedReply = "bluejay-381"

  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_no_model_gate_load_default_resolves_and_send_succeeds() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    // The engine starts STOPPED and flips to RUNNING the instant Load calls
    // startEngine — no real Helper / pie. Deliberately NO PIE_TEST_CHAT_MODEL:
    // nothing resolves the model, so the gate must raise (and offer Load,
    // because the wrapper staged the default model on disk).
    app.launchEnvironment["PIE_TEST_ENGINE_START_TO_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    // Opening a chat with the engine idle + a default model on disk raises the
    // no-model gate (the App never silently auto-starts — it asks).
    openFreshChat(in: app)

    let load = app.buttons["noModel.load"]
    XCTAssertTrue(load.waitForExistence(timeout: 15),
                  "no-model gate Load affordance never appeared; app tree: \(app.debugDescription)")

    // Drive Load until the gate dismisses (model resolved). Re-click defends
    // against a dropped sheet-button action.
    let deadline = Date().addingTimeInterval(40)
    var clicks = 0
    while Date() < deadline {
      if !load.exists { break }
      if load.isHittable {
        load.click()
        clicks += 1
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2))
    }
    XCTAssertFalse(load.exists,
                   "Load did not resolve the model (gate still up after \(clicks) click(s)); app tree: \(app.debugDescription)")

    // The gate is gone → the composer is usable → a send now streams a reply
    // from the engine the Load brought up.
    typeComposerText("Hello once the model is loaded.", in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after the gate resolved; app tree: \(app.debugDescription)")
    send.click()
    XCTAssertTrue(waitForStaticTextContaining(loadedReply, in: app, timeout: 20),
                  "assistant reply '\(loadedReply)' never rendered after Load; app tree: \(app.debugDescription)")
  }

  /// #516 — the gate's promise is now kept: a send blocked behind the
  /// no-model gate auto-submits once Load resolves the model. The flow
  /// differs from the test above (which Loads FIRST, then sends manually):
  ///
  ///   chat opens → launch gate cancelled → type a message → Send is
  ///   BLOCKED (gate re-raises, pending send armed) → tap Load → engine
  ///   starts + serves the model → the original message sends itself —
  ///   the reply streams in with NO second interaction with the composer.
  @MainActor
  func test_516_blocked_send_auto_submits_after_load() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_ENGINE_START_TO_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    openFreshChat(in: app)

    // The launch-time engine-start prompt raises the same gate (no pending
    // send — the composer is empty). Cancel it so we can type; the
    // once-per-launch flag keeps it from re-popping on its own.
    let cancel = app.buttons["noModel.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 15),
                  "launch-time no-model gate never appeared; app tree: \(app.debugDescription)")
    // Re-drive Cancel until the sheet dismisses — the same dropped-click
    // defense as the Load loop below (a synthesized sheet-button click can
    // be dropped while the app settles / is briefly not key).
    let cancelDeadline = Date().addingTimeInterval(20)
    while Date() < cancelDeadline {
      if !cancel.exists { break }
      app.activate()
      if cancel.isHittable { cancel.click() }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
    }
    XCTAssertFalse(cancel.exists, "launch gate did not dismiss on Cancel")

    // Type the message and try to send — the gate must BLOCK the send
    // (nothing resolves a model) and re-raise with Load, arming #516's
    // pending auto-send for this exact draft.
    let pendingMessage = "auto-send me once the model loads"
    typeComposerText(pendingMessage, in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.click()

    let load = app.buttons["noModel.load"]
    XCTAssertTrue(load.waitForExistence(timeout: 15),
                  "blocked send did not raise the no-model gate; app tree: \(app.debugDescription)")

    // Drive Load until the gate dismisses (same dropped-click defense as
    // the test above).
    let deadline = Date().addingTimeInterval(40)
    var clicks = 0
    while Date() < deadline {
      if !load.exists { break }
      if load.isHittable {
        load.click()
        clicks += 1
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2))
    }
    XCTAssertFalse(load.exists,
                   "Load did not resolve the model (gate still up after \(clicks) click(s)); app tree: \(app.debugDescription)")

    // The promise: the reply streams in WITHOUT any further composer
    // interaction — no typing, no send click.
    XCTAssertTrue(waitForStaticTextContaining(loadedReply, in: app, timeout: 30),
                  "pending message did not auto-send after Load: reply '\(loadedReply)' never rendered; app tree: \(app.debugDescription)")

    // Once and only once: exactly one user bubble carries the message. The
    // bubble is one selectable NSTextView now (#636, `.textView`) — one element
    // per message body — so the exact `== 1` count holds.
    let userBubbleCount = transcriptTextMatchCount(pendingMessage, in: app)
    XCTAssertEqual(userBubbleCount, 1,
                   "pending message must send exactly once, found \(userBubbleCount); app tree: \(app.debugDescription)")
  }

  // MARK: - helpers

  private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return !element.exists
  }

  private func waitForStaticTextContaining(_ needle: String,
                                           in app: XCUIApplication,
                                           timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      // A message body is one selectable NSTextView now (#636, `.textView`),
      // not per-block `.staticText`; `transcriptTextMatchCount` searches both.
      if transcriptTextMatchCount(needle, in: app) >= 1 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private static let configPath = "/tmp/pie-load-default-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("load-default GUI E2E config missing at \(configPath); run Scripts/run-load-default-gui-e2e.sh")
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
