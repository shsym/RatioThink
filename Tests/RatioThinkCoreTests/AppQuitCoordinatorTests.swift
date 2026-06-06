import XCTest
@testable import RatioThinkCore

/// #448: the App-side full-product quit coordinator. Pins the teardown
/// contract — stop polling, ask the helper to quit, always signal `done` so
/// the App can terminate — without a real helper or AppKit.
@MainActor
final class AppQuitCoordinatorTests: XCTestCase {

  /// Records `quitHelper` invocations and can be told to throw, so the
  /// coordinator's best-effort sequencing is observable.
  private final class FakeQuitClient: AppXPCClient, @unchecked Sendable {
    private(set) var quitCount = 0
    var quitError: Error?
    var suspendQuit = false
    var quitContinuation: CheckedContinuation<Void, Error>?
    func helperProtocolVersion() async throws -> Int { HelperProtocolCompatibility.currentVersion }
    func engineStatus() async throws -> EngineStatus { .stopped }
    func stopEngine() async throws {}
    func startEngine(profileID: String) async throws {}
    func restartEngine(profileID: String) async throws {}
    func quitHelper() async throws {
      quitCount += 1
      if let quitError { throw quitError }
      guard suspendQuit else { return }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        quitContinuation = continuation
      }
    }
  }

  func test_testLaunch_skipsHelperQuit_butStillSignalsDone() async {
    let client = FakeQuitClient()
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: true)
    let done = expectation(description: "done")
    coord.beginTeardown { done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(client.quitCount, 0, "a test/automation launch must NOT quit the real helper")
    XCTAssertTrue(coord.isQuitting)
  }

  func test_realLaunch_callsQuitHelper_thenSignalsDone() async {
    let client = FakeQuitClient()
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let done = expectation(description: "done")
    coord.beginTeardown { done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(client.quitCount, 1, "a real quit must ask the helper to stop the engine + exit")
  }

  func test_quitHelperFailure_isBestEffort_stillSignalsDone() async {
    let client = FakeQuitClient()
    client.quitError = AppXPCClientError.replyTimeout(selector: "quitHelper", timeout: HelperXPCClient.quitReplyTimeout)
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let done = expectation(description: "done despite helper error")
    coord.beginTeardown { done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(client.quitCount, 1)
  }

  func test_secondTeardown_afterCompletion_isIdempotent_doesNotReQuitHelper() async {
    let client = FakeQuitClient()
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let first = expectation(description: "first done")
    coord.beginTeardown { first.fulfill() }
    await fulfillment(of: [first], timeout: 2)
    let second = expectation(description: "second done")
    coord.beginTeardown { second.fulfill() }
    await fulfillment(of: [second], timeout: 2)
    XCTAssertEqual(client.quitCount, 1, "a repeated applicationShouldTerminate must not re-quit the helper")
  }

  func test_secondTeardown_whileHelperQuitInFlight_waitsForOriginalCompletion() async {
    let client = FakeQuitClient()
    client.suspendQuit = true
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let firstReleased = expectation(description: "first done after helper completes")
    var firstDoneEarly = false
    coord.beginTeardown {
      firstDoneEarly = true
      firstReleased.fulfill()
    }

    for _ in 0..<20 where client.quitContinuation == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(client.quitCount, 1)
    XCTAssertNotNil(client.quitContinuation, "fake helper quit should be suspended before the second quit request")
    XCTAssertFalse(firstDoneEarly)

    let secondReleased = expectation(description: "second done after helper completes")
    var secondDoneEarly = false
    coord.beginTeardown {
      secondDoneEarly = true
      secondReleased.fulfill()
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertFalse(firstDoneEarly, "first callback must wait for helper quit completion")
    XCTAssertFalse(secondDoneEarly, "reentrant callback must wait for helper quit completion")
    XCTAssertEqual(client.quitCount, 1, "reentrant quit must share the in-flight helper quit")

    client.quitContinuation?.resume(returning: ())
    await fulfillment(of: [firstReleased, secondReleased], timeout: 2)
    XCTAssertTrue(firstDoneEarly)
    XCTAssertTrue(secondDoneEarly)
    XCTAssertEqual(client.quitCount, 1)
  }
}
