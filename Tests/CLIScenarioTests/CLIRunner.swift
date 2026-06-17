import Foundation
import Darwin
import RatioThinkCore
import Scenarios

/// CLI-flavored runner. Implements headless scenarios (S1, S2, S6) by
/// calling RatioThinkCore APIs directly. S3 was previously a subprocess
/// scenario plumbed through this runner; it now drives
/// `PieControlLauncher` + `HTTPEngineClient` directly from the
/// scenario (binding hands it a `LaunchSpec`), so this runner no
/// longer carries pie-subprocess plumbing.
public final class CLIRunner: ScenarioRunner {
  private let stepPrint: Bool

  public init(stepPrint: Bool = true) {
    self.stepPrint = stepPrint
  }

  public func step(_ name: String, _ body: () async throws -> Void) async throws {
    if stepPrint { print("  · \(name)") }
    try await body()
  }

  // MARK: - S1

  public func parseProfile(toml: String) async throws -> Profile {
    try Profile.parse(toml: toml)
  }

  public func dumpProfile(_ p: Profile) async throws -> String {
    try p.dump()
  }

  // MARK: - S2

  public func pieDirsApplicationSupport() async throws -> URL {
    try PieDirs.applicationSupport()
  }

  public func pieDirsSubpath(_ kind: PieDirsKind) async throws -> URL {
    switch kind {
    case .profiles:  return try PieDirs.profiles()
    case .models:    return try PieDirs.models()
    case .inferlets: return try PieDirs.inferlets()
    case .logs:      return try PieDirs.logs()
    }
  }

  public func fileExists(at url: URL) async throws -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  public func resourceIsExcludedFromBackup(at url: URL) async throws -> Bool {
    let vals = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    return vals.isExcludedFromBackup ?? false
  }

  // MARK: - S6 XPC payload round-trip
  //
  // CLI runner does an in-process JSON round-trip via XPCPayload — same
  // wire format the helper will speak in Phase 2. A future runner that
  // owns a real `NSXPCConnection` can override these to drive the
  // listener end-to-end without touching scenario code.

  public func xpcRoundTripEngineStatus(_ status: EngineStatus) async throws -> EngineStatus {
    try XPCPayload.decode(EngineStatus.self, from: XPCPayload.encode(status))
  }

  public func xpcRoundTripDownloadHandle(_ h: DownloadHandle) async throws -> DownloadHandle {
    try XPCPayload.decode(DownloadHandle.self, from: XPCPayload.encode(h))
  }

  public func xpcRoundTripEngineError(_ e: EngineError) async throws -> EngineError {
    try XPCPayload.decode(EngineError.self, from: XPCPayload.encode(e))
  }

  public func xpcStartEngineReplyRoundTrip(
    _ result: Result<EngineSessionSnapshot, EngineError>
  ) async throws -> Result<EngineSessionSnapshot, EngineError> {
    var captured: (Data?, Data?) = (nil, nil)
    PieHelperXPCWire.replyStartEngine(result) { captured = ($0, $1) }
    return try PieHelperXPCWire.decodeStartEngineReply(
      successData: captured.0, errorData: captured.1
    )
  }
}
