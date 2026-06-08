import Foundation
import os

/// Helper-side `PieHelperXPC` implementation.
///
/// Phase 2.1 surface area is intentionally tiny: only `engineStatus`
/// returns real data (`.stopped` until `PieSupervisor` is wired in
/// Phase 2.2). Every other selector returns
/// `EngineError(.wireContractViolation, "Phase 2.2+ not yet
/// implemented")` so a stray call from a future GUI build surfaces as
/// a *plumbing* error in the wire-violation channel — not silently
/// swallowed and not mis-routed as a generic engine failure.
///
/// `NSObject` conformance is mandatory: `NSXPCConnection`'s proxy
/// machinery dispatches through the Objective-C runtime.
///
/// Concurrency contract (review v1 F4): a single `HelperExportedAPI`
/// instance is assigned as `exportedObject` on every accepted
/// `NSXPCConnection`. `NSXPCConnection` dispatches selector calls on
/// an arbitrary queue and may interleave calls from peer processes,
/// so any state added beyond Phase 2.1's pre-encoded blobs MUST be
/// either:
///   · stored in an `actor` reachable from the selector body, or
///   · guarded by a serial `DispatchQueue` whose label is documented
///     here.
/// Today every reply is built from immutable `static let` data plus
/// the selector's own arguments, so `Sendable` holds trivially —
/// adding mutable state without revisiting this contract would
/// introduce a TSan-quiet race.
public final class HelperExportedAPI: NSObject, PieHelperXPC {
  /// Resolves a profile id into a `PieControlLauncher.LaunchSpec` the
  /// `PieEngineHost` can spawn.  migrated this away from
  /// `PieSupervisor.LaunchSpec` (whose argv + handshake parser no
  /// longer match the `pie` binary). `LaunchSpecResolver
  /// .asClosure` is the canonical adapter.
  ///
  /// Second argument is the optional per-start `explicitModel` (#459 repro
  /// 1) — the chat toolbar / model-list selection that overrides the
  /// profile's persisted default for this boot. `nil` uses the profile
  /// default. `startEngine` threads it; `restartEngine` passes `nil` (its
  /// route always boots the freshly-saved profile default).
  public typealias LaunchSpecResolver = (String, String?) -> Result<PieControlLauncher.LaunchSpec, EngineError>

  /// Pre-encoded `EngineStatus.stopped` reply. Encoded at type
  /// initialization so `engineStatus`'s success path is provably
  /// throw-free (review v1 F6 — the prior do/catch made the catch
  /// branch indistinguishable from a real `.stopped` reply at decode
  /// time). `preconditionFailure` if even the static encode fails
  /// because that's a Codable drift the test bundle would catch.
  ///
  /// Used as the fallback when no `PieSupervisor` is wired (early
  /// Phase 2.2 bring-up + degraded init paths). Once a supervisor is
  /// present, `engineStatus` encodes the live state on demand.
  private static let stoppedReplyData: Data = {
    do {
      return try XPCPayload.encode(EngineStatus.stopped)
    } catch {
      preconditionFailure("HelperExportedAPI: failed to pre-encode .stopped reply: \(error)")
    }
  }()

  /// Single greppable choke point for the "not yet implemented" reply
  /// payload. Hand-encoded once at init so a future Codable drift
  /// can't make a placeholder encode itself fail.
  private static let notImplementedErrorData: Data = {
    let err = EngineError(
      code: .wireContractViolation,
      message: "RatioThinkHelper Phase 2.1 stub: selector not yet implemented (wire up in Phase 2.2+)"
    )
    do {
      return try XPCPayload.encode(err)
    } catch {
      preconditionFailure("HelperExportedAPI: failed to pre-encode notImplemented error: \(error)")
    }
  }()

  /// Pre-encoded empty `[String]` reply for `listProfiles`. The wire
  /// contract types that slot as `Data` decodable to `[String]` —
  /// emitting any other shape would surface as `DecodingError` on
  /// the GUI side, indistinguishable from wire corruption (review
  /// v2 F5). Encoded at type init so the catch path is provably
  /// dead.
  private static let emptyProfilesData: Data = {
    do {
      return try XPCPayload.encode([String]())
    } catch {
      preconditionFailure("HelperExportedAPI: failed to pre-encode empty profiles list: \(error)")
    }
  }()

  /// Pre-encoded `EngineStatus.failed(.wireContractViolation, …)`
  /// reply for the engineStatus encode-failure path (PR12 review v1
  /// F7). Falling back to `.stopped` made a wire-contract violation
  /// indistinguishable from a real stopped engine; the GUI menu-bar
  /// dot rendered green-but-no-engine. This blob lets the dot render
  /// red with a structured cause.
  private static let wireViolationStatusData: Data = {
    do {
      return try XPCPayload.encode(
        EngineStatus.failed(
          code: .wireContractViolation,
          message: "engineStatus encode failed; see helper log"
        )
      )
    } catch {
      preconditionFailure("HelperExportedAPI: failed to pre-encode wireContractViolation status: \(error)")
    }
  }()

  private static let log = Logger(subsystem: "com.ratiothink.app.helper", category: "xpc.exported")
  private static let identityData: Data = {
    do {
      return try XPCPayload.encode(HelperIdentity.current())
    } catch {
      preconditionFailure("HelperExportedAPI: failed to pre-encode HelperIdentity: \(error)")
    }
  }()

  /// Production engine manager. Optional so the same
  /// class still vends a usable `.stopped` reply during early
  /// helper boot before the host is constructed, and so unit tests
  /// can drive XPC selectors without a live process.
  private let engineHost: PieEngineHost?

  /// Profile → launch-spec adapter. Nil until Phase 2.4 wires
  /// `ProfileStore`; in that state `startEngine` returns
  /// `EngineError(.profileMissing, …)` rather than synthesizing a
  /// bogus spec.
  private let launchSpecResolver: LaunchSpecResolver?

  /// Owns the `ModelDownloader` for this helper process. Wired in
  /// Phase 2.5. Eagerly constructed so the first `downloadModel`
  /// call doesn't race with URLSession init on the XPC delegate queue.
  /// Internal-visibility for testability — call sites under
  /// `@testable import` can swap in a downloader configured with a
  /// URLProtocol stub.
  let downloader: ModelDownloader

  /// #448: invoked after `quitHelper` has stopped + reaped the engine, to
  /// terminate the Helper process itself. Injected by `HelperMain` as
  /// `{ NSApp.terminate(nil) }` so this RatioThinkCore type stays AppKit-free
  /// and unit-testable; `nil` (the default for the stub/test inits) makes
  /// `quitHelper` reply and then no-op the termination.
  private let onQuitRequested: (@Sendable () -> Void)?

  #if DEBUG
  /// Test seam (review v2 F30, v3 F41, v5 F63). Replaces the
  /// default reply-timeout deadline computation
  /// `handshakeTimeout * attempts + slack` /
  /// `stopGracePeriod + stopOverrun + slack` with an explicit
  /// (startEngine, stopEngine) pair. Hard-gated under `#if DEBUG`
  /// so release builds strip the storage AND the seam-aware init.
  /// Production callers cannot shorten reply deadlines even via
  /// the same Swift module (Xcode helper target) — the seam is
  /// physically absent.
  internal let replyTimeoutOverride: (start: TimeInterval, stop: TimeInterval)?
  #endif

  /// No-arg overload kept so XPC-test fixtures + the legacy
  /// `HelperExportedAPI()` call site in HelperMain (pre-supervisor)
  /// keep compiling. Equivalent to passing `supervisor: nil,
  /// launchSpecResolver: nil` — Phase 2.1 stub behavior. Allocates a
  /// default `ModelDownloader` for Phase 2.5 download selectors.
  public override init() {
    self.engineHost = nil
    self.launchSpecResolver = nil
    self.downloader = ModelDownloader()
    self.onQuitRequested = nil
    #if DEBUG
    self.replyTimeoutOverride = nil
    #endif
    super.init()
  }

  public init(engineHost: PieEngineHost? = nil,
              launchSpecResolver: LaunchSpecResolver? = nil,
              onQuitRequested: (@Sendable () -> Void)? = nil) {
    self.engineHost = engineHost
    self.launchSpecResolver = launchSpecResolver
    self.downloader = ModelDownloader()
    self.onQuitRequested = onQuitRequested
    #if DEBUG
    self.replyTimeoutOverride = nil
    #endif
    super.init()
  }

  /// Testing seam (review v15 F1 et al.): inject a pre-configured
  /// downloader (URLProtocol stub session, fake modelsRoot). Not
  /// surfaced to the public init because production code has no
  /// business swapping the downloader after the helper boots.
  init(downloader: ModelDownloader) {
    self.engineHost = nil
    self.launchSpecResolver = nil
    self.downloader = downloader
    self.onQuitRequested = nil
    #if DEBUG
    self.replyTimeoutOverride = nil
    #endif
    super.init()
  }

  #if DEBUG
  /// Test-only init (review v3 F41 + v5 F63) that exposes the
  /// reply-timeout override seam. Hard-gated under `#if DEBUG` so
  /// release builds strip the seam entirely — no in-tree caller
  /// can pass a 1ms reply deadline from production code, even
  /// within the same Swift module.
  internal init(engineHost: PieEngineHost?,
                launchSpecResolver: LaunchSpecResolver?,
                replyTimeoutOverride: (start: TimeInterval, stop: TimeInterval)?,
                onQuitRequested: (@Sendable () -> Void)? = nil) {
    self.engineHost = engineHost
    self.launchSpecResolver = launchSpecResolver
    self.downloader = ModelDownloader()
    self.onQuitRequested = onQuitRequested
    self.replyTimeoutOverride = replyTimeoutOverride
    super.init()
  }
  #endif

  // MARK: - engineStatus

  public func helperIdentity(reply: @escaping (Data) -> Void) {
    reply(Self.identityData)
  }

  public func helperProtocolVersion(reply: @escaping (Data) -> Void) {
    do {
      reply(try XPCPayload.encode(HelperProtocolCompatibility.currentVersion))
    } catch {
      Self.log.fault("helperProtocolVersion encode failed: \(String(describing: error), privacy: .public)")
      reply(PieHelperXPCWire.fallbackReplyEncodeFailureData)
    }
  }

  /// Returns the live supervisor status when one is wired. Falls back
  /// to the pre-encoded `.stopped` blob when no supervisor exists,
  /// matching the Phase 2.1 contract. Encode failures fall back to
  /// `.failed(.wireContractViolation, …)` (review v1 F7) so the GUI
  /// never renders a wire-contract violation as a healthy stopped
  /// engine.
  public func engineStatus(reply: @escaping (Data) -> Void) {
    guard let engineHost else {
      reply(Self.stoppedReplyData)
      return
    }
    do {
      let data = try XPCPayload.encode(engineHost.status)
      reply(data)
    } catch {
      Self.log.fault("engineStatus encode failed: \(String(describing: error), privacy: .public)")
      reply(Self.wireViolationStatusData)
    }
  }

  // MARK: - engineMemory

  /// Pre-encoded `Optional<EngineMemorySample>.none` reply — the "no
  /// host / not running / encode failure" payload. Encoded at type init
  /// so the catch path is provably dead, matching the other pre-encoded
  /// blobs above.
  private static let emptyMemoryData: Data = {
    do {
      return try XPCPayload.encode(Optional<EngineMemorySample>.none)
    } catch {
      preconditionFailure("HelperExportedAPI: failed to pre-encode nil EngineMemorySample: \(error)")
    }
  }()

  /// Samples the running engine's resident memory (parent pie process)
  /// and replies `XPCPayload.encode(EngineMemorySample?)`. No host
  /// wired, engine not running, or a sample failure ⇒ nil. Async
  /// because `PieEngineHost.residentMemoryBytes()` hops onto the host's
  /// state queue; the reply fires from the spawned task. The App-side
  /// `HelperXPCClient` bounds this with its own reply-timeout, so no
  /// timeout fallback is needed here (proc_pid_rusage is a cheap
  /// syscall regardless).
  public func engineMemory(reply: @escaping (Data) -> Void) {
    guard let engineHost else {
      reply(Self.emptyMemoryData)
      return
    }
    Task {
      // `.flatMap` (not `.map`): a 0-byte reading is not a valid sample
      // — `EngineMemorySample.from` collapses it to nil so it rides the
      // same "unavailable" channel as a missing engine.
      let sample = await engineHost.residentMemoryBytes()
        .flatMap { EngineMemorySample.from(residentBytes: $0) }
      do {
        reply(try XPCPayload.encode(sample))
      } catch {
        Self.log.fault("engineMemory encode failed: \(String(describing: error), privacy: .public)")
        reply(Self.emptyMemoryData)
      }
    }
  }

  // MARK: - startEngine / stopEngine

  /// Slack added on top of the engine host's timeout budget before
  /// the XPC reply-timeout fallback (review v1 F4) fires. Covers
  /// the gap between deadline arrival on the host's state queue
  /// and the observer hopping over to reply.
  ///
  /// Public so `AppXPCClient.restartReplyTimeout` derives its budget from
  /// these helper deadlines rather than a hand-picked margin (#459 review
  /// F2) — the App restart wait must always dominate the helper's serial
  /// stop+start budget.
  public static let replyTimeoutSlack: TimeInterval = 2

  /// XPC reply safety net for start / restart. Must sit ABOVE the engine's
  /// own process-lifetime lease (`LaunchSpec.handshakeTimeout` +
  /// `PieEngineHost.launchTimeoutSlack`) so this fallback never reports a
  /// premature `handshakeTimeout` for an engine that is still legitimately
  /// cold-booting a large model (#459). The production resolver sets the boot
  /// handshake to `PieControlLauncher.coldStartHandshakeTimeout` (120s); 15s
  /// of headroom covers the host slack + WS `installProgram`/`launchDaemon`
  /// rounds. The host surfaces a real `.failed` (or `.running`) via the
  /// observer long before this fires; tests inject a short
  /// `replyTimeoutOverride`. Public so the App-side restart wait derives
  /// from it (#459 review F2).
  public static let startReplyDeadline: TimeInterval =
    PieControlLauncher.coldStartHandshakeTimeout + 15

  /// `LaunchedSession.shutdown` budget: SIGINT(10s) → SIGKILL(5s) =
  /// 15s in the worst case. Add slack. Public so the App-side restart wait
  /// derives from it (#459 review F2).
  public static let stopReplyDeadline: TimeInterval = 17

  /// Spawns the engine for `profileID` via `PieEngineHost`. Returns
  /// `.profileMissing` when the resolver is unwired and
  /// `.alreadyRunning` for incompatible starts (for example, a different
  /// profile is already starting / running, or the host is stopping).
  /// Same-profile requests while the host is already `.starting` /
  /// `.running` attach to the existing launch/session instead; once the
  /// host reaches `.running`, this selector returns that session's port.
  ///
  /// Success path waits for the host to transition out of
  /// `.starting`: on `.running(port, _)` the port is encoded and
  /// returned; on `.failed(code, message)` the failure is
  /// propagated. A fallback timeout guarantees the reply block
  /// fires even if the host wedges (review v1 F4). `NSXPCConnection`
  /// reply blocks may be invoked from any thread so the observer
  /// is self-cancelling via the token argument from
  /// `PieEngineHost.observe` (review v1 F3) — no tokenBox race.
  public func startEngine(profileID: String,
                          modelOverride: String?,
                          reply: @escaping (Data?, Data?) -> Void) {
    guard let engineHost else {
      Self.log.error("startEngine: no engineHost wired (early boot or unit test)")
      reply(nil, Self.notImplementedErrorData)
      return
    }
    guard let spec = resolveLaunchSpec(profileID: profileID,
                                       explicitModel: modelOverride,
                                       engineHost: engineHost,
                                       operation: "startEngine",
                                       reply: reply) else {
      return
    }
    let replied = OSAllocatedUnfairLock<Bool>(initialState: false)
    func fireOnce(_ result: Result<EnginePort, EngineError>) {
      let already = replied.withLock { (fired: inout Bool) -> Bool in
        defer { fired = true }
        return fired
      }
      if already { return }
      PieHelperXPCWire.replyStartEngine(result, via: reply)
    }
    beginStart(engineHost: engineHost, spec: spec, fireOnce: fireOnce)
  }

  /// Strict stop→start rebuild used after the active profile's default
  /// model changes. This selector is intentionally helper-side: the
  /// helper has the only authoritative engine state, can wait for
  /// terminal stop with the same deadline as `stopEngine`, and can then
  /// start without reusing the App's generic idempotent start semantics.
  public func restartEngine(profileID: String,
                            modelOverride: String?,
                            reply: @escaping (Data?, Data?) -> Void) {
    guard let engineHost else {
      Self.log.error("restartEngine: no engineHost wired (early boot or unit test)")
      reply(nil, Self.notImplementedErrorData)
      return
    }
    // #469: thread the explicit pick through the rebuild so a model-switch on
    // a running engine boots the chosen model. `nil` keeps the existing
    // default-model-change behavior (resolver picks the profile default).
    guard let spec = resolveLaunchSpec(profileID: profileID,
                                       explicitModel: modelOverride,
                                       engineHost: engineHost,
                                       operation: "restartEngine",
                                       reply: reply) else {
      return
    }
    let replied = OSAllocatedUnfairLock<Bool>(initialState: false)
    func fireOnce(_ result: Result<EnginePort, EngineError>) {
      let already = replied.withLock { (fired: inout Bool) -> Bool in
        defer { fired = true }
        return fired
      }
      if already { return }
      PieHelperXPCWire.replyStartEngine(result, via: reply)
    }
    let advancedToStart = OSAllocatedUnfairLock<Bool>(initialState: false)
    let stopTokenBox = OSAllocatedUnfairLock<PieEngineHost.ObservationToken?>(initialState: nil)
    func cancelStopObserver() {
      stopTokenBox.withLock { (box: inout PieEngineHost.ObservationToken?) in
        box?.cancel()
        box = nil
      }
    }
    func startAfterTerminalStopOnce() {
      let already = advancedToStart.withLock { (advanced: inout Bool) -> Bool in
        defer { advanced = true }
        return advanced
      }
      cancelStopObserver()
      guard !already else { return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self, weak engineHost] in
        guard let self, let engineHost else { return }
        self.beginStart(engineHost: engineHost, spec: spec, mode: .strict, fireOnce: fireOnce)
      }
    }
    func failBeforeStartOnce(_ error: EngineError) {
      let already = advancedToStart.withLock { (advanced: inout Bool) -> Bool in
        defer { advanced = true }
        return advanced
      }
      cancelStopObserver()
      guard !already else { return }
      fireOnce(.failure(error))
    }

    switch engineHost.status {
    case .stopped, .failed:
      startAfterTerminalStopOnce()
      return
    case .starting, .running, .stopping:
      break
    }

    let token = engineHost.observe { status, _ in
      switch status {
      case .stopped:
        startAfterTerminalStopOnce()
      case .failed(let code, let message):
        failBeforeStartOnce(EngineError(code: code, message: message))
      case .starting, .running, .stopping:
        return
      }
    }
    stopTokenBox.withLock { $0 = token }
    if advancedToStart.withLock({ $0 }) { cancelStopObserver() }
    engineHost.stop()
    #if DEBUG
    let deadline: TimeInterval = replyTimeoutOverride?.stop
      ?? Self.stopReplyDeadline
    #else
    let deadline: TimeInterval = Self.stopReplyDeadline
    #endif
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
      failBeforeStartOnce(EngineError(
        code: .handshakeTimeout,
        message: "restartEngine stop phase fallback fired after \(deadline)s (host never reached terminal)"
      ))
    }
  }

  private func resolveLaunchSpec(
    profileID: String,
    explicitModel: String? = nil,
    engineHost: PieEngineHost,
    operation: String,
    reply: @escaping (Data?, Data?) -> Void
  ) -> PieControlLauncher.LaunchSpec? {
    guard let launchSpecResolver else {
      Self.log.error("\(operation, privacy: .public): no launch-spec resolver wired")
      PieHelperXPCWire.replyStartEngine(
        .failure(EngineError(code: .profileMissing,
                             message: "ProfileStore-backed resolver not wired")),
        via: reply
      )
      return nil
    }
    switch launchSpecResolver(profileID, explicitModel) {
    case .success(let spec):
      return spec
    case .failure(let err):
      Self.log.error("\(operation, privacy: .public): resolver rejected profileID=\(profileID, privacy: .public) (\(err.code.rawValue, privacy: .public))")
      if err.code == .memoryRisk {
        engineHost.recordPreStartFailure(err)
      }
      PieHelperXPCWire.replyStartEngine(.failure(err), via: reply)
      return nil
    }
  }

  private enum StartMode {
    case attachIfSameProfile
    case strict
  }

  private func beginStart(
    engineHost: PieEngineHost,
    spec: PieControlLauncher.LaunchSpec,
    mode: StartMode = .attachIfSameProfile,
    fireOnce complete: @escaping (Result<EnginePort, EngineError>) -> Void
  ) {
    let startResult: Result<Void, EngineError>
    switch mode {
    case .attachIfSameProfile:
      startResult = engineHost.startOrAttach(spec)
    case .strict:
      startResult = engineHost.start(spec)
    }
    if case .failure(let err) = startResult {
      complete(.failure(err))
      return
    }
    let replied = OSAllocatedUnfairLock<Bool>(initialState: false)
    let tokenBox = OSAllocatedUnfairLock<PieEngineHost.ObservationToken?>(initialState: nil)
    func cancelObserver() {
      tokenBox.withLock { (box: inout PieEngineHost.ObservationToken?) in
        box?.cancel()
        box = nil
      }
    }
    /// Resolve the single startEngine/restartEngine reply. Returns `true`
    /// when THIS call won the race (it delivered the reply), `false` when a
    /// prior path already replied. The XPC reply timeout uses this only to
    /// avoid duplicate XPC replies; engine launch cleanup remains owned by
    /// `PieEngineHost`'s attempt-scoped launch timeout.
    @discardableResult
    func finish(_ result: Result<EnginePort, EngineError>) -> Bool {
      let already = replied.withLock { (fired: inout Bool) -> Bool in
        defer { fired = true }
        return fired
      }
      cancelObserver()
      if already { return false }
      complete(result)
      return true
    }
    let token = engineHost.observe { status, _ in
      guard let result = Self.startEngineTerminalResult(for: status,
                                                        requestedProfileID: spec.profileID) else { return }
      finish(result)
    }
    tokenBox.withLock { $0 = token }
    if replied.withLock({ $0 }) { cancelObserver() }
    #if DEBUG
    let deadline: TimeInterval = replyTimeoutOverride?.start
      ?? Self.startReplyDeadline
    #else
    let deadline: TimeInterval = Self.startReplyDeadline
    #endif
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) { [weak engineHost] in
      // The XPC reply timeout is NOT an engine lifetime lease. It exists only
      // to complete this selector's reply block if the observer path wedges or
      // loses a race. Process cleanup for a stuck launch belongs to
      // PieEngineHost's attempt-scoped launch timeout; calling `stop()` here
      // can kill a healthy `.running` engine after an earlier success reply.
      guard let engineHost else {
        finish(.failure(EngineError(
          code: .handshakeTimeout,
          message: "startEngine reply-timeout fallback fired after \(deadline)s (host unavailable)"
        )))
        return
      }
      if let result = Self.startEngineTerminalResult(for: engineHost.status,
                                                     requestedProfileID: spec.profileID) {
        finish(result)
      } else {
        DiagnosticLog.helper.event("xpc.startEngine.reply_timeout", [
          ("profile", spec.profileID),
          ("state", String(describing: engineHost.status)),
          ("action", "reply_only_no_lifetime_stop"),
          ("deadline", String(format: "%.1f", deadline)),
        ])
        finish(.failure(EngineError(
          code: .handshakeTimeout,
          message: "startEngine reply-timeout fallback fired after \(deadline)s (host still starting; launch cleanup is host-owned)"
        )))
      }
    }
  }

  private static func startEngineTerminalResult(
    for status: EngineStatus,
    requestedProfileID: String
  ) -> Result<EnginePort, EngineError>? {
    switch status {
    case .running(let port, let pid) where pid == requestedProfileID:
      return .success(port)
    case .running:
      return .failure(EngineError(code: .alreadyRunning,
                                  message: "engine host running a different profile"))
    case .failed(let code, let message):
      return .failure(EngineError(code: code, message: message))
    case .stopped:
      return .failure(EngineError(code: .spawnFailed,
                                  message: "engine returned to stopped before handshake"))
    case .starting, .stopping:
      return nil
    }
  }

  /// Stops the supervised engine via `PieEngineHost.stop()`. Replies
  /// nil on success once the host confirms `.stopped` / `.failed`,
  /// or the notImplemented blob when no host is wired. A fallback
  /// timeout guarantees the reply fires even if the host wedges.
  public func stopEngine(reply: @escaping (Data?) -> Void) {
    guard let engineHost else {
      Self.log.error("stopEngine: no engineHost wired")
      reply(Self.notImplementedErrorData)
      return
    }
    let replied = OSAllocatedUnfairLock<Bool>(initialState: false)
    let tokenBox = OSAllocatedUnfairLock<PieEngineHost.ObservationToken?>(initialState: nil)
    func cancelObserver() {
      tokenBox.withLock { (box: inout PieEngineHost.ObservationToken?) in
        box?.cancel()
        box = nil
      }
    }
    func fireOnce(_ payload: EngineError?) {
      let already = replied.withLock { (fired: inout Bool) -> Bool in
        defer { fired = true }
        return fired
      }
      cancelObserver()
      if already { return }
      PieHelperXPCWire.replyStopEngine(payload, via: reply)
    }
    let token = engineHost.observe { status, _ in
      let payload: EngineError?
      switch status {
      case .stopped: payload = nil
      case .failed(let code, let message):
        payload = EngineError(code: code, message: message)
      case .starting, .running, .stopping: return
      }
      fireOnce(payload)
    }
    tokenBox.withLock { $0 = token }
    if replied.withLock({ $0 }) { cancelObserver() }
    engineHost.stop(reason: "xpc.stopEngine")
    #if DEBUG
    let deadline: TimeInterval = replyTimeoutOverride?.stop
      ?? Self.stopReplyDeadline
    #else
    let deadline: TimeInterval = Self.stopReplyDeadline
    #endif
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
      fireOnce(EngineError(
        code: .handshakeTimeout,
        message: "stopEngine reply-timeout fallback fired after \(deadline)s (host never reached terminal)"
      ))
    }
  }

  /// Phase 2.5: hand off to `ModelDownloader`. Re-stamps
  /// `DownloadError` into `EngineError` at the wire boundary so the
  /// GUI sees structured `EngineErrorCode` values rather than
  /// downloader-internal enum cases.
  public func downloadModel(repo: String, file: String,
                            reply: @escaping (Data?, Data?) -> Void) {
    Self.log.info("downloadModel repo=\(repo, privacy: .public) file=\(file, privacy: .public)")
    let result = downloader.start(repo: repo, file: file)
      .mapError { Self.engineError(forDownload: $0) }
    PieHelperXPCWire.replyDownloadModel(result, via: reply)
  }

  public func cancelDownload(handle handleData: Data, reply: @escaping (Data?) -> Void) {
    let decoded: DownloadHandle
    do {
      decoded = try XPCPayload.decode(DownloadHandle.self, from: handleData)
    } catch {
      Self.log.error("cancelDownload: decode handle failed: \(String(describing: error), privacy: .public)")
      PieHelperXPCWire.replyCancelDownload(
        EngineError(code: .wireContractViolation,
                    message: "cancelDownload handle decode failed: \(error)"),
        via: reply)
      return
    }
    Self.log.info("cancelDownload handle=\(decoded.id.uuidString, privacy: .public)")
    let mapped = downloader.cancel(handle: decoded).map { Self.engineError(forDownload: $0) }
    PieHelperXPCWire.replyCancelDownload(mapped, via: reply)
  }

  /// Map `DownloadError` cases onto the closed `EngineErrorCode`
  /// surface. Review v1 F17 split the prior `.unknown` collapse into
  /// three discrete codes so the GUI can route integrity / transport /
  /// disk failures to different recovery UI (checksum-warning banner
  /// vs. retry button vs. disk-full diagnostic).
  ///
  /// - `.unknownHandle`  → `.wireContractViolation` (caller bug)
  /// - `.cancelled`       → `.cancelled`
  /// - `.alreadyInFlight` → `.alreadyRunning`
  /// - `.transportFailed` → `.networkFailed`
  /// - `.httpStatus`      → `.networkFailed`
  /// - `.sha256Mismatch`  → `.integrityFailed`  (security signal)
  /// - `.writeFailed`     → `.diskWriteFailed`
  /// - `.modelsRootUnavailable` → `.degraded`
  /// Percent-encode `NSError.domain` so the cause-token packing
  /// (`[domain=… code=… errno=…]`) survives free-form domain values
  /// containing whitespace, `=`, or `]`. Encodes anything outside
  /// `urlPathAllowed` AND the structural token characters; reverses
  /// with `removingPercentEncoding`. Review v8 F2.
  static func percentEncodeDomain(_ domain: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: " =]")
    return domain.addingPercentEncoding(withAllowedCharacters: allowed) ?? domain
  }

  static func engineError(forDownload error: DownloadError) -> EngineError {
    switch error {
    case .unknownHandle:
      return EngineError(code: .wireContractViolation,
                         message: "ModelDownloader: unknown handle")
    case .cancelled:
      return EngineError(code: .cancelled, message: "download cancelled")
    case .alreadyInFlight(let repo, let file):
      return EngineError(code: .alreadyRunning,
                         message: "download already in flight for \(repo)/\(file)")
    case .transportFailed(let message, _):
      // `resumeAvailable` is *intentionally* not surfaced on the
      // wire at Phase 2.5 (review v3 F1 — there is no GUI consumer
      // yet, and the v2 string-smuggling approach was undefended
      // dead code that a reformat could silently regress). The
      // signal lives in `helper.log` and on the in-process
      // `DownloadError`. When Phase 6.1 wires `HTTPEngineClient`
      // and the XPC progress channel lands, that phase adds
      // a typed `resumeAvailable` field to the wire payload.
      return EngineError(code: .networkFailed,
                         message: "transport failure: \(message)")
    case .httpStatus(let code):
      return EngineError(code: .networkFailed, message: "HTTP \(code)")
    case .sha256Mismatch(let expected, let actual):
      return EngineError(code: .integrityFailed,
                         message: "SHA-256 mismatch: expected=\(expected) actual=\(actual)")
    case .writeFailed(let message, let cause):
      // Embed structured cause tokens in the message so a GUI log
      // scraper can deterministically extract domain/code/errno
      // without parsing free-form text (review v7 F5). `domain` is
      // a free-form `String` on `NSError` and Foundation does not
      // guarantee it lacks whitespace / `=` / `]` (third-party
      // domains can contain anything), so percent-encode it before
      // embedding (review v8 F2). The other fields are integers and
      // safe by construction. Scrapers reverse with
      // `removingPercentEncoding`. TODO: replace this whole
      // message-smuggling surface with a typed wire field once the
      // XPC progress channel lands.
      let causeSuffix: String = {
        guard let cause else { return "" }
        var parts = ["domain=\(Self.percentEncodeDomain(cause.domain))",
                     "code=\(cause.code)"]
        if let errno = cause.posixErrno { parts.append("errno=\(errno)") }
        return " [" + parts.joined(separator: " ") + "]"
      }()
      return EngineError(code: .diskWriteFailed,
                         message: "write failed\(causeSuffix): \(message)")
    case .modelsRootUnavailable(let message):
      return EngineError(code: .degraded, message: "models root unavailable: \(message)")
    case .invalidArguments(let message):
      // Review v16 F2 / v17 F5: a path-traversal attempt or
      // builder-rejected input is a caller-input failure — surface
      // as `.invalidInput` so the GUI renders "please correct
      // repo/file" rather than "Rational internal bug." Reserves
      // `.wireContractViolation` for actual XPC plumbing bugs per
      // its doc-comment.
      return EngineError(code: .invalidInput,
                         message: "invalid arguments: \(message)")
    }
  }

  public func listProfiles(reply: @escaping (Data) -> Void) {
    Self.log.error("listProfiles called on Phase 2.1 stub")
    // Empty-list TOML array is a safe Phase 2.1 answer: the GUI sees
    // "no profiles" and renders the empty state. Phase 4 wires the
    // real `ProfileStore` listing.
    reply(Self.emptyProfilesData)
  }

  public func reloadProfiles(reply: @escaping (Data?) -> Void) {
    Self.log.error("reloadProfiles called on Phase 2.1 stub")
    reply(Self.notImplementedErrorData)
  }

  public func tailLog(stream: String,
                      reply: @escaping (FileHandle?, Data?) -> Void) {
    Self.log.error("tailLog called on Phase 2.1 stub (stream=\(stream, privacy: .public))")
    reply(nil, Self.notImplementedErrorData)
  }

  /// PR12 review v5 F58: surface the `clearKillRejected` recovery
  /// path over XPC. Forwards to `PieSupervisor.clearKillRejected()`,
  /// which verifies the zombie pid is reaped (via the retained
  /// Process reference per F59) before transitioning to `.stopped`.
  /// Replies nil on success, `EngineError(.killRejected, …)` when
  /// the supervisor refuses (engine still alive, no zombie
  /// tracked, not in killRejected state).
  ///  unwired `PieSupervisor` from production; the
  /// `.killRejected` recovery path is part of PieSupervisor's
  /// out-of-scope restart-ladder + boot-recovery logic and has not
  /// been ported to `PieEngineHost`. Surface a structured error
  /// instead of silently no-oping so a GUI button that drives this
  /// selector (none exists today) gets a real cause line.
  public func clearKillRejected(reply: @escaping (Data?) -> Void) {
    Self.log.error("clearKillRejected: not implemented under PieEngineHost — follow-up required")
    let err = EngineError(
      code: .wireContractViolation,
      message: "clearKillRejected is not supported by PieEngineHost ( left PieSupervisor's restart/boot-recovery out of scope; track the follow-up before wiring a GUI button)"
    )
    do {
      reply(try XPCPayload.encode(err))
    } catch {
      Self.log.fault("clearKillRejected encode failed: \(String(describing: error), privacy: .public)")
      reply(PieHelperXPCWire.fallbackReplyEncodeFailureData)
    }
  }

  // MARK: - quitHelper (#448)

  /// Full-product quit. Stops the engine and WAITS for it to reach a
  /// terminal state — `PieEngineHost.stop()` only publishes `.stopped`
  /// after `LaunchedSession.shutdown` (SIGINT → grace → SIGKILL) has reaped
  /// `pie`, so awaiting `.stopped`/`.failed` guarantees no orphan engine
  /// before the Helper exits. Then replies and fires `onQuitRequested`
  /// (wired by `HelperMain` to `NSApp.terminate`) for a clean exit so
  /// launchd's `KeepAlive { SuccessfulExit: false }` does not relaunch it.
  ///
  /// If the deadline expires before a terminal/reaped state, `quitHelper`
  /// replies with a structured timeout and does NOT terminate the Helper. This
  /// keeps the Helper alive as the owner of the engine session so the App can
  /// cancel normal quit and offer retry / explicit force-quit recovery.
  public func quitHelper(reply: @escaping (Data?) -> Void) {
    Self.log.info("quitHelper: tearing down engine then terminating helper")
    guard let engineHost else {
      // No engine to reap (early boot / stub) — just acknowledge + exit.
      PieHelperXPCWire.replyStopEngine(nil, via: reply)
      onQuitRequested?()
      return
    }
    #if DEBUG
    let deadline = replyTimeoutOverride?.stop ?? Self.stopReplyDeadline
    #else
    let deadline = Self.stopReplyDeadline
    #endif
    HelperQuitTeardown.stopThenTerminate(
      engineHost: engineHost,
      initialTimeout: deadline,
      onTerminalBeforeTimeout: { _ in
        PieHelperXPCWire.replyStopEngine(nil, via: reply)
      },
      onTerminalFailure: { result in
        let error: EngineError
        if case let .failed(code, message) = result.lastStatus {
          error = EngineError(code: code, message: message)
        } else {
          error = EngineError(
            code: .unknown,
            message: "quitHelper stop/reap failed before pie was confirmed reaped (last status: \(result.lastStatus))"
          )
        }
        PieHelperXPCWire.replyStopEngine(error, via: reply)
      },
      onTimeout: { result in
        PieHelperXPCWire.replyStopEngine(EngineError(
          code: .handshakeTimeout,
          message: "quitHelper stop/reap timeout after \(deadline)s (last status: \(result.lastStatus)); normal quit is blocked until pie reaches a terminal/reaped state"
        ), via: reply)
      },
      terminate: { [onQuitRequested] in onQuitRequested?() }
    )
  }
}

/// Degraded-mode `PieHelperXPC` implementation. Used when the helper
/// booted but cannot reach its state directory (`PieDirsError`). The
/// listener still publishes the mach service so the GUI receives a
/// structured `EngineError(.degraded, message: <PieDirsError>)`
/// instead of a generic mach-service-not-found (review v1 F12).
///
/// Every selector returns the same pre-encoded degraded payload —
/// shaped to fit each reply tuple. `engineStatus` returns
/// `.failed(.degraded, ...)` so the GUI menu-bar dot can render the
/// dot color *plus* surface the message.
public final class DegradedHelperAPI: NSObject, PieHelperXPC {
  private let reasonMessage: String
  private let degradedErrorData: Data
  private let degradedStatusData: Data
  /// Pre-encoded empty `[String]` for `listProfiles`. Same rationale
  /// as `HelperExportedAPI.emptyProfilesData` (review v2 F5) — the
  /// prior catch path replied with `EngineError`-shaped bytes into a
  /// `[String]` slot, which the GUI decoded as wire corruption.
  private let emptyProfilesData: Data
  private let identityData: Data

  /// #448: self-terminate hook, same contract as `HelperExportedAPI`. A
  /// degraded Helper owns no engine, so `quitHelper` just acknowledges and
  /// fires this to exit cleanly.
  private let onQuitRequested: (@Sendable () -> Void)?

  private static let log = Logger(subsystem: "com.ratiothink.app.helper", category: "xpc.exported.degraded")

  /// `reasonMessage` is folded into both `EngineError.message` and
  /// `EngineStatus.failed.message` so a single source of truth flows
  /// from PieDirsError → wire → GUI alert.
  public init(reasonMessage: String, onQuitRequested: (@Sendable () -> Void)? = nil) {
    self.reasonMessage = reasonMessage
    self.onQuitRequested = onQuitRequested
    let err = EngineError(code: .degraded, message: reasonMessage)
    do {
      self.degradedErrorData = try XPCPayload.encode(err)
    } catch {
      preconditionFailure("DegradedHelperAPI: failed to encode EngineError(.degraded): \(error)")
    }
    let status = EngineStatus.failed(code: .degraded, message: reasonMessage)
    do {
      self.degradedStatusData = try XPCPayload.encode(status)
    } catch {
      preconditionFailure("DegradedHelperAPI: failed to encode EngineStatus.failed(.degraded): \(error)")
    }
    do {
      self.emptyProfilesData = try XPCPayload.encode([String]())
    } catch {
      preconditionFailure("DegradedHelperAPI: failed to encode empty profiles list: \(error)")
    }
    do {
      self.identityData = try XPCPayload.encode(HelperIdentity.current())
    } catch {
      preconditionFailure("DegradedHelperAPI: failed to encode HelperIdentity: \(error)")
    }
    super.init()
  }

  public func helperIdentity(reply: @escaping (Data) -> Void) {
    reply(identityData)
  }

  public func engineStatus(reply: @escaping (Data) -> Void) {
    Self.log.info("engineStatus -> .degraded")
    reply(degradedStatusData)
  }

  public func helperProtocolVersion(reply: @escaping (Data) -> Void) {
    reply((try? XPCPayload.encode(HelperProtocolCompatibility.currentVersion))
          ?? PieHelperXPCWire.fallbackReplyEncodeFailureData)
  }

  public func engineMemory(reply: @escaping (Data) -> Void) {
    // No engine runs in degraded mode → RSS unavailable. `nil` cannot
    // realistically fail to encode; the literal "null" fallback decodes
    // to the same nil EngineMemorySample?.
    reply((try? XPCPayload.encode(Optional<EngineMemorySample>.none)) ?? Data("null".utf8))
  }

  public func startEngine(profileID: String,
                          modelOverride: String?,
                          reply: @escaping (Data?, Data?) -> Void) {
    Self.log.error("startEngine refused in degraded mode (profileID=\(profileID, privacy: .public))")
    reply(nil, degradedErrorData)
  }

  public func restartEngine(profileID: String,
                            modelOverride: String?,
                            reply: @escaping (Data?, Data?) -> Void) {
    Self.log.error("restartEngine refused in degraded mode (profileID=\(profileID, privacy: .public))")
    reply(nil, degradedErrorData)
  }

  public func stopEngine(reply: @escaping (Data?) -> Void) {
    reply(degradedErrorData)
  }

  public func downloadModel(repo: String, file: String,
                            reply: @escaping (Data?, Data?) -> Void) {
    Self.log.error("downloadModel refused in degraded mode (repo=\(repo, privacy: .public) file=\(file, privacy: .public))")
    reply(nil, degradedErrorData)
  }

  public func cancelDownload(handle: Data, reply: @escaping (Data?) -> Void) {
    reply(degradedErrorData)
  }

  public func listProfiles(reply: @escaping (Data) -> Void) {
    // No state dir means no ProfileStore; return an empty list and
    // let `engineStatus` carry the cause. GUI gets the empty state
    // banner + the failed-engine dot in parallel.
    reply(emptyProfilesData)
  }

  public func reloadProfiles(reply: @escaping (Data?) -> Void) {
    reply(degradedErrorData)
  }

  public func tailLog(stream: String,
                      reply: @escaping (FileHandle?, Data?) -> Void) {
    reply(nil, degradedErrorData)
  }

  /// PR12 review v5 F58: degraded helpers cannot recover — they
  /// never owned an engine. Refuse with the standard degraded error
  /// so the GUI keeps presenting the degraded-mode affordance
  /// instead of optimistically retrying.
  public func clearKillRejected(reply: @escaping (Data?) -> Void) {
    reply(degradedErrorData)
  }

  /// #448: a degraded Helper owns no engine, so there is nothing to reap —
  /// acknowledge the quit and terminate. Honoring quit (rather than
  /// returning the degraded error) lets the user fully dismiss a broken
  /// Helper from the menu bar.
  public func quitHelper(reply: @escaping (Data?) -> Void) {
    Self.log.info("quitHelper: degraded helper terminating (no engine to reap)")
    reply(nil)
    onQuitRequested?()
  }
}
