import Foundation

/// Pure-Swift policy half of the menu-bar Resume action. Extracted
/// from `HelperAppDelegate.togglePauseResume(_:)` (Helper target, not
/// SPM-reachable) so `RatioThinkCoreTests` can exercise the resolve-and-
/// start sequence without spinning up AppKit / NSStatusBar.
///
/// HelperMain owns the AppKit half (button representedObject parsing,
/// log lines) and forwards into `HelperResumeAction.run(...)` for the
/// decision. Returned `Outcome` lets the caller log the exact failure
/// reason and lets the test bundle assert against discrete cases
/// instead of grepping log strings.
public enum HelperResumeAction {
  /// One per discrete branch the Resume policy can take. Carried as
  /// values (not just booleans) so the helper log line carries the
  /// underlying cause without re-deriving it.
  public enum Outcome: Equatable, CustomStringConvertible {
    /// Healthy path — `engineHost.start(spec)` returned `.success`.
    case started(profileID: String)
    /// Degraded boot or pre-listener race — no engine host wired.
    case supervisorMissing
    /// Degraded boot or test-mode skip — no ProfileStore.
    case profileStoreMissing
    /// LaunchSpecResolver not wired (DEBUG smoke path with no
    /// PIE_SMOKE_FAKE_ENGINE_BIN, test mode without explicit wiring).
    case resolverMissing
    /// ProfileStore has no `activeProfileID` — the user has not
    /// picked one yet. Distinct from `.activeProfileUnreadable`
    /// (broken marker) so operator logs distinguish the two.
    ///
    /// `afterRetry == true` means the F3 retry path ran (marker WAS
    /// broken), the retry healed the error, AND the post-retry id
    /// is still nil — the operator's repair was to delete the
    /// marker rather than write a valid id. Pre-v6 this case
    /// collapsed into the same log arm as "user never picked one",
    /// losing the breadcrumb that the retry attempt fired (review
    /// v6 F3). The principle from v5 F2 — "tried again, still X"
    /// is a distinct outcome from "first-look X" — now applies
    /// symmetrically to both X=broken AND X=absent.
    case noActiveProfile(afterRetry: Bool)
    /// The on-disk active-profile marker is present but unreadable
    /// (permission denied, directory at the path, decode failure).
    /// Carries the underlying `ProfileStoreError.activeProfileReadFailed`
    /// so the helper log line names the precise cause. Review v3 F1:
    /// the prior code collapsed this into `.noActiveProfile`, so
    /// helper.log could not tell never-selected from perms-denied.
    case activeProfileUnreadable(ProfileStoreError)
    /// Marker was previously broken (we observed `lastActiveProfileError`),
    /// the F3 user-Resume retry path called `reloadActiveProfile()`, and
    /// the post-retry snapshot is STILL broken. Distinct from
    /// `.activeProfileUnreadable` so helper.log distinguishes
    /// "tried again, still broken" from "first-look broken" (review
    /// v5 F2: the prior collapsed code path made both outcomes
    /// bit-identical in logs).
    case activeProfileUnreadableAfterRetry(ProfileStoreError)
    /// `LaunchSpecResolver` rejected the active profile id — surfaces
    /// `.profileMissing` (id drift between store + resolver) or
    /// `.spawnFailed` (binary lookup throw, etc.).
    case resolverFailed(EngineError)
    /// `PieEngineHost.start` rejected the spec (e.g. `.alreadyRunning`
    /// race against an external XPC `startEngine` call).
    case startRejected(EngineError)

    public var description: String {
      switch self {
      case .started(let id):          return "started(profileID=\(id))"
      case .supervisorMissing:        return "supervisorMissing"
      case .profileStoreMissing:      return "profileStoreMissing"
      case .resolverMissing:          return "resolverMissing"
      case .noActiveProfile(let afterRetry):
        return "noActiveProfile(afterRetry=\(afterRetry))"
      case .activeProfileUnreadable(let e):
        return "activeProfileUnreadable(\(e))"
      case .activeProfileUnreadableAfterRetry(let e):
        return "activeProfileUnreadableAfterRetry(\(e))"
      case .resolverFailed(let e):    return "resolverFailed(\(e.code.rawValue): \(e.message))"
      case .startRejected(let e):     return "startRejected(\(e.code.rawValue): \(e.message))"
      }
    }
  }

  /// Resolve the active profile and ask the supervisor to start it.
  /// In-process — no XPC round-trip; the menu-bar action lives in the
  /// helper itself, so the supervisor reference is directly usable.
  ///
  /// Two-step lookup (review cycle 149/150 F2):
  ///   1. Read `store.activeProfileID`. Nil → `.noActiveProfile` —
  ///      the user has not picked one yet.
  ///   2. Hand the id to `resolver(id)`. A missing/failed-to-parse
  ///      entry surfaces as `.resolverFailed(.profileMissing)` so
  ///      the caller distinguishes "nothing selected" from "selected
  ///      id is stale" (the prior single-step
  ///      `store.activeProfile != nil` check collapsed both).
  ///
  /// Idempotent against the supervisor's own
  /// `.starting`/`.running`/`.stopping` rejection (returned as
  /// `.startRejected(.alreadyRunning)`); the policy here does NOT
  /// pre-check status so the supervisor stays the single source of
  /// truth for "is one already in flight".
  public static func run(
    engineHost: PieEngineHost?,
    profileStore: ProfileStore?,
    resolver: HelperExportedAPI.LaunchSpecResolver?
  ) -> Outcome {
    guard let engineHost else { return .supervisorMissing }
    guard let store = profileStore else { return .profileStoreMissing }
    guard let resolver else { return .resolverMissing }
    // User-initiated Resume is the natural retry affordance for a
    // previously-broken marker (review v4 F3). If the store is
    // currently carrying `_activeProfileError`, force an authoritative
    // reload BEFORE consulting `activeProfileID` so an operator who
    // repaired perms / removed a planted directory sees the click
    // resolve into a real start instead of bouncing off
    // `.activeProfileUnreadable` until helper restart.
    //
    // Observability (review v5 F2): log the retry attempt at
    // `.notice` and the still-broken outcome at `.error` so
    // helper.log distinguishes "no retry, marker was already clean"
    // from "retried, still broken" — bit-identical in the v4
    // implementation. The post-retry snapshot is the authoritative
    // truth (review v5 F5): we read from it directly instead of
    // re-polling `lastActiveProfileError`, which would race against
    // a concurrent FS event between the two reads.
    if store.lastActiveProfileError != nil {
      Log.helper.notice("HelperResumeAction: active-profile marker was unreadable; attempting reloadActiveProfile() before consulting activeProfileID")
      let retrySnap = store.reloadActiveProfile()
      if let retryErr = retrySnap.activeProfileError {
        Log.helper.error("HelperResumeAction: active-profile marker still unreadable after retry: \(String(describing: retryErr), privacy: .public)")
        return .activeProfileUnreadableAfterRetry(retryErr)
      }
      // Retry healed the error — fall through to the standard
      // resolve-and-start path using the refreshed snapshot.
      if let id = retrySnap.activeProfileID {
        return resolveAndStart(id: id, activeModel: store.activeModelID,
                               engineHost: engineHost, resolver: resolver)
      }
      // Review v6 F3: retry healed the error but produced no active
      // id — operator's repair was to remove the marker, not write a
      // valid one. Distinguish from never-selected so helper.log
      // shows the retry breadcrumb.
      return .noActiveProfile(afterRetry: true)
    }
    guard let id = store.activeProfileID else {
      // Disambiguate "never picked" from "marker present but
      // unreadable" (review v3 F1).
      if let err = store.lastActiveProfileError {
        return .activeProfileUnreadable(err)
      }
      return .noActiveProfile(afterRetry: false)
    }
    return resolveAndStart(id: id, activeModel: store.activeModelID,
                           engineHost: engineHost, resolver: resolver)
  }

  /// Shared resolve→host.start tail (review v6 F6). Both the
  /// retry-healed branch and the non-retry branch funnel through here
  /// so a future change to the start path (pre-resolve hook,
  /// structured `.resolverFailed` log decoration) lives in one place.
  private static func resolveAndStart(
    id: String,
    activeModel: String?,
    engineHost: PieEngineHost,
    resolver: HelperExportedAPI.LaunchSpecResolver
  ) -> Outcome {
    // #469: the menu-bar Resume / crash auto-relaunch path has no XPC
    // override, so the durable active-model marker is the explicit boot model
    // here. Precedence in the resolver is `explicit override > marker >
    // profile default`: a non-nil marker boots the user's last-launched model
    // (so a stopped-engine Resume honors their last pick instead of reverting
    // to the profile default); a nil marker (never launched) falls back to
    // the profile default. The resolver re-writes the marker to the resolved
    // model, so this is idempotent when the marker already holds it.
    let spec: PieControlLauncher.LaunchSpec
    switch resolver(id, activeModel) {
    case .success(let s):
      spec = s
    case .failure(let err):
      // #469 defense in depth: a STALE marker — the model it names was deleted
      // or evicted out from under it (e.g. an HF-cache eviction, or a delete
      // that did not go through `ModelsSettingsTab.deleteInstalledModel`) —
      // must not dead-end Resume on `modelMissing` ahead of a still-valid
      // profile default. When the marker DROVE this resolve (activeModel
      // non-nil) and it failed `modelMissing`, retry ONCE with the profile
      // default (the pre-#469 Resume behavior). Bounded to a single retry: if
      // the default is the same missing model (or itself missing), the retry
      // also fails and the original error is surfaced below.
      if activeModel != nil,
         err.code == .modelMissing,
         case .success(let retried) = resolver(id, nil) {
        spec = retried
      } else {
        // Publish EVERY resolver failure (not just `.memoryRisk`) through
        // the engine's `.failed` status so the App surfaces the reason —
        // notably `modelMissing` from a fresh install / stale profile —
        // instead of silently sitting at `.stopped` while the chat
        // composer defers forever ( follow-up). `HelperStatusItemModel`
        // gates the Resume affordance on `code.invitesResumeRetry`, so a
        // recoverable code keeps a working retry while `memoryRisk` does
        // not invite one.
        engineHost.recordPreStartFailure(err)
        return .resolverFailed(err)
      }
    }
    switch engineHost.start(spec) {
    case .failure(let err): return .startRejected(err)
    case .success:          return .started(profileID: id)
    }
  }

  /// Review v3 N3 — main-async veto for the engine-death auto-relaunch
  /// closure. Extracted from `HelperMain.swift`'s relauncher body
  /// (HelperMain is not SPM-reachable, so the inline guard was the
  /// exact untestable boundary that hid the v1 F1 blocker). Pure
  /// function over `EngineStatus`; the closure calls this at its
  /// deferred `DispatchQueue.main.async` commit point to decide
  /// whether `HelperResumeAction.run` should run.
  ///
  /// Semantics (see PieEngineHost review v2 R1):
  ///  - `.failed`   → commit. The auto-relaunch scheduler ran
  ///                  because the engine reported `.failed(.engineGone)`;
  ///                  if state is still `.failed` at the deferred
  ///                  main-queue commit, no user Pause has won the
  ///                  race.
  ///  - `.stopped`  → veto. `stopLocked`'s `.failed(.engineGone)` arm
  ///                  transitions to `.stopped` on a user Pause; a
  ///                  Pause landed between the host's schedule sync
  ///                  and this main-queue turn. Abort.
  ///  - `.running` / `.starting` / `.stopping` → veto. Some other
  ///                  caller drove `start()` between the host's
  ///                  schedule sync and the main-queue commit (e.g.
  ///                  user Resume click). Do not pile a second
  ///                  auto-relaunch on top of it.
  public static func shouldCommitAutoRelaunch(status: EngineStatus) -> Bool {
    switch status {
    case .failed:
      return true
    case .stopped, .starting, .running, .stopping:
      return false
    }
  }

  /// Result of the composite auto-relaunch decision (#395). Carries the
  /// observed status on a veto so the caller can log WHY it skipped.
  public enum AutoRelaunchDecision: Equatable, CustomStringConvertible {
    /// `shouldCommitAutoRelaunch` vetoed — a user Pause, a concurrent
    /// start, or teardown won the deferred main-queue-hop race. The engine
    /// is no longer in the `.failed` state the scheduler fired for.
    case vetoed(EngineStatus)
    /// Committed — the `run` closure fired; carries its `Outcome`.
    case ran(Outcome)

    public var description: String {
      switch self {
      case .vetoed(let status): return "vetoed(status=\(status))"
      case .ran(let outcome):   return "ran(\(outcome))"
      }
    }
  }

  /// SPM-reachable composite of the engine-death auto-relaunch closure
  /// (#395). The production relauncher in `HelperMain.swift` lives in the
  /// Helper Xcode target — NOT SPM-reachable — so its veto→run body was the
  /// exact untestable boundary that hid the #299 v1 F1 "feature dead in
  /// production" blocker. This extracts the *decision* (veto via
  /// `shouldCommitAutoRelaunch`) plus the *action* (`run`) so the whole
  /// composition is unit-testable here; HelperMain keeps only the
  /// AppKit-bound `DispatchQueue.main.async` hop, the `HelperResumeHolder`
  /// deref, and the log lines.
  ///
  /// `run` is supplied by the caller (rather than threading
  /// host/store/resolver through this function) so HelperMain reads its
  /// live `engineHost.status` AND the run inputs at the same deferred
  /// commit point — the status passed here and the closure's captures stay
  /// consistent. Pure over `status` + the closure's effect: a `.failed`
  /// status runs the closure exactly once; any other status vetoes and the
  /// closure is never invoked.
  public static func composeAutoRelaunch(
    status: EngineStatus,
    run: () -> Outcome
  ) -> AutoRelaunchDecision {
    guard shouldCommitAutoRelaunch(status: status) else { return .vetoed(status) }
    return .ran(run())
  }
}
