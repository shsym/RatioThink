import SwiftUI

/// One source of truth for left-menu spacing and glyph sizing so every item in
/// the left navigation — the top nav rows (Chats, Search, API Endpoints) and
/// the chat-list header + rows below them — lines up on the same
/// horizontal/vertical metric. Before this each surface carried its own ad-hoc
/// paddings and icon sizes.
enum SidebarMetrics {
  /// Section-level left/right margin for the top nav rows (Chats, Search, API
  /// Endpoints) and the Conversations header. +50% over the legacy uniform 10
  /// so the section framing sits further from the window edge.
  static let sectionHorizontalPadding: CGFloat = 15
  /// Per-conversation-entry horizontal inset. Held at the original 10 while the
  /// section margin grows to `sectionHorizontalPadding`, so each entry keeps its
  /// original on-screen left/right margin and does not indent further inward
  /// (equivalent to: container shifts in by +5, entry padding drops by 5).
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
