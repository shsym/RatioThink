import Foundation
import os

/// Production engine manager that replaces `PieSupervisor` on the
/// helper boot path. Wraps `PieControlLauncher.launch`
/// + `LaunchedSession` and projects the result onto the
/// `EngineStatus` surface previously owned by `PieSupervisor`, so
/// `HelperStatusItemBinding` / `HelperStatusItemModel.make(from:)`
/// keep working unchanged.
///
/// PieSupervisor's argv (`pie --model <path> --http-listen :0
/// --inferlet-dir <dir>`) and `HTTP_LISTEN=` handshake parser do not
/// match the current `pie` binary, which is a multi-command CLI
/// whose engine is `pie serve --config <toml>` with handshake
/// `pie-server serving on <host>:<port>` + `internal token: <tok>`.
/// PieControlLauncher already speaks that protocol; this host plugs
/// it into the helper's selector + menu-bar wiring without
/// rewriting PieSupervisor itself.
///
/// Scope ceiling ( "Out of scope"): the restart ladder,
/// slow-flap cap, and `.killRejected` boot recovery from
/// `PieSupervisor.swift:563,890,1132+` are NOT ported here. A
/// single-shot lifecycle closes the MVP-S1 chat-demo path; if pie
/// crashes mid-session the host transitions to `.failed` and waits
/// for an explicit user Resume. Porting (or re-deciding) those
/// behaviors is a follow-up.
///
/// Concurrency model:
///  · `stateQueue` (serial) owns every `_state` transition. The
///    async `PieControlLauncher.launch` task and `stop()`'s
///    teardown task both hop onto it before mutating state.
///  · `_status` lives behind an `OSAllocatedUnfairLock` so the
///    lock-free `status` getter does not have to bounce through
///    `stateQueue` (the XPC `engineStatus` selector reads from any
///    peer queue and must never deadlock the host's own state path).
/// Verdict from an `EngineSession` liveness probe ( G1). `gone`
/// carries a coarse human cause (process exit status, or "control
/// plane unreachable: …"); the rich death reason from captured engine
/// stderr is deferred to .
public enum EngineLiveness: Equatable, Sendable {
  case alive
  case gone(reason: String)
}

public final class PieEngineHost: @unchecked Sendable {

  // MARK: - LaunchSpec

  /// PieControlLauncher's spec is what the host hands to
  /// `launch(spec:)`. Re-exported under a host-scoped name so call
  /// sites that already hold a `PieEngineHost` do not have to
  /// import the launcher type for the LaunchSpec.
  public typealias LaunchSpec = PieControlLauncher.LaunchSpec

  // MARK: - Observation

  /// Opaque handle returned by `observe`. Drop it (or call
  /// `cancel()`) to stop receiving status updates. Same shape as
  /// `PieSupervisor.ObservationToken` so `HelperMain
  /// .supervisorObservation` can hold either.
  public final class ObservationToken: @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    fileprivate init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
      let already = lock.withLock { (cancelled: inout Bool) -> Bool in
        defer { cancelled = true }
        return cancelled
      }
      if !already { onCancel() }
    }
    deinit { cancel() }
  }

  // MARK: - State

  private enum State {
    case stopped
    case starting(profileID: String, launchTask: Task<Void, Never>)
    case running(port: EnginePort, profileID: String, session: any EngineSession)
    case stopping(session: (any EngineSession)?)
    case failed(EngineErrorCode, String)

    var publicStatus: EngineStatus {
      switch self {
      case .stopped:                                return .stopped
      case .starting:                               return .starting
      case .running(let port, let profileID, _):    return .running(port: port, profileID: profileID)
      case .stopping:                               return .stopping
      case .failed(let code, let message):          return .failed(code: code, message: message)
      }
    }
  }

  // MARK: - Launcher seam

  /// Function shape `PieEngineHost` calls to bring a `pie serve`
  /// engine up. Production binds this to `PieControlLauncher.launch`;
  /// unit tests inject a closure returning a fake `EngineSession`
  /// so the XPC selector wiring can be exercised without spawning
  /// a real subprocess. The return type uses `any EngineSession`
  /// (not the concrete `LaunchedSession`) precisely so tests do
  /// not have to construct a `Process`.
  public typealias LauncherCall = @Sendable (LaunchSpec) async throws -> (port: EnginePort, session: any EngineSession)

  /// The affordances `PieEngineHost` needs from the launcher's
  /// returned session: shut it down, and report whether the engine is
  /// still alive ( G1). `LaunchedSession` conforms with the
  /// real process-exit + control-plane ping probe; test fakes
  /// implement the same contract on top of in-memory state. The
  /// `checkLiveness()` default returns `.alive` so existing fakes that
  /// only care about shutdown need no change.
  public protocol EngineSession: Sendable {
    func shutdown() async
    func checkLiveness() async -> EngineLiveness
    /// Resident memory of the live engine process in bytes, or nil when
    /// unavailable. Default nil (see extension) so test fakes that
    /// only model shutdown/liveness need no change; the production
    /// `LaunchedSession` overrides with a `proc_pid_rusage` sample of the
    /// pie pid.
    func residentMemoryBytes() async -> UInt64?
  }

  // MARK: - RelaunchPolicy

  /// Bounded auto-relaunch ladder applied after the liveness monitor
  /// declares `.failed(.engineGone)` (D2). The goal: a
  /// mid-stream engine death becomes a retryable fault, not a terminal
  /// `.failed` the user must manually click Resume out of. After the
  /// ladder exhausts (more than `maxAttempts` engine-gone transitions
  /// inside `window`), the host stops auto-relaunching and waits for
  /// an explicit user action — mirrors PieSupervisor's slow-flap cap
  /// so a chronically broken engine doesn't loop forever.
  public struct RelaunchPolicy: Sendable {
    /// Max engine-gone auto-relaunches inside `window` before giving
    /// up. `<= 0` disables auto-relaunch.
    public var maxAttempts: Int
    /// Sliding window over which `maxAttempts` is counted. An attempt
    /// older than `window` no longer counts against the cap.
    public var window: TimeInterval
    /// Backoff before each attempt, indexed by attempt number (0-based).
    /// The final element repeats if `maxAttempts` exceeds the array.
    public var backoffSchedule: [TimeInterval]
    /// Review v1 F2 — re-arm the ladder on sustained healthy
    /// `.running`. After the host has stayed `.running` continuously
    /// for `healthyUptimeThreshold`, the recorded attempt timestamps
    /// are cleared so a future engine death starts the cap fresh.
    /// Counts "deaths without a healthy recovery" rather than
    /// "deaths total"; either auto-relaunch or a user-driven
    /// `start()` that survives the threshold qualifies as recovery.
    /// `<= 0` disables the re-arm (cap counts deaths total — matches
    /// pre-F2 behavior).
    public var healthyUptimeThreshold: TimeInterval

    public init(maxAttempts: Int = 2,
                window: TimeInterval = 60,
                backoffSchedule: [TimeInterval] = [1.0, 2.0],
                healthyUptimeThreshold: TimeInterval = 30) {
      self.maxAttempts = maxAttempts
      self.window = window
      self.backoffSchedule = backoffSchedule.isEmpty ? [1.0] : backoffSchedule
      self.healthyUptimeThreshold = healthyUptimeThreshold
    }

  }

  /// Closure the host invokes off `stateQueue` after the backoff
  /// elapses. Production binding (in `HelperMain`) calls
  /// `HelperResumeAction.run(...)` so the active-profile / resolver
  /// policy is reused; tests inject a closure that calls
  /// `host.start(spec)` directly.
  public typealias Relauncher = @Sendable () -> Void

  // MARK: - Init

  /// - Parameters:
  ///   - livenessInterval: cadence of the post-launch liveness probe
  ///     while `.running`. `<= 0` disables the monitor.
  ///   - livenessFailureThreshold: consecutive `.gone` probes required
  ///     before declaring `.failed(.engineGone)`. `> 1` tolerates a
  ///     transient control-plane blip without a spurious relaunch.
  ///   - relaunchPolicy: bounded ladder applied after engine-gone.
  ///     Default `.init()` allows 2 retries / 60s.
  ///   - relauncher: closure that brings the engine back up after the
  ///     ladder's backoff elapses. `nil` (the default) disables
  ///     auto-relaunch even if `relaunchPolicy.maxAttempts > 0`, so
  ///     existing call sites (tests, degraded boot) keep the prior
  ///     "stay .failed until user-Resume" behavior.
  public init(
    launcher: LauncherCall? = nil,
    livenessInterval: TimeInterval = 5,
    livenessFailureThreshold: Int = 2,
    relaunchPolicy: RelaunchPolicy = RelaunchPolicy(),
    relauncher: Relauncher? = nil,
    clock: @Sendable @escaping () -> Date = { Date() }
  ) {
    self.launcher = launcher ?? PieEngineHost.productionLauncher
    self.livenessInterval = livenessInterval
    self.livenessFailureThreshold = max(1, livenessFailureThreshold)
    self.relaunchPolicy = relaunchPolicy
    self.relauncher = relauncher
    self.clock = clock
  }

  private let launcher: LauncherCall
  private let livenessInterval: TimeInterval
  private let livenessFailureThreshold: Int
  private let relaunchPolicy: RelaunchPolicy
  private let relauncher: Relauncher?

  /// Wall-clock source for the slow-flap window math, injectable so a
  /// test can advance time deterministically instead of sleeping —
  /// the window prune is otherwise racy against the real liveness and
  /// backoff timers. Defaults to `Date()` (production + existing
  /// callers unaffected).
  private let clock: @Sendable () -> Date

  /// Production launcher: bridge `PieControlLauncher.launch` into the
  /// `(EnginePort, any EngineSession)` shape `PieEngineHost`
  /// consumes. Extension on `LaunchedSession` declares the
  /// conformance. Free function (not a static method) so it can be
  /// used as a default-argument value without tripping Swift's
  /// covariant-Self restriction.
  internal static let productionLauncher: LauncherCall = { spec in
    let (uintPort, session) = try await PieControlLauncher.launch(spec: spec)
    return (port: EnginePort(uintPort), session: session)
  }

  // MARK: - Public surface

  /// Cheap snapshot. Lock-free path so XPC `engineStatus` never
  /// bounces through `stateQueue`.
  public var status: EngineStatus { statusLock.withLock { $0 } }

  /// Live resident memory of the running engine process in bytes, or nil
  /// when not running / unavailable. Hops onto `stateQueue` — the
  /// owner of `_state`, which carries the live session — to extract the
  /// session, then awaits its `proc_pid_rusage` sampler. Deliberately off
  /// the hot `status` path: callers read this on demand (status popover
  /// open), never per frame.
  public func residentMemoryBytes() async -> UInt64? {
    let session: (any EngineSession)? = stateQueue.sync {
      if case let .running(_, _, session) = _state { return session }
      return nil
    }
    guard let session else { return nil }
    return await session.residentMemoryBytes()
  }

  /// Diagnostic-only observer count. Mirrors `PieSupervisor
  /// .observerCountForTesting` so the HelperStatusItem integration
  /// tests can pin "observers cleaned up on cancel".
  internal var observerCountForTesting: Int {
    observers.withLock { $0.count }
  }

  /// Register a handler invoked with the current status (synchronously
  /// dispatched on `stateQueue`) and on every subsequent transition.
  /// Same contract as `PieSupervisor.observe`: handlers run on
  /// `stateQueue`; do NOT re-enter `start` / `stop` from inside the
  /// handler.
  @discardableResult
  public func observe(_ handler: @escaping (EngineStatus, ObservationToken) -> Void) -> ObservationToken {
    let id = UUID()
    let token = ObservationToken { [weak self] in
      self?.observers.withLock { $0[id] = nil }
    }
    observers.withLock { $0[id] = { status in handler(status, token) } }
    let current = status
    stateQueue.async { handler(current, token) }
    return token
  }

  /// Spawn `pie serve` for the LaunchSpec. Returns `.alreadyRunning`
  /// when an engine is already starting / running / stopping (the
  /// host does NOT silently restart on top of itself).
  ///
  /// Cancellation: subsequent `stop()` calls cancel the launch task.
  /// `PieControlLauncher.launch`'s catch paths tear down the
  /// freshly-spawned subprocess on `CancellationError` so a
  /// click-Resume-then-Pause does not leak a child engine.
  @discardableResult
  public func start(_ spec: LaunchSpec) -> Result<Void, EngineError> {
    stateQueue.sync {
      switch _state {
      case .stopped, .failed:
        return doStart(spec)
      case .starting, .running, .stopping:
        return .failure(EngineError(
          code: .alreadyRunning,
          message: "PieEngineHost already \(_state)"
        ))
      }
    }
  }

  /// Stop the engine. Sends SIGINT (via `LaunchedSession.shutdown`)
  /// with `LaunchedSession`'s 10s grace, then SIGKILL. Cancels an
  /// in-flight launch task. Idempotent — repeated calls while
  /// `.stopped` / `.failed` / `.stopping` are no-ops.
  public func stop() {
    stateQueue.sync {
      stopLocked()
    }
  }

  /// Publish a resolver-level failure that happened before `start(_:)`
  /// could create a launch task. This keeps pre-start safety
  /// rejections (notably `.memoryRisk`) visible through the same
  /// `EngineStatus.failed` surface used by launcher failures.
  public func recordPreStartFailure(_ error: EngineError) {
    stateQueue.sync {
      switch _state {
      case .stopped, .failed:
        setState(.failed(error.code, error.message))
      case .starting, .running, .stopping:
        Log.engine.error("PieEngineHost: dropping pre-start failure \(error.code.rawValue, privacy: .public) while state=\(String(describing: self._state), privacy: .public)")
      }
    }
  }

  // MARK: - Internals

  private let stateQueue = DispatchQueue(label: "com.ratiothink.engine.host.state", qos: .userInitiated)
  private var _state: State = .stopped {
    didSet { publish(_state.publicStatus) }
  }
  private let statusLock = OSAllocatedUnfairLock<EngineStatus>(initialState: .stopped)
  private let observers = OSAllocatedUnfairLock<[UUID: (EngineStatus) -> Void]>(initialState: [:])

  /// Post-launch liveness probe loop ( G1). Owned by `stateQueue`:
  /// started when entering `.running`, cancelled when leaving it.
  private var livenessMonitor: Task<Void, Never>?

  /// Pending auto-relaunch task scheduled after `.failed(.engineGone)`.
  /// Owned by `stateQueue`; cancelled on user `start()`/`stop()` so a
  /// manual action wins over the ladder.
  private var autoRelaunchTask: Task<Void, Never>?

  /// Engine-gone attempt timestamps, pruned to the sliding window on
  /// every evaluation. Owned by `stateQueue`.
  private var autoRelaunchAttempts: [Date] = []

  /// Review v1 F2 — armed when entering `.running`, runs after
  /// `policy.healthyUptimeThreshold` and clears
  /// `autoRelaunchAttempts` so a sustained healthy engine re-arms
  /// the slow-flap cap. Cancelled on every transition off `.running`.
  /// Owned by `stateQueue`.
  private var healthyUptimeTask: Task<Void, Never>?

  /// Review v2 R3 — incarnation token for `healthyUptimeTask`.
  /// Incremented on every `armHealthyUptimeTimer` call; the timer's
  /// clear-block on `stateQueue` compares its captured value before
  /// touching `autoRelaunchAttempts`, so a stale timer that raced
  /// the post-sleep cancel guard cannot clear a fresh incarnation's
  /// attempt list. Same shape as the state-equality-vs-incarnation
  /// fix in the relaunch task (R1). Owned by `stateQueue`.
  private var healthyUptimeIncarnation: Int = 0

  private func setState(_ next: State) { _state = next }

  private func publish(_ status: EngineStatus) {
    statusLock.withLock { $0 = status }
    let snapshot = observers.withLock { Array($0.values) }
    for handler in snapshot { handler(status) }
  }

  private func doStart(_ spec: LaunchSpec) -> Result<Void, EngineError> {
    Log.engine.info("PieEngineHost: launching profile=\(spec.profileID, privacy: .public) binary=\(spec.pieBinary.path, privacy: .public)")
    // A start request — auto-ladder OR user-driven — supersedes any
    // pending backoff: cancel the timer task so we don't double-fire
    // a stale launch on top of the one we're about to queue (review:
    // race window between scheduleAutoRelaunchIfAllowed's sleep and
    // an external start arriving from HelperResumeAction or a test).
    autoRelaunchTask?.cancel()
    autoRelaunchTask = nil
    let profileID = spec.profileID
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runLaunch(spec: spec)
    }
    setState(.starting(profileID: profileID, launchTask: task))
    return .success(())
  }

  /// Body of the launch task. Lives outside `doStart` so it can hop
  /// back onto `stateQueue` for every transition.
  private func runLaunch(spec: LaunchSpec) async {
    do {
      let (port, session) = try await launcher(spec)
      stateQueue.async { [weak self] in
        guard let self else { return }
        switch self._state {
        case .starting:
          self.setState(.running(port: port, profileID: spec.profileID, session: session))
          self.startLivenessMonitor(session: session)
          self.armHealthyUptimeTimer()
        case .stopping:
          // stop() arrived after launch finished but before we hopped
          // back. Honour the cancellation by shutting the
          // freshly-launched session down.
          //
          // Review v1 F4: capture self weakly here. `session.shutdown`
          // can take up to ~15s; without [weak self] this inner Task
          // keeps the host alive long past any caller's release.
          Log.engine.info("PieEngineHost: launch completed during .stopping — shutting freshly-spawned session down")
          Task { [weak self, session] in
            await session.shutdown()
            self?.stateQueue.async {
              guard let self else { return }
              if case .stopping = self._state {
                self.setState(.stopped)
              }
            }
          }
        default:
          // Unexpected state (.stopped / .failed / .running) — discard.
          Log.engine.error("PieEngineHost: launch completed in unexpected state \(String(describing: self._state), privacy: .public); shutting session down")
          Task { [session] in await session.shutdown() }
        }
      }
    } catch is CancellationError {
      // PieControlLauncher.launch's catch paths already shut the
      // freshly-spawned session down on cancellation. Just publish
      // the terminal transition.
      stateQueue.async { [weak self] in
        guard let self else { return }
        switch self._state {
        case .starting, .stopping:
          self.setState(.stopped)
        default:
          // Review v1 F3: the success arm logs + shuts the session
          // down in this terminal-state branch; mirror the diagnostic
          // here so a future refactor that lets `.starting` be left
          // by some other path doesn't silently swallow the cancel.
          Log.engine.fault("PieEngineHost: launch cancelled in unexpected state \(String(describing: self._state), privacy: .public); dropping")
          return
        }
      }
    } catch {
      let msg = "\(error)"
      Log.engine.error("PieEngineHost: launch failed: \(msg, privacy: .public)")
      stateQueue.async { [weak self] in
        guard let self else { return }
        // Don't clobber a user-initiated stop with a launch error —
        // the cancellation winner already published .stopped.
        switch self._state {
        case .starting:
          self.setState(.failed(.spawnFailed, msg))
        case .stopping:
          self.setState(.stopped)
        default:
          // Review v1 F3: mirror the success-default's diagnostic.
          Log.engine.fault("PieEngineHost: launch error in unexpected state \(String(describing: self._state), privacy: .public): \(msg, privacy: .public); dropping")
          return
        }
      }
    }
  }

  private func stopLocked() {
    switch _state {
    case .stopped, .stopping:
      return
    case .failed(.engineGone, _):
      // Review v2 R1: a user Pause on `.failed(.engineGone)` is an
      // explicit "off" intent that MUST be honored before any
      // pending auto-relaunch can re-enter `start()`. The prior
      // implementation tried to ride a `Task.isCancelled` flag
      // through the relaunch task, but the task nils its own
      // handle inside `stateQueue.sync` before the commit (so a
      // subsequent `autoRelaunchTask?.cancel()` is a no-op) AND
      // the production relauncher hops via `DispatchQueue.main
      // .async` a runloop turn later — both paths defeated the
      // token. The robust signal is a state transition: move from
      // `.failed(.engineGone)` to `.stopped` here, so the relaunch
      // task's in-sync state check (see `scheduleAutoRelaunchIfAllowed`)
      // sees a mismatch and aborts BEFORE invoking `relauncher`,
      // and HelperMain's deferred main-async block re-checks
      // `engineHost.status` to close the post-sync race window.
      Log.engine.info("PieEngineHost: stop() on .failed(.engineGone) — transitioning to .stopped (user Pause)")
      autoRelaunchTask?.cancel()
      autoRelaunchTask = nil
      healthyUptimeTask?.cancel()
      healthyUptimeTask = nil
      // #394: an explicit user Pause is "off intent" — reset the
      // slow-flap death history so a later Resume starts the cap fresh.
      // Without this, a Pause → Resume → quick-death would inherit the
      // pre-Pause attempt count and could exhaust the ladder prematurely
      // (the healthy-uptime re-arm needs sustained `.running` the paused
      // user never reaches).
      autoRelaunchAttempts.removeAll()
      setState(.stopped)
      return
    case .failed(let code, _):
      // Non-engineGone failure codes carry no auto-relaunch ladder,
      // so the user-Pause race that motivates the `.engineGone` arm
      // above does not apply here. Stay `.failed` as a no-op —
      // `start()` accepts `.failed` as restartable, so the next
      // user Resume drives `doStart` directly.
      Log.engine.info("PieEngineHost: stop() no-op: already .failed(\(code.rawValue, privacy: .public))")
      return
    case .starting(_, let launchTask):
      // Cancel the launch task. PieControlLauncher.launch propagates
      // `CancellationError` on the next await point; its catch paths
      // shut the (possibly-spawned) session down. The launch task's
      // own state hop will publish `.stopped`.
      Log.engine.info("PieEngineHost: stop() cancelling in-flight launch")
      launchTask.cancel()
      healthyUptimeTask?.cancel()
      healthyUptimeTask = nil
      setState(.stopping(session: nil))
    case .running(_, _, let session):
      Log.engine.info("PieEngineHost: stop() shutting running session down (pid path)")
      livenessMonitor?.cancel()
      livenessMonitor = nil
      autoRelaunchTask?.cancel()
      autoRelaunchTask = nil
      healthyUptimeTask?.cancel()
      healthyUptimeTask = nil
      setState(.stopping(session: session))
      Task { [weak self, session] in
        await session.shutdown()
        self?.stateQueue.async {
          guard let self else { return }
          if case .stopping = self._state {
            self.setState(.stopped)
          }
        }
      }
    }
  }

  /// Start the post-launch liveness probe loop ( G1). Runs off
  /// `stateQueue`; each tick asks the session whether the engine is
  /// alive. After `livenessFailureThreshold` CONSECUTIVE `.gone`
  /// verdicts it hops back onto `stateQueue` and, only if still
  /// `.running`, transitions to `.failed(.engineGone, reason)` — the
  /// coded engine-gone signal the GUI surfaces through the existing
  /// `engineStatus()` poll. A single `.alive` resets the counter so a
  /// transient control-plane blip does not trigger a relaunch. This is
  /// detection only; reaping/relaunch is recovery (out of scope, → 
  /// for the rich reason).
  private func startLivenessMonitor(session: any EngineSession) {
    let interval = livenessInterval
    let threshold = livenessFailureThreshold
    guard interval > 0 else { return }
    livenessMonitor?.cancel()
    livenessMonitor = Task { [weak self] in
      var consecutiveGone = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        if Task.isCancelled { return }
        guard self != nil else { return }
        let liveness = await session.checkLiveness()
        if Task.isCancelled { return }
        switch liveness {
        case .alive:
          consecutiveGone = 0
        case .gone(let reason):
          consecutiveGone += 1
          guard consecutiveGone >= threshold else { continue }
          self?.stateQueue.async { [weak self] in
            guard let self else { return }
            guard case .running = self._state else { return }
            Log.engine.error("PieEngineHost: liveness monitor declared engine gone: \(reason, privacy: .public)")
            self.livenessMonitor = nil
            self.healthyUptimeTask?.cancel()
            self.healthyUptimeTask = nil
            self.setState(.failed(.engineGone, reason))
            self.scheduleAutoRelaunchIfAllowed(reason: reason)
          }
          return
        }
      }
    }
  }

  /// Review v1 F2 — arm a timer that clears
  /// `autoRelaunchAttempts` after the host has stayed `.running`
  /// continuously for `policy.healthyUptimeThreshold`. Caller must
  /// be on `stateQueue`. The timer is cancelled by any transition
  /// off `.running` (stop / liveness-gone / launcher failure), so
  /// only a SUSTAINED healthy engine re-arms the cap. The clear
  /// is whoever-driven: an auto-relaunch that stays healthy long
  /// enough qualifies just as well as a user-clicked Resume.
  private func armHealthyUptimeTimer() {
    let threshold = relaunchPolicy.healthyUptimeThreshold
    guard threshold > 0 else { return }
    guard relaunchPolicy.maxAttempts > 0 else { return }
    healthyUptimeIncarnation += 1
    let myIncarnation = healthyUptimeIncarnation
    healthyUptimeTask?.cancel()
    healthyUptimeTask = Task { [weak self, threshold, myIncarnation] in
      let nanos = UInt64(max(0, threshold) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      if Task.isCancelled { return }
      guard let self else { return }
      self.stateQueue.async { [weak self] in
        guard let self else { return }
        // Review v2 R3: a stale timer whose post-sleep cancel-check
        // raced a new `armHealthyUptimeTimer` (e.g. quick stop +
        // start back into `.running`) would otherwise clear the
        // FRESH incarnation's attempt list. The token comparison
        // here mirrors the state-equality-vs-incarnation pattern
        // in the relaunch task (R1) — only the timer whose
        // incarnation still matches owns the clear.
        guard self.healthyUptimeIncarnation == myIncarnation else { return }
        guard case .running = self._state else { return }
        guard !self.autoRelaunchAttempts.isEmpty else {
          self.healthyUptimeTask = nil
          return
        }
        Log.engine.notice("PieEngineHost: healthy uptime \(threshold, privacy: .public)s elapsed; clearing auto-relaunch attempts (was \(self.autoRelaunchAttempts.count, privacy: .public))")
        self.autoRelaunchAttempts.removeAll()
        self.healthyUptimeTask = nil
      }
    }
  }

  /// D2 — after the liveness monitor declared
  /// `.failed(.engineGone)`, schedule a bounded auto-relaunch attempt
  /// so an in-flight chat turn can be retried without an explicit user
  /// click. Caller must be on `stateQueue`. After the backoff elapses,
  /// invokes `relauncher` off-queue so it can re-enter `start(_:)`
  /// without re-entering `stateQueue.sync` from itself (deadlock).
  ///
  /// Slow-flap cap: more than `policy.maxAttempts` engine-gone events
  /// inside `policy.window` exhausts the ladder; the host stays
  /// `.failed(.engineGone)` until a sustained healthy `.running`
  /// re-arms the cap (review v1 F2 — counts deaths-without-healthy-
  /// recovery, so any recovery whose engine survives
  /// `policy.healthyUptimeThreshold` qualifies, whether driven by
  /// auto-relaunch or by an explicit user `start()`).
  private func scheduleAutoRelaunchIfAllowed(reason: String) {
    guard let relauncher else { return }
    guard relaunchPolicy.maxAttempts > 0 else { return }

    let now = clock()
    autoRelaunchAttempts.removeAll { now.timeIntervalSince($0) > relaunchPolicy.window }
    guard autoRelaunchAttempts.count < relaunchPolicy.maxAttempts else {
      Log.engine.error("PieEngineHost: auto-relaunch ladder exhausted (\(self.autoRelaunchAttempts.count, privacy: .public)/\(self.relaunchPolicy.maxAttempts, privacy: .public) inside \(self.relaunchPolicy.window, privacy: .public)s); leaving .failed(.engineGone) until a sustained healthy .running re-arms the cap (review v1 F2)")
      return
    }
    let attemptIndex = autoRelaunchAttempts.count
    autoRelaunchAttempts.append(now)
    let schedule = relaunchPolicy.backoffSchedule
    let backoff = schedule[min(attemptIndex, schedule.count - 1)]

    Log.engine.notice("PieEngineHost: scheduling auto-relaunch attempt \(attemptIndex + 1, privacy: .public)/\(self.relaunchPolicy.maxAttempts, privacy: .public) in \(backoff, privacy: .public)s (reason=\(reason, privacy: .public))")

    autoRelaunchTask?.cancel()
    autoRelaunchTask = Task { [weak self, relauncher, backoff] in
      let nanos = UInt64(max(0, backoff) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      if Task.isCancelled { return }
      guard let self else { return }

      // Confirm the host is still in the failed state we scheduled
      // for. Review v2 R1: the load-bearing signal here is the
      // engine STATE, not the cancellation token. `stopLocked`'s
      // `.failed(.engineGone)` arm transitions to `.stopped` on a
      // user Pause, so a state mismatch in this guard means "the
      // user paused while the backoff was running" — abort. A
      // `Task.isCancelled` re-check would be dead code (we nil the
      // handle inside this sync before the commit, so no later
      // `autoRelaunchTask?.cancel()` from `stopLocked` could ever
      // set the flag). The inside-sync `Task.isCancelled` covers
      // cancels that landed during the sleep but before the sync
      // hop; the post-sync race with HelperMain's deferred
      // `DispatchQueue.main.async` hop is closed by a second state
      // re-check inside that hop (see `HelperMain.swift`).
      let okToCommit = self.stateQueue.sync { () -> Bool in
        self.autoRelaunchTask = nil
        if Task.isCancelled { return false }
        if case .failed(.engineGone, _) = self._state { return true }
        return false
      }
      guard okToCommit else {
        Log.engine.info("PieEngineHost: auto-relaunch backoff completed but cancelled or state moved off .failed(.engineGone); skipping")
        return
      }
      Log.engine.info("PieEngineHost: auto-relaunch backoff elapsed; invoking relauncher")
      relauncher()
    }
  }

  // MARK: - Test seams

  /// Diagnostic-only attempt count for tests. Mirrors the rolling
  /// window the policy uses (entries older than `window` are pruned
  /// on access). Owned by `stateQueue`.
  internal var autoRelaunchAttemptsForTesting: Int {
    stateQueue.sync {
      let now = self.clock()
      self.autoRelaunchAttempts.removeAll { now.timeIntervalSince($0) > self.relaunchPolicy.window }
      return self.autoRelaunchAttempts.count
    }
  }
}

// MARK: - EngineSession liveness default

public extension PieEngineHost.EngineSession {
  /// Default: assume alive. Sessions that can observe engine death
  /// (the production `LaunchedSession`) override this; test fakes that
  /// only model shutdown inherit it so they never trip the monitor.
  func checkLiveness() async -> EngineLiveness { .alive }
  /// Default: memory unavailable. Only the production `LaunchedSession`
  /// samples real RSS; test fakes inherit nil.
  func residentMemoryBytes() async -> UInt64? { nil }
}
