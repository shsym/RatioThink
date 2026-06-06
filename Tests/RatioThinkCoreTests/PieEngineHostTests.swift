import XCTest
import os
@testable import RatioThinkCore

/// Unit tests for `PieEngineHost` — the production engine manager
/// that replaces `PieSupervisor` on the helper boot path. Drives the launcher-seam injection so the host's state
/// machine can be exercised without spawning a real `pie` subprocess.
final class PieEngineHostTests: XCTestCase {

  // MARK: - fakes

  /// Records `shutdown()` invocation count so the cancellation /
  /// pause-during-running tests can verify the host actually tore
  /// the session down.
  final class FakeSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var shutdownCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func shutdown() async { lock.lock(); _count += 1; lock.unlock() }
  }

  final class BlockingShutdownSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var _shutdownCount = 0
    let shutdownStarted: XCTestExpectation

    init(shutdownStarted: XCTestExpectation) {
      self.shutdownStarted = shutdownStarted
    }

    var shutdownCount: Int {
      lock.lock(); defer { lock.unlock() }
      return _shutdownCount
    }

    func shutdown() async {
      lock.lock()
      _shutdownCount += 1
      lock.unlock()
      shutdownStarted.fulfill()
      await withCheckedContinuation { continuation in
        lock.lock()
        shutdownContinuation = continuation
        lock.unlock()
      }
    }

    func finishShutdown() {
      lock.lock()
      let continuation = shutdownContinuation
      shutdownContinuation = nil
      lock.unlock()
      continuation?.resume()
    }
  }

  final class LaunchGate: @unchecked Sendable {
    typealias LaunchResult = (port: EnginePort, session: any PieEngineHost.EngineSession)

    private let lock = NSLock()
    private var continuations: [CheckedContinuation<LaunchResult, Error>] = []
    let started: [XCTestExpectation]

    init(started: [XCTestExpectation]) {
      self.started = started
    }

    func launch(_ spec: PieControlLauncher.LaunchSpec) async throws -> LaunchResult {
      try await withCheckedThrowingContinuation { continuation in
        let index = lock.withLock { () -> Int in
          continuations.append(continuation)
          return continuations.count - 1
        }
        if index < started.count {
          started[index].fulfill()
        }
      }
    }

    func succeed(_ index: Int, port: EnginePort, session: any PieEngineHost.EngineSession) {
      let continuation = lock.withLock { continuations[index] }
      continuation.resume(returning: (port: port, session: session))
    }

    func fail(_ index: Int, _ error: Error) {
      let continuation = lock.withLock { continuations[index] }
      continuation.resume(throwing: error)
    }
  }

  final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    let armed: [XCTestExpectation]

    init(armed: [XCTestExpectation]) {
      self.armed = armed
    }

    func sleep(_ seconds: TimeInterval) async {
      await withCheckedContinuation { continuation in
        let index = lock.withLock { () -> Int in
          continuations.append(continuation)
          return continuations.count - 1
        }
        if index < armed.count {
          armed[index].fulfill()
        }
      }
    }

    func wake(_ index: Int) {
      let continuation = lock.withLock { continuations[index] }
      continuation.resume()
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

  // MARK: - start → running

  func test_start_transitions_through_starting_to_running() {
    let host = PieEngineHost(launcher: { _ in
      return (port: EnginePort(42424), session: FakeSession())
    })
    let exp = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running(let port, let profileID) = status {
        XCTAssertEqual(port, 42424)
        XCTAssertEqual(profileID, "chat")
        exp.fulfill()
      }
    }
    XCTAssertEqual(host.status, .stopped, "initial status must be .stopped")
    let result = host.start(makeSpec(profileID: "chat"))
    if case .failure = result {
      XCTFail("start must succeed on a fresh host")
    }
    wait(for: [exp], timeout: 2)
    token.cancel()
  }

  // MARK: - stopAndWait (#448 quit primitive)

  func test_stopAndWait_reapsRunningEngine_thenFiresCompletionOnce() {
    let session = FakeSession()
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(5150), session: session) })
    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    token.cancel()

    let done = expectation(description: "stopAndWait completion fires")
    let fireCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    host.stopAndWait(timeout: 5) { result in
      XCTAssertTrue(result.reachedTerminal, "normal stop must report a terminal reap")
      XCTAssertEqual(result.lastStatus, .stopped)
      fireCount.withLock { $0 += 1 }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    // Completion fires only after the session was shut down (pie reaped).
    XCTAssertEqual(session.shutdownCount, 1, "stopAndWait must reap the engine before firing")
    XCTAssertEqual(host.status, .stopped)
    // Give any stray duplicate a window to (not) arrive.
    let settle = expectation(description: "settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
    wait(for: [settle], timeout: 1)
    XCTAssertEqual(fireCount.withLock { $0 }, 1, "completion must fire exactly once")
  }

  func test_stopAndWait_onAlreadyStoppedHost_firesImmediately() {
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(1), session: FakeSession()) })
    XCTAssertEqual(host.status, .stopped)
    let done = expectation(description: "completion fires for already-stopped host")
    host.stopAndWait(timeout: 5) { result in
      XCTAssertTrue(result.reachedTerminal)
      XCTAssertEqual(result.lastStatus, .stopped)
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }

  func test_stopAndWait_timeoutReportsNonTerminalLastStatus() {
    final class HangingSession: PieEngineHost.EngineSession, @unchecked Sendable {
      func shutdown() async {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }

    let host = PieEngineHost(launcher: { _ in (port: EnginePort(5151), session: HangingSession()) })
    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    token.cancel()

    let done = expectation(description: "stopAndWait timeout completion fires")
    host.stopAndWait(timeout: 0.05) { result in
      XCTAssertFalse(result.reachedTerminal, "timeout must be distinguishable from terminal reap")
      XCTAssertEqual(result.lastStatus, .stopping)
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }

  // MARK: - start → failed

  func test_start_surfaces_launcher_error_as_spawnFailed() {
    struct Boom: Error, CustomStringConvertible { var description: String { "fake spawn boom" } }
    let host = PieEngineHost(launcher: { _ in throw Boom() })
    let exp = expectation(description: "host reaches .failed")
    let token = host.observe { status, _ in
      if case .failed(let code, let message) = status {
        XCTAssertEqual(code, .spawnFailed)
        XCTAssertTrue(message.contains("fake spawn boom"),
                      "expected the launcher error to flow into the message; got \(message)")
        exp.fulfill()
      }
    }
    _ = host.start(makeSpec())
    wait(for: [exp], timeout: 2)
    token.cancel()
  }

  // MARK: - repeated start semantics

  func test_double_start_different_profile_returns_alreadyRunning() {
    let host = PieEngineHost(launcher: { _ in
      // Hold past the second start so the host stays in .starting.
      try await Task.sleep(nanoseconds: 200_000_000)
      return (port: EnginePort(1234), session: FakeSession())
    })
    let firstSpec = makeSpec(profileID: "chat-1")
    let secondSpec = makeSpec(profileID: "chat-2")
    _ = host.start(firstSpec)
    let second = host.start(secondSpec)
    guard case .failure(let err) = second else {
      return XCTFail("second start must be rejected while first is .starting")
    }
    XCTAssertEqual(err.code, .alreadyRunning)
    host.stop()
  }

  func test_startOrAttach_same_profile_while_starting_is_idempotent_and_does_not_launch_again() {
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let host = PieEngineHost(launcher: { _ in
      launchCount.withLock { $0 += 1 }
      try await Task.sleep(nanoseconds: 200_000_000)
      return (port: EnginePort(1234), session: FakeSession())
    })
    let spec = makeSpec(profileID: "chat")
    XCTAssertNoThrow(try host.start(spec).get())
    XCTAssertNoThrow(try host.startOrAttach(spec).get())

    let exp = expectation(description: "host reaches running from the single launch")
    let token = host.observe { status, _ in
      if case .running(let port, let profileID) = status {
        XCTAssertEqual(port, 1234)
        XCTAssertEqual(profileID, "chat")
        exp.fulfill()
      }
    }
    wait(for: [exp], timeout: 2)
    token.cancel()
    XCTAssertEqual(launchCount.withLock { $0 }, 1,
                   "idempotent start(same profile) must attach to the in-flight launch, not spawn another engine")
    host.stop()
  }

  func test_startOrAttach_same_profile_while_running_is_idempotent_and_does_not_restart() {
    let launchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let session = FakeSession()
    let host = PieEngineHost(launcher: { _ in
      launchCount.withLock { $0 += 1 }
      return (port: EnginePort(5678), session: session)
    })
    let spec = makeSpec(profileID: "tree-of-thought")
    XCTAssertNoThrow(try host.start(spec).get())
    let exp = expectation(description: "host reaches running")
    let token = host.observe { status, _ in
      if case .running = status { exp.fulfill() }
    }
    wait(for: [exp], timeout: 2)
    token.cancel()

    XCTAssertNoThrow(try host.startOrAttach(spec).get())
    XCTAssertEqual(launchCount.withLock { $0 }, 1,
                   "idempotent start(same profile) while running must not restart the engine")
    XCTAssertEqual(session.shutdownCount, 0,
                   "idempotent start(same profile) while running must not shut down the active engine")
    host.stop()
  }

  func test_launch_timeout_is_owned_by_host_and_cancels_only_still_starting_attempt() {
    let host = PieEngineHost(
      launcher: { _ in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CancellationError()
      },
      launchTimeoutSlack: 0
    )
    let exp = expectation(description: "host launch timeout fails with handshakeTimeout")
    let token = host.observe { status, _ in
      if case .failed(.handshakeTimeout, let message) = status {
        XCTAssertTrue(message.contains("launch timed out"), "got \(message)")
        exp.fulfill()
      }
    }
    XCTAssertNoThrow(try host.start(makeSpec(handshakeTimeout: 0.2)).get())
    wait(for: [exp], timeout: 2)
    token.cancel()
    guard case .failed(.handshakeTimeout, _) = host.status else {
      return XCTFail("expected host-owned launch timeout failure; got \(host.status)")
    }
  }

  func test_stale_launch_timeout_after_running_is_inert() {
    let session = FakeSession()
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(9012), session: session) },
      launchTimeoutSlack: 0
    )
    XCTAssertNoThrow(try host.start(makeSpec(profileID: "tree-of-thought", handshakeTimeout: 0.2)).get())
    let running = expectation(description: "host reaches running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    wait(for: [running], timeout: 2)

    let timeoutWouldHaveExpired = expectation(description: "launch timeout deadline passed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
      timeoutWouldHaveExpired.fulfill()
    }
    wait(for: [timeoutWouldHaveExpired], timeout: 2)
    token.cancel()

    guard case .running(let port, let profileID) = host.status else {
      return XCTFail("stale launch timeout must not change a running host; status=\(host.status)")
    }
    XCTAssertEqual(port, 9012)
    XCTAssertEqual(profileID, "tree-of-thought")
    XCTAssertEqual(session.shutdownCount, 0,
                   "stale launch timeout must not shut down a running engine")
    host.stop()
  }

  func test_stale_launch_success_after_timeout_does_not_overwrite_retry() {
    let firstStarted = expectation(description: "launch #1 started")
    let secondStarted = expectation(description: "launch #2 started")
    let firstTimeoutArmed = expectation(description: "launch #1 timeout armed")
    let secondTimeoutArmed = expectation(description: "launch #2 timeout armed")
    let launches = LaunchGate(started: [firstStarted, secondStarted])
    let sleeps = SleepGate(armed: [firstTimeoutArmed, secondTimeoutArmed])
    let firstSession = FakeSession()
    let secondSession = FakeSession()
    let host = PieEngineHost(
      launcher: { spec in try await launches.launch(spec) },
      launchTimeoutSlack: 0,
      sleepFor: { seconds in await sleeps.sleep(seconds) }
    )

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "chat", handshakeTimeout: 0.2)).get())
    wait(for: [firstStarted, firstTimeoutArmed], timeout: 2)

    let timedOut = expectation(description: "launch #1 times out")
    var sawTimeout = false
    let timeoutToken = host.observe { status, token in
      if case .failed(.handshakeTimeout, _) = status, !sawTimeout {
        sawTimeout = true
        timedOut.fulfill()
        token.cancel()
      }
    }
    sleeps.wake(0)
    wait(for: [timedOut], timeout: 2)
    timeoutToken.cancel()

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "tree-of-thought", handshakeTimeout: 0.2)).get())
    wait(for: [secondStarted, secondTimeoutArmed], timeout: 2)

    let running = expectation(description: "launch #2 owns running state")
    let runningToken = host.observe { status, token in
      if case .running(let port, let profileID) = status,
         port == 2002, profileID == "tree-of-thought" {
        running.fulfill()
        token.cancel()
      }
    }
    launches.succeed(0, port: EnginePort(1001), session: firstSession)
    launches.succeed(1, port: EnginePort(2002), session: secondSession)
    wait(for: [running], timeout: 2)
    runningToken.cancel()

    guard case .running(let port, let profileID) = host.status else {
      return XCTFail("retry launch must remain running; status=\(host.status)")
    }
    XCTAssertEqual(port, 2002)
    XCTAssertEqual(profileID, "tree-of-thought")
    XCTAssertEqual(firstSession.shutdownCount, 1,
                   "stale successful launch must shut down only its own returned session")
    XCTAssertEqual(secondSession.shutdownCount, 0,
                   "current retry session must remain owned by the host")
    host.stop()
  }

  func test_stale_launch_cancellation_after_timeout_does_not_stop_retry() {
    let firstStarted = expectation(description: "launch #1 started")
    let secondStarted = expectation(description: "launch #2 started")
    let firstTimeoutArmed = expectation(description: "launch #1 timeout armed")
    let secondTimeoutArmed = expectation(description: "launch #2 timeout armed")
    let launches = LaunchGate(started: [firstStarted, secondStarted])
    let sleeps = SleepGate(armed: [firstTimeoutArmed, secondTimeoutArmed])
    let secondSession = FakeSession()
    let host = PieEngineHost(
      launcher: { spec in try await launches.launch(spec) },
      launchTimeoutSlack: 0,
      sleepFor: { seconds in await sleeps.sleep(seconds) }
    )

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "chat", handshakeTimeout: 0.2)).get())
    wait(for: [firstStarted, firstTimeoutArmed], timeout: 2)
    let timedOut = expectation(description: "launch #1 times out")
    var sawTimeout = false
    let timeoutToken = host.observe { status, token in
      if case .failed(.handshakeTimeout, _) = status, !sawTimeout {
        sawTimeout = true
        timedOut.fulfill()
        token.cancel()
      }
    }
    sleeps.wake(0)
    wait(for: [timedOut], timeout: 2)
    timeoutToken.cancel()

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "tree-of-thought", handshakeTimeout: 0.2)).get())
    wait(for: [secondStarted, secondTimeoutArmed], timeout: 2)

    launches.fail(0, CancellationError())
    let staleCancellationSettled = expectation(description: "stale cancellation processed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      staleCancellationSettled.fulfill()
    }
    wait(for: [staleCancellationSettled], timeout: 1)
    guard case .starting = host.status else {
      return XCTFail("stale launch #1 cancellation must leave launch #2 starting; status=\(host.status)")
    }
    let running = expectation(description: "launch #2 owns running state")
    let runningToken = host.observe { status, token in
      if case .running(let port, let profileID) = status,
         port == 2002, profileID == "tree-of-thought" {
        running.fulfill()
        token.cancel()
      }
    }
    launches.succeed(1, port: EnginePort(2002), session: secondSession)
    wait(for: [running], timeout: 2)
    runningToken.cancel()

    XCTAssertEqual(host.status, .running(port: 2002, profileID: "tree-of-thought"))
    XCTAssertEqual(secondSession.shutdownCount, 0)
    host.stop()
  }

  func test_stale_launch_error_after_timeout_does_not_fail_retry() {
    struct Boom: Error, CustomStringConvertible { var description: String { "late launch #1 boom" } }

    let firstStarted = expectation(description: "launch #1 started")
    let secondStarted = expectation(description: "launch #2 started")
    let firstTimeoutArmed = expectation(description: "launch #1 timeout armed")
    let secondTimeoutArmed = expectation(description: "launch #2 timeout armed")
    let launches = LaunchGate(started: [firstStarted, secondStarted])
    let sleeps = SleepGate(armed: [firstTimeoutArmed, secondTimeoutArmed])
    let secondSession = FakeSession()
    let host = PieEngineHost(
      launcher: { spec in try await launches.launch(spec) },
      launchTimeoutSlack: 0,
      sleepFor: { seconds in await sleeps.sleep(seconds) }
    )

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "chat", handshakeTimeout: 0.2)).get())
    wait(for: [firstStarted, firstTimeoutArmed], timeout: 2)
    let timedOut = expectation(description: "launch #1 times out")
    var sawTimeout = false
    let timeoutToken = host.observe { status, token in
      if case .failed(.handshakeTimeout, _) = status, !sawTimeout {
        sawTimeout = true
        timedOut.fulfill()
        token.cancel()
      }
    }
    sleeps.wake(0)
    wait(for: [timedOut], timeout: 2)
    timeoutToken.cancel()

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "tree-of-thought", handshakeTimeout: 0.2)).get())
    wait(for: [secondStarted, secondTimeoutArmed], timeout: 2)

    launches.fail(0, Boom())
    let staleErrorSettled = expectation(description: "stale error processed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      staleErrorSettled.fulfill()
    }
    wait(for: [staleErrorSettled], timeout: 1)
    guard case .starting = host.status else {
      return XCTFail("stale launch #1 error must leave launch #2 starting; status=\(host.status)")
    }
    let running = expectation(description: "launch #2 owns running state")
    let runningToken = host.observe { status, token in
      if case .running(let port, let profileID) = status,
         port == 2002, profileID == "tree-of-thought" {
        running.fulfill()
        token.cancel()
      }
    }
    launches.succeed(1, port: EnginePort(2002), session: secondSession)
    wait(for: [running], timeout: 2)
    runningToken.cancel()

    XCTAssertEqual(host.status, .running(port: 2002, profileID: "tree-of-thought"))
    XCTAssertEqual(secondSession.shutdownCount, 0)
    host.stop()
  }

  func test_stale_launch_success_does_not_complete_unrelated_slow_stop() {
    let firstSession = FakeSession()
    assertStaleLaunchCompletionDoesNotCompleteUnrelatedSlowStop { launches in
      launches.succeed(0, port: EnginePort(1001), session: firstSession)
    }
    XCTAssertEqual(firstSession.shutdownCount, 1,
                   "stale successful launch must shut down only its own returned session")
  }

  func test_stale_launch_cancellation_does_not_complete_unrelated_slow_stop() {
    assertStaleLaunchCompletionDoesNotCompleteUnrelatedSlowStop { launches in
      launches.fail(0, CancellationError())
    }
  }

  func test_stale_launch_error_does_not_complete_unrelated_slow_stop() {
    struct Boom: Error, CustomStringConvertible { var description: String { "late launch #1 boom" } }
    assertStaleLaunchCompletionDoesNotCompleteUnrelatedSlowStop { launches in
      launches.fail(0, Boom())
    }
  }

  private func assertStaleLaunchCompletionDoesNotCompleteUnrelatedSlowStop(
    file: StaticString = #filePath,
    line: UInt = #line,
    completeStaleLaunch: (LaunchGate) -> Void
  ) {
    let firstStarted = expectation(description: "launch #1 started")
    let secondStarted = expectation(description: "launch #2 started")
    let firstTimeoutArmed = expectation(description: "launch #1 timeout armed")
    let secondTimeoutArmed = expectation(description: "launch #2 timeout armed")
    let secondShutdownStarted = expectation(description: "launch #2 shutdown started")
    let stopped = expectation(description: "launch #2 stop completes")
    let launches = LaunchGate(started: [firstStarted, secondStarted])
    let sleeps = SleepGate(armed: [firstTimeoutArmed, secondTimeoutArmed])
    let secondSession = BlockingShutdownSession(shutdownStarted: secondShutdownStarted)
    let host = PieEngineHost(
      launcher: { spec in try await launches.launch(spec) },
      launchTimeoutSlack: 0,
      sleepFor: { seconds in await sleeps.sleep(seconds) }
    )

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "chat", handshakeTimeout: 0.2)).get(),
                     file: file, line: line)
    wait(for: [firstStarted, firstTimeoutArmed], timeout: 2)

    let timedOut = expectation(description: "launch #1 times out")
    var sawTimeout = false
    let timeoutToken = host.observe { status, token in
      if case .failed(.handshakeTimeout, _) = status, !sawTimeout {
        sawTimeout = true
        timedOut.fulfill()
        token.cancel()
      }
    }
    sleeps.wake(0)
    wait(for: [timedOut], timeout: 2)
    timeoutToken.cancel()

    XCTAssertNoThrow(try host.start(makeSpec(profileID: "tree-of-thought", handshakeTimeout: 0.2)).get(),
                     file: file, line: line)
    wait(for: [secondStarted, secondTimeoutArmed], timeout: 2)

    let running = expectation(description: "launch #2 reaches running")
    let runningToken = host.observe { status, token in
      if case .running(let port, let profileID) = status,
         port == 2002, profileID == "tree-of-thought" {
        running.fulfill()
        token.cancel()
      }
    }
    launches.succeed(1, port: EnginePort(2002), session: secondSession)
    wait(for: [running], timeout: 2)
    runningToken.cancel()

    let stoppedToken = host.observe { status, token in
      if case .stopped = status {
        stopped.fulfill()
        token.cancel()
      }
    }
    host.stop()
    wait(for: [secondShutdownStarted], timeout: 2)
    XCTAssertEqual(host.status, .stopping, file: file, line: line)

    completeStaleLaunch(launches)
    let staleCompletionSettled = expectation(description: "stale launch completion processed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      staleCompletionSettled.fulfill()
    }
    wait(for: [staleCompletionSettled], timeout: 1)

    XCTAssertEqual(host.status, .stopping,
                   "stale launch #1 completion must not complete launch #2's stop",
                   file: file, line: line)
    let overlappingStart = host.start(makeSpec(profileID: "chat", handshakeTimeout: 0.2))
    guard case .failure(let err) = overlappingStart else {
      return XCTFail("host must reject new starts while launch #2 shutdown is still in progress",
                     file: file, line: line)
    }
    XCTAssertEqual(err.code, .alreadyRunning, file: file, line: line)
    XCTAssertEqual(secondSession.shutdownCount, 1, file: file, line: line)

    secondSession.finishShutdown()
    wait(for: [stopped], timeout: 2)
    stoppedToken.cancel()
  }

  // MARK: - stop while running

  func test_stop_while_running_invokes_session_shutdown() {
    let session = FakeSession()
    let host = PieEngineHost(launcher: { [session] _ in
      return (port: EnginePort(55555), session: session)
    })
    let runningExp = expectation(description: "host reaches .running")
    let stoppedExp = expectation(description: "host reaches .stopped")
    var hitRunning = false
    let token = host.observe { status, _ in
      if case .running = status, !hitRunning {
        hitRunning = true
        runningExp.fulfill()
      }
      if hitRunning, case .stopped = status {
        stoppedExp.fulfill()
      }
    }
    _ = host.start(makeSpec())
    wait(for: [runningExp], timeout: 2)
    host.stop()
    wait(for: [stoppedExp], timeout: 2)
    token.cancel()
    XCTAssertEqual(session.shutdownCount, 1,
                   "stop() must invoke session.shutdown exactly once on the running path")
  }

  // MARK: - stop while starting cancels launch task

  func test_stop_while_starting_cancels_launch_and_publishes_stopped() {
    let host = PieEngineHost(launcher: { _ in
      // Hang until cancelled; CancellationError propagates through
      // PieControlLauncher.launch's catch paths in production. Here
      // the launcher itself observes Task.isCancelled and throws.
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      throw CancellationError()
    })
    let stoppedExp = expectation(description: "host reaches .stopped")
    // The stop-while-starting cancel path can publish .stopped more than
    // once (stop() itself, plus the cancelled launch task's error path),
    // so guard the fulfill — matching the idempotent-observer pattern the
    // other tests use (hitRunning / fired). Without the guard the second
    // .stopped over-fulfills the expectation; because it can arrive after
    // this test completes, XCTest attributes the API violation to the
    // next test and the suite flakes.
    var hitStopped = false
    let token = host.observe { status, _ in
      if case .stopped = status, !hitStopped {
        hitStopped = true
        stoppedExp.fulfill()
      }
    }
    _ = host.start(makeSpec())
    // Give the launch task one runloop turn to enter the loop.
    let armed = expectation(description: "armed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { armed.fulfill() }
    wait(for: [armed], timeout: 1)
    host.stop()
    wait(for: [stoppedExp], timeout: 2)
    token.cancel()
  }

  // MARK: - observer initial dispatch + token discard survival

  func test_observe_dispatches_initial_status_and_survives_discarded_token() {
    let host = PieEngineHost(launcher: { _ in
      return (port: EnginePort(31415), session: FakeSession())
    })
    let initialExp = expectation(description: "observer fires with initial status")
    let runningExp = expectation(description: "observer fires with .running")
    // Intentionally not stored: the host must retain the observer
    // by the same contract as PieSupervisor (review v1 F3).
    _ = host.observe { status, token in
      switch status {
      case .stopped: initialExp.fulfill()
      case .running: runningExp.fulfill(); token.cancel()
      default: return
      }
    }
    wait(for: [initialExp], timeout: 1)
    _ = host.start(makeSpec())
    wait(for: [runningExp], timeout: 2)
  }

  // MARK: - liveness monitor → engine-gone ( G1)

  /// Session whose `checkLiveness()` replays a scripted sequence, then
  /// repeats the final element forever. Drives the liveness-monitor
  /// transitions without standing up a real control-plane WebSocket.
  final class ScriptedLivenessSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [EngineLiveness]
    private var idx = 0
    init(_ script: [EngineLiveness]) { self.script = script }
    func shutdown() async {}
    func checkLiveness() async -> EngineLiveness {
      lock.lock(); defer { lock.unlock() }
      let v = script[min(idx, script.count - 1)]
      idx += 1
      return v
    }
  }

  /// Liveness session whose verdict the test sets explicitly, so the
  /// monitor's view of the engine changes only when the test decides —
  /// removing the wall-clock race between scripted probes and `stop()`.
  final class ControllableLivenessSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private var liveness: EngineLiveness
    init(_ initial: EngineLiveness) { self.liveness = initial }
    func set(_ v: EngineLiveness) { lock.lock(); liveness = v; lock.unlock() }
    func shutdown() async {}
    func checkLiveness() async -> EngineLiveness {
      lock.lock(); defer { lock.unlock() }
      return liveness
    }
  }

  func test_running_engine_death_transitions_to_failed_engineGone() {
    // Engine reports gone on every probe → after the consecutive
    // threshold the host must leave .running for .failed(.engineGone),
    // carrying the probe's reason. This is the  G1 detection half:
    // a coded engine-gone signal surfaced through EngineStatus.failed
    // (no  dependency).
    let session = ScriptedLivenessSession([.gone(reason: "engine process exited (status 139)")])
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(40404), session: session) },
      livenessInterval: 0.02,
      livenessFailureThreshold: 2
    )
    let exp = expectation(description: ".failed(.engineGone)")
    var fired = false
    let token = host.observe { status, _ in
      if case .failed(let code, let message) = status, !fired {
        fired = true
        XCTAssertEqual(code, .engineGone)
        XCTAssertTrue(message.contains("exited"),
                      "engine-gone reason should carry the cause; got \(message)")
        exp.fulfill()
      }
    }
    _ = host.start(makeSpec())
    wait(for: [exp], timeout: 3)
    token.cancel()
    host.stop()
  }

  func test_transient_liveness_blip_does_not_trip_engineGone() {
    // A single .gone followed by .alive must NOT fail: the monitor
    // requires `livenessFailureThreshold` CONSECUTIVE gone probes, so
    // a transient blip resets the counter and the engine stays running.
    let session = ScriptedLivenessSession([.gone(reason: "blip"), .alive])
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(40405), session: session) },
      livenessInterval: 0.02,
      livenessFailureThreshold: 2
    )
    let running = expectation(description: ".running")
    var sawFailed = false
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
      if case .failed = status { sawFailed = true }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    // Let many monitor ticks elapse (interval 20ms).
    let settle = expectation(description: "settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { settle.fulfill() }
    wait(for: [settle], timeout: 2)
    XCTAssertFalse(sawFailed, "a single transient .gone must not trip engine-gone")
    token.cancel()
    host.stop()
  }

  func test_stop_cancels_liveness_monitor_no_spurious_engineGone() {
    // After stop(), the monitor must not later flip a stopped host to
    // .failed(.engineGone) even if the session would report gone.
    //
    // The session stays .alive until AFTER stop(), so an engine-gone flip
    // can only come from a monitor that wrongly survived stop(). The old
    // script ([.alive, .gone]) raced: with threshold 1 the .gone probe
    // could land BEFORE stop() and trip a legitimate engine-gone — both
    // failing the assertion and starving the .stopped expectation.
    let session = ControllableLivenessSession(.alive)
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(40406), session: session) },
      livenessInterval: 0.02,
      livenessFailureThreshold: 1
    )
    let running = expectation(description: ".running")
    let stopped = expectation(description: ".stopped")
    var hitRunning = false
    var hitStopped = false
    var sawEngineGone = false
    let token = host.observe { status, _ in
      if case .running = status, !hitRunning { hitRunning = true; running.fulfill() }
      if hitRunning, case .stopped = status, !hitStopped { hitStopped = true; stopped.fulfill() }
      if case .failed(.engineGone, _) = status { sawEngineGone = true }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    host.stop()
    wait(for: [stopped], timeout: 2)
    // Only now would the session report gone — a correctly cancelled
    // monitor has already stopped probing and must never observe it.
    session.set(.gone(reason: "post-stop"))
    let settle = expectation(description: "settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
    wait(for: [settle], timeout: 2)
    XCTAssertFalse(sawEngineGone, "monitor must not flip a stopped host to engine-gone")
    token.cancel()
  }
}
