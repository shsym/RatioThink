import XCTest

/// Multi-part `messages[].content` arrays against the REAL engine the GUI
/// shares (PR #115): the app itself always sends string content, so the
/// array form arrives only from external OpenAI-compatible clients hitting
/// the same loopback Local API. This scenario proves, in one seat:
///
///  1. an external client's array-form request succeeds non-stream AND
///     stream against the live chat-apc engine,
///  2. a malformed part is rejected with a 400 (never silently dropped),
///  3. the GUI chat path still streams a real assistant reply afterwards —
///     the external array-form traffic left the shared engine healthy.
final class S520_MultiPartContentGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_external_multipart_client_succeeds_and_gui_chat_still_streams() async throws {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(
      config["PIE_TEST_ENGINE_BASE_URL"],
      "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL"
    )
    let pieHome = try XCTUnwrap(
      config["PIE_TEST_GUI_HOME"],
      "\(Self.configPath) must define PIE_TEST_GUI_HOME"
    )
    // The wrapper publishes the engine's resident model under
    // PIE_TEST_CHAT_MODEL_PIN (the GGUF slug). Reading the old
    // PIE_TEST_CHAT_MODEL key fell back to "Qwen/Qwen3-0.6B", so the external
    // client requested a model the engine does not serve → 409 target_mismatch.
    // Use the published pin so the request targets the resident model (#545).
    let model = config["PIE_TEST_CHAT_MODEL_PIN"]
      ?? config["PIE_TEST_CHAT_MODEL"]
      ?? "Qwen/Qwen3-0.6B"

    // 1) External client, non-stream, multi-part array content -> 200
    //    chat.completion with non-empty assistant text.
    let multiPart: [[String: Any]] = [
      ["role": "user",
       "content": [
         ["type": "text", "text": "The capital of "],
         ["type": "text", "text": "France is"],
       ]],
    ]
    let (status, body) = try await Self.postChat(
      baseURL: baseURL, model: model, messages: multiPart, stream: false)
    XCTAssertEqual(status, 200, "non-stream multi-part request failed: \(body.prefix(300))")
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    XCTAssertEqual(obj["object"] as? String, "chat.completion")
    let choices = try XCTUnwrap(obj["choices"] as? [[String: Any]])
    let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
    // The seeded Qwen3-0.6B is a *thinking* model: within a small token
    // budget the whole answer can land in `reasoning_content` with empty
    // final `content` (same convention as the wrapper script's semantic
    // gate). Either channel being non-empty proves real generation.
    let content = (message["content"] as? String) ?? ""
    let reasoning = (message["reasoning_content"] as? String) ?? ""
    XCTAssertFalse(content.isEmpty && reasoning.isEmpty,
                   "multi-part request produced no assistant text in content or reasoning_content: \(message)")

    // 2) External client, stream, multi-part array content -> SSE with a
    //    terminal [DONE].
    let (streamStatus, streamBody) = try await Self.postChat(
      baseURL: baseURL, model: model, messages: multiPart, stream: true)
    XCTAssertEqual(streamStatus, 200, "stream multi-part request failed: \(streamBody.prefix(300))")
    XCTAssertTrue(streamBody.contains("data: [DONE]"),
                  "stream multi-part response missing terminal [DONE]: \(streamBody.suffix(300))")

    // 3) Malformed part (non-object element) -> 400 at the boundary.
    let malformed: [[String: Any]] = [
      ["role": "user", "content": ["bare string"]],
    ]
    let (badStatus, badBody) = try await Self.postChat(
      baseURL: baseURL, model: model, messages: malformed, stream: false)
    XCTAssertEqual(badStatus, 400, "malformed part must 400, got \(badStatus): \(badBody.prefix(300))")

    // 4) GUI chat still streams a real reply over the same engine.
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = model
    // #504: pin the engine `.running` so the GUI send-gate passes (mirrors
    // S258); the send still hits PIE_TEST_ENGINE_BASE_URL.
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    defer { app.terminate() }
    // Launch + win key reliably even on a later not-key launch (#545). Use the
    // default window sentinel — this scenario starts from an empty DB where
    // openFreshChat picks among New-Chat affordances, so don't presume which
    // one renders; openFreshChat re-activates further as needed.
    app.launchActivated()

    openFreshChat(in: app)
    typeComposerText("The capital of France is", in: app)
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5),
                  "composer.send missing; app tree: \(app.debugDescription)")
    // Action-based: wait until send is genuinely tappable, not a one-shot read
    // that races the not-key window transition (#545).
    XCTAssertTrue(send.waitForHittable(timeout: 5),
                  "composer.send not tappable after typing prompt; app tree: \(app.debugDescription)")
    send.click()

    let predicate = NSPredicate(
      format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
      "The capital of Fra", "The capital of Fra")
    let deadline = Date().addingTimeInterval(120)
    var visible = false
    while Date() < deadline {
      // Keep the app key during the stream wait so the AX tree stays live (#545).
      app.activate()
      if app.descendants(matching: .staticText).matching(predicate).count >= 2 {
        visible = true
        break
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    XCTAssertTrue(visible,
                  "GUI assistant reply not visible after external multi-part traffic; app tree: \(app.debugDescription)")
  }

  /// POST /v1/chat/completions from the test-runner process — the
  /// "external OpenAI-compatible client" half of the scenario.
  private static func postChat(
    baseURL: String, model: String, messages: [[String: Any]], stream: Bool
  ) async throws -> (Int, String) {
    var req = URLRequest(url: try XCTUnwrap(URL(string: "\(baseURL)/v1/chat/completions")))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "messages": messages, "stream": stream, "max_tokens": 16,
    ] as [String: Any])
    req.timeoutInterval = 120
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
    return (status, String(decoding: data, as: UTF8.self))
  }

  private static let configPath = "/tmp/pie-chat-gui-e2e.env"

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" GUI E2E config missing at \(configPath); run Scripts/run-chat-gui-e2e.sh")
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
