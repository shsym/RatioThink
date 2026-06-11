import XCTest

/// Feature B lifecycle recovery, GUI-facing scenario.
///
/// The existing GUI scenario runner has a stable stale-engine seam:
/// `PIE_TEST_ENGINE_BASE_URL` lets XCUITest launch Rational.app with the
/// chat HTTP client pointed at an explicit loopback URL. Full real-stack
/// helper/RatioThink crash injection is not available in the current GUI
/// framework without broad runner refactors, so this scenario covers the
/// stale engine-config path through the real app UI: a send against an
/// unreachable engine must produce a visible recoverable error and return
/// control to the composer instead of spinning forever.
final class S279_LifecycleRecoveryGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_stale_engine_baseURL_shows_recoverable_chat_error_and_allows_retry() async throws {
    let pieHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s279-stale-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: pieHome, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: pieHome) }

    // XCUITest runners in this repo are not entitled to bind a local
    // socket, so use the well-known discard port instead of reserving
    // an ephemeral port. macOS does not serve Pie's engine on this
    // privileged loopback port, which gives the app a fast
    // connection-refused stale-engine path without starting a server.
    let staleBaseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    configure(app, pieHome: pieHome.path, staleBaseURL: staleBaseURL.absoluteString)
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    try createChatAndSend("Trigger stale engine recovery", in: app)

    guard waitForAnyStaticTextContaining(
      ["⚠️", "Could not connect", "could not connect", "NSURLErrorDomain"],
      in: app,
      timeout: 20
    ) else {
      XCTFail("stale engine send did not surface a visible recoverable error; app tree: \(app.debugDescription)")
      return
    }

    typeComposerText("Retry after lifecycle recovery", in: app)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5),
                  "composer.send missing after stale engine error; app tree: \(app.debugDescription)")
    XCTAssertTrue(
      send.isEnabled,
      "composer stayed in a sending/loading state after stale engine failure; app tree: \(app.debugDescription)"
    )
  }

  private func configure(_ app: XCUIApplication, pieHome: String, staleBaseURL: String) {
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = staleBaseURL
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "stale-engine-scenario"
    // #504: the send-gate bypass override is gone, so pin the engine `.running`
    // to PASS the gate for real — but the base URL points at a DEAD port
    // (127.0.0.1:9), so the send still fails at the socket. The asserted
    // user-visible outcome (a recoverable connection error + the composer
    // re-enables) is unchanged; only the injected fault shifts from "engine
    // never came up" to "engine reports running but is unreachable" — a faithful
    // stale-engine-config fault.
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
  }

  @MainActor
  private func createChatAndSend(_ prompt: String, in app: XCUIApplication) throws {
    openFreshChat(in: app)

    typeComposerText(prompt, in: app)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5),
                  "composer.send missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(send.isEnabled, "composer.send was disabled after typing prompt")
    send.click()
  }

  private func waitForAnyStaticTextContaining(
    _ needles: [String],
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let predicates = needles.map {
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", $0, $0)
    }
    while Date() < deadline {
      if predicates.contains(where: { predicate in
        app.descendants(matching: .staticText).matching(predicate).count > 0
      }) {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }
}
