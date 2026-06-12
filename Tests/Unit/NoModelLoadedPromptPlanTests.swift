import XCTest
@testable import RatioThink

/// #397 F1/F8: view-level coverage that the no-model gate renders DISTINCT
/// content (reason + correct action) for each wired ChatStartGate state —
/// not the generic "Load" fall-through the review flagged. Drives the pure
/// `NoModelLoadedPrompt.plan(state:action:)` so the per-state copy +
/// affordances are asserted without a view hierarchy.
@MainActor
final class NoModelLoadedPromptPlanTests: XCTestCase {

  // #326 availability actions, built via the shared recovery decision so
  // no ModelDownloadTarget has to be constructed by hand.
  private let loadAction = MissingModelRecovery.promptAction(
    profileDefaultModel: ProfileStore.defaultChatModelID, isInstalled: true)
  private let downloadAction = MissingModelRecovery.promptAction(
    profileDefaultModel: ProfileStore.defaultChatModelID, isInstalled: false)
  private let unavailableAction = MissingModelRecovery.promptAction(
    profileDefaultModel: nil, isInstalled: false)

  /// Defaults to `willAutoSend: true` — the blocked-send path, where the
  /// "…to send your message" promise copy is the expected rendering. #516
  /// tests pass false explicitly to assert the neutral (launch-prompt) copy.
  private func plan(_ state: ChatStartGate.State,
                    _ action: MissingModelRecovery.PromptAction,
                    willAutoSend: Bool = true) -> NoModelLoadedPrompt.Plan {
    NoModelLoadedPrompt.plan(state: state, action: action, willAutoSend: willAutoSend)
  }

  func test_action_fixtures_are_what_we_expect() {
    // Guards the test premises: the seeded default is a curated download.
    guard case .load = loadAction else { return XCTFail("expected .load, got \(loadAction)") }
    guard case .download = downloadAction else { return XCTFail("expected .download, got \(downloadAction)") }
    XCTAssertEqual(unavailableAction, .unavailable)
  }

  // MARK: - engineFailed (F1 + F3)

  func test_engineFailed_retryable_shows_curated_reason_and_retry() {
    // #477: headline, reason, AND the primary affordance all come from
    // the EngineProblem taxonomy — the gate's raw diagnostic never renders.
    let p = plan(.engineFailed(code: .spawnFailed, reason: "fork ENOENT"), unavailableAction)
    XCTAssertEqual(p.headline, "The engine couldn’t start")
    XCTAssertEqual(p.reason, "The engine failed to start. Try restarting it.")
    XCTAssertEqual(p.primary, .retryEngine)
    XCTAssertFalse(p.showsOpenSettings)
  }

  func test_degraded_helper_never_offers_engine_retry() {
    // Review F2: `.degraded` invitesResumeRetry on the menu axis, but its
    // taxonomy recovery is restart-HELPER — a Retry that re-fires an
    // engine start the degraded helper will refuse must not render.
    let p = plan(.engineFailed(code: .degraded, reason: "helper boot fell back"), unavailableAction)
    XCTAssertEqual(p.headline, "Engine helper problem")
    XCTAssertEqual(p.reason, "The background helper hit a problem and needs to be restarted.")
    XCTAssertEqual(p.primary, .none)
    XCTAssertFalse(p.showsOpenSettings)
  }

  func test_engineGone_is_retryable() {
    let p = plan(.engineFailed(code: .engineGone, reason: "exited 9"), loadAction)
    XCTAssertEqual(p.headline, "Engine stopped unexpectedly")
    XCTAssertEqual(p.reason, "The engine process exited. Restart the engine to continue.")
    XCTAssertFalse(p.reason?.contains("exited 9") ?? false)
    XCTAssertEqual(p.primary, .retryEngine)
  }

  func test_memoryRisk_routes_to_settings_never_retry_or_load() {
    // F3: non-retryable model-choice fault — no Load/Retry even though the
    // model is on disk (action == .load); route to Models settings.
    let p = plan(.engineFailed(code: .memoryRisk, reason: "9.0 GB; choose smaller"), loadAction)
    XCTAssertEqual(p.headline, "Model too large")
    XCTAssertEqual(p.reason, "This model exceeds this Mac’s safe memory limit. Pick a smaller model.")
    XCTAssertEqual(p.primary, .none)               // F3: no re-fire
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertFalse(p.showsModelChip)
  }

  func test_modelUnsupported_routes_to_settings_never_retry() {
    let reason = "Couldn’t load acme/model.gguf: the selected model is unsupported or not loadable. "
      + "To recover, choose a curated model, remove or fix the cached repo, or install a supported artifact."
    let p = plan(.engineFailed(code: .modelUnsupported, reason: reason), loadAction)
    XCTAssertEqual(p.headline, "Model unsupported")
    XCTAssertEqual(
      p.reason,
      "The selected model is unsupported or not loadable. Choose a curated model, remove or fix the cached repo, or install a supported artifact."
    )
    XCTAssertEqual(p.primary, .none)
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertFalse(p.showsModelChip)
    XCTAssertTrue(p.reason?.contains("Choose a curated model") ?? false)
  }

  func test_killRejected_is_terminal_no_retry() {
    // F3: non-retryable, non-model-choice → reason only, no Retry loop.
    // Review F2: the headline must match the body (refused to STOP), not
    // claim a failed start.
    let p = plan(.engineFailed(code: .killRejected, reason: "zombie pid 42"), loadAction)
    XCTAssertEqual(p.headline, "Engine couldn’t be stopped")
    XCTAssertEqual(p.reason, "The engine process refused to stop. Quit and reopen the app if this persists.")
    XCTAssertFalse(p.reason?.contains("pid 42") ?? false)
    XCTAssertEqual(p.primary, .none)
    XCTAssertFalse(p.showsOpenSettings)
  }

  func test_modelMissing_downloadable_offers_inline_download() {
    // #326 inline download IS the fix for a missing-but-downloadable model.
    // #477: the CTA carries the action; no reason line under it.
    // Review v2 F1: this failure state carries no target axis while the CTA
    // downloads the gate target (the pin when present) — the headline is
    // target-NEUTRAL and doubles as the explainer, so no downloadCaption.
    let p = plan(.engineFailed(code: .modelMissing, reason: "not downloaded"), downloadAction)
    XCTAssertEqual(p.headline, "Model isn't downloaded")
    XCTAssertNil(p.reason)
    XCTAssertNil(p.downloadCaption, "headline explains the state; no second caption")
    XCTAssertTrue(p.showsDownloadCTA)
    XCTAssertEqual(p.primary, .none)               // CTA owns the action, not Load
  }

  func test_modelMissing_not_downloadable_routes_to_settings() {
    let p = plan(.engineFailed(code: .modelMissing, reason: "no HF fallback"), unavailableAction)
    XCTAssertFalse(p.showsDownloadCTA)
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertEqual(p.primary, .none)
    XCTAssertEqual(p.reason, "The selected model isn’t downloaded. Download it in Settings → Models, or pick another model.")
  }

  // MARK: - helperUnreachable / configBroken (F1)

  func test_helperUnreachable_shows_fixed_copy_and_refresh() {
    // #477: the raw XPC transport string stays in logs.
    let p = plan(.helperUnreachable(reason: "connection invalid"), unavailableAction)
    XCTAssertEqual(p.headline, "Can't reach the engine")
    XCTAssertEqual(p.reason, "The app can't reach its background helper right now. Try again in a moment.")
    XCTAssertEqual(p.primary, .refresh)
  }

  func test_configBroken_shows_fixed_copy_and_settings() {
    let p = plan(.configBroken(reason: "marker unreadable"), unavailableAction)
    XCTAssertEqual(p.headline, "Can't read your profile selection")
    XCTAssertEqual(p.reason, "Your profile settings couldn't be read. Open Settings → Models to fix them.")
    XCTAssertEqual(p.primary, .none)
    XCTAssertTrue(p.showsOpenSettings)
  }

  // MARK: - F2: busy keeps the download CTA on a fresh install

  func test_busy_starting_keeps_download_cta_when_not_downloaded() {
    let p = plan(.busy(.startingEngine), downloadAction)
    XCTAssertEqual(p.headline, "Starting the engine…")
    XCTAssertTrue(p.showsWaitSpinner)
    XCTAssertTrue(p.showsDownloadCTA, "F2: a fresh-install model must stay downloadable while the engine starts")
  }

  func test_busy_starting_hides_download_when_model_on_disk() {
    let p = plan(.busy(.startingEngine), loadAction)
    XCTAssertTrue(p.showsWaitSpinner)
    XCTAssertFalse(p.showsDownloadCTA)
  }

  func test_busy_stopping_is_wait_only() {
    let p = plan(.busy(.stoppingEngine), loadAction)
    XCTAssertTrue(p.showsWaitSpinner)
    XCTAssertFalse(p.showsDownloadCTA)
    XCTAssertEqual(p.primary, .none)
  }

  // MARK: - #326 paths preserved (regression guard)

  func test_needsLoad_on_disk_offers_load_with_benign_headline() {
    let p = plan(.needsLoad(target: ModelTarget(modelID: ProfileStore.defaultChatModelID, source: .profileDefault)), loadAction)
    XCTAssertEqual(p.headline, "Model not loaded yet")  // #397 framing
    XCTAssertTrue(p.showsModelChip)
    XCTAssertEqual(p.primary, .load)
  }

  func test_needsLoad_not_on_disk_offers_download_with_truthful_headline() {
    let p = plan(.needsLoad(target: ModelTarget(modelID: ProfileStore.defaultChatModelID, source: .profileDefault)), downloadAction)
    // #446: headline agrees with the body ("isn't downloaded yet") and with
    // the .engineFailed(.modelMissing) + .download sibling — not the
    // contradictory "No model loaded" (a default IS configured). GUI S286/S326
    // assert via noModel.cancel, not the headline, so nothing else pins it.
    XCTAssertEqual(p.headline, "Default model isn't downloaded")
    XCTAssertTrue(p.showsDownloadCTA)
    XCTAssertEqual(p.primary, .none)                    // no noModel.load for .download
  }

  // MARK: - #497: source-honest framing for a pinned selection

  func test_497_needsLoad_selected_download_headline_names_the_selection() {
    let p = plan(.needsLoad(target: ModelTarget(
      modelID: ProfileStore.defaultChatModelID, source: .selected)), downloadAction)
    XCTAssertEqual(p.headline, "Selected model isn't downloaded",
                   "a pinned selection must never be described as the default")
    XCTAssertTrue(p.showsDownloadCTA)
  }

  func test_497_needsLoad_selected_on_disk_offers_load_same_affordances() {
    let p = plan(.needsLoad(target: ModelTarget(
      modelID: ProfileStore.defaultChatModelID, source: .selected)), loadAction)
    XCTAssertEqual(p.headline, "Model not loaded yet")
    XCTAssertTrue(p.showsModelChip)
    XCTAssertEqual(p.primary, .load)
  }

  func test_noDefault_is_unavailable_with_settings() {
    let p = plan(.noDefault, unavailableAction)
    XCTAssertEqual(p.headline, "No model loaded")
    XCTAssertEqual(p.unavailableCopy,
                   "This profile has no model ready. Choose one from the Model menu in the toolbar, or add one in Settings → Models.")
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertEqual(p.primary, .none)
  }

  // MARK: - review v1 F1/F2/F5: source-honest copy lives in the pure Plan

  func test_497_needsLoad_selected_unavailable_names_the_pin() {
    // Review v1 F1: a pinned, non-loadable, non-downloadable model must be
    // named as the SELECTION — never "this profile has no model ready".
    let p = plan(.needsLoad(target: ModelTarget(
      modelID: "org/picked", source: .selected)), unavailableAction)
    XCTAssertEqual(p.headline, "Selected model isn't available")
    XCTAssertEqual(p.unavailableCopy,
                   "Your selected model isn't available on this Mac. Choose another from the Model menu in the toolbar, or add one in Settings → Models.")
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertEqual(p.primary, .none)
  }

  func test_497_needsLoad_default_unavailable_keeps_profile_framing() {
    let p = plan(.needsLoad(target: ModelTarget(
      modelID: "org/default", source: .profileDefault)), unavailableAction)
    XCTAssertEqual(p.headline, "No model loaded")
    XCTAssertEqual(p.unavailableCopy,
                   "This profile has no model ready. Choose one from the Model menu in the toolbar, or add one in Settings → Models.")
  }

  func test_497_load_captions_follow_target_source() {
    // Review v1 F5: captions are part of the pure Plan, asserted here.
    let selected = plan(.needsLoad(target: ModelTarget(
      modelID: ProfileStore.defaultChatModelID, source: .selected)), loadAction)
    XCTAssertEqual(selected.loadCaption,
                   "Load your selected model to send your message?")
    let fallback = plan(.needsLoad(target: ModelTarget(
      modelID: ProfileStore.defaultChatModelID, source: .profileDefault)), loadAction)
    XCTAssertEqual(fallback.loadCaption,
                   "Load this profile's default model to send your message?")
  }

  func test_497_download_captions_follow_target_source() {
    let selected = plan(.needsLoad(target: ModelTarget(
      modelID: ProfileStore.defaultChatModelID, source: .selected)), downloadAction)
    XCTAssertEqual(selected.downloadCaption,
                   "Your selected model isn't downloaded yet. Download it to send your message.")
    let fallback = plan(.needsLoad(target: ModelTarget(
      modelID: ProfileStore.defaultChatModelID, source: .profileDefault)), downloadAction)
    XCTAssertEqual(fallback.downloadCaption,
                   "This profile's model isn't downloaded yet. Download it to send your message.")
  }

  func test_497_busy_download_detail_is_target_neutral() {
    // Review v1 F2: `.busy` has no target axis, so the spinner detail must
    // never claim "this profile's model" while the CTA downloads a pin.
    let p = plan(.busy(.startingEngine), downloadAction)
    XCTAssertEqual(p.detail, "The model isn't downloaded yet — download it to continue.")
    XCTAssertNil(p.downloadCaption, "the spinner detail explains the state; no second caption")
    let loading = plan(.busy(.startingEngine), loadAction)
    XCTAssertEqual(loading.detail, "Your model is loading — your message will send once it's ready.")
    XCTAssertEqual(plan(.busy(.stoppingEngine), loadAction).detail, "One moment…")
  }

  // MARK: - #400: availability action is derived LIVE per render (drift fix)

  /// The regression #400 closes: the availability action was captured ONCE
  /// into `@State`, so it froze (e.g. a stale `.download`) while the prompt
  /// stayed open. The fix routes the prompt's action through
  /// `ChatScaffoldView.availabilityAction`, the SAME seam `noModelAction`
  /// delegates to on every render, which re-reads install-state each call.
  ///
  /// This drives that seam across an install-state flip with a STATEFUL
  /// probe: the action must follow the latest install-state
  /// (`.download` → `.load`) AND the probe must be consulted on every call
  /// (not once). A reintroduced capture / memoization would return the
  /// stale `.download` on the second call (and leave `probeCalls == 1`),
  /// failing this test — where the old `plan()`-only test, asserting an
  /// already-pure function, would still pass. (View-host re-render is not
  /// asserted — no ViewInspector dep — but the per-render derivation the
  /// view runs is.)
  func test_availabilityAction_is_reread_every_render_not_captured() {
    let slug = ProfileStore.defaultChatModelID
    var installed = false
    var probeCalls = 0
    let probe: (String) -> Bool = { _ in probeCalls += 1; return installed }

    // Render 1 — model not on disk → Download.
    let r1 = ChatScaffoldView.availabilityAction(gateModel: slug, isModelInstalled: probe)
    guard case .download = r1 else { return XCTFail("render 1 expected .download, got \(r1)") }

    // The model lands on disk between renders.
    installed = true

    // Render 2 — SAME slug, install-state flipped → must re-probe and
    // return .load. A captured/memoized derivation returns the stale
    // .download here and fails.
    let r2 = ChatScaffoldView.availabilityAction(gateModel: slug, isModelInstalled: probe)
    guard case .load = r2 else { return XCTFail("render 2 expected .load after install, got \(r2)") }

    XCTAssertEqual(probeCalls, 2,
                   "install-state must be re-read every render, not captured once")

    // The rendered plan follows the live action for an unchanged lifecycle
    // state (sheet open on a profile default): Download CTA → Load.
    let sheetOpen: ChatStartGate.State = .needsLoad(target: ModelTarget(
      modelID: slug, source: .profileDefault))
    XCTAssertTrue(plan(sheetOpen, r1).showsDownloadCTA)
    XCTAssertEqual(plan(sheetOpen, r2).primary, .load)
  }

  /// `availabilityAction` with no profile default is `.unavailable`
  /// regardless of the install probe — and must NOT consult the probe
  /// (nothing to check). Guards the `slug.map(...) ?? false` short-circuit.
  func test_availabilityAction_no_default_is_unavailable_without_probing() {
    var probeCalls = 0
    let action = ChatScaffoldView.availabilityAction(
      gateModel: nil, isModelInstalled: { _ in probeCalls += 1; return true })
    XCTAssertEqual(action, .unavailable)
    XCTAssertEqual(probeCalls, 0, "no slug → no install probe")
  }

  // MARK: - gate model identity follows the boot path (#459/#460 interaction)

  /// With the engine stopped, `currentModelID` deliberately nils the chat's
  /// pick (#460), so the gate's model-identity axis must come from
  /// `gateTarget` — the same pick-over-default precedence the Load tap's
  /// `startEngineForSelectedProfile` boots (#459 repro 1). The prompt must
  /// name the PICK, never the profile default the boot would ignore.
  func test_gate_with_pick_and_stopped_engine_carries_the_pick() {
    let pick = "org/picked/picked.gguf"
    let state = ChatStartGate.evaluate(
      engineStatus: .stopped,
      helperError: nil,
      resolvedModelID: nil,  // engine stopped → currentModelID is nil (#460)
      target: ChatScaffoldView.gateTarget(
        selectedModelID: pick,
        profileDefaultModel: ProfileStore.defaultChatModelID))
    XCTAssertEqual(state, .needsLoad(target: ModelTarget(modelID: pick, source: .selected)))
  }

  func test_gateTarget_precedence_matches_boot_path() {
    XCTAssertEqual(
      ChatScaffoldView.gateTarget(selectedModelID: "pick", profileDefaultModel: "default"),
      ModelTarget(modelID: "pick", source: .selected))
    XCTAssertEqual(
      ChatScaffoldView.gateTarget(selectedModelID: nil, profileDefaultModel: "default"),
      ModelTarget(modelID: "default", source: .profileDefault))
    // Blank pick falls back, mirroring the helper's nil/blank boot fallback.
    XCTAssertEqual(
      ChatScaffoldView.gateTarget(selectedModelID: "  ", profileDefaultModel: "default"),
      ModelTarget(modelID: "default", source: .profileDefault))
    XCTAssertNil(ChatScaffoldView.gateTarget(selectedModelID: nil, profileDefaultModel: nil))
  }

  /// Availability keys on the gate model: a pick that IS installed while
  /// the profile default is NOT must yield `.load(pick)` — never the
  /// default's Download CTA (which would download a model the Load tap
  /// wouldn't boot).
  func test_availability_keys_on_the_pick_not_the_default() {
    let pick = "org/picked/picked.gguf"
    let installed: (String) -> Bool = { $0 == pick }  // default missing
    let action = ChatScaffoldView.availabilityAction(
      gateModel: ChatScaffoldView.gateTarget(
        selectedModelID: pick,
        profileDefaultModel: ProfileStore.defaultChatModelID)?.modelID,
      isModelInstalled: installed)
    XCTAssertEqual(action, .load(pick))
  }

  /// End-to-end through the plan: pick + stopped engine renders the Load
  /// chip naming the PICK (the chip slug comes from the `.load` payload).
  func test_prompt_plan_chip_names_the_pick() {
    let pick = "org/picked/picked.gguf"
    let gateTarget = ChatScaffoldView.gateTarget(
      selectedModelID: pick,
      profileDefaultModel: ProfileStore.defaultChatModelID)
    let state = ChatStartGate.evaluate(
      engineStatus: .stopped, helperError: nil,
      resolvedModelID: nil, target: gateTarget)
    let action = ChatScaffoldView.availabilityAction(
      gateModel: gateTarget?.modelID, isModelInstalled: { $0 == pick })
    let p = plan(state, action)
    XCTAssertTrue(p.showsModelChip)
    XCTAssertEqual(p.primary, .load)
    guard case let .load(chipModel) = action else {
      return XCTFail("expected .load, got \(action)")
    }
    XCTAssertEqual(chipModel, pick, "the chip must name the model the tap will boot")
  }

  /// Review v4 F1: the `ModelMissingBanner` target is keyed on the GATE
  /// model like its suppression axis. Installed pick + missing-but-
  /// downloadable default + `.failed(.modelMissing)` must never surface
  /// the DEFAULT's download CTA (a model the boot override wouldn't
  /// load) — with the pick not in the curated catalog the banner is
  /// suppressed outright.
  func test_missingModel_banner_keys_on_the_pick_not_the_default() {
    // A 2-segment safetensors dir slug is genuinely non-downloadable —
    // the catalog's generic fallback synthesizes targets for ANY
    // 3-segment `<org>/<name>/<file>.gguf` slug (review v5 F1: a .gguf
    // fixture here gets a target and defeats the suppression assert).
    let pick = "org/picked"
    let failed = EngineStatus.failed(code: .modelMissing, message: "resolver trace")
    let gateModel = ChatScaffoldView.gateTarget(
      selectedModelID: pick,
      profileDefaultModel: ProfileStore.defaultChatModelID)?.modelID

    XCTAssertNil(
      MissingModelRecovery.bannerTarget(
        engineStatus: failed, profileDefaultModel: gateModel),
      "banner must not offer the default's download when the boot model is the pick")

    // Premise guard: the OLD keying (profile default) WOULD have offered
    // the default's download here — the substitution is load-bearing.
    XCTAssertNotNil(
      MissingModelRecovery.bannerTarget(
        engineStatus: failed, profileDefaultModel: ProfileStore.defaultChatModelID))

    // Unpinned chat: gate model IS the default — banner behavior unchanged.
    XCTAssertNotNil(
      MissingModelRecovery.bannerTarget(
        engineStatus: failed,
        profileDefaultModel: ChatScaffoldView.gateTarget(
          selectedModelID: nil,
          profileDefaultModel: ProfileStore.defaultChatModelID)?.modelID))
  }

  /// #568: with the display banner suppressed for a non-downloadable pick,
  /// the chat-local action-error banner must NOT take over for the live
  /// `.failed` status. RootView's unified status banner owns live engine
  /// failures; the chat-local banner is only for thrown action errors while
  /// status itself is not failed.
  func test_missingModel_nonDownloadablePick_doesNotRenderActionErrorBanner() {
    let pick = "org/picked"  // non-downloadable (2-segment dir slug)
    let failed = EngineStatus.failed(code: .modelMissing, message: "resolver trace")
    let gateModel = ChatScaffoldView.gateTarget(
      selectedModelID: pick,
      profileDefaultModel: ProfileStore.defaultChatModelID)?.modelID

    // Both axes key on the same gate model, as ChatScaffoldView wires them.
    let hasDownloadTarget = MissingModelRecovery.bannerTarget(
      engineStatus: failed, profileDefaultModel: gateModel) != nil
    XCTAssertFalse(hasDownloadTarget, "premise: the pick has no download target")
    XCTAssertNil(
      MissingModelRecovery.engineActionFailureBannerMessage(
        engineStatus: failed,
        actionError: nil),
      "live modelMissing failures are owned by the unified status banner")

    // Premise guard: keying the display banner on the DEFAULT (old axis)
    // would still find a download target, while the gate-axis display banner
    // is nil. The action-error banner remains nil either way because live
    // `.failed` status is not its responsibility.
    let staleAxisTarget = MissingModelRecovery.bannerTarget(
      engineStatus: failed,
      profileDefaultModel: ProfileStore.defaultChatModelID) != nil
    XCTAssertTrue(staleAxisTarget)
    XCTAssertNil(MissingModelRecovery.engineActionFailureBannerMessage(
      engineStatus: failed,
      actionError: nil))
  }

  // MARK: - #516: the "…to send your message" promise tracks willAutoSend

  /// The copy guard the ticket requires: every "your message will send" /
  /// "…to send your message" line renders ONLY when a pending auto-send is
  /// armed to keep that promise. The same sheet raised with an empty
  /// composer (the launch-time engine-start prompt) must stay neutral.
  func test_516_promise_copy_only_when_auto_send_armed() {
    // busy spinner detail.
    let armed = plan(.busy(.startingEngine), loadAction, willAutoSend: true)
    XCTAssertEqual(armed.detail, "Your model is loading — your message will send once it's ready.")
    let unarmed = plan(.busy(.startingEngine), loadAction, willAutoSend: false)
    XCTAssertEqual(unarmed.detail, "Your model is loading.")

    // load captions, both target sources.
    let target = ModelTarget(modelID: ProfileStore.defaultChatModelID, source: .profileDefault)
    XCTAssertEqual(plan(.needsLoad(target: target), loadAction, willAutoSend: false).loadCaption,
                   "Load this profile's default model?")
    let pinned = ModelTarget(modelID: ProfileStore.defaultChatModelID, source: .selected)
    XCTAssertEqual(plan(.needsLoad(target: pinned), loadAction, willAutoSend: false).loadCaption,
                   "Load your selected model?")

    // download captions, both target sources.
    XCTAssertEqual(plan(.needsLoad(target: target), downloadAction, willAutoSend: false).downloadCaption,
                   "This profile's model isn't downloaded yet. Download it to use it here.")
    XCTAssertEqual(plan(.needsLoad(target: pinned), downloadAction, willAutoSend: false).downloadCaption,
                   "Your selected model isn't downloaded yet. Download it to use it here.")
  }

  /// Sweep guard: with `willAutoSend: false`, NO rendered string anywhere in
  /// the plan may promise a send — across every state × action cell.
  func test_516_no_state_promises_a_send_when_unarmed() {
    let states: [ChatStartGate.State] = [
      .busy(.startingEngine), .busy(.stoppingEngine),
      .needsLoad(target: ModelTarget(modelID: ProfileStore.defaultChatModelID, source: .profileDefault)),
      .needsLoad(target: ModelTarget(modelID: ProfileStore.defaultChatModelID, source: .selected)),
      .noDefault,
      .engineFailed(code: .modelMissing, reason: "x"),
      .helperUnreachable(reason: "x"),
      .configBroken(reason: "x"),
    ]
    for state in states {
      for action in [loadAction, downloadAction, unavailableAction] {
        let p = plan(state, action, willAutoSend: false)
        let rendered = [p.headline, p.reason, p.detail, p.loadCaption,
                        p.downloadCaption, p.unavailableCopy]
          .compactMap { $0 }.joined(separator: " ").lowercased()
        XCTAssertFalse(rendered.contains("will send") || rendered.contains("send your message"),
                       "unarmed gate promises a send in \(state) × \(action): \(rendered)")
      }
    }
  }
}
