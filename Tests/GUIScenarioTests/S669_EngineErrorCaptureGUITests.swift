import XCTest

/// #669: capture the ENGINE-START-FAILURE state the operator reported — the
/// no-model send gate AND the loud Tier-2 engine/helper error banner up at
/// once — with the toolbar model picker opened OVER it, proving the picker
/// stays reachable in that state (the recovery invariant the merged #669
/// `.sheet`→`.overlay` fix guarantees).
///
/// Repro recipe (same seams used during #669 root-cause):
///   · `PIE_TEST_PIN_HELPER_HEALTH=unreachable` pins the helper ladder to its
///     exhausted state, so `StatusBannerReducer.make` returns Tier 2 and the
///     loud red `status.banner` ("Background helper isn't responding" / Force
///     Restart) renders immediately on launch.
///   · NO resolvable model (empty PIE_HOME, no `PIE_TEST_CHAT_MODEL`), so a
///     send raises the no-model gate (`noModel.cancel`).
/// Then open `toolbar.model` and screenshot the whole screen (the picker is its
/// own window).
///
/// IMPORTANT: this proves the gate/banner/picker STATE and picker reachability.
/// It does NOT — and cannot — reproduce the macOS-26 scroll-edge blur the
/// operator saw on 26.5.1 hardware: that effect is GPU/appearance-gated and
/// does not render in a headless capture. The shot neither shows nor disproves
/// the blur.
///
/// Engine-free, mirroring sibling S669 (the gate fires before any engine
/// contact). The screenshot is attached via XCTAttachment; the
/// run-engine-error-gui-e2e.sh wrapper exports it from the .xcresult to
/// build/gui-artifacts/engine-error.png.
final class S669_EngineErrorCaptureGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws { try guardSeatedGUI() }

  override func tearDown() {
    for home in tempHomes { try? FileManager.default.removeItem(atPath: home) }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  func test_capture_engine_error_state_with_model_picker_open() async throws {
    let pieHome = "/tmp/pie-s669err-" + UUID().uuidString
    tempHomes.append(pieHome)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // Pin the helper to its exhausted state → loud Tier-2 error banner up.
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "unreachable"
    // No PIE_TEST_CHAT_MODEL: nothing resolves a model, so the send gates.
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    // The loud engine/helper error banner is up from launch (Tier 2).
    let banner = app.descendants(matching: .any)
      .matching(identifier: "status.banner").firstMatch
    XCTAssertTrue(banner.waitForExistence(timeout: 10),
                  "Tier-2 engine/helper error banner (status.banner) missing; app tree: \(app.debugDescription)")

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer.text missing")
    composer.click()
    composer.typeText("Trigger the engine-error gate")

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.click()

    // The no-model gate is up (its Cancel affordance is present in every state).
    let cancel = app.buttons["noModel.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                  "send with nothing resolvable + unreachable helper must raise the no-model gate")

    // Open the toolbar model picker OVER the gate+banner — the #669 recovery
    // invariant: it must stay reachable so the user can switch to a working
    // model. Opening it also positions the captured frame on the exact surface
    // the operator reported as occluded.
    app.activate()
    let modelMenu = app.buttons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "toolbar.model missing; app tree: \(app.debugDescription)")
    modelMenu.click()

    let manageModels = app.buttons["toolbar.model.manageModels"]
    XCTAssertTrue(manageModels.waitForExistence(timeout: 5),
                  "model picker must open over the engine-error gate so the user can recover; app tree: \(app.debugDescription)")

    // Capture: gate + Tier-2 banner + open model picker. Whole screen, because
    // the picker popover is its own window.
    Self.settle()
    let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    att.name = "engine-error"
    att.lifetime = .keepAlways
    add(att)

    // Leave the menu closed so teardown doesn't trip over a stray popover.
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Let the open picker + banner paint before the screenshot.
  private static func settle() {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.6))
  }
}
