import XCTest

/// S572 — the seeded "JSON Think" JSON-constrained profile works end-to-end
/// through the real GUI against a real pie engine.
///
/// Proves the user-facing path the unit/HTTP tier cannot:
///   1. The seeded `json-think` profile appears in the chat profile
///      switcher (`toolbar.profile`) and is selectable.
///   2. Selecting it and sending a prompt streams a real assistant reply
///      whose visible content is JSON (begins with a JSON value char) — i.e.
///      the selected-profile send path (which attaches `response_format`,
///      asserted at the wire level in `ChatSendControllerTests`) actually
///      engages grammar-constrained decoding against a real model.
///
/// Like S426 this needs a real engine serving the seeded GGUF, so it is
/// driven by `Scripts/run-chat-gui-e2e.sh`. Absent that config it XCSkips
/// loudly rather than passing on a stub — the engine is NEVER mocked.
///
/// JSON parse-validity + reasoning/content separation are proven
/// deterministically at the HTTP layer (`json_smoke_real.py`); here we assert
/// the observable end-to-end fact a small thinking model can reliably show:
/// the streamed visible content begins as a JSON value (not free prose), and
/// the `<think>` scratchpad never leaks into it.
final class S572_JSONThinkProfileGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_json_think_profile_selectable_and_streams_json_reply() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(
      config["PIE_TEST_ENGINE_BASE_URL"],
      "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME")
    let model = config["PIE_TEST_CHAT_MODEL"] ?? "Qwen/Qwen3-0.6B"
    // The concrete served slug the engine reconciles via /v1/models — the
    // toolbar VALUE settles to this once residency lands (mirror S260).
    let servedModelID = config["PIE_TEST_CHAT_MODEL_PIN"]
      ?? "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"

    // A prompt with NO JSON-value characters, so a static text carrying one
    // can only be the grammar-constrained assistant answer (not the echoed
    // user bubble).
    let prompt = "List the first three prime numbers as a JSON array."

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome, baseURL: baseURL, model: model)
    defer { app.terminate() }
    // Launch + win key reliably even on a later not-key launch (#545).
    app.launchActivated(landmark: { $0.buttons["chats.newButton"] })

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    // Reconciliation barrier before swapping profiles (mirror the PASSING
    // S260): the toolbar VALUE settles to the concrete served slug only after
    // /v1/models reconciles, so this proves residency landed WITHOUT opening
    // the model menu — eliminating that menu's not-key focus race entirely
    // (#545). The same-model JSON Think swap is silent because the resident
    // model is unchanged.
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "model menu missing after creating chat; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForResidentModelValue(modelMenu, servedModelID, timeout: 20),
                  "toolbar.model never reflected reconciled resident model \(servedModelID); "
                    + "title=\(modelMenu.title), value=\(String(describing: modelMenu.value)); "
                    + "app tree: \(app.debugDescription)")

    // 1) JSON Think appears in the profile switcher and is selectable.
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenu.waitForExistence(timeout: 10),
                  "profile switcher (toolbar.profile) missing; app tree: \(app.debugDescription)")
    let jsonThinkItem = app.menuItems["json-think"]
    openMenuAndWaitForItem(profileMenu, item: jsonThinkItem, in: app)
    // Action-based: wait until the item is genuinely tappable, not a one-shot
    // `.isEnabled` snapshot that races the not-key window transition (#545).
    XCTAssertTrue(jsonThinkItem.waitForHittable(timeout: 5),
                  "'json-think' profile menu item not tappable; app tree: \(app.debugDescription)")
    jsonThinkItem.click()

    guard waitForMenuButtonTitleContaining(profileMenu, "json-think", in: app, timeout: 10) else {
      XCTFail("toolbar.profile did not reflect the 'json-think' selection (title=\(profileMenu.title)); app tree: \(app.debugDescription)")
      return
    }

    // 2) Send a prompt under JSON Think and assert a JSON reply streams.
    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10),
                  "composer.text missing; app tree: \(app.debugDescription)")
    composer.click()
    composer.typeText(prompt)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "composer.send missing")
    // Action-based: wait until send is genuinely tappable, not a one-shot
    // `.isEnabled` that races the not-key window transition (#545).
    XCTAssertTrue(send.waitForHittable(timeout: 5),
                  "composer.send not tappable after typing prompt; app tree: \(app.debugDescription)")
    send.click()

    guard waitForStaticTextBeginningWithJSON(in: app, timeout: 120) else {
      XCTFail("no JSON-shaped assistant reply streamed under JSON Think; app tree: \(app.debugDescription)")
      return
    }
  }

  // MARK: - configure (mirror S426)

  private func configure(_ app: XCUIApplication, pieHome: String, baseURL: String, model: String) {
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL"] = model
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
  }

  // MARK: - assertions

  /// Resident-model reconciliation barrier (mirror S260): the toolbar VALUE
  /// equals the concrete served slug only after `/v1/models` reconciles, with
  /// no "profile default"/"(Default)" annotation. Pure value read — no menu
  /// open, so it cannot lose a not-key focus race (#545).
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

  private func waitForMenuButtonTitleContaining(_ element: XCUIElement,
                                                _ needle: String,
                                                in app: XCUIApplication,
                                                timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      // Keep the app key while polling the toolbar title: a mid-test not-key
      // transition collapses the AX tree so `.title` reads stale/empty (#545).
      app.activate()
      if element.title.localizedCaseInsensitiveContains(needle) {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }

  /// A grammar-constrained answer's visible content begins with a JSON value
  /// character (`{ [ " - digit t f n`). The prompt carries none, so a static
  /// text whose trimmed value starts with one can only be the assistant's
  /// JSON answer. MarkdownUI may split runs; any matching run proves the
  /// constrained reply streamed.
  private func waitForStaticTextBeginningWithJSON(in app: XCUIApplication,
                                                  timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    // A leading JSON value char after optional whitespace; reject `<` so a
    // leaked `<think>` delimiter can never satisfy the gate.
    let predicate = NSPredicate(format: "value MATCHES %@ OR label MATCHES %@",
                                "^\\s*[\\{\\[\"\\-0-9tfn].*", "^\\s*[\\{\\[\"\\-0-9tfn].*")
    while Date() < deadline {
      // Keep the app key during the stream wait so the AX tree stays live (#545).
      app.activate()
      if app.descendants(matching: .staticText).matching(predicate).count >= 1 {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  private static let configPath = "/tmp/pie-chat-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("JSON Think GUI E2E config missing at \(configPath); run Scripts/run-chat-gui-e2e.sh")
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
