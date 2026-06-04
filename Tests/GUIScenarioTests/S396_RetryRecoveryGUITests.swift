import XCTest

/// #396 EXECUTED failure-recovery coverage for the model-load popover.
///
/// Where S302 drives the loadviz harness through a SUCCEEDING load, this
/// suite points the same real production path
/// (model menu → confirm → ProfileSwapCoordinator → ModelLoadCenter.load
/// → HTTPEngineClient.loadModel → POST /v1/models/load) at a harness
/// started with `--fail-load-attempts 1`: the FIRST load returns HTTP
/// 500, so `ModelLoadCenter` goes `.failed` and the indicator shows the
/// red "Load failed" pip. The popover then offers a Retry recovery
/// (re-invokes the stored stream factory via `retryLast`) whose second
/// attempt succeeds, plus a Dismiss that stays the default key.
///
/// Each test runs against its OWN freshly-started harness (the runner
/// starts one per `-only-testing` invocation), so the leading-failure
/// window is deterministic per app session.
///
/// Narrow type queries only (`descendants(matching:.any)` can SIGBUS on a
/// degraded session — GUI-test convention).
final class S396_RetryRecoveryGUITests: XCTestCase {
  private static let menuModelLeaf = "Qwen3-0.6B-Q8_0.gguf"

  override func setUp() async throws { try guardSeatedGUI() }

  // MARK: - Retry recovers a failed load

  /// A failed load is not a dead end: the popover offers BOTH "Retry" and
  /// "Dismiss", and tapping Retry re-invokes the stored factory — the
  /// second attempt (the harness succeeds after its one forced failure)
  /// drives the indicator back through `.loading` to a resident model.
  @MainActor
  func test_failed_load_offers_retry_and_recovers() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated; app: \(app.debugDescription)")

    // The forced HTTP 500 drives ModelLoadCenter → .failed → the pip's
    // red "Load failed" label.
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Load failed", timeout: 20),
      "load did not surface as 'Load failed' after the harness 500; "
        + "label=\(indicator.label); app: \(app.debugDescription)")

    // The failed popover offers a recovery action AND a dismiss.
    XCTAssertTrue(openIndicatorPopover(indicator, in: app),
                  "indicator popover did not open over the failed load; app: \(app.debugDescription)")
    let retry = app.popovers.buttons.matching(NSPredicate(format: "label == %@", "Retry")).firstMatch
    XCTAssertTrue(retry.waitForExistence(timeout: 5),
                  "failed popover did not offer a Retry recovery action (#396); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")
    XCTAssertTrue(app.popovers.buttons.matching(NSPredicate(format: "label == %@", "Dismiss")).firstMatch.exists,
                  "failed popover dropped the Dismiss action; popover: \(app.popovers.firstMatch.debugDescription)")

    // Tapping Retry re-invokes the stored load factory: the indicator
    // re-enters `.loading` (proof the factory ran again), then the
    // harness's now-succeeding attempt clears the failure to a resident
    // model.
    retry.click()
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Loading model", timeout: 15),
      "Retry did not re-invoke the load (indicator never re-entered 'Loading model'); "
        + "label=\(indicator.label); app: \(app.debugDescription)")
    let hold = try Self.holdSeconds()
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Engine running, model", timeout: hold + 15),
      "Retry re-loaded but the recovery never reached a resident model; "
        + "label=\(indicator.label); app: \(app.debugDescription)")
  }

  // MARK: - Dismiss clears the failure WITHOUT reloading

  /// Dismiss is the safe, non-destructive recovery: it CLEARS the error
  /// ring without re-running the load (Retry is the explicit reload
  /// path). In the view Dismiss additionally carries
  /// `.keyboardShortcut(.defaultAction)` while Retry carries none, so the
  /// safe action is the default key — that binding is a static code
  /// property (XCUITest cannot reliably synthesise a SwiftUI popover's
  /// default-action keypress, mirroring why S302 drives Esc/Return via
  /// explicit clicks too). This test proves the behaviour that matters:
  /// Dismiss clears and does NOT reload.
  @MainActor
  func test_failed_load_dismiss_clears_without_reloading() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated; app: \(app.debugDescription)")
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Load failed", timeout: 20),
      "load did not surface as 'Load failed'; label=\(indicator.label); app: \(app.debugDescription)")

    XCTAssertTrue(openIndicatorPopover(indicator, in: app),
                  "indicator popover did not open; app: \(app.debugDescription)")
    let dismiss = app.popovers.buttons.matching(NSPredicate(format: "label == %@", "Dismiss")).firstMatch
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5),
                  "failed popover missing Dismiss; popover: \(app.popovers.firstMatch.debugDescription)")
    dismiss.click()

    XCTAssertTrue(waitForNoPopover(app, timeout: 5),
                  "Dismiss did not close the popover; app: \(app.debugDescription)")
    // Dismiss must NOT reload — if it behaved like Retry the indicator
    // would re-enter 'Loading model'.
    XCTAssertFalse(
      waitForLabel(indicator, beginsWith: "Loading model", timeout: 5),
      "Dismiss re-loaded instead of clearing — Dismiss clears, only Retry reloads (#396); "
        + "label=\(indicator.label); app: \(app.debugDescription)")
    XCTAssertFalse(indicator.label.hasPrefix("Load failed"),
                   "Dismiss did not clear the 'Load failed' state; label=\(indicator.label)")
  }

  // MARK: - steps (mirror S302; self-contained per GUI-test convention)

  @MainActor
  private func launchedApp() throws -> XCUIApplication {
    let config = try Self.loadConfig()
    let baseURL = try XCTUnwrap(config["PIE_TEST_ENGINE_BASE_URL"],
                                "\(Self.configPath) must define PIE_TEST_ENGINE_BASE_URL")
    let pieHome = try XCTUnwrap(config["PIE_TEST_GUI_HOME"],
                                "\(Self.configPath) must define PIE_TEST_GUI_HOME")

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = baseURL
    // Same pin S302 uses: the pure-HTTP harness has no Helper/XPC, so pin
    // EngineStatus.running so the toolbar /v1/models reconcile populates
    // the model menu (gated on .running).
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()
    return app
  }

  @MainActor
  private func triggerExplicitLoad(in app: XCUIApplication) throws {
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app: \(app.debugDescription)")
    newChat.click()

    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "model menu missing after creating chat; app: \(app.debugDescription)")
    modelMenu.click()

    let modelItem = app.menuItems[Self.menuModelLeaf]
    XCTAssertTrue(modelItem.waitForExistence(timeout: 5),
                  "seeded model '\(Self.menuModelLeaf)' missing from menu; app: \(app.debugDescription)")
    modelItem.click()

    let switchButton = app.buttons.matching(NSPredicate(format: "label == %@", "Switch")).firstMatch
    XCTAssertTrue(switchButton.waitForExistence(timeout: 5),
                  "profileSwap confirm popover did not present a Switch button; app: \(app.debugDescription)")
    switchButton.click()
  }

  @MainActor
  private func openIndicatorPopover(_ indicator: XCUIElement, in app: XCUIApplication) -> Bool {
    _ = waitForNoPopover(app, timeout: 5)
    var attempts = 0
    while app.popovers.count == 0 && attempts < 5 {
      attempts += 1
      indicator.click()
      let deadline = Date().addingTimeInterval(2.0)
      while Date() < deadline {
        if app.popovers.count > 0 { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
      }
    }
    return app.popovers.count > 0
  }

  private func waitForLabel(_ element: XCUIElement,
                            beginsWith prefix: String,
                            timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.exists, element.label.hasPrefix(prefix) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  private func waitForNoPopover(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if app.popovers.count == 0 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  // MARK: - config

  private static let configPath = "/tmp/pie-gui-396-retry.env"

  private static func holdSeconds() throws -> TimeInterval {
    let config = try loadConfig()
    let raw = try XCTUnwrap(config["PIE_TEST_LOAD_HOLD_SECONDS"],
                            "\(configPath) must define PIE_TEST_LOAD_HOLD_SECONDS")
    return try XCTUnwrap(TimeInterval(raw), "PIE_TEST_LOAD_HOLD_SECONDS must parse; got \(raw)")
  }

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("#396 retry GUI config missing at \(configPath); run Scripts/run-gui-396-retry-e2e.sh")
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
