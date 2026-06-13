import XCTest

/// S586 — left sidebar revision: the `Search` sibling section drives a
/// detail-column search panel over conversation titles + bodies.
///
/// Each test runs against an isolated `PIE_HOME` temp root so the on-disk
/// `chats.sqlite` starts empty and nothing here pollutes the developer's
/// real store or other tests.
final class S586_SidebarSearchGUITests: XCTestCase {
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
    let home = "/tmp/pie-s586-" + UUID().uuidString
    tempHomes.append(home)
    app.launchEnvironment["PIE_HOME"] = home
    return app
  }

  /// Selecting Search opens the detail-column panel with its search field,
  /// and a query that matches nothing shows the empty-results message
  /// (deterministic against the empty isolated store).
  @MainActor
  func test_search_section_shows_field_and_no_match_state() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let navRow = app.descendants(matching: .any).matching(identifier: "Search").firstMatch
    XCTAssertTrue(navRow.waitForExistence(timeout: 5), "sidebar 'Search' nav row missing")
    navRow.click()

    let field = app.textFields["search.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5),
                  "selecting Search must open the detail search field")

    field.click()
    field.typeText("zzznomatchqqq")

    let noMatch = app.staticTexts["search.noResults"]
    XCTAssertTrue(noMatch.waitForExistence(timeout: 5),
                  "a non-matching query must show the empty-results message")
  }

  /// A conversation created via the titlebar new-chat button is findable by
  /// its title, and selecting the result routes back to the chat.
  @MainActor
  func test_search_finds_a_conversation_by_title() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    // Create a chat (default title "New Chat") via the titlebar affordance.
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 5), "titlebar new-chat button missing")
    newChat.click()

    // Switch to Search and query the default title.
    let navRow = app.descendants(matching: .any).matching(identifier: "Search").firstMatch
    XCTAssertTrue(navRow.waitForExistence(timeout: 5), "sidebar 'Search' nav row missing")
    navRow.click()

    let field = app.textFields["search.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5), "search field missing")
    field.click()
    field.typeText("New Chat")

    // The matched conversation surfaces in the boxed results list. Each result
    // is a Button, so its title folds into the button's accessibility label.
    let results = app.descendants(matching: .any).matching(identifier: "search.results").firstMatch
    XCTAssertTrue(results.waitForExistence(timeout: 5),
                  "search must render the boxed results list for a matching query")
    let hit = app.buttons["New Chat"].firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: 5),
                  "search should surface the created 'New Chat' conversation")

    // Selecting a result routes back to Chats and opens that conversation.
    hit.click()
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5),
                  "selecting a search result must open that chat")
  }
}
