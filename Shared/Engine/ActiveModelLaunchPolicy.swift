import Foundation

/// Pure decision for "the user picked model X — how do we make the engine
/// SERVE it?" (#469).
///
/// v1 pie binds the served model at `pie serve` boot (the WIT `model::load`
/// import is a registry lookup, not a swap — see `chat-apc` `control/load.rs`
/// and `LaunchSpecResolver.resolveLauncherSpec`). So changing the served model
/// is an engine LIFECYCLE event, not a `/v1/models/load` call:
///   · engine stopped/failed-retryable → START it bound to the pick,
///   · engine running a DIFFERENT model → RESTART it bound to the pick,
///   · engine already serving the pick → nothing to (re)launch,
///   · engine starting/stopping → in flight, defer to the live state.
///
/// The pre-#469 pick path routed every selection through
/// `engine.loadModel` (POST `/v1/models/load`), which no-ops against a
/// stopped engine (so a pick never started it) and only acks the boot model
/// on a running one (so a different pick was never served). This policy maps
/// the pick to the correct lifecycle action instead; the caller executes it
/// via `EngineStatusStore.startEngine(modelOverride:)` /
/// `restartEngine(modelOverride:)`.
///
/// Pure over its three inputs so the routing is unit-tested without standing
/// up an engine, a helper, or a SwiftUI host.
public enum ActiveModelLaunchPolicy {
  /// The lifecycle action a served-model-changing pick maps to.
  public enum Decision: Equatable {
    /// Engine is down — start it bound to this model (`startEngine`).
    case startEngine(modelOverride: String)
    /// Engine is up serving a different model — rebuild it bound to this
    /// model (`restartEngine`); a live `/v1/models/load` could not swap it.
    case restartEngine(modelOverride: String)
    /// Engine already serves this exact model — no (re)launch needed.
    case alreadyResident
    /// Engine is mid-transition (`.starting` / `.stopping`) — the in-flight
    /// launch already reflects a target; do not pile a second one on.
    case deferBusy
    /// Engine is in a terminal failure that a fresh start cannot clear
    /// (`memoryRisk` / `killRejected`). The failure banner owns the reason;
    /// a pick must not re-fire a guaranteed-to-fail start.
    case blockedTerminal
  }

  /// Map a model pick to the engine action that actually serves it.
  ///
  /// - Parameters:
  ///   - modelID: the slug the user picked.
  ///   - status: the live engine status.
  ///   - residentModelID: the model the engine currently serves (from
  ///     `ModelLoadCenter.residentModelID`), or `nil` when nothing is
  ///     resident. Compared against `modelID` to detect the no-op pick —
  ///     deliberately the ACTUAL resident, not a pending per-chat override.
  public static func decide(modelID: String,
                            status: EngineStatus,
                            residentModelID: String?) -> Decision {
    switch status {
    case .stopped:
      return .startEngine(modelOverride: modelID)
    case .failed(let code, _):
      // Mirror `ChatScaffoldView.loadDefaultModel`: only a retryable failure
      // (engineGone / spawnFailed / modelMissing) invites a fresh start; a
      // terminal one (memoryRisk / killRejected) would loop on a guaranteed
      // refusal, so the banner keeps the reason and the pick is inert.
      return code.invitesResumeRetry ? .startEngine(modelOverride: modelID)
                                      : .blockedTerminal
    case .running:
      if let residentModelID, residentModelID == modelID {
        return .alreadyResident
      }
      return .restartEngine(modelOverride: modelID)
    case .starting, .stopping:
      return .deferBusy
    }
  }
}
