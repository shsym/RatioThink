import SwiftUI

/// Top-level navigation nodes in the sidebar (col 1). v1 ships three; v2 will
/// add Routines / MCP Servers / Remote Engines as additional cases.
enum SidebarSection: Hashable, CaseIterable, Identifiable {
  case chats
  case search
  case apiEndpoints

  var id: Self { self }

  var title: String {
    switch self {
    case .chats: return "Chats"
    case .search: return "Search"
    case .apiEndpoints: return "API Endpoints"
    }
  }

  var systemImage: String {
    switch self {
    case .chats: return "bubble.left.and.bubble.right"
    case .search: return "magnifyingglass"
    case .apiEndpoints: return "network"
    }
  }
}

/// Per-window UI state shared between the SwiftUI `App` (for `.commands`) and
/// `RootView`'s `NavigationSplitView`. Lives at App level so menu items can
/// toggle sidebar / embedded chat-list visibility without reaching into view
/// state.
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

  /// Route the shell to a freshly-forked chat and arm its one-shot resend
  /// (#624). The new scaffold consumes the signal via
  /// `consumePendingForkResend(_:)` on mount.
  func beginForkResend(to chatID: UUID) {
    pendingForkResendChatID = chatID
    selectedSection = .chats
    selectedItemID = chatID
  }

  /// Consume the fork-resend handoff for `chatID`, exactly once. Returns
  /// `true` (and clears the flag) on the first call whose id matches the
  /// armed chat; every later call — re-mounts, sibling scaffolds, the
  /// source chat — returns `false`. This is what guarantees the resend
  /// fires a single time. (#624)
  func consumePendingForkResend(_ chatID: UUID) -> Bool {
    guard pendingForkResendChatID == chatID else { return false }
    pendingForkResendChatID = nil
    return true
  }

  func toggleSidebar() {
    // Two-column split view: the sidebar is hidden by collapsing to the detail
    // column only (`.detailOnly`). Every other visibility — `.all`,
    // `.doubleColumn`, `.automatic` — shows the sidebar, so key the predicate on
    // the single hidden state. The system-injected sidebar-toggle control writes
    // `.doubleColumn` (not `.all`) back through this binding when it shows the
    // sidebar in a 2-column view; keying on `== .all` would miss that and make
    // the next Hide a no-op (#677).
    columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
  }

  func toggleItemList() {
    isItemListHidden.toggle()
  }
}
