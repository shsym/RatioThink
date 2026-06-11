import XCTest

/// S426 — the seeded "Fast Think" speculative-decoding profile works
/// end-to-end through the real GUI against a real pie engine.
///
/// Proves the user-facing path that the unit/integration tier cannot:
///   1. The seeded `fast-think` profile appears in the chat profile
///      switcher (`toolbar.profile`) and is selectable.
///   2. Selecting it and sending a prompt streams a real assistant reply
///      from the live engine — i.e. the selected-profile send path
///      (which injects `speculation` + forces greedy temperature, already
///      asserted at the wire level in `ChatSendControllerTests`) actually
///      produces a generation against a real model.
///
/// Like its siblings S258/S260 this needs a real engine serving the
/// seeded GGUF, so it is driven by `Scripts/run-chat-gui-e2e.sh`, which
/// boots `chat-engine-harness` in portable mode against the app-staged
/// weight and writes the engine URL into the shared config file. Absent
/// that config (e.g. a plain `make test-gui`), it XCTSkips loudly rather
/// than passing on a stub — the engine is NEVER mocked.
///
/// The `speculation`-injected / temperature-0 wire shape is intentionally
/// NOT re-asserted here: it is unit-covered (TDD greedy-body test) and is
/// not cleanly observable through Accessibility, so per the real-engine
/// convention we assert the observable end-to-end fact (a reply streams)
/// rather than contort the GUI test to inspect the request.
final class S426_FastThinkProfileGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_fast_think_profile_selectable_and_streams_real_reply() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(
      config["PIE_TEST_ENGINE_BASE_URL"],
      "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let model = config["PIE_TEST_CHAT_MODEL_PIN"] ?? "Qwen/Qwen3-0.6B"

    // The seeded Fast Think profile uses the SAME default model as Chat, so
    // selecting it is a same-model swap. Pinning `.running` (S302 seam) lets
    // the `/v1/models` reconcile resolve `residentModelID` to the served slug,
    // making the swap silent (no confirm popover) — exactly how it behaves
    // with a live engine resident.
    let prompt = "The capital of France is"
    let visibleAssistantEcho = "The capital of Fra"

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome, baseURL: baseURL, model: model)
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    // Resolve `residentModelID` to the served slug before swapping profiles:
    // `waitForResidentModelValue` below is the reconciliation barrier because
    // it waits for the unannotated toolbar accessibility value to equal the
    // served model id. A seeded-leaf menu row can exist earlier from the
    // profile-default option, so row appearance alone is not the barrier.
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "model menu missing after creating chat; app tree: \(app.debugDescription)")

    // This is the silent same-resident swap barrier. A menu row containing the
    // Qwen leaf can be present from the profile-default option before
    // `/v1/models` reconciliation. The toolbar accessibility value only becomes
    // the unannotated concrete served slug once resident reconciliation has
    // landed, which is what makes the Fast Think profile swap silent.
    XCTAssertTrue(waitForResidentModelValue(modelMenu, model, timeout: 15),
                  "toolbar.model never reflected reconciled resident model \(model); title=\(modelMenu.title), value=\(String(describing: modelMenu.value)); app tree: \(app.debugDescription)")

    // With resident reconciliation proven, separately verify the selectable
    // model row is still present in the menu.
    XCTAssertTrue(waitForModelMenuItem(containingModelLeaf: "Qwen3-0.6B-Q8_0.gguf",
                                       in: app,
                                       openedBy: modelMenu,
                                       timeout: 15),
                  "seeded Qwen3 GGUF missing from chat model menu (reconcile did not land); app tree: \(app.debugDescription)")
    app.typeKey(.escape, modifierFlags: [])

    // 1) Fast Think appears in the profile switcher and is selectable.
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenu.waitForExistence(timeout: 10),
                  "profile switcher (toolbar.profile) missing; app tree: \(app.debugDescription)")
    profileMenu.click()
    // The switcher lists profile ids (`Button(id)`), so the seeded profile
    // renders as its id `fast-think`.
    let fastThinkItem = app.menuItems["fast-think"]
    XCTAssertTrue(fastThinkItem.waitForExistence(timeout: 10),
                  "seeded 'fast-think' profile missing from the chat profile switcher; app tree: \(app.debugDescription)")
    XCTAssertTrue(fastThinkItem.isEnabled, "'fast-think' profile menu item was not selectable")
    fastThinkItem.click()

    // Selection took effect: the switcher titles the active profile. The
    // label is the menuButton's own title (not a free-standing static text),
    // so assert on the element title.
    guard waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10) else {
      XCTFail("toolbar.profile did not reflect the 'fast-think' selection (title=\(profileMenu.title)); app tree: \(app.debugDescription)")
      return
    }

    // 2) Send a prompt under Fast Think and assert a real reply streams back.
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10),
                  "composer.text missing; app tree: \(app.debugDescription)")
    composer.click()
    composer.typeText(prompt)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    XCTAssertTrue(send.isEnabled, "composer.send was disabled after typing prompt")
    send.click()

    guard waitForAssistantEchoStaticTexts(visibleAssistantEcho, in: app, timeout: 120) else {
      XCTFail("assistant reply did not stream back under Fast Think; app tree: \(app.debugDescription)")
      return
    }
  }

  // MARK: - configure (mirror S258/S260)

  private func configure(_ app: XCUIApplication, pieHome: String, baseURL: String, model: String) {
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = model
    // Pin `.running` so the model reconcile resolves the resident model and
    // the same-model Fast Think swap is silent (S302 DEBUG seam; the GUI
    // suite runs the Debug build).
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
  }

  // MARK: - assertions (shared idiom with S258)

  /// Poll a menuButton's title for `needle`. The profile switcher renders
  /// the active profile as its own title (`Profile: <id>`), which is not a
  /// child static text — so re-query the element title until it updates.
  private func waitForMenuButtonTitleContaining(_ element: XCUIElement,
                                                _ needle: String,
                                                timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.title.localizedCaseInsensitiveContains(needle) {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }

  /// MarkdownUI exposes the assistant answer as separate/truncated static
  /// text runs, so — like S258 — the THIRD matching run proves the assistant
  /// bubble streamed in: two exist without any assistant output (the user's
  /// prompt bubble and, since #512, the sidebar row auto-titled from that
  /// same first message). The wrapper's post-run SQLite assertion covers the
  /// semantic answer.
  private func waitForAssistantEchoStaticTexts(_ needle: String,
                                               in app: XCUIApplication,
                                               timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                needle, needle)
    while Date() < deadline {
      if app.descendants(matching: .staticText).matching(predicate).count >= 3 {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  private func waitForResidentModelValue(_ element: XCUIElement,
                                         _ expectedModelID: String,
                                         timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let value = element.value as? String ?? ""
      let title = element.title
      if value == expectedModelID,
         !value.localizedCaseInsensitiveContains("profile default"),
         !title.localizedCaseInsensitiveContains("(Default)") {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }

  private func waitForModelMenuItem(containingModelLeaf leaf: String,
                                    in app: XCUIApplication,
                                    openedBy modelMenu: XCUIElement,
                                    timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      modelMenu.click()
      if menuItem(containingModelLeaf: leaf, in: app).waitForExistence(timeout: 2) {
        return true
      }
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }

  private func menuItem(containingModelLeaf leaf: String, in app: XCUIApplication) -> XCUIElement {
    let predicate = NSPredicate(format: "title CONTAINS[c] %@ OR label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                leaf, leaf, leaf)
    return app.menuItems.matching(predicate).firstMatch
  }

  /// Shared with S258/S260: `Scripts/run-chat-gui-e2e.sh` writes this fixed
  /// config after its engine harness has a live loopback URL (xcodebuild does
  /// not reliably forward ad-hoc env to the UI-test runner). Missing config →
  /// loud XCTSkip, never a silent pass.
  private static let configPath = "/tmp/pie-chat-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("Fast Think GUI E2E config missing at \(configPath); run Scripts/run-chat-gui-e2e.sh")
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
