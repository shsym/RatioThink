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
  @EnvironmentObject private var windowState: WindowState

  var body: some View {
    switch (section, selectedItemID) {
    case (.chats, _) where selectedItemID != nil || windowState.pendingChatDraft != nil:
      // `.id(id)` rebuilds the scaffold (and its `@StateObject`
      // view-model) when switching between chat rows so each chat has
      // its own toolbar state. The scaffold itself loads the chat
      // row via `@Query` keyed on `id`.
      //
      // Draft and saved chats share this ONE structural branch on purpose:
      // a draft's first save flips the route from `pendingChatDraft` to
      // `selectedItemID` under the SAME chat UUID, and only an unchanged
      // branch + unchanged `.id` lets SwiftUI keep the scaffold instance —
      // so toolbar overrides set on the draft survive the commit instead of
      // resetting with a remounted view-model.
      let draft = selectedItemID == nil ? windowState.pendingChatDraft : nil
      if let id = selectedItemID ?? draft?.id {
        ChatScaffoldView(chatID: id, draftChat: draft)
          .id(id)
      }
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
