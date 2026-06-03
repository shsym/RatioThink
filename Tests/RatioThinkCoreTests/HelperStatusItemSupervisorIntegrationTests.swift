import XCTest
import os
@testable import RatioThinkCore

/// End-to-end coverage of the supervisor → model → binding leg
/// without an `NSStatusBar`. Drives `PieSupervisor` with a fake
/// engine shell script and records the projected `HelperStatusItemModel`
/// at every transition. Locks the menu-bar pipeline the helper depends
/// on so a refactor that breaks the EngineStatus → menu-state mapping
/// surfaces here instead of waiting on a seated-console GUI run.
///
/// NOTE: this lives in RatioThinkCoreTests (not PieSupervisorTests) because
/// the assertions are about the menu-bar projection, not the
/// supervisor's own contract. PieSupervisorTests already cover the
/// supervisor states; this file proves the projection composes.
final class HelperStatusItemSupervisorIntegrationTests: XCTestCase {

  private var tempDir: URL!
  private var logURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-statusitem-\(uuid)", isDirectory: true)
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

  // MARK: - happy path: cold boot → running → stopped

  func test_supervisor_transitions_drive_modelStream() throws {
    let fake = try writeScript("pie-stay.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:54321"
      while true; do sleep 60; done
      """)
    let sup = makeSupervisor()
    let recorder = ModelRecorder()
    let token = sup.observe { status, _ in
      recorder.record(HelperStatusItemModel.make(from: status))
    }

    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    recorder.waitForDot(.running, timeout: 5, testCase: self)

    // Drop the observer BEFORE stop() so the post-stop transitions
    // don't race the test's tear-down assertion.
    sup.stop()
    recorder.waitForDot(.stopped, after: .running, timeout: 5, testCase: self)
    token.cancel()

    let dots = recorder.snapshot.map(\.dot)
    // Initial-status dispatch puts `.stopped` at index 0; the rest is
    // the live transition stream. Filter consecutive duplicates so
    // the assertion stays robust against any extra `.starting` /
    // `.running` re-publishes the supervisor may emit during the
    // attempt ladder (it shouldn't, but the test doesn't depend on
    // exact multiplicity).
    let collapsed = dots.reduce(into: [HelperStatusItemModel.Dot]()) { acc, dot in
      if acc.last != dot { acc.append(dot) }
    }
    XCTAssertEqual(collapsed.first, .stopped, "first emit must be initial .stopped")
    XCTAssertTrue(collapsed.contains(.loading), "must transit through .starting (loading dot)")
    XCTAssertTrue(collapsed.contains(.running), "must reach running")
    XCTAssertEqual(collapsed.last, .stopped, "must end at stopped after stop()")

    // Verify the running-state label embeds profile + port — the
    // Phase 2.3 "current model/profile/port" requirement.
    let runningLabel = recorder.snapshot.first { $0.dot == .running }?.engineLabel
    XCTAssertEqual(runningLabel, "Engine: running — chat @ port 54321")

    // Verify Pause/Resume affordance flips with state.
    let runningPause = recorder.snapshot.first { $0.dot == .running }?.pauseResume
    XCTAssertEqual(runningPause?.title, "Pause Engine")
    XCTAssertEqual(runningPause?.enabled, true)
    XCTAssertEqual(runningPause?.action, .pause)

    let finalStopped = recorder.snapshot.last
    XCTAssertEqual(finalStopped?.pauseResume.title, "Resume Engine")
    XCTAssertEqual(finalStopped?.pauseResume.enabled, true,
                   "Resume must be actionable when stopped — ProfileStore + resolver are wired; a disabled Resume strands the engine and defers every model load ( follow-up)")
  }

  // MARK: - failure path: spawn-failed engine → error dot

  func test_supervisor_failure_drives_errorDot() throws {
    // Crash on launch. Supervisor will retry per restartAttempts then
    // give up with .failed(.spawnFailed, …).
    let fake = try writeScript("pie-boom.sh", body: """
      #!/bin/bash
      exit 7
      """)
    let sup = makeSupervisor(policy: .init(handshakeTimeout: 0.5,
                                            restartAttempts: 1,
                                            restartWindow: 30,
                                            stopGracePeriod: 1))
    let recorder = ModelRecorder()
    let token = sup.observe { status, _ in
      recorder.record(HelperStatusItemModel.make(from: status))
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    // Wait for the TERMINAL spawn-failure classification, not merely the
    // first `.error` dot. A crash-on-launch child that exits with a code
    // settles on `.failed(.spawnFailed)`, but under load the handshake
    // timer can briefly publish an intermediate `.error`/`.handshakeTimeout`
    // first (the supervisor then reclassifies it once the real exit code
    // arrives). Stopping at the first `.error` could capture that
    // intermediate; wait for the real invariant instead.
    recorder.waitForLabel(containing: "spawnFailed", timeout: 5, testCase: self)
    token.cancel()

    let last = recorder.snapshot.last
    XCTAssertEqual(last?.dot, .error)
    XCTAssertTrue(last?.engineLabel.contains("spawnFailed") ?? false,
                  "failed label must surface the code; got \(String(describing: last?.engineLabel))")
    XCTAssertEqual(last?.pauseResume.title, "Resume Engine")
    XCTAssertTrue(last?.pauseResume.enabled ?? false,
                  "spawnFailed is user-recoverable → Resume must stay actionable for a retry (EngineErrorCode.invitesResumeRetry)")
  }

  // MARK: - binding integration: full stream reaches setters in order

  func test_supervisor_stream_through_binding_setters() throws {
    let fake = try writeScript("pie-stay-binding.sh", body: """
      #!/bin/bash
      echo "HTTP_LISTEN=127.0.0.1:33333"
      while true; do sleep 60; done
      """)
    let sup = makeSupervisor()
    let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    let binding = HelperStatusItemBinding(
      setDot: { dot in events.withLock { $0.append("dot=\(dot.rawValue)") } },
      setEngineLabel: { label in events.withLock { $0.append("label=\(label)") } },
      setPauseResumeTitle: { t in events.withLock { $0.append("pr.title=\(t)") } },
      setPauseResumeEnabled: { e in events.withLock { $0.append("pr.enabled=\(e)") } },
      setPauseResumeAction: { a in events.withLock { $0.append("pr.action=\(a)") } }
    )
    let runningExp = expectation(description: ".running reached")
    let stoppedExp = expectation(description: ".stopped reached")
    let stoppedSeen = OSAllocatedUnfairLock<Bool>(initialState: false)
    let runningSeen = OSAllocatedUnfairLock<Bool>(initialState: false)
    let token = sup.observe { status, _ in
      binding.apply(HelperStatusItemModel.make(from: status))
      if case .running = status {
        let first = runningSeen.withLock { (seen: inout Bool) -> Bool in
          defer { seen = true }
          return seen
        }
        if !first { runningExp.fulfill() }
      }
      if case .stopped = status, runningSeen.withLock({ $0 }) {
        let first = stoppedSeen.withLock { (seen: inout Bool) -> Bool in
          defer { seen = true }
          return seen
        }
        if !first { stoppedExp.fulfill() }
      }
    }
    _ = sup.start(makeSpec(binary: fake, profileID: "chat"))
    wait(for: [runningExp], timeout: 5)
    sup.stop()
    wait(for: [stoppedExp], timeout: 5)
    token.cancel()

    let recorded = events.withLock { $0 }
    XCTAssertTrue(recorded.contains("dot=running"),
                  "binding must have seen the running dot")
    XCTAssertTrue(recorded.contains("label=Engine: running — chat @ port 33333"),
                  "binding must have seen the running label with port + profile")
    XCTAssertTrue(recorded.contains("pr.title=Pause Engine"))
    XCTAssertTrue(recorded.contains("pr.enabled=true"))
    XCTAssertTrue(recorded.contains("pr.action=pause"))
  }

  // MARK: - helpers

  private final class ModelRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[HelperStatusItemModel]>(initialState: [])
    func record(_ m: HelperStatusItemModel) { lock.withLock { $0.append(m) } }
    var snapshot: [HelperStatusItemModel] { lock.withLock { $0 } }

    func waitForDot(_ dot: HelperStatusItemModel.Dot,
                    after preceded: HelperStatusItemModel.Dot? = nil,
                    timeout: TimeInterval,
                    testCase: XCTestCase) {
      let exp = testCase.expectation(description: "model reaches dot=\(dot.rawValue)")
      let fired = OSAllocatedUnfairLock<Bool>(initialState: false)
      // Poll on a background queue — the model stream is appended by
      // the supervisor's observer; the test thread is waiting.
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
      timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
      timer.setEventHandler {
        let snap = self.snapshot.map(\.dot)
        let reached: Bool
        if let preceded {
          guard let pIdx = snap.firstIndex(of: preceded) else { reached = false; return }
          reached = snap[pIdx...].contains(dot)
        } else {
          reached = snap.contains(dot)
        }
        if reached {
          let already = fired.withLock { (f: inout Bool) -> Bool in
            defer { f = true }
            return f
          }
          if !already { exp.fulfill() }
        }
      }
      timer.resume()
      defer { timer.cancel() }
      testCase.wait(for: [exp], timeout: timeout)
    }

    /// Wait until any recorded model's `engineLabel` contains `needle`.
    /// Used to wait for a terminal classification (e.g. "spawnFailed")
    /// rather than a coarse dot that an intermediate state may also map to.
    func waitForLabel(containing needle: String,
                      timeout: TimeInterval,
                      testCase: XCTestCase) {
      let exp = testCase.expectation(description: "model label contains \(needle)")
      let fired = OSAllocatedUnfairLock<Bool>(initialState: false)
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
      timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
      timer.setEventHandler {
        guard self.snapshot.contains(where: { $0.engineLabel.contains(needle) }) else { return }
        let already = fired.withLock { (f: inout Bool) -> Bool in
          defer { f = true }
          return f
        }
        if !already { exp.fulfill() }
      }
      timer.resume()
      defer { timer.cancel() }
      testCase.wait(for: [exp], timeout: timeout)
    }
  }

  private func makeSupervisor(policy: PieSupervisor.Policy = .init(handshakeTimeout: 3,
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
}
