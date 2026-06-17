import XCTest

/// #527 extension: an explicit per-chat pin must not send into a running
/// engine that is already known to serve a different resident model. The guard
/// fires before the user message is persisted and asks the user how to resolve
/// the model identity mismatch.
final class S527_PinnedResidentMismatchGUITests: XCTestCase {
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

  @MainActor
  func test_send_with_pinned_model_mismatch_shows_confirm_and_can_repin_to_resident() throws {
    let pinnedModel = "test/Pinned-A.gguf"
    let residentModel = "test/Resident-B.gguf"
    let pieHome = "/tmp/pie-s527mismatch-" + UUID().uuidString
    tempHomes.append(pieHome)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = pinnedModel
    app.launchEnvironment["PIE_TEST_ENGINE_SERVED_MODEL"] = residentModel
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)
    XCTAssertTrue(waitForToolbarModelValue(pinnedModel, in: app, timeout: 5),
                  "fresh chat should start pinned to \(pinnedModel); app tree: \(app.debugDescription)")

    typeComposerText("This should not be sent into model_not_found.", in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing prompt")
    send.click()

    let prompt = app.descendants(matching: .any)
      .matching(identifier: "pinnedModelMismatch.prompt")
      .firstMatch
    XCTAssertTrue(prompt.waitForExistence(timeout: 5),
                  "pinned/resident mismatch must raise a confirmation popup instead of sending; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.staticTexts[pinnedModel].exists,
                  "popup must name pinned model \(pinnedModel); app tree: \(app.debugDescription)")
    XCTAssertTrue(app.staticTexts[residentModel].exists,
                  "popup must name resident model \(residentModel); app tree: \(app.debugDescription)")
    XCTAssertTrue(app.buttons["Relaunch engine with Pinned-A.gguf"].exists,
                  "popup must offer explicit relaunch with the pinned model")

    let useResident = app.buttons["Use Resident-B.gguf for this chat"]
    XCTAssertTrue(useResident.exists, "popup must offer re-pinning this chat to the resident model")
    useResident.click()

    XCTAssertTrue(waitForToolbarModelValue(residentModel, in: app, timeout: 5),
                  "Use resident must re-pin Chat.modelID to \(residentModel); app tree: \(app.debugDescription)")
  }

  private func waitForToolbarModelValue(_ expected: String,
                                        in app: XCUIApplication,
                                        timeout: TimeInterval) -> Bool {
    // The redesigned `toolbar.model` is a Button (custom popover), not a native
    // Menu; read it as a button and check label as well as value/title.
    let modelMenu = app.buttons["toolbar.model"]
    let deadline = Date().addingTimeInterval(timeout)
    let leaf = expected.split(separator: "/").last.map(String.init) ?? expected
    while Date() < deadline {
      let value = (modelMenu.value as? String) ?? ""
      if value.contains(expected) || modelMenu.title.contains(leaf)
        || modelMenu.label.contains(leaf) || modelMenu.label.contains(expected) {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return false
  }
}
