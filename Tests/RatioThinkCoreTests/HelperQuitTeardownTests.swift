import XCTest
@testable import RatioThinkCore

final class HelperQuitTeardownTests: XCTestCase {
  private final class HangingSession: PieEngineHost.EngineSession, @unchecked Sendable {
    func shutdown() async {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
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

  func test_appAbsentLocalQuitPolicy_timeoutTerminatesAfterBoundedSecondStage() {
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
    let finalTimeoutReported = expectation(description: "bounded fallback timeout is reported")
    let terminated = expectation(description: "bounded fallback terminates helper")
    HelperQuitTeardown.stopThenTerminate(
      engineHost: host,
      initialTimeout: 0.05,
      timeoutTerminationGrace: 0.05,
      onTimeout: { result in
        XCTAssertFalse(result.reachedTerminal)
        XCTAssertEqual(result.lastStatus, .stopping)
        timeoutReported.fulfill()
      },
      onFinalTimeout: { result in
        XCTAssertFalse(result.reachedTerminal)
        XCTAssertEqual(result.lastStatus, .stopping)
        finalTimeoutReported.fulfill()
      },
      terminate: { terminated.fulfill() }
    )

    wait(for: [timeoutReported, finalTimeoutReported, terminated], timeout: 2)
  }
}
