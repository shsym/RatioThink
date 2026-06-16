import XCTest
@testable import RatioThink

/// #678 — locks the chat toolbar dropdown's model-row marking so the
/// unverified signal can NEVER be suppressed by the row also being current or
/// blocked.
///
/// Root cause this guards against: the leading-glyph column holds ONE glyph,
/// and the old precedence (current > blocked > unverified) dropped the
/// unverified shield whenever the unverified model was the current selection
/// (the just-downloaded, now-current case the operator hit) or blocked. The
/// fix moves the unverified signal to an INDEPENDENT trailing badge
/// (`option.isUnverified`), so it survives any leading glyph.
@MainActor
final class ContentToolbarModelRowMarkerTests: XCTestCase {
  private func option(isCurrent: Bool = false,
                      isUnverified: Bool = false,
                      unavailableReason: String? = nil) -> ToolbarModelOptions.Option {
    ToolbarModelOptions.Option(
      slug: "Vendor/Test-Model-GGUF/Test-Model-Q4_K_M.gguf",
      displayName: "Test Model Q4_K_M",
      source: .appManaged,
      isCurrent: isCurrent,
      isProfileDefault: false,
      unavailableReason: unavailableReason,
      isUnverified: isUnverified)
  }

  // MARK: leading glyph (current / blocked / bullet — NOT unverified)

  func test_leading_marker_is_current_blocked_or_bullet_only() {
    XCTAssertEqual(ContentToolbar.leadingMarker(option(isCurrent: true)), .current)
    XCTAssertEqual(
      ContentToolbar.leadingMarker(option(unavailableReason: "Download in progress")), .blocked)
    XCTAssertEqual(ContentToolbar.leadingMarker(option()), .bullet)
  }

  /// The leading glyph must NOT change with `isUnverified` — unverified is no
  /// longer a leading-precedence state, so it cannot be swallowed by current
  /// or blocked. (Mutation check: restoring the old `if option.isUnverified {
  /// return .unverified }` arm makes the non-current case below fail.)
  func test_leading_marker_ignores_unverified() {
    XCTAssertEqual(ContentToolbar.leadingMarker(option(isUnverified: true)), .bullet,
                   "a non-current unverified row keeps the bullet; the shield is the trailing badge")
    XCTAssertEqual(ContentToolbar.leadingMarker(option(isCurrent: true, isUnverified: true)), .current)
    XCTAssertEqual(
      ContentToolbar.leadingMarker(option(isUnverified: true, unavailableReason: "x")), .blocked)
  }

  // The trailing unverified badge + row accessibilityValue are guarded
  // end-to-end (and mutation-proven) by S678_UnverifiedModelMarkGUITests; a
  // unit case asserting `option(isUnverified: true).isUnverified` would only
  // round-trip the initializer, so it is intentionally omitted here.
}
