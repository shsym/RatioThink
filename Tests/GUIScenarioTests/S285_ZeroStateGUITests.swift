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
  }

  /// The col-3 zero-state "Start Chat" CTA must create a chat and open it,
  /// not dead-end (previously wired to an empty closure).
  @MainActor
  func test_start_chat_cta_opens_a_live_chat() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let startChat = app.buttons["Start Chat"]
    XCTAssertTrue(startChat.waitForExistence(timeout: 5),
                  "col-3 zero-state Start Chat CTA missing")
    startChat.click()

    // Selecting the new chat swaps col-3 from the zero-state to the chat
    // scaffold — the composer send button only exists inside a live chat.
    XCTAssertTrue(app.buttons["composer.send"].waitForExistence(timeout: 5),
                  "Start Chat must create a chat and open the chat scaffold")
    XCTAssertTrue(startChat.waitForNonExistence(timeout: 5),
                  "zero-state CTAs must dismiss once a chat is selected")
  }

  /// #422: the old per-endpoint "Add Endpoint" CTA stays absent from the
  /// col-3 zero-state, while selecting the sidebar's "API Endpoints" section
  /// opens the single live `LocalAPIView` for Rational's engine endpoint.
  @MainActor
  func test_api_endpoints_section_opens_local_api_view_without_add_endpoint_cta() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    XCTAssertTrue(app.buttons["Start Chat"].waitForExistence(timeout: 5),
                  "shipped col-3 zero-state Start Chat CTA missing")
    XCTAssertFalse(app.buttons["Add Endpoint"].exists,
                   "zero-state must not expose the removed per-endpoint Add Endpoint CTA")

    let navRow = app.descendants(matching: .any).matching(identifier: "API Endpoints").firstMatch
    XCTAssertTrue(navRow.waitForExistence(timeout: 5),
                  "sidebar 'API Endpoints' nav row missing")
    navRow.click()

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
