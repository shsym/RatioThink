import Foundation

/// Loopback TCP port the engine listens on.
///
/// `UInt16` matches the OS-level port type so impossible values (negative,
/// >65535) can't make it across the wire (review F2). Port 0 is still
/// reachable through the type but `EngineStatus.running`'s decoder
/// rejects it — the engine never auto-binds, so 0 is always a bug.
///
/// Named `EnginePort`, not `Port`, because Foundation re-exports
/// `NSPort` as `Port` in Swift on macOS 14+, which makes unqualified
/// `Port` ambiguous everywhere `import Foundation` is in scope.
public typealias EnginePort = UInt16

/// Engine lifecycle state observed by `PieEngineHost`. Single source of
/// truth for menu-bar dot color and chat startup gating. The `running`
/// case carries the full `EngineSessionSnapshot` (#476) — port, active
/// profile id, served model id, effective `max_tokens` ceiling, the launch
/// generation, and the effective Local API daemon bind mode — so the App
/// reads the whole session off ONE channel instead of reconciling
/// served-model + request limits through `/v1/models` and transient view
/// state. A nil `daemonBindHost` inside the snapshot means an older helper
/// payload, not confirmed loopback.
///
/// `failed` carries a discriminator (`EngineErrorCode`) plus a bounded
/// message so the GUI can route on the code rather than substring-match
/// the human text (review F7). The encoder truncates `message` to
/// `failedMessageCap` bytes with an explicit marker.
public enum EngineStatus: Codable, Equatable, Sendable {
  case stopped
  case starting
  case running(EngineSessionSnapshot)
  case stopping
  case failed(code: EngineErrorCode, message: String)

  /// Cap on the `failed.message` payload at encode time. 1 KiB is
  /// enough for any human-readable cause line we want to surface; the
  /// full diagnostic belongs in `helper.log`. Beyond this we append
  /// `failedMessageTruncationMarker`.
  public static let failedMessageCap = 1024
  public static let failedMessageTruncationMarker = "…[truncated]"

  private enum Kind: String, Codable { case stopped, starting, running, stopping, failed }
  private enum CodingKeys: String, CodingKey { case kind, snapshot, code, message }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .stopped:  self = .stopped
    case .starting: self = .starting
    case .running:
      let snapshot = try c.decode(EngineSessionSnapshot.self, forKey: .snapshot)
      // Port 0 means "any" to bind(2) but the engine always picks an
      // explicit port and reports it in the handshake. A 0 here is a
      // helper bug or wire corruption — fail closed.
      guard snapshot.port != 0 else {
        throw DecodingError.dataCorruptedError(
          forKey: .snapshot, in: c,
          debugDescription: "EngineStatus.running snapshot.port=0 is invalid; engine never reports auto-bind"
        )
      }
      self = .running(snapshot)
    case .stopping: self = .stopping
    case .failed:
      self = .failed(
        code: try c.decode(EngineErrorCode.self, forKey: .code),
        message: try c.decode(String.self, forKey: .message)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .stopped:  try c.encode(Kind.stopped,  forKey: .kind)
    case .starting: try c.encode(Kind.starting, forKey: .kind)
    case .running(let snapshot):
      // Symmetric guard with the decoder (review v2 F5). UInt16
      // forbids negative/oversized at the type level but admits 0,
      // and the engine never auto-binds — so a helper bug that
      // produces a `snapshot.port == 0` must surface at the encode
      // site, not on the GUI's decode where the trail is cold.
      guard snapshot.port != 0 else {
        throw EncodingError.invalidValue(
          snapshot.port,
          EncodingError.Context(
            codingPath: encoder.codingPath + [CodingKeys.snapshot],
            debugDescription: "EngineStatus.running must not carry snapshot.port=0; the engine never auto-binds"
          )
        )
      }
      try c.encode(Kind.running, forKey: .kind)
      try c.encode(snapshot,     forKey: .snapshot)
    case .stopping: try c.encode(Kind.stopping, forKey: .kind)
    case .failed(let code, let message):
      try c.encode(Kind.failed, forKey: .kind)
      try c.encode(code,        forKey: .code)
      try c.encode(Self.cappedFailedMessage(message), forKey: .message)
    }
  }

  /// Truncate `message` to `failedMessageCap` UTF-8 bytes, appending
  /// `failedMessageTruncationMarker` when truncated. Cap is enforced
  /// at encode time so a misbehaving helper can't ship a multi-MB
  /// string to the GUI.
  public static func cappedFailedMessage(_ message: String) -> String {
    let utf8Count = message.utf8.count
    guard utf8Count > failedMessageCap else { return message }
    // Walk character boundaries so we don't slice a multi-byte UTF-8
    // sequence in half.
    var truncated = message
    while truncated.utf8.count > failedMessageCap {
      truncated.removeLast()
    }
    return truncated + failedMessageTruncationMarker
  }
}

/// Opaque ticket the helper hands back when a download starts. GUI uses
/// it to subscribe to progress and to cancel. `id` is enough to dedupe;
/// `repo`/`file` are echoed so the GUI can render handle lists without
/// a second round-trip.
public struct DownloadHandle: Codable, Equatable, Hashable, Sendable {
  public let id: UUID
  public let repo: String
  public let file: String

  public init(id: UUID = UUID(), repo: String, file: String) {
    self.id = id
    self.repo = repo
    self.file = file
  }
}

/// Discriminated engine failure category. Kept narrow on purpose; new
/// cases require a deliberate decision about how the GUI should render
/// them. Bag any extra detail in `message`.
///
/// `wireContractViolation` exists so XPC plumbing bugs (double-set
/// reply tuple, missing payload, type-skewed Data) route to a distinct
/// "this is a Rational bug, not an engine failure" path in the GUI rather
/// than being lumped with `.unknown` (review F8).
public enum EngineErrorCode: String, Codable, Sendable {
  case spawnFailed
  case handshakeTimeout
  case modelMissing
  case profileMissing
  case portUnavailable
  case alreadyRunning
  case cancelled
  case wireContractViolation
  /// Helper booted but cannot reach its state directory (PieDirsError
  /// at startup). The listener stays published so the GUI receives a
  /// structured cause instead of a generic mach-service-not-found
  /// (review v1 F12); every selector returns `.degraded` until the
  /// helper relaunches under healthier conditions.
  case degraded
  /// Download integrity check failed — SHA-256 mismatch between the
  /// digest HF advertised (`X-Linked-Etag`) and what we hashed off
  /// disk. Distinct from `.unknown` so the GUI can route this to a
  /// "checksum mismatch — likely tampering or CDN corruption" surface
  /// rather than a generic transport retry banner ( review
  /// v1 F17). Added Phase 2.5.
  case integrityFailed
  /// Transport-level failure during download: connection drop, DNS,
  /// non-2xx HTTP status, or any other `URLError` that isn't a user
  /// cancellation. Separate from `.unknown` so retry/backoff UI can
  /// branch on it (review v1 F17).
  case networkFailed
  /// Local filesystem write failed: `mkdir`, rename, `fsync`, or
  /// `.partial` cleanup. Distinct from `.unknown` so the GUI can
  /// surface a "disk full / permission denied" path rather than a
  /// generic transport error (review v1 F17).
  case diskWriteFailed
  /// Caller-supplied input failed validation BEFORE any engine work:
  /// `repo`/`file` path-traversal, malformed URL, NUL byte, etc.
  /// Distinct from `.wireContractViolation` (which is reserved for
  /// Rational-internal plumbing bugs — see comment above) so the GUI can
  /// surface "please correct repo/file" instead of "Rational internal bug
  /// — please file a bug report" (review v17 F5). Added Phase 2.5.
  case invalidInput
  /// Engine subprocess could not be reaped (SIGKILL rejected:
  /// sandbox EPERM, uninterruptible sleep, etc). Distinct from
  /// `spawnFailed` so the GUI can surface a "manual cleanup
  /// required — pie still alive" affordance instead of an
  /// auto-retry hint (review v3 F40).
  ///
  /// Recovery contract (review v4 F50, v5 F58/F59, v6 F69/F70):
  /// `start()` refuses while the supervisor is in
  /// `.failed(.killRejected, _)`. Available recovery paths today:
  ///  · `PieSupervisor.clearKillRejected()` (in-process) — verifies
  ///    the retained `Process` reference is no longer running via
  ///    Foundation's wait4 bookkeeping before transitioning to
  ///    `.stopped` (pid-reuse-safe per F59).
  ///  · `PieHelperXPC.clearKillRejected(reply:)` — wire-level
  ///    selector wraps the above. The App-side GUI button that
  ///    drives this selector is NOT yet implemented (planned for
  ///    Phase 3+); today only programmatic XPC clients can invoke.
  ///  · Helper relaunch — `PieSupervisor.processBootRecovery` runs
  ///    at init, reads the persisted `engine.killrejected.json`
  ///    manifest, sends one-shot SIGKILL to the orphan, and
  ///    deletes the manifest. After this the helper publishes a
  ///    clean `.stopped`.
  ///  · `kill -9 <pid>` manually (pid is in the fault log).
  case killRejected
  /// The requested model was rejected before launch because its
  /// resolved local artifact size is above Rational.app's v1 memory safety
  /// limit, or because the app could not determine the artifact size
  /// safely. This is a user-recoverable model choice problem, not a
  /// Pie binary/process failure.
  case memoryRisk
  /// The engine died or became unresponsive AFTER a successful launch
  /// handshake (process exited, or the control-plane liveness ping
  /// stopped answering) —  G1. Distinct from `spawnFailed`
  /// (which is a launch-time failure) so the GUI can route post-launch
  /// engine death to a relaunch affordance. The accompanying message
  /// carries the coarse cause (exit status / "control plane
  /// unreachable"); the rich death reason from captured engine stderr
  /// is deferred to . Detection is client-side and needs no .
  case engineGone
  /// Engine/helper reported that the selected model artifact or format is
  /// unsupported/not loadable. This is a recoverable model-choice problem,
  /// distinct from generic spawn/crash/timeouts and from the app-side
  /// advisory "outside curated list" warning.
  case modelUnsupported
  case unknown
}

extension EngineErrorCode {
  /// Whether a plain menu "Resume" (re-resolve the active profile and
  /// start) is a sensible retry for a failure carrying this code.
  ///
  /// Most failures ARE retryable: the user fixes the underlying cause
  /// (downloads the missing model, frees the port, reconnects the
  /// network) and clicks Resume to try again. These codes are NOT: a
  /// blind retry of the same action either repeats a guaranteed failure
  /// or takes the wrong recovery path.
  ///   · `memoryRisk` — the same model is still too large; a retry just
  ///     re-rejects. Recovery is choosing a smaller model, not Resume.
  ///   · `modelUnsupported` — the same cached artifact/format is still
  ///     unsupported. Recovery is choosing/fixing/installing a model, not
  ///     re-starting the same active profile.
  ///   · `killRejected` — a prior engine process could not be reaped; a
  ///     plain start refuses (`alreadyRunning`) until the orphan is
  ///     cleared. Resume cannot perform that cleanup.
  ///
  /// Drives `HelperStatusItemModel.make`'s `.failed` Resume-enabled
  /// decision so a recoverable failure (notably `modelMissing`) no
  /// longer strands the engine with a disabled Resume.
  public var invitesResumeRetry: Bool {
    switch self {
    case .memoryRisk, .modelUnsupported, .killRejected:
      return false
    default:
      return true
    }
  }
}

/// Codable failure value passed back through `startEngine` / cancellation
/// paths. Conforms to `Error` so call sites can `throw` it directly after
/// decoding from the wire.
public struct EngineError: Codable, Equatable, Error, Sendable {
  public let code: EngineErrorCode
  public let message: String

  public init(code: EngineErrorCode, message: String = "") {
    self.code = code
    self.message = message
  }
}

/// Which log file `tailLog` should hand back a FileHandle for.
public enum LogStream: String, Codable, Sendable {
  case helper
  case engine
}

/// JSON wire format for Codable payloads passed across `@objc` XPC
/// selectors as `Data` blobs. Using JSON (not plist/keyed archiver) keeps
/// the wire format human-debuggable in `log stream` and lets a future
/// non-Swift consumer (CLI, scripts) read the same bytes.
///
/// Each call instantiates a fresh `JSONEncoder`/`JSONDecoder` — `let` on
/// a reference type doesn't prevent property mutation, so a shared
/// static instance could race on `userInfo`/`dateDecodingStrategy` if a
/// future caller reaches in (review F3). Construction cost is
/// negligible vs the JSON serialization itself. `configuredEncoder` /
/// `configuredDecoder` are the single greppable choke points for the
/// frozen wire config; `XPCPayloadConfig` exposes the same values so
/// tests can snapshot-assert nothing drifted.
public enum XPCPayload {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    try Self.configuredEncoder().encode(value)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try Self.configuredDecoder().decode(type, from: data)
  }

  // MARK: - frozen config

  static func configuredEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = XPCPayloadConfig.outputFormatting
    e.dateEncodingStrategy = XPCPayloadConfig.dateEncodingStrategy
    e.dataEncodingStrategy = XPCPayloadConfig.dataEncodingStrategy
    e.nonConformingFloatEncodingStrategy = XPCPayloadConfig.nonConformingFloatEncodingStrategy
    return e
  }

  static func configuredDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = XPCPayloadConfig.dateDecodingStrategy
    d.dataDecodingStrategy = XPCPayloadConfig.dataDecodingStrategy
    d.nonConformingFloatDecodingStrategy = XPCPayloadConfig.nonConformingFloatDecodingStrategy
    return d
  }
}

/// Frozen wire configuration values. Lives at module scope so the
/// snapshot test can compare without reaching into JSONEncoder/Decoder
/// (whose mutable properties are exactly what we're avoiding sharing).
public enum XPCPayloadConfig {
  public static let outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys]
  public static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601
  public static let dataEncodingStrategy: JSONEncoder.DataEncodingStrategy = .base64
  public static let nonConformingFloatEncodingStrategy: JSONEncoder.NonConformingFloatEncodingStrategy = .throw

  public static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601
  public static let dataDecodingStrategy: JSONDecoder.DataDecodingStrategy = .base64
  public static let nonConformingFloatDecodingStrategy: JSONDecoder.NonConformingFloatDecodingStrategy = .throw
}
