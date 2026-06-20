import XCTest
@testable import RatioThinkCore

/// Engine-free pin for the launch handshake's address matcher. The real
/// matcher only runs in the operator-gated real-engine matrix, so the
/// `Server ready at ws://` branch — the form production pie emits today
/// (`server/src/serve.rs`) — would otherwise have no CI coverage: a typo in
/// `PieControlLauncher.readyBannerAddressPattern` would still pass the unit +
/// scenario tiers and hang only on a real engine. This test runs the SAME
/// pattern `awaitHandshake` uses against both banner forms and asserts each
/// captures the bare `host:port`, so banner drift is caught in `make test-unit`.
final class PieControlLauncherHandshakeRegexTests: XCTestCase {
  /// Extract capture group 1 exactly as `awaitHandshake` does.
  private func capturedAddress(in line: String) throws -> String? {
    let regex = try NSRegularExpression(pattern: PieControlLauncher.readyBannerAddressPattern)
    let range = NSRange(line.startIndex..., in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let r = Range(match.range(at: 1), in: line) else { return nil }
    return String(line[r])
  }

  func test_currentReadyBanner_capturesHostPort() throws {
    // The form current pie prints (serve.rs:265), incl. the ✓ prefix.
    XCTAssertEqual(try capturedAddress(in: "✓ Server ready at ws://127.0.0.1:8080"), "127.0.0.1:8080")
  }

  func test_legacyServingBanner_capturesHostPort() throws {
    // The pre-bump banner — kept matched so older engines still hand-shake.
    XCTAssertEqual(try capturedAddress(in: "pie-server serving on 127.0.0.1:8080"), "127.0.0.1:8080")
  }

  func test_unrelatedLine_capturesNothing() throws {
    // A line carrying neither banner must not yield a spurious address.
    XCTAssertNil(try capturedAddress(in: "internal token: deadbeef"))
  }

  // MARK: - #736 daemon-port parser

  /// pie binds the inferlet daemon to an OS-assigned port (the launcher passes
  /// 0 to dodge the reserve-bind-close-reuse race) and logs `Daemon serving
  /// HTTP on http://<host>:<port>/`. `awaitDaemonPort` learns the port from
  /// that line, so a banner-format drift must be caught here — not only on a
  /// real engine.
  func test_daemonPort_parsesServingBanner() {
    XCTAssertEqual(
      PieControlLauncher.daemonPort(from: "Daemon serving HTTP on http://127.0.0.1:54321/"),
      54321)
    // Tolerate a leading timestamp/level prefix from the tracing layer.
    XCTAssertEqual(
      PieControlLauncher.daemonPort(from: "2026-06-20 INFO daemon: Daemon serving HTTP on http://127.0.0.1:7/"),
      7)
  }

  func test_daemonPort_ignoresUnrelatedLines() {
    XCTAssertNil(PieControlLauncher.daemonPort(from: "✓ Server ready at ws://127.0.0.1:8080"))
    XCTAssertNil(PieControlLauncher.daemonPort(from: "internal token: deadbeef"))
    // No port in the authority → no match (never a spurious 0).
    XCTAssertNil(PieControlLauncher.daemonPort(from: "Daemon serving HTTP on http://127.0.0.1/"))
  }

  // MARK: - #736 build-9: read the port from pie.log (the real sink), not stdout

  /// pie writes the "Daemon serving" line via `tracing::info!` → it lands ONLY
  /// in `<pieHome>/logs/pie.log.<date>`, never on captured stdout (build-8's
  /// bug). `scanDaemonPort` must read that file, and — because the rolling
  /// daily file is shared across same-day launches — it must IGNORE a stale
  /// line written before the pre-launch cursor and return THIS launch's port.
  func test_scanDaemonPort_readsPieLog_skippingStaleLineBeforeCursor() throws {
    let fm = FileManager.default
    let pieHome = fm.temporaryDirectory.appendingPathComponent("pielog-\(UUID().uuidString)")
    let logs = pieHome.appendingPathComponent("logs")
    try fm.createDirectory(at: logs, withIntermediateDirectories: true)
    let logFile = logs.appendingPathComponent("pie.log.2026-06-20")

    // A previous same-day launch left a stale serving line with an OLD port.
    let stale = "2026-06-20T14:00:00 INFO daemon: Daemon serving HTTP on http://127.0.0.1:11111/\n"
    try stale.data(using: .utf8)!.write(to: logFile)

    // Snapshot the cursor BEFORE this launch's daemon binds.
    let cursor = PieControlLauncher.daemonLogCursor(pieHome: pieHome)

    // Before this launch logs anything new, the post-cursor scan finds nothing
    // (must NOT return the stale 11111).
    XCTAssertNil(PieControlLauncher.scanDaemonPort(pieHome: pieHome, baseline: cursor),
                 "stale pre-cursor port must be ignored")

    // This launch binds and logs its real port.
    let fresh = "2026-06-20T14:17:36 INFO daemon: Daemon serving HTTP on http://127.0.0.1:22222/\n"
    let handle = try FileHandle(forWritingTo: logFile)
    handle.seekToEndOfFile()
    handle.write(fresh.data(using: .utf8)!)
    try handle.close()

    XCTAssertEqual(PieControlLauncher.scanDaemonPort(pieHome: pieHome, baseline: cursor), 22222,
                   "must learn THIS launch's bound port from pie.log")
    try? fm.removeItem(at: pieHome)
  }

  /// No logs dir / no pie.log yet → nil (caller keeps polling), never a throw.
  func test_scanDaemonPort_absentLog_returnsNil() {
    let pieHome = FileManager.default.temporaryDirectory.appendingPathComponent("pielog-none-\(UUID().uuidString)")
    XCTAssertNil(PieControlLauncher.scanDaemonPort(pieHome: pieHome, baseline: .zero))
    XCTAssertNil(PieControlLauncher.newestDaemonLog(pieHome: pieHome))
  }
}
