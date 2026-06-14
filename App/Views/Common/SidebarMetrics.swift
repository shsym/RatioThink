import SwiftUI

/// One source of truth for left-menu spacing and glyph sizing so every item in
/// the left navigation — the top nav rows (Chats, Search, API Endpoints) and
/// the chat-list header + rows below them — lines up on the same
/// horizontal/vertical metric. Before this each surface carried its own ad-hoc
/// paddings and icon sizes.
enum SidebarMetrics {
  static let rowHorizontalPadding: CGFloat = 10
  static let rowVerticalPadding: CGFloat = 6
  static let rowSpacing: CGFloat = 6
  /// Fixed glyph box width so leading icons share a column regardless of the
  /// symbol's intrinsic width.
  static let iconWidth: CGFloat = 18
}

extension View {
  /// Uniform sizing for every left-menu glyph: a fixed-width box at one image
  /// scale. Applied to sidebar nav icons and the chat-row pin so a
  /// caption-sized pin no longer reads smaller than the nav glyphs.
  func sidebarIcon() -> some View {
    frame(width: SidebarMetrics.iconWidth, alignment: .center)
      .imageScale(.medium)
  }
}
