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

  /// #577 item 3 end-to-end: the start landing is a NON-persisting new-chat
  /// composer (no draft row), and the FIRST send routes the typed text through
  /// the handoff into a freshly-created, auto-titled chat — i.e. the chat is
  /// created on send, not on landing. A pinned model + pinned-running engine
  /// make the send gate pass without a real engine (the closed port only fails
  /// the stream AFTER the user turn commits), so the auto-title proves the
  /// handoff persisted the message.
  @MainActor
  func test_first_send_from_new_chat_composer_creates_and_auto_titles_chat() async throws {
    let prompt = "Summarize the KV cache design"
    let app = makeApp()
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s577-deterministic"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    // Landing is the draft composer with NO persisted chat (empty list).
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "start must land in the new-chat composer")
    XCTAssertTrue(app.buttons["chats.empty.newButton"].waitForExistence(timeout: 5),
                  "landing on the new-chat composer must not persist a draft chat")

    // First send: the draft composer hands the text to a freshly-created chat,
    // whose scaffold runs the real send → the user message persists and the
    // sidebar row auto-titles from it.
    typeComposerText(prompt, in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing in the new-chat composer; app tree: \(app.debugDescription)")
    send.click()

    let chatList = app.descendants(matching: .any).matching(identifier: "chats.list").firstMatch
    XCTAssertTrue(chatList.staticTexts[prompt].waitForExistence(timeout: 10),
                  "the first send must create + auto-title a chat from the typed text (handoff routed the message); app tree: \(app.debugDescription)")
    XCTAssertFalse(app.buttons["chats.empty.newButton"].exists,
                   "a real chat now exists, so the empty-list placeholder must be gone")
  }

  /// #577 review v2 F4: when the first send's chat creation FAILS, the new-chat
  /// composer must KEEP the typed text (not clear it) and persist no chat —
  /// the `onDraftSubmit -> false` draft-retention contract, mirroring the
  /// existing-chat failed-persist path. A DEBUG seam forces
  /// `ChatCreation.create` to return nil deterministically.
  @MainActor
  func test_first_send_keeps_draft_when_chat_creation_fails() async throws {
    let prompt = "this text must survive a failed create"
    let app = makeApp()
    app.launchEnvironment["PIE_TEST_FORCE_CHAT_CREATE_FAILURE"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "start must land in the new-chat composer")
    XCTAssertTrue(app.buttons["chats.empty.newButton"].waitForExistence(timeout: 5),
                  "no chat exists yet on the landing")

    typeComposerText(prompt, in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "send must enable once the draft is non-empty")
    send.click()

    // Create failed → no chat persisted, still on the new-chat landing, and the
    // typed text is retained (a non-empty draft keeps the send button enabled).
    XCTAssertTrue(app.buttons["chats.empty.newButton"].waitForExistence(timeout: 5),
                  "a failed create must not persist a chat; the empty-list placeholder must remain")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "newChat.view")
                    .firstMatch.exists,
                  "a failed create must keep the new-chat composer mounted (no handoff to a scaffold)")
    XCTAssertTrue(app.buttons["composer.send"].isEnabled,
                  "the typed message must be preserved after a failed create (send stays enabled); app tree: \(app.debugDescription)")
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

    // Switch to the API Endpoints view (activate-and-retry to survive a
    // not-key launch where a single click can be dropped).
    let localAPI = app.descendants(matching: .any).matching(identifier: "LocalAPIView").firstMatch
    selectSidebarSection("API Endpoints", until: localAPI, in: app)

    // #577 item 1: the chat list is still mounted in the left panel even
    // though the detail shows the API view.
    let chatList = app.descendants(matching: .any).matching(identifier: "chats.list").firstMatch
    XCTAssertTrue(chatList.waitForExistence(timeout: 5),
                  "chat list must stay visible in the API Endpoints view")

    // Clicking the chat row (already the selected id, but the list shows no
    // selection while the API view is up) switches the main view back to the
    // chat. `selectPersistedChat` activates + retries the row click and only
    // returns once the composer is back — i.e. the main view switched.
    selectPersistedChat(titled: "New Chat", in: app)
    XCTAssertTrue(localAPI.waitForNonExistence(timeout: 5),
                  "the API view must be replaced by the chat detail after selecting a chat row")
  }
}
