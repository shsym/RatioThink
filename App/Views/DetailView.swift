import SwiftUI

/// Detail surface for the selected left-navigation target. Mounts the chat
/// scaffold (toolbar + transcript + composer) when a chat is selected, the
/// conversation search panel for the Search section, and the single live
/// `LocalAPIView` for the API Endpoints section (there is exactly one engine
/// endpoint — #422). With no selection we fall back to the `EmptyStateView`
/// CTAs.
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
    case (.search, _):
      // Sibling destination: a search panel over conversation titles +
      // message bodies. Selecting a result routes back to the Chats section.
      ConversationSearchView()
    case (.apiEndpoints, _):
      // One engine, one endpoint: the section maps to a single live view
      // regardless of chat selection.
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
