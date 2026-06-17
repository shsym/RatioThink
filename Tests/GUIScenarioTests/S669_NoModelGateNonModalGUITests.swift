import XCTest

/// #669: the no-model gate must NOT lock the window. The earlier
/// implementation presented `NoModelLoadedPrompt` via a window-modal
/// `.sheet`, which disables every other control in the window — including
/// the toolbar model picker — so a user whose engine failed to start could
/// not switch to a working model to recover.
///
/// This pins the recovery invariant: while the gate is up, the toolbar
/// model menu (`toolbar.model`) stays interactive. Mutation-proof — it
/// fails against the modal sheet (the picker is covered/disabled) and
/// passes against the non-modal overlay. Engine-free, mirroring S286: the
/// gate fires before any engine contact, so no model fixture is needed.
final class S669_NoModelGateNonModalGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  // Best-effort only; the authoritative cleanup is the GUI_TMP_HOMES sweep
  // in the Make recipes (sandboxed runner cannot delete the real /tmp home).
  // Matches sibling S286.
  override func tearDown() {
    for home in tempHomes {
      try? FileManager.default.removeItem(atPath: home)
    }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  func test_noModel_gate_keeps_toolbar_model_picker_interactive() async throws {
    // Real /tmp path (not NSTemporaryDirectory) so the non-sandboxed app can
    // seed its ProfileStore — see S286 for the rationale.
    let pieHome = "/tmp/pie-s669gate-" + UUID().uuidString
    tempHomes.append(pieHome)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // Deliberately NO PIE_TEST_CHAT_MODEL: nothing resolves the model, so
    // the send is gated and the no-model prompt is raised — the exact
    // surface that used to lock the window.
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer.text missing")
    composer.click()
    composer.typeText("Hello with no model loaded")

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.click()

    // The gate is up (its Cancel affordance is present in every state).
    let cancel = app.buttons["noModel.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                  "send with nothing resolvable must raise the no-model gate")

    // #669 invariant: the gate is NON-modal — the toolbar model picker must
    // stay OPERABLE so the user can switch to a working model to recover.
    //
    // `isHittable` is NOT a sufficient probe: a window-modal `.sheet` does
    // not physically cover the top toolbar, so the picker still reports
    // hittable even while the modal swallows every click. The bug is in
    // event DELIVERY, not geometry. So drive the real action — click the
    // model picker and assert its dropdown actually OPENS (its always-present
    // "Manage Models…" entry, `toolbar.model.manageModels`, appears even when
    // no model is installed). Against the old modal sheet the click is
    // absorbed and the dropdown never opens; against the non-modal overlay it
    // opens normally. This is the mutation-distinguishing behavior.
    //
    // Re-activate first: after the prior suites in this run the app can come
    // up not-key, leaving a Disabled/unrealized element tree that fails a
    // bare query (the documented multilaunch focus artifact). The toolbar
    // surfaces as a plain `.button`, not a `.menuButton`.
    app.activate()
    let modelMenu = app.buttons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "toolbar.model missing; app tree: \(app.debugDescription)")
    modelMenu.click()

    let manageModels = app.buttons["toolbar.model.manageModels"]
    XCTAssertTrue(manageModels.waitForExistence(timeout: 5),
                  "no-model gate must not lock the window: clicking the toolbar " +
                  "model picker has to open its dropdown so the user can switch models to recover")

    // Leave the menu closed so teardown doesn't trip over a stray popover.
    app.typeKey(.escape, modifierFlags: [])
  }
}
