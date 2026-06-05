import SwiftUI

/// Col 3 — content for the selected item. v1 mounts the chat scaffold
/// (toolbar + transcript + composer) when a chat is selected and the
/// single live `LocalAPIView` when the API Endpoints section is selected
/// (there is exactly one engine endpoint — #422). With no selection we
/// fall back to the `EmptyStateView` CTAs.
struct DetailView: View {
  let section: SidebarSection?
  let selectedItemID: UUID?

  var body: some View {
    switch (section, selectedItemID) {
    case (.chats, let id?):
      // `.id(id)` rebuilds the scaffold (and its `@StateObject`
      // view-model) when switching between chat rows so each chat has
      // its own toolbar state. The scaffold itself loads the chat
      // row via `@Query` keyed on `id`.
      ChatScaffoldView(chatID: id)
        .id(id)
    case (.apiEndpoints, _):
      // One engine, one endpoint: the section maps to a single live view
      // regardless of item selection (the item-list column is collapsed
      // for this section in `RootView`).
      LocalAPIView()
    case (_, nil):
      EmptyStateView()
    default:
      Text("Content placeholder")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
