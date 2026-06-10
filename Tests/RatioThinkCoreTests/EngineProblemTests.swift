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

  func test_unknownCode_fallsBackToHonestGenericNamingTheCode() {
    let p = EngineProblem(statusCode: .wireContractViolation, rawMessage: "")
    XCTAssertEqual(p.recovery, .restartEngine)
    XCTAssertTrue(p.message.contains("wireContractViolation"),
                  "generic copy must still name the code: \(p.message)")
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
    let err = HTTPEngineError.api(status: 404, code: "model_not_found", message: "no such model")
    let p = EngineProblem(requestError: err, requestedModelID: "qwen/qwen3-0.6b/model.gguf")
    XCTAssertEqual(p.recovery, .chooseModel)
    XCTAssertTrue(p.message.contains("isn’t installed"), p.message)
    XCTAssertFalse(p.message.contains("model_not_found"), p.message)
  }

  func test_modelNotFound_midStream_sameMapping() {
    let err = HTTPEngineError.stream(code: "model_not_found", message: "raw")
    XCTAssertEqual(EngineProblem(requestError: err).recovery, .chooseModel)
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
