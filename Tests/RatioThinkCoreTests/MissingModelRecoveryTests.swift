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
                                 .running(port: 8080, profileID: "chat")] {
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
      didComplete: true, engineStatus: .running(port: 8080, profileID: "chat")))
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: true, engineStatus: .starting))
    // A different failure code is the F2 engine-failure banner's job, not
    // a download-retry — the download already succeeded.
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: true, engineStatus: .failed(code: .spawnFailed, message: "fork")))
    XCTAssertFalse(MissingModelRecovery.completedLatchShouldReset(
      didComplete: false, engineStatus: .failed(code: .modelMissing, message: "x")))
  }

  // MARK: - engineFailureBannerMessage (PR#15 F2/F3: one engine-failure channel)

  /// A non-modelMissing engine failure surfaces the live status detail —
  /// the user just acted (download → start), so the failure can't be
  /// menu-bar-dot-only (F2).
  func test_engineFailureBannerMessage_uses_status_detail_for_non_modelMissing_failure() {
    XCTAssertEqual(
      MissingModelRecovery.engineFailureBannerMessage(
        engineStatus: .failed(code: .spawnFailed, message: "fork ENOENT"),
        actionError: nil,
        statusDetail: "Engine failed (spawnFailed): fork ENOENT",
        hasDownloadTarget: false),
      "Engine failed (spawnFailed): fork ENOENT")
  }

  /// modelMissing WITH a download target is owned by the download banner,
  /// so the generic engine-failure banner stays silent for it (even if an
  /// action error is also pending).
  func test_engineFailureBannerMessage_nil_for_modelMissing_with_download_target() {
    XCTAssertNil(MissingModelRecovery.engineFailureBannerMessage(
      engineStatus: .failed(code: .modelMissing, message: "missing"),
      actionError: "boom",
      statusDetail: "Engine failed (modelMissing): missing",
      hasDownloadTarget: true))
  }

  /// PR#15 v2 F1: modelMissing for a NON-downloadable slug (2-seg
  /// safetensors dir, bare leaf, nil default whose snapshot was deleted)
  /// has no download banner to own it — so the engine-failure banner must
  /// cover it, never leaving it menu-bar-dot-only. This is the boundary
  /// the blanket modelMissing suppression slipped through.
  func test_engineFailureBannerMessage_surfaces_non_downloadable_modelMissing() {
    XCTAssertEqual(
      MissingModelRecovery.engineFailureBannerMessage(
        engineStatus: .failed(code: .modelMissing, message: "missing"),
        actionError: nil,
        statusDetail: "Engine failed (modelMissing): missing",
        hasDownloadTarget: false),
      "Engine failed (modelMissing): missing")
  }

  /// A thrown engine-action error (e.g. a stop that left the engine
  /// .running, or a transport error) surfaces via the engine channel —
  /// NOT the persistence "Couldn't save" banner (F3).
  func test_engineFailureBannerMessage_surfaces_action_error_when_status_not_failed() {
    XCTAssertEqual(
      MissingModelRecovery.engineFailureBannerMessage(
        engineStatus: .running(port: 8080, profileID: "chat"),
        actionError: "Couldn't stop the engine: kill rejected",
        statusDetail: "Engine running",
        hasDownloadTarget: false),
      "Couldn't stop the engine: kill rejected")
  }

  /// Healthy engine, no action error → no banner.
  func test_engineFailureBannerMessage_nil_when_healthy() {
    XCTAssertNil(MissingModelRecovery.engineFailureBannerMessage(
      engineStatus: .running(port: 8080, profileID: "chat"),
      actionError: nil,
      statusDetail: "Engine running",
      hasDownloadTarget: false))
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
      engineStatus: .running(port: 8080, profileID: "chat")))
    XCTAssertTrue(MissingModelRecovery.engineFailureDismissable(engineStatus: .stopped))
  }
}
