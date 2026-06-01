import Foundation
import os

/// Spawns and supervises the bundled `pie` engine subprocess on behalf
/// of RatioThinkHelper.
///
/// Responsibilities (per design doc §3 + Phase 2.2 work):
///  · Spawn `RatioThink.app/Contents/Resources/pie-engine/pie` with arguments
///    derived from the active `Profile`.
///  · Capture the `HTTP_LISTEN=host:port\n` handshake line written to
///    stdout. Transition to `.running(port, profileID)` once captured.
///  · Tee stdout + stderr to `~/Library/Application Support/RatioThink/logs/engine.log`.
///  · On unexpected exit, restart with exponential backoff (default
///    3 tries / 30s window). After exhaustion, transition to
///    `.failed(.spawnFailed, reason)` and surface to the menu bar dot
///    via `engineStatus`.
///
/// Concurrency model:
///  · `stateQueue` (serial) owns every state transition. Pipe
///    `readabilityHandler` closures and `Process.terminationHandler`
///    fire on arbitrary queues and hop onto `stateQueue` before
///    mutating state.
///  · `logQueue` (serial) owns the append-only `engine.log`
///    FileHandle. Both pipes route their bytes through it so the file
///    is written from exactly one thread.
///  · `_status` lives behind an `OSAllocatedUnfairLock` so
///    `var status` reads do not have to bounce through `stateQueue`
///    (which is critical for the XPC engineStatus selector — it can be
///    invoked from any peer queue and must never deadlock the
///    supervisor's own state path).
public final class PieSupervisor: @unchecked Sendable {

  // MARK: - LaunchSpec

  /// Inputs the supervisor needs to spawn one engine instance. Built
  /// by the caller (Phase 2.4 wires this in `HelperExportedAPI` from
  /// the active profile + bundled resources); the supervisor does not
  /// reach into `ProfileStore` itself so this file stays unit-testable
  /// with shell-script fakes.
  public struct LaunchSpec: Sendable, Equatable {
    public var binaryURL: URL
    public var modelPath: String
    public var inferletDir: URL
    /// Inferlet identifier the engine should activate after spawn —
    /// mirrors `Profile.inferlet` (review v2 F7). Required: dropping
    /// it on the floor used to silently bind every profile to the
    /// engine's auto-selected default, masking a second inferlet
    /// shipping under a different profile.
    public var inferletName: String
    public var profileID: String
    public var httpListenHost: String
    /// Profile-driven extra args appended verbatim after the
    /// canonical `--model / --http-listen / --inferlet-dir / --inferlet`
    /// quadruple. Phase 2.2 does not consume any; reserved for future
    /// profile fields (system prompt, sampling) that pie surfaces as
    /// flags.
    public var extraArgs: [String]
    /// Environment overlaid on top of `ProcessInfo` env for the child.
    /// Used by tests to scope PIE_HOME / PIE_TEST_MODE per case.
    public var extraEnvironment: [String: String]

    public init(binaryURL: URL,
                modelPath: String,
                inferletDir: URL,
                inferletName: String,
                profileID: String,
                httpListenHost: String = "127.0.0.1",
                extraArgs: [String] = [],
                extraEnvironment: [String: String] = [:]) {
      self.binaryURL = binaryURL
      self.modelPath = modelPath
      self.inferletDir = inferletDir
      self.inferletName = inferletName
      self.profileID = profileID
      self.httpListenHost = httpListenHost
      self.extraArgs = extraArgs
      self.extraEnvironment = extraEnvironment
    }

    /// Canonical argv per design doc §3 first-launch flow:
    ///   `pie --model <path> --http-listen <host>:0 --inferlet-dir <dir> --inferlet <name>`
    /// `:0` asks the OS for a free port; the engine prints the bound
    /// port back via the `HTTP_LISTEN=` handshake. `extraArgs` is
    /// appended verbatim.
    public func arguments() -> [String] {
      var args: [String] = [
        "--model", modelPath,
        "--http-listen", "\(httpListenHost):0",
        "--inferlet-dir", inferletDir.path,
        "--inferlet", inferletName,
      ]
      args.append(contentsOf: extraArgs)
      return args
    }
  }

  // MARK: - Policy

  /// Timeouts + retry caps. Public so tests can shrink them.
  public struct Policy: Sendable {
    /// How long after spawn we wait for `HTTP_LISTEN=` before
    /// declaring `.handshakeTimeout`.
    public var handshakeTimeout: TimeInterval
    /// Restart attempts allowed inside `restartWindow`. Counts BOTH
    /// pre- and post-handshake exits as attempts (an engine that
    /// crashes on boot is just as broken as one that crashes after
    /// serving a request). `Process.run()` throws (review v1 F2)
    /// are fast-failed without consuming attempts — they represent
    /// deterministic per-spec failures (missing binary, ENOEXEC,
    /// EACCES) that retrying cannot fix.
    public var restartAttempts: Int
    /// Sliding window over which restartAttempts is enforced. When
    /// the window expires with the engine still running, the
    /// attempt counter resets — design doc §3 "Engine crash →
    /// supervisor exponential-backoff restarts (3 tries / 30s)".
    public var restartWindow: TimeInterval
    /// Grace period between `SIGTERM` and `SIGKILL` on `stop()`.
    public var stopGracePeriod: TimeInterval
    /// Hard ceiling on time spent in `.stopping` before the
    /// supervisor force-transitions to `.failed(.spawnFailed)`
    /// (review v1 F5). Computed as `stopGracePeriod + stopOverrun`.
    /// Guarantees a terminal observable transition even if SIGKILL
    /// itself fails (sandbox EPERM, ESRCH/PID-reuse, uninterruptible
    /// sleep).
    public var stopOverrun: TimeInterval
    /// Maximum bytes the supervisor buffers from stdout while
    /// waiting on the handshake line. Past this, the engine has
    /// clearly failed to produce HTTP_LISTEN and is killed (review
    /// v1 F11). Held tight on purpose — a real handshake line is
    /// ≤32 chars; 64 KiB is already an order of magnitude over the
    /// largest credible legitimate prefix.
    public var stdoutCarryLimit: Int
    /// How long an engine must hold `.running` before a subsequent
    /// crash is treated as a FRESH incident rather than accumulating
    /// against `consecutivePostHandshakeCrashes` (review v5 F60).
    /// Default 5×restartWindow (150s). An engine that's been up
    /// for ≥this duration when it crashes resets the counter to 1
    /// instead of incrementing; the slow-flap cap therefore only
    /// fires on tightly-clustered post-handshake failures, not on
    /// the occasional crash after hours of healthy uptime.
    public var healthyUptimeThreshold: TimeInterval
    /// Maximum age of a `.killRejected` boot-recovery manifest
    /// (review v6 F69, v7 F80). Past this, the supervisor deletes
    /// the manifest without SIGKILLing — a days-old manifest from
    /// a long-dead helper is no longer a credible orphan target,
    /// and the OS has had plenty of time to recycle the pid.
    /// Default 1h. Combined with the F79 binary-path check, two
    /// independent gates protect against pid reuse.
    public var recoveryManifestMaxAge: TimeInterval

    public init(handshakeTimeout: TimeInterval = 10,
                restartAttempts: Int = 3,
                restartWindow: TimeInterval = 30,
                stopGracePeriod: TimeInterval = 3,
                stopOverrun: TimeInterval = 2,
                stdoutCarryLimit: Int = 64 * 1024,
                healthyUptimeThreshold: TimeInterval = 150,
                recoveryManifestMaxAge: TimeInterval = 3600) {
      self.handshakeTimeout = handshakeTimeout
      self.restartAttempts = restartAttempts
      self.restartWindow = restartWindow
      self.stopGracePeriod = stopGracePeriod
      self.stopOverrun = stopOverrun
      self.stdoutCarryLimit = stdoutCarryLimit
      self.healthyUptimeThreshold = healthyUptimeThreshold
      self.recoveryManifestMaxAge = recoveryManifestMaxAge
    }
  }

  // MARK: - Observation

  /// Opaque handle returned by `observe`. Drop it (or call
  /// `cancel()`) to stop receiving status updates.
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

  // MARK: - Public surface

  public init(policy: Policy = Policy(),
              logFileURL: URL? = nil,
              recoveryManifestURL: URL? = nil,
              processFactory: @escaping () -> Process = { Process() },
              clock: @escaping () -> Date = Date.init) {
    self.policy = policy
    self.providedLogURL = logFileURL
    self.providedRecoveryManifestURL = recoveryManifestURL
    self.processFactory = processFactory
    self.clock = clock
    #if DEBUG
    self.killProcessOverride = nil
    self.livenessOverride = nil
    #endif
    self.stateQueue.setSpecific(key: self.stateQueueKey, value: ())
    // Sweep any persisted .killRejected manifest from a prior
    // helper lifetime (review v6 F69). Done at init so the
    // supervisor publishes a clean `.stopped` state to early
    // observers — the orphan, if any, is either reaped here or
    // surfaced via a fault log for operator follow-up.
    processBootRecovery()
  }

  #if DEBUG
  /// Test-only init (review v3 F40 test seam, hard-gated under
  /// `#if DEBUG` per review v5 F63): replace the real
  /// `kill(SIGKILL)` call with a closure that decides true/false.
  /// Lets tests drive the killRejected branches deterministically
  /// without needing a process that refuses SIGKILL (impossible —
  /// SIGKILL is uninterceptable). Release builds strip both this
  /// init AND `killProcessOverride` storage entirely, so no
  /// production caller can shorten the OS-level kill semantics.
  internal init(policy: Policy = Policy(),
                logFileURL: URL? = nil,
                recoveryManifestURL: URL? = nil,
                processFactory: @escaping () -> Process = { Process() },
                clock: @escaping () -> Date = Date.init,
                killProcessOverride: @escaping (Process) -> Bool,
                livenessOverride: ((Process) -> Bool)? = nil) {
    self.policy = policy
    self.providedLogURL = logFileURL
    self.providedRecoveryManifestURL = recoveryManifestURL
    self.processFactory = processFactory
    self.clock = clock
    self.killProcessOverride = killProcessOverride
    self.livenessOverride = livenessOverride
    self.stateQueue.setSpecific(key: self.stateQueueKey, value: ())
    processBootRecovery()
  }
  #endif

  /// Cheap snapshot. Lock-free path so the XPC `engineStatus`
  /// selector never bounces through `stateQueue`.
  public var status: EngineStatus {
    statusLock.withLock { $0 }
  }

  /// Read-only view of the policy the supervisor was constructed
  /// with. Used by `HelperExportedAPI` to size the XPC reply-timeout
  /// fallback (review v1 F4) without having to keep a parallel copy.
  public var policyValues: Policy { policy }

  /// Diagnostic-only observer count. `internal` so the SPM RatioThinkCore
  /// module does not expose it as public API surface (review v3
  /// F42). NOTE: under the Xcode `RatioThinkHelper` target this property
  /// is still reachable from `HelperMain` because both files
  /// compile into a single Swift module (review v4 F52). No
  /// production caller uses it today; treat the `forTesting`
  /// suffix as a soft convention, not a compiler-enforced barrier.
  internal var observerCountForTesting: Int {
    observers.withLock { $0.count }
  }

  /// Register a handler invoked with the current status (synchronously
  /// dispatched on `stateQueue`) and on every subsequent transition.
  ///
  /// The handler receives both the status AND the token, so handlers
  /// that need to self-cancel on a terminal state can do so without
  /// referring to an external `var tokenBox` (review v1 F3 — the prior
  /// assign-after-observe pattern raced the initial async dispatch).
  ///
  /// Handlers run on `stateQueue`; do NOT synchronously call back
  /// into the supervisor's `start` / `stop` from inside the handler
  /// (re-entering a serial queue from itself deadlocks).
  /// `clearKillRejected` IS safe to call from inside a handler
  /// because it detects same-queue dispatch via DispatchSpecificKey
  /// and runs inline (review v5 F61).
  @discardableResult
  public func observe(_ handler: @escaping (EngineStatus, ObservationToken) -> Void) -> ObservationToken {
    let id = UUID()
    let token = ObservationToken { [weak self] in
      self?.observers.withLock { $0[id] = nil }
    }
    // Strong-capture the token inside the stored closure so callers
    // that discard the returned token do NOT cause the observer to
    // immediately self-cancel via ObservationToken.deinit (review
    // v1 F3 root cause — the prior `[weak token]` capture meant the
    // observer was only as long-lived as the caller's local var,
    // racing the initial async dispatch). cancel() removes the
    // entry from the map, which drops this strong reference and
    // lets the token deallocate then.
    observers.withLock { $0[id] = { status in
      handler(status, token)
    } }
    let current = status
    stateQueue.async { handler(current, token) }
    return token
  }

  /// Start the engine with `spec`. Returns `.failure(.alreadyRunning)`
  /// if a supervised process is already live or starting; the supervisor
  /// does NOT restart on top of itself silently. Callers that want to
  /// reconfigure call `stop()` first.
  @discardableResult
  public func start(_ spec: LaunchSpec) -> Result<Void, EngineError> {
    stateQueue.sync {
      switch _state {
      case .stopped:
        return doStart(spec)
      case .failed(let code, let msg) where code == .killRejected:
        // Review v3 F40: refuse to spawn on top of a zombie engine.
        // The previous child is still holding the port + model +
        // GPU memory; a new spawn would race on the listen port
        // and double-load the model. The operator has to quit the
        // helper / reboot first.
        return .failure(EngineError(code: .killRejected,
                                    message: "previous engine still alive; manual cleanup required: \(msg)"))
      case .failed:
        return doStart(spec)
      case .starting, .running, .stopping:
        return .failure(EngineError(code: .alreadyRunning,
                                    message: "supervisor already \(_state)"))
      }
    }
  }

  private func doStart(_ spec: LaunchSpec) -> Result<Void, EngineError> {
    currentSpec = spec
    attemptCount = 0
    windowStart = nil
    attemptHistory = []
    consecutivePostHandshakeCrashes = 0
    spawn(spec: spec)
    return .success(())
  }

  /// Stop the engine. Sends `SIGTERM`, waits `stopGracePeriod`, then
  /// `SIGKILL` if necessary. Transitions through `.stopping → .stopped`
  /// and clears the restart bookkeeping so a subsequent `start`
  /// starts fresh.
  public func stop() {
    stateQueue.sync {
      stopLocked()
    }
  }

  /// Recovery escape hatch out of `.failed(.killRejected, _)` (review
  /// v4 F50, v5 F58/F59/F61). Verifies the zombie engine process is
  /// actually reaped before clearing — otherwise the same failure
  /// is re-published with an updated message so the operator knows
  /// the engine is still alive.
  ///
  /// Verification source (review v5 F59): the supervisor retains
  /// the original `Process` reference, not just the integer pid.
  /// `Process.isRunning` consults Foundation's internal wait4
  /// bookkeeping for the SPECIFIC child the supervisor spawned, so
  /// pid reuse cannot mislead the probe. A raw `kill(pid, 0)`
  /// against a recycled pid would have stayed alive forever.
  ///
  /// Concurrency (review v5 F61): callers may invoke this from
  /// inside an observer handler (which runs on `stateQueue`). The
  /// queue-affinity probe falls back to inline execution in that
  /// case to avoid `dispatch_sync` deadlock; otherwise the body
  /// runs under `stateQueue.sync`.
  ///
  /// Returns true when the supervisor transitioned out of
  /// `.killRejected`; false when verification failed (engine still
  /// alive) or when the supervisor was not in `.killRejected` to
  /// begin with.
  @discardableResult
  public func clearKillRejected() -> Bool {
    performLocked { self.clearKillRejectedLocked() }
  }

  private func clearKillRejectedLocked() -> Bool {
    guard case .failed(let code, _) = _state, code == .killRejected else {
      return false
    }
    guard let process = killRejectedProcess, let pid = killRejectedPid else {
      Log.engine.error("PieSupervisor: clearKillRejected with no retained zombie reference; refusing")
      return false
    }
    if isProcessRunning(process) {
      Log.engine.fault("PieSupervisor: clearKillRejected denied — Process pid=\(pid, privacy: .public) still running")
      return false
    }
    Log.engine.info("PieSupervisor: clearKillRejected confirmed pid=\(pid, privacy: .public) is reaped; transitioning to .stopped")
    killRejectedProcess = nil
    killRejectedPid = nil
    attemptCount = 0
    windowStart = nil
    attemptHistory = []
    consecutivePostHandshakeCrashes = 0
    currentSpec = nil
    // Manifest written by enterKillRejected (review v6 F69) is no
    // longer needed once the supervisor itself confirms recovery.
    clearRecoveryManifest()
    setState(.stopped)
    return true
  }

  // MARK: - Internals

  private enum State {
    case stopped
    case starting(spec: LaunchSpec, since: Date)
    case running(port: EnginePort, spec: LaunchSpec)
    case stopping
    case failed(EngineErrorCode, String)

    var publicStatus: EngineStatus {
      switch self {
      case .stopped:                          return .stopped
      case .starting:                         return .starting
      case .running(let port, let spec):      return .running(port: port, profileID: spec.profileID)
      case .stopping:                         return .stopping
      case .failed(let code, let message):    return .failed(code: code, message: message)
      }
    }
  }

  private let policy: Policy
  private let providedLogURL: URL?
  private let providedRecoveryManifestURL: URL?
  private let processFactory: () -> Process
  private let clock: () -> Date
  #if DEBUG
  private let killProcessOverride: ((Process) -> Bool)?
  /// Test-only seam parallel to `killProcessOverride`:
  /// replaces the real `Process.isRunning` liveness probe consulted
  /// by `clearKillRejectedLocked`. Lets a test drive the zombie
  /// alive→dead transition synchronously instead of depending on a
  /// real subprocess actually exiting AND being `wait4`-reaped —
  /// timing that is arbitrarily delayed on a contended CI runner and
  /// made `test_clearKillRejected_*` flake up to the 25s suite
  /// timeout. Release builds strip both this storage AND the only
  /// init that sets it, so production liveness always uses the real
  /// `Process.isRunning` (review v5 F59 pid-reuse safety intact).
  private let livenessOverride: ((Process) -> Bool)?
  #endif

  private let stateQueue = DispatchQueue(label: "com.ratiothink.supervisor.state", qos: .userInitiated)
  private let logQueue   = DispatchQueue(label: "com.ratiothink.supervisor.log",   qos: .utility)

  /// Per-instance specific key used to detect whether the current
  /// thread is already on THIS supervisor's `stateQueue` (review
  /// v5 F61, v6 F68). Must be `let` (not `static`): a static key
  /// would be shared across all PieSupervisor instances, so a
  /// caller already on supervisor A's stateQueue would see a
  /// non-nil value when probing supervisor B and `performLocked`
  /// would run B's body inline on A's queue — bypassing B's
  /// serial invariant and silently corrupting B's `_state` /
  /// `killRejectedProcess` / counters.
  private let stateQueueKey = DispatchSpecificKey<Void>()

  /// Run `work` with serialized access to supervisor state. Hops
  /// onto `stateQueue` via `sync` from off-queue callers; runs
  /// inline when already on `stateQueue` (review v5 F61).
  private func performLocked<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
      return work()
    }
    return stateQueue.sync(execute: work)
  }

  private var _state: State = .stopped {
    didSet { publish(_state.publicStatus) }
  }
  private let statusLock  = OSAllocatedUnfairLock<EngineStatus>(initialState: .stopped)
  private let observers   = OSAllocatedUnfairLock<[UUID: (EngineStatus) -> Void]>(initialState: [:])

  /// In-flight child + IO + handshake bookkeeping. Replaced atomically
  /// (under `stateQueue`) on each spawn so dangling pipe callbacks
  /// from a prior incarnation can detect "I'm stale, drop the event".
  private var current: Incarnation?

  /// Profile-bound spec for the current supervised lifetime. Reset by
  /// `start()` and cleared on `.stopped` / final `.failed`.
  private var currentSpec: LaunchSpec?

  private var attemptCount: Int = 0
  private var windowStart: Date?
  /// Per-attempt failure summaries — joined into the final
  /// `.failed(.spawnFailed)` message so an operator can tell SIGSEGV
  /// from handshake-timeout from exit-7 (review v1 F12). Reset on
  /// the same window-reset condition as `attemptCount`.
  private var attemptHistory: [String] = []
  /// Window-independent count of post-handshake crashes (review v3
  /// F39 opened the post-handshake retry path; review v4 F49 caught
  /// the slow-flap bypass — an engine that runs >restartWindow
  /// between segfaults resets `attemptCount` on every cycle, so the
  /// window-based cap never fires). Reset ONLY on a user-initiated
  /// stop()+start() cycle, never on uptime exceeding restartWindow.
  /// Capped at `policy.restartAttempts`.
  private var consecutivePostHandshakeCrashes: Int = 0
  /// Wallclock at which the supervisor last transitioned to
  /// `.running`. Used by the F60 healthy-uptime check in
  /// handleTermination — a crash arriving more than
  /// `policy.healthyUptimeThreshold` after `.running` was published
  /// resets `consecutivePostHandshakeCrashes` instead of
  /// incrementing it. nil whenever the supervisor is not currently
  /// `.running`.
  private var runningSinceWallclock: Date?

  /// Zombie engine state retained when the supervisor enters
  /// `.failed(.killRejected, _)` so `clearKillRejected()` can
  /// confirm-then-clear (review v4 F50, review v5 F59).
  ///
  /// F59 rationale: a bare pid is brittle under macOS pid reuse —
  /// the OS may recycle the integer between zombie exit and the
  /// operator's recovery attempt, and `kill(pid, 0)` would then
  /// report the recycled process as "still alive" forever. Foundation's
  /// `Process` tracks `wait4` reap state internally, so
  /// `process.isRunning` flips false for the SPECIFIC child the
  /// supervisor spawned regardless of pid reuse. Retain the Process
  /// reference here (plus pid for log messages) and probe both.
  private var killRejectedProcess: Process?
  private var killRejectedPid: pid_t?
  /// Pending stop-deadline timer (review v1 F5). Cancelled when
  /// terminationHandler fires within the deadline.
  private var stopDeadlineTimer: DispatchSourceTimer?

  private final class Incarnation {
    let id = UUID()
    let process: Process
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    var stdoutCarry = Data()
    var handshakeFound = false
    /// Port carried by the most-recently-parsed valid handshake line.
    /// Captured so the final-flush path can produce a precise
    /// "printed handshake but exited before serving" diagnostic
    /// (review v2 F29) without re-running the parser.
    var handshakePort: EnginePort?
    var handshakeTimer: DispatchSourceTimer?
    /// Once the parser saw a `HTTP_LISTEN=` prefix that failed to
    /// validate (review v1 F10), the supervisor fast-fails with the
    /// real cause. Latched here so a re-print isn't double-reported.
    var malformedHandshakeReported = false
    /// Trimmed raw line captured alongside the malformed-handshake
    /// flag so the final-flush diagnostic path (review v2 F29) can
    /// surface it without re-parsing.
    var malformedHandshakeRaw: String?
    init(process: Process) { self.process = process }
  }

  // MARK: state mutation

  private func setState(_ next: State) {
    _state = next
  }

  private func publish(_ status: EngineStatus) {
    statusLock.withLock { $0 = status }
    let snapshot = observers.withLock { Array($0.values) }
    for handler in snapshot {
      handler(status)
    }
  }

  // MARK: spawn

  private func spawn(spec: LaunchSpec) {
    let proc = processFactory()
    let inc = Incarnation(process: proc)
    proc.executableURL = spec.binaryURL
    proc.arguments = spec.arguments()
    var env = ProcessInfo.processInfo.environment
    for (k, v) in spec.extraEnvironment { env[k] = v }
    proc.environment = env
    proc.standardOutput = inc.stdoutPipe
    proc.standardError  = inc.stderrPipe
    proc.terminationHandler = { [weak self] p in
      self?.stateQueue.async { self?.handleTermination(of: inc, process: p) }
    }

    let now = clock()
    if windowStart == nil || now.timeIntervalSince(windowStart!) > policy.restartWindow {
      windowStart = now
      attemptCount = 0
      attemptHistory = []
    }
    attemptCount += 1
    current = inc
    currentSpec = spec
    setState(.starting(spec: spec, since: now))

    Log.engine.info("PieSupervisor: spawning attempt=\(self.attemptCount, privacy: .public) profile=\(spec.profileID, privacy: .public) binary=\(spec.binaryURL.path, privacy: .public)")

    // Hook readers BEFORE run so we never miss the handshake line.
    let stdoutHandle = inc.stdoutPipe.fileHandleForReading
    let stderrHandle = inc.stderrPipe.fileHandleForReading
    stdoutHandle.readabilityHandler = { [weak self, weak inc] fh in
      guard let self, let inc else { return }
      let data = fh.availableData
      if data.isEmpty {
        // Empty data = EOF OR a read error (EBADF/EIO). FileHandle
        // does not expose the difference; the terminationHandler is
        // the authoritative signal that the child is done. Detach
        // the handler so it doesn't busy-loop, but defer the final
        // carry-buffer flush to `handleTermination` — that path
        // already runs on stateQueue and can race-free re-parse the
        // tail (review v1 F9).
        Log.engine.debug("PieSupervisor: stdout readabilityHandler observed EOF/error")
        fh.readabilityHandler = nil
        return
      }
      self.stateQueue.async { self.consumeStdout(inc: inc, chunk: data) }
      self.appendLog(data)
    }
    stderrHandle.readabilityHandler = { [weak self] fh in
      let data = fh.availableData
      if data.isEmpty {
        fh.readabilityHandler = nil
        return
      }
      self?.appendLog(data)
    }

    do {
      try proc.run()
    } catch {
      // Permanent per-spec failures (missing binary, ENOEXEC, EACCES,
      // wrong arch) reach here. Retrying cannot fix them and the GUI
      // is waiting on a reply, so fast-fail immediately rather than
      // burning the full attempt ladder (review v1 F2).
      let msg = "Process.run() failed for \(spec.binaryURL.path): \(error)"
      Log.engine.fault("\(msg, privacy: .public)")
      stdoutHandle.readabilityHandler = nil
      stderrHandle.readabilityHandler = nil
      current = nil
      currentSpec = nil
      // Do not credit this against `attemptCount`; the count is the
      // policy-relevant "how often did the engine fail under us"
      // metric, and a never-spawned process is a different failure
      // class. Walking it back here also keeps the attempt-history
      // message accurate.
      attemptCount = max(0, attemptCount - 1)
      attemptHistory.append("attempt-pre-spawn: \(error)")
      let joined = attemptHistory.joined(separator: "; ")
      setState(.failed(.spawnFailed, joined.isEmpty ? msg : joined))
      return
    }

    // Arm handshake timer. Cancelled by the handshake parser on
    // success; fires here if pie never prints HTTP_LISTEN.
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now() + policy.handshakeTimeout)
    timer.setEventHandler { [weak self, weak inc] in
      guard let self, let inc, !inc.handshakeFound else { return }
      guard self.current?.id == inc.id else { return }
      // A process that has already exited before the handshake is an
      // early-exit / spawn failure (it carries an exit code), NOT a
      // handshake timeout — which specifically means "process alive
      // but silent". Its `terminationHandler` is guaranteed to fire
      // and `handleTermination` classifies it via the exit code as
      // `.spawnFailed`. Defer to that path rather than racing it to a
      // less precise label: under load the timer event can run before
      // the (starved) termination callback, and `finishSpawnFailure`
      // would otherwise stamp `.handshakeTimeout`, which the
      // `.failed` priorState guard in `handleTermination` then refuses
      // to correct. Keying on `Process.isRunning` (Foundation `wait4`
      // truth for THIS child, flips false on reap) makes the
      // classification deterministic regardless of which event wins.
      guard inc.process.isRunning else {
        Log.engine.debug("PieSupervisor: handshake timer fired but process pid=\(inc.process.processIdentifier, privacy: .public) already exited; deferring to termination path for spawn-failure classification")
        return
      }
      Log.engine.error("PieSupervisor: handshake timeout after \(self.policy.handshakeTimeout, privacy: .public)s")
      let killed = self.killProcess(inc.process)
      // Review v2 F31: surface SIGKILL failure precisely. Without
      // this branch, the supervisor reports .failed while the
      // engine process is still alive holding the model + port.
      if !killed {
        // Review v3 F40 + v4 F50: distinct code so start() can
        // refuse and HelperExportedAPI.stopEngine can surface the
        // zombie. Record pid for `clearKillRejected()` recovery
        // and emit a fault-level message with the explicit
        // operator instruction.
        let pid = inc.process.processIdentifier
        self.enterKillRejected(
          process: inc.process,
          pid: pid,
          message: "handshake timeout AND SIGKILL pid=\(pid) rejected; engine may still be alive"
        )
        return
      }
      self.finishSpawnFailure(code: .handshakeTimeout,
                              message: "pie did not print HTTP_LISTEN within \(Int(self.policy.handshakeTimeout))s")
    }
    inc.handshakeTimer = timer
    timer.resume()
  }

  private func consumeStdout(inc: Incarnation, chunk: Data) {
    guard current?.id == inc.id else { return }
    inc.stdoutCarry.append(chunk)
    // Bound the carry buffer (review v1 F11). A real handshake line
    // is ≤32 chars; anything past `stdoutCarryLimit` without a
    // newline is the engine misbehaving, and continuing to buffer
    // would only let it balloon helper RSS.
    if inc.stdoutCarry.count > policy.stdoutCarryLimit {
      Log.engine.fault("PieSupervisor: stdout carry exceeded \(self.policy.stdoutCarryLimit, privacy: .public) bytes without a HTTP_LISTEN line — killing engine")
      inc.handshakeTimer?.cancel()
      inc.handshakeTimer = nil
      let killed = killProcess(inc.process)
      if !killed {
        // Review v3 F40 + v4 F50.
        let pid = inc.process.processIdentifier
        enterKillRejected(
          process: inc.process,
          pid: pid,
          message: "stdout carry overflow AND SIGKILL pid=\(pid) rejected; engine may still be alive"
        )
        return
      }
      finishSpawnFailure(
        code: .handshakeTimeout,
        message: "engine emitted >\(policy.stdoutCarryLimit) bytes of stdout with no HTTP_LISTEN line"
      )
      return
    }
    while let nl = inc.stdoutCarry.firstIndex(of: 0x0A) {
      let lineData = inc.stdoutCarry[..<nl]
      inc.stdoutCarry.removeSubrange(...nl)
      processLine(inc: inc, lineData: lineData, applySideEffects: true)
      // processLine may have driven us to a terminal state; bail if
      // current was cleared.
      if current?.id != inc.id { return }
    }
  }

  /// Outcome of inspecting one stdout line for the handshake prefix.
  /// Separated from `processLine` so the final-flush path in
  /// `handleTermination` can re-parse the carry tail without
  /// triggering setState / kill / retry side effects (review v2 F29).
  private enum HandshakeOutcome {
    case ignore
    case valid(EnginePort)
    case malformed(String)
  }

  private static func classifyHandshake(_ line: String) -> HandshakeOutcome {
    let prefix = "HTTP_LISTEN="
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix) else { return .ignore }
    if let port = parseHandshake(trimmed) {
      return .valid(port)
    } else {
      return .malformed(trimmed)
    }
  }

  private func processLine(inc: Incarnation, lineData: Data, applySideEffects: Bool) {
    guard let line = String(data: lineData, encoding: .utf8) else { return }
    if inc.handshakeFound { return }
    switch Self.classifyHandshake(line) {
    case .ignore:
      return
    case .valid(let port):
      inc.handshakeFound = true
      inc.handshakePort = port
      if !applySideEffects { return }
      inc.handshakeTimer?.cancel()
      inc.handshakeTimer = nil
      guard let spec = currentSpec else { return }
      runningSinceWallclock = clock()
      setState(.running(port: port, spec: spec))
      Log.engine.info("PieSupervisor: handshake captured port=\(port, privacy: .public)")
    case .malformed(let trimmed):
      guard !inc.malformedHandshakeReported else { return }
      inc.malformedHandshakeReported = true
      inc.malformedHandshakeRaw = trimmed
      Log.engine.error("PieSupervisor: malformed HTTP_LISTEN line: \(trimmed, privacy: .public)")
      if !applySideEffects { return }
      inc.handshakeTimer?.cancel()
      inc.handshakeTimer = nil
      let killed = killProcess(inc.process)
      if !killed {
        // Review v3 F40 + v4 F50.
        let pid = inc.process.processIdentifier
        enterKillRejected(
          process: inc.process,
          pid: pid,
          message: "malformed HTTP_LISTEN AND SIGKILL pid=\(pid) rejected; engine may still be alive: \(trimmed)"
        )
        return
      }
      finishSpawnFailure(code: .handshakeTimeout,
                         message: "malformed HTTP_LISTEN line: \(trimmed)")
    }
  }

  /// Parse `HTTP_LISTEN=<host>:<port>`. Returns nil if the line does
  /// not match or the port is out of range. Supports both
  /// `HTTP_LISTEN=127.0.0.1:54321` and bracketed IPv6
  /// `HTTP_LISTEN=[::1]:54321`. Host is accepted as anything non-
  /// empty; only the port is plumbed onward.
  static func parseHandshake(_ line: String) -> EnginePort? {
    let prefix = "HTTP_LISTEN="
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix) else { return nil }
    let rest = String(trimmed.dropFirst(prefix.count))
    let (host, portStr): (String, String)
    if rest.hasPrefix("[") {
      // IPv6 bracketed form. The closing `]` MUST be followed by `:`
      // and the port. lastIndex(of: ":") would otherwise pick a
      // colon inside the address.
      guard let close = rest.firstIndex(of: "]"),
            rest.index(after: close) < rest.endIndex,
            rest[rest.index(after: close)] == ":" else { return nil }
      host = String(rest[rest.index(after: rest.startIndex)..<close])
      portStr = String(rest[rest.index(close, offsetBy: 2)...])
    } else {
      guard let colon = rest.lastIndex(of: ":") else { return nil }
      host = String(rest[..<colon])
      portStr = String(rest[rest.index(after: colon)...])
    }
    guard !host.isEmpty, let raw = Int(portStr), raw > 0, raw <= Int(UInt16.max) else {
      return nil
    }
    return EnginePort(raw)
  }

  // MARK: termination + restart

  private func handleTermination(of inc: Incarnation, process: Process) {
    // Drop stale callbacks from a prior incarnation that we've
    // already moved past (the new spawn took over `current`).
    guard current?.id == inc.id else { return }
    inc.handshakeTimer?.cancel()
    inc.stdoutPipe.fileHandleForReading.readabilityHandler = nil
    inc.stderrPipe.fileHandleForReading.readabilityHandler = nil

    // Final flush: an engine that exited without a trailing newline
    // may have parked the handshake line in stdoutCarry. Re-parse
    // the tail BUT do not let processLine call setState / kill /
    // finishSpawnFailure (review v2 F29 — the prior side-effecting
    // flush published a transient `.running` for an already-exited
    // engine). The flush only updates `inc.handshakeFound` /
    // `inc.malformedHandshakeRaw`; the unified failure path below
    // produces a precise diagnostic without ever crossing through
    // `.running`.
    if !inc.handshakeFound, !inc.stdoutCarry.isEmpty {
      let tail = inc.stdoutCarry
      inc.stdoutCarry = Data()
      processLine(inc: inc, lineData: tail, applySideEffects: false)
    }

    let exitCode = process.terminationStatus
    let reason = process.terminationReason
    let priorState = _state
    current = nil

    if case .stopping = priorState {
      // We asked for it. Clean shutdown.
      Log.engine.info("PieSupervisor: child exited during stop (code=\(exitCode, privacy: .public))")
      attemptCount = 0
      windowStart = nil
      attemptHistory = []
      // Reset post-handshake crash counter only on user-initiated
      // stop (review v4 F49). Window-based timeouts do NOT clear it.
      consecutivePostHandshakeCrashes = 0
      currentSpec = nil
      stopDeadlineTimer?.cancel()
      stopDeadlineTimer = nil
      setState(.stopped)
      return
    }

    if case .failed = priorState {
      // The handshake-timeout path already drove the state to .failed
      // (final cap) before the killed child's terminationHandler ran.
      // Don't re-enter the restart ladder — that would clobber the
      // failure cause with a generic exit-code message.
      Log.engine.info("PieSupervisor: child exited after .failed transition (code=\(exitCode, privacy: .public))")
      return
    }

    // Unexpected exit. Decide whether to back off + restart.
    let exitDesc = "pie exited code=\(exitCode) reason=\(reason.rawValue)"
    Log.engine.error("PieSupervisor: unexpected \(exitDesc, privacy: .public) attempt=\(self.attemptCount, privacy: .public)")
    appendLog(Data("[supervisor] \(exitDesc)\n".utf8))

    // Review v2 F29 / review v3 F39: the post-flush short-circuits
    // ONLY fire when the live path never reached `.running` — i.e.
    // priorState is `.starting`. A healthy engine that ran for
    // hours and then crashed (priorState=.running) must fall
    // through to the normal retry ladder per design doc §3
    // ("Engine crash → supervisor exponential-backoff restarts").
    // Both `handshakePort` and `malformedHandshakeRaw` get set on
    // the live path too (so the same `.failed` produces a precise
    // diagnostic), which is why the priorState gate is the
    // load-bearing predicate, not the inc.* flags alone.
    if case .starting = priorState {
      if let port = inc.handshakePort {
        currentSpec = nil
        let msg = "engine printed handshake (port=\(port)) but exited immediately: \(exitDesc)"
        attemptHistory.append("attempt \(attemptCount): \(msg)")
        let joined = attemptHistory.joined(separator: "; ")
        setState(.failed(.spawnFailed, joined))
        return
      }
      if let raw = inc.malformedHandshakeRaw {
        currentSpec = nil
        let msg = "engine printed malformed HTTP_LISTEN line then exited: \(raw); \(exitDesc)"
        attemptHistory.append("attempt \(attemptCount): \(msg)")
        let joined = attemptHistory.joined(separator: "; ")
        setState(.failed(.handshakeTimeout, joined))
        return
      }
    }

    attemptHistory.append("attempt \(attemptCount): \(exitDesc)")

    // Review v4 F49: enforce a window-independent cap on
    // post-handshake crashes. The window-based attemptCount cap
    // (below) only fires when crashes are tight enough to all
    // land in restartWindow; a slow flap (e.g. 31s between
    // segfaults with the default 30s window) bypasses it forever.
    //
    // Review v5 F60: an engine that ran healthily for ≥
    // `policy.healthyUptimeThreshold` before crashing is a FRESH
    // incident — reset the counter to 1 instead of incrementing.
    // Without this decay, an engine at counter=2 (cap=3) that
    // recovers, runs for 24h, then crashes once for an unrelated
    // reason would falsely trip 'slow-flapped 3 times'.
    if case .running = priorState {
      let uptime = runningSinceWallclock.map { clock().timeIntervalSince($0) } ?? .infinity
      runningSinceWallclock = nil
      if uptime >= policy.healthyUptimeThreshold {
        Log.engine.info("PieSupervisor: post-handshake crash after healthy uptime=\(uptime, privacy: .public)s — resetting slow-flap counter to 1")
        consecutivePostHandshakeCrashes = 1
      } else {
        consecutivePostHandshakeCrashes += 1
      }
      if consecutivePostHandshakeCrashes >= policy.restartAttempts {
        Log.engine.fault("PieSupervisor: post-handshake-crash cap reached (\(self.consecutivePostHandshakeCrashes, privacy: .public) restarts); giving up")
        currentSpec = nil
        let joined = attemptHistory.joined(separator: "; ")
        setState(.failed(.spawnFailed,
                         "engine slow-flapped \(consecutivePostHandshakeCrashes) consecutive times after handshake: \(joined)"))
        return
      }
    }

    if attemptCount >= policy.restartAttempts {
      Log.engine.fault("PieSupervisor: giving up after \(self.attemptCount, privacy: .public) attempts in \(self.policy.restartWindow, privacy: .public)s window")
      currentSpec = nil
      let joined = attemptHistory.joined(separator: "; ")
      setState(.failed(.spawnFailed,
                       "engine failed \(attemptCount) consecutive times: \(joined)"))
      return
    }

    guard let spec = currentSpec else {
      setState(.failed(.spawnFailed, "no launch spec retained across restart"))
      return
    }
    // Review v5 F62: publish `.starting` BEFORE the asyncAfter delay
    // so the supervisor's wire state during the backoff window
    // reflects "engine restarting", not the stale `.running(port:
    // <dead-port>, …)` carried over from priorState. Without this,
    // a parallel `engineStatus` poll during the post-handshake-crash
    // backoff returns `.running` on a dead port while `stopEngine`
    // returns the failure — conflicting wire state.
    setState(.starting(spec: spec, since: clock()))
    // Exponential backoff: 250ms, 500ms, 1000ms, ... before the next
    // spawn. Keeps a fast-failing engine from pinning a core.
    let delay = pow(2.0, Double(attemptCount - 1)) * 0.25
    stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      // Cancellation via stop() between attempts must short-circuit;
      // .stopped/.stopping/.failed are terminal. .starting is the
      // synthetic backoff-window state set just above (review v5
      // F62); .running can carry over from a post-handshake crash
      // when the fall-through path did not publish .starting (kept
      // for safety until the entire fall-through is audited).
      switch self._state {
      case .stopped, .stopping, .failed: return
      case .starting, .running: break
      }
      self.spawn(spec: spec)
    }
  }

  /// Called from the handshake-timeout path (and malformed-handshake
  /// path). Mirrors `handleTermination`'s giving-up branch but does
  /// not consult `Process.terminationStatus` because the child was
  /// force-killed before any exit code became meaningful.
  private func finishSpawnFailure(code: EngineErrorCode, message: String) {
    attemptHistory.append("attempt \(attemptCount): \(code.rawValue) — \(message)")
    if attemptCount >= policy.restartAttempts {
      currentSpec = nil
      current = nil
      let joined = attemptHistory.joined(separator: "; ")
      setState(.failed(code, joined.isEmpty ? message : joined))
      return
    }
    guard let spec = currentSpec else {
      setState(.failed(code, message + " (no spec to retry)"))
      return
    }
    let delay = pow(2.0, Double(attemptCount - 1)) * 0.25
    current = nil
    stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      // Symmetric guard with the handleTermination retry path
      // (review v1 F1, review v3 F39). stop() may have transitioned
      // the supervisor out of the retry-pending state between the
      // kill and this fire; reviving the engine under the user's
      // nose is the silent override failure mode the finding
      // caught. .running is allowed because a post-handshake crash
      // carries it over from priorState.
      switch self._state {
      case .stopped, .stopping, .failed: return
      case .starting, .running: break
      }
      self.spawn(spec: spec)
    }
  }

  // MARK: stop

  private func stopLocked() {
    switch _state {
    case .stopped, .failed:
      // Idempotent.
      return
    case .stopping:
      return
    case .starting, .running:
      setState(.stopping)
      if let inc = current {
        inc.handshakeTimer?.cancel()
        inc.handshakeTimer = nil
        terminateGracefully(inc.process)
        armStopDeadline()
      } else {
        // No live process but state said running — defensive.
        currentSpec = nil
        setState(.stopped)
      }
    }
  }

  private func terminateGracefully(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = DispatchTime.now() + policy.stopGracePeriod
    stateQueue.asyncAfter(deadline: deadline) { [weak self, weak process] in
      guard let self, let process, process.isRunning else { return }
      Log.engine.error("PieSupervisor: SIGTERM ignored; sending SIGKILL")
      let killed = self.killProcess(process)
      if !killed {
        // SIGKILL refused (sandbox EPERM, etc). Record .killRejected
        // (review v3 F40 + v4 F50) so HelperExportedAPI.stopEngine
        // surfaces the zombie up the wire instead of replying nil.
        // The stopDeadlineTimer would otherwise fire
        // `.failed(.spawnFailed, "stop deadline exceeded")` and
        // clobber the precise cause.
        let pid = process.processIdentifier
        self.stopDeadlineTimer?.cancel()
        self.stopDeadlineTimer = nil
        self.enterKillRejected(
          process: process,
          pid: pid,
          message: "SIGKILL pid=\(pid) rejected during stop; engine may still be alive"
        )
      }
    }
  }

  /// Hard deadline that fires `.failed(.spawnFailed, "stop deadline
  /// exceeded")` if neither SIGTERM nor SIGKILL produced a terminal
  /// observation in `stopGracePeriod + stopOverrun` (review v1 F5).
  /// Cancelled by `handleTermination`'s `.stopping` branch.
  private func armStopDeadline() {
    stopDeadlineTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now() + policy.stopGracePeriod + policy.stopOverrun)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      guard case .stopping = self._state else { return }
      Log.engine.fault("PieSupervisor: stop deadline (\(self.policy.stopGracePeriod + self.policy.stopOverrun, privacy: .public)s) exceeded; forcing .failed")
      self.current = nil
      self.currentSpec = nil
      self.stopDeadlineTimer = nil
      self.setState(.failed(.spawnFailed,
                            "stop deadline (\(self.policy.stopGracePeriod + self.policy.stopOverrun)s) exceeded; engine did not exit after SIGTERM+SIGKILL"))
    }
    stopDeadlineTimer = timer
    timer.resume()
  }

  /// Centralized entry to the `.failed(.killRejected, …)` state
  /// (review v4 F50). Logs a fault-level message with the zombie
  /// pid + operator instruction, retains both the pid AND the
  /// Foundation `Process` reference (review v5 F59 — pid alone is
  /// pid-reuse-brittle) for `clearKillRejected()` to verify
  /// against, and clears the live-process bookkeeping.
  private func enterKillRejected(process: Process, pid: pid_t, message: String) {
    // Review v6 F70: trim the recovery instruction to wire-level
    // facts. The XPC selector exists; an App-side GUI button does
    // NOT exist yet (Phase 3+ work). Be honest about what the
    // operator can do today: re-launch the helper (boot recovery
    // will reap the orphan via the persisted manifest), or kill
    // the pid manually.
    Log.engine.fault("PieSupervisor: entering .failed(.killRejected) pid=\(pid, privacy: .public) — \(message, privacy: .public). Recovery options: (1) call clearKillRejected via XPC (selector wired in HelperExportedAPI; no App-side button yet), (2) relaunch the helper (boot will reap the orphan via the persisted manifest), or (3) `kill -9 \(pid, privacy: .public)` manually.")
    current = nil
    currentSpec = nil
    killRejectedProcess = process
    killRejectedPid = pid
    // Persist for F69 boot-recovery in case the helper itself
    // dies before clearKillRejected runs. Canonicalize the
    // binary path (review v8 F87) so disk format matches what
    // `proc_pidpath` will return at recovery time — no
    // `/private/var` vs `/var` symlink mismatch.
    let rawPath = process.executableURL?.path ?? "<unknown>"
    writeRecoveryManifest(
      pid: pid,
      binaryPath: Self.canonicalPath(rawPath),
      message: message
    )
    setState(.failed(.killRejected, message))
  }

  /// Liveness probe for the retained `.killRejected` zombie. Defers
  /// to the real `Process.isRunning` (Foundation `wait4` bookkeeping
  /// for the SPECIFIC child, pid-reuse-safe per review v5 F59) in
  /// production; the `livenessOverride` test seam replaces it
  /// so `clearKillRejected` recovery can be exercised synchronously
  /// without waiting on a real subprocess to exit and be reaped.
  private func isProcessRunning(_ process: Process) -> Bool {
    #if DEBUG
    if let livenessOverride { return livenessOverride(process) }
    #endif
    return process.isRunning
  }

  /// SIGKILL with errno capture (review v1 F6). Returns true if the
  /// signal landed; false on any non-ESRCH error (ESRCH = the child
  /// already exited before we got here, which is normal in races
  /// with terminationHandler). The `killProcessOverride` test seam
  /// (review v3 F40) lets unit tests drive the `false` branch
  /// without trying to refuse SIGKILL at the OS level.
  @discardableResult
  private func killProcess(_ process: Process) -> Bool {
    #if DEBUG
    if let killProcessOverride { return killProcessOverride(process) }
    #endif
    guard process.isRunning else { return true }
    let pid = process.processIdentifier
    let rc = kill(pid, SIGKILL)
    if rc == 0 { return true }
    let err = errno
    let desc = String(cString: strerror(err))
    if err == ESRCH {
      Log.engine.info("PieSupervisor: SIGKILL pid=\(pid, privacy: .public) returned ESRCH (already exited)")
      return true
    }
    Log.engine.fault("PieSupervisor: SIGKILL pid=\(pid, privacy: .public) failed errno=\(err, privacy: .public) (\(desc, privacy: .public))")
    return false
  }

  // MARK: kill-rejected boot recovery (review v6 F69)

  /// On-disk shape of a `.killRejected` event persisted so a helper
  /// crash / launchd KeepAlive relaunch can still reap the zombie
  /// engine on the next boot (review v6 F69). Pre-F69 the
  /// `killRejectedProcess` reference was in-memory only, so any
  /// helper-side restart left an orphan engine holding the port +
  /// GPU with no recovery path.
  struct KillRejectedManifest: Codable {
    let pid: pid_t
    let binaryPath: String
    let timestamp: Date
    let message: String
  }

  private func resolvedRecoveryManifestURL() -> URL? {
    if let providedRecoveryManifestURL { return providedRecoveryManifestURL }
    do {
      return try PieDirs.applicationSupport()
        .appendingPathComponent("engine.killrejected.json")
    } catch {
      Log.engine.error("PieSupervisor: cannot resolve recovery manifest path: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private func writeRecoveryManifest(pid: pid_t, binaryPath: String, message: String) {
    guard let url = resolvedRecoveryManifestURL() else { return }
    let manifest = KillRejectedManifest(
      pid: pid, binaryPath: binaryPath, timestamp: clock(), message: message
    )
    do {
      let data = try JSONEncoder().encode(manifest)
      try data.write(to: url, options: .atomic)
    } catch {
      Log.engine.error("PieSupervisor: writeRecoveryManifest failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func clearRecoveryManifest() {
    guard let url = resolvedRecoveryManifestURL() else { return }
    if !FileManager.default.fileExists(atPath: url.path) { return }
    do { try FileManager.default.removeItem(at: url) }
    catch { Log.engine.error("PieSupervisor: clearRecoveryManifest failed: \(String(describing: error), privacy: .public)") }
  }

  /// Best-effort cleanup of an orphan engine from a prior helper
  /// lifetime (review v6 F69, v7 F79/F80). Runs at init. Gated by
  /// two independent safety checks against pid reuse:
  ///  · Manifest age (F80): if `clock() - manifest.timestamp >
  ///    policy.recoveryManifestMaxAge`, the manifest is treated
  ///    as stale, deleted, and no signal is sent. A days-old
  ///    manifest is not a credible orphan target — macOS
  ///    recycles pids aggressively.
  ///  · Binary-path validation (F79): `proc_pidpath(pid, …)` is
  ///    compared to `manifest.binaryPath` before SIGKILL. A
  ///    mismatch means the pid was recycled for an unrelated
  ///    process; skip the kill, log fault, delete the manifest.
  /// Failures are logged at fault level — the helper still boots,
  /// the operator just has to clean up manually (the same failure
  /// mode as without persistence).
  private func processBootRecovery() {
    guard let url = resolvedRecoveryManifestURL(),
          FileManager.default.fileExists(atPath: url.path) else {
      return
    }
    let manifest: KillRejectedManifest
    do {
      let data = try Data(contentsOf: url)
      manifest = try JSONDecoder().decode(KillRejectedManifest.self, from: data)
    } catch {
      Log.engine.error("PieSupervisor: bootRecovery manifest decode failed: \(String(describing: error), privacy: .public) — deleting")
      try? FileManager.default.removeItem(at: url)
      return
    }
    let pid = manifest.pid
    Log.engine.fault("PieSupervisor: boot recovery found stale .killRejected manifest pid=\(pid, privacy: .public) binary=\(manifest.binaryPath, privacy: .public) ts=\(manifest.timestamp, privacy: .public)")

    // Review v7 F80: age gate. A manifest older than
    // `recoveryManifestMaxAge` cannot reliably be paired with the
    // recorded pid — the OS has had time to recycle the pid
    // millions of times.
    let age = clock().timeIntervalSince(manifest.timestamp)
    if age > policy.recoveryManifestMaxAge {
      Log.engine.fault("PieSupervisor: manifest age=\(age, privacy: .public)s > \(self.policy.recoveryManifestMaxAge, privacy: .public)s — skipping SIGKILL (pid-reuse hazard), deleting manifest")
      try? FileManager.default.removeItem(at: url)
      return
    }

    if kill(pid, 0) != 0 {
      if errno == ESRCH {
        Log.engine.info("PieSupervisor: orphan pid=\(pid, privacy: .public) already gone")
      } else {
        let err = errno
        let desc = String(cString: strerror(err))
        Log.engine.error("PieSupervisor: kill(\(pid, privacy: .public), 0) probe errno=\(err, privacy: .public) (\(desc, privacy: .public))")
      }
      try? FileManager.default.removeItem(at: url)
      return
    }

    // Review v7 F79: process exists, but the pid may have been
    // recycled. Validate executable path before SIGKILL.
    // Review v8 F87: canonicalize both sides so the comparison
    // survives `/private/var` ↔ `/var` symlink families.
    let actualPath = currentPathForPid(pid)
    guard let actualPath else {
      Log.engine.fault("PieSupervisor: proc_pidpath(\(pid, privacy: .public)) failed — refusing SIGKILL (cannot verify identity)")
      try? FileManager.default.removeItem(at: url)
      return
    }
    let canonActual = Self.canonicalPath(actualPath)
    let canonManifest = Self.canonicalPath(manifest.binaryPath)
    if canonActual != canonManifest {
      Log.engine.fault("PieSupervisor: pid=\(pid, privacy: .public) now belongs to '\(actualPath, privacy: .public)' (manifest expected '\(manifest.binaryPath, privacy: .public)'; canonical='\(canonActual, privacy: .public)' vs '\(canonManifest, privacy: .public)') — pid was reused; skipping SIGKILL")
      try? FileManager.default.removeItem(at: url)
      return
    }

    Log.engine.fault("PieSupervisor: orphan engine pid=\(pid, privacy: .public) (binary='\(actualPath, privacy: .public)' matches manifest) — sending SIGKILL")
    if kill(pid, SIGKILL) == 0 {
      Log.engine.info("PieSupervisor: SIGKILL on orphan pid=\(pid, privacy: .public) succeeded")
    } else {
      let err = errno
      let desc = String(cString: strerror(err))
      Log.engine.fault("PieSupervisor: SIGKILL on orphan pid=\(pid, privacy: .public) failed errno=\(err, privacy: .public) (\(desc, privacy: .public)). Operator: clean up manually (e.g. Activity Monitor)")
    }
    try? FileManager.default.removeItem(at: url)
  }

  /// Wrap `proc_pidpath` for the F79 boot-recovery identity check.
  /// Returns nil on lookup failure (process gone, permission
  /// denied, etc) — the caller MUST treat nil as "cannot verify"
  /// and refuse the SIGKILL.
  private func currentPathForPid(_ pid: pid_t) -> String? {
    let capacity = Int(MAXPATHLEN)
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    defer { buf.deallocate() }
    let rc = proc_pidpath(pid, buf, UInt32(capacity))
    guard rc > 0 else { return nil }
    return String(cString: buf)
  }

  /// Resolve a filesystem path to its realpath(3) form so the F79
  /// binary-path comparison survives macOS's `/private/var` ↔
  /// `/var`, `/private/tmp` ↔ `/tmp` symlink families (review v8
  /// F87). `proc_pidpath` returns realpath; the Process API
  /// returns whatever the client constructed. Canonicalize both
  /// sides at the comparison site.
  ///
  /// `URL.resolvingSymlinksInPath()` was the first attempt but
  /// does not reliably convert `/tmp/x` → `/private/tmp/x` (it
  /// short-circuits in cases that look fully-qualified). `realpath`
  /// is the POSIX canonical form and matches proc_pidpath exactly.
  /// Falls back to the input path on lookup failure (nonexistent
  /// file) so the comparison still produces a deterministic
  /// result.
  static func canonicalPath(_ path: String) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(path, &buf) != nil {
      return String(cString: buf)
    }
    return path
  }

  // MARK: logs

  private lazy var logHandle: FileHandle? = openLogHandle()

  private func openLogHandle() -> FileHandle? {
    let url: URL
    if let providedLogURL {
      url = providedLogURL
    } else {
      do {
        url = try PieDirs.logs().appendingPathComponent("engine.log")
      } catch {
        Log.engine.fault("PieSupervisor: cannot resolve logs dir: \(String(describing: error), privacy: .public)")
        return nil
      }
    }
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    do {
      let h = try FileHandle(forWritingTo: url)
      try h.seekToEnd()
      return h
    } catch {
      Log.engine.fault("PieSupervisor: cannot open engine.log: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private func appendLog(_ data: Data) {
    logQueue.async { [weak self] in
      guard let self, let h = self.logHandle else { return }
      do { try h.write(contentsOf: data) }
      catch { Log.engine.error("PieSupervisor: engine.log write failed: \(String(describing: error), privacy: .public)") }
    }
  }
}
