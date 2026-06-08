import XCTest
@testable import RatioThinkCore
import Foundation

/// #447 — `LaunchError.engineExitedEarly` must carry `terminationReason` so a
/// signal death (e.g. SIGSEGV) is never read as an exit code of the same
/// number, and its `description` must render which.
final class PieControlLauncherTerminationTests: XCTestCase {

  func test_engineExitedEarly_carriesTerminationReason() {
    let e = PieControlLauncher.LaunchError.engineExitedEarly(
      code: 11, reason: .uncaughtSignal, stderrTail: "boom")
    guard case let .engineExitedEarly(code, reason, tail, rssBytes) = e else {
      return XCTFail("wrong case")
    }
    XCTAssertEqual(code, 11)
    XCTAssertEqual(reason, .uncaughtSignal)
    XCTAssertEqual(tail, "boom")
    XCTAssertNil(rssBytes)
  }

  func test_description_signalDeath_rendersSignalName_notExitCode() {
    let e = PieControlLauncher.LaunchError.engineExitedEarly(
      code: SIGSEGV, reason: .uncaughtSignal, stderrTail: "")
    XCTAssertTrue(e.description.contains("signal=11"), e.description)
    XCTAssertTrue(e.description.contains("SIGSEGV"), e.description)
    XCTAssertFalse(e.description.contains("code=11"), e.description)
  }

  func test_description_cleanExit_rendersExitCode() {
    let e = PieControlLauncher.LaunchError.engineExitedEarly(
      code: 1, reason: .exit, stderrTail: "")
    XCTAssertTrue(e.description.contains("code=1"), e.description)
    XCTAssertFalse(e.description.contains("signal="), e.description)
  }
}
