import XCTest

/// S285 — UI soundness audit: empty/zero states stay top-aligned and the
/// shipped col-3 zero-state CTA is a live affordance (not a dead button).
///
/// Each test runs against an isolated `PIE_HOME` temp root so the on-disk
/// `chats.sqlite` starts empty and creating a chat/endpoint here never
/// pollutes the developer machine's real store or other tests.
final class S285_ZeroStateGUITests: XCTestCase {
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
    // Use a real shared /tmp path, NOT NSTemporaryDirectory(): the
    // XCUITest runner is sandboxed, so NSTemporaryDirectory() resolves
    // to the runner's container tmp, which the non-sandboxed Rational.app
    // cannot write — its on-disk store would silently fall back to
    // in-memory and the "isolated empty store" intent would be a no-op.
    let home = "/tmp/pie-s285-" + UUID().uuidString
    tempHomes.append(home)
    app.launchEnvironment["PIE_HOME"] = home
    return app
  }

  /// Design §5: "Chats section empty → grayed placeholder row + inline New
  /// chat button". The placeholder must sit just under the list header, not
  /// float at the vertical center the way `ContentUnavailableView` did.
  @MainActor
  func test_chat_empty_state_keeps_new_chat_top_aligned() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5), "main window missing")

    let headerNew = app.buttons["chats.newButton"]
    XCTAssertTrue(headerNew.waitForExistence(timeout: 5),
                  "chat list header New Chat affordance missing")
    let searchField = app.textFields["chats.searchField"]
    XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                  "chat search field must sit above chat rows in the simplified left navigation")
    let emptyNew = app.buttons["chats.empty.newButton"]
    XCTAssertTrue(emptyNew.waitForExistence(timeout: 5),
                  "empty-state New Chat affordance missing (empty chat DB expected)")

    // Top-aligned: the empty-state affordance lives in the upper half of
    // the window. A vertically-centered placeholder would land near midY.
    XCTAssertLessThan(emptyNew.frame.maxY, window.frame.midY,
                      "empty-state New Chat must be top-aligned under the header, not vertically centered")
    // And it stays below the header, preserving top-down reading order.
    XCTAssertGreaterThan(emptyNew.frame.minY, headerNew.frame.minY,
                         "empty-state placeholder must sit below the list header")
    XCTAssertGreaterThan(emptyNew.frame.minY, searchField.frame.maxY,
                         "empty-state placeholder must sit below the search field")
  }

  /// #577: the Chats "start" landing is a ready new-chat composer — selecting
  /// it (the default at launch) opens an editable composer directly, with NO
  /// separate "Start Chat" click and NO chat row persisted until the first
  /// send. The empty chat DB must therefore still show the sidebar's empty
  /// placeholder (no draft was created just by landing on the composer).
  @MainActor
  func test_start_lands_in_new_chat_composer_without_persisting_a_draft() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    // The composer is the landing surface — present without any New Chat click.
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "Chats landing must open the editable new-chat composer directly")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "newChat.view")
                    .firstMatch.waitForExistence(timeout: 5),
                  "Chats landing must mount NewChatView")
    XCTAssertFalse(app.buttons["Start Chat"].exists,
                   "the new-chat composer replaces the old 'Start Chat' CTA")

    // No chat row was persisted just by landing on the composer: the empty DB
    // still shows the sidebar empty-state placeholder (#577 "no draft until
    // first send"; #512 prune stays the belt-and-braces net).
    XCTAssertTrue(app.buttons["chats.empty.newButton"].waitForExistence(timeout: 5),
                  "landing on the new-chat composer must not persist a draft chat")

    // Typing enables send without creating a row yet (the send is what would
    // create + route the chat).
    typeComposerText("hello", in: app)
    XCTAssertTrue(app.buttons["composer.send"].isEnabled,
                  "composer send must enable once the new-chat draft is non-empty")
    XCTAssertTrue(app.buttons["chats.empty.newButton"].exists,
                  "typing (without sending) must still not persist a draft chat")
  }

  /// #422 + #577: the old per-endpoint "Add Endpoint" CTA stays absent, the
  /// sidebar's "API Endpoints" section opens the single live `LocalAPIView`,
  /// AND the chat list stays mounted in the left panel across that selection
  /// (it is no longer hidden when a non-Chat view is shown).
  @MainActor
  func test_api_endpoints_section_opens_local_api_view_without_add_endpoint_cta() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    // Settle on the landing before interacting (the composer is the start
    // landing) so the synthesized nav-row click below lands on a key window.
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "start landing (new-chat composer) did not appear")
    XCTAssertFalse(app.buttons["Add Endpoint"].exists,
                   "landing must not expose the removed per-endpoint Add Endpoint CTA")

    // Switch to the API Endpoints view (activate-and-retry to survive a
    // not-key launch where a single click can be dropped).
    let localAPI = app.descendants(matching: .any).matching(identifier: "LocalAPIView").firstMatch
    selectSidebarSection("API Endpoints", until: localAPI, in: app)

    // #577 item 1: the chat list (its search field + New Chat header button)
    // stays visible in the left panel even though the detail shows LocalAPIView.
    XCTAssertTrue(app.textFields["chats.searchField"].waitForExistence(timeout: 5),
                  "chat search must stay visible when the API Endpoints view is selected")
    XCTAssertTrue(app.buttons["chats.newButton"].exists,
                  "chat list New Chat button must stay visible in the API Endpoints view")

    // The single live view mounts in the detail column; its security section
    // (read-only posture) is always present whether or not the engine runs.
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIView")
                    .firstMatch.waitForExistence(timeout: 5),
                  "selecting API Endpoints must open the LocalAPIView")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPISecurity")
                    .firstMatch.waitForExistence(timeout: 5),
                  "LocalAPIView must always show the read-only security posture")

  }
}
