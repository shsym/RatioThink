import XCTest

/// S577 — left-panel UX: the chat list is a persistent bottom region of the
/// sidebar (visible across view selections), and a chat row chosen from ANY
/// view switches the right-hand main view back to that chat.
///
/// Each test runs against an isolated `PIE_HOME` temp root so the on-disk
/// `chats.sqlite` starts empty and never pollutes the developer machine's
/// real store or other tests (same pattern as S285).
final class S577_LeftPanelGUITests: XCTestCase {
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

  private func makeApp() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    configureCompletedFirstLaunch(app)
    let home = "/tmp/pie-s577-" + UUID().uuidString
    tempHomes.append(home)
    app.launchEnvironment["PIE_HOME"] = home
    return app
  }

  /// The chat list stays mounted when the API Endpoints view is selected, and
  /// clicking a chat row while that view is up switches the detail surface
  /// back to the chat (its composer reappears, the API view goes away).
  @MainActor
  func test_chat_row_from_api_view_switches_back_to_chat() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    // Create a persisted chat row from the always-visible chat-list header
    // button (this path persists immediately — no send needed).
    let newButton = app.buttons["chats.newButton"]
    XCTAssertTrue(newButton.waitForExistence(timeout: 5), "chat-list New Chat header button missing")
    newButton.click()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "New Chat must open the chat scaffold composer")

    // Switch to the API Endpoints view.
    let navRow = app.descendants(matching: .any).matching(identifier: "API Endpoints").firstMatch
    XCTAssertTrue(navRow.waitForExistence(timeout: 5), "API Endpoints nav row missing")
    navRow.click()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIView")
                    .firstMatch.waitForExistence(timeout: 5),
                  "API Endpoints must open the LocalAPIView")

    // #577 item 1: the chat list is still mounted in the left panel even
    // though the detail shows the API view.
    let chatList = app.descendants(matching: .any).matching(identifier: "chats.list").firstMatch
    XCTAssertTrue(chatList.waitForExistence(timeout: 5),
                  "chat list must stay visible in the API Endpoints view")

    // Clicking the chat row (already the selected id, but the list shows no
    // selection while the API view is up) switches the main view back to the
    // chat — the composer returns and the API view goes away.
    let row = chatList.staticTexts["New Chat"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "persisted chat row missing in the list")
    row.click()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "clicking a chat row from the API view must switch the main view back to the chat")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIView")
                    .firstMatch.waitForNonExistence(timeout: 5),
                  "the API view must be replaced by the chat detail after selecting a chat row")
  }
}
