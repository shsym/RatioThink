import XCTest
@testable import RatioThinkCore
import Foundation

/// #447 — the classifier is the testable heart of "diagnostics can
/// distinguish crash / segfault / OOM / SIGKILL / user-stop / helper-
/// termination / liveness-failure", and the field allowlist is the testable
/// heart of the no-chat-content invariant.
final class EngineTerminationTests: XCTestCase {

  // MARK: - cause classification

  func test_cleanExit() {
    let t = EngineTermination.classify(reason: .exit, status: 0,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .cleanExit)
    XCTAssertEqual(t.exitCode, 0)
    XCTAssertNil(t.signal)
  }

  func test_nonzeroExit_carriesCode() {
    let t = EngineTermination.classify(reason: .exit, status: 3,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .nonzeroExit)
    XCTAssertEqual(t.exitCode, 3)
    XCTAssertNil(t.signal)
  }

  func test_segfault_SIGSEGV() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGSEGV,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .segfault)
    XCTAssertEqual(t.signal, SIGSEGV)
    XCTAssertEqual(t.signalName, "SIGSEGV")
    XCTAssertNil(t.exitCode)
  }

  func test_segfault_SIGBUS() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGBUS,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .segfault)
    XCTAssertEqual(t.signalName, "SIGBUS")
  }

  func test_crash_SIGABRT_rustPanic() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGABRT,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .crash)
    XCTAssertEqual(t.signalName, "SIGABRT")
  }

  func test_crash_SIGILL() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGILL,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .crash)
  }

  func test_externalSIGKILL_belowGuardrail_isKilled() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGKILL,
      initiator: .engine, lastRSSBytes: 1_000_000_000, guardrailBytes: 8_000_000_000)
    XCTAssertEqual(t.cause, .killed)
    XCTAssertEqual(t.signal, SIGKILL)
  }

  func test_SIGKILL_atOrAboveGuardrail_isLikelyOOM() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGKILL,
      initiator: .engine, lastRSSBytes: 8_000_000_000, guardrailBytes: 8_000_000_000)
    XCTAssertEqual(t.cause, .oom)
    XCTAssertEqual(t.signal, SIGKILL)
  }

  func test_SIGKILL_noRSSorGuardrail_isKilled_notOOM() {
    // OOM is a heuristic that needs both signals; missing either → killed.
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGKILL,
      initiator: .engine, lastRSSBytes: nil, guardrailBytes: 8_000_000_000)
    XCTAssertEqual(t.cause, .killed)
  }

  func test_userStop_shortCircuits_regardlessOfSignal() {
    // We sent the SIGINT/SIGKILL — must NOT read as crash/oom even though the
    // RSS is above the guardrail and the signal is SIGKILL.
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGKILL,
      initiator: .user, lastRSSBytes: 9_000_000_000, guardrailBytes: 8_000_000_000)
    XCTAssertEqual(t.cause, .userStop)
  }

  func test_helperShutdown_shortCircuits() {
    let t = EngineTermination.classify(reason: .exit, status: 0,
      initiator: .helper, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .helperShutdown)
  }

  func test_livenessFailure_processStillAlive_reasonNil() {
    // Control-plane hang: the process did not exit, so there is no
    // reason/status snapshot to read.
    let t = EngineTermination.classify(reason: nil, status: nil,
      initiator: .liveness, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .livenessFailure)
  }

  func test_launchInitiator_selfExit_classifiesBySignal_notStop() {
    // A pre-handshake self-death (engineExitedEarly) keeps initiator=.launch
    // but the cause comes from the real reason/status.
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGSEGV,
      initiator: .launch, lastRSSBytes: nil, guardrailBytes: nil)
    XCTAssertEqual(t.cause, .segfault)
    XCTAssertEqual(t.initiator, .launch)
  }

  // MARK: - no-chat-content invariant

  func test_diagnosticFields_keyAllowlist() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGSEGV,
      initiator: .engine, lastRSSBytes: 7_340_032_000, guardrailBytes: 8_000_000_000)
    let keys = Set(t.diagnosticFields.map { $0.0 })
    let allowed: Set<String> = ["cause", "initiator", "signal", "name", "code",
                                "rss_mb", "guardrail_mb"]
    XCTAssertTrue(keys.isSubset(of: allowed),
                  "unexpected diagnostic key(s): \(keys.subtracting(allowed))")
  }

  func test_diagnosticFields_valuesAreScalars_noProseChannel() {
    // Every value is a short scalar: no newline, no multi-line tail, nothing
    // that could smuggle a prompt / generated token / request body.
    for initiator in [EngineTermination.Initiator.engine, .user, .helper, .launch, .liveness] {
      let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGKILL,
        initiator: initiator, lastRSSBytes: 9_000_000_000, guardrailBytes: 8_000_000_000)
      for (k, v) in t.diagnosticFields {
        XCTAssertFalse(v.contains("\n"), "field \(k) carried a newline")
        XCTAssertLessThanOrEqual(v.count, 24, "field \(k) value too long: \(v)")
      }
    }
  }

  func test_rssAndGuardrail_renderedAsMegabytes() {
    let t = EngineTermination.classify(reason: .uncaughtSignal, status: SIGKILL,
      initiator: .engine, lastRSSBytes: 8_589_934_592 /* 8 GiB */,
      guardrailBytes: 5_368_709_120 /* 5 GiB */)
    let fields = Dictionary(uniqueKeysWithValues: t.diagnosticFields)
    XCTAssertEqual(fields["rss_mb"], "8192")
    XCTAssertEqual(fields["guardrail_mb"], "5120")
  }
}
