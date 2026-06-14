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
/// toggle sidebar / embedded chat-list visibility without reaching into view
/// state.
/// #577: the new-chat first-message handoff. The draft composer (`NewChatView`)
/// persists no chat until the first send; on send it creates + selects the
/// chat and stashes the typed text here. The mounting `ChatScaffoldView`
/// consumes it (seeds its composer + runs the real send) and clears it.
struct PendingFirstMessage {
  let chatID: UUID
  let text: String
}

@MainActor
final class WindowState: ObservableObject {
  @Published var columnVisibility: NavigationSplitViewVisibility = .all
  @Published var isItemListHidden: Bool = false
  @Published var selectedSection: SidebarSection? = .chats
  @Published var selectedItemID: UUID? = nil
  /// #577: one-shot first-message handoff from the new-chat draft composer to
  /// the freshly-created chat's scaffold. Nil except in the brief window
  /// between "first send in a new chat" and the scaffold consuming it.
  @Published var pendingFirstMessage: PendingFirstMessage? = nil

  func toggleSidebar() {
    columnVisibility = (columnVisibility == .all) ? .doubleColumn : .all
  }

  func toggleItemList() {
    isItemListHidden.toggle()
  }
}
