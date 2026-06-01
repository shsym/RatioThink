import XCTest

/// sending a chat with no model resolvable (no per-chat override,
/// nothing resident, and no PIE_TEST_CHAT_MODEL) must BLOCK the send and
/// raise the no-model confirm instead of silently loading a model. This
/// is engine-free: the gate fires before any engine contact.
final class S286_NoModelSendGateGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  // Best-effort only: the XCUITest runner is app-sandboxed and cannot delete
  // the real /tmp home (removeItem is silently denied), so the authoritative
  // cleanup is the `GUI_TMP_HOMES` sweep in the GUI Make recipes, which runs
  // non-sandboxed after xcodebuild exits. This block still helps any future
  // non-sandboxed runner. Matches sibling S285.
  override func tearDown() {
    for home in tempHomes {
      try? FileManager.default.removeItem(atPath: home)
    }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  func test_send_with_no_model_resolvable_blocks_and_shows_confirm() async throws {
    // Use a real /tmp path, NOT NSTemporaryDirectory(): in the
    // sandboxed XCUITest runner the latter resolves to the runner's
    // container, which the (non-sandboxed) app cannot write to — its
    // ProfileStore would fail to seed and the profile default would not
    // resolve. Tracked in tempHomes for best-effort tearDown; the real
    // cleanup is the GUI_TMP_HOMES sweep in the Make recipe (see tearDown).
    let pieHome = "/tmp/pie-s286gate-" + UUID().uuidString
    tempHomes.append(pieHome)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // Deliberately NO PIE_TEST_CHAT_MODEL: nothing resolves the model,
    // so the send must be gated.
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

    // The send is blocked behind the no-model confirm — never a silent
    // load. The seeded chat profile's default model is offered via Load.
    // Hard invariant: the send is BLOCKED behind the no-model
    // confirm — RatioThink never loads a model the user did not choose. The
    // Load-default affordance + its resolution are unit-proven
    // (CuratedModelCatalog resolution invariant, LaunchSpecResolver
    // nested-stage, InstalledModels recurse); the GUI Load button isn't
    // asserted here (the seated-session automation wedge blocks a
    // reliable run — verify on a fresh console session).
    XCTAssertTrue(app.staticTexts["No model loaded"].waitForExistence(timeout: 5),
                  "send with nothing resolvable must raise the no-model confirm, not load silently")
  }
}
