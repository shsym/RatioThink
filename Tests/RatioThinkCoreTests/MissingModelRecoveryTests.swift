import XCTest
@testable import RatioThinkCore

/// Pure decision logic shared by #326's two surfaces:
///   · the no-model send prompt (`NoModelLoadedPrompt`)
///   · the failed(modelMissing) chat banner (`ModelMissingBanner`)
/// Keeping the branching here (not buried in SwiftUI bodies) lets the
/// Load-vs-Download-vs-unavailable decision and the banner-gating be
/// unit-tested without standing up a view hierarchy or an engine.
final class MissingModelRecoveryTests: XCTestCase {

  // MARK: - promptAction (Path 1: no-model send prompt)

  /// Installed model → just load it (current behavior). Download is not
  /// offered for something already on disk.
  func test_promptAction_installed_model_loads() {
    let action = MissingModelRecovery.promptAction(
      profileDefaultModel: ProfileStore.defaultChatModelID,
      isInstalled: true)
    XCTAssertEqual(action, .load(ProfileStore.defaultChatModelID))
  }

  /// Not installed + a known download target → offer Download. This is
  /// the fresh-install fix: "Load the default" with nothing on disk
  /// becomes "Download it".
  func test_promptAction_missing_downloadable_model_offers_download() {
    let action = MissingModelRecovery.promptAction(
      profileDefaultModel: ProfileStore.defaultChatModelID,
      isInstalled: false)
    guard case let .download(target) = action else {
      return XCTFail("expected .download, got \(action)")
    }
    XCTAssertEqual(target.repo, "Qwen/Qwen3-0.6B-GGUF")
    XCTAssertEqual(target.file, "Qwen3-0.6B-Q8_0.gguf")
  }

  /// Not installed AND not single-file-downloadable (2-seg safetensors
  /// dir slug) → unavailable; the UI points the user at Settings →
  /// Models rather than offering a broken Download.
  func test_promptAction_missing_nondownloadable_model_is_unavailable() {
    let action = MissingModelRecovery.promptAction(
      profileDefaultModel: "Qwen/Qwen3-0.6B",
      isInstalled: false)
    XCTAssertEqual(action, .unavailable)
  }

  /// No profile default at all → unavailable (point at the toolbar /
  /// Settings), never a phantom download.
  func test_promptAction_no_default_is_unavailable() {
    XCTAssertEqual(
      MissingModelRecovery.promptAction(profileDefaultModel: nil, isInstalled: false),
      .unavailable)
  }

  // MARK: - bannerTarget (Path 2: failed(modelMissing) chat banner)

  /// Engine failed specifically because the model is missing AND the
  /// active profile's default is downloadable → surface the banner with
  /// that target.
  func test_bannerTarget_present_when_failed_modelMissing_and_downloadable() {
    let target = MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .modelMissing, message: "model missing"),
      profileDefaultModel: ProfileStore.defaultChatModelID)
    XCTAssertEqual(target?.repo, "Qwen/Qwen3-0.6B-GGUF")
    XCTAssertEqual(target?.file, "Qwen3-0.6B-Q8_0.gguf")
  }

  /// A non-modelMissing failure (e.g. memoryRisk, spawnFailed) is NOT a
  /// download problem — the banner must stay hidden so we don't tell a
  /// user to download a model that is present but too large.
  func test_bannerTarget_absent_for_non_modelMissing_failure() {
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .memoryRisk, message: "too big"),
      profileDefaultModel: ProfileStore.defaultChatModelID))
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .spawnFailed, message: "fork"),
      profileDefaultModel: ProfileStore.defaultChatModelID))
  }

  /// A healthy / non-failed engine never shows the missing-model banner.
  func test_bannerTarget_absent_when_engine_not_failed() {
    for status: EngineStatus in [.starting, .stopped, .stopping,
                                 .running(EngineSessionSnapshot(port: 8080, profileID: "chat"))] {
      XCTAssertNil(MissingModelRecovery.bannerTarget(
        engineStatus: status,
        profileDefaultModel: ProfileStore.defaultChatModelID),
        "no banner for \(status)")
    }
  }

  /// modelMissing but the slug isn't single-file-downloadable → no
  /// banner target (the Settings path covers it).
  func test_bannerTarget_absent_when_modelMissing_but_not_downloadable() {
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .modelMissing, message: "missing"),
      profileDefaultModel: "Qwen/Qwen3-0.6B"))
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .modelMissing, message: "missing"),
      profileDefaultModel: nil))
  }

  // MARK: - bannerTarget gated by the send-gate sheet (#446: single download surface)

  /// While the send-gate sheet is presented it renders the SAME inline
  /// download, so the banner must stay hidden — otherwise the user sees two
  /// Download prompts for one model. The sheet (modal, user-initiated) owns
  /// the recovery while it is up.
  func test_bannerTarget_suppressed_while_send_gate_presented() {
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .modelMissing, message: "model missing"),
      profileDefaultModel: ProfileStore.defaultChatModelID,
      sendGatePresented: true),
      "banner must defer to the send-gate sheet's download CTA")
  }

  /// When the sheet is NOT presented the banner re-takes the surface (e.g.
  /// a post-download start that did not take is still recoverable). The
  /// `sendGatePresented:` default (false) reproduces the ungated decision, so
  /// the ungated `hasDownloadTarget` call site keeps the pre-#446 behavior.
  func test_bannerTarget_present_when_send_gate_not_presented() {
    let target = MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .modelMissing, message: "model missing"),
      profileDefaultModel: ProfileStore.defaultChatModelID,
      sendGatePresented: false)
    XCTAssertEqual(target?.repo, "Qwen/Qwen3-0.6B-GGUF")
    XCTAssertEqual(target?.file, "Qwen3-0.6B-Q8_0.gguf")
    // F3: the default-arg form (no sendGatePresented:) is the same single
    // entry point — ungated — not a separate arity overload.
    XCTAssertEqual(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .modelMissing, message: "model missing"),
      profileDefaultModel: ProfileStore.defaultChatModelID), target)
  }

  /// The sheet gate is the ONLY thing the argument adds: a non-modelMissing
  /// failure has no banner with or without the sheet (no false positive).
  func test_bannerTarget_gated_still_absent_for_non_modelMissing() {
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: .failed(code: .spawnFailed, message: "fork"),
      profileDefaultModel: ProfileStore.defaultChatModelID,
      sendGatePresented: false))
  }

  // MARK: - F1: gate honors the sheet's REAL download condition, not bare presentation

  /// `PromptAction.isDownload` — the predicate the call site ANDs with sheet
  /// presentation so the banner defers only when the sheet duplicates it.
  func test_promptAction_isDownload() {
    let slug = ProfileStore.defaultChatModelID
    XCTAssertTrue(MissingModelRecovery.promptAction(profileDefaultModel: slug, isInstalled: false).isDownload)
    XCTAssertFalse(MissingModelRecovery.promptAction(profileDefaultModel: slug, isInstalled: true).isDownload)   // .load
    XCTAssertFalse(MissingModelRecovery.promptAction(profileDefaultModel: nil, isInstalled: false).isDownload)   // .unavailable
  }

  /// F1 edge: a slug the gate reports installed (`isInstalled == true` → action
  /// `.load`) can still fail the engine with `.modelMissing` — e.g. a TOCTOU
  /// removal between the gate's existence check and the launch, or an artifact
  /// the launcher's deeper validation rejects. The sheet then shows Open
  /// Settings, NOT a download, so the banner is the only one-click download
  /// there and must NOT be suppressed even with the sheet open. Mirrors the
  /// call site's `showNoModelPrompt && noModelAction.isDownload` gate.
  func test_bannerTarget_not_suppressed_when_sheet_shows_settings_not_download() {
    let status = EngineStatus.failed(code: .modelMissing, message: "model file vanished after the gate check")
    let slug = ProfileStore.defaultChatModelID
    let action = MissingModelRecovery.promptAction(profileDefaultModel: slug, isInstalled: true)
    XCTAssertEqual(action, .load(slug), "installed-but-modelMissing edge: isInstalled true → .load")
    let sheetGate = true && action.isDownload   // the call site's expression
    XCTAssertNotNil(MissingModelRecovery.bannerTarget(
      engineStatus: status, profileDefaultModel: slug, sendGatePresented: sheetGate),
      "banner (one-click download) must stay when the sheet only offers Open Settings")
  }

  /// The common fresh-install edge (file genuinely absent → action
  /// `.download`): the sheet DOES duplicate the download, so an open sheet
  /// suppresses the banner — the single-download-surface intent holds.
  func test_bannerTarget_suppressed_when_sheet_shows_duplicate_download() {
    let status = EngineStatus.failed(code: .modelMissing, message: "absent")
    let slug = ProfileStore.defaultChatModelID
    let action = MissingModelRecovery.promptAction(profileDefaultModel: slug, isInstalled: false)
    XCTAssertTrue(action.isDownload)
    let sheetGate = true && action.isDownload
    XCTAssertNil(MissingModelRecovery.bannerTarget(
      engineStatus: status, profileDefaultModel: slug, sendGatePresented: sheetGate))
  }

  // MARK: - completedLatchShouldReset (PR#15 F1: re-failure → Retry)

  /// After a download completed (latched), the engine re-entering
  /// failed(modelMissing) means the start did not take (corrupt/partial
  /// artifact or a rejected path) — the CTA must drop its green latch and
  /// return to a Retry/Download affordance, not stay green forever.
  func test_completedLatchShouldReset_when_completed_and_modelMissing() {
    XCTAssertTrue(MissingModelRecovery.completedLatchShouldReset(
      didComplete: true,
      engineStatus: .failed(code: .modelMissing, message: "still missing")))
  }

  /// A successful start (or any non-failed/other-code state) must NOT
  /// reset the latch — the green "starting engine" is correct there.
  func test_completedLatchShouldReset_false_when_not_modelMissing_or_not_completed() {
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: true, engineStatus: .running(EngineSessionSnapshot(port: 8080, profileID: "chat"))))
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: true, engineStatus: .starting))
    // A different failure code is the F2 engine-failure banner's job, not
    // a download-retry — the download already succeeded.
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: true, engineStatus: .failed(code: .spawnFailed, message: "fork")))
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: false, engineStatus: .failed(code: .modelMissing, message: "x")))
  }

  // MARK: - engineActionFailureBannerMessage (chat-local action-error channel)

  /// Live engine-status failures are owned by the app-level unified status
  /// banner. The chat-local engine banner is reserved for distinct thrown
  /// action errors that the status poll may not reflect; otherwise the same
  /// failure copy appears both above the window and inside the chat.
  func test_engineActionFailureBannerMessage_nil_for_live_nonModelMissing_failure() {
    XCTAssertNil(
      MissingModelRecovery.engineActionFailureBannerMessage(
        engineStatus: .failed(code: .spawnFailed, message: "fork ENOENT"),
        actionError: nil))
  }

  /// modelMissing is owned by either the download banner or the app-level
  /// unified status banner, so the chat-local action banner stays silent for
  /// live failures even if an action error is also pending.
  func test_engineActionFailureBannerMessage_nil_for_modelMissing_failure() {
    XCTAssertNil(MissingModelRecovery.engineActionFailureBannerMessage(
      engineStatus: .failed(code: .modelMissing, message: "missing"),
      actionError: "boom"))
  }

  /// modelMissing for a NON-downloadable slug (2-seg safetensors dir, bare
  /// leaf, nil default whose snapshot was deleted) still belongs to the
  /// app-level unified status banner. It must not also render the chat-local
  /// engine banner.
  func test_engineActionFailureBannerMessage_nil_for_non_downloadable_modelMissing() {
    XCTAssertNil(
      MissingModelRecovery.engineActionFailureBannerMessage(
        engineStatus: .failed(code: .modelMissing, message: "missing"),
        actionError: nil))
  }

  /// Even if a thrown action error is pending, once the poll reports a live
  /// engine failure the app-level status banner owns the failure surface.
  /// Rendering the chat-local banner too duplicates the same recovery state.
  func test_engineActionFailureBannerMessage_nil_for_live_failure_even_with_action_error() {
    XCTAssertNil(
      MissingModelRecovery.engineActionFailureBannerMessage(
        engineStatus: .failed(code: .spawnFailed, message: "fork ENOENT"),
        actionError: "Couldn't start the engine: transport failed"))
  }

  /// A thrown engine-action error (e.g. a stop that left the engine
  /// .running, or a transport error) surfaces via the engine channel —
  /// NOT the persistence "Couldn't save" banner (F3).
  func test_engineActionFailureBannerMessage_surfaces_action_error_when_status_not_failed() {
    XCTAssertEqual(
      MissingModelRecovery.engineActionFailureBannerMessage(
        engineStatus: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")),
        actionError: "Couldn't stop the engine: kill rejected"),
      "Couldn't stop the engine: kill rejected")
  }

  /// Healthy engine, no action error → no banner.
  func test_engineActionFailureBannerMessage_nil_when_healthy() {
    XCTAssertNil(MissingModelRecovery.engineActionFailureBannerMessage(
      engineStatus: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")),
      actionError: nil))
  }

  // MARK: - engineFailureDismissable (PR#15 v2 F2)

  /// A live `.failed` status re-derives the banner every render, so its
  /// message is NOT dismissable — the Dismiss button would be a no-op and
  /// must be hidden.
  func test_engineFailureDismissable_false_for_failed_status() {
    XCTAssertFalse(MissingModelRecovery.engineFailureDismissable(
      engineStatus: .failed(code: .spawnFailed, message: "fork")))
    XCTAssertFalse(MissingModelRecovery.engineFailureDismissable(
      engineStatus: .failed(code: .modelMissing, message: "missing")))
  }

  /// A thrown action-error banner (status not `.failed`) IS dismissable —
  /// clearing `engineActionError` removes it.
  func test_engineFailureDismissable_true_when_status_not_failed() {
    XCTAssertTrue(MissingModelRecovery.engineFailureDismissable(
      engineStatus: .running(EngineSessionSnapshot(port: 8080, profileID: "chat"))))
    XCTAssertTrue(MissingModelRecovery.engineFailureDismissable(engineStatus: .stopped))
  }
}
