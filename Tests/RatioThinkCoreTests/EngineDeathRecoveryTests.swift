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
    // Window = 250ms; backoff = 10ms. Two deaths inside the window
    // exhaust the ladder (cap=2). After the window elapses, attempts
    // are pruned, so a fresh death gets a fresh attempt. Mirrors
    // PieSupervisor's healthy-uptime reset pattern.
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let launcher: PieEngineHost.LauncherCall = { _ in
      let n = launchCount.withLock { c -> Int in c += 1; return c }
      return (port: EnginePort(60030 + UInt16(n)), session: OneShotDeathSession())
    }
    let policy = PieEngineHost.RelaunchPolicy(
      maxAttempts: 2,
      window: 0.25,
      backoffSchedule: [0.01, 0.01, 0.01]
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

    let exhausted = expectation(description: "third .failed (ladder exhausted inside window)")
    var failedCount = 0
    let token = host.observe { status, _ in
      if case .failed(.engineGone, _) = status {
        failedCount += 1
        if failedCount == 3 { exhausted.fulfill() }
      }
    }
    _ = host.start(spec)
    await fulfillment(of: [exhausted], timeout: 3)
    let launchesInsideWindow = launchCount.withLock { $0 }
    XCTAssertEqual(launchesInsideWindow, 3,
                   "1 initial + 2 auto-relaunches inside window before exhaustion")

    // Sleep past the window so attempt timestamps are pruned.
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertEqual(host.autoRelaunchAttemptsForTesting, 0,
                   "post-window prune must clear the attempt set")

    // Drive a fresh start; engine dies again → ladder should re-arm
    // and fire one more auto-relaunch since the window is empty.
    let rearmed = expectation(description: "post-window auto-relaunch fires again")
    var sawFreshFailed = false
    let preLaunchCount = launchCount.withLock { $0 }
    let token2 = host.observe { status, _ in
      if case .failed(.engineGone, _) = status {
        if !sawFreshFailed { sawFreshFailed = true }
      }
    }
    _ = host.start(spec) // user-driven restart
    // After this start: engine dies → .failed → ladder re-arms → fresh launch.
    try await Task.sleep(nanoseconds: 250_000_000)
    let postLaunchCount = launchCount.withLock { $0 }
    XCTAssertGreaterThanOrEqual(postLaunchCount - preLaunchCount, 2,
                                "post-window: a fresh user start + at least one auto-relaunch")
    rearmed.fulfill()
    await fulfillment(of: [rearmed], timeout: 0.1)

    token.cancel()
    token2.cancel()
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
  func shutdown() async {}
  func checkLiveness() async -> EngineLiveness { .alive }
}

@available(macOS 14, *)
private final class OneShotDeathSession: PieEngineHost.EngineSession, @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  func shutdown() async {}
  func checkLiveness() async -> EngineLiveness {
    lock.lock(); defer { lock.unlock() }
    if !fired { fired = true; return .gone(reason: "synthetic crash") }
    return .alive
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

@available(macOS 14, *)
@MainActor
private final class ScriptedRecoveryGate: ChatRecoveryGate {
  private var goneFlag: Bool
  let willRecover: Bool
  init(initialGone: Bool, willRecover: Bool) {
    self.goneFlag = initialGone
    self.willRecover = willRecover
  }
  var isEngineGone: Bool { goneFlag }
  func refreshStatus() async {}
  func waitUntilRunning(timeout: TimeInterval) async -> Bool {
    if willRecover {
      goneFlag = false
      return true
    }
    return false
  }
}
