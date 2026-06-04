import XCTest
import Foundation
@testable import RatioThinkCore

/// Unit coverage for `EngineStatusStore` — the @MainActor mirror of
/// the helper's `engineStatus()` selector. Tests drive transitions
/// through a `StubXPCClient` so we never spin up a real
/// `NSXPCConnection`; the cross-process integration leg lives in
/// `EngineStatusStoreIntegrationTests` (CLIScenarioTests target,
/// anonymous listener).
@MainActor
final class EngineStatusStoreTests: XCTestCase {

  // MARK: - stub

  /// `AppXPCClient` stub that hands back whatever the test queued via
  /// `setNext(...)`. Calls `record(...)` per invocation so tests can
  /// assert the poll cadence without relying on `pollCount` alone.
  final class StubXPCClient: AppXPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<EngineStatus, Error>] = []
    private(set) var calls = 0

    func setNext(_ result: Result<EngineStatus, Error>) {
      lock.withLock { queue.append(result) }
    }

    func setNext(_ status: EngineStatus) { setNext(.success(status)) }
    func setNext(_ error: Error) { setNext(.failure(error)) }

    func engineStatus() async throws -> EngineStatus {
      let result: Result<EngineStatus, Error> = lock.withLock {
        calls += 1
        if queue.isEmpty {
          // No queued reply → behave like the helper before it
          // answers: simulate a transient unreachable peer so the
          // store stays on its initial `.starting` placeholder.
          return .failure(AppXPCClientError.proxyError(
            NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
          ))
        }
        return queue.removeFirst()
      }
      return try result.get()
    }

    //  Unload: capture stopEngine calls + let tests inject a result.
    private(set) var stopCalls = 0
    private var stopResult: Result<Void, Error> = .success(())
    func setStopResult(_ result: Result<Void, Error>) {
      lock.withLock { stopResult = result }
    }
    func stopEngine() async throws {
      let result: Result<Void, Error> = lock.withLock {
        stopCalls += 1
        return stopResult
      }
      try result.get()
    }

    // #326: capture startEngine calls + let tests inject a result.
    private(set) var startCalls = 0
    private(set) var lastStartProfileID: String?
    private var startResult: Result<Void, Error> = .success(())
    func setStartResult(_ result: Result<Void, Error>) {
      lock.withLock { startResult = result }
    }
    func startEngine(profileID: String) async throws {
      let result: Result<Void, Error> = lock.withLock {
        startCalls += 1
        lastStartProfileID = profileID
        return startResult
      }
      try result.get()
    }
  }

  // MARK: -  Unload

  func test_stopEngine_forwards_to_client() async throws {
    let client = StubXPCClient()
    let store = EngineStatusStore(client: client)
    try await store.stopEngine()
    XCTAssertEqual(client.stopCalls, 1, "Unload must forward stopEngine to the helper XPC client")
  }

  func test_stopEngine_propagates_rejection() async {
    let client = StubXPCClient()
    client.setStopResult(.failure(AppXPCClientError.proxyTypeMismatch))
    let store = EngineStatusStore(client: client)
    do {
      try await store.stopEngine()
      XCTFail("a rejected stop must throw so the caller keeps resident-model state")
    } catch {
      // expected
    }
  }

  // MARK: - startEngine (#326 fresh-install recovery)

  func test_startEngine_forwards_profileID_to_client() async throws {
    let client = StubXPCClient()
    let store = EngineStatusStore(client: client)
    try await store.startEngine(profileID: "chat")
    XCTAssertEqual(client.startCalls, 1,
                   "startEngine must forward to the helper XPC client")
    XCTAssertEqual(client.lastStartProfileID, "chat")
  }

  func test_startEngine_propagates_real_failure() async {
    let client = StubXPCClient()
    client.setStartResult(.failure(
      EngineError(code: .modelMissing, message: "still missing")))
    let store = EngineStatusStore(client: client)
    do {
      try await store.startEngine(profileID: "chat")
      XCTFail("a real start failure must throw so the UI can surface the reason")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .modelMissing)
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  /// The helper only replies to `startEngine` after the launch
  /// handshake (which includes the model load at engine boot); a slow
  /// start trips the App-side reply timeout. That is NOT a failure —
  /// the start is in flight and the status poll surfaces the real
  /// outcome — so `startEngine` swallows `.replyTimeout` and returns.
  func test_startEngine_swallows_reply_timeout_as_in_flight() async throws {
    let client = StubXPCClient()
    client.setStartResult(.failure(
      AppXPCClientError.replyTimeout(selector: "startEngine", timeout: 2.0)))
    let store = EngineStatusStore(client: client)
    try await store.startEngine(profileID: "chat")  // must NOT throw
    XCTAssertEqual(client.startCalls, 1)
  }

  /// A concurrent start finds the engine already starting/running and is
  /// rejected `.alreadyRunning`. For a "kick the start" caller that is
  /// the desired end state — #326's two recovery surfaces can both fire
  /// `startEngine` on the same completed download, and the second must
  /// NOT surface a user-facing error. Idempotent: swallow it.
  func test_startEngine_swallows_alreadyRunning_as_idempotent() async throws {
    let client = StubXPCClient()
    client.setStartResult(.failure(
      EngineError(code: .alreadyRunning, message: "engine already starting")))
    let store = EngineStatusStore(client: client)
    try await store.startEngine(profileID: "chat")  // must NOT throw
    XCTAssertEqual(client.startCalls, 1)
  }

  // MARK: - initial state

  func test_initial_status_is_starting_until_first_poll() {
    let store = EngineStatusStore(client: StubXPCClient())
    XCTAssertEqual(store.status, .starting)
    XCTAssertNil(store.baseURL)
    XCTAssertNil(store.lastError)
    XCTAssertEqual(store.pollCount, 0)
  }

  func test_initial_status_override_is_respected() {
    let store = EngineStatusStore(client: StubXPCClient(), initialStatus: .stopped)
    XCTAssertEqual(store.status, .stopped)
  }

  // MARK: - refresh

  func test_refresh_publishes_running_and_exposes_baseURL() async throws {
    let client = StubXPCClient()
    client.setNext(.running(port: 51234, profileID: "chat"))
    let store = EngineStatusStore(client: client)

    let status = try await store.refresh()
    XCTAssertEqual(status, .running(port: 51234, profileID: "chat"))
    XCTAssertEqual(store.status, .running(port: 51234, profileID: "chat"))
    XCTAssertEqual(store.baseURL, URL(string: "http://127.0.0.1:51234"))
    XCTAssertNil(store.lastError)
    XCTAssertEqual(store.pollCount, 1)
  }

  func test_refresh_throws_engineNotReady_unless_running() {
    let store = EngineStatusStore(client: StubXPCClient(), initialStatus: .stopped)
    XCTAssertThrowsError(try store.requireBaseURL()) { error in
      guard case HTTPEngineError.engineNotReady(let detail) = error else {
        XCTFail("expected .engineNotReady, got \(error)")
        return
      }
      XCTAssertTrue(detail.contains("Engine stopped"),
                    "detail should include human status; got \(detail)")
    }
  }

  func test_requireBaseURL_returns_url_when_running() async throws {
    let client = StubXPCClient()
    client.setNext(.running(port: 8080, profileID: "chat"))
    let store = EngineStatusStore(client: client)
    _ = try await store.refresh()
    let url = try store.requireBaseURL()
    XCTAssertEqual(url, URL(string: "http://127.0.0.1:8080"))
  }

  // MARK: - status transitions

  func test_starting_to_running_to_stopped_round_trip() async throws {
    let client = StubXPCClient()
    let store = EngineStatusStore(client: client)

    client.setNext(.starting)
    let s1 = try await store.refresh()
    XCTAssertEqual(s1, .starting)
    XCTAssertNil(store.baseURL)
    XCTAssertEqual(store.statusDetail, "Engine starting…")

    client.setNext(.running(port: 49152, profileID: "chat"))
    let s2 = try await store.refresh()
    XCTAssertEqual(s2, .running(port: 49152, profileID: "chat"))
    XCTAssertEqual(store.baseURL, URL(string: "http://127.0.0.1:49152"))

    client.setNext(.stopped)
    let s3 = try await store.refresh()
    XCTAssertEqual(s3, .stopped)
    XCTAssertNil(store.baseURL)
  }

  // MARK: - failures

  func test_refresh_propagates_xpc_failures() async {
    struct Boom: Error {}
    let client = StubXPCClient()
    client.setNext(Boom())
    let store = EngineStatusStore(client: client)

    do {
      _ = try await store.refresh()
      XCTFail("expected throw")
    } catch is Boom {
      // expected
    } catch {
      XCTFail("unexpected: \(error)")
    }
    // refresh() left status unchanged AND did not record an error
    // (only the poll loop records errors on the published store).
    XCTAssertEqual(store.status, .starting)
  }

  func test_poll_failure_after_running_clears_stale_baseURL_and_reports_helper_unreachable() async throws {
    let client = StubXPCClient()
    client.setNext(.running(port: 51234, profileID: "chat"))
    let store = EngineStatusStore(
      client: client,
      pollInterval: 0.01
    )

    _ = try await store.refresh()
    XCTAssertEqual(store.baseURL, URL(string: "http://127.0.0.1:51234"))

    store.start()
    defer { store.stop() }

    try await waitUntil("poll failure is recorded") {
      store.pollCount >= 2 && store.lastError != nil
    }

    XCTAssertEqual(store.status, .starting)
    XCTAssertNil(store.baseURL)
    XCTAssertNotNil(store.lastError)
    XCTAssertTrue(
      store.statusDetail.contains("Helper unreachable:"),
      "statusDetail should explain helper reachability; got \(store.statusDetail)"
    )
  }

  // MARK: - failed engine

  func test_failed_status_surfaces_in_detail() async throws {
    let client = StubXPCClient()
    client.setNext(.failed(code: .spawnFailed, message: "fork ENOENT"))
    let store = EngineStatusStore(client: client)
    _ = try await store.refresh()
    XCTAssertEqual(store.status, .failed(code: .spawnFailed, message: "fork ENOENT"))
    XCTAssertTrue(store.statusDetail.contains("spawnFailed"),
                  "got \(store.statusDetail)")
    XCTAssertTrue(store.statusDetail.contains("fork ENOENT"))
  }

  func test_memoryRisk_failed_status_surfaces_actionable_copy() async throws {
    let client = StubXPCClient()
    client.setNext(.failed(
      code: .memoryRisk,
      message: "memory risk: model is 9.0 GB; choose a smaller model"
    ))
    let store = EngineStatusStore(client: client)

    _ = try await store.refresh()

    XCTAssertEqual(store.status, .failed(
      code: .memoryRisk,
      message: "memory risk: model is 9.0 GB; choose a smaller model"
    ))
    XCTAssertTrue(store.statusDetail.contains("Memory risk"),
                  "got \(store.statusDetail)")
    XCTAssertTrue(store.statusDetail.contains("choose a smaller model"),
                  "got \(store.statusDetail)")
  }

  // MARK: - #412 review F1: recovery wait bounded by the ladder outcome

  func test_waitUntilRunning_earlyExits_when_helper_ladder_gaveUp() async {
    // When the App's helper-restart ladder reports `.unreachable` (gave up),
    // the recovery wait must return false IMMEDIATELY rather than burn the
    // full (helper-sized) budget — so the chat turn surfaces in lockstep with
    // the escalation banner instead of spinning for tens of seconds.
    let store = EngineStatusStore(client: StubXPCClient(), initialStatus: .starting)
    store.helperHealthProvider = { .unreachable }
    let start = Date()
    let recovered = await store.waitUntilRunning(timeout: 10)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertFalse(recovered, "a ladder that gave up must not report recovery")
    XCTAssertLessThan(elapsed, 1.0, "must early-exit on .unreachable, not wait the full 10s budget")
  }

  func test_waitUntilRunning_keepsWaiting_while_ladder_still_repairing() async {
    // While the ladder is still working (not terminal), the wait honors its
    // budget — it must NOT bail early on a non-terminal helper state.
    let store = EngineStatusStore(client: StubXPCClient(), initialStatus: .starting)
    store.helperHealthProvider = { .repairing(attempt: 1) }
    let start = Date()
    let recovered = await store.waitUntilRunning(timeout: 0.3)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertFalse(recovered)
    XCTAssertGreaterThanOrEqual(elapsed, 0.25, "a still-repairing ladder must not trip the give-up early-exit")
  }

  func test_waitUntilRunning_noProvider_waits_full_budget() async {
    // Backward compat: with no helper-health source (engine-gone path / tests)
    // `helperRecoveryGaveUp` is false and the wait runs to its timeout.
    let store = EngineStatusStore(client: StubXPCClient(), initialStatus: .starting)
    let start = Date()
    let recovered = await store.waitUntilRunning(timeout: 0.3)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertFalse(recovered)
    XCTAssertGreaterThanOrEqual(elapsed, 0.25, "no give-up signal → honor the timeout")
  }

  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1.0,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
  }
}
