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
///  · #1 selecting a SAME-MODEL profile keeps the panel "Running" and updates
///    the selection — it does not knock the engine offline. (The relaunch
///    DECISION itself is exhaustively + mutation-proven in
///    `LocalAPIStateTests` — `LocalAPIProfileSwitchGate.decide` returns
///    `.selectOnly` for a same-model switch. The sandboxed XCUITest runner
///    cannot spawn a real `pie`, so a real engine relaunch / port change is not
///    observable here; this asserts the user-visible steady state.)
///
/// Engine-free + deterministic: `PIE_TEST_PIN_ENGINE_RUNNING` pins a running
/// engine whose served model equals the seeded profiles' default model, so a
/// `chat → repeat-boost` switch is a same-model switch. The non-sandboxed app
/// auto-seeds the chat / repeat-boost / json-think / tree-of-thought profiles
/// into the isolated `PIE_HOME`.
// gui-suite: full-matrix-only: no product-area focused target; runs in the full `make test-gui` matrix.
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

    // #2: the seeded plain "Chat" profile (and the others) are selectable tabs.
    let tabs = app.descendants(matching: .any).matching(identifier: "LocalAPIProfileTabs").firstMatch
    XCTAssertTrue(tabs.waitForExistence(timeout: 10),
                  "Local API profile tabs missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(profileSegment("Chat", in: app).waitForExistence(timeout: 5),
                  "the plain 'Chat' profile must be a selectable tab in the Local API panel; app tree: \(app.debugDescription)")
    XCTAssertTrue(profileSegment("Repeat Boost", in: app).exists,
                  "seeded profiles must all be listed; 'Repeat Boost' missing; app tree: \(app.debugDescription)")

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
  func test_same_model_profile_switch_keeps_the_engine_running() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    // Switch chat → repeat-boost (both serve the pinned model): a same-model
    // switch. The panel must stay "Running" — no teardown, no "Starting…"/"Off".
    let repeatBoost = profileSegment("Repeat Boost", in: app)
    XCTAssertTrue(repeatBoost.waitForExistence(timeout: 10),
                  "Repeat Boost tab missing; app tree: \(app.debugDescription)")
    repeatBoost.click()

    let runningLabel = app.staticTexts["Running"].firstMatch
    XCTAssertTrue(runningLabel.waitForExistence(timeout: 5),
                  "a same-model profile switch must keep the engine Running; app tree: \(app.debugDescription)")
    XCTAssertFalse(app.staticTexts["Starting…"].exists,
                   "a same-model switch must not relaunch the engine (no 'Starting…')")
    XCTAssertFalse(app.staticTexts["Off"].exists,
                   "a same-model switch must not stop the engine (no 'Off')")
  }

  /// #663: the per-profile "Running" badge (next to the selected profile's
  /// model, id `LocalAPISelectedProfile`) must stay meaningful after a
  /// same-model switch. The header status label is a sibling that also reads
  /// "Running", so this scopes the assertion to the selected-profile row —
  /// before #663 the badge was gated on the boot profile id and vanished when
  /// the user switched to a same-model sibling.
  @MainActor
  func test_same_model_switch_keeps_per_profile_running_badge() throws {
    let app = launchPinnedRunning()
    defer { app.terminate() }
    _ = openLocalAPIPanel(in: app)

    // Boot profile shows the badge to begin with.
    XCTAssertTrue(selectedProfileRowShowsRunning(in: app, timeout: 10),
                  "the booted profile must show its 'Running' badge; app tree: \(app.debugDescription)")

    // Switch to a same-model sibling (chat → repeat-boost). The badge must
    // follow the served model, not the boot profile id.
    let repeatBoost = profileSegment("Repeat Boost", in: app)
    XCTAssertTrue(repeatBoost.waitForExistence(timeout: 10),
                  "Repeat Boost tab missing; app tree: \(app.debugDescription)")
    repeatBoost.click()

    XCTAssertTrue(selectedProfileRowShowsRunning(in: app, timeout: 5),
                  "after a same-model switch the selected profile must still show 'Running'; app tree: \(app.debugDescription)")
  }

  // MARK: - helpers

  /// Whether the selected-profile row's green "Running" badge is present.
  ///
  /// SwiftUI exposes the row (id `LocalAPISelectedProfile`) as a single
  /// StaticText whose accessibility VALUE becomes "Running" when the badge
  /// renders, so this matches on `identifier == LocalAPISelectedProfile AND
  /// value CONTAINS "Running"` — scoping by identifier excludes the sibling
  /// header status label (`LocalAPIStatus`, which also reads "Running"), and
  /// waiting on the value handles the async snapshot/selection update.
  @MainActor
  private func selectedProfileRowShowsRunning(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let badge = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@ AND value CONTAINS %@",
                  "LocalAPISelectedProfile", "Running")).firstMatch
    return badge.waitForExistence(timeout: timeout)
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
