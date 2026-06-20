import XCTest
import Foundation
@testable import RatioThinkCore

/// regression — the app's EngineStatus must CONVERGE to the true engine
/// status after a start INTENT, independent of the background poll cadence.
///
/// The bug: `currentCadence()` pauses the loop on `.stopped`; since the engine
/// no longer auto-starts, the app's first poll saw `.stopped` and suspended the
/// loop, and `startEngine`'s old `start()` re-arm raced the helper committing
/// `.starting` — a re-armed poll that read the pre-start `.stopped` re-paused
/// permanently, so the app never observed `.running` (Load stuck).
///
/// The fix: a start intent OWNS convergence on its own task that polls THROUGH
/// `.stopped → .starting → .running`. These tests drive that seam with an
/// instant `sleepFor` so they assert the convergence, not wall-clock timing.
@MainActor
final class EngineStartConvergenceTests: XCTestCase {

  private func makeStore(initial: EngineStatus)
    -> (EngineStatusStore, EngineStatusStoreTests.StubXPCClient) {
    let stub = EngineStatusStoreTests.StubXPCClient()
    let store = EngineStatusStore(
      client: stub,
      initialStatus: initial,
      now: { Date(timeIntervalSince1970: 1_000) },  // fixed clock; deadline never trips
      sleepFor: { _ in }                            // instant: drive convergence fast
    )
    return (store, stub)
  }

  /// Spin the main-actor run loop until `predicate` holds or `maxYields`
  /// elapses, letting the convergence/liveness tasks make progress.
  private func waitFor(_ maxYields: Int = 500,
                       _ predicate: () -> Bool) async {
    for _ in 0..<maxYields {
      if predicate() { return }
      await Task.yield()
    }
  }

  /// THE regression: starting from a paused-eligible `.stopped`, a start request
  /// converges the published status to `.running` even though the first polls
  /// return the pre-start `.stopped` that would otherwise pause the loop.
  func test_startEngine_convergesToRunning_throughPreStartStopped() async throws {
    let (store, stub) = makeStore(initial: .stopped)
    // The pre-start `.stopped` the cadence loop would latch on, then the real
    // transition the convergence must poll through to.
    stub.setNext(.stopped)
    stub.setNext(.stopped)
    stub.setNext(.starting)
    let snapshot = EngineSessionSnapshot(port: 55_417, profileID: "chat")
    for _ in 0..<8 { stub.setNext(.running(snapshot)) }  // extra runs keep liveness happy

    try await store.startEngine(profileID: "chat")
    await waitFor { if case .running = store.status { return true }; return false }
    store.stop()

    guard case .running(let s) = store.status else {
      return XCTFail("expected convergence to .running, got \(store.status)")
    }
    XCTAssertEqual(s.port, 55_417)
    XCTAssertGreaterThanOrEqual(stub.calls, 3, "convergence must poll through the transition")
  }

  /// A start that ends in a real terminal failure converges to `.failed` (not
  /// stuck on `.starting`) and hands back to the liveness loop.
  func test_startEngine_convergesToFailure() async throws {
    let (store, stub) = makeStore(initial: .stopped)
    stub.setNext(.stopped)
    stub.setNext(.starting)
    for _ in 0..<8 {
      stub.setNext(.failed(code: .spawnFailed, message: "resolver rejected"))
    }

    try await store.startEngine(profileID: "chat")
    await waitFor { if case .failed = store.status { return true }; return false }
    store.stop()

    guard case .failed(let code, _) = store.status else {
      return XCTFail("expected convergence to .failed, got \(store.status)")
    }
    XCTAssertEqual(code, .spawnFailed)
  }

  /// `stop()` cancels an in-flight convergence so a late poll cannot respawn the
  /// on-demand helper after a quit teardown (#448 invariant preserved).
  func test_stop_cancelsConvergence() async throws {
    let (store, stub) = makeStore(initial: .stopped)
    for _ in 0..<50 { stub.setNext(.stopped) }  // never reaches .running
    try await store.startEngine(profileID: "chat")
    store.stop()
    let callsAfterStop = stub.calls
    await waitFor(50) { false }  // give any stray task a chance to poll
    XCTAssertLessThanOrEqual(stub.calls - callsAfterStop, 1,
                             "convergence must not keep polling after stop()")
  }
}
