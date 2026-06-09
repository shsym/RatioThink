import Foundation
import RatioThinkCore

/// Shared vocabulary that CLI and GUI runners both satisfy. A single
/// scenario definition (e.g. `S1_ProfileRoundtrip.run`) is replayed by
/// both runners. CLI runner calls APIs directly; GUI runner drives
/// XCUITest. Failure semantics: throw on assertion failure; the runner
/// translates the throw into the host test framework's failure mechanism.
public protocol ScenarioRunner {
  /// Log a named step. Tests may use this for traceability.
  func step(_ name: String, _ body: () async throws -> Void) async throws

  /// Plain boolean assert.
  func require(_ cond: Bool, _ message: @autoclosure () -> String,
               file: StaticString, line: UInt) throws

  // MARK: - S1 Profile roundtrip
  func parseProfile(toml: String) async throws -> Profile
  func dumpProfile(_ p: Profile) async throws -> String

  // MARK: - S2 PieDirs lazy creation
  func pieDirsApplicationSupport() async throws -> URL
  func pieDirsSubpath(_ kind: PieDirsKind) async throws -> URL
  func fileExists(at url: URL) async throws -> Bool
  func resourceIsExcludedFromBackup(at url: URL) async throws -> Bool

  // MARK: - S3 Engine subprocess
  //
  // S3 used to require `runEngineOneShot` here, but the rewritten
  // scenario drives `PieControlLauncher` + `HTTPEngineClient` directly
  // (RatioThinkCore APIs available to any runner). Subprocess plumbing is no
  // longer part of the runner protocol — the binding hands a
  // `PieControlLauncher.LaunchSpec` straight into `S3_EngineSubprocess.run`.
  // See `S3_EngineSubprocess` + .

  // MARK: - S6 XPC payload round-trip
  //
  // Encode then decode each XPC value type through the runner so a
  // future runner that drives a real `NSXPCConnection` proves the same
  // Codable contract end-to-end. For v1 the CLIRunner does an
  // in-process JSON round-trip; that's enough to lock the wire format
  // before Phase 2 brings up the helper listener.
  func xpcRoundTripEngineStatus(_ status: EngineStatus) async throws -> EngineStatus
  func xpcRoundTripDownloadHandle(_ handle: DownloadHandle) async throws -> DownloadHandle
  func xpcRoundTripEngineError(_ error: EngineError) async throws -> EngineError
  func xpcStartEngineReplyRoundTrip(
    _ result: Result<EngineSessionSnapshot, EngineError>
  ) async throws -> Result<EngineSessionSnapshot, EngineError>
}

// Note: S4 (Helper menu bar) and S5 (App window shell) are GUI-only and
// live as plain XCUITest cases under Tests/GUIScenarioTests/. They don't
// flow through ScenarioRunner because the GUI bundle can't import RatioThinkCore
// directly (lives in SPM, not the xcodeproj). The convention: any
// scenario testable headlessly goes here as a protocol-driven method;
// GUI-only scenarios are written as bespoke XCUITest classes that mirror
// the same step structure manually.

public enum PieDirsKind: String, CaseIterable {
  case profiles, models, inferlets, logs
}

public enum ScenarioError: Error, CustomStringConvertible {
  case notSupportedByRunner(String)
  case assertionFailed(String, file: StaticString, line: UInt)
  /// Skippable host precondition that the binding probes BEFORE
  /// launching the engine (HF snapshot absent, env gate off, etc.).
  /// Bindings map this to `XCTSkip` (review v1 F5). DO NOT use for
  /// failures observed AFTER the engine is up — those are real
  /// regressions and must surface as `assertionFailed`.
  case precondition(String)
  /// Engine subprocess could not be brought up (binary missing,
  /// handshake timed out, install_program failed, etc). Distinct
  /// from `precondition` so a regression that takes pie down silently
  /// does NOT collapse into "skip" (review v1 F5).
  case engineMissing(String)
  case timeout(String)

  public var description: String {
    switch self {
    case .notSupportedByRunner(let s): return "Runner does not implement: \(s)"
    case .assertionFailed(let m, let f, let l): return "[\(f):\(l)] \(m)"
    case .precondition(let m): return "Precondition not met: \(m)"
    case .engineMissing(let m): return "Engine missing: \(m)"
    case .timeout(let m):       return "Timeout: \(m)"
    }
  }
}

public extension ScenarioRunner {
  func require(_ cond: Bool, _ message: @autoclosure () -> String = "assertion failed",
               file: StaticString = #file, line: UInt = #line) throws {
    if !cond { throw ScenarioError.assertionFailed(message(), file: file, line: line) }
  }
}
