import Foundation

/// Pure decision for the chat send GATE — the surface that today is the
/// "No model loaded" prompt (`NoModelLoadedPrompt`). This is NOT a
/// rendered status indicator: the in-app model-load ring
/// (`ModelLoadCenter` axis) and the menu-bar engine dot (`EngineStatus`
/// axis) remain separate surfaces. `ChatStartGate` folds BOTH axes plus
/// the resolved `ModelTarget` (the chat's pinned selection, else the
/// active profile's default — #497) ONLY to decide what a *blocked send*
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
    /// Engine is `.starting` — an explicit start request, a model-switch
    /// restart, or crash auto-relaunch is bringing the engine (and, for v1's
    /// load-at-boot pie, its model) up.
    case startingEngine
    /// Engine is `.stopping` — transient; resolves to `.stopped` shortly.
    case stoppingEngine
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
    /// A launch target resolves (the chat's pinned selection, else the
    /// profile's default — `ModelTarget`) but is not loaded yet. Primary
    /// action = Load (which first ensures the engine is running). Framed
    /// benignly: "not loaded yet", never "no model". #497: carries the
    /// full target so the prompt can frame a pinned selection honestly —
    /// no surface re-derives (and drifts back to) the profile default.
    case needsLoad(target: ModelTarget)
    /// The active profile has no default model. The only genuine
    /// "choose a model first" case. Offer Choose / Open Models settings.
    case noDefault
    /// The engine reported `.failed`. Carries the raw status diagnostic
    /// as `reason`; the rendered copy AND the recovery affordance both
    /// derive from `EngineProblem(statusCode:rawMessage:)` at the
    /// presentation layer (#477) — the gate adds no parallel
    /// retryability axis.
    case engineFailed(code: EngineErrorCode, reason: String)
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
  ///   - resolvedModelID: the send target the app already computes after
  ///     desired-vs-resident preflight (`EngineRequestSync`). Non-nil means
  ///     the app target and helper resident model match, so a send can
  ///     proceed and the gate is not shown.
  ///   - residentModelID: helper-observed resident model id. Kept on the
  ///     reducer boundary so tests pin the app/helper synchronization
  ///     contract directly; callers should pass the same resident state used
  ///     to derive `resolvedModelID`.
  ///   - target: the launch/load target — the single
  ///     `ModelTarget.resolve(selectedModelID:profileDefault:)` derivation
  ///     (#497, the chat's pin else the profile default). Nil when
  ///     neither exists.
  ///   - profileError: a structural problem with the active-profile
  ///     selection (unreadable marker / unparsable profile), if any.
  public static func evaluate(
    engineStatus: EngineStatus,
    helperError: String?,
    resolvedModelID: String?,
    residentModelID: String? = nil,
    target: ModelTarget?,
    profileError: String? = nil
  ) -> State {
    // Helper transport down: the polled status is stale/placeholder, so
    // surface the reachability failure rather than misreading it as
    // `.stopped`/`.starting`.
    if let helperError, !helperError.isEmpty {
      return .helperUnreachable(reason: helperError)
    }

    switch engineStatus {
    case .failed(let code, let message):
      return .engineFailed(code: code, reason: message)
    case .stopping:
      return .busy(.stoppingEngine)
    case .starting:
      // Engine coming up via launch prompt/user-confirm, explicit Restart,
      // Local API, post-download startEngine, or crash auto-relaunch. v1 pie
      // loads the model at `pie serve` boot, so "starting" already implies
      // the default is on its way — wait, don't offer a redundant Load.
      return .busy(.startingEngine)
    case .running:
      if let id = resolvedModelID,
         !id.isEmpty,
         residentModelID == id {
        return .ready(modelID: id)
      }
      return targetOrNo(target: target, profileError: profileError)
    case .stopped:
      return targetOrNo(target: target, profileError: profileError)
    }
  }

  // MARK: - per-engine-state resolution

  /// Shared tail: broken profile config beats a resolved target beats
  /// the genuine no-target state.
  private static func targetOrNo(target: ModelTarget?, profileError: String?) -> State {
    if let err = profileError, !err.isEmpty {
      return .configBroken(reason: err)
    }
    if let target {
      return .needsLoad(target: target)
    }
    return .noDefault
  }
}
