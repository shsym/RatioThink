import SwiftUI

/// One source of truth for left-menu spacing and glyph sizing so every
/// item in col 1 (sidebar nav rows) and col 2 (conversation-list header +
/// rows) lines up on the same horizontal/vertical metric. Before this the
/// three surfaces each carried their own ad-hoc paddings and icon sizes.
enum SidebarMetrics {
  static let rowHorizontalPadding: CGFloat = 10
  static let rowVerticalPadding: CGFloat = 6
  static let rowSpacing: CGFloat = 6
  /// Fixed glyph box width so leading icons share a column regardless of
  /// the symbol's intrinsic width.
  static let iconWidth: CGFloat = 18
}

extension View {
  /// Uniform sizing for every left-menu glyph: a fixed-width box at one
  /// image scale. Applied to sidebar nav icons and the chat-row pin so a
  /// caption-sized pin no longer reads smaller than the nav glyphs.
  func sidebarIcon() -> some View {
    frame(width: SidebarMetrics.iconWidth, alignment: .center)
      .imageScale(.medium)
  }
}
