import XCTest
@testable import RatioThinkCore

/// Asserts the launcher's token-redaction policy (review  F1).
/// `LaunchedSession.redactToken` is the single hook that prevents
/// `internal token: <secret>` from landing in
/// `engineExitedEarly.stderrTail` or `handshakeTimeout.lastLines`.
final class PieControlLauncherRedactionTests: XCTestCase {
  func test_redactsBareTokenLine() {
    let raw = "internal token: NrcO7XU8GDIzVp6rjIWGe1TahM2PuSmJmGn4T36ld3HuJcLVsaGiFtHZl7UYn4G3"
    let redacted = LaunchedSession.redactToken(in: raw)
    XCTAssertEqual(redacted, "internal token: <REDACTED>")
    XCTAssertFalse(redacted.contains("NrcO7XU8"), "redacted output must not echo any token prefix")
  }

  func test_redactsTokenWithLeadingTimestamp() {
    let raw = "[2026-05-19T22:15:01Z] internal token: aBcDeFgHiJkLmN0pQ"
    let redacted = LaunchedSession.redactToken(in: raw)
    XCTAssertEqual(redacted, "[2026-05-19T22:15:01Z] internal token: <REDACTED>")
  }

  func test_leavesUnrelatedLinesAlone() {
    let raw = "pie-server serving on 127.0.0.1:59165 (1 model(s))"
    XCTAssertEqual(LaunchedSession.redactToken(in: raw), raw)
  }

  func test_controlAddressParsesLegacyServingMarker() {
    let raw = "pie-server serving on 127.0.0.1:59165 (1 model(s))"
    XCTAssertEqual(LaunchedSession.controlAddress(from: raw), "127.0.0.1:59165")
  }

  func test_controlAddressParsesUpstreamServerReadyWebSocketMarker() {
    let raw = "✓ Server ready at ws://127.0.0.1:63431"
    XCTAssertEqual(LaunchedSession.controlAddress(from: raw), "127.0.0.1:63431")
  }

  func test_redactsEachTokenWhenMultiplePerLine() {
    let raw = "internal token: AAA followed by internal token: BBB"
    let redacted = LaunchedSession.redactToken(in: raw)
    XCTAssertEqual(redacted, "internal token: <REDACTED> followed by internal token: <REDACTED>")
    XCTAssertFalse(redacted.contains("AAA"))
    XCTAssertFalse(redacted.contains("BBB"))
  }

  func test_doesNotMatchPartialPrefix() {
    // A "almost"-match must NOT be redacted. The contract: only
    // strings that look exactly like `internal token: <opaque>`.
    let raw = "looks like internal_token: not_a_match"
    XCTAssertEqual(LaunchedSession.redactToken(in: raw), raw)
  }
}
