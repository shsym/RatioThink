import XCTest
@testable import RatioThinkCore

/// #477: the single raw-error → user-problem → next-action taxonomy.
/// Two contracts under test:
///   1. Mapping — each fault routes to the right title/recovery.
///   2. Leak-proofing — raw diagnostic text (stderr tails, resolver
///      traces, wire messages, NSError dumps) never appears in the
///      primary `message`; it is preserved only in `technicalDetail`.
final class EngineProblemTests: XCTestCase {

  // MARK: - status axis: mapping

  func test_modelMissing_routesToChooseModel() {
    let p = EngineProblem(statusCode: .modelMissing, rawMessage: "x")
    XCTAssertEqual(p.title, "Model not installed")
    XCTAssertEqual(p.recovery, .chooseModel)
  }

  func test_memoryRisk_routesToChooseModel() {
    let p = EngineProblem(statusCode: .memoryRisk, rawMessage: "x")
    XCTAssertEqual(p.title, "Model too large")
    XCTAssertEqual(p.recovery, .chooseModel)
  }

  func test_profileMissing_routesToChooseModel() {
    XCTAssertEqual(
      EngineProblem(statusCode: .profileMissing, rawMessage: "").recovery,
      .chooseModel)
  }

  func test_engineGone_routesToRestartEngine() {
    let p = EngineProblem(statusCode: .engineGone, rawMessage: "x")
    XCTAssertEqual(p.title, "Engine stopped unexpectedly")
    XCTAssertEqual(p.recovery, .restartEngine)
  }

  func test_spawnFailed_and_handshakeTimeout_routeToRestartEngine() {
    for code in [EngineErrorCode.spawnFailed, .handshakeTimeout, .portUnavailable] {
      let p = EngineProblem(statusCode: code, rawMessage: "x")
      XCTAssertEqual(p.title, "The engine couldn’t start", "\(code)")
      XCTAssertEqual(p.recovery, .restartEngine, "\(code)")
    }
  }

  func test_killRejected_offersNoAction() {
    XCTAssertEqual(
      EngineProblem(statusCode: .killRejected, rawMessage: "x").recovery, .none)
  }

  func test_degraded_routesToRestartHelper() {
    XCTAssertEqual(
      EngineProblem(statusCode: .degraded, rawMessage: "x").recovery, .restartHelper)
  }

  func test_wireContractViolation_isPlumbingBug_notEngineRestart() {
    // Documented as an app–helper plumbing bug — an engine restart can't
    // fix a type-skewed XPC reply, and the case name is not user copy.
    let p = EngineProblem(statusCode: .wireContractViolation, rawMessage: "decode failed")
    XCTAssertEqual(p.recovery, .none)
    XCTAssertEqual(p.title, "App–helper communication problem")
    XCTAssertFalse(p.message.contains("wireContractViolation"), p.message)
  }

  func test_unknownCode_fallsBackToGeneric_codeOnlyInTechnicalDetail() {
    let p = EngineProblem(statusCode: .unknown, rawMessage: "raw cause")
    XCTAssertEqual(p.recovery, .restartEngine)
    XCTAssertFalse(p.message.contains("unknown"),
                   "enum case names are never user copy: \(p.message)")
    XCTAssertEqual(p.technicalDetail, "[unknown] raw cause",
                   "the code discriminator must survive in the diagnostic")
    XCTAssertEqual(EngineProblem(statusCode: .unknown, rawMessage: "").technicalDetail,
                   "unknown")
  }

  // MARK: - status axis: leak-proofing

  func test_statusRawMessage_neverLeaksIntoPrimaryCopy() {
    // Real shapes observed in the codebase: launcher stderr tail,
    // resolver trace with paths + debugDescription, guardrail prose.
    let raws: [(EngineErrorCode, String)] = [
      (.spawnFailed,
       "PieControlLauncher: pie exited early signal 6 stderr-tail:\nthread 'main' panicked at src/x.rs:42"),
      (.modelMissing,
       "model missing for profile Optional(\"default\"): \"qwen/q.gguf\"; checked app-staged path /Users/x/Library/..."),
      (.memoryRisk,
       "memory risk: choose a smaller model; model \"big\" at /Users/x/big.gguf was not launched; needs 32 GiB."),
    ]
    for (code, raw) in raws {
      let p = EngineProblem(statusCode: code, rawMessage: raw)
      XCTAssertFalse(p.message.contains("stderr"), "\(code): \(p.message)")
      XCTAssertFalse(p.message.contains("/Users/"), "\(code): \(p.message)")
      XCTAssertFalse(p.title.contains("/Users/"), "\(code): \(p.title)")
      XCTAssertEqual(p.technicalDetail, raw, "\(code) must preserve the diagnostic")
    }
  }

  func test_emptyRawMessage_meansNoTechnicalDetail() {
    XCTAssertNil(EngineProblem(statusCode: .spawnFailed, rawMessage: "  \n").technicalDetail)
  }

  // MARK: - request axis: model_not_found

  func test_modelNotFound_namesTheModelLeaf_andRoutesToChooseModel() {
    let modelID = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    let err = HTTPEngineError.api(status: 404, code: "model_not_found", message: "no such model")
    let p = EngineProblem(requestError: err, requestedModelID: modelID)
    XCTAssertEqual(p.recovery, .chooseModel)
    XCTAssertEqual(
      p.message,
      "Model \(ModelDisplayName.leaf(modelID)) isn’t installed — download it in Settings → Models, or pick another model.")
    XCTAssertFalse(p.message.contains("model_not_found"), p.message)
  }

  func test_modelNotFound_midStream_sameMapping_withoutModelID() {
    let err = HTTPEngineError.stream(code: "model_not_found", message: "noisy detail")
    let p = EngineProblem(requestError: err)
    XCTAssertEqual(p.recovery, .chooseModel)
    XCTAssertEqual(
      p.message,
      "The selected model isn’t installed — download it in Settings → Models, or pick another model.")
  }

  func test_modelNotFound_totTerminalFrame_paritiesHTTPPath() {
    // Review F3: the ToT stream's model_not_found terminal frame is the
    // same user problem as the HTTP envelope's — retrying would re-fail.
    let err = ToTStreamError.stream(code: "model_not_found", message: "raw")
    let p = EngineProblem(requestError: err, requestedModelID: "org/repo/m.gguf")
    XCTAssertEqual(p.recovery, .chooseModel)
    XCTAssertTrue(p.message.contains("isn’t installed"), p.message)
    // v2 F3: the wire code must survive in the diagnostic — the
    // errorDescription bridge drops it when a message is present.
    XCTAssertEqual(p.technicalDetail, "[model_not_found] raw")
  }

  func test_totStream_genericFrame_diagnosticKeepsCode() {
    let p = EngineProblem(requestError: ToTStreamError.stream(code: "budget_exhausted", message: "kv full"))
    XCTAssertEqual(p.technicalDetail, "[budget_exhausted] kv full")
    XCTAssertEqual(EngineProblem(requestError: ToTStreamError.stream(code: "x", message: "")).technicalDetail,
                   "[x]")
  }

  // MARK: - request axis: FaultClass

  func test_inFlightCrash503_invitesRetryShortly() {
    let err = HTTPEngineError.http(status: 503, body: Data("handler-panic".utf8), retryAfter: 2)
    let p = EngineProblem(requestError: err)
    XCTAssertEqual(p.recovery, .retryShortly)
    XCTAssertFalse(p.message.contains("handler-panic"), p.message)
  }

  func test_hostSetup500_invitesRestartEngine() {
    let err = HTTPEngineError.http(status: 500, body: Data("instantiate-failed".utf8), retryAfter: nil)
    XCTAssertEqual(EngineProblem(requestError: err).recovery, .restartEngine)
  }

  func test_guestFault502_invitesRetrySend() {
    let err = HTTPEngineError.http(status: 502, body: Data("handler-trap".utf8), retryAfter: nil)
    XCTAssertEqual(EngineProblem(requestError: err).recovery, .retrySend)
  }

  // MARK: - request axis: lifecycle + generic

  func test_engineGone_request_invitesRestartEngine() {
    let p = EngineProblem(requestError: HTTPEngineError.engineGone(detail: "exit 9"))
    XCTAssertEqual(p.recovery, .restartEngine)
    XCTAssertFalse(p.message.contains("exit 9"), p.message)
  }

  func test_engineNotReady_invitesRetryShortly() {
    XCTAssertEqual(
      EngineProblem(requestError: HTTPEngineError.engineNotReady(detail: "")).recovery,
      .retryShortly)
  }

  func test_genericApiError_neverShowsWireText() {
    let err = HTTPEngineError.api(status: 400, code: "context_overflow",
                                  message: "prompt of 9999 tokens exceeds kv budget")
    let p = EngineProblem(requestError: err)
    XCTAssertEqual(p.recovery, .retrySend)
    XCTAssertFalse(p.message.contains("kv budget"), p.message)
    XCTAssertEqual(p.technicalDetail, err.description)
  }

  func test_totStreamError_normalizes_andPreservesDiagnostic() {
    let err = ToTStreamError.malformedFrame(payload: "{\"event\":\"???\"}")
    let p = EngineProblem(requestError: err)
    XCTAssertEqual(p.recovery, .retrySend)
    XCTAssertFalse(p.message.contains("???"), p.message)
    XCTAssertTrue(p.technicalDetail?.contains("???") == true)
  }

  func test_urlError_invitesRestartEngine() {
    let p = EngineProblem(requestError: URLError(.cannotConnectToHost))
    XCTAssertEqual(p.recovery, .restartEngine)
  }

  func test_arbitraryNSError_neverShowsDomainDump() {
    let err = NSError(domain: "NSCocoaErrorDomain", code: 256,
                      userInfo: [NSFilePathErrorKey: "/Users/x/store.sqlite"])
    let p = EngineProblem(requestError: err)
    XCTAssertFalse(p.message.contains("domain="), p.message)
    XCTAssertFalse(p.message.contains("/Users/"), p.message)
    XCTAssertTrue(p.technicalDetail?.contains("domain=NSCocoaErrorDomain") == true)
  }
}
