import XCTest

/// S285 — UI soundness audit: empty/zero states stay top-aligned and the
/// shipped zero-state CTA is a live affordance (not a dead button). Also covers
/// the Settings → Models empty-state top-alignment (folded in from the former
/// S360 suite — same regression class, different pane).
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

  private func makeApp(isolateHFCache: Bool = false) -> XCUIApplication {
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
    // (Swept by the GUI_TMP_HOMES `pie-s285-*` glob in the Makefile.)
    let home = "/tmp/pie-s285-" + UUID().uuidString
    tempHomes.append(home)
    app.launchEnvironment["PIE_HOME"] = home
    // The Models empty-state test needs an empty HF cache too: `CachedModelScan`
    // surfaces HF-cached models in the pane, so a populated dev cache
    // (`~/.cache/huggingface`) would hide the empty state.
    if isolateHFCache {
      app.launchEnvironment["HF_HOME"] = home + "/hf-empty"
    }
    return app
  }

  /// Empty chat DB → the sidebar shows a top-aligned "No chats yet" placeholder
  /// with an inline New Chat button, and the titlebar new-chat button is
  /// present. The placeholder must sit in the upper half, not float to center.
  @MainActor
  func test_chat_empty_state_keeps_new_chat_top_aligned() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5), "main window missing")

    // The primary new-chat affordance lives in the titlebar.
    XCTAssertTrue(app.buttons["chats.newButton"].waitForExistence(timeout: 5),
                  "titlebar New Chat affordance missing")
    // Conversation search is a sidebar destination, not an inline filter.
    XCTAssertFalse(app.textFields["chats.searchField"].exists,
                   "the chat list must not carry an inline search field")

    let emptyNew = app.buttons["chats.empty.newButton"]
    XCTAssertTrue(emptyNew.waitForExistence(timeout: 5),
                  "empty-state New Chat affordance missing (empty chat DB expected)")
    // Top-aligned: the empty-state affordance lives in the upper half of the
    // window. A vertically-centered placeholder would land near midY.
    XCTAssertLessThan(emptyNew.frame.maxY, window.frame.midY,
                      "empty-state New Chat must be top-aligned, not vertically centered")
  }

  /// The detail zero-state "Start Chat" CTA must create a chat and open it
  /// (a live composer), not dead-end.
  @MainActor
  func test_start_chat_cta_opens_a_live_chat() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let startChat = app.buttons["Start Chat"]
    XCTAssertTrue(startChat.waitForExistence(timeout: 5),
                  "detail zero-state must show the 'Start Chat' CTA")
    startChat.click()

    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer.text")
                    .firstMatch.waitForExistence(timeout: 5),
                  "'Start Chat' must open a live chat composer")
  }

  /// #422: selecting the "API Endpoints" sidebar section opens the single live
  /// `LocalAPIView`; the titlebar new-chat button stays available, and there is
  /// no inline chat search field.
  @MainActor
  func test_api_endpoints_section_opens_local_api_view() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let localAPI = app.descendants(matching: .any).matching(identifier: "LocalAPIView").firstMatch
    selectSidebarSection("API Endpoints", until: localAPI, in: app)

    XCTAssertTrue(localAPI.waitForExistence(timeout: 5),
                  "selecting API Endpoints must open the LocalAPIView")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPISecurity")
                    .firstMatch.waitForExistence(timeout: 5),
                  "LocalAPIView must always show the read-only security posture")
    XCTAssertTrue(app.buttons["chats.newButton"].exists,
                  "titlebar New Chat button must stay available in the API Endpoints view")
    XCTAssertFalse(app.textFields["chats.searchField"].exists,
                   "there must be no inline chat search field")
  }

  /// Settings → Models keeps its content top-aligned in the empty state
  /// instead of floating at the vertical center of the pane (folded in from
  /// the former S360 suite). Regression guard for the `ModelsSettingsTab`
  /// layout bug: the pane only expanded to fill the 520-tall Settings tab when
  /// it held a greedy child (the populated `Table`). The empty/loading/error
  /// states sized to their content, so `TabView` centered the whole block and
  /// the "Installed Models" header + empty-state box drifted to mid-pane. The
  /// fix pins the pane with `.frame(maxHeight: .infinity, alignment: .topLeading)`,
  /// matching the chat empty-state assertion above.
  @MainActor
  func test_models_empty_state_is_top_aligned() async throws {
    let app = makeApp(isolateHFCache: true)
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear; app: \(app.debugDescription)")

    let modelsTab = settings.toolbars.buttons["Models"]
    XCTAssertTrue(modelsTab.waitForExistence(timeout: 10),
                  "Models tab missing; window: \(settings.debugDescription)")
    modelsTab.click()

    let emptyState = settings.staticTexts["No models installed yet"]
    XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                  "Models empty state missing (empty PIE_HOME/models expected); " +
                  "window: \(settings.debugDescription)")

    let addButton = settings.buttons["AddModelButton"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 5),
                  "Add Model header button missing")

    // Top-aligned: the empty-state box lives in the upper half of the
    // Settings window. A vertically-centered pane (the bug) would push
    // the box's bottom edge past the window's midline.
    XCTAssertLessThan(emptyState.frame.maxY, settings.frame.midY,
                      "Models empty state must be top-aligned in the pane, " +
                      "not vertically centered")
    // And it stays below the "Installed Models" header, preserving the
    // top-down reading order.
    XCTAssertGreaterThan(emptyState.frame.minY, addButton.frame.minY,
                         "empty-state box must sit below the Installed Models header")
  }
}
