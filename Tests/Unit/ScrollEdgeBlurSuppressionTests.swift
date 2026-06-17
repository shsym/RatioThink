import XCTest
@testable import RatioThink

/// #669: the toolbar model picker reads as "occluded and blurred" while the
/// no-model / engine-failure gate is up because macOS 26's scroll-edge effect
/// blurs the transcript's top strip under the toolbar. The fix suppresses that
/// top-edge effect on the transcript scroll view (`hidingTopScrollEdgeBlur`),
/// gated by `ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect`.
///
/// The visual only manifests on macOS 26, so the regression is the VERSION GATE
/// (state/API level) rather than a pixel assertion: suppression must engage on
/// 26+ and stay off on the macOS 14/15 floor where the effect does not exist.
/// Mutation-proof — flipping `>=` to `>` drops the 26 case, flipping the
/// constant off the real boundary drops 26 or wrongly catches 25.
final class ScrollEdgeBlurSuppressionTests: XCTestCase {

  func test_suppresses_on_macOS26_and_later() {
    XCTAssertTrue(ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: 26),
                  "macOS 26 introduced the scroll-edge effect — must suppress it")
    XCTAssertTrue(ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: 27),
                  "later macOS keeps the effect — must keep suppressing")
  }

  func test_noop_below_macOS26() {
    XCTAssertFalse(ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: 15),
                   "macOS 15 has no scroll-edge effect — must not suppress")
    XCTAssertFalse(ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: 14),
                   "macOS 14 (deployment floor) has no scroll-edge effect — must not suppress")
  }

  /// The boundary is exactly the introducing version, not an off-by-one.
  func test_boundary_is_26() {
    XCTAssertEqual(ScrollEdgeBlurSuppression.scrollEdgeEffectMajorVersion, 26)
    XCTAssertFalse(ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: 25))
    XCTAssertTrue(ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: 26))
  }

  /// On this build's actual OS the gate must agree with the real major version,
  /// so the wired default argument can't silently diverge from the policy.
  func test_matches_running_os() {
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    XCTAssertEqual(
      ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: major),
      major >= 26)
  }
}
