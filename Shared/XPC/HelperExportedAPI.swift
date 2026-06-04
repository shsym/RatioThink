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
  public typealias LaunchSpecResolver = (String) -> Result<PieControlLauncher.LaunchSpec, EngineError>

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
    #if DEBUG
    self.replyTimeoutOverride = nil
    #endif
    super.init()
  }

  public init(engineHost: PieEngineHost? = nil,
              launchSpecResolver: LaunchSpecResolver? = nil) {
    self.engineHost = engineHost
    self.launchSpecResolver = launchSpecResolver
    self.downloader = ModelDownloader()
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
                replyTimeoutOverride: (start: TimeInterval, stop: TimeInterval)?) {
    self.engineHost = engineHost
    self.launchSpecResolver = launchSpecResolver
    self.downloader = ModelDownloader()
    self.replyTimeoutOverride = replyTimeoutOverride
    super.init()
  }
  #endif

  // MARK: - engineStatus

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
  private static let replyTimeoutSlack: TimeInterval = 2

  /// PieControlLauncher's `handshakeTimeout` + WS install upper bound.
  /// `LaunchSpec.handshakeTimeout` defaults to 30s; the WS
  /// `installProgram` + `launchDaemon` rounds add at most a few
  /// seconds on cold boot. 60s + slack is the safety net for the
  /// XPC reply — the host itself will surface a real failure long
  /// before this fires.
  private static let startReplyDeadline: TimeInterval = 60

  /// `LaunchedSession.shutdown` budget: SIGINT(10s) → SIGKILL(5s) =
  /// 15s in the worst case. Add slack.
  private static let stopReplyDeadline: TimeInterval = 17

  /// Spawns the engine for `profileID` via `PieEngineHost`. Returns
  /// `.profileMissing` when the resolver is unwired and
  /// `.alreadyRunning` when a host is already starting / running.
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
                          reply: @escaping (Data?, Data?) -> Void) {
    guard let engineHost else {
      Self.log.error("startEngine: no engineHost wired (early boot or unit test)")
      reply(nil, Self.notImplementedErrorData)
      return
    }
    guard let launchSpecResolver else {
      Self.log.error("startEngine: no launch-spec resolver wired")
      PieHelperXPCWire.replyStartEngine(
        .failure(EngineError(code: .profileMissing,
                             message: "ProfileStore-backed resolver not wired")),
        via: reply
      )
      return
    }
    let resolved = launchSpecResolver(profileID)
    let spec: PieControlLauncher.LaunchSpec
    switch resolved {
    case .success(let s): spec = s
    case .failure(let err):
      Self.log.error("startEngine: resolver rejected profileID=\(profileID, privacy: .public) (\(err.code.rawValue, privacy: .public))")
      if err.code == .memoryRisk {
        engineHost.recordPreStartFailure(err)
      }
      PieHelperXPCWire.replyStartEngine(.failure(err), via: reply)
      return
    }
    if case .failure(let err) = engineHost.start(spec) {
      PieHelperXPCWire.replyStartEngine(.failure(err), via: reply)
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
    func fireOnce(_ result: Result<EnginePort, EngineError>) {
      let already = replied.withLock { (fired: inout Bool) -> Bool in
        defer { fired = true }
        return fired
      }
      cancelObserver()
      if already { return }
      PieHelperXPCWire.replyStartEngine(result, via: reply)
    }
    let token = engineHost.observe { status, _ in
      let shouldFire: (Result<EnginePort, EngineError>)?
      switch status {
      case .running(let port, let pid) where pid == spec.profileID:
        shouldFire = .success(port)
      case .running:
        shouldFire = .failure(EngineError(code: .alreadyRunning,
                                          message: "engine host running a different profile"))
      case .failed(let code, let message):
        shouldFire = .failure(EngineError(code: code, message: message))
      case .stopped:
        shouldFire = .failure(EngineError(code: .spawnFailed,
                                          message: "engine returned to stopped before handshake"))
      case .starting, .stopping:
        shouldFire = nil
      }
      guard let result = shouldFire else { return }
      fireOnce(result)
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
      // Review v1 F1: cancel the in-flight launch BEFORE firing the
      // failure reply. Without this the host stays in `.starting`; a
      // slow `pie serve` boot then publishes `.running` after the
      // client already received `.handshakeTimeout`, and a subsequent
      // `startEngine` is rejected with `.alreadyRunning` against an
      // orphan engine the client never saw acknowledged.
      engineHost?.stop()
      fireOnce(.failure(EngineError(
        code: .handshakeTimeout,
        message: "startEngine reply-timeout fallback fired after \(deadline)s (host never transitioned out of .starting)"
      )))
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
    engineHost.stop()
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

  /// Reshaped to `(Data?, Data?) -> Void`. Phase 2.1 returns the
  /// notImplemented error on the error slot — no fake handle (review
  /// v1 F8).
  public func loadModel(modelID: String,
                        reply: @escaping (Data?, Data?) -> Void) {
    Self.log.error("loadModel called on Phase 2.1 stub (modelID=\(modelID, privacy: .public))")
    reply(nil, Self.notImplementedErrorData)
  }

  public func cancelLoad(handle: Data, reply: @escaping (Data?) -> Void) {
    Self.log.error("cancelLoad called on Phase 2.1 stub")
    reply(Self.notImplementedErrorData)
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
      // repo/file" rather than "RatioThink internal bug." Reserves
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

  private static let log = Logger(subsystem: "com.ratiothink.app.helper", category: "xpc.exported.degraded")

  /// `reasonMessage` is folded into both `EngineError.message` and
  /// `EngineStatus.failed.message` so a single source of truth flows
  /// from PieDirsError → wire → GUI alert.
  public init(reasonMessage: String) {
    self.reasonMessage = reasonMessage
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
    super.init()
  }

  public func engineStatus(reply: @escaping (Data) -> Void) {
    Self.log.info("engineStatus -> .degraded")
    reply(degradedStatusData)
  }

  public func engineMemory(reply: @escaping (Data) -> Void) {
    // No engine runs in degraded mode → RSS unavailable. `nil` cannot
    // realistically fail to encode; the literal "null" fallback decodes
    // to the same nil EngineMemorySample?.
    reply((try? XPCPayload.encode(Optional<EngineMemorySample>.none)) ?? Data("null".utf8))
  }

  public func startEngine(profileID: String,
                          reply: @escaping (Data?, Data?) -> Void) {
    Self.log.error("startEngine refused in degraded mode (profileID=\(profileID, privacy: .public))")
    reply(nil, degradedErrorData)
  }

  public func stopEngine(reply: @escaping (Data?) -> Void) {
    reply(degradedErrorData)
  }

  public func loadModel(modelID: String,
                        reply: @escaping (Data?, Data?) -> Void) {
    Self.log.error("loadModel refused in degraded mode (modelID=\(modelID, privacy: .public))")
    reply(nil, degradedErrorData)
  }

  public func cancelLoad(handle: Data, reply: @escaping (Data?) -> Void) {
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
}
