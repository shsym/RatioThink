import Foundation

/// Pure decision for the chat send GATE — the surface that today is the
/// "No model loaded" prompt (`NoModelLoadedPrompt`). This is NOT a
/// rendered status indicator: the in-app model-load ring
/// (`ModelLoadCenter` axis) and the menu-bar engine dot (`EngineStatus`
/// axis) remain separate surfaces. `ChatStartGate` folds BOTH axes plus
/// the active profile's default ONLY to decide what a *blocked send*
/// should tell the user and what action to offer next.
///
/// #397 — removes the state conflation. The prior gate fired off
/// `currentModelID() == nil` ALONE and always rendered the error-framed
/// "No model loaded / Load / Choose another", blind to whether the
/// engine was still starting, had failed, or the default was simply
/// not loaded yet. That made the common post-launch case ("engine not
/// up yet, default exists") read as a problem instead of the benign
/// "this profile's default (XYZ) isn't loaded yet — load it?".
///
/// Pure + value-only inputs so the whole matrix is unit-testable in the
/// fast `RatioThinkCoreTests` (SPM) tier without standing up an engine,
/// XPC, or SwiftUI.
public enum ChatStartGate {

  /// Why a send is gated in a wait state. Distinct from `.engineFailed`
  /// / `.loadFailed` so the prompt shows a calm "starting/loading…"
  /// affordance (no conflicting Load/Choose buttons that would
  /// double-trigger) rather than an actionable error.
  public enum BusyPhase: Equatable, Sendable {
    /// Engine is `.starting` — an explicit start request or crash auto-relaunch is
    /// bringing the engine (and, for v1's load-at-boot pie, its model) up.
    case startingEngine
    /// Engine is `.stopping` — transient; resolves to `.stopped` shortly.
    case stoppingEngine
    /// A model load is in flight (engine running, `/v1/models/load`).
    case loadingModel(modelID: String)
  }

  /// What the blocked send resolves to. `ready` means the gate is NOT
  /// shown (a model resolves and the send proceeds); every other case
  /// is a distinct prompt state with its own copy + actions.
  public enum State: Equatable, Sendable {
    /// A model resolves (per-chat override, resident, or the test-env
    /// override). Send proceeds; the gate is not raised.
    case ready(modelID: String)
    /// Engine or model is busy — show a wait state, gate the send, do
    /// NOT offer a Load/Choose action that would conflict.
    case busy(BusyPhase)
    /// A default model is configured for the active profile but is not
    /// loaded yet. Primary action = Load (which first ensures the engine
    /// is running). Framed benignly: "not loaded yet", never "no model".
    case needsDefaultLoad(modelID: String)
    /// The active profile has no default model. The only genuine
    /// "choose a model first" case. Offer Choose / Open Models settings.
    case noDefault
    /// The engine reported `.failed`. Name the underlying reason; offer
    /// Retry when the code invites one (see
    /// `EngineErrorCode.invitesResumeRetry`) and route model-choice
    /// faults (missing / too-large / profile) to Models settings.
    case engineFailed(code: EngineErrorCode, reason: String, retryable: Bool)
    /// A model load against a running engine failed. Offer Retry (re-run
    /// the load) plus the reason.
    case loadFailed(modelID: String, reason: String)
    /// The engine helper is unreachable over XPC (transport down) —
    /// distinct from a clean `.stopped` engine. Offer Retry + reason.
    case helperUnreachable(reason: String)
    /// The active-profile selection or its profile file is broken
    /// (unreadable marker, unparsable TOML). Point at Settings.
    case configBroken(reason: String)
  }

  /// Fold the live facts into a single gate state.
  ///
  /// - Parameters:
  ///   - engineStatus: the helper's last reported `EngineStatus`
  ///     (`EngineStatusStore.status`).
  ///   - helperError: `EngineStatusStore.lastError` — non-nil when the
  ///     `engineStatus()` XPC poll itself failed (helper transport down).
  ///     Takes priority over `engineStatus` because a failed poll leaves
  ///     a stale/placeholder status that must not be read as truth.
  ///   - load: the app-side `ModelLoadCenter.State`.
  ///   - resolvedModelID: the send target the app already computes
  ///     (`override ?? resident ?? PIE_TEST_CHAT_MODEL`). Non-nil ⇒ a
  ///     send can proceed and the gate is not shown.
  ///   - profileDefault: the active profile's default model slug, or nil
  ///     when the profile carries no default.
  ///   - profileError: a structural problem with the active-profile
  ///     selection (unreadable marker / unparsable profile), if any.
  public static func evaluate(
    engineStatus: EngineStatus,
    helperError: String?,
    load: ModelLoadCenter.State,
    resolvedModelID: String?,
    profileDefault: String?,
    profileError: String? = nil
  ) -> State {
    // A resolvable model wins outright — this is the send-proceeds path
    // and matches `ChatScaffoldView.requestModelID` precedence.
    if let id = resolvedModelID, !id.isEmpty {
      return .ready(modelID: id)
    }

    // Helper transport down: the polled status is stale/placeholder, so
    // surface the reachability failure rather than misreading it as
    // `.stopped`/`.starting`.
    if let helperError, !helperError.isEmpty {
      return .helperUnreachable(reason: helperError)
    }

    switch engineStatus {
    case .failed(let code, let message):
      return .engineFailed(code: code, reason: message, retryable: code.invitesResumeRetry)
    case .stopping:
      return .busy(.stoppingEngine)
    case .starting:
      // Engine coming up via launch prompt/user-confirm, explicit Restart,
      // Local API, post-download startEngine, or crash auto-relaunch. v1 pie
      // loads the model at `pie serve` boot, so "starting" already implies
      // the default is on its way — wait, don't offer a redundant Load.
      return .busy(.startingEngine)
    case .running:
      return runningState(load: load, profileDefault: profileDefault, profileError: profileError)
    case .stopped:
      return stoppedState(load: load, profileDefault: profileDefault, profileError: profileError)
    }
  }

  // MARK: - per-engine-state resolution

  /// Engine `.running` but nothing resolved yet. A model load may be in
  /// flight or terminal; otherwise the default can be loaded now
  /// (`/v1/models/load` against the live engine).
  private static func runningState(
    load: ModelLoadCenter.State,
    profileDefault: String?,
    profileError: String?
  ) -> State {
    switch load {
    case let .loading(id, _, _, _):
      return .busy(.loadingModel(modelID: id))
    case let .failed(id, message):
      return .loadFailed(modelID: id, reason: message)
    case .engineNotReady:
      // The load deferred on a not-yet-running engine; status has since
      // flipped to `.running`. Treat as still-coming-up; a reconcile or
      // retry resolves it. Calmer than a failure.
      return .busy(.startingEngine)
    case .idle, .ready, .cancelled:
      // `.ready` with no resolved id shouldn't occur (resident would be
      // set → resolvedModelID non-nil), but fall through safely.
      return defaultOrNo(profileDefault: profileDefault, profileError: profileError)
    }
  }

  /// Engine `.stopped`. A terminal load state still routes to its
  /// reason; otherwise offer the default (Load will START the engine
  /// first), or report no-default / broken-config.
  private static func stoppedState(
    load: ModelLoadCenter.State,
    profileDefault: String?,
    profileError: String?
  ) -> State {
    switch load {
    case let .loading(id, _, _, _):
      return .busy(.loadingModel(modelID: id))
    case let .failed(id, message):
      return .loadFailed(modelID: id, reason: message)
    case .idle, .ready, .cancelled, .engineNotReady:
      return defaultOrNo(profileDefault: profileDefault, profileError: profileError)
    }
  }

  /// Shared tail: broken profile config beats a present default beats
  /// the genuine no-default state.
  private static func defaultOrNo(profileDefault: String?, profileError: String?) -> State {
    if let err = profileError, !err.isEmpty {
      return .configBroken(reason: err)
    }
    if let model = profileDefault, !model.isEmpty {
      return .needsDefaultLoad(modelID: model)
    }
    return .noDefault
  }
}
