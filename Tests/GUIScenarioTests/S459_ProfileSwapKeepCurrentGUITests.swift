import XCTest

/// #459/#460/#527 — explicit model picks now stay pinned across profile
/// changes by default; the cross-model profile-swap popover remains available
/// only when the user opts into "Follow profile default model" compatibility.
///
/// The popover fires only on `ProfileSwapCoordinator.requestSwap` Policy 3:
/// switching to a profile whose default model differs from the chat's CURRENT
/// SELECTION. Under #460's single source of truth that "current model" is the
/// chat's `Chat.modelID` (the selection authority) resolved through the active
/// profile default — NOT engine residency, which is no longer a selection
/// source. So the cross-model state is established by an EXPLICIT pin, not by
/// seeding a resident model.
///
/// Engine-free + deterministic, with NO runner filesystem writes (the
/// sandboxed XCUITest runner cannot write `/tmp`): the non-sandboxed app
/// auto-seeds the `chat` + `fast-think` profiles (both default to the same
/// seeded model Y), and `PIE_TEST_CHAT_MODEL_PIN` (DEBUG seam) pins a
/// DIFFERENT model X as the fresh chat's `Chat.modelID`. Switching
/// `chat → fast-think` is therefore a cross-model swap (chat selection X ≠
/// fast-think default Y). In default mode it switches silently and keeps X; in
/// compatibility mode it raises the popover — no real engine, no network, no
/// Helper.
///
/// Outcomes asserted at the GUI level (the per-outcome coordinator logic —
/// keep-current pins X, no reload, stale-token drop — is exhaustively
/// unit-proven in ProfileSwapWiringTests / ProfileSwapCoordinatorTests):
///   1. all three buttons render (Cancel / Keep Current Model / Switch);
///   2. CANCEL       → abandon: profile stays `chat`;
///   3. KEEP CURRENT → profile becomes `fast-think` but the chat's pinned
///                     model X is kept (toolbar.model still reflects X — no
///                     reload, no adoption of fast-think's default);
///   4. SWITCH       → profile becomes `fast-think`.
final class S459_ProfileSwapKeepCurrentGUITests: XCTestCase {
  /// A slug deliberately DIFFERENT from the seeded profile default so the
  /// chat→fast-think swap is cross-model and raises the popover. Pinned as
  /// the fresh chat's `Chat.modelID` (the #460 selection authority).
  private let pinnedSlug = "ghost-pinned.gguf"

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_all_three_buttons_present_on_cross_model_swap() throws {
    let app = launchPinnedX(followProfileDefault: true)
    defer { app.terminate() }
    _ = openSwapPopoverSwitchingToFastThink(in: app, requiringButton: "Switch")

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
    let app = launchPinnedX(followProfileDefault: true)
    defer { app.terminate() }
    let profileMenu = openSwapPopoverSwitchingToFastThink(in: app, requiringButton: "Cancel")

    XCTAssertTrue(clickPopoverButton("Cancel", in: app), "Cancel button missing")

    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "chat", timeout: 10),
                  "Cancel must abandon the swap and stay on the old profile; title=\(profileMenu.title)")
    XCTAssertFalse(profileMenu.title.localizedCaseInsensitiveContains("fast-think"),
                   "Cancel must never switch the profile; title=\(profileMenu.title)")
  }

  @MainActor
  func test_keep_current_switches_profile_but_keeps_pinned_model() throws {
    let app = launchPinnedX(followProfileDefault: true)
    defer { app.terminate() }
    let profileMenu = openSwapPopoverSwitchingToFastThink(in: app, requiringButton: "Keep Current Model")

    // Query by visible label — the container id masks the inner button id
    // (S302-documented SwiftUI quirk).
    XCTAssertTrue(clickPopoverButton("Keep Current Model", in: app),
                  "Keep Current Model button missing; app tree: \(app.debugDescription)")

    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10),
                  "Keep Current must still commit the profile switch to fast-think; title=\(profileMenu.title)")
    // The chat's pinned model X is kept as `Chat.modelID` — toolbar.model must
    // still reflect X, never the fast-think profile's default.
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(waitForElementValueContaining(modelMenu, "ghost-pinned", timeout: 10),
                  "Keep Current must keep the chat's pinned model X (Chat.modelID); toolbar.model value=\(String(describing: modelMenu.value))")
  }

  @MainActor
  func test_switch_commits_the_profile_switch() throws {
    let app = launchPinnedX(followProfileDefault: true)
    defer { app.terminate() }
    let profileMenu = openSwapPopoverSwitchingToFastThink(in: app, requiringButton: "Switch")

    // Query by visible label — the container id masks the inner button id
    // (S302-documented SwiftUI quirk).
    XCTAssertTrue(clickPopoverButton("Switch", in: app), "Switch button missing")

    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10),
                  "Switch must commit the profile switch to fast-think; title=\(profileMenu.title)")
  }

  /// #582: the swap popover must survive the window resigning key. The old
  /// transient SwiftUI `.popover` was auto-closed by AppKit the instant the
  /// window lost key (Cmd-Tab, Dock click, Spotlight, a notification), silently
  /// dropping the pending swap. The production fix drives it from a
  /// coordinator-owned `.applicationDefined` NSPopover. The DEBUG auto-pick seam
  /// no longer re-raises a dismissed popover (that #579 re-raise MASKED this
  /// gap), so a popover still present after a real focus steal proves genuine
  /// resign-key survival — not a re-raise. This case FAILS if the popover dies
  /// on focus loss.
  @MainActor
  func test_popover_survives_window_resigning_key() throws {
    let app = launchPinnedX(followProfileDefault: true)
    defer { app.terminate() }
    _ = openSwapPopoverSwitchingToFastThink(in: app, requiringButton: "Switch")

    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch
    XCTAssertTrue(popover.exists,
                  "precondition: swap popover must be present before the focus steal; app tree: \(app.debugDescription)")

    // #582 review F1: the popover must present BELOW the profile menu (matching
    // the former `arrowEdge: .bottom`), so the `preferredEdge` direction can't
    // silently regress. XCUITest frames are screen coordinates (y increases
    // downward), so "below" means the popover's top edge sits at/under the
    // menu's bottom edge.
    let profileMenuForGeometry = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenuForGeometry.exists, "profile menu missing for geometry check")
    XCTAssertGreaterThanOrEqual(
      popover.frame.minY, profileMenuForGeometry.frame.maxY,
      "swap popover must present below the profile menu (#582 F1); popover=\(popover.frame) menu=\(profileMenuForGeometry.frame)")

    // Steal key focus so our window resigns key — the exact condition that
    // auto-closes a transient `.popover`. Finder is always running, so
    // activating it is the lightest deterministic resign-key trigger.
    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    finder.activate()
    XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 10),
                  "could not steal focus to Finder to force the window to resign key")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                  "Rational.app did not return to the foreground after the focus steal")

    // The pending swap must NOT have been dropped by the focus loss.
    XCTAssertTrue(popover.waitForExistence(timeout: 10),
                  "profile-swap popover died when the window resigned key (#582); app tree: \(app.debugDescription)")
    // …and its actions must still be live, not an empty shell.
    XCTAssertTrue(app.buttons["Switch"].waitForExistence(timeout: 5),
                  "popover survived but its Switch action is gone after focus loss; app tree: \(app.debugDescription)")
    // The surviving popover still commits a real switch — prove it is the same
    // live coordinator-owned swap, not a stale husk.
    XCTAssertTrue(clickPopoverButton("Switch", in: app),
                  "Switch button missing on the survived popover")
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10),
                  "the survived popover's Switch must still commit the profile switch; title=\(profileMenu.title)")
  }

  @MainActor
  func test_default_mode_switches_profile_without_prompt_and_keeps_pinned_model() throws {
    let app = launchPinnedX(followProfileDefault: false)
    defer { app.terminate() }

    let profileMenu = selectFastThink(in: app)
    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch

    XCTAssertFalse(popover.waitForExistence(timeout: 2),
                   "default explicit-model mode should not ask to swap to the destination profile default")
    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 10),
                  "default explicit-model mode still commits the profile switch; title=\(profileMenu.title)")
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(waitForElementValueContaining(modelMenu, "ghost-pinned", timeout: 10),
                  "default explicit-model mode must keep the chat's pinned model X; toolbar.model value=\(String(describing: modelMenu.value))")
  }

  // MARK: - setup

  /// Launch engine-free with a /tmp PIE_HOME the NON-sandboxed app seeds
  /// itself (the runner writes nothing), and pin model X as the fresh chat's
  /// `Chat.modelID` via the DEBUG `PIE_TEST_CHAT_MODEL_PIN` seam. The seeded
  /// `chat`/`fast-think` profiles both default to model Y ≠ X, so swapping is
  /// cross-model on the chat's SELECTION (single-source #460), not residency.
  @MainActor
  private func launchPinnedX(followProfileDefault: Bool) -> XCUIApplication {
    let pieHome = "/tmp/pie-s459swap-" + UUID().uuidString
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // DEBUG seam: pin model X as the fresh chat's selection authority
    // (`Chat.modelID`) so swapping to a profile whose default is Y is
    // cross-model under #460's single source of truth and raises the popover.
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = pinnedSlug
    // Avoid native macOS Menu automation flake while exercising the same
    // ContentToolbar.selectProfile path as the production profile menu.
    app.launchEnvironment["PIE_TEST_AUTO_PICK_PROFILE"] = "fast-think"
    // Engine-free: a stray developer Helper must not let reconcile run; the
    // swap keys on the chat's pin regardless, but keep the harness hermetic.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    if followProfileDefault {
      app.launchEnvironment["PIE_TEST_FOLLOW_PROFILE_DEFAULT_MODEL"] = "1"
    }
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    openFreshChat(in: app)
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(waitForElementValueContaining(modelMenu, "ghost-pinned", timeout: 10),
                  "fresh chat did not expose the debug-pinned model before profile swap; toolbar.model value=\(String(describing: modelMenu.value)); app tree=\(app.debugDescription)")
    return app
  }

  /// Wait for the DEBUG-only auto-pick seam to select `fast-think`, then
  /// return the toolbar.profile menu button. This intentionally avoids native
  /// macOS Menu automation; the seam calls ContentToolbar.selectProfile,
  /// which is the same product path reached by the production menu.
  @MainActor
  private func selectFastThink(in app: XCUIApplication) -> XCUIElement {
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenu.waitForExistence(timeout: 10),
                  "profile switcher (toolbar.profile) missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(waitForMenuButtonTitleContaining(profileMenu, "fast-think", timeout: 45),
                  "DEBUG auto-pick seam did not select fast-think; title=\(profileMenu.title); app tree=\(app.debugDescription)")
    return profileMenu
  }

  /// Wait for the DEBUG-only auto-pick seam to select `fast-think` and raise
  /// the compatibility popover. Asserts the requested outcome button presents.
  @MainActor
  private func openSwapPopoverSwitchingToFastThink(
    in app: XCUIApplication,
    requiringButton buttonLabel: String
  ) -> XCUIElement {
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenu.waitForExistence(timeout: 10),
                  "profile switcher (toolbar.profile) missing; app tree: \(app.debugDescription)")
    // Under a contended seated session the app can transiently report a
    // disabled accessibility tree; avoid a native Menu click entirely and wait
    // on the product condition the auto-pick should create.
    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      app.activate()
      if popover.waitForExistence(timeout: 1),
         app.buttons[buttonLabel].waitForExistence(timeout: 2) {
        return profileMenu
      }
      // Focus lost / popover didn't present — retry the observation. Do not
      // fall back to native Menu interaction here: that AppKit/XCUITest
      // boundary is the flake this scenario is isolating away from while still
      // exercising ContentToolbar.selectProfile.
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    XCTFail("cross-model profile swap must raise the swap popover via DEBUG auto-pick seam; app tree: \(app.debugDescription)")
    return profileMenu
  }

  private func clickPopoverButton(_ label: String, in app: XCUIApplication) -> Bool {
    let button = app.buttons[label]
    guard button.waitForExistence(timeout: 5) else { return false }
    button.click()
    return true
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
