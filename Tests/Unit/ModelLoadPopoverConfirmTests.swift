import XCTest
@testable import RatioThink

/// #359: the indicator click opens info only; the one
/// destructive/interrupting action — Unload a resident model — is gated behind
/// an explicit confirm step. (#469: the former Cancel-a-live-load action is
/// gone with the removed `/v1/models/load` UI.)
///
/// `ModelLoadPopover.unloadConfirm(residentModelID:)` is the pure seam for the
/// confirm copy. Asserting it here proves — without standing up the SwiftUI
/// view — that the copy names the model (by its friendly leaf), says it frees
/// memory, and names the reload path.
@MainActor
final class ModelLoadPopoverConfirmTests: XCTestCase {

  func test_unload_confirm_names_model_and_reload_path() {
    let c = try! XCTUnwrap(ModelLoadPopover.unloadConfirm(residentModelID: "qwen3-0.6b"))

    XCTAssertTrue(c.message.contains("qwen3-0.6b"), "unload confirm must name the model; got: \(c.message)")
    XCTAssertTrue(c.message.localizedCaseInsensitiveContains("frees its memory"),
                  "unload confirm must say it frees memory; got: \(c.message)")
    XCTAssertTrue(c.message.localizedCaseInsensitiveContains("reload"),
                  "unload confirm must say the model can be reloaded; got: \(c.message)")
    XCTAssertEqual(c.confirmTitle, "Unload")
    XCTAssertEqual(c.keepTitle, "Keep Loaded")
    XCTAssertEqual(c.confirmIdentifier, "modelLoad.popover.confirmUnload")
    XCTAssertEqual(c.keepIdentifier, "modelLoad.popover.keepLoaded")
  }

  // #462: the confirm copy must name the model by its friendly LEAF, never the
  // raw `<repo>/<file>` slug — an unbreakable slug token clips the fixed-width
  // confirm popover. The full id stays in the popover header.
  func test_unload_confirm_uses_leaf_not_raw_slug() {
    let slug = "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
    let c = try! XCTUnwrap(ModelLoadPopover.unloadConfirm(residentModelID: slug))
    XCTAssertTrue(c.message.contains("Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"),
                  "confirm must name the model by its leaf; got: \(c.message)")
    XCTAssertFalse(c.message.contains("bartowski/"),
                   "confirm must NOT inline the raw repo slug; got: \(c.message)")
    XCTAssertFalse(c.message.contains(slug),
                   "confirm must NOT inline the full slug; got: \(c.message)")
  }
}
