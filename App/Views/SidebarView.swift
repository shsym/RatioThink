import SwiftUI

/// Left navigation, two regions:
///   • TOP: the view selector (Chats, Search, API Endpoints, …) — switches the
///     right-hand main view.
///   • BOTTOM: a persistent shortcut area whose first occupant is the chat
///     list. It stays mounted across every section selection, so opening the
///     Search or API view no longer hides the chat list. Future foldable
///     sections (Workflows, …) slot in alongside the list here.
///
/// The Chats top entry clears the item selection so the detail surface lands on
/// the empty-state CTA; new chats are started from the titlebar new-chat
/// button. Search is a sibling destination whose detail view searches
/// conversation titles + message bodies.
struct SidebarView: View {
  @Binding var selection: SidebarSection?
  @Binding var selectedItemID: UUID?
  let isItemListHidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // TOP region: view selector.
      sidebarRow(.chats) {
        // Selecting Chats clears the selection so the detail surface shows the
        // empty-state landing; the titlebar button starts a new chat.
        selection = .chats
        selectedItemID = nil
      }
      // Sibling destination: a search panel (detail column) over conversation
      // titles + message bodies.
      sidebarRow(.search) { selection = .search }
      // #422: the API Endpoints section mirrors the live engine HTTP endpoint
      // (LocalAPIView). Selecting it shows the single status view in the
      // detail column; the chat list below stays put.
      sidebarRow(.apiEndpoints) { selection = .apiEndpoints }

      // BOTTOM region: persistent shortcut area. The chat list is always
      // mounted (it does not unmount when a non-Chat section is selected);
      // only the View > Hide List command collapses it.
      if !isItemListHidden {
        Divider()
          .padding(.horizontal, 10)
          .padding(.vertical, 2)
        ChatListView(
          selectedItemID: $selectedItemID,
          selectedSection: $selection
        )
        .padding(.top, 2)
      }
      Spacer()
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
  }

  private func sidebarRow(_ section: SidebarSection, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: SidebarMetrics.rowSpacing) {
        Image(systemName: section.systemImage)
          .sidebarIcon()
          .foregroundStyle(.secondary)
        Text(section.title)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
      .padding(.vertical, SidebarMetrics.rowVerticalPadding)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(selection == section ? Color.accentColor.opacity(0.18) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
