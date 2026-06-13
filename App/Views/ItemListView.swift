import SwiftUI

/// Col 2 — items inside the selected sidebar section. Chats render a list;
/// the API Endpoints section has no list (one engine endpoint — #422), so
/// its column is collapsed in `RootView` and this returns nothing for it.
struct ItemListView: View {
  let section: SidebarSection?
  @Binding var selectedItemID: UUID?

  var body: some View {
    Group {
      switch section {
      case .chats:
        ChatListView(selectedItemID: $selectedItemID)
      case .search, .apiEndpoints:
        // No item list — the search panel / single `LocalAPIView` fills the
        // detail column (col 2 is collapsed for these sections in RootView).
        EmptyView()
      case .none:
        Text("Select a section")
          .foregroundStyle(.secondary)
      }
    }
    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
  }
}
