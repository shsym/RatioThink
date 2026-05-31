import XCTest
@testable import RatioThink

/// #359: the indicator click opens info only; the two
/// destructive/interrupting actions (cancel a live load, unload a
/// resident model) are gated behind an explicit confirm step.
///
/// `ModelLoadPopover.destructiveConfirm(for:)` is the pure seam that
/// decides WHICH states get a destructive confirm and what the confirm
/// says. Asserting it here proves — without standing up the SwiftUI
/// view — that (a) only `.loading` and `.ready` are gated, (b) every
/// non-destructive state (`.idle` / `.cancelled` / `.failed` /
/// `.engineNotReady`) returns nil so a single click can never reach a
/// stop/unload, and (c) the copy names the model, what stops, and that
/// it can be resumed.
@MainActor
final class ModelLoadPopoverConfirmTests: XCTestCase {

  // MARK: - gated states (the two interrupting actions)

  func test_loading_offers_a_cancel_confirm_naming_model_and_resumability() {
    let confirm = try? XCTUnwrap(
      ModelLoadPopover.destructiveConfirm(for: .loading(
        modelID: "qwen3-0.6b", loadedBytes: 0, totalBytes: 0, etaSeconds: nil)))
    let c = try! XCTUnwrap(confirm)

    // Names the specific model being stopped — not generic copy.
    XCTAssertTrue(c.message.contains("qwen3-0.6b"), "cancel confirm must name the model; got: \(c.message)")
    // States what stops …
    XCTAssertTrue(c.message.localizedCaseInsensitiveContains("stop loading"),
                  "cancel confirm must say the load stops; got: \(c.message)")
    // … and that it is resumable (the ticket's "can be resumed" copy).
    XCTAssertTrue(c.message.localizedCaseInsensitiveContains("again"),
                  "cancel confirm must say the load can be restarted; got: \(c.message)")
    XCTAssertEqual(c.confirmTitle, "Stop Loading")
    XCTAssertEqual(c.keepTitle, "Keep Loading")
    XCTAssertEqual(c.confirmIdentifier, "modelLoad.popover.confirmCancel")
    XCTAssertEqual(c.keepIdentifier, "modelLoad.popover.keepLoading")
  }

  func test_ready_offers_an_unload_confirm_naming_model_and_reload_path() {
    let c = try! XCTUnwrap(ModelLoadPopover.destructiveConfirm(for: .ready(modelID: "qwen3-0.6b")))

    XCTAssertTrue(c.message.contains("qwen3-0.6b"), "unload confirm must name the model; got: \(c.message)")
    // States what stops: frees memory.
    XCTAssertTrue(c.message.localizedCaseInsensitiveContains("frees its memory"),
                  "unload confirm must say it frees memory; got: \(c.message)")
    // … and the resume path: reload before next message.
    XCTAssertTrue(c.message.localizedCaseInsensitiveContains("reload"),
                  "unload confirm must say the model can be reloaded; got: \(c.message)")
    XCTAssertEqual(c.confirmTitle, "Unload")
    XCTAssertEqual(c.keepTitle, "Keep Loaded")
    XCTAssertEqual(c.confirmIdentifier, "modelLoad.popover.confirmUnload")
    XCTAssertEqual(c.keepIdentifier, "modelLoad.popover.keepLoaded")
  }

  /// The two interrupting actions are distinct affordances, not one
  /// overloaded button.
  func test_loading_and_ready_confirms_are_distinct() {
    let loading = ModelLoadPopover.destructiveConfirm(for: .loading(
      modelID: "m", loadedBytes: 0, totalBytes: 0, etaSeconds: nil))
    let ready = ModelLoadPopover.destructiveConfirm(for: .ready(modelID: "m"))
    XCTAssertNotNil(loading)
    XCTAssertNotNil(ready)
    XCTAssertNotEqual(loading, ready, "cancel and unload must be distinct confirms")
    XCTAssertNotEqual(loading?.confirmIdentifier, ready?.confirmIdentifier)
  }

  // MARK: - non-destructive states (no confirm gate → single click is safe)

  func test_failed_has_no_destructive_confirm() {
    // `.failed` uses one-tap Dismiss to clear the error ring — clearing
    // an already-finished failure is not destructive.
    XCTAssertNil(ModelLoadPopover.destructiveConfirm(for: .failed(modelID: "m", message: "engine returned 502")))
  }

  func test_engine_not_ready_has_no_destructive_confirm() {
    XCTAssertNil(ModelLoadPopover.destructiveConfirm(for: .engineNotReady(modelID: "m", detail: "Engine stopped")))
  }

  func test_idle_and_cancelled_have_no_destructive_confirm() {
    XCTAssertNil(ModelLoadPopover.destructiveConfirm(for: .idle))
    XCTAssertNil(ModelLoadPopover.destructiveConfirm(for: .cancelled(modelID: "m")))
  }
}
