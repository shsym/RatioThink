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

    func helperProtocolVersion() async throws -> Int {
      HelperProtocolCompatibility.currentVersion
    }

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
    // #459: capture the explicit per-start model override threaded through.
    private(set) var lastStartModelOverride: String?
    private var startResult: Result<Void, Error> = .success(())
    func setStartResult(_ result: Result<Void, Error>) {
      lock.withLock { startResult = result }
    }
    func startEngine(profileID: String, modelOverride: String?) async throws {
      let result: Result<Void, Error> = lock.withLock {
        startCalls += 1
        lastStartProfileID = profileID
        lastStartModelOverride = modelOverride
        return startResult
      }
      try result.get()
    }

    // Active-profile default-model changes need restart semantics that
    // differ from the generic "kick start" path above. Model reload must
    // not be decided from EngineStatusStore's cached mirror or swallow
    // `.alreadyRunning`.
    private(set) var restartCalls = 0
    private(set) var lastRestartProfileID: String?
    private(set) var lastRestartModelOverride: String?
    private var restartResult: Result<Void, Error> = .success(())
    func setRestartResult(_ result: Result<Void, Error>) {
      lock.withLock { restartResult = result }
    }
    func restartEngine(profileID: String, modelOverride: String?) async throws {
      let result: Result<Void, Error> = lock.withLock {
        restartCalls += 1
        lastRestartProfileID = profileID
        lastRestartModelOverride = modelOverride
        return restartResult
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
    XCTAssertNil(client.lastStartModelOverride,
                 "no override given → nil so the helper boots the profile default")
  }

  /// #459 repro 1: the explicit toolbar / model-list pick must reach the
  /// helper as `modelOverride` so a no-default profile boots the chosen
  /// model instead of failing with `has no default model`.
  func test_startEngine_forwards_explicit_modelOverride() async throws {
    let client = StubXPCClient()
    let store = EngineStatusStore(client: client)
    try await store.startEngine(profileID: "tree-of-thought",
                                modelOverride: "Org/New-GGUF/new.gguf")
    XCTAssertEqual(client.lastStartProfileID, "tree-of-thought")
    XCTAssertEqual(client.lastStartModelOverride, "Org/New-GGUF/new.gguf",
                   "the explicit pick must be threaded through to the helper start call")
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

  /// Same-profile idempotent attach is owned by the helper's
  /// `startOrAttach` boundary. If `.alreadyRunning` reaches the app, it is
  /// an incompatible start (different profile, stopping, etc.) and must
  /// surface to the caller instead of pretending the requested profile
  /// started.
  func test_startEngine_propagates_alreadyRunning_conflict() async {
    let client = StubXPCClient()
    client.setStartResult(.failure(
      EngineError(code: .alreadyRunning, message: "engine already starting")))
    let store = EngineStatusStore(client: client)
    do {
      try await store.startEngine(profileID: "chat")
      XCTFail("alreadyRunning from helper startEngine must surface as an incompatible start")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .alreadyRunning)
    } catch {
      XCTFail("unexpected: \(error)")
    }
    XCTAssertEqual(client.startCalls, 1)
  }

  func test_startEngine_propagates_alreadyRunning_when_current_status_is_different_profile() async {
    let client = StubXPCClient()
    client.setStartResult(.failure(
      EngineError(code: .alreadyRunning, message: "tree-of-thought already running")))
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 8123, profileID: "tree-of-thought")
    )
    do {
      try await store.startEngine(profileID: "chat")
      XCTFail("a different-profile alreadyRunning conflict must throw")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .alreadyRunning)
    } catch {
      XCTFail("unexpected: \(error)")
    }
    XCTAssertEqual(client.startCalls, 1)
    XCTAssertEqual(store.status, .running(port: 8123, profileID: "tree-of-thought"))
  }

  /// #422 F1: a resolver-stage start rejection re-throws AND does NOT move
  /// the status — the helper leaves it `.stopped` (only `.memoryRisk`
  /// publishes `.failed`). So the polled-status reducer can't surface it;
  /// the Local API on/off toggle MUST surface the throw itself, or the user
  /// gets a silent snap-back. Pins the contract `LocalAPIView.start()` relies
  /// on. (`.modelMissing` re-throw is covered by
  /// `test_startEngine_propagates_real_failure` above; this adds the
  /// status-unchanged half for `.profileMissing`.)
  func test_startEngine_profileMissing_rethrows_and_leaves_status_stopped() async {
    let client = StubXPCClient()
    client.setStartResult(.failure(
      EngineError(code: .profileMissing, message: "no such profile")))
    let store = EngineStatusStore(client: client, initialStatus: .stopped)
    do {
      try await store.startEngine(profileID: "ghost")
      XCTFail("a resolver-stage start rejection must re-throw so the toggle can surface it")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .profileMissing)
    } catch {
      XCTFail("unexpected: \(error)")
    }
    XCTAssertEqual(store.status, .stopped,
                   "start rejection must NOT change status — proves the poll channel can't surface it")
  }

  /// #422 F1: a rejected stop (e.g. `.killRejected`) re-throws AND leaves the
  /// engine `.running`, so the Local API toggle stays ON with no explanation
  /// unless `stop()` surfaces the thrown reason after the user-confirmed
  /// destructive action.
  func test_stopEngine_killRejected_rethrows_and_leaves_status_running() async {
    let client = StubXPCClient()
    client.setStopResult(.failure(
      EngineError(code: .killRejected, message: "pid still alive")))
    let store = EngineStatusStore(
      client: client, initialStatus: .running(port: 8123, profileID: "chat"))
    do {
      try await store.stopEngine()
      XCTFail("a rejected stop must re-throw so the toggle can surface it")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .killRejected)
    } catch {
      XCTFail("unexpected: \(error)")
    }
    XCTAssertEqual(store.status, .running(port: 8123, profileID: "chat"),
                   "a rejected stop must NOT change status — toggle stays on, so the view must explain why")
  }

  // MARK: - restartEngine (active profile default changed)

  func test_restartEngine_forwardsToAuthoritativeClientRestart() async throws {
    let client = StubXPCClient()
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 51234, profileID: "chat")
    )

    try await store.restartEngine(profileID: "chat")

    XCTAssertEqual(client.restartCalls, 1,
                   "active-profile model changes need the helper's authoritative restart contract")
    XCTAssertEqual(client.lastRestartProfileID, "chat")
    XCTAssertEqual(client.stopCalls, 0,
                   "app must not locally compose stop+start from a cached 1Hz status mirror")
    XCTAssertEqual(client.startCalls, 0,
                   "generic start swallows alreadyRunning; restart must not reuse that idempotent path")
  }

  func test_restartEngine_forwardsExplicitModelOverride() async throws {
    // #469: a running-engine model switch threads the explicit pick through
    // the restart so the rebuilt engine boots the chosen model.
    let client = StubXPCClient()
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 51234, profileID: "chat")
    )

    try await store.restartEngine(profileID: "chat", modelOverride: "Org/New-GGUF/new.gguf")

    XCTAssertEqual(client.restartCalls, 1)
    XCTAssertEqual(client.lastRestartModelOverride, "Org/New-GGUF/new.gguf",
                   "restartEngine must forward the explicit model override to the helper")
  }

  func test_restartEngine_defaultsToNilOverride() async throws {
    // The convenience restart (set-as-default / post-download) boots the
    // profile default — no override.
    let client = StubXPCClient()
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 51234, profileID: "chat")
    )

    try await store.restartEngine(profileID: "chat")

    XCTAssertNil(client.lastRestartModelOverride,
                 "the no-override restart convenience boots the profile default")
  }

  func test_restartEngine_slowButSuccessfulStopDoesNotTripAppSideStopTimeout() async throws {
    let client = StubXPCClient()
    client.setStopResult(.failure(
      AppXPCClientError.replyTimeout(selector: "stopEngine", timeout: 2.0)
    ))
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 51234, profileID: "chat")
    )

    try await store.restartEngine(profileID: "chat")

    XCTAssertEqual(client.stopCalls, 0,
                   "a normal slow helper stop must be owned by the restart selector's longer deadline, not app-side stopEngine's short timeout")
    XCTAssertEqual(client.startCalls, 0)
    XCTAssertEqual(client.restartCalls, 1)
  }

  func test_restartEngine_staleStoppedCacheAlreadyRunningDoesNotSilentlySucceed() async {
    let client = StubXPCClient()
    let staleRunning = EngineError(code: .alreadyRunning,
                                   message: "helper is already running despite stale app cache")
    client.setStartResult(.failure(staleRunning))
    client.setRestartResult(.failure(staleRunning))
    let store = EngineStatusStore(
      client: client,
      initialStatus: .stopped
    )

    do {
      try await store.restartEngine(profileID: "chat")
      XCTFail("restart must not report success when stale cached .stopped hides a live helper engine")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .alreadyRunning)
      XCTAssertEqual(client.restartCalls, 1,
                     "the helper-side restart selector owns real helper state")
      XCTAssertEqual(client.startCalls, 0,
                     "generic start would swallow .alreadyRunning and silently skip the rebuild")
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  /// #459 repro 2: a rebuild whose cold boot outlasts the App reply window
  /// is in flight, not a failed reload. `restartEngine` must swallow
  /// `.replyTimeout` so a slow large-model reload is never reported to the
  /// caller (ProfileEditor) as a reload failure; the status poll surfaces the
  /// real outcome.
  func test_restartEngine_swallows_reply_timeout_as_in_flight() async throws {
    let client = StubXPCClient()
    client.setRestartResult(.failure(
      AppXPCClientError.replyTimeout(selector: "restartEngine", timeout: 85.0)))
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 51234, profileID: "chat")
    )
    try await store.restartEngine(profileID: "chat")  // must NOT throw
    XCTAssertEqual(client.restartCalls, 1)
  }

  /// A real helper `EngineError` (resolver rejected, modelMissing, …) still
  /// propagates so ProfileEditor can surface the reason in its banner.
  func test_restartEngine_propagates_real_failure() async {
    let client = StubXPCClient()
    client.setRestartResult(.failure(
      EngineError(code: .modelMissing, message: "still missing")))
    let store = EngineStatusStore(
      client: client,
      initialStatus: .running(port: 51234, profileID: "chat")
    )
    do {
      try await store.restartEngine(profileID: "chat")
      XCTFail("a real restart failure must throw so the UI can surface the reason")
    } catch let e as EngineError {
      XCTAssertEqual(e.code, .modelMissing)
    } catch {
      XCTFail("unexpected: \(error)")
    }
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

  // MARK: - transport loss: anti-flap + escalation (#1 / #5a)

  /// #1 anti-flap: a brief transport blip (helper respawning on demand,
  /// or one slow `engineStatus` reply during a heavy load) must HOLD the
  /// last known status — not flap to a worse-looking state or surface a
  /// "Helper unreachable" fault — until the loss is SUSTAINED. A running
  /// engine stays `.running` (baseURL preserved) through sub-threshold
  /// failures, with no `lastError` churn.
  func test_transient_transport_loss_holds_last_running_status() async throws {
    let client = StubXPCClient()
    client.setNext(.running(port: 51234, profileID: "chat"))
    let store = EngineStatusStore(client: client, tierPolicy: StatusTierPolicy(tier1Polls: 2, tier2Polls: 3))

    _ = try await store.refresh()
    XCTAssertEqual(store.baseURL, URL(string: "http://127.0.0.1:51234"))

    // Two failed polls (< threshold of 3): held, calm.
    store._applyPollForTesting(next: nil, error: "NSXPCConnectionInterrupted")
    store._applyPollForTesting(next: nil, error: "NSXPCConnectionInterrupted")

    XCTAssertEqual(store.status, .running(port: 51234, profileID: "chat"),
                   "a sub-threshold transport blip must hold the last status, not flap")
    XCTAssertEqual(store.baseURL, URL(string: "http://127.0.0.1:51234"))
    XCTAssertNil(store.lastError,
                 "a transient blip must NOT surface a user-facing helper-unreachable fault (#1)")
  }

  /// #5a: SUSTAINED transport loss escalates to a real, recoverable
  /// `.failed(.engineGone)` — killing the old "stuck at `.starting`
  /// forever" behavior — so the indicator/banner/chat/gate all see an
  /// error with a Retry/Restart affordance. baseURL is cleared.
  func test_sustained_transport_loss_escalates_to_engineGone() async throws {
    let client = StubXPCClient()
    client.setNext(.running(port: 51234, profileID: "chat"))
    let store = EngineStatusStore(client: client, tierPolicy: StatusTierPolicy(tier1Polls: 2, tier2Polls: 3))
    _ = try await store.refresh()

    for _ in 0..<3 {
      store._applyPollForTesting(next: nil, error: "NSXPCConnectionInvalid")
    }

    guard case .failed(.engineGone, let message) = store.status else {
      return XCTFail("sustained transport loss must escalate to .failed(.engineGone); got \(store.status)")
    }
    XCTAssertNil(store.baseURL, "engineGone must clear the stale baseURL")
    XCTAssertTrue(message.contains("Restart Engine") || message.localizedCaseInsensitiveContains("reach"),
                  "message must read as a recoverable transport error; got \(message)")
    // requireBaseURL routes engineGone so the chat-send recovery path fires.
    XCTAssertThrowsError(try store.requireBaseURL()) { error in
      guard case HTTPEngineError.engineGone = error else {
        return XCTFail("expected .engineGone, got \(error)")
      }
    }
  }

  /// The escalation is "deaths without recovery": one successful poll
  /// resets the counter, so an intermittent helper never escalates.
  func test_successful_poll_resets_transport_failure_counter() async throws {
    let client = StubXPCClient()
    let store = EngineStatusStore(client: client, tierPolicy: StatusTierPolicy(tier1Polls: 2, tier2Polls: 3))

    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    store._applyPollForTesting(next: nil, error: "blip")
    store._applyPollForTesting(next: nil, error: "blip")
    // Recovery resets the counter…
    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    // …so two more blips still do NOT escalate.
    store._applyPollForTesting(next: nil, error: "blip")
    store._applyPollForTesting(next: nil, error: "blip")

    XCTAssertEqual(store.status, .running(port: 8080, profileID: "chat"),
                   "a successful poll must reset the failure counter so an intermittent helper never escalates")
  }

  /// #1: `startingSince` is stamped on entry to `.starting` and cleared
  /// on any other state, so the indicator can render a live "Starting…
  /// (Ns)" elapsed counter. Published only on transitions (never per poll).
  func test_startingSince_tracks_starting_transitions() async throws {
    let fixed = Date(timeIntervalSince1970: 1_000_000)
    let client = StubXPCClient()
    let store = EngineStatusStore(client: client, now: { fixed })

    // Initial status is `.starting` → stamped at init.
    XCTAssertEqual(store.startingSince, fixed)

    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    XCTAssertNil(store.startingSince, "running clears startingSince")

    store._applyPollForTesting(next: .starting, error: nil)
    XCTAssertEqual(store.startingSince, fixed, "re-entering starting re-stamps the instant")

    store._applyPollForTesting(next: .stopped, error: nil)
    XCTAssertNil(store.startingSince, "a non-starting state clears startingSince")
  }

  // MARK: - failed engine

  func test_failed_status_surfaces_in_detail() async throws {
    let client = StubXPCClient()
    client.setNext(.failed(code: .spawnFailed, message: "fork ENOENT"))
    // initialStatus `.running` ⇒ wasEverRunning, so a post-run `.spawnFailed`
    // surfaces at once. (The #2 first-load hold defers a transient failure
    // ONLY during the very first load — covered by its own tests.)
    let store = EngineStatusStore(client: client, initialStatus: .running(port: 8080, profileID: "chat"))
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

  // MARK: - #2 first-load transient-failure hold

  /// A momentary explicit `.spawnFailed` during a FIRST load (never run,
  /// still starting) is held as `.starting` and never surfaces if the load
  /// then succeeds — the #2 "no red flash on a slow load" fix.
  func test_first_load_holds_transient_spawnFailed_until_running() {
    let store = EngineStatusStore(client: StubXPCClient(),
      tierPolicy: StatusTierPolicy(tier1Polls: 2, tier2Polls: 5, firstLoadFailureGracePolls: 3))
    store._applyPollForTesting(next: .failed(code: .spawnFailed, message: "engine exited early"), error: nil)
    store._applyPollForTesting(next: .failed(code: .spawnFailed, message: "engine exited early"), error: nil)
    XCTAssertEqual(store.status, .starting, "a transient first-load .spawnFailed must read as Starting…, not error")
    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    XCTAssertEqual(store.status, .running(port: 8080, profileID: "chat"))
    XCTAssertTrue(store.wasEverRunning)
  }

  /// A genuinely persistent first-load failure still surfaces after the grace.
  func test_first_load_surfaces_persistent_spawnFailed_after_grace() {
    let store = EngineStatusStore(client: StubXPCClient(),
      tierPolicy: StatusTierPolicy(tier1Polls: 2, tier2Polls: 5, firstLoadFailureGracePolls: 3))
    for _ in 0..<3 {
      store._applyPollForTesting(next: .failed(code: .spawnFailed, message: "real spawn failure"), error: nil)
    }
    guard case .failed(.spawnFailed, _) = store.status else {
      return XCTFail("a persistent .spawnFailed must surface after the grace; got \(store.status)")
    }
  }

  /// Once the engine has run, a `.spawnFailed` is a real failure — surfaced
  /// immediately, never held (the hold is first-load only).
  func test_hold_does_not_apply_once_engine_has_run() {
    let store = EngineStatusStore(client: StubXPCClient(),
      tierPolicy: StatusTierPolicy(tier1Polls: 2, tier2Polls: 5, firstLoadFailureGracePolls: 3))
    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    XCTAssertTrue(store.wasEverRunning)
    store._applyPollForTesting(next: .failed(code: .spawnFailed, message: "died"), error: nil)
    guard case .failed(.spawnFailed, _) = store.status else {
      return XCTFail("post-run .spawnFailed must not be held; got \(store.status)")
    }
  }

  /// The engine-axis recovery count the banner tiers off: increments on
  /// consecutive `.failed(.engineGone)`, resets on any other status.
  func test_engineGonePolls_counts_consecutive_engineGone_and_resets() {
    let store = EngineStatusStore(client: StubXPCClient())
    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    XCTAssertEqual(store.engineGonePolls, 0)
    store._applyPollForTesting(next: .failed(code: .engineGone, message: "exit 1"), error: nil)
    store._applyPollForTesting(next: .failed(code: .engineGone, message: "exit 1"), error: nil)
    XCTAssertEqual(store.engineGonePolls, 2)
    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    XCTAssertEqual(store.engineGonePolls, 0)
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
