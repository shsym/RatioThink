import Foundation

/// Pure decision logic for #326's fresh-install model-download UX,
/// shared by the two surfaces that recover a missing model:
///   · `NoModelLoadedPrompt` — the send-blocked "no model loaded" sheet.
///   · `ModelMissingBanner` — the in-chat banner shown when the engine
///     failed to start because its model is not on disk.
///
/// Both decisions are pure functions of (slug, install/engine state) so
/// the Load-vs-Download-vs-unavailable branching is unit-tested without
/// a view hierarchy or a live engine. The SwiftUI views stay thin glue
/// over these.
public enum MissingModelRecovery {

  /// What the no-model send prompt should offer for the active profile's
  /// default model.
  public enum PromptAction: Equatable {
    /// Model is already on disk — load it (the pre-#326 behavior).
    case load(String)
    /// Model is not on disk but resolves to a single downloadable GGUF.
    case download(ModelDownloadTarget)
    /// No default model, or a not-installed model that is not a
    /// single-file GGUF download — the UI points the user at the
    /// toolbar / Settings → Models instead of offering a broken action.
    case unavailable
  }

  /// Decide the prompt action. `isInstalled` is the caller's filesystem
  /// check for the slug's app-staged path (the engine's primary model
  /// source).
  public static func promptAction(profileDefaultModel: String?,
                                  isInstalled: Bool) -> PromptAction {
    guard let slug = profileDefaultModel,
          !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unavailable
    }
    if isInstalled { return .load(slug) }
    if let target = CuratedModelCatalog.downloadTarget(forModelSlug: slug) {
      return .download(target)
    }
    return .unavailable
  }

  /// Download target for the failed(modelMissing) banner, or nil when
  /// the banner must stay hidden.
  ///
  /// Non-nil ONLY when the engine failed *specifically* because the
  /// model is missing AND the active profile's default resolves to a
  /// single-file GGUF download. A `.memoryRisk` / `.spawnFailed` failure
  /// is a different problem (model present but too large, binary broken)
  /// and must not be papered over with a download prompt.
  public static func bannerTarget(engineStatus: EngineStatus,
                                  profileDefaultModel: String?) -> ModelDownloadTarget? {
    guard case .failed(.modelMissing, _) = engineStatus else { return nil }
    guard let slug = profileDefaultModel else { return nil }
    return CuratedModelCatalog.downloadTarget(forModelSlug: slug)
  }
}
