import XCTest

/// #512 — chat lifecycle through the GUI: an untouched draft never enters the
/// persisted conversation list, while a chat with a committed user message
/// survives — even when the send FAILS — and is auto-titled from that first
/// message in the sidebar.
///
/// Engine-free: pruning needs no engine at all; the failed-send case points
/// `PIE_TEST_ENGINE_BASE_URL` at a closed port so the user turn commits and
/// the stream errors deterministically. Each test runs against an isolated
/// `PIE_HOME` (real /tmp path — the sandboxed runner's NSTemporaryDirectory
/// is unwritable for the non-sandboxed app, see S285).
final class S512_ChatLifecycleGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  override func tearDown() {
    for home in tempHomes {
      try? FileManager.default.removeItem(atPath: home)
    }
    tempHomes.removeAll()
    super.tearDown()
  }

  private func makeApp(pieHome: String) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    return app
  }

  private func freshHome(_ tag: String) -> String {
    let home = "/tmp/pie-s512-\(tag)-" + UUID().uuidString
    tempHomes.append(home)
    return home
  }

  /// Sidebar chat-list scope. All row assertions stay inside it so the
  /// transcript's message bubbles and the empty-state "New Chat" button
  /// label can never satisfy (or break) a sidebar-row expectation. When
  /// the list is empty the placeholder replaces it, so a scoped count is
  /// simply 0.
  private func chatList(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "chats.list").firstMatch
  }

  private func sidebarRow(titled title: String, in app: XCUIApplication) -> XCUIElement {
    chatList(in: app).staticTexts[title].firstMatch
  }

  private func newChatRowCount(in app: XCUIApplication) -> Int {
    chatList(in: app).descendants(matching: .staticText)
      .matching(identifier: "New Chat").count
  }

  private func waitForNewChatRowCount(
    _ expected: Int, in app: XCUIApplication, timeout: TimeInterval = 5
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if newChatRowCount(in: app) == expected { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return newChatRowCount(in: app) == expected
  }

  /// The once-per-launch engine-start ask (#4) can sheet over the chat
  /// when engine status settles to stopped/failed mid-test; the modal
  /// disables every other affordance. Dismiss it so lifecycle clicks land.
  private func dismissNoModelGateIfPresent(in app: XCUIApplication) {
    let cancel = app.buttons["noModel.cancel"]
    if cancel.waitForExistence(timeout: 3), cancel.isHittable {
      cancel.click()
    }
  }

  /// Opening an untouched draft never inserts a sidebar row, and quitting
  /// cannot leave anything for launch reconciliation to clean up.
  @MainActor
  func test_untouched_draft_never_creates_sidebar_row_or_persists() async throws {
    let home = freshHome("transient")
    let app = makeApp(pieHome: home)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)
    XCTAssertTrue(app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch.exists,
                  "draft composer missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "an untouched draft must not create a sidebar row; app tree: \(app.debugDescription)")

    app.terminate()
    let relaunched = makeApp(pieHome: home)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10))
    relaunched.activate()

    XCTAssertTrue(relaunched.staticTexts["chats.empty.label"].waitForExistence(timeout: 10),
                  "an untouched transient draft must leave the store empty; app tree: \(relaunched.debugDescription)")
    XCTAssertTrue(chatList(in: relaunched).exists || relaunched.staticTexts["chats.empty.label"].exists,
                  "sidebar never rendered — a scoped row count of 0 would be vacuous; app tree: \(relaunched.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: relaunched),
                  "no draft row may appear after relaunch; app tree: \(relaunched.debugDescription)")
  }

  /// Manual rename via the row context menu remains available once the first
  /// message has made the chat persistent, and the title survives relaunch.
  @MainActor
  func test_context_menu_rename_persists_after_first_send() async throws {
    let customTitle = "Research scratchpad"
    let initialPrompt = "Notes for a research plan"
    let home = freshHome("rename")
    let app = makeApp(pieHome: home)
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s512-deterministic"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "draft must not create a row before send; app tree: \(app.debugDescription)")
    typeComposerText(initialPrompt, in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.click()
    XCTAssertTrue(sidebarRow(titled: initialPrompt, in: app).waitForExistence(timeout: 10),
                  "first send did not create the titled row; app tree: \(app.debugDescription)")

    // Open the row context menu and pick Rename. The synthesized
    // right-click can leave the menu half-presented or miss the item on a
    // busy session (the S486 hazard) — reset with Escape and retry.
    let row = sidebarRow(titled: initialPrompt, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    var openedRename = false
    for _ in 0..<3 {
      row.rightClick()
      let rename = app.menuItems["Rename"]
      if rename.waitForExistence(timeout: 3), rename.isHittable {
        rename.click()
        openedRename = true
        break
      }
      app.typeKey(.escape, modifierFlags: [])
    }
    XCTAssertTrue(openedRename,
                  "Rename missing from row context menu; app tree: \(app.debugDescription)")

    // SwiftUI's macOS `.alert` drops accessibility identifiers from its
    // accessory TextField and action buttons, so anchor on the alert's
    // single text field and the action's visible "Rename" label (the
    // context-menu item of the same name is a menuItem, not a button,
    // and is gone once the alert is up).
    let field = app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5),
                  "rename field missing; app tree: \(app.debugDescription)")
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(customTitle)
    // Confirm with Return — the alert's default action. An unscoped
    // buttons["Rename"] query matches a Touch Bar proxy element that
    // XCUITest refuses to click ("cannot be called with Touch Bar
    // elements"), so don't click the button at all.
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(sidebarRow(titled: customTitle, in: app).waitForExistence(timeout: 5),
                  "renamed title not shown in sidebar; app tree: \(app.debugDescription)")

    // Relaunch: the user-set title is durable.
    app.terminate()
    let relaunched = makeApp(pieHome: home)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10))
    relaunched.activate()

    XCTAssertTrue(sidebarRow(titled: customTitle, in: relaunched).waitForExistence(timeout: 10),
                  "user title must survive relaunch; app tree: \(relaunched.debugDescription)")
  }

  /// A send blocked by the no-model gate remains a transient draft. Switching
  /// to an existing conversation drops it without a persistence delete.
  @MainActor
  func test_switching_from_empty_chat_with_noModelPrompt_visible_does_not_crash() async throws {
    let anchorPrompt = "Anchor chat for no model prune probe"
    let blockedDraft = "Draft that should remain uncommitted"
    let home = freshHome("prompt-prune")

    let seeded = makeApp(pieHome: home)
    seeded.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s512-deterministic"
    seeded.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    seeded.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    seeded.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    seeded.launch()
    XCTAssert(seeded.wait(for: .runningForeground, timeout: 10))
    seeded.activate()

    openFreshChat(in: seeded)
    typeComposerText(anchorPrompt, in: seeded)
    let seedSend = seeded.buttons["composer.send"]
    XCTAssertTrue(seedSend.waitForExistence(timeout: 5))
    XCTAssertTrue(seedSend.isEnabled, "composer.send disabled after typing; app tree: \(seeded.debugDescription)")
    seedSend.click()
    XCTAssertTrue(sidebarRow(titled: anchorPrompt, in: seeded).waitForExistence(timeout: 10),
                  "anchor chat was not auto-titled; app tree: \(seeded.debugDescription)")
    seeded.terminate()

    let app = makeApp(pieHome: home)
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_ENGINE_START_TO_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    // A launch-start prompt may appear before selection; dismiss it so this
    // test controls exactly which empty draft owns the visible prompt.
    dismissNoModelGateIfPresent(in: app)
    selectPersistedChat(titled: anchorPrompt, in: app)
    // The launch-start prompt is evaluated on the scaffold's appear/status
    // edges; it can land just after selecting the anchor chat. Clear that
    // launch prompt too so the later visible prompt belongs to the empty
    // draft created below.
    dismissNoModelGateIfPresent(in: app)
    openFreshChat(in: app)
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "empty draft must not create a row before blocked send; app tree: \(app.debugDescription)")

    typeComposerText(blockedDraft, in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing blocked draft; app tree: \(app.debugDescription)")
    send.click()

    let gate = noModelPrompt(in: app)
    XCTAssertTrue(gate.waitForExistence(timeout: 10),
                  "no-model prompt should be visible for the empty blocked draft; app tree: \(app.debugDescription)")

    sidebarRow(titled: anchorPrompt, in: app).click()
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
    XCTAssertEqual(app.state, .runningForeground,
                   "switching away while the no-model prompt was visible should not crash; app tree: \(app.debugDescription)")

    if gate.exists {
      gate.click()
      sidebarRow(titled: anchorPrompt, in: app).click()
    }

    XCTAssertTrue(sidebarRow(titled: anchorPrompt, in: app).waitForExistence(timeout: 5),
                  "anchor chat missing after leaving empty prompted draft; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "leaving the prompted draft must not leave a row; app tree: \(app.debugDescription)")
    XCTAssertFalse(app.staticTexts[blockedDraft].exists,
                   "blocked draft text must not have been committed as a user message")
  }

  /// A chat whose send FAILED is real conversation: the user turn committed,
  /// so the chat is kept across switch-away AND relaunch — and the sidebar
  /// row carries the auto-derived title (the first user message) instead of
  /// the "New Chat" placeholder.
  @MainActor
  func test_failed_send_chat_is_kept_and_auto_titled() async throws {
    let prompt = "Plan a trip to Kyoto in autumn"
    let home = freshHome("title")
    let app = makeApp(pieHome: home)
    // #504: pin the chat's model and the engine `.running` so the real
    // send gate passes without a Helper/engine; the closed port makes the
    // stream fail AFTER the user turn commits.
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s512-deterministic"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    // Pin helper health so the #496 recovery overlay never covers the
    // composer on this helper-less launch.
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)
    typeComposerText(prompt, in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing; app tree: \(app.debugDescription)")
    send.click()

    // The auto-title lands in the same save as the user message — the
    // sidebar row renames immediately, well before the stream fails.
    XCTAssertTrue(sidebarRow(titled: prompt, in: app).waitForExistence(timeout: 10),
                  "sidebar row was not auto-titled from the first user message; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "the titled chat must replace its 'New Chat' placeholder row; app tree: \(app.debugDescription)")

    // Switching away must NOT prune it (user-authored turn + title).
    dismissNoModelGateIfPresent(in: app)
    openFreshChat(in: app)
    XCTAssertTrue(sidebarRow(titled: prompt, in: app).waitForExistence(timeout: 5),
                  "a chat with a committed (failed) send must survive switch-away; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "a fresh draft must not appear in the sidebar; app tree: \(app.debugDescription)")

    // Switching BACK to the real chat simply abandons the in-memory draft.
    sidebarRow(titled: prompt, in: app).click()
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "leaving a draft must not create or retain a row; app tree: \(app.debugDescription)")
    XCTAssertTrue(sidebarRow(titled: prompt, in: app).exists,
                  "the real chat must survive the draft prune; app tree: \(app.debugDescription)")

    // Relaunch: the real failed-send chat persists under its derived title.
    app.terminate()
    let relaunched = makeApp(pieHome: home)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10))
    relaunched.activate()

    XCTAssertTrue(sidebarRow(titled: prompt, in: relaunched).waitForExistence(timeout: 10),
                  "titled chat missing after relaunch; app tree: \(relaunched.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: relaunched),
                  "no transient draft row may appear after relaunch; app tree: \(relaunched.debugDescription)")
  }
}
