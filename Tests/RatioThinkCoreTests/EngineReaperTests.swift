import XCTest
import Foundation
@testable import RatioThinkCore

/// regression — OS-enforced single-owner engine teardown. The invariant is
/// that no `pie` outlives its owning Helper; the reap-before-spawn BACKSTOP is
/// what closes the one uncatchable case (SIGKILL of the Helper) on the next
/// launch. These tests pin that backstop's logic (the part that decides whether
/// to kill, and that it never kills a recycled pid) with injected probes, so the
/// real-process end of it (the leak count before/after a quit+relaunch cycle)
/// can stay an integration check.
final class EngineReaperTests: XCTestCase {

  /// Isolate PieDirs (and thus `engine.pid`) into a temp dir per test.
  private func withTempHome(_ body: () throws -> Void) rethrows {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("rt-reaper-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try PieDirs.$homeOverride.withValue(tmp) {
      EngineReaper.release()  // clean slate
      try body()
    }
  }

  func test_own_persistsPidFile_andRelease_removesIt() throws {
    try withTempHome {
      EngineReaper.own(pid: 4242, pgid: 4242, binaryPath: "/Apps/Rational.app/pie")
      let url = try XCTUnwrap(EngineReaper.pidFileURL())
      let raw = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(raw.hasPrefix("4242 4242 /Apps/Rational.app/pie"), "got: \(raw)")
      EngineReaper.release()
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
  }

  /// BACKSTOP fires: the recorded pid is alive AND still maps to the recorded
  /// pie binary → it is killed, and the durable record is cleared.
  func test_reapStale_killsLiveOwnedPid_whenIdentityMatches() throws {
    try withTempHome {
      EngineReaper.own(pid: 4242, pgid: 0, binaryPath: "/Apps/Rational.app/pie")
      var killed: Int32?
      // Inject identity probes so no real process is touched.
      let reaped = EngineReaper.reapStaleOwnedProcess(
        expectedBinaryPath: "/Apps/Rational.app/pie",
        isAlive: { _ in true },
        pathOf: { pid in killed = pid; return "/Apps/Rational.app/pie" }
      )
      XCTAssertEqual(reaped, 4242)
      XCTAssertEqual(killed, 4242)
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: try XCTUnwrap(EngineReaper.pidFileURL()).path),
        "record cleared after a backstop reap")
    }
  }

  /// pid REUSE guard: the recorded pid is alive but now maps to a DIFFERENT
  /// executable → it must NOT be killed (an innocent process recycled the pid).
  func test_reapStale_doesNotKillRecycledPid() throws {
    try withTempHome {
      EngineReaper.own(pid: 4242, pgid: 0, binaryPath: "/Apps/Rational.app/pie")
      let reaped = EngineReaper.reapStaleOwnedProcess(
        expectedBinaryPath: "/Apps/Rational.app/pie",
        isAlive: { _ in true },
        pathOf: { _ in "/usr/bin/totally-unrelated" }
      )
      XCTAssertNil(reaped, "a recycled pid (different binary) must be spared")
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: try XCTUnwrap(EngineReaper.pidFileURL()).path))
    }
  }

  /// A dead recorded pid is a no-op, and the stale record is cleared.
  func test_reapStale_noOp_whenOwnedPidDead() throws {
    try withTempHome {
      EngineReaper.own(pid: 4242, pgid: 0, binaryPath: "/Apps/Rational.app/pie")
      let reaped = EngineReaper.reapStaleOwnedProcess(
        expectedBinaryPath: "/Apps/Rational.app/pie",
        isAlive: { _ in false },
        pathOf: { _ in nil }
      )
      XCTAssertNil(reaped)
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: try XCTUnwrap(EngineReaper.pidFileURL()).path))
    }
  }

  /// No record → nothing to reap.
  func test_reapStale_noRecord_returnsNil() throws {
    try withTempHome {
      XCTAssertNil(EngineReaper.reapStaleOwnedProcess(isAlive: { _ in true }))
    }
  }
}
