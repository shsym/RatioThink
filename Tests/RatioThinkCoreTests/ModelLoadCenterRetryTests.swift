import XCTest
@testable import RatioThinkCore

/// #396: a failed model load must offer a recovery action, not just a
/// dead-end "Dismiss". `retryLast()` re-runs the most recent load with
/// the same stream factory so the popover's Retry button can recover
/// without the caller re-threading the engine + model id.
@MainActor
final class ModelLoadCenterRetryTests: XCTestCase {

  private enum TestError: Error { case boom }

  /// Invocation counter for the stream factory — `@unchecked Sendable`
  /// behind a lock because the factory closure is `@Sendable`.
  private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
  }

  func test_retryLast_reinvokes_factory_and_recovers_after_failure() async {
    let center = ModelLoadCenter()
    let counter = AttemptCounter()
    // Attempt 1 fails; the retry (attempt 2) succeeds — proving the
    // factory is re-invoked, not just the prior terminal cleared.
    let factory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error> = {
      let attempt = counter.next()
      return AsyncThrowingStream { continuation in
        if attempt == 1 {
          continuation.finish(throwing: TestError.boom)
        } else {
          continuation.yield(.ready)
          continuation.finish()
        }
      }
    }

    center.load(modelID: "m1", streamFactory: factory)
    await waitUntil(timeout: 1.0) {
      if case .failed = center.state { return true }
      return false
    }
    XCTAssertEqual(counter.count, 1)

    center.retryLast()
    await waitUntil(timeout: 1.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(counter.count, 2, "retryLast must re-invoke the stored factory")
    XCTAssertEqual(center.state, .ready(modelID: "m1"))
    XCTAssertEqual(center.residentModelID, "m1")
  }

  func test_retryLast_is_noop_without_a_prior_load() {
    let center = ModelLoadCenter()
    center.retryLast()
    XCTAssertEqual(center.state, .idle, "no prior load → nothing to retry")
    XCTAssertFalse(center.isLoading)
  }

  func test_retryLast_after_unload_does_not_reload() {
    // Explicit Unload is the user saying "stop"; a later retry must not
    // resurrect the unloaded model.
    let center = ModelLoadCenter()
    center.load(modelID: "m1") {
      AsyncThrowingStream { $0.finish(throwing: TestError.boom) }
    }
    center.markUnloaded()
    center.retryLast()
    XCTAssertEqual(center.state, .idle)
    XCTAssertNil(center.residentModelID)
  }

  private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
