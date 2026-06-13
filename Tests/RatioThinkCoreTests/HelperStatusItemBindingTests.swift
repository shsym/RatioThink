import XCTest
import os
@testable import RatioThinkCore

/// Pins the closure-injection seam between `HelperStatusItemModel`
/// and the AppKit status item. Verifies:
///   · Every model field reaches the correct setter.
///   · Setter invocation ORDER matches the documented contract (a
///     reordered apply could expose a transient inconsistent menu
///     state to AppKit accessibility / VoiceOver).
///   · A sequence of model snapshots produces the expected sequence
///     of setter calls — locks the supervisor-transition → menu
///     refresh leg without requiring an `NSStatusBar`.
final class HelperStatusItemBindingTests: XCTestCase {

  private final class Recorder: @unchecked Sendable {
    let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
    func record(_ line: String) { lock.withLock { $0.append(line) } }
    var events: [String] { lock.withLock { $0 } }
  }

  private func makeBinding(_ rec: Recorder) -> HelperStatusItemBinding {
    HelperStatusItemBinding(
      setDot: { rec.record("dot=\($0.rawValue)") },
      setEngineLabel: { rec.record("label=\($0)") },
      setPauseResumeTitle: { rec.record("pr.title=\($0)") },
      setPauseResumeEnabled: { rec.record("pr.enabled=\($0)") },
      setPauseResumeAction: { rec.record("pr.action=\($0)") }
    )
  }

  func test_apply_callsEverySetter_inDocumentedOrder() {
    let rec = Recorder()
    let binding = makeBinding(rec)
    let model = HelperStatusItemModel.make(from: .running(EngineSessionSnapshot(port: 54321, profileID: "chat")))
    binding.apply(model)
    XCTAssertEqual(rec.events, [
      "dot=running",
      "label=Engine: running — chat @ port 54321",
      "pr.title=Pause Engine",
      "pr.action=pause",
      "pr.enabled=true",
    ])
  }

  func test_apply_stopped_setsResumeEnabled() {
    let rec = Recorder()
    let binding = makeBinding(rec)
    binding.apply(HelperStatusItemModel.make(from: .stopped))
    XCTAssertEqual(rec.events, [
      "dot=stopped",
      "label=Engine: stopped",
      "pr.title=Resume Engine",
      "pr.action=resume",
      "pr.enabled=true",
    ])
  }

  /// Review v1 F5: a `.stopped → .running` transition (or any
  /// `.resume → .pause` transition) MUST set the new action BEFORE
  /// flipping enabled to true. Otherwise the menu item is enabled
  /// for one main-thread tick still carrying `.resume`, and an AX
  /// click landing in that tick invokes the wrong branch.
  func test_apply_stopped_to_running_actionLandsBeforeEnableFlip() {
    let rec = Recorder()

    // The race the reorder closes: while transitioning INTO Pause mode
    // (title "Pause Engine"), enabled must not flip true while the
    // action is still the stale ".resume" from the prior state.
    // `.stopped` now legitimately rests at (title "Resume Engine",
    // action .resume, enabled true) ( follow-up), so we key the
    // detector on the Pause-mode title, not on action != pause.
    var pendingTitle: String = "pr.title=Resume Engine"  // starting state
    var pendingAction: String = "pr.action=resume"
    var observedRaces: [String] = []
    let raceCheckingBinding = HelperStatusItemBinding(
      setDot: { rec.record("dot=\($0.rawValue)") },
      setEngineLabel: { rec.record("label=\($0)") },
      setPauseResumeTitle: { t in
        pendingTitle = "pr.title=\(t)"
        rec.record(pendingTitle)
      },
      setPauseResumeEnabled: { e in
        rec.record("pr.enabled=\(e)")
        if e && pendingTitle == "pr.title=Pause Engine" && pendingAction != "pr.action=pause" {
          observedRaces.append("RACE: enabled=true in Pause mode while action=\(pendingAction)")
        }
      },
      setPauseResumeAction: { a in
        pendingAction = "pr.action=\(a)"
        rec.record(pendingAction)
      }
    )

    // Walk: stopped (.resume, enabled=true) → running (.pause, enabled=true)
    raceCheckingBinding.apply(HelperStatusItemModel.make(from: .stopped))
    raceCheckingBinding.apply(HelperStatusItemModel.make(from: .running(EngineSessionSnapshot(port: 1, profileID: "p"))))

    XCTAssertEqual(observedRaces, [],
                   "setPauseResumeAction MUST land before setPauseResumeEnabled flips true")
  }

  func test_apply_failed_setsErrorDot() {
    let rec = Recorder()
    let binding = makeBinding(rec)
    binding.apply(HelperStatusItemModel.make(
      from: .failed(code: .spawnFailed, message: "binary missing")))
    let events = rec.events
    XCTAssertEqual(events.first, "dot=error")
    // #477: the label carries the code + the curated taxonomy line, never
    // the raw diagnostic.
    XCTAssertTrue(events.contains { $0.contains("spawnFailed") && $0.contains("The engine failed to start") })
    // spawnFailed is user-recoverable → Resume stays enabled so a retry
    // is possible after the cause is fixed (EngineErrorCode.invitesResumeRetry).
    XCTAssertTrue(events.contains("pr.enabled=true"))
    XCTAssertTrue(events.contains("pr.action=resume"))
  }

  /// Drive a realistic transition sequence (cold boot → start →
  /// running → stop → stopped) through `make` + `apply`. Locks the
  /// full state-machine projection.
  func test_transitionSequence_matchesExpectedSetterStream() {
    let rec = Recorder()
    let binding = makeBinding(rec)
    let statuses: [EngineStatus] = [
      .stopped,
      .starting,
      .running(EngineSessionSnapshot(port: 54321, profileID: "chat")),
      .stopping,
      .stopped,
    ]
    for s in statuses {
      binding.apply(HelperStatusItemModel.make(from: s))
    }
    let dotLine = rec.events.filter { $0.hasPrefix("dot=") }
    XCTAssertEqual(dotLine, [
      "dot=stopped",
      "dot=loading",   // starting
      "dot=running",
      "dot=loading",   // stopping
      "dot=stopped",
    ])
    let titleLine = rec.events.filter { $0.hasPrefix("pr.title=") }
    XCTAssertEqual(titleLine, [
      "pr.title=Resume Engine",
      "pr.title=Pause Engine",
      "pr.title=Pause Engine",
      "pr.title=Pause Engine",
      "pr.title=Resume Engine",
    ])
    let enabledLine = rec.events.filter { $0.hasPrefix("pr.enabled=") }
    XCTAssertEqual(enabledLine, [
      "pr.enabled=true",   // stopped — Resume actionable ( wired,  follow-up)
      "pr.enabled=true",   // starting — pause cancels spawn
      "pr.enabled=true",   // running — pause SIGTERMs
      "pr.enabled=false",  // stopping — nothing to do
      "pr.enabled=true",   // back to stopped — Resume actionable again
    ])
  }
}
