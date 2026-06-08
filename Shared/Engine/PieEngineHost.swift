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

public struct EngineShutdownResult: Equatable, Sendable {
  public let reaped: Bool
  public let message: String

  public static let reaped = EngineShutdownResult(reaped: true, message: "")

  public static func unreaped(_ message: String) -> EngineShutdownResult {
    EngineShutdownResult(reaped: false, message: message)
  }

  public init(reaped: Bool, message: String = "") {
    self.reaped = reaped
    self.message = message
  }
}

public struct StopAndWaitResult: Equatable, Sendable {
  public enum Completion: Equatable, Sendable {
    case terminalReaped
    case terminalFailed
    case timedOut
  }

  public let completion: Completion
  public let lastStatus: EngineStatus

  public var reachedTerminal: Bool { completion == .terminalReaped }
  public var failedBeforeReap: Bool { completion == .terminalFailed }

  public init(completion: Completion, lastStatus: EngineStatus) {
    self.completion = completion
    self.lastStatus = lastStatus
  }
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
    case starting(profileID: String, launchID: UInt64, launchTask: Task<Void, Never>)
    case running(port: EnginePort, profileID: String, launchID: UInt64, session: any EngineSession)
    case stopping(session: (any EngineSession)?, launchID: UInt64?)
    case failed(EngineErrorCode, String)

    var publicStatus: EngineStatus {
      switch self {
      case .stopped:                                return .stopped
      case .starting:                               return .starting
      case .running(let port, let profileID, _, _): return .running(port: port, profileID: profileID)
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
    func shutdown() async -> EngineShutdownResult
    func shutdown(reason: String) async -> EngineShutdownResult
    func checkLiveness() async -> EngineLiveness
    func diagnosticProcessID() async -> pid_t?
    /// Resident memory of the live engine process in bytes, or nil when
    /// unavailable. Default nil (see extension) so test fakes that
    /// only model shutdown/liveness need no change; the production
    /// `LaunchedSession` overrides with a `proc_pid_rusage` sample of the
    /// pie pid.
    func residentMemoryBytes() async -> UInt64?
    /// Highest successful RSS sample observed during the child lifetime.
    /// Unlike `residentMemoryBytes()`, this may remain available after a
    /// fast exit/SIGKILL, when the dead process can no longer be sampled.
    func observedResidentMemoryBytes() async -> UInt64?
    /// Process-exit snapshot for the #447 termination classifier, or nil
    /// while the process is still alive (a control-plane hang → the host
    /// classifies `.livenessFailure`). Default nil so test fakes that only
    /// model shutdown/liveness need no change.
    func terminationSnapshot() async -> (reason: Process.TerminationReason, status: Int32)?
    /// Bounded, token-redacted tail of the engine's stdout/stderr for
    /// durable failure capture (#447). Default empty.
    func diagnosticTail() async -> [String]
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
  ///   - terminationSink: receives one `EngineTermination` per engine
  ///     death (#447). `nil` (default) emits nothing so existing tests
  ///     never pollute the real `helper.log`; production (HelperMain) wires
  ///     `PieEngineHost.productionTerminationSink`, tests inject a capture.
  ///   - tailWriter: receives the bounded, redacted stderr tail on death so
  ///     it can be persisted durably. `nil` (default) writes nothing;
  ///     production wires `PieEngineHost.productionTailWriter` (engine.log).
  ///   - guardrailBytes: the #328 resolved-artifact ceiling used for the
  ///     likely-OOM heuristic (SIGKILL-not-by-us + last-RSS >= ceiling).
  ///     `nil` (default) means OOM is never inferred; production passes
  ///     `ModelMemoryGuardrail.defaultPolicy.maxResolvedModelBytes`.
  ///   - launchTimeoutSlack: host-owned safety margin added to
  ///     `LaunchSpec.handshakeTimeout` before cancelling a launch that is
  ///     still `.starting`. This is scoped to the launch incarnation; once
  ///     the host reaches `.running`, the timer is cancelled / inert. The
  ///     XPC reply timeout is deliberately separate and never owns process
  ///     lifetime.
  public init(
    launcher: LauncherCall? = nil,
    livenessInterval: TimeInterval = 5,
    livenessFailureThreshold: Int = 2,
    relaunchPolicy: RelaunchPolicy = RelaunchPolicy(),
    relauncher: Relauncher? = nil,
    terminationSink: (@Sendable (EngineTermination) -> Void)? = nil,
    tailWriter: (@Sendable ([String]) -> Void)? = nil,
    guardrailBytes: Int64? = nil,
    launchTimeoutSlack: TimeInterval = PieEngineHost.defaultLaunchTimeoutSlack,
    clock: @Sendable @escaping () -> Date = { Date() },
    // Default: a real cooperative sleep that swallows cancellation, exactly
    // matching the inline `try? await Task.sleep` the three timers used
    // before the seam existed — so production behaviour is unchanged.
    sleepFor: @Sendable @escaping (TimeInterval) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
  ) {
    self.launcher = launcher ?? PieEngineHost.productionLauncher
    self.livenessInterval = livenessInterval
    self.livenessFailureThreshold = max(1, livenessFailureThreshold)
    self.relaunchPolicy = relaunchPolicy
    self.relauncher = relauncher
    self.terminationSink = terminationSink
    self.tailWriter = tailWriter
    self.guardrailBytes = guardrailBytes
    self.launchTimeoutSlack = max(0, launchTimeoutSlack)
    self.clock = clock
    self.sleepFor = sleepFor
  }

  private let launcher: LauncherCall
  private let livenessInterval: TimeInterval
  private let livenessFailureThreshold: Int
  private let relaunchPolicy: RelaunchPolicy
  private let relauncher: Relauncher?
  private let terminationSink: (@Sendable (EngineTermination) -> Void)?
  private let tailWriter: (@Sendable ([String]) -> Void)?
  private let guardrailBytes: Int64?

  /// Production breadcrumb sink: one durable, chat-free `engine.terminated`
  /// line per death in `helper.log` (via `DiagnosticLog`). Wired by
  /// HelperMain so tests stay free of real-dir writes.
  public static let productionTerminationSink: @Sendable (EngineTermination) -> Void = {
    Diag.helper.event("engine.terminated", $0.diagnosticFields)
  }

  /// Production tail writer: tee the bounded, redacted engine stderr tail to
  /// `engine.log` so the failure output survives in the diagnostics bundle.
  /// Offloaded to its own serial queue (mirroring `DiagnosticLog.event`) so a
  /// death-time file write never blocks `stateQueue` — important precisely in
  /// the OOM/memory-pressure case, where the disk may be stalled. Production
  /// resolves the dir from `$PIE_HOME` (env, thread-safe), so running off the
  /// caller thread is safe; tests inject a capturing writer instead.
  public static let productionTailWriter: @Sendable ([String]) -> Void = { lines in
    tailWriteQueue.async { EngineLogTail.append(lines) }
  }
  private static let tailWriteQueue = DispatchQueue(label: "com.ratiothink.engine.logtail")
  /// Default host-owned safety margin added to `LaunchSpec.handshakeTimeout`
  /// to form the launch lease. Public + named so the cross-layer timeout
  /// ladder (engine lease < helper reply deadline < App restart wait) can be
  /// asserted from one source (#459 review F2).
  public static let defaultLaunchTimeoutSlack: TimeInterval = 2
  private let launchTimeoutSlack: TimeInterval

  /// Wall-clock source for the slow-flap window math, injectable so a
  /// test can advance time deterministically instead of sleeping —
  /// the window prune is otherwise racy against the real liveness and
  /// backoff timers. Defaults to `Date()` (production + existing
  /// callers unaffected).
  private let clock: @Sendable () -> Date

  /// Suspension seam shared by the liveness-poll cadence, the
  /// auto-relaunch backoff, and the healthy-uptime re-arm timer.
  /// Production sleeps for real (the default argument in `init`); a
  /// deterministic test injects an immediate (or virtual-clock) sleep so
  /// the death/relaunch cycle carries zero wall-clock dependence and
  /// cannot race the injected `clock`'s window math. The default is
  /// behaviour-identical to the prior inline `try? await Task.sleep`.
  private let sleepFor: @Sendable (TimeInterval) async -> Void

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
      if case let .running(_, _, _, session) = _state { return session }
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

  /// Start the engine, or attach to the existing same-profile
  /// `.starting`/`.running` incarnation. This is deliberately narrower than
  /// `start(_:)`: XPC `startEngine` is idempotent for repeated same-profile
  /// requests, but explicit caller intents such as menu Resume still use
  /// `start(_:)` so duplicate user/system starts surface `.alreadyRunning`.
  @discardableResult
  public func startOrAttach(_ spec: LaunchSpec) -> Result<Void, EngineError> {
    stateQueue.sync {
      switch _state {
      case .stopped, .failed:
        return doStart(spec)
      case .starting(let profileID, _, _) where profileID == spec.profileID:
        DiagnosticLog.helper.event("engine.start.request", [
          ("profile", spec.profileID),
          ("state", "starting"),
          ("action", "attach_existing"),
        ])
        return .success(())
      case .running(_, let profileID, _, _) where profileID == spec.profileID:
        DiagnosticLog.helper.event("engine.start.request", [
          ("profile", spec.profileID),
          ("state", "running"),
          ("action", "already_running_same_profile"),
        ])
        return .success(())
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
  ///
  /// `initiator` (#447) records WHO requested the stop so the durable
  /// breadcrumb can tell an operator pause (`.user`, the default for the
  /// XPC `stopEngine` selector) from a helper process shutting the engine
  /// down on its way out (`.helper`, passed by `applicationWillTerminate`).
  public func stop(initiator: EngineTermination.Initiator = .user) {
    stop(reason: "unspecified", initiator: initiator)
  }

  /// Stop the engine with a durable non-content diagnostic reason. Callers that
  /// represent explicit user/system intent should use this overload so
  /// helper.log can separate user Pause, XPC Unload, app/helper termination,
  /// and timeout fallback from organic engine death.
  public func stop(reason: String, initiator: EngineTermination.Initiator = .user) {
    stateQueue.sync {
      stopLocked(reason: reason, initiator: initiator)
    }
  }

  /// #448 quit primitive: `stop()` the engine and invoke `completion`
  /// exactly once with a result that distinguishes a real terminal state
  /// (`.stopped`) from shutdown failure and the timeout fallback. `.stopped`
  /// is published only AFTER `LaunchedSession.shutdown` (SIGINT → grace →
  /// SIGKILL) confirms the `pie` process was reaped; unreaped shutdowns are
  /// surfaced as `.failed(.killRejected, ...)` and return
  /// `failedBeforeReap == true`, so callers that promise a no-orphan
  /// structured quit must require `result.reachedTerminal == true` before
  /// reporting success. The bounded fallback keeps callers observable when the
  /// engine wedges instead of silently conflating timeout with reap.
  /// `completion` fires on `stateQueue` (terminal path) or a global queue
  /// (timeout).
  public func stopAndWait(timeout: TimeInterval, completion: @escaping @Sendable (StopAndWaitResult) -> Void) {
    let done = OSAllocatedUnfairLock<Bool>(initialState: false)
    let tokenBox = OSAllocatedUnfairLock<ObservationToken?>(initialState: nil)
    func cancelObserver() {
      tokenBox.withLock { (box: inout ObservationToken?) in
        box?.cancel()
        box = nil
      }
    }
    func finish(_ result: StopAndWaitResult) {
      let already = done.withLock { (d: inout Bool) -> Bool in
        defer { d = true }
        return d
      }
      cancelObserver()
      if already { return }
      completion(result)
    }
    // observe() dispatches the CURRENT status synchronously on stateQueue, so
    // an already-terminal host fires `finish()` immediately.
    let token = observe { status, _ in
      switch status {
      case .stopped, .failed:
        let completion: StopAndWaitResult.Completion
        if case .failed(.killRejected, _) = status {
          completion = .terminalFailed
        } else {
          completion = .terminalReaped
        }
        finish(StopAndWaitResult(completion: completion, lastStatus: status))
      case .starting, .running, .stopping: return
      }
    }
    tokenBox.withLock { $0 = token }
    if done.withLock({ $0 }) { cancelObserver() }
    stop()
    if timeout > 0 {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
        finish(StopAndWaitResult(completion: .timedOut, lastStatus: self?.status ?? .failed(
          code: .unknown,
          message: "PieEngineHost deallocated before stopAndWait timeout sampled status"
        )))
      }
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

  /// Host-owned launch timeout. This is the process-lifetime lease for a
  /// not-yet-running engine; XPC reply fallbacks must never call `stop()`.
  /// Owned by `stateQueue` and guarded by `launchIncarnation` so a stale timer
  /// can only cancel the same still-starting launch it was armed for.
  private var launchTimeoutTask: Task<Void, Never>?
  private var launchIncarnation: UInt64 = 0

  private enum LaunchCancellationReason {
    case handshakeTimeout(profileID: String, timeout: TimeInterval)

    var shutdownReason: String {
      switch self {
      case .handshakeTimeout: return "engine.launchTimeout"
      }
    }

    var failureMessage: String {
      switch self {
      case let .handshakeTimeout(profileID, timeout):
        return "engine launch timed out after \(String(format: "%.1f", timeout))s while starting profile \(profileID)"
      }
    }

    var termination: EngineTermination {
      switch self {
      case .handshakeTimeout:
        return EngineTermination(cause: .handshakeTimeout, initiator: .launch)
      }
    }
  }

  /// Launch cancellations whose terminal state must wait for launcher-owned
  /// cleanup/reap. Keyed by launch incarnation so stale completions cannot
  /// settle a newer start/stop.
  private var pendingLaunchCancellations: [UInt64: LaunchCancellationReason] = [:]

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
    launchIncarnation &+= 1
    let launchID = launchIncarnation
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runLaunch(spec: spec, launchID: launchID)
    }
    setState(.starting(profileID: profileID, launchID: launchID, launchTask: task))
    armLaunchTimeout(profileID: profileID, launchID: launchID, timeout: spec.handshakeTimeout + launchTimeoutSlack)
    return .success(())
  }

  private func armLaunchTimeout(profileID: String,
                                launchID: UInt64,
                                timeout: TimeInterval) {
    let sleepFor = self.sleepFor
    launchTimeoutTask?.cancel()
    launchTimeoutTask = Task { [weak self, timeout, launchID, profileID, sleepFor] in
      await sleepFor(timeout)
      if Task.isCancelled { return }
      guard let self else { return }
      self.stateQueue.async { [weak self] in
        guard let self else { return }
        guard case .starting(let currentProfileID, let currentLaunchID, let currentTask) = self._state else {
          DiagnosticLog.helper.event("engine.launch_timeout", [
            ("profile", profileID),
            ("launch_id", String(launchID)),
            ("state", String(describing: self._state)),
            ("action", "stale_noop_not_starting"),
          ])
          return
        }
        guard currentLaunchID == launchID else {
          DiagnosticLog.helper.event("engine.launch_timeout", [
            ("profile", profileID),
            ("launch_id", String(launchID)),
            ("current_launch_id", String(currentLaunchID)),
            ("state", String(describing: self._state)),
            ("action", "stale_noop_new_launch"),
          ])
          return
        }
        DiagnosticLog.helper.event("engine.shutdown.request", [
          ("reason", "engine.launchTimeout"),
          ("profile", currentProfileID),
          ("launch_id", String(currentLaunchID)),
          ("state", "starting"),
          ("action", "cancel_starting"),
          ("timeout", String(format: "%.1f", timeout)),
        ])
        self.launchTimeoutTask = nil
        self.pendingLaunchCancellations[currentLaunchID] = .handshakeTimeout(
          profileID: currentProfileID,
          timeout: timeout)
        currentTask.cancel()
        self.setState(.stopping(session: nil, launchID: currentLaunchID))
      }
    }
  }

  /// Body of the launch task. Lives outside `doStart` so it can hop
  /// back onto `stateQueue` for every transition.
  private func runLaunch(spec: LaunchSpec, launchID: UInt64) async {
    do {
      let (port, session) = try await launcher(spec)
      stateQueue.async { [weak self] in
        guard let self else { return }
        switch self._state {
        case .starting(let currentProfileID, let currentLaunchID, _)
          where currentProfileID == spec.profileID && currentLaunchID == launchID:
          self.launchTimeoutTask?.cancel()
          self.launchTimeoutTask = nil
          self.setState(.running(port: port, profileID: spec.profileID, launchID: launchID, session: session))
          self.startLivenessMonitor(session: session)
          self.armHealthyUptimeTimer()
        case .stopping(_, let stoppingLaunchID) where stoppingLaunchID == launchID:
          // stop() arrived after launch finished but before we hopped back,
          // or the host-owned launch timeout moved the launch into
          // `.stopping` while waiting for cleanup. Honour the cancellation by
          // shutting the freshly-launched session down.
          //
          // Review v1 F4: capture self weakly here. `session.shutdown`
          // can take up to ~15s; without [weak self] this inner Task
          // keeps the host alive long past any caller's release.
          Log.engine.info("PieEngineHost: launch completed during .stopping — shutting freshly-spawned session down")
          Task { [weak self, session] in
            let reason = self?.stateQueue.sync { [weak self] in
              guard let self else { return nil }
              return self.pendingLaunchCancellations[launchID]?.shutdownReason
            } ?? "host.launch_completed_during_stopping"
            let shutdownResult = await session.shutdown(reason: reason)
            let tail = await session.diagnosticTail()
            self?.stateQueue.async {
              guard let self else { return }
              if case .stopping(_, let currentLaunchID) = self._state,
                 currentLaunchID == launchID {
                if let cancellation = self.pendingLaunchCancellations.removeValue(forKey: launchID) {
                  self.finishLaunchCancellation(
                    cancellation,
                    shutdownResult: shutdownResult,
                    tail: tail)
                } else {
                  self.setState(Self.stateAfterShutdown(shutdownResult))
                }
              }
            }
          }
        default:
          // Stale completion from an older launch incarnation (or an
          // otherwise unexpected state) must not publish `.running` over a
          // newer `.starting` retry. Discard only the session this launch
          // returned.
          Log.engine.error("PieEngineHost: launch completed in unexpected/stale state \(String(describing: self._state), privacy: .public) launchID=\(launchID, privacy: .public); shutting session down")
          Task { [session] in _ = await session.shutdown(reason: "host.launch_completed_stale_or_unexpected_state") }
        }
      }
    } catch is CancellationError {
      // PieControlLauncher.launch's catch paths already shut the
      // freshly-spawned session down on cancellation. Just publish
      // the terminal transition.
      stateQueue.async { [weak self] in
        guard let self else { return }
        switch self._state {
        case .starting(let currentProfileID, let currentLaunchID, _)
          where currentProfileID == spec.profileID && currentLaunchID == launchID:
          self.launchTimeoutTask?.cancel()
          self.launchTimeoutTask = nil
          self.pendingLaunchCancellations.removeValue(forKey: launchID)
          self.setState(.stopped)
        case .stopping(_, let stoppingLaunchID) where stoppingLaunchID == launchID:
          self.launchTimeoutTask?.cancel()
          self.launchTimeoutTask = nil
          if let cancellation = self.pendingLaunchCancellations.removeValue(forKey: launchID) {
            self.finishLaunchCancellation(cancellation, shutdownResult: .reaped, tail: [])
          } else {
            self.setState(.stopped)
          }
        default:
          // Review v1 F3: the success arm logs + shuts the session
          // down in this terminal-state branch; mirror the diagnostic
          // here so a future refactor that lets `.starting` be left
          // by some other path doesn't silently swallow the cancel.
          Log.engine.fault("PieEngineHost: launch cancelled in unexpected/stale state \(String(describing: self._state), privacy: .public) launchID=\(launchID, privacy: .public); dropping")
          return
        }
      }
    } catch {
      let msg = "\(error)"
      Log.engine.error("PieEngineHost: launch failed: \(msg, privacy: .public)")
      let terminationEvidence = Self.terminationForLaunchError(error, guardrailBytes: guardrailBytes)
      let shutdownFailureMessage = Self.shutdownFailureMessage(from: error)
      let launchCancellationEvidence = Self.launchCancellationEvidence(from: error)
      stateQueue.async { [weak self] in
        guard let self else { return }
        // Don't clobber a user-initiated stop with a launch error —
        // the cancellation winner already published .stopped.
        switch self._state {
        case .starting(let currentProfileID, let currentLaunchID, _)
          where currentProfileID == spec.profileID && currentLaunchID == launchID:
          self.launchTimeoutTask?.cancel()
          self.launchTimeoutTask = nil
          self.pendingLaunchCancellations.removeValue(forKey: launchID)
          if let shutdownFailureMessage {
            self.setState(.failed(.killRejected, shutdownFailureMessage))
          } else {
            self.setState(.failed(.spawnFailed, msg))
          }
          if let (termination, tail) = terminationEvidence {
            self.emitTermination(termination, tail: tail)
          }
        case .stopping(_, let stoppingLaunchID) where stoppingLaunchID == launchID:
          self.launchTimeoutTask?.cancel()
          self.launchTimeoutTask = nil
          let cancellation = self.pendingLaunchCancellations.removeValue(forKey: launchID)
          if let cancellation, let launchCancellationEvidence {
            self.finishLaunchCancellation(
              cancellation,
              shutdownResult: launchCancellationEvidence.shutdownResult,
              tail: launchCancellationEvidence.tail)
          } else if let cancellation, let (_, tail) = terminationEvidence {
            self.finishLaunchCancellation(cancellation, shutdownResult: .reaped, tail: tail)
          } else if let launchCancellationEvidence {
            self.setState(Self.stateAfterShutdown(launchCancellationEvidence.shutdownResult))
          } else if let shutdownFailureMessage {
            self.setState(.failed(.killRejected, shutdownFailureMessage))
          } else if let cancellation {
            self.finishLaunchCancellation(cancellation, shutdownResult: .reaped, tail: [])
          } else {
            self.setState(.stopped)
          }
        default:
          // Review v1 F3: mirror the success-default's diagnostic.
          Log.engine.fault("PieEngineHost: launch error in unexpected/stale state \(String(describing: self._state), privacy: .public) launchID=\(launchID, privacy: .public): \(msg, privacy: .public); dropping")
          return
        }
      }
    }
  }

  private static func shutdownFailureMessage(from error: Error) -> String? {
    guard case let PieControlLauncher.LaunchError.shutdownFailed(_, shutdownFailure) = error else {
      return nil
    }
    return shutdownFailure.isEmpty
      ? "pie shutdown failed before the process was confirmed reaped"
      : shutdownFailure
  }

  private static func launchCancellationEvidence(
    from error: Error
  ) -> (shutdownResult: EngineShutdownResult, tail: [String])? {
    guard case let PieControlLauncher.LaunchError.launchCancelledAfterCleanup(
      shutdownResult,
      lastLines
    ) = error else {
      return nil
    }
    return (shutdownResult, lastLines)
  }

  private func finishLaunchCancellation(_ reason: LaunchCancellationReason,
                                        shutdownResult: EngineShutdownResult,
                                        tail: [String]) {
    guard shutdownResult.reaped else {
      setState(Self.stateAfterShutdown(shutdownResult))
      return
    }
    setState(.failed(.handshakeTimeout, reason.failureMessage))
    emitTermination(reason.termination, tail: tail)
  }

  private func stopLocked(reason: String, initiator: EngineTermination.Initiator) {
    // One chat-free stop breadcrumb recording WHO ended a live/launching
    // engine (#447). Only the `.starting`/`.running` arms below reach this —
    // the `.failed(.engineGone)` arm was already recorded by the liveness
    // monitor, and the no-op arms have nothing to stop.
    func recordStop() {
      let t = EngineTermination.classify(
        reason: nil, status: nil, initiator: initiator,
        lastRSSBytes: nil, guardrailBytes: guardrailBytes)
      emitTermination(t, tail: [])
    }
    switch _state {
    case .stopped, .stopping:
      DiagnosticLog.helper.event("engine.shutdown.request", [
        ("reason", reason),
        ("state", String(describing: _state)),
        ("action", "noop"),
      ])
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
      DiagnosticLog.helper.event("engine.shutdown.request", [
        ("reason", reason),
        ("state", String(describing: _state)),
        ("action", "clear_failed_engineGone"),
      ])
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
      DiagnosticLog.helper.event("engine.shutdown.request", [
        ("reason", reason),
        ("state", String(describing: _state)),
        ("action", "noop_failed"),
        ("code", code.rawValue),
      ])
      return
    case .starting(_, let launchID, let launchTask):
      // Cancel the launch task. PieControlLauncher.launch propagates
      // `CancellationError` on the next await point; its catch paths
      // shut the (possibly-spawned) session down. The launch task's
      // own state hop will publish `.stopped`.
      Log.engine.info("PieEngineHost: stop() cancelling in-flight launch")
      DiagnosticLog.helper.event("engine.shutdown.request", [
        ("reason", reason),
        ("state", String(describing: _state)),
        ("action", "cancel_starting"),
      ])
      launchTask.cancel()
      launchTimeoutTask?.cancel()
      launchTimeoutTask = nil
      healthyUptimeTask?.cancel()
      healthyUptimeTask = nil
      recordStop()
      setState(.stopping(session: nil, launchID: launchID))
    case .running(_, _, let launchID, let session):
      Log.engine.info("PieEngineHost: stop() shutting running session down (pid path)")
      recordStop()
      DiagnosticLog.helper.event("engine.shutdown.request", [
        ("reason", reason),
        ("state", "running"),
        ("action", "shutdown_session"),
      ])
      Task { [session, reason] in
        let pid = await session.diagnosticProcessID()
        DiagnosticLog.helper.event("engine.shutdown.request", [
          ("reason", reason),
          ("state", "running"),
          ("action", "shutdown_session"),
          ("pid", pid.map(String.init) ?? "?"),
        ])
      }
      livenessMonitor?.cancel()
      livenessMonitor = nil
      autoRelaunchTask?.cancel()
      autoRelaunchTask = nil
      healthyUptimeTask?.cancel()
      healthyUptimeTask = nil
      setState(.stopping(session: session, launchID: launchID))
      Task { [weak self, session, reason] in
        let shutdownResult = await session.shutdown(reason: reason)
        self?.stateQueue.async {
          guard let self else { return }
          if case .stopping(_, let currentLaunchID) = self._state,
             currentLaunchID == launchID {
            self.setState(Self.stateAfterShutdown(shutdownResult))
          }
        }
      }
    }
  }

  private static func stateAfterShutdown(_ result: EngineShutdownResult) -> State {
    if result.reaped { return .stopped }
    return .failed(
      .killRejected,
      result.message.isEmpty
        ? "pie shutdown did not confirm the process was reaped"
        : result.message
    )
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
    let sleepFor = self.sleepFor
    guard interval > 0 else { return }
    livenessMonitor?.cancel()
    let guardrail = guardrailBytes
    livenessMonitor = Task { [weak self, sleepFor] in
      var consecutiveGone = 0
      // Highest successful RSS sample from this child lifetime. Sample
      // immediately rather than waiting for the first `.alive` tick: early
      // model-load SIGKILL/OOM happens before a slow liveness interval can
      // observe a healthy process.
      var maxRSS = await session.residentMemoryBytes()
      while !Task.isCancelled {
        await sleepFor(interval)
        if Task.isCancelled { return }
        guard self != nil else { return }
        let started = Date()
        let liveness = await session.checkLiveness()
        let elapsed = Date().timeIntervalSince(started)
        if Task.isCancelled { return }
        switch liveness {
        case .alive:
          consecutiveGone = 0
          maxRSS = Self.maxRSS(maxRSS, await session.residentMemoryBytes())
          maxRSS = Self.maxRSS(maxRSS, await session.observedResidentMemoryBytes())
        case .gone(let reason):
          consecutiveGone += 1
          let pid = await session.diagnosticProcessID()
          // #413 diag: a `.gone` verdict from the control-plane ping while the
          // engine is BUSY (not dead) would falsely restart it mid-search and
          // close the in-flight ToT SSE. Persist every miss + its reason so the
          // operator's run shows whether (and why) the monitor fired.
          DiagnosticLog.helper.event("engine.liveness", [
            ("verdict", "gone"),
            ("pid", pid.map(String.init) ?? "?"),
            ("elapsed", String(format: "%.2f", elapsed)),
            ("consecutive", String(consecutiveGone)),
            ("threshold", String(threshold)),
            ("reason", reason),
          ])
          guard consecutiveGone >= threshold else { continue }
          // Gather the authoritative exit evidence in the async context
          // BEFORE hopping to stateQueue (these are actor-isolated awaits).
          // snapshot == nil ⇒ the process is still alive but the control
          // plane is unreachable ⇒ a liveness failure, not a self-death.
          let snapshot = await session.terminationSnapshot()
          maxRSS = Self.maxRSS(maxRSS, await session.residentMemoryBytes())
          maxRSS = Self.maxRSS(maxRSS, await session.observedResidentMemoryBytes())
          let tail = await session.diagnosticTail()
          let termination = EngineTermination.classify(
            reason: snapshot?.reason, status: snapshot?.status,
            initiator: snapshot == nil ? .liveness : .engine,
            lastRSSBytes: maxRSS, guardrailBytes: guardrail)
          self?.stateQueue.async { [weak self] in
            guard let self else { return }
            guard case .running = self._state else { return }
            Log.engine.error("PieEngineHost: liveness monitor declared engine gone (cause=\(termination.cause.rawValue, privacy: .public)): \(reason, privacy: .public)")
            DiagnosticLog.helper.event("engine.gone", [
              ("pid", pid.map(String.init) ?? "?"),
              ("reason", reason),
              ("consecutive", String(consecutiveGone)),
            ])
            self.livenessMonitor = nil
            self.healthyUptimeTask?.cancel()
            self.healthyUptimeTask = nil
            self.setState(.failed(.engineGone, reason))
            self.emitTermination(termination, tail: tail)
            self.scheduleAutoRelaunchIfAllowed(reason: reason)
          }
          return
        }
      }
    }
  }

  /// Fan the captured #447 death evidence out to the durable sinks: one
  /// chat-free breadcrumb + the bounded redacted stderr tail. Both are
  /// no-ops when unwired (tests / non-production hosts). Caller is on
  /// `stateQueue`; the sinks are best-effort and never throw.
  private func emitTermination(_ termination: EngineTermination, tail: [String]) {
    terminationSink?(termination)
    if !tail.isEmpty { tailWriter?(tail) }
  }

  /// Map only engine-death launch-task failures to termination evidence. A
  /// pre-handshake self-death (`engineExitedEarly`) classifies by the real
  /// `(reason, status)` — so a launch-time segfault is still a segfault —
  /// while a handshake timeout is OUR kill of an alive-but-silent engine
  /// (`cause = .handshakeTimeout`), never read as a crash. Setup failures
  /// (missing binary/config/driver/path/client setup) are not engine deaths
  /// and intentionally return nil.
  private static func terminationForLaunchError(
    _ error: Error, guardrailBytes: Int64?) -> (EngineTermination, [String])? {
    guard let le = error as? PieControlLauncher.LaunchError else {
      return nil
    }
    switch le {
    case let .engineExitedEarly(code, reason, stderrTail, rssBytes):
      let t = EngineTermination.classify(
        reason: reason, status: code, initiator: .launch,
        lastRSSBytes: rssBytes, guardrailBytes: guardrailBytes)
      return (t, splitTail(stderrTail))
    case let .handshakeTimeout(_, lastLines):
      return (EngineTermination(cause: .handshakeTimeout, initiator: .launch), lastLines)
    default:
      return nil
    }
  }

  private static func maxRSS(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
    switch (lhs, rhs) {
    case let (l?, r?): return max(l, r)
    case let (l?, nil): return l
    case let (nil, r?): return r
    case (nil, nil): return nil
    }
  }

  private static func splitTail(_ joined: String) -> [String] {
    joined.isEmpty ? [] : joined.components(separatedBy: "\n")
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
    let sleepFor = self.sleepFor
    healthyUptimeTask?.cancel()
    healthyUptimeTask = Task { [weak self, threshold, myIncarnation, sleepFor] in
      await sleepFor(threshold)
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
    // #413 diag: a relaunch kills + respawns the engine — if this fires during
    // a ToT search the in-flight SSE closes with no terminal. Persist it so the
    // operator's run lines this up against the chat.fail.tot timestamp.
    DiagnosticLog.helper.event("engine.relaunch", [
      ("attempt", String(attemptIndex + 1)),
      ("backoff", String(format: "%.1f", backoff)),
      ("reason", reason),
    ])

    let sleepFor = self.sleepFor
    autoRelaunchTask?.cancel()
    autoRelaunchTask = Task { [weak self, relauncher, backoff, sleepFor] in
      await sleepFor(backoff)
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
  /// Default: reason-aware shutdown collapses to the legacy shutdown for fakes.
  func shutdown(reason: String) async -> EngineShutdownResult { await shutdown() }
  /// Default: assume alive. Sessions that can observe engine death
  /// (the production `LaunchedSession`) override this; test fakes that
  /// only model shutdown inherit it so they never trip the monitor.
  func checkLiveness() async -> EngineLiveness { .alive }
  /// Default: no process identity. Production sessions override this so
  /// lifecycle diagnostics can correlate liveness misses, exits, and relaunches.
  func diagnosticProcessID() async -> pid_t? { nil }
  /// Default: memory unavailable. Only the production `LaunchedSession`
  /// samples real RSS; test fakes inherit nil.
  func residentMemoryBytes() async -> UInt64? { nil }
  /// Default: no lifetime RSS sample has been recorded.
  func observedResidentMemoryBytes() async -> UInt64? { nil }
  /// Default: no exit snapshot. The production `LaunchedSession` overrides
  /// with the real `(terminationReason, terminationStatus)` (#447).
  func terminationSnapshot() async -> (reason: Process.TerminationReason, status: Int32)? { nil }
  /// Default: no tail. The production `LaunchedSession` overrides with its
  /// bounded, token-redacted recent lines (#447).
  func diagnosticTail() async -> [String] { [] }
}
