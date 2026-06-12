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
}
