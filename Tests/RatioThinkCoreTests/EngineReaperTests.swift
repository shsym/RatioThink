import XCTest
import Foundation
import Darwin
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

  // MARK: - live (real process) backstop proof

  /// Spawn a REAL long-lived child, record it as the owned engine, then prove
  /// the reap-before-spawn backstop actually KILLS it via the production
  /// `kill`/`proc_pidpath` path (no injected probes). This is the end-to-end
  /// "an orphan from a dead Helper is reaped on the next launch" guarantee.
  func test_reapStale_killsRealOrphanedProcess() throws {
    try withTempHome {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
      proc.arguments = ["30"]
      try proc.run()
      let pid = proc.processIdentifier
      defer { if proc.isRunning { kill(pid, SIGKILL) } }  // safety net

      // Record it exactly as the launcher would (own group + real path).
      _ = setpgid(pid, pid)
      EngineReaper.own(pid: pid, pgid: pid, binaryPath: "/bin/sleep")
      XCTAssertTrue(EngineReaper.processIsAlive(pid))

      // Production probes — real identity gate against /bin/sleep.
      let reaped = EngineReaper.reapStaleOwnedProcess(expectedBinaryPath: "/bin/sleep")
      XCTAssertEqual(reaped, pid)

      // The child must actually die.
      var alive = true
      for _ in 0..<100 where alive {
        if !EngineReaper.processIsAlive(pid) { alive = false; break }
        usleep(20_000)
      }
      proc.waitUntilExit()  // reap the zombie so the assertion is clean
      XCTAssertFalse(EngineReaper.processIsAlive(pid), "real orphan must be reaped")
    }
  }

  /// The identity gate must SPARE a real process whose path differs from the
  /// recorded engine binary (pid reuse): record `/bin/sleep`'s live pid under a
  /// bogus binary path, and confirm the backstop does NOT kill it.
  func test_reapStale_sparesRealProcess_onIdentityMismatch() throws {
    try withTempHome {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
      proc.arguments = ["30"]
      try proc.run()
      let pid = proc.processIdentifier
      defer { kill(pid, SIGKILL); proc.waitUntilExit() }

      EngineReaper.own(pid: pid, pgid: 0, binaryPath: "/Apps/Rational.app/pie")
      // The live pid maps to /bin/sleep, not the recorded pie binary → spared.
      let reaped = EngineReaper.reapStaleOwnedProcess(expectedBinaryPath: "/Apps/Rational.app/pie")
      XCTAssertNil(reaped)
      XCTAssertTrue(EngineReaper.processIsAlive(pid), "a non-matching live pid must be spared")
    }
  }
}
