import XCTest

/// S260 — the chat model menu surfaces the seeded GGUF the engine serves.
///
/// The menu reflects the ids the engine ACTUALLY serves (`GET /v1/models`,
/// via `ChatScaffoldView`'s reconcile, which is gated on engine `.running`):
/// the menu item label is `ModelDisplayName.leaf(servedID)`, so a served id
/// of `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf` renders as
/// `Qwen3-0.6B-Q8_0.gguf`. This needs a real engine serving that GGUF, so —
/// like its sibling S258 — it is driven by `Scripts/run-chat-gui-e2e.sh`,
/// which boots the harness in portable mode against the staged weight and
/// writes the engine URL into the shared config file. Absent that config
/// (e.g. a plain `make test-gui`), the test XCTSkips honestly rather than
/// hard-failing.
final class S260_ChatModelMenuGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_chat_model_menu_contains_seeded_qwen3_default() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(
      config["PIE_TEST_ENGINE_BASE_URL"],
      "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME")

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    // No Helper runs on the wrapper path, so engine status would never reach
    // `.running` and the model-menu reconcile (gated on `.running`) would
    // leave the menu empty. Pin status via the DEBUG-only S302 seam so the
    // reconcile fetches `/v1/models` from the wrapper-booted engine.
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
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

    // The served id `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf` renders as its
    // leaf. Status is pinned `.running`, so allow time for the reconcile to
    // fetch `/v1/models` (the menu only resolves to the served id once
    // `engineModels` is `.known([...])`).
    let seededModel = app.menuItems["Qwen3-0.6B-Q8_0.gguf"]
    XCTAssertTrue(seededModel.waitForExistence(timeout: 10),
                  "seeded Qwen3 GGUF missing from chat model menu; app tree: \(app.debugDescription)")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// `xcodebuild test` does not reliably pass ad-hoc shell env vars through to
  /// the UI-test runner, so `Scripts/run-chat-gui-e2e.sh` writes this fixed
  /// config file after its engine harness has a live loopback URL. Shared with
  /// S258 (same wrapper).
  private static let configPath = "/tmp/pie-chat-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("chat GUI E2E config missing at \(configPath); run Scripts/run-chat-gui-e2e.sh")
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text
      .split(separator: "\n")
      .reduce(into: [:]) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let key = String(parts[0])
        let value = String(parts[1])
        if !key.isEmpty { result[key] = value }
      }
  }
}
