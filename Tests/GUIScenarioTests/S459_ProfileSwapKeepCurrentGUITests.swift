import XCTest

/// #459 — the cross-model profile-swap popover offers THREE outcomes.
///
/// The popover fires only on `ProfileSwapCoordinator.requestSwap` Policy 3:
/// switching to a profile whose default model differs from the resident
/// model. Engine-free + deterministic, with NO runner filesystem writes (the
/// sandboxed XCUITest runner cannot write `/tmp`): the non-sandboxed app
/// auto-seeds the `chat` + `fast-think` profiles (both default to the same
/// seeded model Y), and `PIE_TEST_RESIDENT_MODEL` (DEBUG seam) pins a
/// DIFFERENT model X resident. Switching `chat → fast-think` is therefore a
/// cross-model swap (profile default Y ≠ resident X) that raises the popover
/// — no real engine, no network, no Helper.
///
/// Outcomes asserted at the GUI level (the per-outcome coordinator logic —
/// override = A, no reload, stale-token drop — is exhaustively unit-proven in
/// ProfileSwapWiringTests):
///   1. all three buttons render (Cancel / Keep Current Model / Switch);
///   2. CANCEL       → abandon: profile stays `chat`;
///   3. KEEP CURRENT → profile becomes `fast-think` but the resident model X
///                     is kept (toolbar.model still reflects X — no reload);
///   4. SWITCH       → profile becomes `fast-think`.
final class S459_ProfileSwapKeepCurrentGUITests: XCTestCase {
  /// A slug deliberately DIFFERENT from the seeded profile default so the
  /// chat→fast-think swap is cross-model and raises the popover.
  private let residentSlug = "ghost-resident.gguf"

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_all_three_buttons_present_on_cross_model_swap() throws {
    let app = launchResidentX()
    defer { app.terminate() }
    _ = openSwapPopoverSwitchingToFastThink(in: app)

    // The popover's container `.accessibilityIdentifier("profileSwap.popover")`
    // masks the inner button ids on macOS (same SwiftUI quirk S302 documents),
    // so query the popover buttons by their visible LABELS — the real
    // user-facing controls.
    XCTAssertTrue(app.buttons["Switch"].waitForExistence(timeout: 5),
                  "Switch button missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.buttons["Keep Current Model"].exists,
                  "Keep Current Model button missing on a cross-model profile swap; app tree: \(app.debugDescription)")
    XCTAssertTrue(app.buttons["Cancel"].exists, "Cancel button missing")
  }

  @MainActor
  func test_cancel_abandons_and_stays_on_the_old_profile() throws {
    let app = launchResidentX()
    defer { app.terminate() }
    let profileMenu = openSwapPopoverSwitchingToFastThink(in: app)

    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel button missing")
    cancel.click()

    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "chat", timeout: 10),
                  "Cancel must abandon the swap and stay on the old profile; title=\(profileMenu.title)")
    XCTAssertFalse(profileMenu.title.localizedCaseInsensitiveContains("fast-think"),
                   "Cancel must never switch the profile; title=\(profileMenu.title)")
  }

  @MainActor
  func test_keep_current_switches_profile_but_keeps_resident_model() throws {
    let app = launchResidentX()
    defer { app.terminate() }
    let profileMenu = openSwapPopoverSwitchingToFastThink(in: app)

    // Query by visible label — the container id masks the inner button id
    // (S302-documented SwiftUI quirk).
    let keepButton = app.buttons["Keep Current Model"]
    XCTAssertTrue(keepButton.waitForExistence(timeout: 5),
                  "Keep Current Model button missing; app tree: \(app.debugDescription)")
    keepButton.click()

    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10),
                  "Keep Current must still commit the profile switch to fast-think; title=\(profileMenu.title)")
    // The resident model X is kept as the per-chat override — toolbar.model
    // must still reflect X, never the fast-think profile's default.
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(waitForElementValueContaining(modelMenu, "ghost-resident", timeout: 10),
                  "Keep Current must keep the resident model X via the per-chat override; toolbar.model value=\(String(describing: modelMenu.value))")
  }

  @MainActor
  func test_switch_commits_the_profile_switch() throws {
    let app = launchResidentX()
    defer { app.terminate() }
    let profileMenu = openSwapPopoverSwitchingToFastThink(in: app)

    // Query by visible label — the container id masks the inner button id
    // (S302-documented SwiftUI quirk).
    let switchButton = app.buttons["Switch"]
    XCTAssertTrue(switchButton.waitForExistence(timeout: 5), "Switch button missing")
    switchButton.click()

    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10),
                  "Switch must commit the profile switch to fast-think; title=\(profileMenu.title)")
  }

  // MARK: - setup

  /// Launch engine-free with a /tmp PIE_HOME the NON-sandboxed app seeds
  /// itself (the runner writes nothing), and pin model X resident via the
  /// DEBUG `PIE_TEST_RESIDENT_MODEL` seam. The seeded `chat`/`fast-think`
  /// profiles both default to model Y ≠ X, so swapping is cross-model.
  @MainActor
  private func launchResidentX() -> XCUIApplication {
    let pieHome = "/tmp/pie-s459swap-" + UUID().uuidString
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // DEBUG seam: pin model X resident with NO engine so swapping to a
    // profile whose default is Y is cross-model and raises the popover.
    app.launchEnvironment["PIE_TEST_RESIDENT_MODEL"] = residentSlug
    // Engine-free: a stray developer Helper must not let reconcile discover a
    // different resident and skew the swap.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    openFreshChat(in: app)
    return app
  }

  /// Open the profile switcher, pick `fast-think`, and return the
  /// toolbar.profile menu button. Asserts the popover presents.
  @MainActor
  private func openSwapPopoverSwitchingToFastThink(in app: XCUIApplication) -> XCUIElement {
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenu.waitForExistence(timeout: 10),
                  "profile switcher (toolbar.profile) missing; app tree: \(app.debugDescription)")
    // Under a contended seated session the app can transiently lose key focus
    // (app tree shows 'Disabled') at any single interaction, so retry the
    // WHOLE sequence — re-activate, open the switcher, pick `fast-think`,
    // confirm the popover presented — until it lands. Re-entrant requestSwap
    // to the same profile is safe (the coordinator just re-publishes the same
    // pending). Mirrors S426's retry idiom, extended across the full open.
    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      app.activate()
      profileMenu.click()
      let item = app.menuItems["fast-think"]
      if item.waitForExistence(timeout: 3) {
        item.click()
        if popover.waitForExistence(timeout: 3) { return profileMenu }
      }
      // Focus lost / menu didn't open / popover didn't present — reset + retry.
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    XCTFail("cross-model profile swap must raise the swap popover; app tree: \(app.debugDescription)")
    return profileMenu
  }

  // MARK: - polling helpers (shared idiom with S426)

  private func waitForMenuButtonTitleContaining(_ element: XCUIElement,
                                                _ needle: String,
                                                timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.title.localizedCaseInsensitiveContains(needle) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }

  private func waitForElementValueContaining(_ element: XCUIElement,
                                             _ needle: String,
                                             timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let value = (element.value as? String) ?? ""
      if value.localizedCaseInsensitiveContains(needle)
        || element.title.localizedCaseInsensitiveContains(needle) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }
}
