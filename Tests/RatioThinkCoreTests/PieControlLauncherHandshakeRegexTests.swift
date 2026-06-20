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
}
