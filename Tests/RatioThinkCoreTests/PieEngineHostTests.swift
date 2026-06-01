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

  // MARK: - double-start rejected

  func test_double_start_returns_alreadyRunning() {
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
