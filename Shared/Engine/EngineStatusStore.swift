import Foundation
import Combine
import os

/// `@MainActor ObservableObject` mirror of the helper's
/// `engineStatus()` selector. Owns a poll loop against an
/// `AppXPCClient` and republishes the most recent `EngineStatus` so
/// SwiftUI views can branch on it and `HTTPEngineClient.baseURLProvider`
/// can resolve the loopback URL synchronously per request.
///
/// Why poll rather than push? `PieHelperXPC` exposes only a one-shot
/// reply selector — there is no streaming `subscribeEngineStatus` yet.
/// The cadence is adaptive (#587): fast (`pollInterval`, ~1 s) while the
/// engine state is changing, slow (`steadyPollInterval`, ~10 s) once it is
/// established `.running`, and paused entirely when no engine session is
/// expected (stopped/idle) so macOS App Nap can engage. This keeps the
/// GUI's "engine reachable?" signal current without standing up a second
/// XPC surface and without 60 idle wakeups/min on the app + helper.
///
/// Initial status is `.starting` (not `.stopped`) because the helper's
/// reachability is genuinely unknown until the first reply lands —
/// `.stopped` would be a load-bearing claim that the supervisor said
/// "engine off," which we have no evidence for yet (and the surfaced
/// UI would say "Engine is stopped, click Resume" instead of the
/// truthful "Engine starting…" placeholder).
@MainActor
public final class EngineStatusStore: ObservableObject {
  /// Last status reported by the helper (or the initial `.starting`
  /// placeholder before the first poll completes).
  @Published public private(set) var status: EngineStatus

  /// Effective Local API daemon bind mode for the currently launched engine.
  /// This is a runtime fact recorded at the shared start boundary, not merely
  /// the user's desired preference. Views that warn about external exposure
  /// read this while `.running` so they do not claim loopback-only posture for
  /// a daemon that was actually launched on `0.0.0.0`.
  @Published public private(set) var runtimeDaemonBindMode: EngineHTTPBindMode

  /// Most recent error string from a failed `engineStatus()` poll.
  /// `nil` after a successful poll. Surfaces helper-down vs
  /// supervisor-running-but-still-starting in the UI without forcing
  /// the caller to introspect `EngineStatus` for a `.failed` case.
  @Published public private(set) var lastError: String?

  /// Latest authoritative KV usage rows from pie `model_status` (#517),
  /// refreshed opportunistically while the engine is running. Chat sends read
  /// this synchronously to seed APC retention; an empty array means unknown
  /// and must not be treated as zero usage.
  @Published public private(set) var latestKVUsageSnapshots: [KVUsageSnapshot] = []

  /// Number of `engineStatus()` polls that have returned (success or
  /// failure). Test seam — lets tests `await` a transition without
  /// polling `status` in a tight loop.
  ///
  /// Deliberately NOT `@Published`: the poll loop bumps this every tick,
  /// and publishing it would re-render every observer (incl. the toolbar
  /// that hosts the engine-status popover) on each poll and dismiss the
  /// popover. Real state changes ride `status`/`lastError`, which are
  /// `@Published` and change-guarded; tests observe those.
  public private(set) var pollCount: UInt64 = 0

  /// Signature of the engine failure the user has dismissed from the
  /// in-window error banner. The banner shows only while a failure is
  /// live AND its signature differs from this — so a Dismiss hides the
  /// current failure, and the banner reappears only on a DIFFERENT one
  /// (mirrors `PersistenceStatus.acknowledgeLastError`). `nil` ⇒ nothing
  /// acknowledged yet.
  ///
  /// `@Published` is safe here (it is NOT a per-second churn source): it
  /// changes only on a user Dismiss — never on the 1 Hz poll — and the
  /// banner must re-render to hide itself when it flips.
  @Published public private(set) var acknowledgedEngineFailureSignature: String?

  /// Wall-clock instant the engine most recently entered `.starting`,
  /// or `nil` when not starting. Drives the indicator's honest
  /// "Starting… (elapsed Ns)" copy (#1) via a view-local timer: the
  /// store stamps the instant on the transition INTO `.starting` and
  /// clears it on any other state, so it publishes only on transitions
  /// (never once per poll — preserves the #327 no-per-second-churn rule
  /// that keeps the status popover from flapping).
  @Published public private(set) var startingSince: Date?

  /// `URL(string: "http://127.0.0.1:<port>")` while running, else
  /// `nil`. Computed live off `status` so the SwiftUI dependency
  /// graph re-evaluates dependent views when status flips.
  public var baseURL: URL? {
    if case .running(let snapshot) = status {
      return URL(string: "http://127.0.0.1:\(snapshot.port)")
    }
    return nil
  }

  /// User-facing Local API URL for the effective runtime bind mode. In-app
  /// clients keep using `baseURL` (loopback), but the endpoint explorer should
  /// render the listener mode the engine was actually launched with.
  public var localAPIBaseURL: URL? {
    if case .running(let snapshot) = status {
      return URL(string: "http://\(runtimeDaemonBindMode.baseURLHost):\(snapshot.port)")
    }
    return nil
  }

  /// The active engine session's `EngineSessionSnapshot` while `.running`,
  /// else `nil` (#476). The single authoritative view of the launched
  /// session — served model id, effective `max_tokens` ceiling, launch
  /// generation — that `EngineLifecycle` feeds into `ModelLoadCenter` on the
  /// `.running` edge and that callers use for stale-generation detection.
  public var currentSnapshot: EngineSessionSnapshot? {
    if case .running(let snapshot) = status { return snapshot }
    return nil
  }

  public func kvUsageSnapshot(for modelID: String) -> KVUsageSnapshot? {
    latestKVUsageSnapshots.first { $0.modelID == modelID }
  }

  private let client: any AppXPCClient
  private let daemonBindModeProvider: @MainActor @Sendable () -> EngineHTTPBindMode
  /// Fast cadence — the interval used while the engine state is actively
  /// changing (transition tier: `.starting`/`.stopping`, an engine-death or
  /// transport-loss recovery episode). Named `pollInterval` for back-compat
  /// with the original fixed-cadence constructor.
  private let pollInterval: TimeInterval
  /// Steady cadence — the (slower) interval used once the engine is
  /// established `.running` and stable. Cuts idle wakeups ~10× vs the old
  /// fixed 1 Hz loop so macOS App Nap can engage (#587).
  private let steadyPollInterval: TimeInterval
  private var task: Task<Void, Never>?
  private nonisolated static let log = Logger(subsystem: "com.ratiothink.app", category: "engine-status")

  /// Wall-clock source, injectable so a test can stamp `startingSince`
  /// deterministically. Defaults to `Date()` (production + existing
  /// callers unaffected). Module-internal (not `private`) so the
  /// `ChatRecoveryGate` conformance in a sibling file can route
  /// `waitUntilRunning`'s deadline through the same clock.
  let now: @Sendable () -> Date

  /// Cooperative sleep used by the `waitUntilRunning` recovery loop,
  /// injectable so a test can drive the wait on a virtual clock instead of
  /// burning real wall-clock budget (mirrors `PieEngineHost.sleepFor`).
  /// Default: the cancellation-aware `Task.sleep` the loop used inline, so
  /// production behaviour is byte-identical.
  let sleepFor: @Sendable (TimeInterval) async -> Void

  /// Consecutive `engineStatus()` polls that FAILED at the transport layer
  /// (helper unreachable / reply timeout). Reset to 0 on the first
  /// successful poll. Once it reaches `transportLossEscalation` the store
  /// synthesizes `.failed(.engineGone)` so an in-flight chat send can ride
  /// the recovery (`requireBaseURL` → `.engineGone`). The unified status
  /// banner shows the helper-axis tiers off `HelperHealth`; this counter is
  /// only the chat-recovery escalation, now aligned to the unified policy.
  private var consecutiveFailures = 0
  /// True while the current `.failed(.engineGone)` was synthesized by THIS
  /// store for sustained transport loss (#5a) rather than reported by the
  /// helper. Drives honest "can't reach" copy in `statusDetail` — there is
  /// no evidence the engine process exited in that case (#477 review F8).
  private var engineGoneSynthesized = false

  /// Unified poll-count policy — single source of truth shared with the
  /// status banner (`StatusBannerReducer`) so the engine axis and the helper
  /// axis count identically. Replaces the former standalone ~5-poll
  /// transport-loss timing.
  public let tierPolicy: StatusTierPolicy

  /// Sustained transport-loss polls that escalate to a synthesized
  /// `.failed(.engineGone)` for the chat-recovery path. Derived from the
  /// unified `tierPolicy.tier2Polls`.
  private var transportLossEscalation: Int { tierPolicy.tier2Polls }

  /// Consecutive polls a REACHABLE helper reported `.failed(.engineGone)` —
  /// the engine-axis recovery count the banner tiers off. Reset to 0 on any
  /// non-engineGone status. `@Published` so the banner re-renders when it
  /// crosses a tier boundary; it changes only during an engine-death
  /// episode, never in steady state (no per-poll churn).
  @Published public private(set) var engineGonePolls = 0

  /// Whether the engine has reached `.running` this session. Gates the
  /// first-load rules (#1/#2): a never-run engine is never escalated on a
  /// timer alone, and a transient explicit `.failed` is held during its
  /// first-load window.
  @Published public private(set) var wasEverRunning = false

  /// Consecutive first-load polls a held-eligible explicit `.failed` has
  /// been suppressed (#2). Surfaces it once it survives
  /// `tierPolicy.firstLoadFailureGracePolls`.
  private var heldFailurePolls = 0

  /// True only when `runtimeDaemonBindMode` came from an explicit app start
  /// request or a helper status payload that carried `daemonBindHost`. Legacy
  /// running payloads lack that field, so they must not silently certify a
  /// loopback-only posture.
  private var runtimeDaemonBindModeIsConfirmed = false

  public init(
    client: any AppXPCClient,
    pollInterval: TimeInterval = 1.0,
    steadyPollInterval: TimeInterval = 10.0,
    initialStatus: EngineStatus = .starting,
    initialDaemonBindMode: EngineHTTPBindMode = .loopback,
    daemonBindModeProvider: @escaping @MainActor @Sendable () -> EngineHTTPBindMode = { .loopback },
    tierPolicy: StatusTierPolicy = StatusTierPolicy(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleepFor: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
  ) {
    self.client = client
    self.daemonBindModeProvider = daemonBindModeProvider
    self.pollInterval = pollInterval
    self.steadyPollInterval = steadyPollInterval
    self.tierPolicy = tierPolicy
    self.now = now
    self.sleepFor = sleepFor
    self.status = initialStatus
    self.runtimeDaemonBindMode = initialDaemonBindMode
    if case .running(let snapshot) = initialStatus {
      self.wasEverRunning = true
      if let daemonBindHost = snapshot.daemonBindHost {
        self.runtimeDaemonBindMode = daemonBindHost
        self.runtimeDaemonBindModeIsConfirmed = true
      } else {
        self.runtimeDaemonBindMode = Self.failSafeLegacyBindMode(
          current: initialDaemonBindMode,
          currentIsConfirmed: false,
          desired: daemonBindModeProvider()
        )
      }
    }
    if case .starting = initialStatus { self.startingSince = now() }
  }

  /// Adaptive poll cadence resolved from the current state (#587). The
  /// loop drives its next sleep from this tier instead of a fixed interval
  /// so an idle/stopped app lets macOS App Nap engage while transitions
  /// stay responsive.
  enum PollCadence: Equatable {
    /// Engine state actively changing — poll fast (`pollInterval`).
    case transition
    /// Engine established `.running` and stable — poll slow (`steadyPollInterval`).
    case steady
    /// No engine session expected — suspend the loop entirely (no wakeups).
    case paused
  }

  /// Resolve the poll cadence from the current state. A recovery episode
  /// (sustained transport loss climbing toward escalation, or a live
  /// `.failed(.engineGone)` death) stays on the fast tier so the recovery is
  /// detected promptly. A `.running` engine with no in-flight blip drops to
  /// the steady tier. A `.stopped` or persistently `.failed` engine — no
  /// session expected, nothing a timer can change — pauses the loop; an
  /// explicit resume trigger (a start request or app foreground) re-arms it.
  func currentCadence() -> PollCadence {
    // Active recovery: a transport blip in progress (held last status) or a
    // reachable-helper engine-death episode. Poll fast to catch the recovery.
    if consecutiveFailures > 0 || engineGonePolls > 0 { return .transition }
    switch status {
    case .running:
      return .steady
    case .starting, .stopping:
      return .transition
    case .stopped:
      return .paused
    case .failed(.engineGone, _):
      // Covered by `engineGonePolls > 0` above in steady operation; kept
      // explicit so a synthesized engineGone never falls through to paused.
      return .transition
    case .failed:
      // memoryRisk / spawnFailed / modelMissing etc. — terminal until the
      // user acts (Restart Engine / pick a model), which re-arms via the
      // start path. Polling cannot change it, so pause.
      return .paused
    }
  }

  /// Seconds to sleep before the next poll for a non-paused cadence
  /// (`.infinity` for `.paused`, which the loop never sleeps on — it
  /// suspends instead). Test seam so cadence selection is asserted by the
  /// chosen interval, never by elapsed wall-clock.
  func sleepInterval(for cadence: PollCadence) -> TimeInterval {
    switch cadence {
    case .transition: return pollInterval
    case .steady: return steadyPollInterval
    case .paused: return .infinity
    }
  }

  /// Begin the background poll loop. Idempotent — re-entry while a
  /// task is already running is a no-op so `RatioThinkApp.init` can safely
  /// `start()` without tracking a "did we already start" flag. Also the
  /// resume primitive (#587): a paused loop nils `task`, so any start path
  /// or foreground hook that calls `start()` re-arms it.
  public func start() {
    guard task == nil else { return }
    let client = self.client
    Self.log.info("starting engine-status poll loop (fast=\(self.pollInterval, privacy: .public)s steady=\(self.steadyPollInterval, privacy: .public)s)")
    task = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshOnce(client: client)
        if Task.isCancelled { return }
        // Reacquire `self` only briefly to read the cadence off the
        // just-applied state (a synchronous main-actor read — the Task
        // inherits this @MainActor context); never hold it across the sleep.
        guard let cadence = self?.currentCadence() else { return }
        if cadence == .paused {
          // Suspend: no engine session expected, so stop waking the app and
          // the helper. Nil `task` so a resume trigger's `start()` re-arms.
          self?.suspendLoop()
          return
        }
        guard let interval = self?.sleepInterval(for: cadence) else { return }
        // `Task.sleep` is the cancellation-aware sleep; an
        // intermediate `cancel()` wakes us with `CancellationError`
        // which we swallow because the outer loop checks the flag.
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }
  }

  /// Suspend the poll loop from inside its own task: drop the `task`
  /// reference so a later `start()` (resume trigger) re-arms it. The
  /// caller `return`s immediately after, ending the task.
  private func suspendLoop() {
    task = nil
    Self.log.info("engine-status poll loop paused (no engine session — App Nap may engage)")
  }

  /// Cancel the poll loop. Idempotent. After `stop()` the published
  /// `status` retains its last value — the helper may have torn down,
  /// but the GUI's last view of the world is still actionable.
  public func stop() {
    task?.cancel()
    task = nil
  }

  /// Force one immediate poll. Returns the resolved status (or throws
  /// the XPC failure). Public so tests can drive deterministic
  /// transitions without sleeping for the poll interval — production
  /// callers should not need this.
  ///
  /// Asymmetry vs the poll loop (review v1 F2): on success this
  /// updates `status` and clears `lastError`; on failure it RE-THROWS
  /// and does NOT write `lastError`. Only the poll loop's
  /// `refreshOnce(...)` records failures into `lastError`, because
  /// only the loop has a "no human waiting" path where the error
  /// would otherwise be silently dropped. `refresh()`'s caller
  /// already gets the error via `throw`, so re-publishing it would
  /// flicker a `lastError` value the loop will immediately overwrite
  /// on the next tick. Tests pin this behavior in
  /// `test_refresh_propagates_xpc_failures`.
  @discardableResult
  public func refresh() async throws -> EngineStatus {
    let next = try await client.engineStatus()
    apply(next: next, error: nil)
    return next
  }

  /// Force one poll, recording BOTH outcomes into `status`/`lastError` (unlike
  /// `refresh()`, which rethrows on failure WITHOUT recording — see its
  /// asymmetry note). Used by `ChatRecoveryGate.refreshStatus()` so the chat
  /// classifier's `isHelperUnreachable`/`isEngineGone` reflect the forced
  /// probe, catching a sub-second mid-stream helper/engine death the 1Hz
  /// background loop missed (#393). Also feeds the helper-health ladder via
  /// `onPollOutcome` (a forced-poll failure is a real reachability signal).
  func pollRecordingOutcome() async {
    do {
      apply(next: try await client.engineStatus(), error: nil)
    } catch {
      apply(next: nil, error: String(describing: error))
    }
  }

  /// #488 review F1: fired at the entry of `stopEngine()` — the single
  /// funnel both UI stop paths (ChatScaffold Unload, Local API stop) route
  /// through — BEFORE the XPC call. `ActiveModelServeExecutor` wires this to
  /// `cancelDeferredPick()` so an explicit user stop drops any queued model
  /// pick instead of being reversed by it at the `.stopped` settle. Fired on
  /// the attempt (not the outcome): the stop is the user's newest intent
  /// whether or not the helper accepts it. Default no-op (mirrors
  /// `onPollOutcome`); the executor is the sole production consumer.
  @MainActor public var onExplicitStop: () -> Void = {}

  /// #496: refuse a Helper MUTATION (start/stop/restart) while the Helper
  /// transport isn't healthy. Reads the same `helperHealthProvider` the chat
  /// recovery wait uses; a `nil` provider (default / tests with no helper
  /// source) leaves every op allowed, preserving prior behavior. Read-only
  /// polls (`refresh`/`engineMemory`/the loop) stay UNGATED so the ladder can
  /// recover — see `HelperOpGate`. Throws `HelperUnavailable` so the call site
  /// surfaces an inline, helper-framed refusal (never the engine banner).
  private func requireHelperAvailable() throws {
    guard let health = helperHealthProvider() else { return }
    if let block = HelperOpGate.evaluate(health) { throw block }
  }

  ///  Unload: ask the helper to stop the running engine, freeing the
  /// resident model's RAM. Throws on rejection / transport failure so
  /// the caller keeps the resident-model state when the stop did not
  /// actually happen. The next status poll reflects the stopped engine.
  public func stopEngine() async throws {
    try requireHelperAvailable()
    onExplicitStop()
    try await client.stopEngine()
  }

  /// Intentionally rebuild the helper engine for `profileID`.
  ///
  /// pie's `/v1/models/load` endpoint is a registry lookup: the set of
  /// loadable ids is fixed by the config written before `pie serve`
  /// starts. When the active profile's default model changes (for
  /// example after a just-finished download), a live engine still
  /// advertises the old id until it is stopped and started again. This
  /// helper performs that product-internal reload without requiring the
  /// user to quit Rational.
  ///
  /// Restart deliberately routes through a helper-side selector instead
  /// of composing `stopEngine()` + `startEngine(profileID:)` here:
  /// the app's `status` is only a 1 Hz mirror, generic start swallows
  /// `.alreadyRunning` as idempotent, and `stopEngine()` has a short
  /// app-side reply timeout. The helper owns the authoritative state
  /// machine and waits for terminal stop before starting the new
  /// profile; any `.alreadyRunning` that escapes that contract is a
  /// failed rebuild and must surface to the caller.
  ///
  /// `modelOverride` (#469) rebuilds the engine bound to an explicit pick —
  /// the running-engine model switch, where `/v1/models/load` cannot swap the
  /// served model. `nil` (the default) preserves the existing
  /// default-model-change restart that boots the freshly-saved profile
  /// default (set-as-default, post-download).
  public func restartEngine(profileID: String, modelOverride: String? = nil) async throws {
    // #587 resume trigger: a restart rebuilds the engine, so a paused loop
    // (stopped/idle) must re-arm or the published status stays frozen while a
    // live engine is running. Idempotent — a no-op on the `.running` restart
    // path (ActiveModelServeExecutor) — and re-armed BEFORE the XPC call so the
    // rebuild's `.starting` → `.running`/`.failed` transition is surfaced.
    start()
    try requireHelperAvailable()
    do {
      try await client.restartEngine(profileID: profileID, modelOverride: modelOverride)
    } catch let error as AppXPCClientError {
      // The helper only replies after the rebuild's cold-boot handshake.
      // A boot slower than the App reply window is NOT a reload failure —
      // the restart is in flight and the status poll surfaces the real
      // `.running`/`.failed` outcome (#459 repro 2). Mirror `startEngine`'s
      // in-flight swallow so a slow large-model reload is never reported to
      // the caller as a failed reload. A real helper `EngineError`
      // (resolver rejected, modelMissing, …) still propagates.
      if case .replyTimeout = error {
        Self.log.notice("restartEngine(profileID=\(profileID, privacy: .public)) reply timed out — rebuild in flight; status poll will surface the outcome")
        return
      }
      throw error
    }
  }

  /// Test seam: invoked with the human-readable cause whenever a
  /// memory-poll transport error is swallowed to nil. Default routes to
  /// the os.Logger, mirroring `refreshOnce`; tests inject a spy to prove
  /// a wedged engine is RECORDED even though the UI value is nil.
  /// Not `@Published`; never touched on the hot status-poll path.
  var onMemoryPollError: (String) -> Void = { message in
    EngineStatusStore.log.error("engineMemory poll failed: \(message, privacy: .public)")
  }

  /// #412: invoked once per `engineStatus()` poll resolution with the
  /// outcome — `true` when the XPC call returned a value (helper reachable),
  /// `false` when it threw a transport error. The App wires this to
  /// `HelperHealthController.ingestPollOutcome` so the helper-restart ladder
  /// is driven by the SAME poll the status mirror already runs — no second
  /// XPC surface. Default no-op (mirrors `onMemoryPollError`). Not
  /// `@Published`: it is an effect hook fired from `apply` on the main actor,
  /// never a SwiftUI dependency. `@MainActor` so the wired closure can call
  /// the `@MainActor` controller synchronously.
  @MainActor public var onPollOutcome: (Bool) -> Void = { _ in }

  /// #412 review F1: source of the App's helper-restart ladder state, so the
  /// chat recovery wait can be bounded by the LADDER OUTCOME (`.unreachable`
  /// ⇒ give up now) rather than a fixed timeout chosen out of sync with the
  /// ladder cadence. Wired by RatioThinkApp to read `HelperHealthController`;
  /// the default `nil` keeps the engine-gone path + tests on prior behavior.
  /// `@MainActor` so `helperRecoveryGaveUp` can read it synchronously from the
  /// main-actor recovery wait.
  @MainActor public var helperHealthProvider: () -> HelperHealth? = { nil }

  /// On-demand engine resident-memory readout for the status popover.
  /// Forwards to the XPC client; on a transport error it returns nil to
  /// the UI (a quiet, optional readout just hides the row — never
  /// surfaces an error path or flips status) but FIRST logs the cause via
  /// `onMemoryPollError`. Without that log a wedged engine that times out
  /// this selector would be byte-identical to a healthy "engine not
  /// running" and leave no diagnostic trace; `replyTimeout` / `proxyError`
  /// are transport faults, NOT evidence the engine stopped.
  /// Deliberately NOT a `@Published` field: RSS drifts every sample, so
  /// publishing it would re-render every observer (incl. the toolbar
  /// hosting the popover) and dismiss the popover. Callers read this
  /// while the popover is open and store the result in local view state.
  public func engineMemory() async -> EngineMemorySample? {
    do {
      return try await client.engineMemory()
    } catch {
      onMemoryPollError(String(describing: error))
      return nil
    }
  }

  /// Acknowledge (dismiss) the engine failure currently surfaced by the
  /// in-window error banner. Records the failure's `signature` so the
  /// banner suppresses THIS failure but re-shows on a different one.
  /// Idempotent: re-dismissing the same signature is a no-op.
  public func acknowledgeEngineFailure(_ signature: String) {
    guard acknowledgedEngineFailureSignature != signature else { return }
    acknowledgedEngineFailureSignature = signature
  }

  /// Whether `signature` matches the most recently dismissed failure —
  /// the banner reads this to decide whether to stay hidden.
  public func isEngineFailureAcknowledged(_ signature: String) -> Bool {
    acknowledgedEngineFailureSignature == signature
  }

  /// #326: kick the helper to (re)start the engine on `profileID` —
  /// used after a fresh-install model download lands so the engine boots
  /// with the now-present model. The poll loop surfaces the live
  /// `.starting` → `.running`/`.failed` transition; this call only needs
  /// to trigger the start and report a fast refusal.
  ///
  /// The helper replies to `startEngine` only AFTER the launch handshake
  /// (which includes the model load at engine boot), so a slow start
  /// trips the App-side reply timeout. That is not a failure — the start
  /// is in flight — so `.replyTimeout` is swallowed. A real helper
  /// `EngineError` (resolver rejected, still `.modelMissing`, etc.)
  /// propagates so the UI can surface the reason.
  ///
  /// `modelOverride` is the explicit per-start model selection (chat
  /// toolbar / model-list pick). Non-nil boots that model regardless of the
  /// profile's persisted default, so a no-default profile starts cleanly
  /// from an explicit pick (#459 repro 1).
  ///
  /// `daemonBindHost` overrides the shared Local API bind preference for this
  /// start (the settings external-access toggle); `nil` inherits
  /// `daemonBindModeProvider()`.
  ///
  /// Same-profile idempotency is owned by the helper's `startOrAttach`
  /// boundary, so an `.alreadyRunning` that reaches here is an incompatible
  /// start (different profile, stopping, …) and surfaces to the caller rather
  /// than being swallowed.
  public func startEngine(profileID: String,
                          modelOverride: String? = nil,
                          daemonBindHost: EngineHTTPBindMode? = nil) async throws {
    // #587 resume trigger: a start request means an engine session is now
    // expected, so re-arm the poll loop if it paused while stopped/idle.
    // Idempotent — a no-op when the loop is already running. Re-arm BEFORE
    // the XPC call so the `.starting` → `.running`/`.failed` transition the
    // start produces is surfaced even if the loop was paused.
    start()
    try requireHelperAvailable()
    let requestedBindMode = daemonBindHost ?? daemonBindModeProvider()
    do {
      if let modelOverride {
        // Model-pick start: the helper resolver injects the persisted Local
        // API bind mode into the spec, so this start still honors the user's
        // exposure preference even though the model-override wire selector
        // carries no explicit bind host. Record the shared preference as the
        // optimistic runtime posture (it matches what the resolver injects).
        try await client.startEngine(profileID: profileID, modelOverride: modelOverride)
      } else {
        try await client.startEngine(profileID: profileID, daemonBindHost: requestedBindMode)
      }
      runtimeDaemonBindMode = requestedBindMode
      runtimeDaemonBindModeIsConfirmed = true
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        Self.log.notice("startEngine(profileID=\(profileID, privacy: .public)) reply timed out — start in flight; status poll will surface the outcome")
        runtimeDaemonBindMode = requestedBindMode
        runtimeDaemonBindModeIsConfirmed = true
        return
      }
      throw error
    }
  }

  /// Synchronous accessor for `HTTPEngineClient.baseURLProvider`.
  /// Throws `HTTPEngineError.engineNotReady` when the engine is not
  /// `.running` — the discriminator the HTTP client uses to surface
  /// "Engine starting…" rather than a generic network error. Must
  /// run on the main actor because it reads the published `status`.
  ///
  /// When the helper has reported `.failed(.engineGone, _)` (the
  /// post-launch death signal), the provider throws `.engineGone`
  /// instead of `.engineNotReady` — a semantic 503-Retry-After at the
  /// boundary. `ChatSendController` keys its recovery retry on that
  /// discrete case rather than parsing the `engineNotReady` detail.
  public func requireBaseURL() throws -> URL {
    if case .running(let snapshot) = status {
      // Force-unwrap is safe: `EnginePort` (UInt16) interpolates into
      // a valid IPv4 loopback URL by construction, and the `running`
      // decoder already rejects `port == 0`.
      return URL(string: "http://127.0.0.1:\(snapshot.port)")!
    }
    // The `detail` fields are the DIAGNOSTIC channel (they end up in
    // `EngineProblem.technicalDetail` / logs, never primary copy) — feed
    // them the raw `.failed` message, not the curated `statusDetail`
    // line, so a chat-path failure keeps its cause (#477 review F8).
    if case .failed(.engineGone, let message) = status {
      throw HTTPEngineError.engineGone(detail: message)
    }
    if case .failed(let code, let message) = status {
      throw HTTPEngineError.engineNotReady(detail: "[\(code.rawValue)] \(message)")
    }
    throw HTTPEngineError.engineNotReady(detail: detailForStatus())
  }

  /// One-line, human-readable summary of `status`. Used in the
  /// `engineNotReady` detail field so the UI's "Engine starting…"
  /// placeholder can carry a useful sub-line ("Helper unreachable"
  /// vs "Engine failed: spawnFailed — …").
  public var statusDetail: String { detailForStatus() }

  private func detailForStatus() -> String {
    if let lastError {
      return "Helper unreachable: \(lastError)"
    }
    switch status {
    case .stopped:
      return "Engine stopped"
    case .starting:
      return "Engine starting…"
    case .running:
      return "Engine running"
    case .stopping:
      return "Engine stopping…"
    case .failed(.engineGone, _) where engineGoneSynthesized:
      // Store-synthesized transport loss (#5a): there is no evidence the
      // engine process exited — only that the helper stopped answering.
      // Honest copy instead of the taxonomy's process-exited line.
      return "Can’t reach the engine — it stopped responding. Restart the engine to reconnect."
    case .failed(let code, let message):
      // #477: the status `message` is a raw diagnostic (stderr tails,
      // resolver traces) — surface the taxonomy's curated line instead.
      return EngineProblem(statusCode: code, rawMessage: message).message
    }
  }

  private nonisolated func refreshOnce(client: any AppXPCClient) async {
    let started = Date()
    do {
      let next = try await client.engineStatus()
      let took = Date().timeIntervalSince(started)
      // #413 diag: a slow-but-succeeding poll is the early warning that the
      // helper is getting saturated (toward the 2 s reply timeout) — the next
      // poll may time out and feed HelperHealthController's restart ladder.
      if took > 0.5 {
        DiagnosticLog.app.event("engine.poll", [("result", "slow"), ("took", String(format: "%.2f", took))])
      }
      await MainActor.run { [weak self] in
        self?.apply(next: next, error: nil)
      }
      if case .running = next {
        do {
          let usage = try await client.kvUsageSnapshots()
          await MainActor.run { [weak self] in
            self?.latestKVUsageSnapshots = usage
          }
        } catch {
          let message = String(describing: error)
          Self.log.error("kvUsageSnapshots poll failed: \(message, privacy: .public)")
          DiagnosticLog.app.event("engine.kv_usage", [("result", "fail"), ("reason", message)])
          await MainActor.run { [weak self] in
            self?.latestKVUsageSnapshots = []
          }
        }
      } else {
        await MainActor.run { [weak self] in
          self?.latestKVUsageSnapshots = []
        }
      }
    } catch {
      let message = String(describing: error)
      let took = Date().timeIntervalSince(started)
      Self.log.error("engineStatus poll failed: \(message, privacy: .public)")
      // #413 diag: a FAILED engineStatus XPC poll is exactly what drives the
      // helper-restart ladder. A `replyTimeout` here = the helper was too slow
      // to answer (e.g. saturated draining pie's --debug output during a busy
      // search), NOT engine death. Persist it + the XPC latency so the
      // operator's run shows whether the helper-restart path fired.
      DiagnosticLog.app.event("engine.poll", [
        ("result", "fail"), ("took", String(format: "%.2f", took)), ("reason", message),
      ])
      await MainActor.run { [weak self] in
        self?.apply(next: nil, error: message)
        self?.latestKVUsageSnapshots = []
      }
    }
  }

  private func apply(next: EngineStatus?, error: String?) {
    if let next {
      // Successful poll — the helper answered. Clear the transport-loss
      // counter and mirror the reported status verbatim.
      consecutiveFailures = 0
      // #2 App-side hold: during a FIRST load (engine never `.running`, still
      // in its `.starting` window) a transient explicit `.failed(.spawnFailed
      // / .engineGone)` is held as `.starting` for a short grace, so a
      // momentary handshake mis-classification reads as Tier-0 "Starting…"
      // not a red flash. A genuinely persistent failure surfaces once it
      // survives the grace. (`#2` root fix is helper-side; this is defense.)
      if shouldHoldTransientFailure(next) {
        heldFailurePolls += 1
        if heldFailurePolls < tierPolicy.firstLoadFailureGracePolls {
          if self.lastError != nil { self.lastError = nil }
          updateEngineGonePolls(for: self.status)
          pollCount &+= 1
          onPollOutcome(true)   // helper answered (with a held .failed)
          return
        }
        // grace exhausted — surface the failure below.
      }
      heldFailurePolls = 0
      updateRuntimeDaemonBindMode(from: next)
      engineGoneSynthesized = false
      setStatusAndTrackStarting(next)
      if case .running = next { wasEverRunning = true }
      updateEngineGonePolls(for: next)
      if self.lastError != nil { self.lastError = nil }
    } else {
      heldFailurePolls = 0
      // Failed poll — the helper did not answer (unreachable / reply
      // timeout). A single blip is NOT a failure: the on-demand Helper
      // respawn takes ~1–3 s and a heavy model load can momentarily delay
      // one `engineStatus` reply. Hold the LAST known status (anti-flap,
      // #1) and escalate only once the loss is SUSTAINED.
      consecutiveFailures += 1
      if consecutiveFailures >= transportLossEscalation {
        // #5a: sustained transport loss → synthesize the recoverable
        // `.failed(.engineGone)` the rest of the app already understands
        // (red indicator + banner, chat-send retry via `requireBaseURL`,
        // gate `.engineFailed`) instead of sticking at `.starting`
        // forever. Synthesize once and hold so a continuing outage does
        // not re-publish a fresh message every poll.
        if !isEngineGone(self.status) {
          let cause = error.flatMap { $0.isEmpty ? nil : $0 } ?? "no response from the engine helper"
          engineGoneSynthesized = true
          setStatusAndTrackStarting(.failed(
            code: .engineGone,
            message: "Can’t reach the engine — it stopped responding (\(cause)). Use Restart Engine to reconnect."
          ))
          // Symmetric to the success non-running clear in
          // `updateRuntimeDaemonBindMode`: leaving a running generation must
          // invalidate the confirmed bind posture, or a later legacy running
          // payload (no `daemonBindHost`) would reuse the stale confirmed
          // `.loopback` and hide the 0.0.0.0 exposure warning for an
          // externally bound endpoint. Keep `runtimeDaemonBindMode` as the
          // last-known value so the fail-safe still over-reports on doubt.
          runtimeDaemonBindModeIsConfirmed = false
        }
        if self.lastError != nil { self.lastError = nil }
      }
      updateEngineGonePolls(for: self.status)
      // else: transient — keep current status, keep `startingSince`, and
      // do NOT surface `lastError`, so a slow-but-normal start reads as a
      // calm "Starting…" rather than a fault at the ~2 s reply-timeout (#1).
    }
    pollCount &+= 1
    // #412: feed the helper-health ladder. `error == nil` ⟺ the poll
    // returned an EngineStatus (helper reachable); a non-nil error is a
    // transport failure (helper unreachable). Both the background loop's
    // success and failure paths flow through `apply`, so the ladder sees
    // every tick. Fired last so observers of `status`/`lastError` settle
    // first.
    onPollOutcome(error == nil)
  }

  /// Assign `status` (change-guarded) and maintain `startingSince` so the
  /// indicator can render a live elapsed counter while the engine starts.
  private func setStatusAndTrackStarting(_ next: EngineStatus) {
    if self.status != next { self.status = next }
    if case .starting = next {
      if self.startingSince == nil { self.startingSince = now() }
    } else if self.startingSince != nil {
      self.startingSince = nil
    }
  }

  private func isEngineGone(_ status: EngineStatus) -> Bool {
    if case .failed(.engineGone, _) = status { return true }
    return false
  }

  /// #2 hold predicate: a held-eligible transient failure is an explicit
  /// `.spawnFailed`/`.engineGone` while the engine has NEVER run this
  /// session and is still inside its `.starting` window.
  private func updateRuntimeDaemonBindMode(from next: EngineStatus) {
    guard case .running(let snapshot) = next else {
      runtimeDaemonBindModeIsConfirmed = false
      return
    }
    if let daemonBindHost = snapshot.daemonBindHost {
      runtimeDaemonBindMode = daemonBindHost
      runtimeDaemonBindModeIsConfirmed = true
      return
    }

    runtimeDaemonBindMode = Self.failSafeLegacyBindMode(
      current: runtimeDaemonBindMode,
      currentIsConfirmed: runtimeDaemonBindModeIsConfirmed,
      desired: daemonBindModeProvider()
    )
  }

  private static func failSafeLegacyBindMode(
    current: EngineHTTPBindMode,
    currentIsConfirmed: Bool,
    desired: EngineHTTPBindMode
  ) -> EngineHTTPBindMode {
    if desired == .external { return .external }
    if currentIsConfirmed { return current }
    if current == .external { return .external }
    // Missing daemonBindHost is unknown, not proof of loopback. Prefer the
    // current desired external posture over stale confirmed state from an
    // earlier running generation. When no
    // confirmed app start or persisted external preference can explain the
    // running daemon, over-report exposure so the Local API UI keeps the
    // network warning visible instead of claiming loopback-only safety.
    return .external
  }

  private func shouldHoldTransientFailure(_ next: EngineStatus) -> Bool {
    guard !wasEverRunning, startingSince != nil else { return false }
    guard case let .failed(code, _) = next else { return false }
    return code == .spawnFailed || code == .engineGone
  }

  /// Maintain the engine-axis recovery count the banner tiers off:
  /// increment while a reachable helper reports `.failed(.engineGone)`,
  /// reset to 0 on any other status. Change-guarded so it only publishes
  /// during an engine-death episode (no steady-state churn).
  private func updateEngineGonePolls(for status: EngineStatus) {
    if case .failed(.engineGone, _) = status {
      engineGonePolls += 1
    } else if engineGonePolls != 0 {
      engineGonePolls = 0
    }
  }

  /// Test seam: drive the poll-apply reducer directly, exactly as the
  /// 1 Hz loop's `refreshOnce` does per tick (`next` on success, `nil` +
  /// `error` on a transport failure). Lets the anti-flap / escalation /
  /// `startingSince` logic be pinned deterministically without sleeping
  /// on the real poll loop. `internal` (RatioThinkCoreTests imports
  /// `@testable`); never reached by production code.
  internal func _applyPollForTesting(next: EngineStatus?, error: String?) {
    apply(next: next, error: error)
  }
}
