import XCTest
import SwiftData
import os
@testable import RatioThinkCore

/// D2 — integration coverage of the engine-death recovery
/// path, tier "in-process Swift mocks". Wires real `PieEngineHost`
/// (with real `RelaunchPolicy` + injected `Relauncher`), real
/// `EngineStatusStore` (driven by a stub `AppXPCClient`), and real
/// `ChatSendController` (driven by canned `EngineClient` stream
/// fakes) into the same call graph the App+Helper actually run, so
/// the auto-relaunch + chat-retry handshake is exercised end-to-end
/// at the Swift layer.
///
/// Coverage trade-off (per // absorbed onto PR ):
/// these tests prove SWIFT-SIDE autoheal control flow against mocked
/// `EngineClient` + mocked `AppXPCClient` + injected `Relauncher`.
/// They do NOT prove real subprocess race, real pie binary crash
/// modes, OS-level WS socket teardown under SIGKILL, or the
/// real-wire `PieControlClient` handshake — those live in the
/// real-binary opt-in tier (`PIE_RUN_REAL_ENGINE_TESTS=1`, sibling
/// suite) and the scripted operator harness under `scripts/`.
///
/// Cases:
///   1. Happy-path auto-recovery (engine dies → ladder fires → host
///      back to .running → chat retry succeeds against fresh engine).
///   2. Ladder exhaust at maxAttempts=2 (REJECT_NEW_SPAWNS-style
///      session: every spawn dies; host settles .failed(.engineGone)
///      after the cap).
///   3. Slow-flap window: 2 deaths inside `window` exhausts; the
///      same number of deaths spread across >window resets, so a
///      fresh death still gets a fresh attempt.
///   4. User stop() during the ladder backoff cancels the pending
///      attempt — user intent wins.
///   5. Auto + user-Resume share `HelperResumeAction.run` funnel —
///      both paths reach `engineHost.start` with the same LaunchSpec.
///   6. G4-via-first-SSE: after the retry, the chat stream actually
///      emits its first content frame; that frame is the engine +
///      model "can serve generation" proof, distinct from inferlet
///      `/healthz` (which only proves the WASM is up).
@available(macOS 14, *)
@MainActor
final class EngineDeathRecoveryTests: XCTestCase {

  // MARK: - 1. Happy-path auto-recovery

  func test_engineGone_then_autoRelaunch_brings_host_back_to_running() async throws {
    // Sequence:
    //   start → .running → liveness reports .gone once → host moves
    //   to .failed(.engineGone) → ladder schedules a relauncher call
    //   after backoff → relauncher invokes host.start(spec) → fresh
    //   session returns alive → host re-enters .running.
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let launcher: PieEngineHost.LauncherCall = { _ in
      let n = launchCount.withLock { count -> Int in count += 1; return count }
      if n == 1 {
        return (port: EnginePort(60001), session: OneShotDeathSession())
      }
      return (port: EnginePort(60002), session: HealthySession())
    }
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 5,
      backoffSchedule: [0.02]
    )
    let box = WeakHostBox()
    let spec = makeSpec()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 0.02,
      livenessFailureThreshold: 1,
      relaunchPolicy: policy,
      relauncher: relauncher
    )
    box.host = host

    let gone = expectation(description: ".failed(.engineGone)")
    let secondRunning = expectation(description: "second .running after auto-relaunch")
    var hitGone = false
    var runningCount = 0
    let token = host.observe { status, _ in
      if case .running = status {
        runningCount += 1
        if runningCount == 2 { secondRunning.fulfill() }
      }
      if case .failed(.engineGone, _) = status, !hitGone {
        hitGone = true; gone.fulfill()
      }
    }
    _ = host.start(spec)
    await fulfillment(of: [gone, secondRunning], timeout: 3, enforceOrder: true)
    XCTAssertEqual(launchCount.withLock { $0 }, 2)
    token.cancel()
    host.stop()
  }

  // MARK: - 2. Ladder exhaust

  func test_repeated_engineGone_exhausts_ladder_at_maxAttempts() async throws {
    // Every spawn returns a death-once session: initial death plus N
    // auto-relaunch deaths. After maxAttempts auto-relaunches, the
    // ladder gives up and the host stays .failed(.engineGone).
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let launcher: PieEngineHost.LauncherCall = { _ in
      let n = launchCount.withLock { c -> Int in c += 1; return c }
      return (port: EnginePort(60010 + UInt16(n)), session: OneShotDeathSession())
    }
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 10,
      backoffSchedule: [0.02, 0.02]
    )
    let box = WeakHostBox()
    let spec = makeSpec()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 0.02,
      livenessFailureThreshold: 1,
      relaunchPolicy: policy,
      relauncher: relauncher
    )
    box.host = host

    let exhausted = expectation(description: "third .failed (ladder exhausted)")
    var failedCount = 0
    let token = host.observe { status, _ in
      if case .failed(.engineGone, _) = status {
        failedCount += 1
        if failedCount == 3 { exhausted.fulfill() }
      }
    }
    _ = host.start(spec)
    await fulfillment(of: [exhausted], timeout: 5)
    // Drain post-exhaust to confirm no further launches fire.
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(launchCount.withLock { $0 }, 3,
                   "1 initial + 2 auto-relaunches; ladder must not fire a 4th")
    token.cancel()
    host.stop()
  }

  // MARK: - 3. Slow-flap window resets

  func test_slowFlap_outsideWindow_rearms_ladder() async throws {
    // Fully deterministic, zero wall-clock waits. The death/relaunch cycle
    // runs through an injected immediate `sleepFor` (the liveness-poll
    // cadence and the backoff carry no real-time duration), and the
    // sliding-window prune/re-arm is driven by the injected `MutableClock`,
    // advanced by hand. Cycle progress is awaited on the host's published
    // status stream — not a wall-clock `fulfillment(timeout:)` — so the
    // prune read and the re-arm relaunch can no longer race the live
    // liveness/backoff timers (the historical flake: under CI load the real
    // 0.02s poll / 0.01s backoff slipped, and the post-advance prune read +
    // the re-arm both lost the race).
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let launcher: PieEngineHost.LauncherCall = { _ in
      let n = launchCount.withLock { c -> Int in c += 1; return c }
      return (port: EnginePort(60030 + UInt16(n)), session: OneShotDeathSession())
    }
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000_000))
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 0.25,
      // Backoff is inert under the immediate `sleepFor` below; its value
      // only has to be >= 0. The injected clock — frozen here — is what
      // keeps both deaths inside the window so the ladder exhausts.
      backoffSchedule: [0],
      // Disable the healthy-uptime re-arm: under the immediate `sleepFor`
      // its (default 30s) timer would fire instantly on every `.running`
      // and clear the attempt set, so the ladder could never exhaust. This
      // test exercises the *window* prune re-arm, not the uptime re-arm, so
      // turning the uptime path off keeps it focused and deterministic.
      healthyUptimeThreshold: 0
    )
    let box = WeakHostBox()
    let spec = makeSpec()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    let host = PieEngineHost(
      launcher: launcher,
      // > 0 so the liveness monitor is enabled; the duration is inert
      // because `sleepFor` returns immediately.
      livenessInterval: 1,
      livenessFailureThreshold: 1,
      relaunchPolicy: policy,
      relauncher: relauncher,
      clock: { clock.now() },
      sleepFor: { _ in }  // immediate: no real liveness-poll or backoff wait
    )
    box.host = host

    // Await the host's transitions on a stream (one iterator reused across
    // both phases) instead of a timeout-bounded expectation.
    let (statuses, statusCont) = AsyncStream<EngineStatus>.makeStream()
    let token = host.observe { status, _ in statusCont.yield(status) }
    var statusIter = statuses.makeAsyncIterator()

    // Phase A — two deaths inside the (frozen) window exhaust the ladder:
    // the initial death plus two auto-relaunch deaths = 3 .failed(.engineGone).
    _ = host.start(spec)
    var failedCount = 0
    while let status = await statusIter.next() {
      if case .failed(.engineGone, _) = status {
        failedCount += 1
        if failedCount == 3 { break }
      }
    }
    XCTAssertEqual(launchCount.withLock { $0 }, 3,
                   "1 initial + 2 auto-relaunches inside the window before exhaustion")

    // Phase B — inside the window the two exhausted attempts still count
    // against the cap; advancing the injected clock past the window prunes
    // them. Checking 2 -> 0 (not a static 0) proves the window prune
    // actually transitions.
    XCTAssertEqual(host.autoRelaunchAttemptsForTesting, 2,
                   "inside the window the two exhausted attempts still count against the cap")
    clock.advance(by: policy.window + 0.1)
    XCTAssertEqual(host.autoRelaunchAttemptsForTesting, 0,
                   "after the injected clock passes the window the prune clears the attempt set")

    // Phase C — a fresh start outside the (now-pruned) window must re-arm
    // the ladder. The user start is one launch and the re-armed
    // auto-relaunch is a second, so reaching preLaunch+2 can only happen if
    // the ladder actually fired again.
    let preLaunchCount = launchCount.withLock { $0 }
    _ = host.start(spec)  // user-driven restart, outside the window
    while await statusIter.next() != nil {
      if launchCount.withLock({ $0 }) >= preLaunchCount + 2 { break }
    }
    XCTAssertGreaterThanOrEqual(launchCount.withLock { $0 } - preLaunchCount, 2,
                                "post-window: a fresh user start plus at least one auto-relaunch")

    token.cancel()
    statusCont.finish()
    host.stop()
  }

  // MARK: - 4. User stop cancels pending ladder

  func test_user_stop_during_backoff_cancels_pending_auto_relaunch() async throws {
    // User clicks Pause during the ladder's backoff sleep. The
    // pending Task must NOT fire a launch after stop() — user
    // intent always wins over auto recovery.
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let launcher: PieEngineHost.LauncherCall = { _ in
      launchCount.withLock { $0 += 1 }
      return (port: EnginePort(60050), session: OneShotDeathSession())
    }
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 5,
      backoffSchedule: [0.4] // long enough that the test can stop() first
    )
    let box = WeakHostBox()
    let spec = makeSpec()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 0.02,
      livenessFailureThreshold: 1,
      relaunchPolicy: policy,
      relauncher: relauncher
    )
    box.host = host

    let gone = expectation(description: ".failed(.engineGone)")
    var hit = false
    let token = host.observe { status, _ in
      if case .failed(.engineGone, _) = status, !hit { hit = true; gone.fulfill() }
    }
    _ = host.start(spec)
    await fulfillment(of: [gone], timeout: 2)
    host.stop() // mid-backoff
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(launchCount.withLock { $0 }, 1,
                   "user stop() must cancel the pending ladder Task before it fires")
    token.cancel()
  }

  // MARK: - 4b. User Pause out of engineGone clears the attempt ladder (#394)

  func test_userPause_outOfEngineGone_clearsAutoRelaunchAttempts() async throws {
    // #394: a user Pause out of `.failed(.engineGone)` is an explicit
    // "off". The recorded death-attempt history must reset so a later
    // Resume starts the slow-flap ladder fresh — otherwise a
    // Pause → Resume → quick-death prematurely exhausts the cap, since the
    // healthy-uptime re-arm needs `healthyUptimeThreshold` of sustained
    // `.running` the paused user never reaches. `stop()` already cancels
    // the pending backoff Task (case 4); this pins that it ALSO clears the
    // attempt timestamps.
    let launcher: PieEngineHost.LauncherCall = { _ in
      (port: EnginePort(60095), session: OneShotDeathSession())
    }
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 60,
      backoffSchedule: [0.4] // long enough that the Pause lands mid-backoff
    )
    let box = WeakHostBox()
    let spec = makeSpec()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in _ = box.host?.start(spec) }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 0.02,
      livenessFailureThreshold: 1,
      relaunchPolicy: policy,
      relauncher: relauncher
    )
    box.host = host

    let gone = expectation(description: ".failed(.engineGone)")
    var hit = false
    let token = host.observe { status, _ in
      if case .failed(.engineGone, _) = status, !hit { hit = true; gone.fulfill() }
    }
    _ = host.start(spec)
    await fulfillment(of: [gone], timeout: 2)
    // The death recorded one ladder attempt: scheduleAutoRelaunchIfAllowed
    // appends `now` before it sleeps the backoff.
    XCTAssertEqual(host.autoRelaunchAttemptsForTesting, 1,
                   "engine death must record one auto-relaunch attempt before the backoff fires")

    host.stop() // user Pause out of .failed(.engineGone), mid-backoff
    try await waitUntil("host returns to .stopped after user pause") {
      if case .stopped = host.status { return true }
      return false
    }
    XCTAssertEqual(host.autoRelaunchAttemptsForTesting, 0,
                   "#394: a user Pause out of engineGone must clear the recorded attempts so a later Resume starts the cap fresh")
    token.cancel()
  }

  // MARK: - 5. Auto + user-Resume share HelperResumeAction.run funnel

  func test_autoRelaunch_and_userResume_share_HelperResumeAction_funnel() async throws {
    // The auto path (relauncher closure from PR ) and the menu-bar
    // Pause/Resume path (HelperResumeAction.run from togglePauseResume)
    // must produce the same LaunchSpec going into engineHost.start so
    // a future profile / resolver change can't accidentally diverge
    // the two paths.
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pie_test_\(UUID().uuidString.prefix(8))", isDirectory: true)
    let profilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    let activeMarker = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Minimal profiles tree so ProfileStore.start() succeeds:
    //   <tempDir>/profiles/chat.toml         — profile body
    //   <tempDir>/active-profile             — marker (one line: profile id)
    // Marker path mirrors `ProfileStore.init`'s default
    // (`directory.deletingLastPathComponent()/active-profile`).
    let toml = #"""
    name = "chat"
    """#
    try toml.write(to: profilesDir.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    try "chat\n".write(to: activeMarker, atomically: true, encoding: .utf8)

    let store = ProfileStore(directory: profilesDir)
    try store.start()
    XCTAssertEqual(store.activeProfileID, "chat",
                   "test fixture must seed the active-profile marker so HelperResumeAction can resolve it")

    // Resolver hands back a synthesizable LaunchSpec we can compare
    // across the auto + user-Resume paths.
    let canonicalSpec = makeSpec(profileID: "chat")
    let resolverInvocations = OSAllocatedUnfairLock<[String]>(initialState: [])
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id in
      resolverInvocations.withLock { $0.append(id) }
      return .success(canonicalSpec)
    }

    // Capture every LaunchSpec the host actually receives via start().
    let startInvocations = OSAllocatedUnfairLock<[String]>(initialState: [])
    let launcher: PieEngineHost.LauncherCall = { spec in
      startInvocations.withLock { $0.append(spec.profileID) }
      return (port: EnginePort(60070), session: HealthySession())
    }
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 5,
      backoffSchedule: [0.02]
    )
    let box = WeakHostBox()
    let relauncher: PieEngineHost.Relauncher = { [weak store] in
      // Mirrors HelperMain.swift wiring: route the auto path through
      // the same HelperResumeAction.run that togglePauseResume uses.
      guard let store else { return }
      let outcome = HelperResumeAction.run(
        engineHost: box.host,
        profileStore: store,
        resolver: resolver
      )
      _ = outcome
    }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 100, // disable liveness monitor in this scenario
      livenessFailureThreshold: 99,
      relaunchPolicy: policy,
      relauncher: relauncher
    )
    box.host = host

    // Drive the user-Resume path first.
    let userResumeOutcome = HelperResumeAction.run(
      engineHost: host,
      profileStore: store,
      resolver: resolver
    )
    if case .started = userResumeOutcome {} else {
      XCTFail("user-Resume must reach .started; got \(userResumeOutcome)")
    }

    // Wait for the user-driven start to land.
    try await waitUntil("user-Resume reaches .running") {
      if case .running = host.status { return true }
      return false
    }
    host.stop()
    try await waitUntil("host returns to .stopped after user pause") {
      if case .stopped = host.status { return true }
      return false
    }

    // Now simulate auto-relaunch by entering .failed(.engineGone) and
    // invoking the relauncher closure directly (skipping the liveness
    // monitor — that's covered in cases 1/2/3).
    host.recordPreStartFailure(EngineError(code: .engineGone, message: "synthetic"))
    relauncher()
    try await waitUntil("auto-relaunch reaches .running") {
      if case .running = host.status { return true }
      return false
    }

    let starts = startInvocations.withLock { $0 }
    let resolves = resolverInvocations.withLock { $0 }
    XCTAssertEqual(starts.count, 2, "exactly two launches: one user-Resume, one auto")
    XCTAssertEqual(starts.first, starts.last,
                   "auto and user-Resume must hand the host the same LaunchSpec.profileID")
    XCTAssertEqual(resolves, ["chat", "chat"],
                   "both paths must consult the same resolver with the same active profile id")

    host.stop()
  }

  // MARK: - 6. G4-via-first-SSE proof

  func test_g4_firstSSE_after_autoRelaunch_proves_engine_and_model_health() async throws {
    // The retry path's first SSE event of the retried turn IS the
    // engine+model health proof. Inferlet /healthz only says the
    // WASM is up; control-plane ping only says the engine is up.
    // The retried turn emitting `delta` proves generation can run,
    // which is what the user actually cares about ( G4 folded
    // into retry).
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let firstFrameSeen = OSAllocatedUnfairLock<Bool>(initialState: false)
    let engine = ProbingChatEngine(
      firstError: HTTPEngineError.engineGone(detail: "synthetic engine death"),
      successEvents: [
        .modelReady,
        .delta(role: .assistant, content: "ack"),
        .finish(reason: .stop),
      ],
      onSecondAttemptFirstFrame: {
        firstFrameSeen.withLock { $0 = true }
      }
    )
    let gate = ScriptedRecoveryGate(initialGone: true, willRecover: true)
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1"),
      recoveryGate: gate
    )

    try await waitUntil("retry stream completes") { !controller.isInFlight }
    XCTAssertTrue(firstFrameSeen.withLock { $0 },
                  "G4 contract: the first SSE event of the retried turn proves engine+model health")
    let assistant = chat.messages.first { $0.role == "assistant" }
    XCTAssertEqual(assistant?.content, "ack",
                   "the retried turn must produce real generated content, not a placeholder")
  }

  // MARK: - 7. Engine-gone retry must reset the durable reasoning field

  func test_engineGone_retry_resets_reasoning_no_fusion_across_attempts() async throws {
    // Regression: the retry-reset block clears `content`/`meta` but the
    // durable `reasoning` field must reset too. Attempt 1 streams a
    // reasoning delta and FLUSHES it durably (a `model_ready` frame
    // forces the writer's durability boundary) before the engine dies;
    // attempt 2 streams its own reasoning. After auto-recovery,
    // `assistant.reasoning` must hold ONLY attempt-2's text — never
    // attempt-1 + attempt-2 fused (the same data-loss class as a stale
    // reasoning carry-over).
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ReasoningRetryEngine(
      firstAttemptEvents: [
        .reasoningDelta("attempt-1 thinking"),
        .modelReady, // forces flush → "attempt-1 thinking" committed durably
      ],
      firstError: HTTPEngineError.engineGone(detail: "synthetic engine death"),
      successEvents: [
        .reasoningDelta("attempt-2 thinking"),
        .delta(role: .assistant, content: "ack"),
        .finish(reason: .stop),
      ]
    )
    let gate = ScriptedRecoveryGate(initialGone: true, willRecover: true)
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1"),
      recoveryGate: gate
    )

    try await waitUntil("retry stream completes") { !controller.isInFlight }
    let assistant = chat.messages.first { $0.role == "assistant" }
    XCTAssertEqual(assistant?.content, "ack",
                   "the retried turn must produce the retry's content")
    XCTAssertEqual(assistant?.reasoning, "attempt-2 thinking",
                   "retry-reset must discard attempt-1 reasoning; the recovered turn's reasoning must not fuse across attempts")
  }

  // MARK: - 8. Recovery-failure branch surfaces the error (no hang)

  func test_recoveryFails_surfacesEngineGoneMarker_doesNotHang() async throws {
    // gate reports engine-gone but never recovers → the retry path falls
    // through to markAssistant on the LIVE row (generation unchanged, no
    // cancel), surfaces the engine-gone marker, and settles isInFlight.
    // Exercises the `guard recovered else { … }` branch with the post-await
    // generation guard PASSING.
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ProbingChatEngine(
      firstError: HTTPEngineError.engineGone(detail: "synthetic engine death"),
      successEvents: []   // recovery never happens, so this is never streamed
    )
    let gate = ScriptedRecoveryGate(initialGone: true, willRecover: false)
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1"),
      recoveryGate: gate
    )

    try await waitUntil("controller settles after failed recovery") { !controller.isInFlight }
    let assistant = chat.messages.first { $0.role == "assistant" }
    XCTAssertNotNil(assistant, "the assistant row must remain (it was never cancelled/deleted)")
    XCTAssertTrue(assistant?.content.hasPrefix("⚠️") ?? false,
                  "failed recovery must surface the engine-gone marker, got: \(assistant?.content ?? "nil")")
    XCTAssertTrue(assistant?.content.contains("Engine stopped unexpectedly") ?? false,
                  "the surfaced error must be the engine-gone description")
  }

  // MARK: - 9. No recovery gate wired → engineGone surfaces, no hang

  func test_noRecoveryGate_engineGoneFirst_surfaces_doesNotHang() async throws {
    // With no gate the fault cannot be ridden through recovery; the
    // first-pass throw must surface immediately on the live row and the
    // controller must settle (not park on a recovery wait). Exercises the
    // `guard attemptsRemaining > 0, isEngineGoneFault, let gate else { … }`
    // branch with the post-await generation guard PASSING.
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ProbingChatEngine(
      firstError: HTTPEngineError.engineGone(detail: "synthetic engine death"),
      successEvents: []
    )
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1"),
      recoveryGate: nil
    )

    try await waitUntil("controller settles with no gate") { !controller.isInFlight }
    let assistant = chat.messages.first { $0.role == "assistant" }
    XCTAssertNotNil(assistant)
    XCTAssertTrue(assistant?.content.hasPrefix("⚠️") ?? false,
                  "no-gate engineGone must surface the error marker, got: \(assistant?.content ?? "nil")")
    XCTAssertEqual(engine.callCount, 1, "with no gate there must be no retry attempt")
  }

  // MARK: - 10. Cancel during the recovery wait must not resurrect a deleted row

  func test_cancelDuringRecoveryWait_doesNotResurrectDeletedRow() async throws {
    // Reproduces the write-after-delete: attempt 1 throws engineGone, the
    // task parks in waitUntilRunning, then cancel() bumps generation and
    // recordCancelledAssistant DELETES the empty assistant row. When the
    // wait returns false (cancellation), the post-await generation guard
    // must abort BEFORE markAssistant — otherwise it writes + saves onto a
    // deleted Message (SwiftData crash / resurrected warning row).
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let entered = OSAllocatedUnfairLock<Bool>(initialState: false)
    let gate = ParkingRecoveryGate(onEntered: { entered.withLock { $0 = true } })
    let engine = ProbingChatEngine(
      firstError: HTTPEngineError.engineGone(detail: "synthetic engine death"),
      successEvents: []
    )
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1"),
      recoveryGate: gate,
      recoveryPolicy: ChatRecoveryPolicy(maxAttempts: 2, waitForReadyTimeout: 30)
    )

    // Park reached: attempt 1 threw, classified engine-gone, now waiting.
    try await waitUntil("recovery wait entered") { entered.withLock { $0 } }
    // Capture the row REFERENCE: markAssistant mutates this exact object, so
    // asserting against it (not via chat.messages, which the delete already
    // pruned) is what gives the regression teeth.
    let parked = try XCTUnwrap(chat.messages.first { $0.role == "assistant" },
                               "assistant row must exist while parked")
    XCTAssertTrue(parked.content.isEmpty, "row is empty before cancel (no content streamed)")

    // Cancel mid-wait → bumps generation, deletes the empty row.
    controller.cancel()
    XCTAssertFalse(controller.isInFlight, "cancel() settles isInFlight synchronously")

    // Let the parked task observe cancellation, return false, and hit the
    // post-await generation guard (which must abort without marking).
    try await Task.sleep(nanoseconds: 200_000_000)

    // F1 core assertion: the post-await generation guard must abort BEFORE
    // markAssistant. markAssistant mutates THIS captured Message reference
    // (sets content to the ⚠️ marker) and saves it — onto a row
    // recordCancelledAssistant already deleted. Asserting the captured row
    // never gained the marker proves the stale task did not write after the
    // delete (on an on-disk store that errant write is the latent crash).
    XCTAssertTrue(parked.content.isEmpty,
                  "F1: the deleted row's content must stay empty (markAssistant must not run), got: \(parked.content)")
    XCTAssertFalse(parked.content.contains("⚠️"),
                   "F1: markAssistant wrote the engine-gone warning onto the deleted row")
    XCTAssertFalse(chat.messages.contains { $0.content.contains("⚠️") },
                   "F1: no engine-gone warning may surface in the live transcript")
  }

  // MARK: - 11. Mid-stream HELPER death is recoverable (#393/#412)

  func test_helperUnreachable_midStream_waitsAndRetries() async throws {
    // A HELPER death mid-stream surfaces as a bare transport error (NOT
    // `HTTPEngineError.engineGone` — the dead helper can't report engineGone).
    // The classifier's forced poll finds the helper unreachable
    // (`isHelperUnreachable`), so the turn must be ridden through recovery:
    // wait for the App's restart ladder to bring the engine back, then retry —
    // instead of surfacing a raw transport error. Without the #412 broadening
    // (isEngineGone OR isHelperUnreachable) the assistant would show the ⚠️
    // error marker instead of the retried answer.
    struct TransportBoom: Error {}
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ProbingChatEngine(
      firstError: TransportBoom(),
      successEvents: [.delta(role: .assistant, content: "ack"), .finish(reason: .stop)]
    )
    let gate = ScriptedRecoveryGate(initialGone: false, willRecover: true, initialHelperUnreachable: true)
    let controller = ChatSendController()

    controller.send(
      chat: chat,
      context: context,
      engine: engine,
      modelLoadCenter: ModelLoadCenter(),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m1"),
      recoveryGate: gate
    )

    try await waitUntil("retry stream completes after helper recovery") { !controller.isInFlight }
    let assistant = chat.messages.first { $0.role == "assistant" }
    XCTAssertEqual(assistant?.content, "ack",
                   "a mid-stream helper death must be ridden through recovery + retried, not surfaced as a transport error")
    XCTAssertEqual(engine.callCount, 2, "exactly one retry after the helper recovered")
  }

  // MARK: - 12. Recovery wait budget is sized to the fault's recovery path (#412 F1)

  func test_recoveryWait_budget_matches_fault_recovery_path() async throws {
    // A HELPER death recovers via the App-side restart ladder (first repair
    // ~17s+), so the wait must use the larger `helperUnreachableWaitTimeout`;
    // an ENGINE death recovers via PieEngineHost's faster ladder, so it keeps
    // the tight `waitForReadyTimeout`. The fixed 15s wait used for both was
    // too short for the helper-ladder path (review F1).
    let policy = ChatRecoveryPolicy()  // 15s engine / 45s helper

    func runAndCaptureBudget(gone: Bool, helperUnreachable: Bool) async throws -> TimeInterval? {
      let container = try RatioThinkModelContainer.makeInMemory()
      let context = ModelContext(container)
      let chat = Chat()
      context.insert(chat)
      chat.messages.append(Message(role: "user", content: "ping", ts: Date(timeIntervalSinceReferenceDate: 1)))
      try context.save()
      struct TransportBoom: Error {}
      let engine = ProbingChatEngine(
        firstError: gone ? HTTPEngineError.engineGone(detail: "x") : TransportBoom(),
        successEvents: [.delta(role: .assistant, content: "ack"), .finish(reason: .stop)]
      )
      let gate = ScriptedRecoveryGate(initialGone: gone, willRecover: true, initialHelperUnreachable: helperUnreachable)
      let controller = ChatSendController()
      controller.send(chat: chat, context: context, engine: engine,
                      modelLoadCenter: ModelLoadCenter(), persistenceStatus: PersistenceStatus(),
                      options: ChatSendRequestOptions(modelID: "m1"),
                      recoveryGate: gate, recoveryPolicy: policy)
      try await waitUntil("retry settles") { !controller.isInFlight }
      return gate.lastWaitTimeout
    }

    let helperBudget = try await runAndCaptureBudget(gone: false, helperUnreachable: true)
    XCTAssertEqual(helperBudget, policy.helperUnreachableWaitTimeout,
                   "helper-death branch must use the larger ladder-sized budget")
    let engineBudget = try await runAndCaptureBudget(gone: true, helperUnreachable: false)
    XCTAssertEqual(engineBudget, policy.waitForReadyTimeout,
                   "engine-death branch must keep the tight engine-relaunch budget")
  }

  // MARK: - 13. Helper-wait ceiling is policy-derived, not a literal (#412 re-F1)

  func test_helperUnreachableCeiling_covers_worstCase_and_tracks_policy() {
    let probe = HelperReconcileProbeBudget.seconds

    // (a) The default helper-wait timeout MUST be the derived ceiling — not a
    // hand-picked literal — and that ceiling MUST cover the ladder's worst-case
    // time-to-.unreachable, modeled here INDEPENDENTLY of the ceiling formula
    // (1 Hz cadence; each repair attempt probes reachability ~twice). If the
    // wait could expire before the ladder escalates, `helperRecoveryGaveUp`
    // never fires and the raw error surfaces — F1 reborn.
    let p = HelperHealthPolicy()
    let worstCaseToUnreachable =
      TimeInterval(p.transientThreshold)
      + TimeInterval(p.maxRepairAttempts) * (TimeInterval(p.repairGap) + 2 * probe)
    let ceiling = ChatRecoveryPolicy.helperUnreachableCeiling(for: p, probeBudget: probe)
    XCTAssertGreaterThanOrEqual(ceiling, worstCaseToUnreachable,
      "derived ceiling must cover the ladder's worst-case time-to-.unreachable")
    XCTAssertEqual(ChatRecoveryPolicy().helperUnreachableWaitTimeout, ceiling,
      "the shipping default must BE the derived ceiling, not a hand-picked literal")

    // (b) The ceiling tracks the policy: bumping ANY ladder knob (or slowing
    // the reconcile probe) raises it, so a future retune cannot silently push
    // recovery past a stale ceiling and re-introduce F1.
    func ceil(_ policy: HelperHealthPolicy, _ pb: TimeInterval = probe) -> TimeInterval {
      ChatRecoveryPolicy.helperUnreachableCeiling(for: policy, probeBudget: pb)
    }
    XCTAssertGreaterThan(ceil(HelperHealthPolicy(transientThreshold: p.transientThreshold + 6)), ceiling,
      "larger transientThreshold must raise the ceiling")
    XCTAssertGreaterThan(ceil(HelperHealthPolicy(maxRepairAttempts: p.maxRepairAttempts + 1)), ceiling,
      "more repair attempts must raise the ceiling")
    XCTAssertGreaterThan(ceil(HelperHealthPolicy(repairGap: p.repairGap + 5)), ceiling,
      "larger repairGap must raise the ceiling")
    XCTAssertGreaterThan(ceil(p, probe + 5), ceiling,
      "a slower reconcile probe must raise the ceiling")
  }

  // MARK: - helpers

  private func makeSpec(profileID: String = "chat") -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: profileID,
      modelConfig: .dummy
    )
  }

  private func waitUntil(_ description: String, timeout: TimeInterval = 2, condition: @MainActor @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
  }
}

// MARK: - in-process fixtures

@available(macOS 14, *)
private final class HealthySession: PieEngineHost.EngineSession, @unchecked Sendable {
  func shutdown() async -> EngineShutdownResult { .reaped }
  func checkLiveness() async -> EngineLiveness { .alive }
}

@available(macOS 14, *)
private final class OneShotDeathSession: PieEngineHost.EngineSession, @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  func shutdown() async -> EngineShutdownResult { .reaped }
  func checkLiveness() async -> EngineLiveness {
    lock.lock(); defer { lock.unlock() }
    if !fired { fired = true; return .gone(reason: "synthetic crash") }
    return .alive
  }
}

/// Test clock the slow-flap test advances by hand so the sliding-window
/// prune is exercised deterministically instead of via a real sleep
/// that races the liveness/backoff timers.
private final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  init(_ start: Date) { current = start }
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
  func advance(by seconds: TimeInterval) {
    lock.lock(); defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}

@available(macOS 14, *)
private final class WeakHostBox: @unchecked Sendable {
  weak var host: PieEngineHost?
}

/// Engine fake that fails on first chat-completion call, then streams
/// `successEvents` on every subsequent call. Fires
/// `onSecondAttemptFirstFrame` right before the first frame of the
/// recovered turn so the G4 test can assert the engine+model health
/// proof.
@available(macOS 14, *)
private final class ProbingChatEngine: EngineClient, @unchecked Sendable {
  let firstError: Error
  let successEvents: [ChatEvent]
  let onSecondAttemptFirstFrame: (@Sendable () -> Void)?
  private(set) var callCount = 0

  init(firstError: Error,
       successEvents: [ChatEvent],
       onSecondAttemptFirstFrame: (@Sendable () -> Void)? = nil) {
    self.firstError = firstError
    self.successEvents = successEvents
    self.onSecondAttemptFirstFrame = onSecondAttemptFirstFrame
  }

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func loadModel(_ id: String) -> AsyncThrowingStream<LoadEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    callCount += 1
    let isFirst = (callCount == 1)
    let error = firstError
    let events = successEvents
    let probe = onSecondAttemptFirstFrame
    return AsyncThrowingStream { continuation in
      if isFirst {
        continuation.finish(throwing: error)
      } else {
        if let probe { probe() }
        for event in events { continuation.yield(event) }
        continuation.finish()
      }
    }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

/// Engine fake for the reasoning-reset regression: attempt 1 streams
/// `firstAttemptEvents` (so a reasoning delta can be flushed durably)
/// then throws `firstError`; every later attempt streams
/// `successEvents` cleanly. Distinct from `ProbingChatEngine`, which
/// throws on attempt 1 with no prior frames.
@available(macOS 14, *)
private final class ReasoningRetryEngine: EngineClient, @unchecked Sendable {
  let firstAttemptEvents: [ChatEvent]
  let firstError: Error
  let successEvents: [ChatEvent]
  private(set) var callCount = 0

  init(firstAttemptEvents: [ChatEvent], firstError: Error, successEvents: [ChatEvent]) {
    self.firstAttemptEvents = firstAttemptEvents
    self.firstError = firstError
    self.successEvents = successEvents
  }

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func loadModel(_ id: String) -> AsyncThrowingStream<LoadEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    callCount += 1
    let isFirst = (callCount == 1)
    let firstEvents = firstAttemptEvents
    let error = firstError
    let events = successEvents
    return AsyncThrowingStream { continuation in
      if isFirst {
        for event in firstEvents { continuation.yield(event) }
        continuation.finish(throwing: error)
      } else {
        for event in events { continuation.yield(event) }
        continuation.finish()
      }
    }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

@available(macOS 14, *)
@MainActor
private final class ScriptedRecoveryGate: ChatRecoveryGate {
  private var goneFlag: Bool
  private var unreachableFlag: Bool
  let willRecover: Bool
  init(initialGone: Bool, willRecover: Bool, initialHelperUnreachable: Bool = false) {
    self.goneFlag = initialGone
    self.unreachableFlag = initialHelperUnreachable
    self.willRecover = willRecover
  }
  var isEngineGone: Bool { goneFlag }
  var isHelperUnreachable: Bool { unreachableFlag }
  var helperRecoveryGaveUp: Bool { false }
  /// Captures the budget `ChatSendController` chose for the wait, so a test
  /// can assert the helper-unreachable branch gets the larger ladder budget.
  private(set) var lastWaitTimeout: TimeInterval?
  func refreshStatus() async {}
  func waitUntilRunning(timeout: TimeInterval) async -> Bool {
    lastWaitTimeout = timeout
    if willRecover {
      goneFlag = false
      unreachableFlag = false
      return true
    }
    return false
  }
}

/// Recovery gate whose `waitUntilRunning` PARKS until the surrounding task
/// is cancelled, then returns false — mirroring the production gate's
/// cancellation-aware return. Lets a test interleave a `cancel()` while the
/// controller is suspended in the recovery wait: the exact window the F1
/// write-after-delete guard protects.
@available(macOS 14, *)
@MainActor
private final class ParkingRecoveryGate: ChatRecoveryGate {
  private let onEntered: () -> Void
  init(onEntered: @escaping () -> Void) { self.onEntered = onEntered }
  var isEngineGone: Bool { true }
  var isHelperUnreachable: Bool { false }
  var helperRecoveryGaveUp: Bool { false }
  func refreshStatus() async {}
  func waitUntilRunning(timeout: TimeInterval) async -> Bool {
    onEntered()
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
  }
}
