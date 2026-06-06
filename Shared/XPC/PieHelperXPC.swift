import Foundation
import os

/// XPC wire protocol the GUI calls and the Helper publishes.
///
/// The selectors are `@objc` because `NSXPCConnection` builds proxies via
/// the Objective-C runtime. Every Codable payload (`EngineStatus`,
/// `LoadHandle`, `DownloadHandle`, `EngineError`, `[Profile]`-as-TOML…)
/// crosses the boundary as a `Data` blob produced by `XPCPayload`. The
/// blob-only wire keeps the protocol free of NSSecureCoding subclass
/// gymnastics: only `Data`, `String`, and `FileHandle` traverse the
/// connection natively, and all three are XPC built-ins.
///
/// Every method has a reply block. One-way fire-and-forget selectors
/// (cancel*, reloadProfiles in the original draft) were a silent-failure
/// trap — review F4/F5 — so they now return an encoded `EngineError?`
/// (nil ⇒ accepted). The GUI no longer has to assume a click landed.
///
/// `startEngine`'s reply is `(successData, errorData)` — exactly one is
/// non-nil. The convenience `Result`-shaped helpers in
/// `PieHelperXPCWire` encode that contract so call sites never see raw
/// `(Data?, Data?)` tuples. Helper-side contract bugs surface as
/// `EngineErrorCode.wireContractViolation`, distinct from any normal
/// engine failure (review F8).
///
/// `tailLog` returns `(FileHandle?, Data?)` so the GUI can tell
/// "stream missing" from "open(2) denied" from "unknown stream" — review
/// F6.
///
/// The explicit `@objc(PieHelperXPC)` name pins the runtime symbol so
/// `NSProtocolFromString("PieHelperXPC")` works for selector
/// introspection in tests and for future bridges.
@objc(PieHelperXPC)
public protocol PieHelperXPC {
  /// Reply data is `XPCPayload.encode(EngineStatus)`.
  func engineStatus(reply: @escaping (Data) -> Void)

  /// Reply data is `XPCPayload.encode(EngineMemorySample?)` — a nil
  /// sample decodes to "engine not running / RSS unavailable". A plain
  /// `Data` reply (like `engineStatus`) so the interface needs no extra
  /// allowed-class list.
  func engineMemory(reply: @escaping (Data) -> Void)

  /// On success `successData` decodes to `EnginePort`; on failure
  /// `errorData` decodes to `EngineError`. Exactly one is non-nil.
  func startEngine(profileID: String,
                   reply: @escaping (_ successData: Data?, _ errorData: Data?) -> Void)

  /// Reply is `XPCPayload.encode(EngineError)` when the stop request
  /// could not be honored (helper degraded, engine missing, transport
  /// race) or nil on acceptance. The prior `() -> Void` shape had no
  /// error channel and a stub `reply()` was indistinguishable from a
  /// real stop (review v1 F7).
  func stopEngine(reply: @escaping (_ errorData: Data?) -> Void)

  /// On success `successData` decodes to `LoadHandle`; on rejection
  /// `errorData` decodes to `EngineError`. Exactly one is non-nil.
  /// Reshaped from `(Data) -> Void` because the prior shape forced
  /// stubs to synthesize a handle that referenced nothing, leaving the
  /// GUI polling a non-existent load forever (review v1 F8).
  func loadModel(modelID: String,
                 reply: @escaping (_ successData: Data?, _ errorData: Data?) -> Void)

  /// `handle` is `XPCPayload.encode(LoadHandle)`. Reply is
  /// `XPCPayload.encode(EngineError)` on rejection (decode failure,
  /// unknown handle, helper busy) or nil on acceptance — review F4.
  func cancelLoad(handle: Data, reply: @escaping (_ errorData: Data?) -> Void)

  /// On success `successData` decodes to `DownloadHandle`; on rejection
  /// `errorData` decodes to `EngineError`. Reshape rationale matches
  /// `loadModel` — review v1 F8.
  func downloadModel(repo: String, file: String,
                     reply: @escaping (_ successData: Data?, _ errorData: Data?) -> Void)

  /// `handle` is `XPCPayload.encode(DownloadHandle)`. Reply mirrors
  /// `cancelLoad` — review F4.
  func cancelDownload(handle: Data, reply: @escaping (_ errorData: Data?) -> Void)

  /// Reply data is `XPCPayload.encode([String])` where each element is
  /// `Profile.dump()` TOML. Sending TOML keeps `Profile`'s lossless
  /// `rawTable` intact across the wire without forcing `Profile` to be
  /// Codable.
  func listProfiles(reply: @escaping (Data) -> Void)

  /// Reply is `XPCPayload.encode(EngineError)` when reload partially
  /// or wholly failed (I/O, TOML parse error, missing directory), nil
  /// on full success — review F5. The GUI MUST treat a non-nil error
  /// as "profiles may be stale" and surface it.
  func reloadProfiles(reply: @escaping (_ errorData: Data?) -> Void)

  /// `stream` is `LogStream.rawValue`. Reply is `(handle, errorData)`:
  /// exactly one is non-nil. `errorData` decodes to `EngineError` and
  /// distinguishes unknown-stream / file-missing / permission-denied
  /// from "no logs yet" — review F6. Use
  /// `PieHelperXPCWire.decodeTailLogReply` at the call site to recover
  /// a `Result<FileHandle, EngineError>`.
  func tailLog(stream: String,
               reply: @escaping (_ handle: FileHandle?, _ errorData: Data?) -> Void)

  /// Recovery selector for the `.failed(.killRejected, …)` state
  /// (PR12 review v5 F58). The helper verifies the zombie engine
  /// process is actually gone before transitioning back to
  /// `.stopped` — see `PieSupervisor.clearKillRejected()`. Reply is
  /// nil on success; non-nil `EngineError` carries the reason a
  /// clear was refused (engine still alive, no zombie tracked, not
  /// in killRejected state, helper degraded).
  func clearKillRejected(reply: @escaping (_ errorData: Data?) -> Void)

  /// Full-product quit (#448): stop the running engine, WAIT for it to
  /// reach a terminal state so `pie` is reaped (no orphan process), then
  /// terminate the Helper itself with a clean exit (so launchd's
  /// `KeepAlive { SuccessfulExit: false }` does not relaunch it). The App
  /// calls this as the final step of a coordinated quit after it has
  /// stopped polling, so nothing respawns the cleanly-exited Helper via the
  /// on-demand mach service. Reply is nil on acceptance; a non-nil
  /// `EngineError` reports why the quit could not be honored. The reply may
  /// also never arrive if the Helper terminates before it flushes — callers
  /// MUST treat a post-call connection invalidation as success.
  func quitHelper(reply: @escaping (_ errorData: Data?) -> Void)
}

/// Convenience encoders/decoders that hide the multi-slot reply tuples
/// behind real `Result` values. Helper-side XPC implementations call
/// the `reply*` helpers; GUI-side proxies call the `decode*ReplyResult`
/// helpers.
///
/// Wire-contract violations (both slots nil, both slots set) become
/// `EngineErrorCode.wireContractViolation` — never `.unknown` — so a
/// future caller writing `try? decode...` can route plumbing bugs to a
/// crash-report path instead of collapsing them into the same "engine
/// failed" banner used for real failures (review F8).
public enum PieHelperXPCWire {
  /// Pre-encoded fallback emitted when helper-side encode of a real
  /// reply payload itself fails. Hand-rolled JSON literal so the path
  /// that recovers from an encode failure never reaches the encoder
  /// again (review v2 F4). Decodes into
  /// `EngineError(code: .wireContractViolation, message: ...)`.
  ///
  /// The full upstream encode-failure detail belongs in the helper's
  /// `os_log` — not in this static blob — because embedding a free-
  /// form error string back into JSON would re-introduce the very
  /// failure mode we're guarding against.
  public static let fallbackReplyEncodeFailureData: Data = Data(
    #"{"code":"wireContractViolation","message":"reply payload encode failed; see helper log"}"#.utf8
  )

  /// Existential-erased adapter for `XPCPayload.encode`. The reply-
  /// block helpers consume `(any Encodable) throws -> Data` so tests
  /// can inject a throwing encoder via the `_reply*` seams (review v3
  /// F2). Swift 5.7+ opens the existential at the call site.
  @usableFromInline
  internal static let defaultEncode: (any Encodable) throws -> Data = { value in
    try XPCPayload.encode(value)
  }

  // MARK: - startEngine

  /// Reply-block helper for `startEngine`. Encodes either an
  /// `EnginePort` or an `EngineError` and invokes the XPC reply block
  /// with the success/error tuple that matches the protocol contract.
  ///
  /// Non-throwing on purpose (review v2 F4): if the inner encode
  /// throws — encoder-strategy misconfig, future Codable change — we
  /// log via `PieHelperXPCLog` and invoke `reply` with
  /// `fallbackReplyEncodeFailureData` so the XPC client never hangs
  /// waiting on a reply block that was never fired. Helper-side
  /// authors do NOT need to wrap calls in `do/catch`.
  public static func replyStartEngine(
    _ result: Result<EnginePort, EngineError>,
    via reply: (Data?, Data?) -> Void
  ) {
    _replyStartEngine(
      result, via: reply,
      encode: defaultEncode,
      onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyStartEngine") }
    )
  }

  /// Internal seam that exposes the encoder + failure-logger as
  /// parameters so tests can drive the F4 catch branch at runtime
  /// (review v3 F2). Same control flow as the public entry point;
  /// callers under `@testable import RatioThinkCore` use this directly with
  /// a throwing encoder.
  @usableFromInline
  internal static func _replyStartEngine(
    _ result: Result<EnginePort, EngineError>,
    via reply: (Data?, Data?) -> Void,
    encode: (any Encodable) throws -> Data,
    onEncodeFailure: (Error) -> Void
  ) {
    do {
      switch result {
      case .success(let port):
        reply(try encode(port), nil)
      case .failure(let error):
        reply(nil, try encode(error))
      }
    } catch {
      onEncodeFailure(error)
      reply(nil, fallbackReplyEncodeFailureData)
    }
  }

  /// Decode a `startEngine` reply tuple back into a typed `Result`.
  /// Throws `EngineError(code: .wireContractViolation)` for every
  /// plumbing failure — tuple-shape violation (review v1 F8) AND
  /// malformed payload bytes that fail inner decode (review v2 F1).
  /// A `try?` at the call site collapses to `nil` only for
  /// plumbing-bug paths, never for real `.unknown` engine failures.
  public static func decodeStartEngineReply(
    successData: Data?,
    errorData: Data?
  ) throws -> Result<EnginePort, EngineError> {
    switch (successData, errorData) {
    case (let s?, nil):
      return .success(try decodeOrWireViolation(
        EnginePort.self, from: s,
        slot: "startEngine.successData(EnginePort)"
      ))
    case (nil, let e?):
      return .failure(try decodeOrWireViolation(
        EngineError.self, from: e,
        slot: "startEngine.errorData(EngineError)"
      ))
    default:
      throw EngineError(
        code: .wireContractViolation,
        message: "startEngine reply violated wire contract: successData=\(successData != nil) errorData=\(errorData != nil)"
      )
    }
  }

  // MARK: - tailLog

  /// Reply-block helper for `tailLog`. Encodes the handle directly
  /// (no Codable on the success path) or the error payload via
  /// `XPCPayload`. Non-throwing for the same reason as
  /// `replyStartEngine` — review v2 F4. Logs encode failures via
  /// `PieHelperXPCLog` (review v3 F1).
  public static func replyTailLog(
    _ result: Result<FileHandle, EngineError>,
    via reply: (FileHandle?, Data?) -> Void
  ) {
    _replyTailLog(
      result, via: reply,
      encode: defaultEncode,
      onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyTailLog") }
    )
  }

  /// Internal seam mirroring `_replyStartEngine` — review v3 F2.
  @usableFromInline
  internal static func _replyTailLog(
    _ result: Result<FileHandle, EngineError>,
    via reply: (FileHandle?, Data?) -> Void,
    encode: (any Encodable) throws -> Data,
    onEncodeFailure: (Error) -> Void
  ) {
    do {
      switch result {
      case .success(let handle):
        reply(handle, nil)
      case .failure(let error):
        reply(nil, try encode(error))
      }
    } catch {
      onEncodeFailure(error)
      reply(nil, fallbackReplyEncodeFailureData)
    }
  }

  /// Decode a `tailLog` reply tuple into a typed `Result`. Same
  /// `.wireContractViolation` discipline as `decodeStartEngineReply` —
  /// applies to tuple shape AND malformed errorData (review v2 F2).
  public static func decodeTailLogReply(
    handle: FileHandle?,
    errorData: Data?
  ) throws -> Result<FileHandle, EngineError> {
    switch (handle, errorData) {
    case (let h?, nil):
      return .success(h)
    case (nil, let e?):
      return .failure(try decodeOrWireViolation(
        EngineError.self, from: e,
        slot: "tailLog.errorData(EngineError)"
      ))
    default:
      throw EngineError(
        code: .wireContractViolation,
        message: "tailLog reply violated wire contract: handle=\(handle != nil) errorData=\(errorData != nil)"
      )
    }
  }

  // MARK: - loadModel (handle-or-error)

  /// Reply-block helper for `loadModel`. Mirrors `replyStartEngine`
  /// shape and failure handling — review v1 F8.
  public static func replyLoadModel(
    _ result: Result<LoadHandle, EngineError>,
    via reply: (Data?, Data?) -> Void
  ) {
    _replyHandleOrError(
      result, via: reply,
      encode: defaultEncode,
      onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyLoadModel") }
    )
  }

  /// Decode a `loadModel` reply tuple. Wire-contract discipline matches
  /// `decodeStartEngineReply`.
  public static func decodeLoadModelReply(
    successData: Data?,
    errorData: Data?
  ) throws -> Result<LoadHandle, EngineError> {
    try decodeHandleOrErrorReply(
      LoadHandle.self,
      successData: successData,
      errorData: errorData,
      slot: "loadModel"
    )
  }

  // MARK: - downloadModel (handle-or-error)

  /// Reply-block helper for `downloadModel`. Mirrors `replyStartEngine`
  /// — review v1 F8.
  public static func replyDownloadModel(
    _ result: Result<DownloadHandle, EngineError>,
    via reply: (Data?, Data?) -> Void
  ) {
    _replyHandleOrError(
      result, via: reply,
      encode: defaultEncode,
      onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyDownloadModel") }
    )
  }

  /// Decode a `downloadModel` reply tuple.
  public static func decodeDownloadModelReply(
    successData: Data?,
    errorData: Data?
  ) throws -> Result<DownloadHandle, EngineError> {
    try decodeHandleOrErrorReply(
      DownloadHandle.self,
      successData: successData,
      errorData: errorData,
      slot: "downloadModel"
    )
  }

  // MARK: - stopEngine (optional-error)

  /// Reply-block helper for `stopEngine`. Encodes an optional
  /// `EngineError`; nil ⇒ accepted. Review v1 F7 — the prior void
  /// shape had no error channel so a stub `reply()` was
  /// indistinguishable from a real stop.
  public static func replyStopEngine(
    _ error: EngineError?,
    via reply: (Data?) -> Void
  ) {
    _replyOptionalError(
      error, via: reply,
      encode: defaultEncode,
      onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyStopEngine") }
    )
  }

  // MARK: - cancel*/reloadProfiles optional-error replies

  /// Reply-block helper for `cancelDownload`. Mirrors `replyStopEngine`
  /// shape — optional `EngineError`, nil ⇒ accepted. Phase 2.5
  /// wires this from `HelperExportedAPI.cancelDownload`; the prior
  /// stub inline-encoded a placeholder error so a per-selector helper
  /// pulls the encode-failure log site into one greppable spot.
  public static func replyCancelDownload(
    _ error: EngineError?,
    via reply: (Data?) -> Void
  ) {
    _replyOptionalError(
      error, via: reply,
      encode: defaultEncode,
      onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyCancelDownload") }
    )
  }

  /// Decode an optional-error reply (`cancelLoad`, `cancelDownload`,
  /// `reloadProfiles`). Returns nil when the helper accepted the
  /// request, the decoded `EngineError` otherwise. Malformed non-nil
  /// bytes throw `.wireContractViolation` rather than leaking a raw
  /// `DecodingError` (review v2 F3).
  public static func decodeOptionalError(_ data: Data?) throws -> EngineError? {
    guard let data else { return nil }
    return try decodeOrWireViolation(
      EngineError.self, from: data,
      slot: "optionalError(EngineError)"
    )
  }

  // MARK: - internals

  /// Generic helper for any `(Data?, Data?)` reply that encodes a
  /// Codable success type or an `EngineError`. Used by
  /// `replyLoadModel` and `replyDownloadModel` so the F4 + F8 control
  /// flow lives in one place.
  @usableFromInline
  internal static func _replyHandleOrError<T: Encodable>(
    _ result: Result<T, EngineError>,
    via reply: (Data?, Data?) -> Void,
    encode: (any Encodable) throws -> Data,
    onEncodeFailure: (Error) -> Void
  ) {
    do {
      switch result {
      case .success(let value):
        reply(try encode(value), nil)
      case .failure(let error):
        reply(nil, try encode(error))
      }
    } catch {
      onEncodeFailure(error)
      reply(nil, fallbackReplyEncodeFailureData)
    }
  }

  /// Generic helper for any `(Data?) -> Void` optional-error reply.
  /// Used by `replyStopEngine` so callers don't have to wrap the
  /// encode in their own do/catch.
  @usableFromInline
  internal static func _replyOptionalError(
    _ error: EngineError?,
    via reply: (Data?) -> Void,
    encode: (any Encodable) throws -> Data,
    onEncodeFailure: (Error) -> Void
  ) {
    guard let error else {
      reply(nil)
      return
    }
    do {
      reply(try encode(error))
    } catch {
      onEncodeFailure(error)
      reply(fallbackReplyEncodeFailureData)
    }
  }

  /// Generic decoder for `(Data?, Data?)` reply tuples carrying a
  /// Decodable success type or an `EngineError`. Wire-contract
  /// violations (both nil, both set, malformed bytes) become
  /// `EngineError(.wireContractViolation)` exactly as the
  /// `startEngine` decoder does.
  private static func decodeHandleOrErrorReply<T: Decodable>(
    _ type: T.Type,
    successData: Data?,
    errorData: Data?,
    slot: String
  ) throws -> Result<T, EngineError> {
    switch (successData, errorData) {
    case (let s?, nil):
      return .success(try decodeOrWireViolation(
        type, from: s,
        slot: "\(slot).successData(\(type))"
      ))
    case (nil, let e?):
      return .failure(try decodeOrWireViolation(
        EngineError.self, from: e,
        slot: "\(slot).errorData(EngineError)"
      ))
    default:
      throw EngineError(
        code: .wireContractViolation,
        message: "\(slot) reply violated wire contract: successData=\(successData != nil) errorData=\(errorData != nil)"
      )
    }
  }

  /// Single choke point: decode a payload Data and re-stamp any
  /// underlying `DecodingError` as `EngineError(.wireContractViolation)`.
  /// All `decode*Reply` helpers route through here so the asymmetry
  /// review v2 F1/F2/F3 caught can't return through a different door.
  private static func decodeOrWireViolation<T: Decodable>(
    _ type: T.Type, from data: Data, slot: String
  ) throws -> T {
    do {
      return try XPCPayload.decode(type, from: data)
    } catch {
      throw EngineError(
        code: .wireContractViolation,
        message: "\(slot) failed to decode: \(error)"
      )
    }
  }
}

/// Module-level logger for XPC wire diagnostics. Lives next to the
/// helpers so a helper-side encode failure surfaces in
/// `log stream --predicate 'subsystem == "com.ratiothink.app.xpc"'` even when
/// the caller is the Helper bundle's first-touched code path and no
/// product-specific Logger has been wired yet (review v3 F1).
///
/// `encodeFailure(_:site:)` is the single greppable choke point; both
/// reply-block helpers route through it. Tests inject their own
/// closure via the `_reply*` seams and don't depend on os_log capture.
public enum PieHelperXPCLog {
  public static let subsystem = "com.ratiothink.app.xpc"
  public static let category  = "wire"

  static let logger = Logger(subsystem: subsystem, category: category)

  public static func encodeFailure(_ error: Error, site: String) {
    logger.fault("\(site, privacy: .public) encode failed: \(String(describing: error), privacy: .public)")
  }
}

/// Builders for the `NSXPCInterface` instances both sides hand to
/// `NSXPCConnection`. The interface is identical at both ends; only
/// `FileHandle` (returned by `tailLog`) needs an explicit allowed-class
/// list because XPC defaults to a permissive set for reply arguments
/// only when the runtime can infer the type, and `FileHandle` arrives
/// inside a Swift optional that the bridge can't always introspect.
public enum PieHelperXPCInterface {
  public static func make() -> NSXPCInterface {
    let iface = NSXPCInterface(with: PieHelperXPC.self)
    iface.setClasses(
      allowedClasses(for: [FileHandle.self, NSNull.self]),
      for: #selector(PieHelperXPC.tailLog(stream:reply:)),
      argumentIndex: 0,
      ofReply: true
    )
    return iface
  }

  /// Build the `Set<AnyHashable>` shape `NSXPCInterface.setClasses`
  /// wants from a list of class metatypes. Bridging each metatype
  /// through `AnyObject` lands on the ObjC class object, which is
  /// NSObject-conformant and hashable — no force-cast of the whole
  /// container (review F1). The per-element `as! AnyHashable` is
  /// guaranteed to succeed for any class metatype on this platform;
  /// if a future stdlib change ever breaks that the failure is on a
  /// single element rather than the whole set construction.
  private static func allowedClasses(for classes: [AnyClass]) -> Set<AnyHashable> {
    var set = Set<AnyHashable>()
    for cls in classes {
      set.insert((cls as AnyObject) as! AnyHashable)
    }
    return set
  }
}
