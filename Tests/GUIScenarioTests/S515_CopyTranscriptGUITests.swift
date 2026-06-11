import AppKit
import XCTest

/// #515: canonical copy path for a rendered transcript turn.
///
/// MarkdownUI fragments one assistant message into multiple native `Text`
/// blocks (paragraph / list / fenced code), and macOS `.textSelection`
/// cannot drag-select across them — so the supported copy path is the
/// bubble's context menu, backed by the message's canonical source text
/// (`MessageCopyPlan`). This seated GUI E2E drives the real app against the
/// deterministic stream harness (mode=normal) whose reply IS multi-section
/// Markdown, invokes context-menu "Copy Answer" on the rendered bubble, and
/// asserts `NSPasteboard.general` holds the verbatim source spanning every
/// section — code fence included.
///
/// Run via `Scripts/run-copy-gui-e2e.sh` (starts the harness, writes the
/// config file, runs this suite).
final class S515_CopyTranscriptGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_context_menu_copy_answer_spans_all_markdown_sections() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let model = config["PIE_TEST_CHAT_MODEL_PIN"] ?? "gui-stream-deterministic"
    // Unwrap the path and read separately so "key missing" and "file
    // unreadable" fail with distinct, correctly-attributed messages.
    let answerPath = try XCTUnwrap(config["PIE_TEST_EXPECTED_ANSWER_FILE"],
                                   "\(Self.configPath) must define PIE_TEST_EXPECTED_ANSWER_FILE")
    let expectedAnswer = try String(contentsOf: URL(fileURLWithPath: answerPath), encoding: .utf8)

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
    // Pin helper health so the transcript stays interactive on the
    // engine-base-URL seam (no real helper).
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }
    // The app must be frontmost or synthesized clicks never reach SwiftUI
    // actions (button stays 'Copy', pasteboard never changes — observed when
    // a single wait raced launch). Retry activation until foreground sticks.
    var foreground = false
    for _ in 0..<10 {
      app.activate()
      if app.wait(for: .runningForeground, timeout: 2) { foreground = true; break }
    }
    XCTAssert(foreground, "Rational.app did not reach runningForeground")
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10),
                  "main window missing; app tree: \(app.debugDescription)")
    // A restored window frame can sit partially offscreen in seated runs
    // (clicks at offscreen coordinates silently no-op). Zoom snaps the
    // window fully onscreen.
    let windowMenu = app.menuBarItems["Window"]
    if windowMenu.waitForExistence(timeout: 3) {
      windowMenu.click()
      let zoom = app.menuItems["Zoom"]
      if zoom.waitForExistence(timeout: 2) { zoom.click() } else { app.typeKey(.escape, modifierFlags: []) }
    }
    NSLog("S515 window frame after zoom: %@", String(describing: window.frame))

    // Send one prompt; the harness answers with the multi-section Markdown.
    openFreshChat(in: app)
    typeComposerText("render the multi-section answer", in: app)
    // Enter-send instead of clicking `composer.send`: a restored window frame
    // can leave the send button reported non-hittable in seated runs, while
    // plain Return submits via the composer's keyDown bridge regardless.
    app.typeKey(.return, modifierFlags: [])

    // The fenced code line renders last; once its canary is visible the whole
    // multi-block answer (paragraph + list + code) has landed and finished.
    XCTAssertTrue(waitForStaticTextContaining("copy515-tail", in: app, timeout: 30),
                  "assistant multi-section answer did not render; app tree: \(app.debugDescription)")

    // Poison the pasteboard so the assertion can only pass via the app's copy.
    let sentinel = "S515-PASTEBOARD-SENTINEL"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(sentinel, forType: .string)

    // The supported copy path: the explicit Copy button under the answer
    // (#515). Right-click on selectable MarkdownUI text surfaces AppKit's
    // text menu rather than the SwiftUI context menu, so the button is the
    // guaranteed affordance. Click via coordinate — selectable-text rows can
    // make XCUITest report descendants non-hittable while clicks land fine.
    let copyButton = app.buttons["message.copyAnswer"].firstMatch
    XCTAssertTrue(copyButton.waitForExistence(timeout: 5),
                  "message.copyAnswer button missing; app tree: \(app.debugDescription)")

    // XCTest can synthesize a click that the still-settling SwiftUI app never
    // delivers to the action (see Helpers.openFreshChat) — retry on the
    // product condition (pasteboard changed) instead of trusting one click.
    var copied: String? = sentinel
    for attempt in 0..<3 where copied == sentinel || copied == nil {
      // Re-assert frontmost before every click — actions silently drop into
      // a backgrounded app.
      app.activate()
      _ = app.wait(for: .runningForeground, timeout: 2)
      if copyButton.isHittable {
        copyButton.click()
      } else {
        copyButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
      }
      copied = waitForPasteboardChange(from: sentinel, timeout: 5)
      // Localize failures: the button flips to "Copied" when its SwiftUI
      // action ran — distinguishes a dropped click from a pasteboard issue.
      NSLog("S515 attempt %d: button label '%@' frame %@, pasteboard changed: %@",
            attempt, copyButton.label, String(describing: copyButton.frame),
            copied != sentinel ? "yes" : "no")
    }
    XCTAssertEqual(copied, expectedAnswer,
                   "Copy Answer must copy the verbatim multi-section Markdown source")
  }

  // MARK: - helpers

  private func waitForPasteboardChange(from sentinel: String, timeout: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let value = NSPasteboard.general.string(forType: .string), value != sentinel {
        return value
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return NSPasteboard.general.string(forType: .string)
  }

  private func waitForStaticTextContaining(_ needle: String,
                                           in app: XCUIApplication,
                                           timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                needle, needle)
    while Date() < deadline {
      if app.descendants(matching: .staticText).matching(predicate).count >= 1 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private static let configPath = "/tmp/pie-copy-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("copy GUI E2E config missing at \(configPath); run Scripts/run-copy-gui-e2e.sh")
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
