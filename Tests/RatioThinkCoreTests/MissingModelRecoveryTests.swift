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
}
