import XCTest
import Foundation
import Darwin
import os
import RatioThinkCore

/// D2 — coverage tier "real pie binary, opt-in".
///
/// Sibling of `EngineDeathRecoveryTests` (RatioThinkCoreTests, in-process
/// mocks): same 3-of-6 cases re-staged against a real `pie serve`
/// subprocess so the recovery handshake is proven against real
/// `PieControlClient` wire behavior, real OS-level WS socket teardown
/// under SIGKILL, and real pie cold-start timing — the things the
/// RatioThinkCoreTests mock tier cannot reach.
///
/// OPT-IN MECHANISM (skipped by default in fast CI):
///   - `PIE_RUN_REAL_ENGINE_TESTS=1`     gate flag (required)
///   - `PIE_REAL_BINARY_PATH=<abs path>` real `pie` binary (preferred)
///   - Fallback if `PIE_REAL_BINARY_PATH` is unset: probe
///     `<repo>/Vendor/pie/target/release/pie` (the standard
///     `make engine-build` artifact path).
///
/// HOW TO RUN LOCALLY:
///   ```
///   # Build the real pie binary once:
///   (cd Vendor/pie && PIE_PORTABLE_METAL=1 \
///       cargo build -p pie-server --release)
///   # Then run just this suite with the opt-in flag set:
///   ENABLE_CODE_COVERAGE=NO PIE_RUN_REAL_ENGINE_TESTS=1 \
///   swift test --filter EngineDeathRecoveryRealEngineTests
///   ```
///
/// EXPECTED RUNTIME:
///   - Real pie cold-start handshake: ~3–8s per launch on a warm box.
///   - Three cases together: ~30–60s. Past the 5s/test default budget
///     deliberately — these are slow-lane / nightly tests, not fast
///     CI. The `make test-all` slow-lane target is the canonical
///     entry; fast `make test-unit` skips them via the gate flag.
///
/// COVERAGE TRADE-OFF (vs RatioThinkCoreTests/EngineDeathRecoveryTests):
///   - In-process mocks prove SWIFT-SIDE control flow only.
///   - This file proves: real `PieControlClient` handshake survives
///     auto-relaunch; real SIGKILL of the pie subprocess flips the
///     liveness monitor; cold-start budget is realistic; the relaunch
///     does not corrupt the chat-history channel.
///
/// OUT OF SCOPE for this file (→ step 2d scripted manual harness):
///   GUI-visible state (⚠️ assistant bubble, menu-bar Resume affordance).
///
/// Build constraint: `ENABLE_CODE_COVERAGE=NO` (cmark-gfm-extensions
/// link-fail under Xcode 26.5, per the `pie-mac coverage build link
/// failure` memory).
final class EngineDeathRecoveryRealEngineTests: IsolatedTestCase {

  // MARK: - opt-in discovery

  private func discoverRealPieBinary() throws -> URL {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PIE_RUN_REAL_ENGINE_TESTS"] == "1",
      "Opt-in: set PIE_RUN_REAL_ENGINE_TESTS=1 to exercise the real-pie tier (see file header)."
    )
    if let override = ProcessInfo.processInfo.environment["PIE_REAL_BINARY_PATH"] {
      let url = URL(fileURLWithPath: override)
      try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                        "PIE_REAL_BINARY_PATH=\(override) does not exist on disk")
      return url
    }
    let probe = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Vendor/pie/target/release/pie")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: probe.path),
                      "No real pie binary: set PIE_REAL_BINARY_PATH or run `cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release` (probed \(probe.path))")
    return probe
  }

  private func discoverBundledInferletResources() throws -> (wasm: URL, manifest: URL) {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let wasm = cwd.appendingPathComponent("Inferlets/chat-apc/prebuilt/chat-apc.wasm")
    let manifest = cwd.appendingPathComponent("Inferlets/chat-apc/Pie.toml")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: wasm.path),
                      "chat-apc prebuilt wasm missing at \(wasm.path) — run `make build-inferlets`")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: manifest.path),
                      "chat-apc manifest missing at \(manifest.path)")
    return (wasm, manifest)
  }

  private func makeRealLaunchSpec(profileID: String = "chat") throws -> PieControlLauncher.LaunchSpec {
    let pieURL = try discoverRealPieBinary()
    let resources = try discoverBundledInferletResources()
    return try PieControlLauncher.LaunchSpec(
      pieBinary: pieURL,
      wasmURL: resources.wasm,
      manifestURL: resources.manifest,
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      handshakeTimeout: 30,
      pidSink: { [weak self] pid in self?.trackSubprocess(pid) },
      profileID: profileID,
      // Dummy driver: skips capability probe + model-load weight read.
      // Sufficient for the recovery state machine — the assertions
      // we make (engine-gone classification, ladder firing, retried
      // turn produces at least one SSE frame) do not depend on real
      // model output. Step 2d (scripted manual harness) covers the
      // user-visible end of the chat against a real model.
      modelConfig: .dummy
    )
  }

  // MARK: - case 1: real cold-start after kill

  func test_realEngine_kill_during_running_triggers_autoRelaunch_back_to_running() async throws {
    let baseSpec = try makeRealLaunchSpec()
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let pidsSeen = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
    let spec = try Self.attachPidSink(baseSpec, sink: { pid in
      pidsSeen.withLock { $0.append(pid) }
    })

    let box = WeakHostBox()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    // Wrap the production launcher so the test can count launches.
    // PieEngineHost.productionLauncher is the same closure HelperMain
    // uses in shipping code; we re-bind it here exclusively for the
    // launch-count instrumentation.
    let instrumentedLauncher: PieEngineHost.LauncherCall = { spec in
      launchCount.withLock { $0 += 1 }
      let (port, session) = try await PieControlLauncher.launch(spec: spec)
      return (port: EnginePort(port), session: session)
    }
    let host = PieEngineHost(
      launcher: instrumentedLauncher,
      livenessInterval: 1.0,
      livenessFailureThreshold: 2,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(
        maxAttempts: 2,
        window: 60,
        backoffSchedule: [1.0, 2.0]
      ),
      relauncher: relauncher
    )
    box.host = host
    defer { host.stop() }

    let firstRunning = expectation(description: "initial .running")
    let gone = expectation(description: ".failed(.engineGone)")
    let secondRunning = expectation(description: "auto-relaunched .running")
    var runningCount = 0
    var sawGone = false
    var firstRunningPort: UInt16?
    let token = host.observe { status, _ in
      switch status {
      case .running(let port, _):
        runningCount += 1
        if runningCount == 1 {
          firstRunningPort = UInt16(port)
          firstRunning.fulfill()
        } else if runningCount == 2 {
          secondRunning.fulfill()
        }
      case .failed(.engineGone, _):
        if !sawGone { sawGone = true; gone.fulfill() }
      default:
        break
      }
    }

    try host.start(spec).get()
    await fulfillment(of: [firstRunning], timeout: 45)

    // SIGKILL the running pie subprocess. The most-recent tracked pid
    // belongs to the freshly-launched engine; pidsSeen records every
    // spawn so this is robust against pid reuse.
    let victim = try XCTUnwrap(pidsSeen.withLock { $0.last },
                               "pidSink must have captured the launched pie pid")
    XCTAssertEqual(kill(victim, SIGKILL), 0,
                   "SIGKILL pid=\(victim) failed: errno=\(errno)")

    await fulfillment(of: [gone, secondRunning], timeout: 60, enforceOrder: true)
    XCTAssertEqual(launchCount.withLock { $0 }, 2,
                   "real-engine kill must drive exactly one auto-relaunch")

    // G4 proof against real engine: send a chat request to the
    // newly-relaunched engine and assert the first SSE event arrives
    // — that's the "engine + model can serve generation" proof.
    let secondPort = try XCTUnwrap({ () -> UInt16? in
      if case .running(let port, _) = host.status { return UInt16(port) }
      return nil
    }(), "host must be .running after auto-relaunch")
    XCTAssertNotEqual(secondPort, firstRunningPort,
                      "auto-relaunch must bind a fresh OS-picked port, not reuse the dead one")

    let client = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:\(secondPort)")!,
                                  unaryTimeout: 15)
    let modelID = try await Self.resolveFirstRegisteredModel(client: client)
    let firstFrame = try await firstSSEFrameOrTimeout(client: client,
                                                      modelID: modelID,
                                                      timeout: 30)
    XCTAssertTrue(firstFrame, "real engine must emit at least one SSE event after auto-relaunch")

    token.cancel()
  }

  // MARK: - case 2: repeat-kill exhausts ladder

  func test_realEngine_repeatedKill_exhausts_ladder_at_maxAttempts() async throws {
    let spec = try makeRealLaunchSpec()
    let pidsSeen = OSAllocatedUnfairLock<[pid_t]>(initialState: [])

    let box = WeakHostBox()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    // Kill every freshly-launched engine the moment we see it bind a
    // port — drives the ladder to exhaustion as fast as the engine
    // can hand off the pid.
    let instrumentedLauncher: PieEngineHost.LauncherCall = { spec in
      let augmentedSpec = try Self.attachPidSink(spec, sink: { pid in
        pidsSeen.withLock { $0.append(pid) }
      })
      let (port, session) = try await PieControlLauncher.launch(spec: augmentedSpec)
      return (port: EnginePort(port), session: session)
    }
    let host = PieEngineHost(
      launcher: instrumentedLauncher,
      livenessInterval: 0.5,
      livenessFailureThreshold: 2,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(
        maxAttempts: 2,
        window: 60,
        backoffSchedule: [0.5, 0.5]
      ),
      relauncher: relauncher
    )
    box.host = host
    defer { host.stop() }

    var failedTransitions = 0
    let exhausted = expectation(description: "third .failed (ladder exhausted)")
    let runningLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    let token = host.observe { status, _ in
      switch status {
      case .running:
        runningLock.withLock { $0 += 1 }
      case .failed(.engineGone, _):
        failedTransitions += 1
        if failedTransitions == 3 { exhausted.fulfill() }
      default:
        break
      }
    }

    try host.start(spec).get()

    // Kill loop: poll for each fresh .running transition (initial +
    // 2 auto-relaunches = up to 3), snapshot the latest pid, SIGKILL
    // it. Polling beats DispatchSemaphore here because the observer
    // closure cannot reach across actor isolation safely.
    let killDeadline = Date().addingTimeInterval(60)
    var observedRunningCount = 0
    var killCount = 0
    while killCount < 3 && Date() < killDeadline {
      let nowSeen = runningLock.withLock { $0 }
      if nowSeen > observedRunningCount {
        observedRunningCount = nowSeen
        if let pid = pidsSeen.withLock({ $0.last }) {
          _ = kill(pid, SIGKILL)
          killCount += 1
        }
      } else {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    await fulfillment(of: [exhausted], timeout: 90)
    XCTAssertGreaterThanOrEqual(pidsSeen.withLock { $0.count }, 3,
                                "real engine must spawn 1 initial + 2 auto-relaunches before the ladder gives up")
    // Confirm no further launches fire post-exhaustion.
    let postCount = pidsSeen.withLock { $0.count }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertEqual(pidsSeen.withLock { $0.count }, postCount,
                   "post-exhaustion: no further launches must fire while the host stays .failed(.engineGone)")
    if case .failed(.engineGone, _) = host.status {
      // expected
    } else {
      XCTFail("host status must be .failed(.engineGone) after the ladder exhausts; got \(host.status)")
    }
    token.cancel()
  }

  // MARK: - case 3: post-relaunch session context preserved

  func test_realEngine_postRelaunch_acceptsExtendedHistory_streamsAtLeastOneFrame() async throws {
    let baseSpec = try makeRealLaunchSpec()
    let pidsSeen = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
    let spec = try Self.attachPidSink(baseSpec, sink: { pid in
      pidsSeen.withLock { $0.append(pid) }
    })
    let box = WeakHostBox()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      _ = box.host?.start(spec)
    }
    let host = PieEngineHost(
      launcher: nil, // productionLauncher
      livenessInterval: 1.0,
      livenessFailureThreshold: 2,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(
        maxAttempts: 2,
        window: 60,
        backoffSchedule: [1.0, 2.0]
      ),
      relauncher: relauncher
    )
    box.host = host
    defer { host.stop() }

    let firstRunning = expectation(description: "initial .running")
    let secondRunning = expectation(description: "auto-relaunched .running")
    var runningCount = 0
    let token = host.observe { status, _ in
      if case .running = status {
        runningCount += 1
        if runningCount == 1 { firstRunning.fulfill() }
        else if runningCount == 2 { secondRunning.fulfill() }
      }
    }
    try host.start(spec).get()
    await fulfillment(of: [firstRunning], timeout: 45)

    // Pre-kill: drive a turn-1 chat. We do not need real content; we
    // need to prove the engine accepts the request shape and emits
    // at least one SSE frame.
    let port1 = try XCTUnwrap({ () -> UInt16? in
      if case .running(let p, _) = host.status { return UInt16(p) }; return nil
    }())
    let client1 = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:\(port1)")!, unaryTimeout: 15)
    let modelID = try await Self.resolveFirstRegisteredModel(client: client1)
    let frame1 = try await firstSSEFrameOrTimeout(client: client1,
                                                   modelID: modelID,
                                                   timeout: 30,
                                                   messages: [ChatMessage(role: .user, content: "hi")])
    XCTAssertTrue(frame1, "real engine pre-kill chat must stream at least one SSE event")

    // Kill the engine, wait for auto-relaunch.
    let victim = try XCTUnwrap(pidsSeen.withLock { $0.last })
    XCTAssertEqual(kill(victim, SIGKILL), 0)
    await fulfillment(of: [secondRunning], timeout: 60)

    // Post-relaunch: extended history (turn-1 user + new turn-2 user).
    // The relauncher uses a fresh PieControlLauncher.launch, so the
    // engine has cold-started with no in-memory chat state. The
    // request body carries the full history — which is the contract:
    // chat state lives App-side (SwiftData), engine processes the
    // request as supplied. Assert: the relaunched engine accepts the
    // multi-turn request shape and streams at least one SSE event.
    let port2 = try XCTUnwrap({ () -> UInt16? in
      if case .running(let p, _) = host.status { return UInt16(p) }; return nil
    }())
    XCTAssertNotEqual(port2, port1, "auto-relaunch must bind a fresh port")
    let client2 = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:\(port2)")!, unaryTimeout: 15)
    let modelID2 = try await Self.resolveFirstRegisteredModel(client: client2)
    let frame2 = try await firstSSEFrameOrTimeout(
      client: client2,
      modelID: modelID2,
      timeout: 30,
      messages: [
        ChatMessage(role: .user, content: "hi"),
        ChatMessage(role: .assistant, content: "hello"),
        ChatMessage(role: .user, content: "what was my first message?"),
      ]
    )
    XCTAssertTrue(frame2,
                  "post-relaunch real engine must accept the extended-history ChatRequest and stream ≥1 SSE event")

    token.cancel()
  }

  // MARK: - helpers

  /// Drive a chat-completions stream against the live engine and
  /// return true once the first event (any kind — modelLoading,
  /// modelReady, delta, finish) arrives. Times out if the engine
  /// produces nothing within `timeout` seconds.
  private func firstSSEFrameOrTimeout(
    client: HTTPEngineClient,
    modelID: String,
    timeout: TimeInterval,
    messages: [ChatMessage] = [ChatMessage(role: .user, content: "ping")]
  ) async throws -> Bool {
    let req = ChatRequest(
      model: modelID,
      messages: messages,
      sampling: ChatSampling(temperature: 0.1, topP: 0.9, maxTokens: 8)
    )
    return try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        for try await _ in client.chatCompletion(req) {
          return true
        }
        return false
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
      }
      let first = try await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  /// `GET /v1/models → first id`. With `modelConfig: .dummy` the
  /// engine still registers chat-apc's bundled model entries, so the
  /// first id is the right thing to feed into chat-completions —
  /// `model: "dummy"` is rejected with `model_not_found`. Mirrors
  /// `S3_EngineSubprocess.resolveChatModel`.
  static func resolveFirstRegisteredModel(client: HTTPEngineClient) async throws -> String {
    let models = try await client.models()
    guard let first = models.first else {
      throw NSError(domain: "EngineDeathRecoveryRealEngineTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "/v1/models returned empty list after successful pie launch"])
    }
    return first.id
  }

  /// Re-build a LaunchSpec adding an extra pidSink fanout. The
  /// IsolatedTestCase already wires its own sink for reap cleanup;
  /// case-2 needs its own observation channel so it can SIGKILL the
  /// freshest spawn without racing the reap path.
  static func attachPidSink(
    _ spec: PieControlLauncher.LaunchSpec,
    sink extra: @Sendable @escaping (pid_t) -> Void
  ) throws -> PieControlLauncher.LaunchSpec {
    let original = spec.pidSink
    return try PieControlLauncher.LaunchSpec(
      pieBinary: spec.pieBinary,
      wasmURL: spec.wasmURL,
      manifestURL: spec.manifestURL,
      subprocessEnvironment: spec.subprocessEnvironment,
      pieHome: spec.pieHome,
      shmemName: spec.shmemName,
      inferletNameAtVersion: spec.inferletNameAtVersion,
      handshakeTimeout: spec.handshakeTimeout,
      pidSink: { pid in
        original?(pid)
        extra(pid)
      },
      profileID: spec.profileID,
      modelConfig: spec.modelConfig
    )
  }
}

// MARK: - in-process fixtures shared with RatioThinkCoreTests/EngineDeathRecoveryTests

/// Weak self-reference box, mirrors the RatioThinkCoreTests fixture so the
/// production-style "host + relauncher = cycle" pattern stays broken
/// in tests. Local copy because RatioThinkCoreTests's `WeakHostBox` is
/// `private` to that file.
private final class WeakHostBox: @unchecked Sendable {
  weak var host: PieEngineHost?
}
