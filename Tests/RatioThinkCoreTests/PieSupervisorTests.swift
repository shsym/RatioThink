import XCTest
import os
@testable import RatioThinkCore

/// Lifecycle coverage for `PieSupervisor`. Uses shell-script fakes of
/// the `pie` binary written into a per-test temp dir — no real engine,
/// no network, no PieDirs. Each script ignores its argv (real pie's
/// `--model / --http-listen / --inferlet-dir` triple is supervised but
/// never consumed by the fakes).
final class PieSupervisorTests: XCTestCase {

  private var tempDir: URL!
  private var logURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-supervisor-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDir = dir
    logURL  = dir.appendingPathComponent("engine.log")
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    tempDir = nil
    logURL = nil
    try super.tearDownWithError()
  }

  // MARK: - handshake parser

  func test_parseHandshake_acceptsCanonicalLine() {
    XCTAssertEqual(PieSupervisor.parseHandshake("HTTP_LISTEN=127.0.0.1:54321"), 54321)
    XCTAssertEqual(PieSupervisor.parseHandshake("HTTP_LISTEN=127.0.0.1:54321\n"), 54321)
    XCTAssertEqual(PieSupervisor.parseHandshake("HTTP_LISTEN=::1:8080"), 8080)
  }

  func test_parseHandshake_rejectsMalformed() {
    XCTAssertNil(PieSupervisor.parseHandshake(""))
    XCTAssertNil(PieSupervisor.parseHandshake("HTTP_LISTEN="))
    XCTAssertNil(PieSupervisor.parseHandshake("HTTP_LISTEN=127.0.0.1:0"))
    XCTAssertNil(PieSupervisor.parseHandshake("HTTP_LISTEN=127.0.0.1:99999999"))
    XCTAssertNil(PieSupervisor.parseHandshake("HTTP_LISTEN=:8080"))
    XCTAssertNil(PieSupervisor.parseHandshake("not a handshake"))
  }

  // MARK: - happy path

  func test_happy_emitsRunningWithCapturedPort() throws {
    let fake = try writeScript("pie-happy.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:54321"
      # Stay alive long enough for the test to observe .running and stop us.
      while true; do sleep 60; done
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 1,
                                            restartWindow: 30,
                                            stopGracePeriod: 1))
    let runningExp = expectation(description: ".running observed")
    let token = sup.observe { status, _ in
      if case .running(let port, let profileID) = status {
        XCTAssertEqual(port, 54321)
        XCTAssertEqual(profileID, "chat")
        runningExp.fulfill()
      }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    wait(for: [runningExp], timeout: 5)
    token.cancel()
    sup.stop()
    waitFor(sup, predicate: { if case .stopped = $0 { return true }; return false }, timeout: 5)
  }

  // MARK: - handshake timeout

  func test_noHandshake_givesUpAfterAttempts() throws {
    let fake = try writeScript("pie-silent.sh", body: """
      #!/bin/bash
      # Never prints HTTP_LISTEN. Sleep so the supervisor's handshake
      # timer is what closes the loop, not an immediate exit.
      sleep 120
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 0.4,
                                            restartAttempts: 2,
                                            restartWindow: 30,
                                            stopGracePeriod: 1))
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    let result = waitFor(sup, predicate: { status in
      if case .failed = status { return true }
      return false
    }, timeout: 6)
    guard case .failed(let code, let message)? = result else {
      return XCTFail("expected .failed; got \(String(describing: result))")
    }
    // After cap exhaustion the supervisor reports either the
    // handshake-timeout code (terminal cap path) or a generic
    // spawnFailed if the retry ladder collapsed via the unexpected-exit
    // branch — both are acceptable outcomes for "no handshake ever".
    XCTAssertTrue(code == .handshakeTimeout || code == .spawnFailed,
                  "unexpected code=\(code) message=\(message)")
  }

  // MARK: - immediate failure

  func test_immediateExit_givesUpAfterAttempts() throws {
    let fake = try writeScript("pie-boom.sh", body: """
      #!/bin/bash
      echo "boom: model load failed" 1>&2
      exit 7
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 5,
                                            restartAttempts: 2,
                                            restartWindow: 30,
                                            stopGracePeriod: 1))
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    let result = waitFor(sup, predicate: { status in
      if case .failed = status { return true }
      return false
    }, timeout: 6)
    guard case .failed(let code, _)? = result else {
      return XCTFail("expected .failed; got \(String(describing: result))")
    }
    XCTAssertEqual(code, .spawnFailed)

    // engine.log captured the child's stderr.
    let logged = (try? String(contentsOf: logURL)) ?? ""
    XCTAssertTrue(logged.contains("boom: model load failed"),
                  "engine.log missing stderr; got:\n\(logged)")
  }

  // MARK: - alreadyRunning

  func test_startWhileRunning_returnsAlreadyRunning() throws {
    let fake = try writeScript("pie-stay.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:23456"
      while true; do sleep 60; done
      """)
    let sup = makeSupervisor()
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    waitFor(sup, predicate: { if case .running = $0 { return true }; return false }, timeout: 5)

    let retry = sup.start(makeSpec(binary: fake, profileID: "chat"))
    guard case .failure(let err) = retry else {
      sup.stop()
      return XCTFail("expected .alreadyRunning, got success")
    }
    XCTAssertEqual(err.code, .alreadyRunning)
    sup.stop()
    waitFor(sup, predicate: { if case .stopped = $0 { return true }; return false }, timeout: 5)
  }

  // MARK: - F1: stop during backoff window short-circuits retry

  func test_stopDuringBackoff_keepsSupervisorStopped() throws {
    let fake = try writeScript("pie-silent2.sh", body: """
      #!/bin/bash
      # Never prints HTTP_LISTEN — supervisor will handshake-timeout
      # and schedule a backoff retry.
      sleep 120
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 0.3,
                                            restartAttempts: 3,
                                            restartWindow: 30,
                                            stopGracePeriod: 0.3,
                                            stopOverrun: 0.5,
                                            stdoutCarryLimit: 64 * 1024))
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    // Wait for the supervisor to hit the backoff window (state is
    // .starting between attempts). Sleep long enough for the first
    // handshake timer to fire (0.3s) but not for the 0.25s backoff
    // delay + next spawn to complete.
    Thread.sleep(forTimeInterval: 0.4)
    sup.stop()
    // Allow the cancelled retry's deadline to pass; if F1's guard
    // is missing, spawn() would have been called and the supervisor
    // would have transitioned back to .starting → .running/.failed.
    Thread.sleep(forTimeInterval: 1.0)
    switch sup.status {
    case .stopped, .failed:
      break // both terminal states are acceptable here
    default:
      XCTFail("expected .stopped or .failed after stop during backoff, got \(sup.status)")
    }
  }

  // MARK: - F2: non-existent binary fast-fails (no retry ladder)

  func test_missingBinary_failsImmediatelyWithoutRetries() throws {
    let bogus = tempDir.appendingPathComponent("does-not-exist-binary")
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 5,
                                            restartAttempts: 3,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    let start = Date()
    _ = sup.start(makeSpec(binary: bogus, profileID: "chat"))
    let result = waitFor(sup, predicate: { if case .failed = $0 { return true }; return false },
                         timeout: 1.5)
    let elapsed = Date().timeIntervalSince(start)
    guard case .failed(let code, _)? = result else {
      return XCTFail("expected .failed, got \(String(describing: result))")
    }
    XCTAssertEqual(code, .spawnFailed)
    // Three retries with handshakeTimeout=5 would have taken >15s.
    // Fast-fail surfaces within ~1s.
    XCTAssertLessThan(elapsed, 1.5,
                      "missing-binary should fast-fail, not burn the retry ladder")
  }

  // MARK: - F10: malformed handshake reports immediately

  func test_malformedHandshake_failsImmediately() throws {
    let fake = try writeScript("pie-malformed.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=garbage"
      sleep 30
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 5,
                                            restartAttempts: 1,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    let start = Date()
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    let result = waitFor(sup, predicate: { if case .failed = $0 { return true }; return false },
                         timeout: 4)
    let elapsed = Date().timeIntervalSince(start)
    guard case .failed(let code, let message)? = result else {
      return XCTFail("expected .failed, got \(String(describing: result))")
    }
    XCTAssertEqual(code, .handshakeTimeout)
    XCTAssertTrue(message.contains("malformed") || message.contains("HTTP_LISTEN"),
                  "message should reference the malformed line; got \(message)")
    // Don't wait the full handshakeTimeout — F10 fix surfaces it
    // immediately after parsing.
    XCTAssertLessThan(elapsed, 2.0)
  }

  // MARK: - F10: IPv6 bracketed handshake decodes correctly

  func test_parseHandshake_acceptsIPv6Bracketed() {
    XCTAssertEqual(PieSupervisor.parseHandshake("HTTP_LISTEN=[::1]:8080"), 8080)
    XCTAssertEqual(PieSupervisor.parseHandshake("HTTP_LISTEN=[fe80::1%lo0]:443"), 443)
    XCTAssertNil(PieSupervisor.parseHandshake("HTTP_LISTEN=[::1]"))
    XCTAssertNil(PieSupervisor.parseHandshake("HTTP_LISTEN=[::1]8080"))
  }

  // MARK: - F11: oversized carry kills engine and surfaces failure

  func test_oversizedStdoutCarry_killsAndFails() throws {
    // 200KB of "x" with no newline, then sleep. The supervisor's
    // 64KB cap should fire before the handshake timeout.
    let fake = try writeScript("pie-flood.sh", body: """
      #!/bin/bash
      head -c 200000 < /dev/zero | tr '\\0' 'x'
      sleep 30
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 5,
                                            restartAttempts: 1,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    let result = waitFor(sup, predicate: { if case .failed = $0 { return true }; return false },
                         timeout: 4)
    guard case .failed(let code, let message)? = result else {
      return XCTFail("expected .failed, got \(String(describing: result))")
    }
    XCTAssertEqual(code, .handshakeTimeout)
    XCTAssertTrue(message.contains("64") || message.contains("bytes"),
                  "message should reference the byte cap; got \(message)")
  }

  // MARK: - F29: handshake printed then immediate exit → no spurious .running

  func test_handshakeWithoutNewlineThenExit_neverPublishesRunning() throws {
    // Script prints HTTP_LISTEN= WITHOUT a trailing newline, then
    // exits. `head -c` truncates the echo so no \n leaks through.
    let fake = try writeScript("pie-no-nl.sh", body: """
      #!/bin/bash
      printf '%s' 'HTTP_LISTEN=127.0.0.1:55555'
      exit 0
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 1,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    let runningSeen = OSAllocatedUnfairLock<Bool>(initialState: false)
    let failedExp = expectation(description: ".failed observed")
    let token = sup.observe { status, _ in
      switch status {
      case .running:
        runningSeen.withLock { $0 = true }
      case .failed:
        failedExp.fulfill()
      default: break
      }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    wait(for: [failedExp], timeout: 5)
    token.cancel()
    XCTAssertFalse(runningSeen.withLock { $0 },
                   "final-flush must not publish a transient .running for an already-exited engine")
    if case let .failed(_, msg) = sup.status {
      XCTAssertTrue(msg.contains("printed handshake") || msg.contains("port=55555"),
                    "expected diagnostic to reference the printed handshake; got \(msg)")
    } else {
      XCTFail("expected .failed, got \(sup.status)")
    }
  }

  // MARK: - F39: post-handshake crash consumes the retry ladder

  func test_postHandshakeCrash_retriesPerPolicy() throws {
    // Script prints handshake, sleeps briefly, then exits non-zero.
    // Each attempt must transition through .starting → .running →
    // .failed (live path), then re-spawn until restartAttempts is
    // exhausted. The review v2 F29 fix had collapsed this to a
    // single .failed because inc.handshakePort was set on both the
    // live and flush paths; review v3 F39 reinstates the priorState
    // gate so only flush-detected handshakes short-circuit.
    let fake = try writeScript("pie-postcrash.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:54321"
      sleep 0.1
      exit 9
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 2,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    let runningCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let exp = expectation(description: ".failed after retries")
    let token = sup.observe { status, _ in
      if case .running = status {
        runningCount.withLock { $0 += 1 }
      }
      if case .failed = status { exp.fulfill() }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    wait(for: [exp], timeout: 6)
    token.cancel()
    let n = runningCount.withLock { $0 }
    XCTAssertGreaterThanOrEqual(n, 2,
                                "post-handshake crash must consume restartAttempts (saw \(n) .running transitions; expected ≥2)")
  }

  // MARK: - F40: SIGKILL-reject → .failed(.killRejected); start() refuses

  func test_killRejected_failsWithKillRejectedCode() throws {
    let fake = try writeScript("pie-silent4.sh", body: """
      #!/bin/bash
      # Bounded so the test never leaks a process even when
      # killProcessOverride blocks the real SIGKILL.
      sleep 3
      """)
    let sup = PieSupervisor(
      policy: .init(handshakeTimeout: 0.3,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      killProcessOverride: { _ in false }  // reject every SIGKILL
    )
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    let result = waitFor(sup, predicate: { status in
      if case .failed = status { return true }
      return false
    }, timeout: 3)
    guard case .failed(let code, let msg)? = result else {
      // Manually reap the actual child so tearDown doesn't leak.
      return XCTFail("expected .failed, got \(String(describing: result))")
    }
    XCTAssertEqual(code, .killRejected)
    XCTAssertTrue(msg.contains("SIGKILL") || msg.contains("rejected"),
                  "message should reference SIGKILL/rejected; got \(msg)")
    // Subsequent start() must refuse — engine may still be alive.
    let retry = sup.start(makeSpec(binary: fake, profileID: "chat"))
    guard case .failure(let err) = retry else {
      return XCTFail("expected start() to refuse after .killRejected")
    }
    XCTAssertEqual(err.code, .killRejected)
  }

  // MARK: - F49: slow-flap respects post-handshake crash cap

  func test_slowFlap_eventuallyFailsViaPostHandshakeCap() throws {
    // Sleep AFTER handshake is longer than restartWindow, so the
    // window-based attemptCount cap resets every cycle. Only the
    // separate consecutivePostHandshakeCrashes counter (F49) can
    // terminate the flap.
    let fake = try writeScript("pie-slowflap.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:54321"
      # Sleep longer than restartWindow (0.1s) so the window resets.
      sleep 0.2
      exit 9
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 2,
                                            restartWindow: 0.1,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    let runningCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let exp = expectation(description: ".failed after post-handshake cap")
    let token = sup.observe { status, _ in
      if case .running = status { runningCount.withLock { $0 += 1 } }
      if case .failed = status { exp.fulfill() }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    wait(for: [exp], timeout: 6)
    token.cancel()
    let n = runningCount.withLock { $0 }
    // restartAttempts=2 → at most 2 .running transitions before the
    // post-handshake cap fires. Without F49 fix, the supervisor
    // restarts forever and we'd time out.
    XCTAssertLessThanOrEqual(n, 2,
                              "post-handshake cap should bound restarts; saw \(n) .running")
    if case let .failed(_, msg) = sup.status {
      XCTAssertTrue(msg.contains("slow-flapped") || msg.contains("post-handshake"),
                    "expected slow-flap diagnostic; got \(msg)")
    } else {
      XCTFail("expected .failed, got \(sup.status)")
    }
  }

  // MARK: - F50: clearKillRejected recovery path

  func test_clearKillRejected_refusesWhenZombieAlive() throws {
    // Drive the zombie alive→dead transition through the
    // `livenessOverride` seam instead of waiting on a real `sleep`
    // subprocess to exit AND be wait4-reaped (the arbitrarily-delayed
    // step that made this flake up to the 25s suite timeout under CI
    // load). Entry into `.killRejected` still exercises the real
    // spawn → handshake-timeout → SIGKILL-rejected path, but against
    // a `FakeProcess` that forks no child, so there is nothing to
    // schedule, exit, or reap. The whole alive→dead recovery now runs
    // synchronously and deterministically.
    let alive = OSAllocatedUnfairLock<Bool>(initialState: true)
    let sup = PieSupervisor(
      policy: .init(handshakeTimeout: 0.05,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest.json"),
      processFactory: { FakeProcess() },
      killProcessOverride: { _ in false },         // reject SIGKILL → enter .killRejected
      livenessOverride: { _ in alive.withLock { $0 } }
    )
    _ = sup.start(makeSpec(binary: tempDir.appendingPathComponent("unused-fake-binary"),
                           profileID: "chat"))
    // Reliable entry: the handshake timer (~50ms) fires, SIGKILL is
    // rejected, supervisor enters .killRejected. No real child means
    // this cannot starve under load.
    waitFor(sup, predicate: { if case .failed(.killRejected, _) = $0 { return true }; return false },
            timeout: 5)

    // Override reports the zombie alive → recovery must refuse and
    // stay in .killRejected.
    XCTAssertFalse(sup.clearKillRejected(),
                   "clearKillRejected must refuse while liveness override reports the zombie alive")
    guard case .failed(.killRejected, _) = sup.status else {
      return XCTFail("expected to remain .killRejected after refusal, got \(sup.status)")
    }

    // Flip the override to dead → recovery succeeds synchronously.
    alive.withLock { $0 = false }
    XCTAssertTrue(sup.clearKillRejected(),
                  "clearKillRejected must succeed once liveness override reports the zombie dead")
    guard case .stopped = sup.status else {
      return XCTFail("expected .stopped after successful clearKillRejected, got \(sup.status)")
    }
  }

  // MARK: - F60: healthy uptime resets slow-flap counter

  func test_healthyUptime_resetsSlowFlapCounter() throws {
    // Two-cycle scenario: each cycle prints handshake, sleeps long
    // enough to clear healthyUptimeThreshold, then exits. With
    // restartAttempts=2 and the F60 fix, the second crash should
    // NOT trip the cap because each crash arrives AFTER healthy
    // uptime → counter resets to 1 each time.
    let fake = try writeScript("pie-uptime.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:43210"
      sleep 0.25
      exit 9
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 2,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024,
                                            healthyUptimeThreshold: 0.1))
    let runningCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let token = sup.observe { status, _ in
      if case .running = status { runningCount.withLock { $0 += 1 } }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    // Let two cycles complete. Without the F60 reset, the second
    // crash trips the cap and supervisor goes .failed after 2
    // .running observations. With F60, the counter is reset on
    // every crash so the supervisor keeps cycling.
    Thread.sleep(forTimeInterval: 1.5)
    token.cancel()
    sup.stop()
    let n = runningCount.withLock { $0 }
    XCTAssertGreaterThanOrEqual(n, 2,
                                "F60: healthy-uptime decay should let multiple cycles complete; saw \(n)")
  }

  // MARK: - F61: clearKillRejected from observer handler does not deadlock

  func test_clearKillRejected_safeFromObserverHandler() throws {
    // Review v5 F61: an observer handler runs on the
    // supervisor's stateQueue. Calling clearKillRejected() from
    // inside it must take the queue-affinity inline path and must
    // NOT dispatch_sync-deadlock the queue. The property under test
    // is PURE re-entrancy — it never needed real process timing.
    // Previously it was proven by polling until a real `sleep 0.3`
    // zombie exited and was reaped, which flaked up to the 25s suite
    // timeout under load. Now the `livenessOverride` seam drives the
    // zombie alive→dead synchronously while the clearKillRejected
    // calls are still made re-entrantly from the handler, so the
    // no-deadlock guarantee is exercised on BOTH the refuse path
    // (alive) and the success path (dead).
    let alive = OSAllocatedUnfairLock<Bool>(initialState: true)
    let refusedInlineWhileAlive = OSAllocatedUnfairLock<Bool>(initialState: false)
    let sup = PieSupervisor(
      policy: .init(handshakeTimeout: 0.05,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest.json"),
      processFactory: { FakeProcess() },
      killProcessOverride: { _ in false },
      livenessOverride: { _ in alive.withLock { $0 } }
    )
    // Only the .stopped reached THROUGH the killRejected→clear path
    // is terminal — the supervisor also publishes its initial
    // .stopped to a freshly-registered observer, which must not be
    // mistaken for recovery.
    let sawKillRejected = OSAllocatedUnfairLock<Bool>(initialState: false)
    let exp = expectation(description: "supervisor reached .stopped via observer-driven clearKillRejected")
    let token = sup.observe { status, token in
      if case .failed(.killRejected, _) = status {
        sawKillRejected.withLock { $0 = true }
        // Re-entrant call #1 (zombie alive): must run INLINE and
        // refuse. If the F61 affinity check were missing this would
        // dispatch_sync-deadlock and the test would hang to timeout.
        if sup.clearKillRejected() == false {
          refusedInlineWhileAlive.withLock { $0 = true }
        }
        // Flip to dead, then re-entrant call #2: must run inline and
        // succeed, transitioning to .stopped.
        alive.withLock { $0 = false }
        _ = sup.clearKillRejected()
      }
      if case .stopped = status, sawKillRejected.withLock({ $0 }) {
        token.cancel()
        exp.fulfill()
      }
    }
    _ = sup.start(makeSpec(binary: tempDir.appendingPathComponent("unused-fake-binary"),
                           profileID: "chat"))
    wait(for: [exp], timeout: 5)
    _ = token
    XCTAssertTrue(refusedInlineWhileAlive.withLock { $0 },
                  "clearKillRejected from the observer handler must run inline and refuse while the zombie is alive")
  }

  // MARK: - F62: post-handshake-crash backoff does not publish stale .running

  func test_postHandshakeCrashBackoff_publishesStartingNotStaleRunning() throws {
    let fake = try writeScript("pie-flap.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:54321"
      sleep 0.05
      exit 9
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 3,
                                            restartWindow: 30,
                                            stopGracePeriod: 1,
                                            stopOverrun: 1,
                                            stdoutCarryLimit: 64 * 1024))
    // Log every transition. The retry-backoff window must not
    // carry .running across — F62 publishes .starting before the
    // asyncAfter delay.
    let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    let exp = expectation(description: ".failed observed")
    let token = sup.observe { status, _ in
      let label: String
      switch status {
      case .stopped: label = "stopped"
      case .starting: label = "starting"
      case .running: label = "running"
      case .stopping: label = "stopping"
      case .failed: label = "failed"
      }
      log.withLock { $0.append(label) }
      if case .failed = status { exp.fulfill() }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    wait(for: [exp], timeout: 6)
    token.cancel()
    let seq = log.withLock { $0 }
    // Each cycle should be: starting → running → starting (review
    // v5 F62 publishes this) → running → ... → failed. Adjacent
    // duplicates from initial-observation are allowed (e.g.
    // double-starting at the head). The invariant: no `running`
    // is the IMMEDIATE predecessor of another `running` without
    // an intervening `starting`.
    var hadStaleRunning = false
    for i in 1..<seq.count {
      if seq[i] == "running" && seq[i - 1] == "running" {
        hadStaleRunning = true
        break
      }
    }
    XCTAssertFalse(hadStaleRunning,
                   "two consecutive .running without intervening .starting indicates F62 regression: \(seq)")
  }

  // MARK: - F68: stateQueueKey isolation across supervisor instances

  func test_stateQueueKey_isPerInstance() throws {
    // Drive supervisor A into .killRejected so its observer
    // handler runs on A's stateQueue. Inside A's handler, invoke
    // supervisor B.clearKillRejected(). With a static
    // stateQueueKey, B.performLocked would see A's affinity
    // marker and run B's body INLINE on A's queue, bypassing B's
    // serial invariant. With per-instance keys, B.performLocked
    // hops via .sync onto its own queue.
    //
    // We cannot directly observe whether B ran inline vs hopped,
    // but a static-key supervisor would deadlock B if B's queue
    // is already running other work, OR (more reliably) we can
    // assert no crash and B reaches its expected state.
    let fakeA = try writeScript("pie-aff-a.sh", body: """
      #!/bin/bash
      sleep 1
      """)
    let fakeB = try writeScript("pie-aff-b.sh", body: """
      #!/bin/bash
      sleep 1
      """)
    let supA = PieSupervisor(
      policy: .init(handshakeTimeout: 0.3,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest-a.json"),
      killProcessOverride: { _ in false }
    )
    let supB = PieSupervisor(
      policy: .init(handshakeTimeout: 0.3,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest-b.json"),
      killProcessOverride: { _ in false }
    )
    _ = supA.start(makeSpec(binary: fakeA, profileID: "a"))
    _ = supB.start(makeSpec(binary: fakeB, profileID: "b"))
    // Both supervisors reach .failed(.killRejected) when their
    // handshake timer fires and the killProcessOverride blocks
    // SIGKILL. Wait for both.
    waitFor(supA, predicate: { if case .failed(.killRejected, _) = $0 { return true }; return false }, timeout: 3)
    waitFor(supB, predicate: { if case .failed(.killRejected, _) = $0 { return true }; return false }, timeout: 3)

    // From inside supA's observer (running on supA.stateQueue),
    // call supB.clearKillRejected(). Per F68 isolation it should
    // hop onto supB's stateQueue via .sync (queue affinity for
    // supA != affinity for supB) and not corrupt supB's state.
    let crossExp = expectation(description: "cross-supervisor clearKillRejected returned")
    let crossToken = supA.observe { status, token in
      if case .failed(.killRejected, _) = status {
        // Run cross-instance call. Returns false because supB's
        // zombie (sleep 1) is still alive — the IMPORTANT
        // invariant is that it returns at all rather than
        // hanging due to bypassed serialization.
        _ = supB.clearKillRejected()
        crossExp.fulfill()
        token.cancel()
      }
    }
    wait(for: [crossExp], timeout: 3)
    _ = crossToken
    // Clean up: wait for the bash processes to self-exit so
    // tearDown doesn't leak.
    Thread.sleep(forTimeInterval: 1.2)
  }

  // MARK: - F69: boot recovery reaps orphan engine from prior helper lifetime

  func test_bootRecovery_reapsOrphanFromPersistedManifest() throws {
    // Spawn a real bash sleep we'll treat as the "orphan" left
    // by a prior helper. Write a manifest pointing to its pid,
    // then construct a fresh PieSupervisor with that manifest
    // path — processBootRecovery should send SIGKILL to the pid
    // and unlink the manifest.
    let manifestURL = tempDir.appendingPathComponent("engine.killrejected.json")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    proc.arguments = ["10"]
    try proc.run()
    let pid = proc.processIdentifier
    XCTAssertTrue(proc.isRunning, "orphan must be alive before boot recovery")

    let manifest: [String: Any] = [
      "pid": pid,
      "binaryPath": "/bin/sleep",
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "message": "synthetic orphan from prior helper",
    ]
    // PieSupervisor uses default JSONEncoder strategy (iso8601 for
    // dates is NOT default — let's use Codable directly via the
    // supervisor's encoder shape). Easiest: write a real
    // KillRejectedManifest via the supervisor's helper init.
    // Since KillRejectedManifest is internal, we re-encode via
    // JSON manually with a Date encoded as default Codable
    // (number of seconds since 2001). Match by constructing the
    // supervisor's exact format with a probe supervisor.
    _ = manifest // suppress warning
    let probe = PieSupervisor(logFileURL: logURL,
                              recoveryManifestURL: manifestURL)
    // probe.processBootRecovery already ran but manifest didn't
    // exist yet — write it now.
    let encoded = try JSONEncoder().encode(
      PieSupervisor.KillRejectedManifest(
        pid: pid,
        binaryPath: "/bin/sleep",
        timestamp: Date(),
        message: "test orphan"
      )
    )
    try encoded.write(to: manifestURL, options: .atomic)
    _ = probe

    // Construct a fresh supervisor — processBootRecovery should
    // fire in init, SIGKILL the orphan, and delete the manifest.
    let _ = PieSupervisor(logFileURL: logURL,
                          recoveryManifestURL: manifestURL)

    // Wait for the SIGKILL to land.
    let waitDeadline = Date().addingTimeInterval(3)
    while Date() < waitDeadline && proc.isRunning {
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTAssertFalse(proc.isRunning, "boot recovery should SIGKILL the orphan")
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path),
                   "boot recovery should delete the manifest after processing")
  }

  // MARK: - F79: boot recovery refuses SIGKILL on binary-path mismatch

  func test_bootRecovery_skipsKillWhenBinaryPathDiffers() throws {
    // Spawn a real /bin/sleep, then write a manifest claiming the
    // orphan was "/usr/bin/never-exists" at that pid. F79's
    // proc_pidpath check should see the mismatch, log fault, and
    // delete the manifest WITHOUT sending SIGKILL.
    let manifestURL = tempDir.appendingPathComponent("engine.killrejected.json")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    proc.arguments = ["5"]
    try proc.run()
    let pid = proc.processIdentifier

    let bogusBinary = "/usr/bin/never-exists-pie-engine"
    let manifest = PieSupervisor.KillRejectedManifest(
      pid: pid, binaryPath: bogusBinary,
      timestamp: Date(), message: "fake orphan with wrong path"
    )
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

    _ = PieSupervisor(logFileURL: logURL,
                      recoveryManifestURL: manifestURL)

    // Brief wait so any erroneous SIGKILL would have landed.
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertTrue(proc.isRunning,
                  "boot recovery must NOT SIGKILL when manifest binaryPath disagrees with proc_pidpath")
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path),
                   "manifest should be deleted regardless")
    proc.terminate()
    proc.waitUntilExit()
  }

  // MARK: - F80: stale manifest deleted without SIGKILL

  func test_bootRecovery_skipsKillWhenManifestStale() throws {
    let manifestURL = tempDir.appendingPathComponent("engine.killrejected.json")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    proc.arguments = ["5"]
    try proc.run()
    let pid = proc.processIdentifier

    // Timestamp 7200s in the past — well beyond the default
    // recoveryManifestMaxAge (3600s).
    let stale = Date().addingTimeInterval(-7200)
    let manifest = PieSupervisor.KillRejectedManifest(
      pid: pid, binaryPath: "/bin/sleep",
      timestamp: stale, message: "ancient orphan"
    )
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

    _ = PieSupervisor(logFileURL: logURL,
                      recoveryManifestURL: manifestURL)

    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertTrue(proc.isRunning,
                  "boot recovery must NOT SIGKILL when manifest is stale")
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path),
                   "stale manifest must still be deleted")
    proc.terminate()
    proc.waitUntilExit()
  }

  // MARK: - F87: boot recovery normalizes /private/var symlinks

  func test_canonicalPath_normalizesPrivatePrefix() {
    XCTAssertEqual(PieSupervisor.canonicalPath("/tmp"),
                   PieSupervisor.canonicalPath("/private/tmp"),
                   "/tmp and /private/tmp must canonicalize identically")
    XCTAssertEqual(PieSupervisor.canonicalPath("/var"),
                   PieSupervisor.canonicalPath("/private/var"),
                   "/var and /private/var must canonicalize identically")
  }

  func test_bootRecovery_killsWhenBinaryPathDiffersByPrivatePrefix() throws {
    // macOS symlinks /tmp -> /private/tmp. Copy /bin/sleep into
    // /tmp/<uuid> and spawn it. `proc_pidpath` resolves to the
    // realpath form `/private/tmp/<uuid>`; we write the manifest
    // with the symlinked form `/tmp/<uuid>`. Without F87
    // canonicalization the exact-string compare fails → no
    // SIGKILL. With canonicalization both resolve to
    // `/private/tmp/<uuid>` → match → SIGKILL.
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let symlinkedPath = "/tmp/pietest-sleep-\(uuid)"
    let canonicalPath = "/private/tmp/pietest-sleep-\(uuid)"
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: symlinkedPath)
    defer { try? FileManager.default.removeItem(atPath: canonicalPath) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: symlinkedPath)
    proc.arguments = ["10"]
    try proc.run()
    let pid = proc.processIdentifier

    // Sanity check: proc_pidpath returns the realpath form.
    let pp = PieSupervisor.canonicalPath(symlinkedPath)
    XCTAssertEqual(pp, canonicalPath,
                   "fixture assumption broken: /tmp must symlink-resolve to /private/tmp")

    let manifestURL = tempDir.appendingPathComponent("engine.killrejected.json")
    let manifest = PieSupervisor.KillRejectedManifest(
      pid: pid,
      binaryPath: symlinkedPath,  // symlinked form — pre-F87 disk shape
      timestamp: Date(),
      message: "fixture orphan with non-canonical path"
    )
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

    _ = PieSupervisor(logFileURL: logURL,
                      recoveryManifestURL: manifestURL)

    // Wait for SIGKILL to land.
    let waitDeadline = Date().addingTimeInterval(3)
    while Date() < waitDeadline && proc.isRunning {
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTAssertFalse(proc.isRunning,
                   "F87: boot recovery must reap orphan when manifest path and proc_pidpath differ only by symlink prefix")
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path),
                   "manifest should be deleted regardless")
  }

  // MARK: - stop while running

  func test_stop_transitionsToStopped() throws {
    let fake = try writeScript("pie-stay2.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:23456"
      while true; do sleep 60; done
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 3,
                                            restartAttempts: 1,
                                            restartWindow: 30,
                                            stopGracePeriod: 1))
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    waitFor(sup, predicate: { if case .running = $0 { return true }; return false }, timeout: 5)
    sup.stop()
    let final = waitFor(sup, predicate: { if case .stopped = $0 { return true }; return false }, timeout: 5)
    guard case .stopped? = final else {
      return XCTFail("expected .stopped, got \(String(describing: final))")
    }
  }

  // MARK: - handshake-timer vs reaper race → exit code wins classification

  /// Under load the handshake timer can fire before Foundation reaps a
  /// crash-on-launch child whose `isRunning` (wait4 bookkeeping) still
  /// reads true, so the supervisor stamps a terminal
  /// `.failed(.handshakeTimeout)` and nils `current` first. The child's
  /// real `terminationReason == .exit` must then reclassify that to
  /// `.failed(.spawnFailed)` — a process that exited with its own code
  /// was never an alive-but-silent handshake timeout. Driven through the
  /// `FakeProcess` seam so the timer-wins-then-reaper ordering is
  /// deterministic instead of load-dependent. Fails (stuck on
  /// `.handshakeTimeout`) without the `handleTermination` reclassification.
  func test_handshakeTimerWinsRace_thenRealExitCode_reclassifiesToSpawnFailed() throws {
    let fake = FakeProcess()
    let sup = PieSupervisor(
      policy: .init(handshakeTimeout: 0.05,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest.json"),
      processFactory: { fake },
      killProcessOverride: { _ in true }   // SIGKILL "succeeds" on the zombie
    )
    _ = sup.start(makeSpec(binary: tempDir.appendingPathComponent("unused-fake-binary"),
                           profileID: "chat"))

    // 1. Timer wins: the ~50ms handshake timer fires while FakeProcess
    //    still reports isRunning==true, so the supervisor stamps the
    //    (wrong) terminal handshake timeout and nils `current`.
    let timedOut = waitFor(sup, predicate: {
      if case .failed(.handshakeTimeout, _) = $0 { return true }; return false
    }, timeout: 5)
    guard case .failed(.handshakeTimeout, _)? = timedOut else {
      return XCTFail("precondition: supervisor must first stamp .handshakeTimeout, got \(String(describing: timedOut))")
    }

    // 2. Reaper arrives: the child actually exited on its own with
    //    code 7. terminationReason==.exit must flip the classification.
    fake.deliverTermination(status: 7, reason: .exit)
    let corrected = waitFor(sup, predicate: {
      if case .failed(.spawnFailed, _) = $0 { return true }; return false
    }, timeout: 5)
    guard case .failed(.spawnFailed, _)? = corrected else {
      return XCTFail("a child that exited with code 7 must reclassify .handshakeTimeout → .spawnFailed; got \(String(describing: sup.status))")
    }
  }

  /// Guard the discriminator: a genuinely alive-but-silent engine we
  /// SIGKILL for missing the handshake reports `terminationReason ==
  /// .uncaughtSignal`, and must STAY `.handshakeTimeout` — the
  /// reclassification keys on `.exit`, so it must not fire here.
  func test_handshakeTimeout_killedAliveEngine_staysHandshakeTimeout() throws {
    let fake = FakeProcess()
    let sup = PieSupervisor(
      policy: .init(handshakeTimeout: 0.05,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest.json"),
      processFactory: { fake },
      killProcessOverride: { _ in true }
    )
    _ = sup.start(makeSpec(binary: tempDir.appendingPathComponent("unused-fake-binary"),
                           profileID: "chat"))
    let timedOut = waitFor(sup, predicate: {
      if case .failed(.handshakeTimeout, _) = $0 { return true }; return false
    }, timeout: 5)
    guard case .failed(.handshakeTimeout, _)? = timedOut else {
      return XCTFail("precondition: supervisor must stamp .handshakeTimeout, got \(String(describing: timedOut))")
    }
    // Our SIGKILL of an alive-but-silent engine surfaces as a signal,
    // not a self-exit — this is a real handshake timeout, keep it.
    fake.deliverTermination(status: SIGKILL, reason: .uncaughtSignal)
    // Give the termination work item time to run; the code must not flip.
    Thread.sleep(forTimeInterval: 0.3)
    guard case .failed(.handshakeTimeout, _) = sup.status else {
      return XCTFail("a SIGKILLed alive engine must stay .handshakeTimeout, got \(sup.status)")
    }
  }

  /// Same reaper race as the exit-code case, but the crash-on-launch
  /// child died on a signal it raised itself — a Rust panic aborts with
  /// SIGABRT, a bad load segfaults with SIGSEGV. Foundation reports
  /// `terminationReason == .uncaughtSignal` with the crash signal as the
  /// status. That is a spawn failure, not an alive-but-silent handshake
  /// timeout, and must reclassify `.handshakeTimeout → .spawnFailed`. The
  /// discriminator is the signal: the supervisor's own kill of a live
  /// engine is SIGKILL (the only signal this path sends), so any OTHER
  /// signal is the child crashing on its own.
  func test_handshakeTimerWinsRace_thenSignalCrash_reclassifiesToSpawnFailed() throws {
    let fake = FakeProcess()
    let sup = PieSupervisor(
      policy: .init(handshakeTimeout: 0.05,
                    restartAttempts: 1,
                    restartWindow: 30,
                    stopGracePeriod: 1,
                    stopOverrun: 1,
                    stdoutCarryLimit: 64 * 1024),
      logFileURL: logURL,
      recoveryManifestURL: tempDir.appendingPathComponent("manifest.json"),
      processFactory: { fake },
      killProcessOverride: { _ in true }   // SIGKILL "succeeds" on the zombie
    )
    _ = sup.start(makeSpec(binary: tempDir.appendingPathComponent("unused-fake-binary"),
                           profileID: "chat"))

    // 1. Timer wins: stamps the (wrong) terminal handshake timeout.
    let timedOut = waitFor(sup, predicate: {
      if case .failed(.handshakeTimeout, _) = $0 { return true }; return false
    }, timeout: 5)
    guard case .failed(.handshakeTimeout, _)? = timedOut else {
      return XCTFail("precondition: supervisor must first stamp .handshakeTimeout, got \(String(describing: timedOut))")
    }

    // 2. Reaper arrives: the child actually aborted on its own (SIGABRT).
    //    terminationReason==.uncaughtSignal with a non-SIGKILL status must
    //    flip the classification to .spawnFailed.
    fake.deliverTermination(status: SIGABRT, reason: .uncaughtSignal)
    let corrected = waitFor(sup, predicate: {
      if case .failed(.spawnFailed, _) = $0 { return true }; return false
    }, timeout: 5)
    guard case .failed(.spawnFailed, _)? = corrected else {
      return XCTFail("a child that crashed on SIGABRT must reclassify .handshakeTimeout → .spawnFailed; got \(String(describing: sup.status))")
    }
  }

  // MARK: - helpers

  private func makeSupervisor(policy: PieSupervisor.Policy = .init(handshakeTimeout: 1.0,
                                                                    restartAttempts: 1,
                                                                    restartWindow: 30,
                                                                    stopGracePeriod: 1)) -> PieSupervisor {
    PieSupervisor(policy: policy, logFileURL: logURL)
  }

  private func makeSpec(binary: URL, profileID: String) -> PieSupervisor.LaunchSpec {
    PieSupervisor.LaunchSpec(
      binaryURL: binary,
      modelPath: tempDir.appendingPathComponent("model.gguf").path,
      inferletDir: tempDir.appendingPathComponent("inferlets"),
      inferletName: "chat-apc",
      profileID: profileID
    )
  }

  private func writeScript(_ name: String, body: String) throws -> URL {
    let url = tempDir.appendingPathComponent(name)
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  @discardableResult
  private func waitFor(_ sup: PieSupervisor,
                       predicate: @escaping (EngineStatus) -> Bool,
                       timeout: TimeInterval) -> EngineStatus? {
    let exp = expectation(description: "status predicate")
    var captured: EngineStatus?
    let lock = NSLock()
    let token = sup.observe { status, _ in
      if predicate(status) {
        lock.lock(); defer { lock.unlock() }
        if captured == nil {
          captured = status
          exp.fulfill()
        }
      }
    }
    let result = XCTWaiter.wait(for: [exp], timeout: timeout)
    token.cancel()
    if result != .completed { return nil }
    return captured
  }
}

/// Test double for a `pie` engine process that forks no real
/// child. `Process`/`NSTask` is an abstract class cluster, so a
/// concrete subclass must provide its OWN storage for every property
/// it is asked to set — NSTask.h: "You cannot use this property in a
/// concrete subclass of NSTask which hasn't been updated to include
/// an implementation of the storage and use of it." `PieSupervisor`
/// `spawn` configures (`executableURL`, `arguments`, `environment`,
/// `standardOutput/Error`, `terminationHandler`) and `run()`s it like
/// any process; because `run()` is a no-op, Foundation never invokes
/// the `terminationHandler`, so the incarnation stays `.starting`
/// until the handshake timer fires. With a rejecting
/// `killProcessOverride` that yields a deterministic entry into
/// `.failed(.killRejected)` — no real subprocess to schedule, exit,
/// or wait4-reap, and therefore no wall-clock flake.
private final class FakeProcess: Process, @unchecked Sendable {
  private var _executableURL: URL?
  private var _arguments: [String]?
  private var _environment: [String: String]?
  private var _standardOutput: Any?
  private var _standardError: Any?
  private var _terminationHandler: (@Sendable (Process) -> Void)?

  override var executableURL: URL? {
    get { _executableURL }
    set { _executableURL = newValue }
  }
  override var arguments: [String]? {
    get { _arguments }
    set { _arguments = newValue }
  }
  override var environment: [String: String]? {
    get { _environment }
    set { _environment = newValue }
  }
  override var standardOutput: Any? {
    get { _standardOutput }
    set { _standardOutput = newValue }
  }
  override var standardError: Any? {
    get { _standardError }
    set { _standardError = newValue }
  }
  override var terminationHandler: (@Sendable (Process) -> Void)? {
    get { _terminationHandler }
    set { _terminationHandler = newValue }
  }
  override var processIdentifier: Int32 { 0 }
  // Models an engine that is alive but silent (never prints the
  // handshake) and refuses SIGKILL — the `.killRejected` scenario these
  // tests drive. The supervisor's handshake-timeout handler consults
  // `isRunning` to distinguish a still-running silent engine from an
  // early-exited one, so this must report `true`; a no-op `run()` means
  // there is no real child to ever flip it false.
  override var isRunning: Bool { true }
  override func run() throws {}

  // Foundation publishes the reaped child's exit code/reason here. The
  // base FakeProcess never terminates on its own (`run()` is a no-op);
  // `deliverTermination` lets a test fire the supervisor's
  // terminationHandler with a chosen exit code + reason to reproduce
  // the reaper-races-the-handshake-timer classification path.
  private var _terminationStatus: Int32 = 0
  private var _terminationReason: Process.TerminationReason = .exit
  override var terminationStatus: Int32 { _terminationStatus }
  override var terminationReason: Process.TerminationReason { _terminationReason }

  /// Synchronously invoke the stored `terminationHandler` as Foundation
  /// would after `wait4` reaps the child, with `status` / `reason`
  /// visible through `terminationStatus` / `terminationReason`.
  func deliverTermination(status: Int32, reason: Process.TerminationReason) {
    _terminationStatus = status
    _terminationReason = reason
    _terminationHandler?(self)
  }
}
