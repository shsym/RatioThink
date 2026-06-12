import XCTest
@testable import RatioThinkCore

final class HelperQuitTeardownTests: XCTestCase {
  private final class HangingSession: PieEngineHost.EngineSession, @unchecked Sendable {
    func shutdown() async -> EngineShutdownResult {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      return .unreaped("test session did not reap")
    }
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

  func test_timeoutReportsButDoesNotTerminateHelper() {
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(5152), session: HangingSession()) })
    defer { host.stop() }

    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    token.cancel()

    let timeoutReported = expectation(description: "initial timeout is reported")
    let terminated = expectation(description: "helper must not terminate while pie may still be alive")
    terminated.isInverted = true
    HelperQuitTeardown.stopThenTerminate(
      engineHost: host,
      initialTimeout: 0.05,
      onTimeout: { result in
        XCTAssertFalse(result.reachedTerminal)
        XCTAssertEqual(result.lastStatus, .stopping)
        timeoutReported.fulfill()
      },
      terminate: { terminated.fulfill() }
    )

    wait(for: [timeoutReported, terminated], timeout: 0.5)
  }

  func test_terminalBeforeTimeoutTerminatesHelper() {
    final class FastSession: PieEngineHost.EngineSession, @unchecked Sendable {
      func shutdown() async -> EngineShutdownResult { .reaped }
    }
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(5153), session: FastSession()) })
    defer { host.stop() }

    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    token.cancel()

    let terminated = expectation(description: "terminal stop terminates helper")
    HelperQuitTeardown.stopThenTerminate(
      engineHost: host,
      initialTimeout: 2,
      onTerminalBeforeTimeout: { result in
        XCTAssertTrue(result.reachedTerminal)
      },
      terminate: { terminated.fulfill() }
    )

    wait(for: [terminated], timeout: 2)
  }

  func test_terminalFailureReportsButDoesNotTerminateHelper() {
    final class UnreapedSession: PieEngineHost.EngineSession, @unchecked Sendable {
      func shutdown() async -> EngineShutdownResult {
        .unreaped("SIGKILL did not reap")
      }
    }
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(5155), session: UnreapedSession()) })
    defer { host.stop() }

    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    wait(for: [running], timeout: 2)
    token.cancel()

    let failureReported = expectation(description: "terminal failure is reported")
    let terminated = expectation(description: "helper must not terminate after failed reap")
    terminated.isInverted = true
    HelperQuitTeardown.stopThenTerminate(
      engineHost: host,
      initialTimeout: 2,
      onTerminalFailure: { result in
        XCTAssertTrue(result.failedBeforeReap)
        XCTAssertFalse(result.reachedTerminal)
        XCTAssertEqual(result.lastStatus, .failed(code: .killRejected, message: "SIGKILL did not reap"))
        failureReported.fulfill()
      },
      terminate: { terminated.fulfill() }
    )

    wait(for: [failureReported, terminated], timeout: 2)
  }
}
