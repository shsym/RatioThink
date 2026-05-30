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
    /// unavailable. Default nil (see extension) so test fakes that only
    /// model shutdown/liveness need no change; the production
    /// `LaunchedSession` overrides with a `proc_pid_rusage` sample of the
    /// pie pid.
    func residentMemoryBytes() async -> UInt64?
  }

  // MARK: - Init

  /// - Parameters:
  ///   - livenessInterval: cadence of the post-launch liveness probe
  ///     while `.running`. `<= 0` disables the monitor.
  ///   - livenessFailureThreshold: consecutive `.gone` probes required
  ///     before declaring `.failed(.engineGone)`. `> 1` tolerates a
  ///     transient control-plane blip without a spurious relaunch.
  public init(
    launcher: LauncherCall? = nil,
    livenessInterval: TimeInterval = 5,
    livenessFailureThreshold: Int = 2
  ) {
    self.launcher = launcher ?? PieEngineHost.productionLauncher
    self.livenessInterval = livenessInterval
    self.livenessFailureThreshold = max(1, livenessFailureThreshold)
  }

  private let launcher: LauncherCall
  private let livenessInterval: TimeInterval
  private let livenessFailureThreshold: Int

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
  /// when not running / unavailable. Hops onto `stateQueue` — the owner
  /// of `_state`, which carries the live session — to extract the
  /// session, then awaits its `proc_pid_rusage` sampler. Deliberately
  /// off the hot `status` path: callers read this on demand (status
  /// popover open), never per frame.
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

  private func setState(_ next: State) { _state = next }

  private func publish(_ status: EngineStatus) {
    statusLock.withLock { $0 = status }
    let snapshot = observers.withLock { Array($0.values) }
    for handler in snapshot { handler(status) }
  }

  private func doStart(_ spec: LaunchSpec) -> Result<Void, EngineError> {
    Log.engine.info("PieEngineHost: launching profile=\(spec.profileID, privacy: .public) binary=\(spec.pieBinary.path, privacy: .public)")
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
    case .failed(let code, _):
      // Review v1 F2: keep `.failed` as a no-op (start() accepts it
      // as restartable), but log so the user-visible "Pause click did
      // nothing" is explainable from the helper log.
      Log.engine.info("PieEngineHost: stop() no-op: already .failed(\(code.rawValue, privacy: .public))")
      return
    case .starting(_, let launchTask):
      // Cancel the launch task. PieControlLauncher.launch propagates
      // `CancellationError` on the next await point; its catch paths
      // shut the (possibly-spawned) session down. The launch task's
      // own state hop will publish `.stopped`.
      Log.engine.info("PieEngineHost: stop() cancelling in-flight launch")
      launchTask.cancel()
      setState(.stopping(session: nil))
    case .running(_, _, let session):
      Log.engine.info("PieEngineHost: stop() shutting running session down (pid path)")
      livenessMonitor?.cancel()
      livenessMonitor = nil
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
            self.setState(.failed(.engineGone, reason))
          }
          return
        }
      }
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
  /// overrides this with a real `proc_pid_rusage` sample.
  func residentMemoryBytes() async -> UInt64? { nil }
}
