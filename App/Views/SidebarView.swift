import SwiftUI

/// Left navigation: stable Chat/API entry points plus the searchable chat list
/// mounted under the Chat entry.
struct SidebarView: View {
  @Binding var selection: SidebarSection?
  @Binding var selectedItemID: UUID?
  let isItemListHidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      sidebarRow(.chats)
      // #422: the API Endpoints section now mirrors the live engine HTTP
      // endpoint (LocalAPIView). Selecting it shows the single status view in
      // the detail column.
      sidebarRow(.apiEndpoints)
      if selection == .chats && !isItemListHidden {
        ChatListView(selectedItemID: $selectedItemID)
          .padding(.top, 2)
      }
      Spacer()
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
  }

  private func sidebarRow(_ section: SidebarSection) -> some View {
    Button {
      selection = section
    } label: {
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
