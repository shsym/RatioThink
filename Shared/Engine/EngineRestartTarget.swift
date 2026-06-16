import Foundation

/// Which model an App-initiated engine restart should boot — so a restart
/// preserves the identity of the session the user is looking at instead of
/// silently reverting to the profile default.
///
/// #668: the App restart entry points ("Restart Engine" menu item,
/// engine-fault banner Retry) used to call `startEngine(profileID:)` with no
/// `modelOverride`, so `LaunchSpecResolver.effectiveModel` fell back to
/// `profile.model`. When the running session served a non-default pick (a
/// per-chat model selection, a Local API model switch), the restart booted a
/// DIFFERENT model than the one on screen — the "retrying engine start loads a
/// model with a different name than expected" symptom. (The served id itself is
/// already single-sourced: `PieControlLauncher` writes `servedModelID` verbatim
/// as the engine's `[[model]].name`, so `/v1/models` and the snapshot never
/// disagree on the string — the divergence is purely which model a restart
/// chooses to boot.)
///
/// The single source of the running session's served identity is the
/// `EngineSessionSnapshot` (#476). While the engine is `.running` that snapshot
/// carries the live `servedModelID`. After a crash/fault the snapshot is gone,
/// so we fall back to the durable active-model marker
/// (`ProfileStore.activeModelID`, written by `LaunchSpecResolver` on every
/// launch — the same record the Helper-side Resume / auto-relaunch already
/// honor). Only when neither is known does `nil` let the resolver boot
/// `profile.model`, exactly the prior behavior for a never-started engine.
///
/// ProfileEditor's change-the-default restart intentionally does NOT use this:
/// it must boot the freshly-edited `profile.model`, so its `nil` override is
/// unchanged.
public enum EngineRestartTarget {
  /// The model id to pass as `modelOverride` for an App-initiated restart, or
  /// `nil` to defer to `profile.model`. Precedence: running snapshot's
  /// `servedModelID` → durable last-served marker → `nil`. Blank/whitespace ids
  /// count as absent (same trim the launch resolver applies).
  public static func bootModel(currentSnapshot: EngineSessionSnapshot?,
                               lastServedModelID: String?) -> String? {
    if let served = currentSnapshot?.servedModelID,
       !served.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return served
    }
    if let marker = lastServedModelID,
       !marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return marker
    }
    return nil
  }
}
