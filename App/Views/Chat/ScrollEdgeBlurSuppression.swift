import SwiftUI

/// #669: macOS 26 (Tahoe / "Liquid Glass") renders an automatic *scroll-edge
/// effect* — a system vibrancy material that blurs scroll content as it passes
/// under the toolbar. On the chat transcript that top-edge material sits exactly
/// where the toolbar model picker's `.popover` (and a menu-bar menu) opens, so
/// the picker's own `.regularMaterial` backdrop samples a doubly-blurred strip
/// and the rows read as "occluded and blurred" — the symptom that survived the
/// merged `.sheet`→`.overlay` no-model-gate fix (which is correct and orthogonal,
/// and is left untouched).
///
/// The effect is brand-new in macOS 26; macOS 14/15 (the deployment floor is
/// 14.0) have no such material and need no suppression. This policy is the
/// version gate of record, kept pure so it is unit-testable without a device of
/// each OS — the view modifier below routes through it.
enum ScrollEdgeBlurSuppression {
  /// The macOS major version that introduced the scroll-edge effect.
  static let scrollEdgeEffectMajorVersion = 26

  /// True when the running macOS applies the scroll-edge effect and the
  /// transcript's top edge must therefore be suppressed (#669).
  static func shouldHideTopEdgeEffect(osMajorVersion: Int) -> Bool {
    osMajorVersion >= scrollEdgeEffectMajorVersion
  }
}

extension View {
  /// Suppress the macOS 26 top-edge scroll-edge blur on the transcript scroll
  /// view so the toolbar model picker / menus open over a clean backdrop (#669).
  /// Scoped to `.top` only (the edge under the toolbar) so any bottom-edge effect
  /// near the composer is preserved, and scoped to this one scroll view so the
  /// rest of the app keeps its intended macOS 26 visuals. No-op below macOS 26.
  @ViewBuilder
  func hidingTopScrollEdgeBlur(
    osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  ) -> some View {
    if ScrollEdgeBlurSuppression.shouldHideTopEdgeEffect(osMajorVersion: osMajorVersion),
       #available(macOS 26.0, *) {
      self.scrollEdgeEffectHidden(true, for: .top)
    } else {
      self
    }
  }
}
