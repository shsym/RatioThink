import XCTest
import ObjectiveC.runtime
@testable import RatioThinkCore

final class XPCProtocolTests: XCTestCase {

  // MARK: - Protocol presence + selectors

  func test_protocol_resolvable_by_runtime_name() {
    // `NSProtocolFromString` only works because the protocol is
    // declared `@objc(PieHelperXPC)` — the pinned obj-c name. Drop the
    // explicit name and this fails with Swift's mangled symbol.
    XCTAssertNotNil(NSProtocolFromString("PieHelperXPC"))
  }

  func test_protocol_declares_each_required_selector() {
    let proto = NSProtocolFromString("PieHelperXPC")!
    // `func foo(reply:)` bridges to `fooWithReply:` because `reply` is
    // a single anonymous trailing label — verifying by string keeps
    // the wire contract greppable when ObjC consumers are added.
    let expected = [
      "helperProtocolVersionWithReply:",
      "engineStatusWithReply:",
      "kvUsageWithReply:",
      "startEngineWithProfileID:modelOverride:reply:",
      "restartEngineWithProfileID:modelOverride:reply:",
      "stopEngineWithReply:",
      "downloadModelWithRepo:file:reply:",
      "cancelDownloadWithHandle:reply:",
      "listProfilesWithReply:",
      "reloadProfilesWithReply:",
      "tailLogWithStream:reply:",
    ]
    for name in expected {
      let sel = NSSelectorFromString(name)
      let desc = protocol_getMethodDescription(proto, sel, /*required:*/ true, /*instance:*/ true)
      XCTAssertNotNil(desc.name,
                      "PieHelperXPC missing required selector \(name)")
    }
  }

  func test_interface_builder_returns_non_nil() {
    let iface = PieHelperXPCInterface.make()
    // Sanity: the protocol pointer round-trips. If this fails the
    // NSXPCInterface didn't bind to PieHelperXPC at all.
    XCTAssertTrue(iface.protocol === NSProtocolFromString("PieHelperXPC")!)
  }

  // MARK: - Codable round-trip: EngineStatus (each case)

  func test_engineStatus_roundtrip_stopped()  { assertRoundTrip(EngineStatus.stopped) }
  func test_engineStatus_roundtrip_starting() { assertRoundTrip(EngineStatus.starting) }
  func test_engineStatus_roundtrip_stopping() { assertRoundTrip(EngineStatus.stopping) }

  func test_engineStatus_roundtrip_running_carries_full_snapshot() throws {
    let snapshot = EngineSessionSnapshot(
      generation: 3, port: 51234, profileID: "chat",
      servedModelID: "Qwen/Qwen3-0.6B", maxOutputTokens: 8000)
    let original = EngineStatus.running(snapshot)
    let data = try XPCPayload.encode(original)
    let decoded = try XPCPayload.decode(EngineStatus.self, from: data)
    XCTAssertEqual(decoded, original)
    if case .running(let snap) = decoded {
      XCTAssertEqual(snap, snapshot)
      XCTAssertEqual(snap.port, 51234)
      XCTAssertEqual(snap.profileID, "chat")
      XCTAssertEqual(snap.servedModelID, "Qwen/Qwen3-0.6B")
      XCTAssertEqual(snap.maxOutputTokens, 8000)
      XCTAssertEqual(snap.generation, 3)
    } else {
      XCTFail("expected .running, got \(decoded)")
    }
  }

  func test_engineStatus_running_port_zero_is_rejected() throws {
    // Hand-craft the wire bytes so the decoder is what's under test.
    // `EnginePort = UInt16` makes negative/oversized values
    // unrepresentable at the type level, but 0 ("any-bind") still
    // round-trips through UInt16 — the EngineStatus decoder is the last
    // line of defense on the embedded snapshot's port (review F2).
    let data = Data(#"{"kind":"running","snapshot":{"generation":0,"maxOutputTokens":32768,"port":0,"profileID":"chat","servedModelID":""}}"#.utf8)
    XCTAssertThrowsError(try XPCPayload.decode(EngineStatus.self, from: data))
  }

  func test_engineStatus_running_port_at_uint16_max_is_accepted() throws {
    let original = EngineStatus.running(EngineSessionSnapshot(port: UInt16.max, profileID: "chat"))
    let data = try XPCPayload.encode(original)
    let decoded = try XPCPayload.decode(EngineStatus.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func test_engineStatus_running_oversized_port_is_rejected_by_uint16() throws {
    // 70000 is outside UInt16 — the Decodable conformance on UInt16
    // throws on the embedded snapshot, independent of our explicit guard.
    let data = Data(#"{"kind":"running","snapshot":{"generation":0,"maxOutputTokens":32768,"port":70000,"profileID":"chat","servedModelID":""}}"#.utf8)
    XCTAssertThrowsError(try XPCPayload.decode(EngineStatus.self, from: data))
  }

  func test_engineStatus_roundtrip_failed_preserves_code_and_message() throws {
    let original = EngineStatus.failed(code: .handshakeTimeout,
                                       message: "after 30s")
    let data = try XPCPayload.encode(original)
    let decoded = try XPCPayload.decode(EngineStatus.self, from: data)
    XCTAssertEqual(decoded, original)
    if case .failed(let code, let message) = decoded {
      XCTAssertEqual(code, .handshakeTimeout)
      XCTAssertEqual(message, "after 30s")
    } else { XCTFail("expected .failed, got \(decoded)") }
  }

  func test_engineStatus_failed_message_truncated_at_cap() throws {
    // 2 KiB of ASCII — encoder must cap to 1 KiB + marker (review F7).
    let huge = String(repeating: "x", count: 2048)
    let original = EngineStatus.failed(code: .unknown, message: huge)
    let data = try XPCPayload.encode(original)
    let decoded = try XPCPayload.decode(EngineStatus.self, from: data)
    if case .failed(_, let message) = decoded {
      XCTAssertLessThanOrEqual(
        message.utf8.count,
        EngineStatus.failedMessageCap + EngineStatus.failedMessageTruncationMarker.utf8.count
      )
      XCTAssertTrue(message.hasSuffix(EngineStatus.failedMessageTruncationMarker))
    } else { XCTFail("expected .failed, got \(decoded)") }
  }

  func test_engineStatus_failed_message_under_cap_is_unchanged() throws {
    let small = "spawn failed: ENOENT"
    let original = EngineStatus.failed(code: .spawnFailed, message: small)
    let data = try XPCPayload.encode(original)
    let decoded = try XPCPayload.decode(EngineStatus.self, from: data)
    if case .failed(_, let message) = decoded {
      XCTAssertEqual(message, small)
    } else { XCTFail("expected .failed, got \(decoded)") }
  }

  // MARK: - Codable round-trip: handles + errors

  func test_downloadHandle_roundtrip() throws {
    let h = DownloadHandle(repo: "bartowski/Llama-3.2-3B-Instruct-GGUF",
                           file: "Q4_K_M.gguf")
    assertRoundTrip(h)
  }

  func test_engineError_roundtrip_covers_each_code() throws {
    for code in [EngineErrorCode.spawnFailed,
                 .handshakeTimeout, .modelMissing, .profileMissing,
                 .portUnavailable, .alreadyRunning, .cancelled,
                 .wireContractViolation, .degraded,
                 .integrityFailed, .networkFailed, .diskWriteFailed,
                 .invalidInput, .killRejected, .memoryRisk, .unknown] {
      assertRoundTrip(EngineError(code: code, message: "msg-\(code.rawValue)"))
    }
  }

  func test_invitesResumeRetry_only_memoryRisk_and_killRejected_are_terminal() throws {
    // Exactly two codes must NOT invite a plain Resume retry: a blind
    // retry re-fails (memoryRisk: same oversized model) or is blocked
    // (killRejected: orphan must be reaped first). Everything else —
    // notably modelMissing — is user-recoverable and keeps Resume live.
    let nonRetryable: Set<EngineErrorCode> = [.memoryRisk, .killRejected]
    for code in [EngineErrorCode.spawnFailed,
                 .handshakeTimeout, .modelMissing, .profileMissing,
                 .portUnavailable, .alreadyRunning, .cancelled,
                 .wireContractViolation, .degraded,
                 .integrityFailed, .networkFailed, .diskWriteFailed,
                 .invalidInput, .killRejected, .memoryRisk,
                 .engineGone, .unknown] {
      XCTAssertEqual(code.invitesResumeRetry, !nonRetryable.contains(code),
                     "invitesResumeRetry mismatch for \(code.rawValue)")
    }
  }

  func test_logStream_roundtrip() throws {
    assertRoundTrip(LogStream.helper)
    assertRoundTrip(LogStream.engine)
  }

  func test_quitHelper_appReplyTimeoutCoversHelperStopReapBudget() {
    XCTAssertGreaterThanOrEqual(
      HelperXPCClient.quitReplyTimeout,
      HelperExportedAPI.stopReplyDeadline + HelperExportedAPI.replyTimeoutSlack,
      "App-side quit timeout must cover the helper's valid stop/reap window plus slack"
    )
  }

  // MARK: - startEngine wire convention

  func test_startEngine_reply_success_encodes_snapshot_only() throws {
    var captured: (Data?, Data?) = (nil, nil)
    let snapshot = EngineSessionSnapshot(
      generation: 2, port: 7777, profileID: "chat",
      servedModelID: "org/repo/m.gguf", maxOutputTokens: 4096)
    PieHelperXPCWire.replyStartEngine(.success(snapshot)) { captured = ($0, $1) }
    XCTAssertNotNil(captured.0)
    XCTAssertNil(captured.1)
    let result = try PieHelperXPCWire.decodeStartEngineReply(
      successData: captured.0, errorData: captured.1
    )
    if case .success(let decoded) = result {
      XCTAssertEqual(decoded, snapshot)
      XCTAssertEqual(decoded.port, 7777)
      XCTAssertEqual(decoded.servedModelID, "org/repo/m.gguf")
      XCTAssertEqual(decoded.maxOutputTokens, 4096)
    } else { XCTFail("expected .success, got \(result)") }
  }

  func test_startEngine_reply_failure_encodes_error_only() throws {
    var captured: (Data?, Data?) = (nil, nil)
    let err = EngineError(code: .portUnavailable, message: "EADDRINUSE")
    PieHelperXPCWire.replyStartEngine(.failure(err)) { captured = ($0, $1) }
    XCTAssertNil(captured.0)
    XCTAssertNotNil(captured.1)
    let result = try PieHelperXPCWire.decodeStartEngineReply(
      successData: captured.0, errorData: captured.1
    )
    if case .failure(let decoded) = result {
      XCTAssertEqual(decoded, err)
    } else { XCTFail("expected .failure, got \(result)") }
  }

  func test_startEngine_reply_double_nil_throws_wire_contract_violation() {
    // Wire-contract bugs MUST carry `.wireContractViolation`, never
    // `.unknown` (review F8) — a `try?` at the call site would
    // otherwise collapse "RatioThink bug" and "engine failed: unknown"
    // into the same nil.
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeStartEngineReply(successData: nil, errorData: nil)
    ) { err in
      guard let e = err as? EngineError else {
        return XCTFail("expected EngineError, got \(err)")
      }
      XCTAssertEqual(e.code, .wireContractViolation)
      XCTAssertNotEqual(e.code, .unknown)
    }
  }

  func test_startEngine_reply_double_set_throws_wire_contract_violation() throws {
    let s = try XPCPayload.encode(EnginePort(80))
    let e = try XPCPayload.encode(EngineError(code: .unknown, message: ""))
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeStartEngineReply(successData: s, errorData: e)
    ) { err in
      guard let ee = err as? EngineError else {
        return XCTFail("expected EngineError, got \(err)")
      }
      XCTAssertEqual(ee.code, .wireContractViolation)
    }
  }

  func test_kvUsage_reply_success_encodes_snapshots_only() throws {
    let snapshots = [KVUsageSnapshot(
      modelID: "default",
      pagesUsed: 1,
      pagesTotal: 256,
      observedAt: Date(timeIntervalSince1970: 5),
      generation: 1,
      source: .pieModelStatus
    )]
    var captured: (Data?, Data?)?
    PieHelperXPCWire.replyKVUsage(.success(snapshots)) { captured = ($0, $1) }
    let tuple = try XCTUnwrap(captured)
    XCTAssertNotNil(tuple.0)
    XCTAssertNil(tuple.1)
    XCTAssertEqual(
      try PieHelperXPCWire.decodeKVUsageReply(successData: tuple.0, errorData: tuple.1).get(),
      snapshots
    )
  }

  // MARK: - tailLog wire convention

  func test_tailLog_reply_success_carries_handle_only() throws {
    var captured: (FileHandle?, Data?) = (nil, nil)
    let h = FileHandle.standardError
    PieHelperXPCWire.replyTailLog(.success(h)) { captured = ($0, $1) }
    XCTAssertNotNil(captured.0)
    XCTAssertNil(captured.1)
    let result = try PieHelperXPCWire.decodeTailLogReply(
      handle: captured.0, errorData: captured.1
    )
    if case .success(let returned) = result {
      XCTAssertTrue(returned === h)
    } else { XCTFail("expected .success, got \(result)") }
  }

  func test_tailLog_reply_failure_carries_error_only() throws {
    var captured: (FileHandle?, Data?) = (nil, nil)
    let err = EngineError(code: .unknown, message: "logs missing")
    PieHelperXPCWire.replyTailLog(.failure(err)) { captured = ($0, $1) }
    XCTAssertNil(captured.0)
    XCTAssertNotNil(captured.1)
    let result = try PieHelperXPCWire.decodeTailLogReply(
      handle: captured.0, errorData: captured.1
    )
    if case .failure(let decoded) = result {
      XCTAssertEqual(decoded, err)
    } else { XCTFail("expected .failure, got \(result)") }
  }

  func test_tailLog_reply_double_nil_throws_wire_contract_violation() {
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeTailLogReply(handle: nil, errorData: nil)
    ) { err in
      XCTAssertEqual((err as? EngineError)?.code, .wireContractViolation)
    }
  }

  // MARK: - Optional-error reply convention (cancelDownload/reloadProfiles)

  func test_decodeOptionalError_nil_returns_nil() throws {
    XCTAssertNil(try PieHelperXPCWire.decodeOptionalError(nil))
  }

  func test_decodeOptionalError_returns_decoded_engineError() throws {
    let err = EngineError(code: .cancelled, message: "user cancelled")
    let data = try XPCPayload.encode(err)
    XCTAssertEqual(try PieHelperXPCWire.decodeOptionalError(data), err)
  }

  // MARK: - XPCPayload config snapshot (review F3)

  func test_xpcPayloadConfig_matches_frozen_snapshot() {
    // Lock down the wire config. Any drift surfaces here so a future
    // contributor can't silently change date strategy or sort order
    // and break compatibility for already-shipped clients.
    XCTAssertEqual(XPCPayloadConfig.outputFormatting, [.sortedKeys])
    switch XPCPayloadConfig.dateEncodingStrategy {
    case .iso8601: break
    default: XCTFail("dateEncodingStrategy drifted from .iso8601")
    }
    switch XPCPayloadConfig.dateDecodingStrategy {
    case .iso8601: break
    default: XCTFail("dateDecodingStrategy drifted from .iso8601")
    }
    switch XPCPayloadConfig.dataEncodingStrategy {
    case .base64: break
    default: XCTFail("dataEncodingStrategy drifted from .base64")
    }
    switch XPCPayloadConfig.dataDecodingStrategy {
    case .base64: break
    default: XCTFail("dataDecodingStrategy drifted from .base64")
    }
    switch XPCPayloadConfig.nonConformingFloatEncodingStrategy {
    case .throw: break
    default: XCTFail("nonConformingFloatEncodingStrategy drifted from .throw")
    }
    switch XPCPayloadConfig.nonConformingFloatDecodingStrategy {
    case .throw: break
    default: XCTFail("nonConformingFloatDecodingStrategy drifted from .throw")
    }
  }

  func test_xpcPayload_encode_uses_sorted_keys() throws {
    struct TwoKey: Codable { let b: Int; let a: Int }
    let bytes = try XPCPayload.encode(TwoKey(b: 2, a: 1))
    let s = String(decoding: bytes, as: UTF8.self)
    // Sorted keys ⇒ "a" appears before "b" in the serialized JSON.
    let aIdx = s.firstIndex(of: "a")!
    let bIdx = s.firstIndex(of: "b")!
    XCTAssertLessThan(aIdx, bIdx, "sortedKeys not honored: \(s)")
  }

  func test_xpcPayload_returns_fresh_encoder_each_call() {
    // Different identities prove a future caller can't poke userInfo
    // on a shared instance and race in-flight decodes (review F3).
    let a = XPCPayload.configuredEncoder()
    let b = XPCPayload.configuredEncoder()
    XCTAssertFalse(a === b)
  }

  // MARK: - Inner-decode failure routes to wireContractViolation (review v2 F1/F2/F3)

  func test_decodeStartEngineReply_malformed_success_payload_yields_wireContractViolation() {
    let garbage = Data("not-json".utf8)
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeStartEngineReply(
        successData: garbage, errorData: nil
      )
    ) { err in
      guard let e = err as? EngineError else {
        return XCTFail("expected EngineError, got \(err)")
      }
      XCTAssertEqual(e.code, .wireContractViolation,
                     "malformed successData must route to wireContractViolation, not leak DecodingError")
      XCTAssertNotEqual(e.code, .unknown)
    }
  }

  func test_decodeStartEngineReply_malformed_error_payload_yields_wireContractViolation() {
    let garbage = Data(#"{"code":"nope"}"#.utf8)  // unknown enum case
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeStartEngineReply(
        successData: nil, errorData: garbage
      )
    ) { err in
      XCTAssertEqual((err as? EngineError)?.code, .wireContractViolation)
    }
  }

  func test_decodeTailLogReply_malformed_error_payload_yields_wireContractViolation() {
    let garbage = Data("not-json".utf8)
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeTailLogReply(
        handle: nil, errorData: garbage
      )
    ) { err in
      XCTAssertEqual((err as? EngineError)?.code, .wireContractViolation)
    }
  }

  func test_decodeOptionalError_malformed_payload_yields_wireContractViolation() {
    let garbage = Data("not-json".utf8)
    XCTAssertThrowsError(
      try PieHelperXPCWire.decodeOptionalError(garbage)
    ) { err in
      XCTAssertEqual((err as? EngineError)?.code, .wireContractViolation)
    }
  }

  // MARK: - reply* never strand the XPC reply block (review v2 F4)

  func test_replyStartEngine_is_non_throwing() {
    // Compile-time check: assigning to a non-throwing function type
    // proves the helper doesn't `throws`. If F4 regresses this fails
    // to compile, not at runtime.
    let _: (Result<EngineSessionSnapshot, EngineError>, (Data?, Data?) -> Void) -> Void =
      PieHelperXPCWire.replyStartEngine(_:via:)
  }

  func test_replyTailLog_is_non_throwing() {
    let _: (Result<FileHandle, EngineError>, (FileHandle?, Data?) -> Void) -> Void =
      PieHelperXPCWire.replyTailLog(_:via:)
  }

  func test_fallbackReplyEncodeFailureData_decodes_as_wireContractViolation() throws {
    // The fallback emitted when helper-side encode fails MUST itself
    // decode through the same machinery the GUI uses on the happy
    // path — otherwise the fallback is another silent-failure trap.
    let err = try XPCPayload.decode(
      EngineError.self,
      from: PieHelperXPCWire.fallbackReplyEncodeFailureData
    )
    XCTAssertEqual(err.code, .wireContractViolation)
    XCTAssertFalse(err.message.isEmpty)
  }

  // MARK: - EngineStatus.running encoder symmetric port=0 guard (review v2 F5)

  func test_engineStatus_running_port_zero_encode_throws() {
    XCTAssertThrowsError(
      try XPCPayload.encode(EngineStatus.running(EngineSessionSnapshot(port: 0, profileID: "x")))
    ) { err in
      // Foundation wraps the inner EncodingError; assert by class
      // name + the diagnostic carries `port` so the trail back to
      // the bug is obvious.
      let s = String(describing: err)
      XCTAssertTrue(s.contains("port") || s.contains("auto-bind"),
                    "unexpected error: \(s)")
    }
  }

  func test_engineStatus_running_port_one_encode_succeeds() throws {
    // Smallest legal port. Proves the guard is on `== 0`, not on a
    // wider range.
    let original = EngineStatus.running(EngineSessionSnapshot(port: 1, profileID: "x"))
    let data = try XPCPayload.encode(original)
    XCTAssertEqual(try XPCPayload.decode(EngineStatus.self, from: data), original)
  }

  // MARK: - reply* end-to-end fallback path (review v3 F1/F2)

  /// Encodable that always throws — drives the F4 catch branch at
  /// runtime so the F2-reported gap (compile-only coverage) closes.
  private struct AlwaysThrowingEncodable: Encodable {
    struct Boom: Error, Equatable {}
    func encode(to encoder: Encoder) throws { throw Boom() }
  }

  func test_replyStartEngine_encode_failure_emits_fallback_and_invokes_logger() {
    var captured: (Data?, Data?)? = nil
    var loggedError: Error? = nil

    // Inject a throwing encoder for both the success and failure
    // payloads. Whichever variant we hand in, the inner encode
    // throws → catch fires → logger called → fallback bytes emitted.
    PieHelperXPCWire._replyStartEngine(
      .success(EngineSessionSnapshot(port: 7777, profileID: "chat")),
      via: { captured = ($0, $1) },
      encode: { _ in throw AlwaysThrowingEncodable.Boom() },
      onEncodeFailure: { loggedError = $0 }
    )

    XCTAssertNotNil(loggedError, "F1: encode failure must be observable (review v3 F1)")
    XCTAssertTrue(loggedError is AlwaysThrowingEncodable.Boom,
                  "logger must receive the original error, got \(String(describing: loggedError))")
    XCTAssertEqual(captured?.0, nil)
    XCTAssertEqual(captured?.1, PieHelperXPCWire.fallbackReplyEncodeFailureData,
                   "F2: fallback bytes must be emitted byte-for-byte (review v3 F2)")

    // Chain end-to-end: the GUI-side decoder sees the fallback as a
    // .failure carrying .wireContractViolation, not a generic
    // DecodingError. (Fallback bytes are a well-formed EngineError
    // payload by design — they decode through the normal path and
    // surface as a typed failure case.)
    let result = try? PieHelperXPCWire.decodeStartEngineReply(
      successData: captured?.0, errorData: captured?.1
    )
    if case .failure(let decoded) = result {
      XCTAssertEqual(decoded.code, .wireContractViolation)
    } else {
      XCTFail("expected .failure(.wireContractViolation), got \(String(describing: result))")
    }
  }

  func test_replyTailLog_encode_failure_emits_fallback_and_invokes_logger() {
    var captured: (FileHandle?, Data?)? = nil
    var loggedError: Error? = nil

    PieHelperXPCWire._replyTailLog(
      .failure(EngineError(code: .unknown, message: "x")),
      via: { captured = ($0, $1) },
      encode: { _ in throw AlwaysThrowingEncodable.Boom() },
      onEncodeFailure: { loggedError = $0 }
    )

    XCTAssertNotNil(loggedError, "review v3 F1")
    XCTAssertTrue(loggedError is AlwaysThrowingEncodable.Boom)
    XCTAssertNil(captured?.0)
    XCTAssertEqual(captured?.1, PieHelperXPCWire.fallbackReplyEncodeFailureData,
                   "review v3 F2")

    let result = try? PieHelperXPCWire.decodeTailLogReply(
      handle: captured?.0, errorData: captured?.1
    )
    if case .failure(let decoded) = result {
      XCTAssertEqual(decoded.code, .wireContractViolation)
    } else {
      XCTFail("expected .failure(.wireContractViolation), got \(String(describing: result))")
    }
  }

  func test_replyTailLog_success_path_does_not_log_on_handle() {
    // FileHandle path bypasses the encoder entirely — must not
    // accidentally trip the failure logger.
    var captured: (FileHandle?, Data?)? = nil
    var loggedError: Error? = nil
    PieHelperXPCWire._replyTailLog(
      .success(FileHandle.standardError),
      via: { captured = ($0, $1) },
      encode: { _ in throw AlwaysThrowingEncodable.Boom() },
      onEncodeFailure: { loggedError = $0 }
    )
    XCTAssertNil(loggedError)
    XCTAssertNotNil(captured?.0)
    XCTAssertNil(captured?.1)
  }

  // MARK: - #459 F1: protocol-version gate for the modelOverride selector

  /// A stale helper from a previous build reports its own compiled-in
  /// version and only exports the OLD `startEngineWithProfileID:reply:`
  /// selector. The repair gate keys on
  /// `helperProtocolVersion() >= currentVersion`, so adding the now-required
  /// `startEngine(profileID:modelOverride:)` selector REQUIRES a version bump
  /// — otherwise a stale v2 helper passes as healthy and the new App's start
  /// call dies into a swallowed `.replyTimeout` and the engine never boots.
  private final class FixedVersionClient: AppXPCClient, @unchecked Sendable {
    let version: Int
    init(version: Int) { self.version = version }
    func helperProtocolVersion() async throws -> Int { version }
    func engineStatus() async throws -> EngineStatus { .stopped }
    func stopEngine() async throws {}
    func startEngine(profileID: String, modelOverride: String?) async throws {}
    func restartEngine(profileID: String, modelOverride: String?) async throws {}
  }

  func test_currentVersion_bumped_for_kvUsage_selector() {
    // #476 changed the `EngineStatus.running` + start/restart reply BYTES to
    // carry an `EngineSessionSnapshot` (selector signatures unchanged). A stale
    // v4 helper would answer with old-shape bytes that fail the App's snapshot
    // decode, so the repair gate must fire. #517 then added the required
    // `kvUsageWithReply:` selector, so stale v5 helpers must also be repaired
    // before the App calls the selector. Pin the version so a future
    // wire/selector change fails here until it is bumped.
    XCTAssertEqual(HelperProtocolCompatibility.currentVersion, 6,
                   "bump currentVersion whenever a REQUIRED PieHelperXPC selector is added OR reply/status wire BYTES change")
  }

  func test_isCompatible_routes_stale_lower_version_helper_to_repair() async {
    let current = HelperProtocolCompatibility.currentVersion
    let staleOK = await HelperProtocolCompatibility.isCompatible(
      client: FixedVersionClient(version: current - 1))
    let freshOK = await HelperProtocolCompatibility.isCompatible(
      client: FixedVersionClient(version: current))
    XCTAssertFalse(staleOK,
                   "a helper below currentVersion must fail the gate so repair unregisters+reregisters it before any start path runs")
    XCTAssertTrue(freshOK)
  }

  // MARK: - #459 F2: cross-layer engine-start timeout ladder

  /// Each outer layer must sit strictly above the inner one so no layer
  /// reports a premature failure for a still-booting engine, and the App
  /// restart wait must dominate the helper's SERIAL stop+start budget.
  func test_engine_start_timeout_ladder_is_strictly_ordered() {
    let engineLease = PieControlLauncher.coldStartHandshakeTimeout
      + PieEngineHost.defaultLaunchTimeoutSlack
    XCTAssertLessThan(engineLease, HelperExportedAPI.startReplyDeadline,
                      "helper start reply deadline must exceed the engine launch lease so its reply reflects the real outcome")
    let helperSerialWorstCase = HelperExportedAPI.startReplyDeadline
      + HelperExportedAPI.stopReplyDeadline
    XCTAssertLessThan(helperSerialWorstCase, HelperXPCClient.defaultRestartReplyTimeout,
                      "App restart wait must dominate the helper's serial stop+start budget (review F2: was 2s short)")
    // #461: the plain-start App wait must likewise dominate the helper's start
    // reply deadline. Pre-#461 `startEngine` used the 2s generic `replyTimeout`
    // — far below the engine lease — so every cold large-model app start timed
    // out and churned the shared connection while the helper was still booting.
    XCTAssertLessThan(HelperExportedAPI.startReplyDeadline,
                      HelperXPCClient.defaultStartReplyTimeout,
                      "App plain-start wait must dominate the helper's start reply deadline (#461: was 2s, below the engine lease)")
    XCTAssertGreaterThan(HelperXPCClient.defaultStartReplyTimeout, engineLease,
                         "App plain-start wait must also sit above the engine launch lease so it never reports a premature failure for a still-booting engine (#461)")
  }

  // MARK: - helpers

  private func assertRoundTrip<T: Codable & Equatable>(
    _ value: T,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    do {
      let data = try XPCPayload.encode(value)
      let decoded = try XPCPayload.decode(T.self, from: data)
      XCTAssertEqual(decoded, value, file: file, line: line)
    } catch {
      XCTFail("round-trip threw: \(error)", file: file, line: line)
    }
  }
}
