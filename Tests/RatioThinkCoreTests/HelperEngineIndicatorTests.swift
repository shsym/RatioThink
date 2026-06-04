import XCTest
@testable import RatioThinkCore

/// Tests for the pure toolbar-pip visual reducers (#412): `StatusLED.engineDot`,
/// `HelperRingState.ring`, and the combined `HelperEngineIndicator.make`
/// (ring = helper, dot = engine). Locks the LED language and the helper×engine
/// folding so the view stays a dumb renderer.
final class HelperEngineIndicatorTests: XCTestCase {

  private let err = EngineIndicatorError(kind: .engineFailed, title: "Engine failed", message: "x", invitesModelChoice: false)

  // MARK: - engine dot LED language

  func test_engineDot_LED_language() {
    XCTAssertEqual(StatusLED.engineDot(for: .offline), StatusLED(tint: .off, blink: false))
    XCTAssertEqual(StatusLED.engineDot(for: .starting(detail: "x")), StatusLED(tint: .white, blink: true))
    XCTAssertEqual(StatusLED.engineDot(for: .running(modelID: "m")), StatusLED(tint: .greenWhite, blink: false))
    XCTAssertEqual(StatusLED.engineDot(for: .error(err)), StatusLED(tint: .amber, blink: true))
  }

  // MARK: - helper ring

  func test_helperRing_quiet_when_healthy() {
    XCTAssertNil(HelperRingState.ring(for: .healthy), "a healthy helper shows no ring")
  }

  func test_helperRing_reconnecting_blinkWhite() {
    XCTAssertEqual(HelperRingState.ring(for: .reconnecting(consecutiveFailures: 3)),
                   StatusLED(tint: .white, blink: true))
  }

  func test_helperRing_repairing_blinkAmber() {
    XCTAssertEqual(HelperRingState.ring(for: .repairing(attempt: 1)),
                   StatusLED(tint: .amber, blink: true))
    XCTAssertEqual(HelperRingState.ring(for: .repairCoolingDown(attempt: 1, failuresSinceRepair: 1)),
                   StatusLED(tint: .amber, blink: true))
  }

  func test_helperRing_unreachable_blinkRed() {
    XCTAssertEqual(HelperRingState.ring(for: .unreachable),
                   StatusLED(tint: .red, blink: true))
  }

  // MARK: - combined fold

  func test_healthy_running_quietRing_greenDot() {
    let (ring, dot) = HelperEngineIndicator.make(helper: .healthy, engine: .running(modelID: "m"))
    XCTAssertNil(ring)
    XCTAssertEqual(dot, .led(StatusLED(tint: .greenWhite, blink: false)))
  }

  func test_healthy_loading_showsProgressRing_notDot() {
    let (ring, dot) = HelperEngineIndicator.make(helper: .healthy, engine: .loading(modelID: "m", fraction: 0.5))
    XCTAssertNil(ring)
    XCTAssertEqual(dot, .progressRing(fraction: 0.5))
  }

  func test_reconnecting_keeps_last_engine_dot_under_white_ring() {
    // A transient blip: ring blinks white, but the engine dot stays "last"
    // (engine almost certainly still fine) — not dimmed.
    let (ring, dot) = HelperEngineIndicator.make(helper: .reconnecting(consecutiveFailures: 2),
                                                 engine: .running(modelID: "m"))
    XCTAssertEqual(ring, StatusLED(tint: .white, blink: true))
    XCTAssertEqual(dot, .led(StatusLED(tint: .greenWhite, blink: false)), "reconnecting keeps the last engine dot")
  }

  func test_repairing_dims_dot_under_amber_ring() {
    // Engine state is stale/unknown while the helper is being restarted.
    let (ring, dot) = HelperEngineIndicator.make(helper: .repairing(attempt: 1),
                                                 engine: .running(modelID: "m"))
    XCTAssertEqual(ring, StatusLED(tint: .amber, blink: true))
    XCTAssertEqual(dot, .led(.dim))
  }

  func test_unreachable_dims_dot_under_red_ring() {
    let (ring, dot) = HelperEngineIndicator.make(helper: .unreachable, engine: .running(modelID: "m"))
    XCTAssertEqual(ring, StatusLED(tint: .red, blink: true))
    XCTAssertEqual(dot, .led(.dim))
  }
}
