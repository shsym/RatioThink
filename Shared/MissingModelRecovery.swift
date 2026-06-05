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

    /// Whether this action is the inline download — i.e. the send-gate sheet
    /// renders the same Download the banner does. The banner-gate keys on
    /// this (not bare sheet presentation) so it only defers when the sheet
    /// actually duplicates the download (review F1).
    public var isDownload: Bool {
      if case .download = self { return true }
      return false
    }
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

  /// Download target the in-chat `ModelMissingBanner` should show, or nil
  /// when the banner must stay hidden.
  ///
  /// Non-nil ONLY when the engine failed *specifically* because the model is
  /// missing AND the active profile's default resolves to a single-file GGUF
  /// download. A `.memoryRisk` / `.spawnFailed` failure is a different problem
  /// (model present but too large, binary broken) and must not be papered over
  /// with a download prompt.
  ///
  /// #446 `sendGatePresented`: the banner and the send-gate sheet
  /// (`NoModelLoadedPrompt`) can BOTH recover a missing-but-downloadable
  /// default with an inline Download — two prompts for one recovery. When the
  /// caller knows the sheet is presented AND is itself showing that download,
  /// pass `true` so the banner defers (the modal, user-initiated sheet owns
  /// the recovery); the banner re-takes the surface when the sheet closes.
  /// The caller must gate on the sheet's REAL download condition, not bare
  /// presentation — if the sheet shows Open Settings (a non-`.download`
  /// action, e.g. a present-but-invalid staged model) it does NOT duplicate
  /// the banner, so the banner must stay (review F1). Defaulting to `false`
  /// keeps this the single `bannerTarget` entry point: an ungated caller (the
  /// fault-routing `hasDownloadTarget` check) omits the argument and gets the
  /// pre-#446 behavior, while the gate is opt-in by name — no arity-only
  /// overload that a dropped argument could silently rebind to (review F3).
  public static func bannerTarget(engineStatus: EngineStatus,
                                  profileDefaultModel: String?,
                                  sendGatePresented: Bool = false) -> ModelDownloadTarget? {
    guard !sendGatePresented else { return nil }
    guard case .failed(.modelMissing, _) = engineStatus else { return nil }
    guard let slug = profileDefaultModel else { return nil }
    return CuratedModelCatalog.downloadTarget(forModelSlug: slug)
  }

  /// Whether the download CTA's completed ("starting engine…") latch
  /// should drop back to a Retry/Download affordance.
  ///
  /// True only when a download has completed (`didComplete`) AND the
  /// engine is back in `failed(.modelMissing)` — i.e. the post-download
  /// `startEngine` did not take (corrupt/partial artifact, or a path the
  /// resolver still rejects). Leaving the green latch up with no retry is
  /// the exact silent dead-end #326 exists to kill. A `.running` (or any
  /// other) state keeps the latch; a *different* failure code is the
  /// generic engine-failure banner's job (the download itself succeeded).
  public static func completedLatchShouldReset(didComplete: Bool,
                                               engineStatus: EngineStatus) -> Bool {
    guard didComplete else { return false }
    if case .failed(.modelMissing, _) = engineStatus { return true }
    return false
  }

  /// Message for the generic in-chat engine-failure banner, or nil when
  /// it should stay hidden. The single engine-failure channel (PR#15
  /// F2/F3): a user-initiated start/stop that fails must surface IN-CHAT,
  /// not only on the menu-bar dot and never under the persistence
  /// "Couldn't save" banner (wrong fault domain).
  ///
  ///   · `.failed(.modelMissing)` → nil ONLY when `hasDownloadTarget`
  ///     (the download banner owns that surface). For a NON-downloadable
  ///     modelMissing slug (2-seg safetensors dir, bare leaf, non-`.gguf`,
  ///     or a default whose snapshot was deleted) NO download banner
  ///     exists, so it falls through to `statusDetail` here — otherwise it
  ///     would be the menu-bar-dot-only state this channel exists to kill
  ///     (PR#15 v2 F1).
  ///   · `.failed(otherCode)` → the live `statusDetail` (e.g. spawnFailed,
  ///     handshakeTimeout, engineGone).
  ///   · otherwise → a pending thrown `actionError` (a stop that left the
  ///     engine running, or a transport error the poll won't reflect).
  public static func engineFailureBannerMessage(engineStatus: EngineStatus,
                                                actionError: String?,
                                                statusDetail: String,
                                                hasDownloadTarget: Bool) -> String? {
    if case .failed(let code, _) = engineStatus {
      if code == .modelMissing, hasDownloadTarget { return nil }
      return statusDetail
    }
    return actionError
  }

  /// Whether the engine-failure banner's message is dismissable (PR#15 v2
  /// F2). A live `.failed` status re-derives the message every render, so
  /// a Dismiss there clears nothing visible — hide the button. Only a
  /// thrown `actionError` (surfaced when the status is NOT `.failed`) can
  /// be dismissed by clearing it.
  public static func engineFailureDismissable(engineStatus: EngineStatus) -> Bool {
    if case .failed = engineStatus { return false }
    return true
  }
}
