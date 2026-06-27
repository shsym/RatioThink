import XCTest

/// #654 — Local API panel surfaces (API Endpoints section).
///
/// Covers the two UI-side defects of the ticket end-to-end in the running app,
/// plus the user-visible steady state of the third:
///
///  · #2 the panel lists the seeded profiles (including the plain "Chat"
///    profile) as selectable tabs — the explorer renders every valid profile,
///    not a curated subset;
///  · #3 a streaming on/off toggle drives the curl example's `stream` field —
///    `chat-apc` serves both `stream: true` (SSE) and `stream: false` (one JSON
///    body), and the panel shows how to request each;
///  · #1 selecting an example profile keeps the panel "Running" and rewrites
///    only the examples — it does not knock the engine offline or change the
///    served profile. Served-profile switching now lives in the chat toolbar.
///
/// Engine-free + deterministic: `PIE_TEST_PIN_ENGINE_RUNNING` pins a running
/// engine whose served model equals the seeded profiles' default model, so
/// example-profile changes can be asserted without a real helper. The non-sandboxed app
/// ships the chat / json-think / tree-of-thought profiles
/// into the isolated `PIE_HOME`.
final class S654_LocalAPIPanelGUITests: XCTestCase {
  private var tempHomes: [String] = []

  /// The model the seeded profiles default to AND the pinned engine serves, so
  /// switching among the seeded profiles is a same-model switch.
  private let servedModel = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  override func tearDown() {
    for home in tempHomes { try? FileManager.default.removeItem(atPath: home) }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  func test_panel_lists_seeded_profiles_and_streaming_toggle_drives_curl() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    let panel = openLocalAPIPanel(in: app)

    // #2: the seeded profiles are selectable from the curl example context,
    // without implying a separate served-engine profile status.
    let tabs = app.descendants(matching: .any).matching(identifier: "LocalAPIProfileTabs").firstMatch
    XCTAssertTrue(tabs.waitForExistence(timeout: 10),
                  "Local API profile picker missing from the curl example; app tree: \(app.debugDescription)")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "LocalAPISelectedProfile").firstMatch.exists,
                   "the Local API pane must not show a redundant profile-level Model/Running row")
    XCTAssertFalse(app.staticTexts["Example profile"].exists,
                   "the profile picker must use the bare 'Profile' label, not 'Example profile'")
    XCTAssertTrue(profileSegment("Chat", in: app).waitForExistence(timeout: 5),
                  "the plain 'Chat' profile must be selectable in the curl example; app tree: \(app.debugDescription)")
    XCTAssertTrue(profileSegment("JSON Think", in: app).exists,
                  "shipped profiles must include JSON Think for examples; app tree: \(app.debugDescription)")
    XCTAssertFalse(profileSegment("Repeat Boost", in: app).exists,
                   "retired Repeat Boost must not be listed as a shipped example profile")

    // #3: the curl example defaults to streaming, and the toggle flips it to a
    // single (non-streaming) JSON request.
    let curl = app.descendants(matching: .any).matching(identifier: "LocalAPICurl").firstMatch
    XCTAssertTrue(curl.waitForExistence(timeout: 10),
                  "curl example missing while serving; app tree: \(app.debugDescription)")
    XCTAssertTrue(curlText(curl).contains("\"stream\": true"),
                  "streaming default must request stream:true; curl=\(curlText(curl).debugDescription)")

    let toggle = app.descendants(matching: .any).matching(identifier: "LocalAPIStreamingToggle").firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                  "streaming on/off toggle missing in the Local API panel; app tree: \(app.debugDescription)")
    XCTAssertEqual(toggle.label, "Streaming responses",
                   "hidden-label trailing switch must keep a VoiceOver-readable label")
    assertProfilePickerIsInsideCurlSection(in: app, tabs: tabs, streamingToggle: toggle)
    toggle.click()

    let nonStreaming = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                   "\"stream\": false", "\"stream\": false")
    expectation(for: nonStreaming, evaluatedWith: curl)
    waitForExpectations(timeout: 5) { error in
      XCTAssertNil(error, "flipping the streaming toggle off must rewrite the curl to stream:false; curl=\(self.curlText(curl).debugDescription)")
    }
    XCTAssertFalse(curlText(curl).contains("\"stream\": true"),
                   "non-streaming curl must not still show stream:true")

    _ = panel
  }

  @MainActor
  func test_example_profile_switch_keeps_the_engine_running() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    // Switch the example profile. The panel must stay "Running" — no served
    // engine profile change, teardown, or "Starting…"/"Off".
    let jsonThink = profileSegment("JSON Think", in: app)
    XCTAssertTrue(jsonThink.waitForExistence(timeout: 10),
                  "JSON Think tab missing; app tree: \(app.debugDescription)")
    jsonThink.click()

    let runningLabel = app.staticTexts["Running"].firstMatch
    XCTAssertTrue(runningLabel.waitForExistence(timeout: 5),
                  "an example profile switch must keep the engine Running; app tree: \(app.debugDescription)")
    XCTAssertFalse(app.staticTexts["Starting…"].exists,
                   "an example profile switch must not relaunch the engine (no 'Starting…')")
    XCTAssertFalse(app.staticTexts["Off"].exists,
                   "an example profile switch must not stop the engine (no 'Off')")
  }

  @MainActor
  func test_example_profile_switch_shapes_curl_without_profile_status_row() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    XCTAssertFalse(app.staticTexts["Example profile"].exists,
                   "profile selection should use the bare 'Profile' label in the curl example")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "LocalAPISelectedProfile").firstMatch.exists,
                   "demoted profile selection must not render a profile-level Model/Running status row")
    let tabs = app.descendants(matching: .any).matching(identifier: "LocalAPIProfileTabs").firstMatch
    XCTAssertTrue(tabs.waitForExistence(timeout: 10),
                  "profile picker missing from the curl example; app tree: \(app.debugDescription)")
    let toggle = app.descendants(matching: .any).matching(identifier: "LocalAPIStreamingToggle").firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                  "streaming toggle missing from the curl example; app tree: \(app.debugDescription)")
    assertProfilePickerIsInsideCurlSection(in: app, tabs: tabs, streamingToggle: toggle)

    let curl = app.descendants(matching: .any).matching(identifier: "LocalAPICurl").firstMatch
    XCTAssertTrue(curl.waitForExistence(timeout: 10),
                  "curl example missing while serving; app tree: \(app.debugDescription)")

    let jsonThink = profileSegment("JSON Think", in: app)
    XCTAssertTrue(jsonThink.waitForExistence(timeout: 10),
                  "JSON Think example profile tab missing; app tree: \(app.debugDescription)")
    jsonThink.click()

    let jsonThinkResponseFormat = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                             "\"response_format\"",
                                             "\"response_format\"")
    expectation(for: jsonThinkResponseFormat, evaluatedWith: curl)
    waitForExpectations(timeout: 5) { error in
      XCTAssertNil(error, "switching example profile must rewrite the curl body for JSON mode; curl=\(self.curlText(curl).debugDescription)")
    }
    XCTAssertTrue(curlText(curl).contains("\"type\": \"json_object\""),
                  "JSON Think curl should request json_object response format; curl=\(curlText(curl).debugDescription)")
  }

  @MainActor
  func test_example_profile_switch_does_not_change_served_profile_control() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    XCTAssertTrue(app.staticTexts["chat"].waitForExistence(timeout: 10),
                  "configuration Profile row should start on the active chat profile; app tree: \(app.debugDescription)")
    let jsonThink = profileSegment("JSON Think", in: app)
    XCTAssertTrue(jsonThink.waitForExistence(timeout: 10),
                  "JSON Think profile tab missing; app tree: \(app.debugDescription)")
    jsonThink.click()

    let curl = app.descendants(matching: .any).matching(identifier: "LocalAPICurl").firstMatch
    let jsonThinkResponseFormat = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                             "\"response_format\"",
                                             "\"response_format\"")
    expectation(for: jsonThinkResponseFormat, evaluatedWith: curl)
    waitForExpectations(timeout: 5) { error in
      XCTAssertNil(error, "example profile switch must still rewrite the curl body for JSON mode; curl=\(self.curlText(curl).debugDescription)")
    }
    XCTAssertTrue(curlText(curl).contains("\"type\": \"json_object\""),
                  "JSON Think curl should request json_object response format; curl=\(curlText(curl).debugDescription)")

    XCTAssertTrue(app.staticTexts["chat"].exists,
                  "example profile selection must not change the real configured/served profile row")
    XCTAssertFalse(app.staticTexts["json-think"].exists,
                   "example profile selection must not persist as the real Local API Profile setting")
    XCTAssertFalse(app.staticTexts["Starting…"].exists,
                   "example profile selection must not relaunch the engine")
    XCTAssertFalse(app.staticTexts["Off"].exists,
                   "example profile selection must not stop the engine")
  }

  @MainActor
  func test_engine_off_keeps_example_profile_endpoints_and_curl_visible() throws {
    let app = launchStopped()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 10),
                  "test fixture should open with the Local API off; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIProfileTabs").firstMatch.waitForExistence(timeout: 10),
                  "profile selector must remain visible while the engine is off; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "LocalAPIEndpoints").firstMatch.waitForExistence(timeout: 5),
                  "endpoints list must remain visible while the engine is off; app tree: \(app.debugDescription)")
    let curl = app.descendants(matching: .any).matching(identifier: "LocalAPICurl").firstMatch
    XCTAssertTrue(curl.waitForExistence(timeout: 5),
                  "curl example must remain visible while the engine is off; app tree: \(app.debugDescription)")
    XCTAssertTrue(curlText(curl).contains("http://127.0.0.1:<port>"),
                  "off-state curl must use a clear placeholder base URL; curl=\(curlText(curl).debugDescription)")
  }

  // MARK: - helpers

  @MainActor
  private func assertProfilePickerIsInsideCurlSection(
    in app: XCUIApplication,
    tabs: XCUIElement,
    streamingToggle: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let curlHeader = app.staticTexts["curl example"].firstMatch
    XCTAssertTrue(curlHeader.waitForExistence(timeout: 5),
                  "curl example header missing; app tree: \(app.debugDescription)",
                  file: file, line: line)
    XCTAssertGreaterThan(tabs.frame.minY, curlHeader.frame.minY,
                         "profile picker should sit below the curl example header",
                         file: file, line: line)
    XCTAssertLessThan(tabs.frame.minY, streamingToggle.frame.minY,
                      "profile picker should sit above the streaming toggle inside curl example",
                      file: file, line: line)
  }

  @MainActor
  private func launchPinnedRunning() -> XCUIApplication {
    let pieHome = "/tmp/pie-s654-" + UUID().uuidString
    tempHomes.append(pieHome)
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_SERVED_MODEL"] = servedModel
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    return app
  }

  @MainActor
  private func launchStopped() -> XCUIApplication {
    let pieHome = "/tmp/pie-s654-off-" + UUID().uuidString
    tempHomes.append(pieHome)
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_ENGINE_START_TO_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    return app
  }

  @MainActor
  private func openLocalAPIPanel(in app: XCUIApplication) -> XCUIElement {
    let panel = app.descendants(matching: .any).matching(identifier: "LocalAPIView").firstMatch
    selectSidebarSection("API Endpoints", until: panel, in: app)
    return panel
  }

  /// A segmented-Picker option exposes as a button/radio with the option title
  /// as its label. Match across element types to survive macOS control mapping.
  @MainActor
  private func profileSegment(_ title: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", title, title, title))
      .firstMatch
  }

  @MainActor
  private func curlText(_ element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty { return value }
    return element.label
  }
}
