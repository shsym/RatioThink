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

  private func plan(_ state: ChatStartGate.State,
                    _ action: MissingModelRecovery.PromptAction) -> NoModelLoadedPrompt.Plan {
    NoModelLoadedPrompt.plan(state: state, action: action)
  }

  func test_action_fixtures_are_what_we_expect() {
    // Guards the test premises: the seeded default is a curated download.
    guard case .load = loadAction else { return XCTFail("expected .load, got \(loadAction)") }
    guard case .download = downloadAction else { return XCTFail("expected .download, got \(downloadAction)") }
    XCTAssertEqual(unavailableAction, .unavailable)
  }

  // MARK: - engineFailed (F1 + F3)

  func test_engineFailed_retryable_shows_reason_and_retry() {
    let p = plan(.engineFailed(code: .spawnFailed, reason: "fork ENOENT", retryable: true), unavailableAction)
    XCTAssertEqual(p.headline, "The engine couldn't start")
    XCTAssertEqual(p.reason, "fork ENOENT")        // reason AT the gate, not only the banner
    XCTAssertEqual(p.primary, .retryEngine)
    XCTAssertFalse(p.showsOpenSettings)
    XCTAssertTrue(p.showsChooseAnother)
  }

  func test_engineGone_is_retryable() {
    let p = plan(.engineFailed(code: .engineGone, reason: "exited 9", retryable: true), loadAction)
    XCTAssertEqual(p.headline, "Engine stopped unexpectedly")
    XCTAssertEqual(p.reason, "exited 9")
    XCTAssertEqual(p.primary, .retryEngine)
  }

  func test_memoryRisk_routes_to_settings_never_retry_or_load() {
    // F3: non-retryable model-choice fault — no Load/Retry even though the
    // model is on disk (action == .load); route to Models settings.
    let p = plan(.engineFailed(code: .memoryRisk, reason: "9.0 GB; choose smaller", retryable: false), loadAction)
    XCTAssertEqual(p.headline, "Model is too large to load")
    XCTAssertEqual(p.reason, "9.0 GB; choose smaller")
    XCTAssertEqual(p.primary, .none)               // F3: no re-fire
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertFalse(p.showsModelChip)
  }

  func test_killRejected_is_terminal_no_retry() {
    // F3: non-retryable, non-model-choice → reason only, no Retry loop.
    let p = plan(.engineFailed(code: .killRejected, reason: "zombie pid 42", retryable: false), loadAction)
    XCTAssertEqual(p.reason, "zombie pid 42")
    XCTAssertEqual(p.primary, .none)
    XCTAssertFalse(p.showsOpenSettings)
    XCTAssertTrue(p.showsChooseAnother)
  }

  func test_modelMissing_downloadable_offers_inline_download() {
    // #326 inline download IS the fix for a missing-but-downloadable model.
    let p = plan(.engineFailed(code: .modelMissing, reason: "not downloaded", retryable: true), downloadAction)
    XCTAssertEqual(p.headline, "Default model isn't downloaded")
    XCTAssertEqual(p.reason, "not downloaded")
    XCTAssertTrue(p.showsDownloadCTA)
    XCTAssertEqual(p.primary, .none)               // CTA owns the action, not Load
  }

  func test_modelMissing_not_downloadable_routes_to_settings() {
    let p = plan(.engineFailed(code: .modelMissing, reason: "no HF fallback", retryable: true), unavailableAction)
    XCTAssertFalse(p.showsDownloadCTA)
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertEqual(p.primary, .none)
    XCTAssertEqual(p.reason, "no HF fallback")
  }

  // MARK: - loadFailed / helperUnreachable / configBroken (F1)

  func test_loadFailed_shows_reason_and_retry_load() {
    let p = plan(.loadFailed(modelID: "M", reason: "model_not_found"), loadAction)
    XCTAssertEqual(p.headline, "Couldn't load the model")
    XCTAssertEqual(p.reason, "model_not_found")
    XCTAssertEqual(p.primary, .retryLoad)
  }

  func test_helperUnreachable_shows_reason_and_refresh() {
    let p = plan(.helperUnreachable(reason: "connection invalid"), unavailableAction)
    XCTAssertEqual(p.headline, "Can't reach the engine")
    XCTAssertEqual(p.reason, "connection invalid")
    XCTAssertEqual(p.primary, .refresh)
  }

  func test_configBroken_shows_reason_and_settings() {
    let p = plan(.configBroken(reason: "marker unreadable"), unavailableAction)
    XCTAssertEqual(p.headline, "Can't read your profile selection")
    XCTAssertEqual(p.reason, "marker unreadable")
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

  func test_busy_loading_is_wait_only() {
    let p = plan(.busy(.loadingModel(modelID: "M")), loadAction)
    XCTAssertTrue(p.showsWaitSpinner)
    XCTAssertFalse(p.showsDownloadCTA)
    XCTAssertEqual(p.primary, .none)
  }

  // MARK: - #326 paths preserved (regression guard)

  func test_needsDefaultLoad_on_disk_offers_load_with_benign_headline() {
    let p = plan(.needsDefaultLoad(modelID: ProfileStore.defaultChatModelID), loadAction)
    XCTAssertEqual(p.headline, "Model not loaded yet")  // #397 framing
    XCTAssertTrue(p.showsModelChip)
    XCTAssertEqual(p.primary, .load)
  }

  func test_needsDefaultLoad_not_on_disk_offers_download_keeps_pinned_headline() {
    let p = plan(.needsDefaultLoad(modelID: ProfileStore.defaultChatModelID), downloadAction)
    XCTAssertEqual(p.headline, "No model loaded")       // S326/S286 pin this for .download
    XCTAssertTrue(p.showsDownloadCTA)
    XCTAssertEqual(p.primary, .none)                    // no noModel.load for .download
  }

  func test_noDefault_is_unavailable_with_settings() {
    let p = plan(.noDefault, unavailableAction)
    XCTAssertEqual(p.headline, "No model loaded")
    XCTAssertTrue(p.showsUnavailableCopy)
    XCTAssertTrue(p.showsOpenSettings)
    XCTAssertEqual(p.primary, .none)
  }
}
