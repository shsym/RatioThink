import XCTest
@testable import RatioThinkCore

/// #497: `ModelTarget` is THE launch/load-target derivation — the chat's
/// pinned selection first, the profile default second, with provenance.
/// Pinning the precedence (and the trim semantics inherited from the
/// pre-#497 `gateModelID`) here is what makes "prompt describes the pick as
/// the profile default" unrepresentable.
final class ModelTargetTests: XCTestCase {

  func test_pin_beats_profile_default() {
    XCTAssertEqual(
      ModelTarget.resolve(selectedModelID: "x", profileDefault: "d"),
      ModelTarget(modelID: "x", source: .selected)
    )
  }

  func test_no_pin_falls_back_to_default() {
    XCTAssertEqual(
      ModelTarget.resolve(selectedModelID: nil, profileDefault: "d"),
      ModelTarget(modelID: "d", source: .profileDefault)
    )
  }

  func test_blank_pin_counts_as_absent() {
    XCTAssertEqual(
      ModelTarget.resolve(selectedModelID: "  ", profileDefault: "d"),
      ModelTarget(modelID: "d", source: .profileDefault)
    )
  }

  func test_blank_default_counts_as_absent() {
    XCTAssertNil(ModelTarget.resolve(selectedModelID: nil, profileDefault: "  "))
  }

  func test_nothing_resolves_to_nil() {
    XCTAssertNil(ModelTarget.resolve(selectedModelID: nil, profileDefault: nil))
    XCTAssertNil(ModelTarget.resolve(selectedModelID: "", profileDefault: ""))
  }

  func test_pin_alone_resolves_without_default() {
    XCTAssertEqual(
      ModelTarget.resolve(selectedModelID: "x", profileDefault: nil),
      ModelTarget(modelID: "x", source: .selected)
    )
  }
}
