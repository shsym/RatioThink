import XCTest

/// #512 — chat lifecycle through the GUI: an untouched "New Chat" draft is
/// pruned when the user leaves it (and at launch reconcile), while a chat
/// with a committed user message survives — even when the send FAILS — and
/// is auto-titled from that first message in the sidebar.
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

  /// Quitting with an untouched "New Chat" draft selected leaves a shell
  /// on disk; the next launch's reconcile removes it — the relaunch lands
  /// on the empty chat-list placeholder, never a stale draft row. (The
  /// switch-away prune is covered in the failed-send test below, where a
  /// real row exists to switch to.)
  @MainActor
  func test_empty_chat_pruned_by_launch_reconcile() async throws {
    let home = freshHome("prune")
    let app = makeApp(pieHome: home)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)
    XCTAssertTrue(waitForNewChatRowCount(1, in: app),
                  "first draft chat row missing; app tree: \(app.debugDescription)")

    app.terminate()
    let relaunched = makeApp(pieHome: home)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10))
    relaunched.activate()

    XCTAssertTrue(relaunched.buttons["chats.empty.newButton"].waitForExistence(timeout: 10),
                  "launch reconcile must prune the leftover empty draft (empty chat-list placeholder expected); app tree: \(relaunched.debugDescription)")
    // Review F2: the row count is scoped to `chats.list`, which counts 0
    // over a missing element — prove the sidebar actually rendered (list
    // or its empty placeholder) before trusting count == 0.
    XCTAssertTrue(chatList(in: relaunched).exists || relaunched.buttons["chats.empty.newButton"].exists,
                  "sidebar never rendered — a scoped row count of 0 would be vacuous; app tree: \(relaunched.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: relaunched),
                  "no 'New Chat' shell may survive the launch reconcile; app tree: \(relaunched.debugDescription)")
  }

  /// Manual rename via the row context menu: the new title shows in the
  /// sidebar, and the renamed chat — though EMPTY — survives switch-away
  /// and relaunch (a user-set title is permanent intent, never pruned).
  @MainActor
  func test_context_menu_rename_persists_and_protects_empty_chat() async throws {
    let customTitle = "Research scratchpad"
    let home = freshHome("rename")
    let app = makeApp(pieHome: home)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)
    XCTAssertTrue(waitForNewChatRowCount(1, in: app),
                  "draft chat row missing; app tree: \(app.debugDescription)")

    // Open the row context menu and pick Rename. The synthesized
    // right-click can leave the menu half-presented or miss the item on a
    // busy session (the S486 hazard) — reset with Escape and retry.
    let row = sidebarRow(titled: "New Chat", in: app)
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

    // Relaunch: the renamed chat is EMPTY, but a user-set title is
    // intent — the launch reconcile must keep it.
    app.terminate()
    let relaunched = makeApp(pieHome: home)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10))
    relaunched.activate()

    XCTAssertTrue(sidebarRow(titled: customTitle, in: relaunched).waitForExistence(timeout: 10),
                  "user-titled empty chat must survive the launch reconcile; app tree: \(relaunched.debugDescription)")
  }

  /// Probe for the prune-vs-scaffold-teardown ordering from ticket #534: an
  /// empty draft can have the no-model sheet raised (blocked send, no user
  /// message persisted) when the user leaves it. The selection-change prune
  /// deletes the outgoing chat while `ChatScaffoldView` teardown/onChange
  /// closures may still be unwinding; this must not trap, and the empty draft
  /// must still be pruned. If the macOS sheet consumes the first sidebar
  /// click, dismiss it and complete the switch so the test does not confuse a
  /// modal event-routing limitation with a lifecycle crash.
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
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 5),
                  "New Chat button missing before prompt-prune probe; app tree: \(app.debugDescription)")
    newChat.click()
    XCTAssertTrue(waitForNewChatRowCount(1, in: app),
                  "empty draft row missing before blocked send; app tree: \(app.debugDescription)")

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
                  "leaving the empty prompted draft must prune it; app tree: \(app.debugDescription)")
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
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 5))
    newChat.click()
    XCTAssertTrue(sidebarRow(titled: prompt, in: app).waitForExistence(timeout: 5),
                  "a chat with a committed (failed) send must survive switch-away; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(1, in: app),
                  "the fresh draft row must appear after New Chat; app tree: \(app.debugDescription)")

    // Switching BACK to the real chat leaves the untouched draft — it must
    // be pruned the moment the user leaves it (the switch-away prune).
    sidebarRow(titled: prompt, in: app).click()
    XCTAssertTrue(waitForNewChatRowCount(0, in: app),
                  "leaving an empty draft must prune it; app tree: \(app.debugDescription)")
    XCTAssertTrue(sidebarRow(titled: prompt, in: app).exists,
                  "the real chat must survive the draft prune; app tree: \(app.debugDescription)")

    // Relaunch: the abandoned empty draft is reconciled away, the real
    // (failed-send) chat persists under its derived title.
    app.terminate()
    let relaunched = makeApp(pieHome: home)
    relaunched.launch()
    defer { relaunched.terminate() }
    XCTAssert(relaunched.wait(for: .runningForeground, timeout: 10))
    relaunched.activate()

    XCTAssertTrue(sidebarRow(titled: prompt, in: relaunched).waitForExistence(timeout: 10),
                  "titled chat missing after relaunch; app tree: \(relaunched.debugDescription)")
    XCTAssertTrue(waitForNewChatRowCount(0, in: relaunched),
                  "the empty draft left at quit must be reconciled away; app tree: \(relaunched.debugDescription)")
  }
}
