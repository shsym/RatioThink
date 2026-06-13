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

/// Stable signal that the no-model send gate (`NoModelLoadedPrompt`) is
/// raised. Asserts the gate's always-present Cancel control
/// (`noModel.cancel`), which `NoModelLoadedPrompt.actions(_:)` renders
/// unconditionally in EVERY gate state (busy / needsLoad / noDefault /
/// download / engineFailed / …) — so it is the state-independent "gate is up"
/// marker the engine-free gate tests want.
///
/// The prior `noModel.prompt` container identifier never matched: the prompt
/// deliberately carries NO container id (it propagated down and overrode the
/// child control ids — see the comment in `NoModelLoadedPrompt.body`), so the
/// children carry their own ids and the container has none. Asserting Cancel
/// matches the product's accessibility design instead of a removed id.
func noModelPrompt(in app: XCUIApplication) -> XCUIElement {
  app.descendants(matching: .any)
    .matching(identifier: "noModel.cancel")
    .firstMatch
}

@MainActor
func closeSettingsWindowIfPresent(in app: XCUIApplication) {
  let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
  guard settings.waitForExistence(timeout: 0.5) else { return }
  app.activate()
  let close = settings.buttons[XCUIIdentifierCloseWindow]
  if close.exists, close.isHittable {
    close.click()
  } else {
    app.typeKey("w", modifierFlags: .command)
  }

  let deadline = Date().addingTimeInterval(3)
  while settings.exists, Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
  }
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
  closeSettingsWindowIfPresent(in: app)

  let composer = app.descendants(matching: .any)
    .matching(identifier: "composer.text")
    .firstMatch
  // #577: the Chats launch landing is now a NON-persisting new-chat draft
  // composer (no chat row until the first send). Most callers of
  // `openFreshChat` want a PERSISTED chat to interact with (type/send, prune,
  // rename, select), so we cannot early-return on the draft composer's
  // presence — that would hand back a chat with no row. Always click a New
  // Chat affordance (which persists immediately) and confirm a real row landed
  // in the sidebar before returning.
  let firstRow = app.descendants(matching: .any)
    .matching(identifier: "chats.row")
    .firstMatch

  // Prefer the larger empty-state affordance when a test starts from an empty
  // chat DB and fall back to the header icon otherwise. In macOS GUI runs
  // XCTest can synthesize a click yet leave the SwiftUI action undelivered
  // while the app is busy settling; after each real user affordance click,
  // wait on the product condition (a persisted row + composer) before trying
  // the next affordance.
  let candidates: [(String, XCUIElement)] = [
    ("empty chat-list New Chat", app.buttons["chats.empty.newButton"]),
    ("header New Chat", app.buttons["chats.newButton"]),
  ]

  // A LATER launch in a multi-test run can come up not-key, presenting an
  // EMPTY accessibility tree (Application=Disabled) — every affordance
  // query then misses even though the UI is fine. Re-activate and re-scan
  // until the tree is live instead of failing on the first empty sweep.
  var sawCandidate = false
  let scanDeadline = Date().addingTimeInterval(20)
  repeat {
    for (label, button) in candidates {
      guard button.waitForExistence(timeout: 2) else { continue }
      sawCandidate = true
      button.click()
      if firstRow.waitForExistence(timeout: 5), composer.waitForExistence(timeout: 5) { return }
      NSLog("openFreshChat: %@ click did not open a persisted chat; trying next affordance", label)
    }
    if !sawCandidate {
      NSLog("openFreshChat: no affordance visible (empty tree?); re-activating")
      app.activate()
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
    }
  } while !sawCandidate && Date() < scanDeadline

  if !sawCandidate {
    XCTFail("New Chat affordance missing; app tree: \(app.debugDescription)", file: file, line: line)
  } else {
    XCTFail("New Chat action must open the chat scaffold; app tree: \(app.debugDescription)",
            file: file, line: line)
  }
}

/// Select a persisted chat row in the sidebar by its title. #512: a chat
/// with real conversation is auto-titled from its first user message, so
/// after a relaunch the persisted row is found by that derived title — the
/// "New Chat" placeholder now only ever names an empty draft (which pruning
/// deletes). Shared by every suite that relaunches and reselects a chat.
@MainActor
func selectPersistedChat(
  titled title: String,
  in app: XCUIApplication,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let chatList = app.descendants(matching: .any)
    .matching(identifier: "chats.list")
    .firstMatch
  XCTAssertTrue(chatList.waitForExistence(timeout: 10),
                "chat list missing before selecting persisted row '\(title)'; app tree: \(app.debugDescription)",
                file: file, line: line)

  let chatTitle = chatList.staticTexts[title].firstMatch
  XCTAssertTrue(chatTitle.waitForExistence(timeout: 10),
                "persisted chat row '\(title)' missing after relaunch; app tree: \(app.debugDescription)",
                file: file, line: line)

  let composer = app.descendants(matching: .any)
    .matching(identifier: "composer.text")
    .firstMatch
  let deadline = Date().addingTimeInterval(10)
  repeat {
    app.activate()
    chatTitle.click()
    if composer.waitForExistence(timeout: 1) { return }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
  } while Date() < deadline

  XCTFail("persisted chat row '\(title)' did not open the chat scaffold; app tree: \(app.debugDescription)",
          file: file, line: line)
}

/// Click a sidebar nav row (by accessibility identifier) and wait until
/// `target` mounts in the detail column, re-activating + retrying the click to
/// survive a not-key launch where a synthesized click can be silently dropped
/// (the multi-launch focus hazard — a later launch in a multi-test run comes up
/// not-key, so a single click is unreliable). Mirrors `selectPersistedChat`'s
/// activate-and-retry loop for the nav-row case (#577).
@MainActor
func selectSidebarSection(
  _ identifier: String,
  until target: XCUIElement,
  in app: XCUIApplication,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let navRow = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  XCTAssertTrue(navRow.waitForExistence(timeout: 10),
                "sidebar nav row '\(identifier)' missing; app tree: \(app.debugDescription)",
                file: file, line: line)
  let deadline = Date().addingTimeInterval(15)
  repeat {
    app.activate()
    navRow.click()
    if target.waitForExistence(timeout: 2) { return }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
  } while Date() < deadline

  XCTFail("selecting sidebar section '\(identifier)' did not mount the expected detail; app tree: \(app.debugDescription)",
          file: file, line: line)
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
