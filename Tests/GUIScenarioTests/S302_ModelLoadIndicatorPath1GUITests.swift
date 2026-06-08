import XCTest

/// toolbar model-load indicator via the REAL production
/// path-1 (explicit load), plus the #359 confirmed mid-load cancel gate
/// — opening the popover is info-only, the "Cancel" button only arms an
/// explicit "Stop Loading" confirm, and only that confirm cancels.
///
/// Where S297 drives the indicator through the chat-send meta-frame path
/// (`applyChatMetaEvent`, which only fires on engine `model_loading`
/// frames pie-control v1 never emits), this exercises the path a real
/// user actually hits:
///
///   model menu → confirm gate (ProfileSwapPopover "Switch")
///     → ProfileSwapCoordinator.confirm → startLoad
///       → ModelLoadCenter.load(modelID:streamFactory:)
///         → HTTPEngineClient.loadModel → POST /v1/models/load
///
/// `center.load` sets state=.loading LOCALLY (ModelLoadCenter.swift:124)
/// the instant the load begins — independent of any engine frame. The
/// harness (Scripts/loadviz-harness.py) holds the load SSE
/// (no `model_loading` frame, exactly v1's shape) then emits
/// `model_ready`, so the toolbar "Loading <id>" label is observable
/// before it clears to the "Model loaded: <id>" ready ring.
///
///  relocated the indicator from the window `NSToolbar` into the
/// content-area `ContentToolbar`: an `NSToolbar`-hosted SwiftUI popover
/// could not be driven reliably under XCUITest (intermittent button
/// action + transient-popover dismissal). Content-hosted, it behaves
/// like the sibling ProfileSwap/params/system popovers.
///
/// Popover container `.accessibilityIdentifier`s mask inner control ids,
/// so inner buttons are queried by visible label ("Switch", "Cancel").
///
/// Uses narrow type queries only — `descendants(matching: .any)` can
/// SIGBUS on a degraded session (GUI-test convention).
final class S302_ModelLoadIndicatorPath1GUITests: XCTestCase {
  /// Seeded curated default surfaced in the chat model menu ( / S260).
  private static let menuModelLeaf = "Qwen3-0.6B-Q8_0.gguf"

  override func setUp() async throws { try guardSeatedGUI() }

  // MARK: - path-1: explicit load lights the indicator, then clears to ready

  @MainActor
  func test_path1_explicit_load_shows_loading_then_ready() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch

    // Wiring assertion (review F4): if the indicator element does not
    // exist, the failure is `ContentToolbar` wiring (no center wired,
    // not rendered) rather than a state-machine regression. Splitting
    // this out makes the diagnostic unambiguous — `waitForLabel` below
    // tolerates `!element.exists` and would otherwise conflate the two.
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated — ContentToolbar wiring regression "
        + "(`modelLoadCenter` not passed)? app: \(app.debugDescription)")

    // During the harness hold: the locally-set .loading must surface as
    // a "Loading model …" label (ModelLoadCenter.swift:124 → indicator).
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Loading model", timeout: 15),
      "toolbar.modelLoadIndicator exists but never showed 'Loading model' — state-machine "
        + "regression (confirm-gate did not start the load OR `center.load` did not transition "
        + "synchronously to `.loading`)? label=\(indicator.label); app: \(app.debugDescription)")

    // After model_ready: the Loading label clears and the ready ring
    // takes over ("Model loaded: <id>", label prefix nil for .ready).
    // Derive the wait from the harness hold (+ slack) rather than a fixed
    // value — model_ready only lands after the hold, so a hardcoded window
    // shorter than the hold would flake when the hold is raised.
    let hold = try Self.holdSeconds()
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Engine running, model", timeout: hold + 10),
      "toolbar.modelLoadIndicator did not clear to the 'Model loaded:' ready ring within hold+10 "
        + "(hold=\(hold)s); label=\(indicator.label); app: \(app.debugDescription)")
  }

  // MARK: - #396: the loading popover shows an honest indeterminate
  // status, never a bare "—" primary value

  /// The loadviz harness emits no `model_loading` byte/eta frame (exactly
  /// pie-control v1's shape), so a held load is genuinely indeterminate
  /// (loaded=0/total=0/eta=nil). The popover must say "Preparing…" — an
  /// honest "we're working on it" — and MUST NOT render the old bare "—"
  /// for a live load. This is the EXECUTED counterpart to the pure
  /// `ModelLoadPopover.loadingDetail` unit coverage (#396).
  @MainActor
  func test_path1_loading_popover_shows_honest_indeterminate_not_dash() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated — ContentToolbar wiring regression? "
        + "app: \(app.debugDescription)")
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Loading model", timeout: 15),
      "indicator never entered the loading state; label=\(indicator.label); app: \(app.debugDescription)")

    // Open the popover DURING the hold and read its detail rows.
    XCTAssertTrue(openIndicatorPopover(indicator, in: app, expecting: .preparing),
                  "indicator popover did not open with Preparing… content; app: \(app.debugDescription); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")

    // Honest indeterminate primary: a byte-less held load reads
    // "Preparing…" (U+2026), not "Loaded —" / "ETA —".
    XCTAssertTrue(
      Self.staticText("Preparing…", in: app).waitForExistence(timeout: 5),
      "loading popover did not show the honest 'Preparing…' status; the live load is "
        + "indeterminate so it must read 'Preparing…', not a bare dash; "
        + "popover: \(app.popovers.firstMatch.debugDescription)")

    // The #396 regression guard: no bare "—" primary anywhere in a live
    // load's popover (the original ticket complaint was a "-- ETA").
    XCTAssertFalse(
      Self.staticText("—", in: app).exists,
      "loading popover rendered a bare '—' primary — unknown ETA/bytes must read "
        + "'Preparing…'/'Estimating…', never a meaningless dash (#396); "
        + "popover: \(app.popovers.firstMatch.debugDescription)")
  }

  // MARK: - mid-load cancel: opening info never cancels; only the
  // explicit confirmed "Stop Loading" cancels (#359)

  @MainActor
  func test_path1_midload_cancel_is_confirmed_and_only_confirm_cancels() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    // Wiring assertion (review F4): split element-existence from
    // label-state so a wiring regression doesn't masquerade as a
    // state-machine regression in the diagnostic.
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated — ContentToolbar wiring regression "
        + "(`modelLoadCenter` not passed)? app: \(app.debugDescription)")
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Loading model", timeout: 15),
      "toolbar.modelLoadIndicator exists but never showed 'Loading model' before cancel — "
        + "state-machine regression? label=\(indicator.label); app: \(app.debugDescription)")

    // (1) Opening the indicator popover is info-only — it must NOT cancel
    // the load (#359 acceptance: "click-open does not cancel").
    XCTAssertTrue(openIndicatorPopover(indicator, in: app, expecting: .cancel),
                  "indicator popover did not open with a Cancel action; app: \(app.debugDescription); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")
    XCTAssertTrue(indicator.label.hasPrefix("Loading model"),
                  "opening the popover cancelled the load — click must be info-only; "
                    + "label=\(indicator.label); app: \(app.debugDescription)")

    // (2) The "Cancel" button ARMS the confirm step; it must not cancel
    // on the first click. After clicking it the confirm prompt appears
    // ("Stop Loading" / "Keep Loading") while the load is STILL running.
    let cancelTrigger = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
    XCTAssertTrue(cancelTrigger.waitForExistence(timeout: 5),
                  "loading popover did not render a Cancel trigger; app: \(app.debugDescription)")
    cancelTrigger.click()

    let confirmStop = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Stop Loading")).firstMatch
    XCTAssertTrue(confirmStop.waitForExistence(timeout: 5),
                  "clicking Cancel did not surface the 'Stop Loading' confirm — confirm gate missing; "
                    + "app: \(app.debugDescription)")
    XCTAssertTrue(indicator.label.hasPrefix("Loading model"),
                  "arming the confirm cancelled the load — cancellation must be confirmed, not on first click; "
                    + "label=\(indicator.label); app: \(app.debugDescription)")

    // (3) Only the confirmed "Stop Loading" actually cancels. center.cancel()
    // makes a synchronous .loading → .cancelled transition
    // (ModelLoadCenter.swift), so the "Loading model" label clears …
    confirmStop.click()
    XCTAssertTrue(
      waitUntilLabelClears(indicator, prefix: "Loading model", timeout: 10),
      "toolbar.modelLoadIndicator stayed in 'Loading model' after confirmed Stop Loading; "
        + "label=\(indicator.label); app: \(app.debugDescription)")
    // … and the cancelled load must NOT complete to ready — for the
    // FULL hold + slack (review F3). The old 8 s window was decoupled
    // from `PIE_TEST_LOAD_HOLD_SECONDS`, so a regression where
    // `center.cancel()` no longer cancelled the underlying URLSession
    // task would let the harness wake at t ≈ hold, write `model_ready`,
    // and pass `XCTAssertFalse(false)` after the window had already
    // returned. Deriving from the hold catches that.
    let hold = try Self.holdSeconds()
    // Model-specific: post-#327 the pip folds engine status, and the
    // harness's 2-entry /v1/models reconcile pre-sets a `loadviz-resident`
    // stub, so "Engine running, model …" can legitimately show that stub
    // even after a cancel. The cancel guarantee is narrower: the model
    // the user cancelled (`menuModelLeaf`) must never become the resident
    // one — a completed load would read "Engine running, model <leaf>
    // resident".
    XCTAssertFalse(
      waitForLabel(indicator, beginsWith: "Engine running, model \(Self.menuModelLeaf)", timeout: hold + 5),
      "cancelled load still completed to a resident \(Self.menuModelLeaf) within hold+slack "
        + "(hold=\(hold)s); the cancel did not stop the load; app: \(app.debugDescription)")
  }

  // MARK: - "Keep Loading" backs out of the confirm without cancelling

  @MainActor
  func test_path1_keep_loading_backs_out_and_load_completes() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated — ContentToolbar wiring regression? "
        + "app: \(app.debugDescription)")
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Loading model", timeout: 15),
      "toolbar.modelLoadIndicator never showed 'Loading model'; "
        + "label=\(indicator.label); app: \(app.debugDescription)")

    // Arm the cancel confirm, then back out with "Keep Loading".
    XCTAssertTrue(openIndicatorPopover(indicator, in: app, expecting: .cancel),
                  "indicator popover did not open with a Cancel action; app: \(app.debugDescription); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")
    let cancelTrigger = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
    XCTAssertTrue(cancelTrigger.waitForExistence(timeout: 5),
                  "loading popover did not render a Cancel trigger; app: \(app.debugDescription)")
    cancelTrigger.click()

    let keepLoading = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Keep Loading")).firstMatch
    XCTAssertTrue(keepLoading.waitForExistence(timeout: 5),
                  "confirm step missing a 'Keep Loading' escape; app: \(app.debugDescription)")
    keepLoading.click()

    // Backing out must NOT cancel — the load proceeds to ready once the
    // harness releases its hold.
    let hold = try Self.holdSeconds()
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Engine running, model", timeout: hold + 15),
      "'Keep Loading' aborted the load instead of letting it finish; "
        + "label=\(indicator.label); app: \(app.debugDescription)")
  }

  // MARK: - path-2: Unload after .ready — opening info never unloads;
  // only the explicit confirmed "Unload" frees the resident model (#359)

  @MainActor
  func test_path2_unload_after_ready_is_confirmed_and_only_confirm_unloads() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated — ContentToolbar wiring regression? "
        + "app: \(app.debugDescription)")

    // Drive the load all the way to .ready ("Model loaded:") — the state
    // the Unload affordance lives in. Unlike the mid-load Cancel path,
    // Unload is real-engine-meaningful today (pie supports unload).
    let hold = try Self.holdSeconds()
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Engine running, model", timeout: hold + 15),
      "load never reached the '.ready' ring; label=\(indicator.label); app: \(app.debugDescription)")

    // (1) Opening the indicator popover is info-only — it must NOT unload
    // the resident model (#359 acceptance: click is read-only in running).
    XCTAssertTrue(openIndicatorPopover(indicator, in: app, expecting: .unload),
                  "indicator popover did not open with an Unload action; app: \(app.debugDescription); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")
    XCTAssertTrue(indicator.label.hasPrefix("Engine running, model"),
                  "opening the popover unloaded the model — click must be info-only; "
                    + "label=\(indicator.label); app: \(app.debugDescription)")

    // (2) The "Unload" button ARMS the confirm; it must not unload on the
    // first click. The arm and the confirm both read "Unload" but the
    // popover's action row is an if/else, so they are never on screen at
    // once: arming swaps the arm out for the confirm ("Keep Loaded" +
    // "Unload"). Wait for "Keep Loaded" to prove the confirm is armed,
    // and assert the model is STILL resident.
    let unloadTrigger = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Unload")).firstMatch
    XCTAssertTrue(unloadTrigger.waitForExistence(timeout: 5),
                  "ready popover did not render an Unload trigger; app: \(app.debugDescription)")
    unloadTrigger.click()

    let keepLoaded = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Keep Loaded")).firstMatch
    XCTAssertTrue(keepLoaded.waitForExistence(timeout: 5),
                  "clicking Unload did not surface the 'Keep Loaded' confirm — confirm gate missing; "
                    + "app: \(app.debugDescription)")
    XCTAssertTrue(indicator.label.hasPrefix("Engine running, model"),
                  "arming the confirm unloaded the model — unload must be confirmed, not on first click; "
                    + "label=\(indicator.label); app: \(app.debugDescription)")

    // (3) Only the confirmed "Unload" actually unloads. With the arm
    // swapped out, the sole "Unload" button is now the confirm. onUnload
    // → stopEngine (harness stub) + markUnloaded → state .idle, so the
    // indicator goes invisible and the "Model loaded:" label clears.
    let confirmUnload = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Unload")).firstMatch
    XCTAssertTrue(confirmUnload.waitForExistence(timeout: 5),
                  "confirm 'Unload' button missing after arming; app: \(app.debugDescription)")
    confirmUnload.click()

    XCTAssertTrue(
      waitUntilLabelClears(indicator, prefix: "Engine running, model", timeout: 10),
      "model did not unload after confirmed Unload — 'Model loaded:' never cleared; "
        + "label=\(indicator.label); app: \(app.debugDescription)")
  }

  // MARK: - path-2: arming Unload then dismissing (not confirming) leaves
  // the confirm DISARMED on reopen (review v1 F4)

  @MainActor
  func test_path2_unload_confirm_disarms_on_dismiss_and_reopen() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    try triggerExplicitLoad(in: app)

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 10),
      "toolbar.modelLoadIndicator was never instantiated; app: \(app.debugDescription)")

    let hold = try Self.holdSeconds()
    XCTAssertTrue(
      waitForLabel(indicator, beginsWith: "Engine running, model", timeout: hold + 15),
      "load never reached the '.ready' ring; label=\(indicator.label); app: \(app.debugDescription)")

    // Arm Unload (the .ready confirm prompt appears: "Keep Loaded" + "Unload").
    XCTAssertTrue(openIndicatorPopover(indicator, in: app, expecting: .unload),
                  "indicator popover did not open with an Unload action; app: \(app.debugDescription); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")
    let unloadTrigger = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Unload")).firstMatch
    XCTAssertTrue(unloadTrigger.waitForExistence(timeout: 5),
                  "ready popover did not render an Unload trigger; app: \(app.debugDescription)")
    unloadTrigger.click()
    let keepLoaded = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Keep Loaded")).firstMatch
    XCTAssertTrue(keepLoaded.waitForExistence(timeout: 5),
                  "Unload did not arm the confirm ('Keep Loaded' missing); app: \(app.debugDescription)")

    // Dismiss by clicking OUTSIDE the popover — NOT Keep, NOT Confirm.
    // (Esc is bound to the "Keep Loaded" button, so it would disarm via
    // Keep rather than exercise the close/reopen @State-freshness reset.)
    // Anchor the coordinate on the WINDOW (the app element proxy has no
    // finite frame → INFINITY point), low-centre and well away from the
    // top-trailing popover.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
    XCTAssertTrue(waitForNoPopover(app, timeout: 5),
                  "popover did not dismiss on an outside click; app: \(app.debugDescription)")
    // Dismissing without confirming must NOT unload — model stays resident.
    XCTAssertTrue(indicator.label.hasPrefix("Engine running, model"),
                  "dismissing the armed confirm unloaded the model; "
                    + "label=\(indicator.label); app: \(app.debugDescription)")

    // Reopen — the documented "a stale armed confirm cannot survive a
    // close/reopen" guarantee (popover @State recreated fresh) must hold:
    // the info "Unload" ARM shows, NOT the armed confirm ("Keep Loaded").
    XCTAssertTrue(openIndicatorPopover(indicator, in: app, expecting: .unload),
                  "indicator popover did not reopen with an Unload action; app: \(app.debugDescription); "
                    + "popover: \(app.popovers.firstMatch.debugDescription)")
    let reopenedUnload = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Unload")).firstMatch
    XCTAssertTrue(reopenedUnload.waitForExistence(timeout: 5),
                  "reopened popover did not show the info Unload arm; app: \(app.debugDescription)")
    let staleConfirm = app.popovers.buttons
      .matching(NSPredicate(format: "label == %@", "Keep Loaded")).firstMatch
    XCTAssertFalse(staleConfirm.waitForExistence(timeout: 2),
                   "reopened popover showed a STALE armed confirm ('Keep Loaded') — the close/reopen "
                     + "@State reset regressed; app: \(app.debugDescription)")
  }

  // MARK: - steps

  /// Launch the app pointed at the harness engine.
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
    // The loadviz harness is a pure-HTTP mock with no Helper to report
    // engine status over XPC. Pin `EngineStatus.running(port:)` so the
    // toolbar `/v1/models` reconcile (gated on `.running`) populates the
    // model menu instead of emptying it — otherwise the model menu is
    // empty and the explicit-load path never starts. See RatioThinkApp.
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    return app
  }

  /// Create a chat, pick a non-resident model from the toolbar menu, and
  /// confirm the swap — the real UI sequence into ModelLoadCenter.load.
  @MainActor
  private func triggerExplicitLoad(in app: XCUIApplication) throws {
    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app: \(app.debugDescription)")
    newChat.click()

    try selectSeededModelFromToolbar(in: app)

    // Picking a model that differs from the (nil) resident raises the
    // confirm gate; "Switch" commits the load (ContentToolbar.swift:106
    // → ProfileSwapCoordinator.confirm → startLoad). The popover's
    // container `.accessibilityIdentifier("profileSwap.popover")` masks
    // the inner `profileSwap.switch` id, so query by the visible label.
    let switchButton = app.buttons.matching(NSPredicate(format: "label == %@", "Switch")).firstMatch
    XCTAssertTrue(switchButton.waitForExistence(timeout: 5),
                  "profileSwap confirm popover did not present a Switch button; app: \(app.debugDescription)")
    switchButton.click()
  }

  /// Select the seeded model from the native toolbar `Menu` with a
  /// reconcile-aware retry/reopen loop. `/v1/models` reconciliation is async,
  /// and AppKit menu traversal can briefly expose stale `MenuItem` proxies;
  /// matching S260/S426's longer window and reopening the menu gives the real
  /// served model list time to settle before clicking the live item.
  @MainActor
  private func selectSeededModelFromToolbar(in app: XCUIApplication) throws {
    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "model menu missing after creating chat; app: \(app.debugDescription)")

    let deadline = Date().addingTimeInterval(15)
    var lastMenuDescription = ""
    var attempt = 0
    while Date() < deadline {
      attempt += 1
      modelMenu.click()
      let modelItem = seededModelMenuItem(in: app)
      if modelItem.waitForExistence(timeout: 2) {
        // Let the native menu finish opening before traversing/tapping; this
        // avoids the observed `open menu during menu traversal` boundary.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        if modelItem.exists {
          modelItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
          return
        }
      }
      lastMenuDescription = app.debugDescription
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }

    XCTFail("seeded model '\(Self.menuModelLeaf)' missing from toolbar model menu after reconcile-aware retries; "
      + "attempts=\(attempt); app: \(lastMenuDescription)")
    throw NSError(domain: "S302.ModelLoadIndicatorPath1GUITests", code: 1)
  }

  private func seededModelMenuItem(in app: XCUIApplication) -> XCUIElement {
    app.menuItems[Self.menuModelLeaf]
  }

  /// Open the indicator's popover and wait for the specific model-load
  /// content/action this test is about to drive. A bare `app.popovers.count > 0`
  /// is not a sufficient proof: native SwiftUI/AppKit popovers can be transient
  /// or stale under XCUITest, and the S302 load path regressed into false
  /// positives where no `Cancel`/`Preparing…`/`Unload` content was present.
  @MainActor
  private func openIndicatorPopover(
    _ indicator: XCUIElement,
    in app: XCUIApplication,
    expecting expectation: IndicatorPopoverExpectation
  ) -> Bool {
    _ = waitForNoPopover(app, timeout: 5)
    var attempts = 0
    while attempts < 5 {
      attempts += 1
      if app.popovers.count > 0 {
        app.typeKey(.escape, modifierFlags: [])
        _ = waitForNoPopover(app, timeout: 2)
      }
      indicator.click()
      if waitForPopoverContent(expectation, in: app, timeout: 3) { return true }
    }
    return waitForPopoverContent(expectation, in: app, timeout: 1)
  }

  private enum IndicatorPopoverExpectation {
    case cancel
    case preparing
    case unload

    var label: String {
      switch self {
      case .cancel:    return "Cancel"
      case .preparing: return "Preparing…"
      case .unload:    return "Unload"
      }
    }

    func element(in app: XCUIApplication) -> XCUIElement {
      switch self {
      case .cancel, .unload:
        return app.popovers.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
      case .preparing:
        return S302_ModelLoadIndicatorPath1GUITests.staticText(label, in: app)
      }
    }
  }

  private static func staticText(_ text: String, in app: XCUIApplication) -> XCUIElement {
    app.popovers.staticTexts
      .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
      .firstMatch
  }

  private func waitForPopoverContent(
    _ expectation: IndicatorPopoverExpectation,
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if expectation.element(in: app).exists { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return expectation.element(in: app).exists
  }

  // MARK: - polling helpers (narrow queries only)

  /// Poll an element's accessibility label for a prefix. Returns true as
  /// soon as it matches; false if the timeout elapses. Tolerates the
  /// element being transiently absent (the indicator is `opacity(0)`
  /// while idle).
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

  /// Poll until an element's label no longer has `prefix` (or the element
  /// is gone). Returns true once cleared; false on timeout.
  private func waitUntilLabelClears(_ element: XCUIElement,
                                    prefix: String,
                                    timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists || !element.label.hasPrefix(prefix) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  /// Poll until no popover is on screen. Returns true once clear.
  private func waitForNoPopover(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if app.popovers.count == 0 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  // MARK: - config

  private static let configPath = "/tmp/pie-gui-load-indicator-e2e.env"

  /// Runner-injected harness hold (`--hold-seconds`). Used to derive the
  /// negative-assert window in the cancel test so a late `.ready`
  /// can't slip past a hard-coded shorter window (review F3).
  private static func holdSeconds() throws -> TimeInterval {
    let config = try loadConfig()
    let raw = try XCTUnwrap(config["PIE_TEST_LOAD_HOLD_SECONDS"],
                            "\(configPath) must define PIE_TEST_LOAD_HOLD_SECONDS")
    let value = try XCTUnwrap(TimeInterval(raw),
                              "PIE_TEST_LOAD_HOLD_SECONDS must parse as a number; got \(raw)")
    return value
  }

  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip(" GUI load-indicator config missing at \(configPath); run Scripts/run-gui-load-indicator-e2e.sh")
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
