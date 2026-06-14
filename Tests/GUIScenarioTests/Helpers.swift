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

// MARK: - multi-launch activation race (shared launch mechanism, #545/#559)
//
// `openFreshChat` / `selectPersistedChat` / `selectSidebarSection` above already
// re-activate-and-retry to survive a not-key launch. The remaining brittle
// spots are the LAUNCH itself and snapshot `.isEnabled` preconditions: under a
// single `xcodebuild test` that launches Rational.app across several scenarios,
// a LATER launch frequently comes up NOT-KEY — the app reaches
// `.runningForeground` but another process still owns key focus, so the whole
// AX tree reads `Disabled` and every `.isEnabled` / `.isHittable` snapshot is
// false. A one-shot `app.activate()` races that key transition, so a following
// `XCTAssertTrue(send.isEnabled, …)` fails on a perfectly healthy app — a
// harness focus flake, not a product fault.
//
// These helpers fix the mechanism so any multi-launch scenario can adopt it:
// poll the LIVE AX tree for genuine hittability and RE-activate until a landmark
// is actually interactable, instead of trusting a stale snapshot. Nothing is
// weakened — a genuinely disabled control never becomes hittable and still fails
// honestly.

extension XCUIElement {
  /// Wait until the element is genuinely hittable (app key + on-screen +
  /// enabled) — exactly the precondition XCUITest needs to synthesize a
  /// click/type. Fast-path returns immediately if already hittable; otherwise
  /// uses `XCTNSPredicateExpectation` to re-evaluate the LIVE AX tree rather
  /// than trusting a one-shot `.isHittable` / `.isEnabled` read. Returns false
  /// on timeout — callers assert on the result, so the proof is action-based
  /// (the control can actually be tapped), not a stale snapshot.
  @discardableResult
  func waitForHittable(timeout: TimeInterval = 10) -> Bool {
    if isHittable { return true }
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: self)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }
}

/// Open a toolbar menu button and wait until `item` appears, surviving a
/// mid-test not-key transition (#545). A menu cannot be re-activated while open
/// (activation dismisses it), so re-activate the app and RE-OPEN the menu until
/// the item shows. On success the menu is left OPEN with `item` present — the
/// caller clicks it or sends Escape. Fails loudly after `attempts` rounds.
@MainActor
func openMenuAndWaitForItem(
  _ menuButton: XCUIElement,
  item: XCUIElement,
  in app: XCUIApplication,
  attempts: Int = 4,
  itemTimeout: TimeInterval = 10,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  for _ in 0..<attempts {
    // Win key BEFORE clicking, the same launchActivated treatment the launch
    // path uses: re-activate in a loop until the menu button is genuinely
    // hittable, so the click OPENS the menu instead of being consumed by the
    // not-key → key window transition (#545).
    let keyDeadline = Date().addingTimeInterval(8)
    var ready = false
    repeat {
      app.activate()
      if menuButton.waitForHittable(timeout: 2) { ready = true; break }
    } while Date() < keyDeadline
    guard ready else { continue }

    menuButton.click()
    // Wait the FULL item window before retrying. A toolbar model/profile menu
    // renders its rows only after async reconciliation (/v1/models), so a short
    // miss means "not reconciled yet", NOT "menu failed to open" — escaping and
    // reopening on a 4s miss threw the pending reconcile away. Only retry if the
    // item never appears within the window (the genuine not-key/closed case).
    if item.waitForExistence(timeout: itemTimeout) { return }
    app.typeKey(.escape, modifierFlags: [])
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
  }
  XCTFail("menu item did not appear after \(attempts) open attempts "
            + "(not-key focus race or unreconciled menu?); app tree: \(app.debugDescription)",
          file: file, line: line)
}

extension XCUIApplication {
  /// Launch, reach `.runningForeground`, then RE-activate until `landmark` is
  /// actually hittable — defeating the not-key multi-launch focus race (#545).
  /// Replaces the brittle `launch(); wait(for: .runningForeground); activate()`
  /// trio every scenario open-coded: a single `activate()` does not reliably
  /// win key on a later launch, so subsequent `.isEnabled` reads race it.
  ///
  /// `landmark` should be the first element the scenario interacts with (e.g.
  /// the New Chat button) so success proves that element is tappable, not just
  /// that a window exists.
  func launchActivated(
    landmark: (XCUIApplication) -> XCUIElement = { $0.windows.firstMatch },
    foregroundTimeout: TimeInterval = 10,
    activationTimeout: TimeInterval = 20,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    launch()
    XCTAssertTrue(
      wait(for: .runningForeground, timeout: foregroundTimeout),
      "Rational.app did not reach runningForeground",
      file: file, line: line
    )
    let sentinel = landmark(self)
    let deadline = Date().addingTimeInterval(activationTimeout)
    repeat {
      activate()
      if sentinel.waitForHittable(timeout: 2) { return }
    } while Date() < deadline
    XCTFail(
      "Rational.app never became key/interactable within \(activationTimeout)s "
        + "(not-key multi-launch focus race); app tree: \(debugDescription)",
      file: file, line: line
    )
  }

  /// Return `element` only once it is actually interactable, re-activating
  /// this app until it is. In the full GUI matrix a launch can come up
  /// not-key — a sibling suite's window keeps keyboard focus, so the whole
  /// app tree reports `Disabled`. A bare `waitForExistence` still passes,
  /// but the subsequent synthesized click/type then times out ("Failed to
  /// synthesize event"), which cascades into spurious "control absent"
  /// failures downstream (#559). Activating and gating on `isHittable`
  /// waits the focus settle out before the event is sent.
  ///
  /// THROWS on exhaustion rather than returning a dead element: a caller
  /// like `try app.readyForInput(send).click()` then aborts on the `try`
  /// before the `.click()` runs, so the clean "stuck not-key" diagnostic
  /// is preserved instead of being buried by a re-triggered synthesize
  /// -event failure on the bogus click.
  @discardableResult
  func readyForInput(_ element: XCUIElement, timeout: TimeInterval = 15,
                     file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
    XCTAssertTrue(element.waitForExistence(timeout: timeout),
                  "element never appeared", file: file, line: line)
    for _ in 0..<3 {
      if element.isHittable { return element }
      activate()
      if element.waitForHittable(timeout: timeout) { return element }
    }
    throw NotKeyError.notHittable
  }
}

/// Thrown by `XCUIApplication.readyForInput` when the element never becomes
/// hittable — the app appears stuck not-key. Carries a readable message so
/// the test failure names the real cause, not a synthesize-event timeout.
enum NotKeyError: Error, CustomStringConvertible {
  case notHittable
  var description: String { "element never became hittable — app appears stuck not-key" }
}
