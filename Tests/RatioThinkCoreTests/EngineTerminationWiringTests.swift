import XCTest
import os
@testable import RatioThinkCore
import Foundation

/// #447 — proves the PieEngineHost wiring threads the captured death evidence
/// into the injected termination sink + tail writer at the liveness-death
/// site, with the correct cause/initiator classification.
@available(macOS 14, *)
@MainActor
final class EngineTerminationWiringTests: XCTestCase {

  // MARK: - liveness self-death → structured breadcrumb

  func test_livenessSelfDeath_segfault_emitsStructuredTermination() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let capturedTail = OSAllocatedUnfairLock<[String]>(initialState: [])
    let got = expectation(description: "termination captured")

    let session = ExitingSession(
      snapshot: (.uncaughtSignal, SIGSEGV),
      tail: ["internal token: <REDACTED>", "thread 'main' panicked", "segfault"])
    let launcher: PieEngineHost.LauncherCall = { _ in
      (port: EnginePort(61001), session: session)
    }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 0.02,
      livenessFailureThreshold: 1,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in
        captured.withLock { $0 = t }
        got.fulfill()
      },
      tailWriter: { lines in capturedTail.withLock { $0 = lines } },
      guardrailBytes: 8_000_000_000)

    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)
    host.stop()

    let t = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(t.cause, .segfault)
    XCTAssertEqual(t.initiator, .engine)
    XCTAssertEqual(t.signal, SIGSEGV)
    XCTAssertEqual(capturedTail.withLock { $0 }, session.tail)
  }

  func test_livenessSelfDeath_SIGKILL_aboveGuardrail_isLikelyOOM() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let got = expectation(description: "termination captured")
    let session = ExitingSession(snapshot: (.uncaughtSignal, SIGKILL),
                                 tail: [], rss: 9_000_000_000)
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(61002), session: session) },
      livenessInterval: 0.02, livenessFailureThreshold: 1,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in captured.withLock { $0 = t }; got.fulfill() },
      guardrailBytes: 8_000_000_000)
    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)
    host.stop()
    XCTAssertEqual(captured.withLock { $0 }?.cause, .oom)
  }

  func test_livenessFirstTickGone_SIGKILL_aboveGuardrail_isLikelyOOM() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let got = expectation(description: "termination captured")
    let session = GoneImmediatelySession(snapshot: (.uncaughtSignal, SIGKILL),
                                         rss: 8_000_000_000)
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(61012), session: session) },
      livenessInterval: 0.02, livenessFailureThreshold: 1,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in captured.withLock { $0 = t }; got.fulfill() },
      guardrailBytes: 8_000_000_000)
    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)
    host.stop()

    let t = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(t.cause, .oom)
    XCTAssertEqual(t.initiator, .engine)
    XCTAssertEqual(t.rssBytes, 8_000_000_000)
  }

  func test_controlPlaneHang_processAlive_isLivenessFailure() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let got = expectation(description: "termination captured")
    // snapshot nil ⇒ process still running, control plane unreachable.
    let session = ExitingSession(snapshot: nil, tail: [])
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(61003), session: session) },
      livenessInterval: 0.02, livenessFailureThreshold: 1,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in captured.withLock { $0 = t }; got.fulfill() },
      guardrailBytes: 8_000_000_000)
    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)
    host.stop()
    let t = captured.withLock { $0 }
    XCTAssertEqual(t?.cause, .livenessFailure)
    XCTAssertEqual(t?.initiator, .liveness)
  }

  func test_noSinkWired_doesNotCrash() async throws {
    // Default nil sinks: a death must not emit / crash (keeps existing tests
    // free of real-dir pollution).
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(61004), session: ExitingSession(snapshot: (.exit, 0), tail: [])) },
      livenessInterval: 0.02, livenessFailureThreshold: 1,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0))
    let gone = expectation(description: ".failed(.engineGone)")
    let token = host.observe { status, _ in
      if case .failed(.engineGone, _) = status { gone.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [gone], timeout: 3)
    token.cancel(); host.stop()
  }

  // MARK: - launch failure → classified termination, initiator .launch

  func test_launchFailure_engineExitedEarly_classifiesBySignal() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let tail = OSAllocatedUnfairLock<[String]>(initialState: [])
    let got = expectation(description: "termination captured")
    let launcher: PieEngineHost.LauncherCall = { _ in
      throw PieControlLauncher.LaunchError.engineExitedEarly(
        code: SIGSEGV, reason: .uncaughtSignal, stderrTail: "trace a\ntrace b")
    }
    let host = PieEngineHost(
      launcher: launcher, livenessInterval: 0,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in captured.withLock { $0 = t }; got.fulfill() },
      tailWriter: { lines in tail.withLock { $0 = lines } },
      guardrailBytes: 8_000_000_000)
    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)
    let t = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(t.cause, .segfault)
    XCTAssertEqual(t.initiator, .launch)
    XCTAssertEqual(tail.withLock { $0 }, ["trace a", "trace b"])
  }

  func test_launchFailure_SIGKILL_withEarlyRSSAboveGuardrail_isLikelyOOM() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let got = expectation(description: "termination captured")
    let launcher: PieEngineHost.LauncherCall = { _ in
      throw PieControlLauncher.LaunchError.engineExitedEarly(
        code: SIGKILL,
        reason: .uncaughtSignal,
        stderrTail: "rss at death",
        rssBytes: 8_000_000_000)
    }
    let host = PieEngineHost(
      launcher: launcher, livenessInterval: 0,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in captured.withLock { $0 = t }; got.fulfill() },
      guardrailBytes: 8_000_000_000)
    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)

    let t = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(t.cause, .oom)
    XCTAssertEqual(t.initiator, .launch)
    XCTAssertEqual(t.rssBytes, 8_000_000_000)
  }

  func test_launchFailure_handshakeTimeout_isHandshakeTimeout() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let got = expectation(description: "termination captured")
    let launcher: PieEngineHost.LauncherCall = { _ in
      throw PieControlLauncher.LaunchError.handshakeTimeout(
        elapsed: 30, lastLines: ["last1", "last2"])
    }
    let host = PieEngineHost(
      launcher: launcher, livenessInterval: 0,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in captured.withLock { $0 = t }; got.fulfill() })
    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 3)
    let t = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(t.cause, .handshakeTimeout)
    XCTAssertEqual(t.initiator, .launch)
  }

  func test_launchFailure_missingBinary_doesNotEmitEngineTermination() async throws {
    try await assertNoLaunchTermination(
      throwing: PieControlLauncher.LaunchError.pieBinaryMissing(path: "/tmp/no-pie"))
  }

  func test_launchFailure_driverUnsupported_doesNotEmitEngineTermination() async throws {
    try await assertNoLaunchTermination(
      throwing: PieControlLauncher.LaunchError.driverUnsupported(
        requested: "metal",
        binary: "/tmp/pie",
        details: "not built"))
  }

  func test_launchFailure_configSetup_doesNotEmitEngineTermination() async throws {
    try await assertNoLaunchTermination(
      throwing: PieControlLauncher.LaunchError.configWriteFailed(
        path: "/tmp/pie/config.toml",
        underlying: "permission denied"))
  }

  func test_lifetimeTailerKeepsPostHandshakeStderrForLivenessTailWriter() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-tail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let script = tmp.appendingPathComponent("stub-pie")
    let unique = "post-handshake-stderr-\(UUID().uuidString)"
    try """
    #!/bin/sh
    echo "pie-server serving on 127.0.0.1:1"
    echo "internal token: stub-token-deadbeef"
    sleep 0.10
    echo "\(unique)" >&2
    exit 9
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)

    let capturedTail = OSAllocatedUnfairLock<[String]>(initialState: [])
    let got = expectation(description: "tail captured")
    let launcher: PieEngineHost.LauncherCall = { spec in
      let proc = Process()
      proc.executableURL = script
      let pipe = Pipe()
      proc.standardOutput = pipe
      proc.standardError = pipe
      try proc.run()
      let session = LaunchedSession(
        process: proc,
        stdout: pipe,
        shmemName: spec.shmemName,
        pieHome: spec.pieHome)
      _ = try await session.awaitHandshake(timeout: 3)
      return (port: EnginePort(61013), session: session)
    }
    let host = PieEngineHost(
      launcher: launcher,
      livenessInterval: 0.02,
      livenessFailureThreshold: 1,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { _ in },
      tailWriter: { lines in
        capturedTail.withLock { $0 = lines }
        got.fulfill()
      })

    _ = host.start(makeSpec())
    await fulfillment(of: [got], timeout: 5)
    host.stop()

    XCTAssertTrue(capturedTail.withLock { $0 }.contains(unique),
                  "post-handshake stderr must keep draining until process EOF/shutdown")
  }

  func test_diagnosticTailImmediatelyAfterDeathDrainsQueuedPostHandshakeStderr() async throws {
    let tmp = try makeTempDir(prefix: "pie-tail-immediate")
    let script = tmp.appendingPathComponent("stub-pie")
    let unique = "immediate-post-handshake-stderr-\(UUID().uuidString)"
    try """
    #!/bin/sh
    echo "pie-server serving on 127.0.0.1:1"
    echo "internal token: stub-token-deadbeef"
    echo "\(unique)" >&2
    exit 7
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)

    let proc = Process()
    proc.executableURL = script
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stdout
    try proc.run()
    let session = LaunchedSession(
      process: proc,
      stdout: stdout,
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      pieHome: tmp.appendingPathComponent("home"))

    do {
      _ = try await session.awaitHandshake(timeout: 3)
    } catch let error as PieControlLauncher.LaunchError {
      guard case .engineExitedEarly = error else {
        throw error
      }
    }
    proc.waitUntilExit()

    let tail = await session.diagnosticTail()
    await session.shutdown()
    XCTAssertTrue(tail.contains(unique),
                  "diagnosticTail() must drain queued post-handshake stderr deterministically after death")
  }

  func test_awaitHandshake_lateSubscriberAfterNoOutputExit_reportsEngineExitedEarly() async throws {
    let tmp = try makeTempDir(prefix: "pie-no-output-exit")
    let script = tmp.appendingPathComponent("stub-pie")
    try """
    #!/bin/sh
    exit 42
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)

    let proc = Process()
    proc.executableURL = script
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stdout
    try proc.run()
    let session = LaunchedSession(
      process: proc,
      stdout: stdout,
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      pieHome: tmp.appendingPathComponent("home"))

    proc.waitUntilExit()
    try await waitUntilOutputTailFinished(session)

    let started = Date()
    do {
      _ = try await session.awaitHandshake(timeout: 5)
      XCTFail("no-output early exit must not handshake")
    } catch let error as PieControlLauncher.LaunchError {
      guard case let .engineExitedEarly(code, reason, tail, _) = error else {
        return XCTFail("expected engineExitedEarly, got \(error)")
      }
      XCTAssertEqual(code, 42)
      XCTAssertEqual(reason, .exit)
      XCTAssertEqual(tail, "")
      XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                        "late subscriber to already-finished output must not wait for handshake timeout")
    }
    await session.shutdown()
  }

  func test_diagnosticTail_finishesSharedCarryForUnterminatedPostHandshakeStderr() async throws {
    let tmp = try makeTempDir(prefix: "pie-tail-unterminated")
    let script = tmp.appendingPathComponent("stub-pie")
    let flag = tmp.appendingPathComponent("stderr-written.flag")
    let unique = "unterminated-post-handshake-stderr-\(UUID().uuidString)"
    try """
    #!/bin/sh
    echo "pie-server serving on 127.0.0.1:1"
    echo "internal token: stub-token-deadbeef"
    printf "\(unique)" >&2
    touch "\(flag.path)"
    sleep 0.10
    exit 7
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)

    let proc = Process()
    proc.executableURL = script
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stdout
    try proc.run()
    let session = LaunchedSession(
      process: proc,
      stdout: stdout,
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      pieHome: tmp.appendingPathComponent("home"))

    _ = try await session.awaitHandshake(timeout: 3)
    try await waitForFile(flag)
    proc.waitUntilExit()

    let tail = await session.diagnosticTail()
    await session.shutdown()
    XCTAssertTrue(tail.contains(unique),
                  "diagnosticTail() must finish the same carry used by the output tailer")
  }

  func test_launcherOwnedHandshakeTimeoutRefreshesTailAfterCleanup() async throws {
    let tmp = try makeTempDir(prefix: "pie-handshake-timeout-refresh")
    let script = tmp.appendingPathComponent("stub-pie")
    let marker = tmp.appendingPathComponent("ready.flag")
    let unique = "shutdown-drained-timeout-tail-\(UUID().uuidString)"
    try """
    #!/bin/sh
    trap '/bin/echo "\(unique)" >&2; exit 0' INT TERM
    touch "\(marker.path)"
    sleep 30 &
    child=$!
    wait "$child"
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)
    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: script,
      wasmURL: tmp.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tmp.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      // Cleanup fires SIGINT at `handshakeTimeout`. It must outlast `/bin/sh`
      // startup so the stub's `trap … INT TERM` is installed before the signal
      // lands; an earlier SIGINT hits the still-starting shell with the default
      // action, killing it uncaught (no trap, empty stderr) and making the
      // refresh assertion vacuously fail. Production never races this — the
      // 30s default handshake timeout always outlasts pie's signal-handler
      // arming — so a generous fixture budget (0.05s/0.5s flaked under load)
      // faithfully models that ordering.
      handshakeTimeout: 3.0,
      profileID: "test-profile",
      modelConfig: .dummy)

    do {
      let (_, session) = try await PieControlLauncher.launch(spec: spec)
      await session.shutdown()
      XCTFail("stub must not handshake")
    } catch let error as PieControlLauncher.LaunchError {
      guard case let .handshakeTimeout(_, lastLines) = error else {
        return XCTFail("expected refreshed handshakeTimeout, got \(error)")
      }
      XCTAssertTrue(lastLines.contains(unique),
                    "launcher-owned timeout must refresh lastLines after cleanup; got \(lastLines)")
    }
  }

  func test_liveNoisyOutputTailerFinishIsBounded() async throws {
    let tmp = try makeTempDir(prefix: "pie-noisy-live-drain")
    let script = tmp.appendingPathComponent("stub-pie")
    let marker = tmp.appendingPathComponent("ready.flag")
    let unique = "noisy-live-drain-\(UUID().uuidString)"
    try """
    #!/bin/sh
    trap '' INT TERM
    touch "\(marker.path)"
    while :; do
      /bin/echo "\(unique)" >&2
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)

    let proc = Process()
    proc.executableURL = script
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stdout
    try proc.run()
    defer {
      Darwin.kill(proc.processIdentifier, SIGKILL)
      proc.waitUntilExit()
    }
    try await waitForFile(marker)
    let session = LaunchedSession(
      process: proc,
      stdout: stdout,
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      pieHome: tmp.appendingPathComponent("home"))

    XCTAssertTrue(proc.isRunning)
    let started = Date()
    _ = await session.finishOutputTailerBeforeCloseForTesting()
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                      "finishing a still-running noisy tailer must be a bounded best-effort drain")
  }

  func test_launchClientErrorCausedByPostHandshakeSelfDeathPreservesSignalAndTail() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-client-death-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let script = tmp.appendingPathComponent("stub-pie")
    let unique = "client-path-post-handshake-stderr-\(UUID().uuidString)"
    try """
    #!/bin/sh
    echo "pie-server serving on 127.0.0.1:1"
    echo "internal token: stub-token-deadbeef"
    sleep 0.05
    echo "\(unique)" >&2
    kill -s SEGV $$
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)
    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: script,
      wasmURL: tmp.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tmp.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: "test-profile",
      modelConfig: .dummy)

    do {
      let (_, session) = try await PieControlLauncher.launch(spec: spec)
      await session.shutdown()
      XCTFail("stub must die before client install can complete")
    } catch let error as PieControlLauncher.LaunchError {
      guard case let .engineExitedEarly(code, reason, tail, _) = error else {
        return XCTFail("expected post-handshake self-death to preserve engineExitedEarly, got \(error)")
      }
      XCTAssertEqual(reason, .uncaughtSignal)
      XCTAssertEqual(code, SIGSEGV)
      XCTAssertTrue(tail.contains(unique), tail)
    }
  }

  func test_launchClientWindow_SIGKILL_usesLifetimeRSSSamplerForOOM() async throws {
    let tmp = try makeTempDir(prefix: "pie-launch-oom")
    let script = tmp.appendingPathComponent("stub-pie")
    try """
    #!/bin/sh
    echo "pie-server serving on 127.0.0.1:1"
    echo "internal token: stub-token-deadbeef"
    sleep 0.15
    echo "launch-window sigkill" >&2
    kill -9 $$
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let got = expectation(description: "termination captured")
    let host = PieEngineHost(
      launcher: { spec in
        let result = try await PieControlLauncher.launch(spec: spec)
        return (port: EnginePort(result.httpPort), session: result.session)
      },
      livenessInterval: 0,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { t in
        captured.withLock { $0 = t }
        got.fulfill()
      },
      guardrailBytes: 8_000_000_000)
    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: script,
      wasmURL: tmp.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tmp.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: "test-profile",
      modelConfig: .dummy)

    await LaunchedSession.withResidentMemorySamplerForTesting({ _ in 9_000_000_000 }) {
      _ = host.start(spec)
      await fulfillment(of: [got], timeout: 3)
    }

    let t = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(t.cause, .oom)
    XCTAssertEqual(t.initiator, .launch)
    XCTAssertEqual(t.rssBytes, 9_000_000_000)
  }

  // MARK: - stop initiator

  func test_userStop_running_emitsUserStop() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let host = makeRunningHost(terminationSink: { t in captured.withLock { $0 = t } })
    try await reachRunning(host)
    host.stop(initiator: .user)
    XCTAssertEqual(captured.withLock { $0 }?.cause, .userStop)
    XCTAssertEqual(captured.withLock { $0 }?.initiator, .user)
  }

  func test_helperStop_running_emitsHelperShutdown() async throws {
    let captured = OSAllocatedUnfairLock<EngineTermination?>(initialState: nil)
    let host = makeRunningHost(terminationSink: { t in captured.withLock { $0 = t } })
    try await reachRunning(host)
    host.stop(initiator: .helper)
    XCTAssertEqual(captured.withLock { $0 }?.cause, .helperShutdown)
  }

  // MARK: - helpers

  /// Host whose engine stays alive (liveness never fires) so the test can
  /// drive an explicit stop.
  private func makeRunningHost(
    terminationSink: @escaping @Sendable (EngineTermination) -> Void) -> PieEngineHost {
    PieEngineHost(
      launcher: { _ in (port: EnginePort(61009), session: AliveSession()) },
      livenessInterval: 100,  // never ticks during the test
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: terminationSink)
  }

  private func reachRunning(_ host: PieEngineHost) async throws {
    let running = expectation(description: ".running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 3)
    token.cancel()
  }

  private func assertNoLaunchTermination(
    throwing error: PieControlLauncher.LaunchError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let noTermination = expectation(description: "no termination emitted")
    noTermination.isInverted = true
    let failed = expectation(description: ".failed")
    let host = PieEngineHost(
      launcher: { _ in throw error },
      livenessInterval: 0,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 0),
      terminationSink: { _ in noTermination.fulfill() })
    let token = host.observe { status, _ in
      if case .failed = status { failed.fulfill() }
    }

    _ = host.start(makeSpec())
    await fulfillment(of: [failed], timeout: 3)
    await fulfillment(of: [noTermination], timeout: 0.2)
    token.cancel()
  }

  private func makeSpec() -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: "test-profile",
      modelConfig: .dummy)
  }

  private func makeTempDir(prefix: String) throws -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
  }

  private func waitUntilOutputTailFinished(_ session: LaunchedSession) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if await session.outputTailFinishedForTesting() { return }
      await Task.yield()
    }
    XCTFail("output tail did not finish before deadline")
  }

  private func waitForFile(_ url: URL) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: url.path) { return }
      await Task.yield()
    }
    XCTFail("file did not appear before deadline: \(url.path)")
  }
}

/// EngineSession fake that reports one `.alive` tick (so the host samples RSS)
/// then one `.gone` with a configurable exit snapshot + tail, then `.alive`
/// (so the host settles after the first death).
@available(macOS 14, *)
private final class ExitingSession: PieEngineHost.EngineSession, @unchecked Sendable {
  let snapshot: (reason: Process.TerminationReason, status: Int32)?
  let tail: [String]
  let rss: UInt64?
  private let lock = NSLock()
  private var ticks = 0

  init(snapshot: (reason: Process.TerminationReason, status: Int32)?,
       tail: [String], rss: UInt64? = nil) {
    self.snapshot = snapshot; self.tail = tail; self.rss = rss
  }
  func shutdown() async -> EngineShutdownResult { .reaped }
  func checkLiveness() async -> EngineLiveness {
    lock.lock(); defer { lock.unlock() }
    ticks += 1
    // tick 1: alive (host samples RSS); tick 2: gone; thereafter alive.
    if ticks == 2 { return .gone(reason: "synthetic death") }
    return .alive
  }
  func residentMemoryBytes() async -> UInt64? { rss }
  func terminationSnapshot() async -> (reason: Process.TerminationReason, status: Int32)? { snapshot }
  func diagnosticTail() async -> [String] { tail }
}

/// EngineSession fake that is already gone on the first liveness probe. Its
/// RSS is only available through the lifetime-observed sample so the host
/// must not require a prior `.alive` tick to classify SIGKILL as likely OOM.
@available(macOS 14, *)
private final class GoneImmediatelySession: PieEngineHost.EngineSession, @unchecked Sendable {
  let snapshot: (reason: Process.TerminationReason, status: Int32)?
  let rss: UInt64?

  init(snapshot: (reason: Process.TerminationReason, status: Int32)?,
       rss: UInt64?) {
    self.snapshot = snapshot
    self.rss = rss
  }

  func shutdown() async -> EngineShutdownResult { .reaped }
  func checkLiveness() async -> EngineLiveness { .gone(reason: "gone before first alive tick") }
  func observedResidentMemoryBytes() async -> UInt64? { rss }
  func terminationSnapshot() async -> (reason: Process.TerminationReason, status: Int32)? { snapshot }
  func diagnosticTail() async -> [String] { [] }
}

/// Always-alive EngineSession so a test can drive an explicit stop without the
/// liveness monitor racing a synthetic death first.
@available(macOS 14, *)
private final class AliveSession: PieEngineHost.EngineSession, @unchecked Sendable {
  func shutdown() async -> EngineShutdownResult { .reaped }
  func checkLiveness() async -> EngineLiveness { .alive }
}
