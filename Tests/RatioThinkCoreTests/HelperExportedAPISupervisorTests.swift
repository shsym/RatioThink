import XCTest
import os
@testable import RatioThinkCore

/// XPC-side wiring between `HelperExportedAPI` and `PieEngineHost`
/// ( — replaces the prior `PieSupervisor`-backed coverage).
/// Drives the live selectors (engineStatus, startEngine, stopEngine,
/// clearKillRejected) with a fake `LauncherCall` so the test harness
/// does not need a real `pie` subprocess.
///
/// Behaviors not ported from the supervisor-era suite:
///  · `killRejected` / `stop-deadline` propagation — PieEngineHost
///    deliberately ships without those branches (
///    out-of-scope).
///  · slow-flap / restart-ladder coverage — same reason.
final class HelperExportedAPISupervisorTests: XCTestCase {

  // MARK: - fakes

  /// Minimal session fake that records shutdown invocation so tests
  /// can verify the host tore the engine down on Pause / cancel.
  final class FakeSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let delay: TimeInterval
    init(shutdownDelay: TimeInterval = 0) {
      self.delay = shutdownDelay
    }
    var shutdownCount: Int { count.withLock { $0 } }
    func shutdown() async -> EngineShutdownResult {
      count.withLock { $0 += 1 }
      if delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      return .reaped
    }
  }

  /// Build a launcher that returns `(port, FakeSession)` after an
  /// optional delay. `delay=0` returns synchronously, which is the
  /// happy path for most reply-shape tests.
  private static func makeLauncher(port: EnginePort,
                                   delay: TimeInterval = 0,
                                   sessionSink: ((FakeSession) -> Void)? = nil) -> PieEngineHost.LauncherCall {
    { _ in
      if delay > 0 {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      let session = FakeSession()
      sessionSink?(session)
      return (port: port, session: session)
    }
  }

  /// Launcher that throws to drive `PieEngineHost.failed(.spawnFailed, _)`.
  private static func makeFailingLauncher(message: String) -> PieEngineHost.LauncherCall {
    { _ in
      struct Boom: Error, CustomStringConvertible { let msg: String; var description: String { msg } }
      throw Boom(msg: message)
    }
  }

  /// Launcher that never returns (until the wrapping Task is
  /// cancelled). Used by the reply-timeout fallback tests so the
  /// host stays in `.starting` past the fallback deadline.
  private static func makeWedgedLauncher() -> PieEngineHost.LauncherCall {
    { _ in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      throw CancellationError()
    }
  }

  private func makeSpec(profileID: String = "chat",
                        handshakeTimeout: TimeInterval = 30) -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      handshakeTimeout: handshakeTimeout,
      profileID: profileID,
      modelConfig: .dummy
    )
  }

  // MARK: - engineStatus

  func test_engineStatus_withoutHost_returnsStopped() {
    let api = HelperExportedAPI()
    let exp = expectation(description: "engineStatus reply")
    var captured: EngineStatus?
    api.engineStatus { data in
      captured = try? XPCPayload.decode(EngineStatus.self, from: data)
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
    XCTAssertEqual(captured, .stopped)
  }

  func test_engineStatus_withHost_reflectsLiveState() throws {
    let host = PieEngineHost(launcher: Self.makeLauncher(port: 42424))
    let spec = makeSpec(profileID: "chat")
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: nil)
    _ = host.start(spec)
    waitForRunning(host, timeout: 5)

    let exp = expectation(description: "engineStatus reply")
    var captured: EngineStatus?
    api.engineStatus { data in
      captured = try? XPCPayload.decode(EngineStatus.self, from: data)
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
    guard case let .running(port, profileID) = captured else {
      host.stop()
      return XCTFail("expected .running, got \(String(describing: captured))")
    }
    XCTAssertEqual(port, 42424)
    XCTAssertEqual(profileID, "chat")
    host.stop()
  }

  // MARK: - startEngine

  func test_startEngine_withoutResolver_returnsProfileMissing() {
    let host = PieEngineHost(launcher: Self.makeLauncher(port: 1234))
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: nil)

    let exp = expectation(description: "startEngine reply")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
    guard case .failure(let err)? = captured else {
      return XCTFail("expected .failure, got \(String(describing: captured))")
    }
    XCTAssertEqual(err.code, .profileMissing)
  }

  func test_startEngine_withResolver_returnsPortOnHandshake() throws {
    let host = PieEngineHost(launcher: Self.makeLauncher(port: 31415))
    let spec = makeSpec(profileID: "chat")
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: { _, _ in .success(spec) })

    let exp = expectation(description: "startEngine reply")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 5)
    guard case .success(let port)? = captured else {
      host.stop()
      return XCTFail("expected .success, got \(String(describing: captured))")
    }
    XCTAssertEqual(port, 31415)
    host.stop()
  }

  func test_startEngine_replyTimeoutFallback_doesNotStopAlreadyAcknowledgedRunningEngine() throws {
    var session: FakeSession?
    let host = PieEngineHost(launcher: Self.makeLauncher(port: 31416, sessionSink: { session = $0 }))
    let spec = makeSpec(profileID: "tree-of-thought")
    let api = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: { _, _ in .success(spec) },
      replyTimeoutOverride: (start: 0.2, stop: 0.3)
    )

    let exp = expectation(description: "startEngine success reply before fallback")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "tree-of-thought", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
    guard case .success(let port)? = captured else {
      host.stop()
      return XCTFail("expected .success before fallback; got \(String(describing: captured))")
    }
    XCTAssertEqual(port, 31416)

    let fallbackExpired = expectation(description: "fallback deadline passed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { fallbackExpired.fulfill() }
    wait(for: [fallbackExpired], timeout: 2)

    guard case .running(let livePort, let liveProfile) = host.status else {
      return XCTFail("reply-timeout fallback stopped an already-acknowledged engine; status=\(host.status)")
    }
    XCTAssertEqual(livePort, 31416)
    XCTAssertEqual(liveProfile, "tree-of-thought")
    XCTAssertEqual(session?.shutdownCount, 0,
                   "fallback must not shutdown a running engine after startEngine already replied success")
    host.stop()
  }

  func test_startEngine_repeatedSameProfileWhileStarting_attachesToSameLaunch() throws {
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let host = PieEngineHost(launcher: { _ in
      launchCount.withLock { $0 += 1 }
      try await Task.sleep(nanoseconds: 200_000_000)
      return (port: EnginePort(41414), session: FakeSession())
    })
    let spec = makeSpec(profileID: "tree-of-thought")
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: { _, _ in .success(spec) })

    let first = expectation(description: "first startEngine reply")
    let second = expectation(description: "second startEngine reply")
    var firstResult: Result<EnginePort, EngineError>?
    var secondResult: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "tree-of-thought", modelOverride: nil) { successData, errorData in
      firstResult = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      first.fulfill()
    }
    api.startEngine(profileID: "tree-of-thought", modelOverride: nil) { successData, errorData in
      secondResult = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      second.fulfill()
    }
    wait(for: [first, second], timeout: 3)

    guard case .success(let firstPort)? = firstResult else {
      host.stop()
      return XCTFail("first startEngine should attach to launch and succeed; got \(String(describing: firstResult))")
    }
    guard case .success(let secondPort)? = secondResult else {
      host.stop()
      return XCTFail("second startEngine should attach to same launch and succeed; got \(String(describing: secondResult))")
    }
    XCTAssertEqual(firstPort, 41414)
    XCTAssertEqual(secondPort, 41414)
    XCTAssertEqual(launchCount.withLock { $0 }, 1,
                   "repeated startEngine(same profile) while starting must not spawn a second engine")
    host.stop()
  }

  func test_startEngine_replyTimeoutFallback_onlyCompletesXPCReply_notEngineLifetime() throws {
    let host = PieEngineHost(
      launcher: Self.makeWedgedLauncher(),
      launchTimeoutSlack: 0
    )
    let spec = makeSpec(profileID: "chat", handshakeTimeout: 1.0)
    let api = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: { _, _ in .success(spec) },
      replyTimeoutOverride: (start: 0.2, stop: 0.3)
    )

    let exp = expectation(description: "startEngine XPC fallback reply")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
    guard case .failure(let err)? = captured else {
      host.stop()
      return XCTFail("expected fallback .failure; got \(String(describing: captured))")
    }
    XCTAssertEqual(err.code, .handshakeTimeout)
    XCTAssertTrue(err.message.contains("reply-timeout fallback"))
    guard case .starting = host.status else {
      host.stop()
      return XCTFail("XPC reply fallback must not be an engine lifetime lease or cleanup path; status=\(host.status)")
    }

    let hostTimeout = expectation(description: "host-owned launch timeout")
    let token = host.observe { status, _ in
      if case .failed(.handshakeTimeout, _) = status { hostTimeout.fulfill() }
    }
    wait(for: [hostTimeout], timeout: 3)
    token.cancel()
  }

  func test_startEngine_propagatesHostFailure() throws {
    let host = PieEngineHost(launcher: Self.makeFailingLauncher(message: "fake spawn boom"))
    let spec = makeSpec(profileID: "chat")
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: { _, _ in .success(spec) })

    let exp = expectation(description: "startEngine reply")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 5)
    guard case .failure(let err)? = captured else {
      return XCTFail("expected .failure, got \(String(describing: captured))")
    }
    XCTAssertEqual(err.code, .spawnFailed)
    XCTAssertTrue(err.message.contains("fake spawn boom"),
                  "expected failure message to carry the launcher error; got: \(err.message)")
  }

  func test_startEngine_memoryRiskResolverFailure_doesNotEnterStarting() {
    let host = PieEngineHost(launcher: { _ in
      XCTFail("memory-risk resolver rejection must happen before launcher invocation")
      throw CancellationError()
    })
    let api = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: { _, _ in
        .failure(EngineError(
          code: .memoryRisk,
          message: "memory risk: oversized model; choose a smaller model"
        ))
      }
    )

    let exp = expectation(description: "startEngine memory-risk reply")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)

    guard case .failure(let err)? = captured else {
      return XCTFail("expected .failure, got \(String(describing: captured))")
    }
    XCTAssertEqual(err.code, .memoryRisk)
    XCTAssertTrue(err.message.contains("choose a smaller model"),
                  "got \(err.message)")
    XCTAssertEqual(host.status, .failed(code: .memoryRisk, message: "memory risk: oversized model; choose a smaller model"),
                   "resolver-level memory rejection must be observable through engineStatus/UI")
  }

  // MARK: - stopEngine

  func test_stopEngine_withoutHost_returnsNotImplemented() {
    let api = HelperExportedAPI()
    let exp = expectation(description: "stopEngine reply")
    var captured: Data?
    api.stopEngine { errorData in
      captured = errorData
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
    let data = try? XCTUnwrap(captured)
    XCTAssertNotNil(data)
    if let data, let err = try? XPCPayload.decode(EngineError.self, from: data) {
      XCTAssertEqual(err.code, .wireContractViolation)
    } else {
      XCTFail("stopEngine reply did not decode as EngineError")
    }
  }

  func test_stopEngine_withHost_repliesNilOnStop() throws {
    var captured: FakeSession?
    let host = PieEngineHost(launcher: Self.makeLauncher(port: 55555, sessionSink: { captured = $0 }))
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: nil)
    _ = host.start(makeSpec(profileID: "chat"))
    waitForRunning(host, timeout: 5)

    let exp = expectation(description: "stopEngine reply")
    var errPayload: Data? = Data([0xff])
    api.stopEngine { errorData in
      errPayload = errorData
      exp.fulfill()
    }
    wait(for: [exp], timeout: 5)
    XCTAssertNil(errPayload, "stopEngine should reply nil on clean stop")
    // Session.shutdown must have been called.
    XCTAssertEqual(captured?.shutdownCount, 1, "host did not invoke session.shutdown on stop")
  }

  // MARK: - restartEngine

  func test_restartEngine_waitsForSlowStopTerminalBeforeStartingReplacement() throws {
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let firstSession = FakeSession(shutdownDelay: 0.3)
    let secondSession = FakeSession()
    let host = PieEngineHost(launcher: { _ in
      let count = launchCount.withLock { count -> Int in
        count += 1
        return count
      }
      return count == 1
        ? (port: EnginePort(11111), session: firstSession)
        : (port: EnginePort(22222), session: secondSession)
    })
    let spec = makeSpec(profileID: "chat")
    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: { _, _ in .success(spec) })

    let startExp = expectation(description: "initial start reply")
    api.startEngine(profileID: "chat", modelOverride: nil) { _, _ in startExp.fulfill() }
    wait(for: [startExp], timeout: 2)
    waitForRunning(host, timeout: 2)

    let restartExp = expectation(description: "restart reply after replacement start")
    var captured: Result<EnginePort, EngineError>?
    api.restartEngine(profileID: "chat") { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      restartExp.fulfill()
    }

    let preTerminalExp = expectation(description: "before slow shutdown finishes")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { preTerminalExp.fulfill() }
    wait(for: [preTerminalExp], timeout: 1)
    XCTAssertEqual(firstSession.shutdownCount, 1)
    XCTAssertEqual(launchCount.withLock { $0 }, 1,
                   "restart must not launch replacement until the helper host has published terminal stop")

    wait(for: [restartExp], timeout: 3)
    guard case .success(let port)? = captured else {
      host.stop()
      return XCTFail("expected restart success, got \(String(describing: captured))")
    }
    XCTAssertEqual(port, 22222)
    XCTAssertEqual(launchCount.withLock { $0 }, 2)
    host.stop()
  }

  // MARK: - wireViolationStatusBlob shape (F7 carry-over)

  func test_wireViolationStatusBlob_decodesAsFailedWireContract() throws {
    let encoded = try XPCPayload.encode(EngineStatus.failed(
      code: .wireContractViolation,
      message: "engineStatus encode failed; see helper log"
    ))
    let decoded = try XPCPayload.decode(EngineStatus.self, from: encoded)
    guard case .failed(.wireContractViolation, let msg) = decoded else {
      return XCTFail("encoded fallback is not .failed(.wireContractViolation)")
    }
    XCTAssertTrue(msg.contains("encode failed"))
  }

  // MARK: - F3: observer survives token discard

  func test_observerSurvivesWhenCallerDiscardsToken() throws {
    let host = PieEngineHost(launcher: Self.makeLauncher(port: 12345))
    let exp = expectation(description: "observer sees .running even after token discarded")
    _ = host.observe { status, token in
      if case .running = status {
        exp.fulfill()
        token.cancel()
      }
    }
    _ = host.start(makeSpec(profileID: "chat"))
    wait(for: [exp], timeout: 5)
    host.stop()
  }

  // MARK: - F4 + F28: reply timeout fallback fires + cancels observer

  func test_startEngine_replyTimeoutFallback_firesAndCancelsObserver() throws {
    let host = PieEngineHost(launcher: Self.makeWedgedLauncher())
    let spec = makeSpec(profileID: "chat")
    let api = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: { _, _ in .success(spec) },
      replyTimeoutOverride: (start: 0.3, stop: 0.3)
    )
    let baseline = host.observerCountForTesting
    let exp = expectation(description: "startEngine reply (deterministic fallback)")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
    guard case .failure(let err)? = captured else {
      host.stop()
      return XCTFail("expected .failure; got \(String(describing: captured))")
    }
    XCTAssertEqual(err.code, .handshakeTimeout)
    XCTAssertTrue(err.message.contains("fallback fired"),
                  "expected fallback marker; got \(err.message)")

    host.stop()
    let detachExp = expectation(description: "observer detached")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { detachExp.fulfill() }
    wait(for: [detachExp], timeout: 1)
    XCTAssertLessThanOrEqual(host.observerCountForTesting, baseline,
                             "fallback path leaked observer (review v2 F28)")
  }

  /// Host-owned launch timeout regression guard. The XPC reply fallback is not
  /// allowed to own process lifetime; a genuinely stuck `.starting` attempt is
  /// cleaned up by `PieEngineHost` using the launch incarnation it armed when
  /// the launch began, and `startEngine` reports that terminal
  /// `.handshakeTimeout` via the observer path.
  func test_startEngine_hostLaunchTimeout_cancelsStuckStartingAndRepliesHandshakeTimeout() throws {
    let host = PieEngineHost(launcher: Self.makeWedgedLauncher(), launchTimeoutSlack: 0)
    let spec = makeSpec(profileID: "chat", handshakeTimeout: 0.2)
    let api = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: { _, _ in .success(spec) },
      replyTimeoutOverride: (start: 5, stop: 0.3)
    )
    let replyExp = expectation(description: "startEngine reply (host launch timeout)")
    var captured: Result<EnginePort, EngineError>?
    api.startEngine(profileID: "chat", modelOverride: nil) { successData, errorData in
      captured = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      replyExp.fulfill()
    }
    wait(for: [replyExp], timeout: 2)
    guard case .failure(let err)? = captured else {
      host.stop()
      return XCTFail("expected .failure; got \(String(describing: captured))")
    }
    XCTAssertEqual(err.code, .handshakeTimeout)
    XCTAssertTrue(err.message.contains("launch timed out"),
                  "expected host-owned launch timeout message; got \(err.message)")

    guard case .failed(.handshakeTimeout, _) = host.status else {
      return XCTFail("host launch timeout must leave a retryable terminal failure, not an orphan .starting launch; status=\(host.status)")
    }
  }

  func test_stopEngine_replyTimeoutFallback_cancelsObserver() throws {
    // Launcher succeeds, then the session's shutdown hangs so
    // stopEngine's observer never sees `.stopped`. The fallback
    // deadline (0.3s) wins and the observer-detach path runs.
    final class HangSession: PieEngineHost.EngineSession, @unchecked Sendable {
      func shutdown() async -> EngineShutdownResult {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .unreaped("test hang")
      }
    }
    let host = PieEngineHost(launcher: { _ in
      return (port: EnginePort(23232), session: HangSession())
    })
    let spec = makeSpec(profileID: "chat")
    let api = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: { _, _ in .success(spec) },
      replyTimeoutOverride: (start: 5, stop: 0.3)
    )
    let startExp = expectation(description: "engine running")
    api.startEngine(profileID: "chat", modelOverride: nil) { _, _ in startExp.fulfill() }
    wait(for: [startExp], timeout: 8)

    let baseline = host.observerCountForTesting
    let exp = expectation(description: "stopEngine fallback reply")
    var captured: Data? = Data([0xff])
    api.stopEngine { errorData in
      captured = errorData
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
    let data = try XCTUnwrap(captured)
    let err = try XPCPayload.decode(EngineError.self, from: data)
    XCTAssertTrue(err.message.contains("fallback fired"),
                  "expected fallback marker; got \(err.message)")

    let detachExp = expectation(description: "observer detached")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { detachExp.fulfill() }
    wait(for: [detachExp], timeout: 1)
    XCTAssertLessThanOrEqual(host.observerCountForTesting, baseline,
                             "stopEngine fallback path leaked observer (review v2 F28)")
  }

  // MARK: - clearKillRejected: stub under PieEngineHost

  func test_clearKillRejected_returnsWireContractViolation() throws {
    //  left PieSupervisor's restart/boot-recovery out of
    // scope; clearKillRejected has no implementation under
    // PieEngineHost, so the selector must surface the structured
    // not-implemented error rather than silently no-op.
    let api = HelperExportedAPI()
    let exp = expectation(description: "clearKillRejected reply")
    var captured: Data?
    api.clearKillRejected { errorData in
      captured = errorData
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
    let data = try XCTUnwrap(captured)
    let err = try XPCPayload.decode(EngineError.self, from: data)
    XCTAssertEqual(err.code, .wireContractViolation)
  }

  // MARK: - helpers

  private func waitForRunning(_ host: PieEngineHost, timeout: TimeInterval) {
    let exp = expectation(description: "host running")
    let lock = NSLock()
    var fulfilled = false
    let token = host.observe { status, _ in
      if case .running = status {
        lock.lock(); defer { lock.unlock() }
        if !fulfilled { fulfilled = true; exp.fulfill() }
      }
    }
    wait(for: [exp], timeout: timeout)
    token.cancel()
  }
}
