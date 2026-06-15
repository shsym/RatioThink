import SwiftUI

/// Top-level navigation nodes in the sidebar (col 1). v1 ships two; v2 will add
/// Routines / MCP Servers / Remote Engines as additional cases.
enum SidebarSection: Hashable, CaseIterable, Identifiable {
  case chats
  case apiEndpoints

  var id: Self { self }

  var title: String {
    switch self {
    case .chats: return "Chats"
    case .apiEndpoints: return "API Endpoints"
    }
  }

  var systemImage: String {
    switch self {
    case .chats: return "bubble.left.and.bubble.right"
    case .apiEndpoints: return "network"
    }
  }
}

/// Per-window UI state shared between the SwiftUI `App` (for `.commands`) and
/// `RootView`'s `NavigationSplitView`. Lives at App level so menu items can
/// toggle the sidebar / item-list visibility without reaching into view state.
@MainActor
final class WindowState: ObservableObject {
  @Published var columnVisibility: NavigationSplitViewVisibility = .all
  @Published var isItemListHidden: Bool = false
  @Published var selectedSection: SidebarSection? = .chats
  @Published var selectedItemID: UUID? = nil
  /// One-shot handoff for the edit→fork flow (#624). Set to the new
  /// forked chat's id alongside `selectedItemID`; the freshly-mounted
  /// `ChatScaffoldView` for that id consumes it once to kick off the
  /// resent assistant turn, then clears it. Lives here (not on the fork
  /// primitive) because the send must run in the NEW scaffold instance —
  /// the one that owns the resent chat's `ChatSendController`.
  @Published var pendingForkResendChatID: UUID? = nil

  func toggleSidebar() {
    columnVisibility = (columnVisibility == .all) ? .doubleColumn : .all
  }

  func toggleItemList() {
    isItemListHidden.toggle()
  }
}
