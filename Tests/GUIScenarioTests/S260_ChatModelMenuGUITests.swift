import XCTest

/// S260 — the chat model menu surfaces the seeded default profile model.
///
/// The menu reflects the ids the engine ACTUALLY serves (`GET /v1/models`,
/// via `ChatScaffoldView`'s reconcile): once a reconcile lands against a
/// non-running engine the list resolves to empty, so the seeded item only
/// renders when a real engine is serving `Qwen/Qwen3-0.6B-GGUF`. Engine-
/// gated exactly like its siblings (S204_ChatSend / S258 / S302): the App
/// is pointed at a serving engine via `PIE_TEST_ENGINE_BASE_URL`; absent
/// that, the test XCTSkips honestly rather than hard-failing (an empty menu
/// with no engine is correct behavior, not a regression).
final class S260_ChatModelMenuGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_chat_model_menu_contains_seeded_qwen3_default() async throws {
    // Engine-gated: the chat model menu is populated from the engine's
    // /v1/models. With no running engine the reconcile resolves the list to
    // empty and the seeded item never renders — correct behavior, not a bug —
    // so skip honestly when no serving engine is wired in.
    let baseURL = ProcessInfo.processInfo.environment["PIE_TEST_ENGINE_BASE_URL"] ?? ""
    try XCTSkipUnless(
      !baseURL.isEmpty,
      "chat model menu needs a running engine serving Qwen/Qwen3-0.6B-GGUF — set "
        + "PIE_TEST_ENGINE_BASE_URL to a pie base URL (boot one with the staged model, "
        + "e.g. Scripts/stage-test-model.sh + Scripts/run-chat-gui-e2e.sh, and export its "
        + "URL). The App reads /v1/models for this menu; with no served model it is empty.")

    let pieHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s260-model-menu-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: pieHome, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: pieHome) }

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome.path
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome.path))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "model menu missing after creating chat; app tree: \(app.debugDescription)")
    modelMenu.click()

    //  F1: seeded default aligned to the recommended curated
    // starter's file (Qwen3-0.6B-Q8_0.gguf).
    let seededModel = app.menuItems["Qwen3-0.6B-Q8_0.gguf"]
    XCTAssertTrue(seededModel.waitForExistence(timeout: 3),
                  "seeded Qwen3 default model missing from chat model menu; app tree: \(app.debugDescription)")
    app.typeKey(.escape, modifierFlags: [])
  }
}
