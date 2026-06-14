import SwiftUI

/// Left navigation, two regions (#577):
///   • TOP: the view selector (Chats, API Endpoints, …) — switches the
///     right-hand main view.
///   • BOTTOM: a persistent shortcut area whose first occupant is the
///     searchable chat list. It stays mounted across every section selection,
///     so opening the API view no longer hides the chat list. Future foldable
///     sections (Workflows, …) slot in alongside the list here.
///
/// The Chats top entry is the "new chat" shortcut: selecting it clears the
/// item selection so the detail surface lands on a ready new-chat composer
/// (`DetailView` → `NewChatView`) with no separate New Chat click.
struct SidebarView: View {
  @Binding var selection: SidebarSection?
  @Binding var selectedItemID: UUID?
  let isItemListHidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // TOP region: view selector.
      sidebarRow(.chats) {
        // Selecting Chats is the new-chat shortcut: clear the selection so the
        // detail surface shows the editable new-chat composer.
        selection = .chats
        selectedItemID = nil
      }
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
      HStack(spacing: 6) {
        Image(systemName: section.systemImage)
          .frame(width: 18, alignment: .center)
          .foregroundStyle(.secondary)
        Text(section.title)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(selection == section ? Color.accentColor.opacity(0.18) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
