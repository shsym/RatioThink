import XCTest
@testable import RatioThinkCore

final class PieControlLauncherHandshakeTests: XCTestCase {
  func test_parseHandshakeLine_acceptsLegacyServingLine() {
    var state = PieControlLauncher.HandshakeState()

    PieControlLauncher.parseHandshakeLine(
      "pie-server serving on 127.0.0.1:59165 (1 model(s))",
      into: &state
    )
    PieControlLauncher.parseHandshakeLine("internal token: abc123", into: &state)

    XCTAssertEqual(state.address, "127.0.0.1:59165")
    XCTAssertEqual(state.token, "abc123")
  }

  func test_parseHandshakeLine_acceptsServerReadyWSLine() {
    var state = PieControlLauncher.HandshakeState()

    PieControlLauncher.parseHandshakeLine(
      "✓ Server ready at ws://127.0.0.1:64307",
      into: &state
    )
    PieControlLauncher.parseHandshakeLine("internal token: token-value", into: &state)

    XCTAssertEqual(state.address, "127.0.0.1:64307")
    XCTAssertEqual(state.token, "token-value")
  }
}
