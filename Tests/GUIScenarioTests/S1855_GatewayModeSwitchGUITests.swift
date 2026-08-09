import XCTest

// gui-suite: full-matrix-only: opt-in live gateway scenario; skips without its config
final class S1855_GatewayModeSwitchGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
    guard FileManager.default.fileExists(atPath: "/tmp/pr333-gui.env") else {
      throw XCTSkip("requires /tmp/pr333-gui.env and a live gateway")
    }
    continueAfterFailure = false
  }

  @MainActor
  func test_chat_tot_chat_and_bestofn_commit_through_gateway() throws {
    let config = try loadConfig()
    let baseURL = try XCTUnwrap(config["BASE_URL"])
    let pieHome = try XCTUnwrap(config["PIE_HOME"])
    let model = config["MODEL"] ?? "qwen"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = model
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    defer { app.terminate() }

    app.launchActivated(landmark: { $0.buttons["chats.newButton"] })
    app.buttons["chats.newButton"].click()

    try send("Reply briefly: name a color.", expectingAssistant: 1, in: app)
    try selectProfile("tree-of-thought", title: "Tree of Thought", in: app)
    try send("Name one prime number.", expectingAssistant: 2, in: app, timeout: 240)
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Tree search'"))
        .firstMatch.waitForExistence(timeout: 10),
      "Tree of Thought completed without rendering its tree section")

    try selectProfile("chat", title: "Chat", in: app)
    try send("Reply briefly: name another color.", expectingAssistant: 3, in: app)

    try selectProfile("best-of-n", title: "Best of N", in: app)
    try send("Suggest a short weekend activity.", expectingAssistant: 4, in: app, timeout: 300)
    let firstOption = app.descendants(matching: .any)
      .matching(identifier: "bestofn.option.0").firstMatch
    XCTAssertTrue(firstOption.waitForExistence(timeout: 60),
                  "Best-of-N did not render a selectable candidate")
    firstOption.click()

    let comment = app.descendants(matching: .any)
      .matching(identifier: "bestofn.comment").firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 10),
                  "Best-of-N level one did not expose refinement")
    comment.click()
    comment.typeText("Make it practical.")
    app.buttons["bestofn.refine"].click()

    let inbound = app.descendants(matching: .any)
      .matching(identifier: "bestofn.inboundComment").firstMatch
    XCTAssertTrue(inbound.waitForExistence(timeout: 300),
                  "Best-of-N refinement did not produce a final round")
    XCTAssertTrue(firstOption.waitForExistence(timeout: 60),
                  "Best-of-N final round did not expose a candidate")
    firstOption.click()
    XCTAssertTrue(waitForAbsence(firstOption, timeout: 30),
                  "Best-of-N final pick was not committed")
  }

  @MainActor
  private func send(
    _ text: String,
    expectingAssistant count: Int,
    in app: XCUIApplication,
    timeout: TimeInterval = 180
  ) throws {
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer missing")
    composer.click()
    composer.typeText(text)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForHittable(timeout: 10), "send button not hittable")
    send.click()

    let messages = app.descendants(matching: .any)
      .matching(identifier: "message.assistant")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      app.activate()
      if messages.count >= count, send.isHittable { return }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    XCTFail("generation did not finish; expected \(count) assistant turns; app tree: \(app.debugDescription)")
  }

  @MainActor
  private func selectProfile(
    _ identifier: String,
    title: String,
    in app: XCUIApplication
  ) throws {
    let menu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10), "profile menu missing")
    let item = app.menuItems[identifier]
    openMenuAndWaitForItem(menu, item: item, in: app)
    XCTAssertTrue(item.waitForHittable(timeout: 5), "profile \(identifier) not hittable")
    item.click()
    XCTAssertTrue(waitForTitle(menu, containing: title, timeout: 15),
                  "profile did not change to \(title)")
  }

  @MainActor
  private func waitForTitle(
    _ element: XCUIElement,
    containing text: String,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.title.localizedCaseInsensitiveContains(text) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    return element.title.localizedCaseInsensitiveContains(text)
  }

  @MainActor
  private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      usleep(200_000)
    }
    return !element.exists
  }

  private func loadConfig() throws -> [String: String] {
    let text = try String(contentsOfFile: "/tmp/pr333-gui.env", encoding: .utf8)
    return text.split(separator: "\n").reduce(into: [:]) { values, line in
      let fields = line.split(separator: "=", maxSplits: 1)
      if fields.count == 2 { values[String(fields[0])] = String(fields[1]) }
    }
  }
}
