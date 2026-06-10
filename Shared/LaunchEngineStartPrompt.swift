import Foundation

/// #4: the App ALWAYS asks before starting the engine/model on launch —
/// it never silently auto-starts. Helper boot leaves the engine stopped;
/// see `HelperMain.autoResumeEngineOnBoot`. This is the pure decision for
/// whether, once the engine status has SETTLED after launch,
/// the App should proactively raise the "Start <model>?" prompt.
///
/// The caller closes the launch window after the first settled status
/// (skipping the initial `.starting` placeholder) and evaluates this
/// once, so a later mid-session stop (e.g. the user unloads) never
/// re-pops the launch prompt — this only decides the launch case.
///
/// Pure + value-only so the "ask iff idle-with-a-target" rule is
/// unit-tested in the fast SPM tier without a view host.
///
/// NOTE: this is the BOOT model-load gate only. The engine-CRASH
/// auto-relaunch ladder (`PieEngineHost.RelaunchPolicy`) is a separate,
/// automatic mechanism and is unaffected.
public enum LaunchEngineStartPrompt {
  /// Ask to start ONLY when the engine is idle (`.stopped`) and a launch
  /// target resolves (the chat's pinned model, else the profile default). Every other settled
  /// status is handled elsewhere: `.running` is already up, `.failed`
  /// surfaces its own recoverable error, and a missing default routes to
  /// the normal no-default gate. (`.starting`/`.stopping` are transient —
  /// the caller waits for a settled status before evaluating.)
  /// #497: keyed on the resolved `ModelTarget` (the chat's pin, else the
  /// profile default) — the same model the prompt's Load tap will boot —
  /// so the launch ask can never diverge from the boot path.
  public static func shouldAsk(status: EngineStatus, target: ModelTarget?) -> Bool {
    guard case .stopped = status else { return false }
    return target != nil
  }
}
