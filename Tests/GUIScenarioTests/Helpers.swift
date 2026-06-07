import AppKit
import XCTest

/// Skip when no seated GUI session present (e.g. SSH without Screen Sharing).
///
/// The XCTRunner template ships with `com.apple.security.app-sandbox=true`, so
/// `Process` cannot exec `/usr/bin/pgrep`. Query the workspace instead — the
/// Dock's bundle identifier is stable and `runningApplications` is
/// sandbox-safe.
func guardSeatedGUI() throws {
  let dockRunning = NSWorkspace.shared.runningApplications.contains { app in
    app.bundleIdentifier == "com.apple.dock"
  }
  try XCTSkipUnless(dockRunning,
                    "No seated GUI session detected (Dock not running). " +
                    "Connect via Screen Sharing / sit at the console to run GUI tests.")
}

func configureCompletedFirstLaunch(
  _ app: XCUIApplication,
  suiteName: String = "com.ratiothink.app.gui." + UUID().uuidString
) {
  app.launchEnvironment["PIE_APP_PREFERENCES_SUITE"] = suiteName
  app.launchEnvironment["PIE_TEST_FIRST_LAUNCH_COMPLETED"] = "1"
}

func stablePreferenceSuiteName(_ seed: String) -> String {
  let safe = seed.map { char -> Character in
    char.isLetter || char.isNumber ? char : "."
  }
  return "com.ratiothink.app.gui." + String(safe).prefix(180)
}

func noModelPrompt(in app: XCUIApplication) -> XCUIElement {
  app.descendants(matching: .any)
    .matching(identifier: "noModel.prompt")
    .firstMatch
}

func missingModelDownloadButton(in app: XCUIApplication) -> XCUIElement {
  let identified = app.buttons["missingModel.download"]
  if identified.exists { return identified }
  return app.buttons.matching(
    NSPredicate(format: "label BEGINSWITH[c] %@", "Download ")
  ).firstMatch
}

@MainActor
func openFreshChat(
  in app: XCUIApplication,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let composer = app.descendants(matching: .any)
    .matching(identifier: "composer.text")
    .firstMatch
  if composer.waitForExistence(timeout: 1) { return }

  // Prefer the larger empty-state affordances when a test starts from an empty
  // chat DB and fall back to the tiny 14pt header icon only when needed. In
  // macOS GUI runs XCTest can synthesize a click yet leave the SwiftUI action
  // undelivered while the app is busy settling; after each real user affordance
  // click, wait on the product condition (chat scaffold appears) before trying
  // the next affordance.
  let candidates: [(String, XCUIElement)] = [
    ("empty chat-list New Chat", app.buttons["chats.empty.newButton"]),
    ("detail Start Chat", app.buttons["Start Chat"]),
    ("header New Chat", app.buttons["chats.newButton"]),
  ]

  var sawCandidate = false
  for (label, button) in candidates {
    guard button.waitForExistence(timeout: 2) else { continue }
    sawCandidate = true
    button.click()
    if composer.waitForExistence(timeout: 5) { return }
    NSLog("openFreshChat: %@ click did not open composer; trying next affordance", label)
  }

  if !sawCandidate {
    XCTFail("New Chat affordance missing; app tree: \(app.debugDescription)", file: file, line: line)
  } else {
    XCTFail("New Chat action must open the chat scaffold; app tree: \(app.debugDescription)",
            file: file, line: line)
  }
}

@MainActor
func typeComposerText(
  _ text: String,
  in app: XCUIApplication,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let composer = app.descendants(matching: .any)
    .matching(identifier: "composer.text")
    .firstMatch
  guard composer.waitForExistence(timeout: 10) else {
    XCTFail("composer.text missing; app tree: \(app.debugDescription)", file: file, line: line)
    return
  }

  // `composer.text` is a SwiftUI TextEditor backed by an NSScrollView at the
  // bottom of the window. XCUIElement.click() can intermittently fail to find
  // a hit point for that scroll view (`{{inf, inf}, {0, 0}}`) even while the
  // accessibility frame is valid. Anchor the tap on the main window and offset
  // to the composer's visible center; this avoids the stale element hit-point
  // path while still focusing the real editor.
  let window = app.windows.firstMatch
  guard window.waitForExistence(timeout: 5) else {
    XCTFail("main window missing; app tree: \(app.debugDescription)", file: file, line: line)
    return
  }
  let frame = composer.frame
  guard !frame.isEmpty else {
    XCTFail("composer.text has empty frame; app tree: \(app.debugDescription)", file: file, line: line)
    return
  }
  window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    .withOffset(CGVector(dx: frame.midX - window.frame.minX,
                         dy: frame.midY - window.frame.minY))
    .click()

  // Prefer paste over per-character `typeText`: the macOS text input/IME path
  // can stall XCUITest for tens of seconds on long strings, while Cmd-V still
  // drives the real editor and binding with one deterministic event.
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
  app.typeKey("v", modifierFlags: .command)
}
