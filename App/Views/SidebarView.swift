import SwiftUI

/// Col 1 — stable navigation. Per design §5: nav-only, no items, no settings.
struct SidebarView: View {
  @Binding var selection: SidebarSection?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      sidebarRow(.chats)
      // #422: the API Endpoints section now mirrors the live engine HTTP
      // endpoint (LocalAPIView). Selecting it collapses the item-list column
      // and shows the single status view in the detail column.
      sidebarRow(.apiEndpoints)
      Spacer()
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
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
