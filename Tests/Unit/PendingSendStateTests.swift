import XCTest
@testable import RatioThink

/// #516 (pre-merge operator request): pin the view-layer disarm paths that
/// were bare `pendingAutoSend = nil` assignments outside the pure
/// `PendingAutoSend` machine — profile switch, chat switch / navigate away,
/// and gate Cancel. The scaffold's transitions now live in
/// `PendingSendState`; each trigger test arms, drives the trigger's
/// transition, then delivers the resolution that WOULD have fired — and
/// asserts no send fires. The positive control proves the assertions can't
/// pass vacuously.
@MainActor
final class PendingSendStateTests: XCTestCase {
  private let chatID = UUID()
  private let target = "org/model-a"
  private let message = "send me after load"

  private func armed() -> PendingSendState {
    var state = PendingSendState()
    state.arm(chatID: chatID, targetModelID: target, messageText: message)
    XCTAssertNotNil(state.pending, "premise: arm must take")
    return state
  }

  /// Deliver the resolution that fires when nothing disarmed it.
  private func resolveTarget(_ state: inout PendingSendState) {
    state.settle(chatID: chatID, resolvedModelID: target, isSending: false)
  }

  // MARK: - positive control (anti-vacuity)

  func test_positive_control_no_trigger_means_resolution_fires() {
    var state = armed()
    resolveTarget(&state)
    XCTAssertNil(state.pending, "fired pending is consumed")
    XCTAssertEqual(state.autoSubmit, ComposerAutoSubmit(tick: 1, expectedText: message),
                   "without any disarm trigger the same resolution MUST fire — proves the trigger tests below aren't vacuous")
  }

  // MARK: - the three view-layer disarm triggers

  /// (1) Profile switch — `ChatScaffoldView`'s profile-swap `onChange`
  /// drops the pending: the gate's promised load target is stale under the
  /// new profile.
  func test_profile_switch_disarms_and_blocks_the_later_fire() {
    var state = armed()
    state.disarm()  // the profile-swap onChange transition
    resolveTarget(&state)
    XCTAssertNil(state.pending)
    XCTAssertNil(state.autoSubmit, "profile switch must prevent the stale auto-send")
  }

  /// (2) Chat switch / navigate away — `onDisappear` drops the pending:
  /// no stale auto-send when the user later returns.
  func test_navigate_away_disarms_and_blocks_the_later_fire() {
    var state = armed()
    state.disarm()  // the onDisappear transition
    resolveTarget(&state)
    XCTAssertNil(state.pending)
    XCTAssertNil(state.autoSubmit, "navigating away must prevent the stale auto-send")
  }

  /// (3) Gate Cancel — the sheet's `onCancel` drops the pending: the draft
  /// stays in the composer but nothing auto-fires later.
  func test_gate_cancel_disarms_and_blocks_the_later_fire() {
    var state = armed()
    state.disarm()  // the sheet onCancel transition
    resolveTarget(&state)
    XCTAssertNil(state.pending)
    XCTAssertNil(state.autoSubmit, "cancelling the gate must prevent the stale auto-send")
  }

  // MARK: - bookkeeping survives the triggers

  func test_rearm_after_disarm_fires_with_a_fresh_tick() {
    // A disarm is not a dead end: a new blocked send re-arms, and the fire
    // signal still changes (tick) even for identical text — the composer's
    // `.onChange` must see a new value.
    var state = armed()
    resolveTarget(&state)  // tick 1
    state.arm(chatID: chatID, targetModelID: target, messageText: message)
    state.disarm()
    state.arm(chatID: chatID, targetModelID: target, messageText: message)
    resolveTarget(&state)  // tick 2
    XCTAssertEqual(state.autoSubmit, ComposerAutoSubmit(tick: 2, expectedText: message))
  }

  func test_fire_happens_once_even_across_reentrant_resolution() {
    // The fired pending is cleared before the signal publishes; a re-entrant
    // resolution edge (the send itself reconciles state) finds nothing.
    var state = armed()
    resolveTarget(&state)
    let afterFire = state.autoSubmit
    resolveTarget(&state)  // re-entrant edge
    XCTAssertEqual(state.autoSubmit, afterFire, "second resolution must not re-fire")
  }
}
