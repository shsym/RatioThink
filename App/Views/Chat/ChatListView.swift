import SwiftUI
import SwiftData

/// Col 2 chat list — backed by SwiftData. Pinned chats sort to the
/// top, then most-recently-updated. "New Chat" inserts a fresh row
/// and selects it; per-row delete cascades to its messages via
/// `Chat.messages`' `.cascade` rule.
struct ChatListView: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  /// Sort by `updatedAt` desc at the query layer; pinned-first
  /// ordering happens client-side in `sortedChats` because `Bool`
  /// doesn't conform to `Comparable` and SwiftData rejects
  /// `SortDescriptor(\.pinned)` at compile time.
  @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
  @Binding var selectedItemID: UUID?

  private var sortedChats: [Chat] {
    chats.sorted { lhs, rhs in
      if lhs.pinned != rhs.pinned { return lhs.pinned }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.6)
      if chats.isEmpty {
        emptyState
      } else {
        list
      }
    }
  }

  // De-emphasized list header. Renamed "Chats" → "Conversations" and dropped
  // the bold headline weight for a quiet secondary label. The new-chat button
  // moved to the titlebar (RootView) so this header carries no control — the
  // `chats.newButton` identity lives there now.
  private var header: some View {
    HStack {
      Text("Conversations")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
    .padding(.vertical, SidebarMetrics.rowVerticalPadding)
  }

  private var list: some View {
    List(selection: $selectedItemID) {
      ForEach(sortedChats) { chat in
        row(for: chat)
          .tag(chat.id)
          // Share the left-menu horizontal/vertical metric so list rows line
          // up with the col-1 nav rows and the header above them.
          .listRowInsets(EdgeInsets(
            top: SidebarMetrics.rowVerticalPadding,
            leading: SidebarMetrics.rowHorizontalPadding,
            bottom: SidebarMetrics.rowVerticalPadding,
            trailing: SidebarMetrics.rowHorizontalPadding
          ))
          .contextMenu {
            Button(chat.pinned ? "Unpin" : "Pin") {
              togglePin(chat)
            }
            Divider()
            Button("Delete", role: .destructive) {
              delete(chat)
            }
          }
      }
      .onDelete { offsets in
        let snapshot = sortedChats
        for index in offsets {
          delete(snapshot[index])
        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("chats.list")
  }

  private func row(for chat: Chat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: SidebarMetrics.rowSpacing) {
      if chat.pinned {
        Image(systemName: "pin.fill")
          .sidebarIcon()
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(chat.title)
          .lineLimit(1)
        Text(chat.updatedAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Top-aligned per design §5 ("Chats section empty → grayed
  /// placeholder row + inline New chat button"). The trailing `Spacer`
  /// pins the placeholder directly under the header rather than letting
  /// it float to the vertical center the way `ContentUnavailableView`
  /// would.
  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No chats yet")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Button(action: createChat) {
        Label("New Chat", systemImage: "square.and.pencil")
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("chats.empty.newButton")
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
    .padding(.vertical, SidebarMetrics.rowVerticalPadding)
  }

  // MARK: - mutations

  private func createChat() {
    if let id = ChatCreation.create(
      in: modelContext,
      persistenceStatus: persistenceStatus,
      contextLabel: "ChatListView.createChat"
    ) {
      selectedItemID = id
    }
  }

  /// Pin / unpin without touching `updatedAt` — the sort uses
  /// recency for the *unpinned* section, so bumping it on a pin
  /// toggle would float the chat to a wrong position the next time
  /// it unpins ( F2 / F9).
  private func togglePin(_ chat: Chat) {
    let previous = chat.pinned
    chat.pinned.toggle()
    do {
      try modelContext.save()
    } catch {
      chat.pinned = previous
      persistenceStatus.report(error, context: "ChatListView.togglePin")
    }
  }

  private func delete(_ chat: Chat) {
    let wasSelected = (selectedItemID == chat.id)
    modelContext.delete(chat)
    do {
      try modelContext.save()
    } catch {
      // SwiftData's `delete` mutates the in-memory graph
      // immediately, so the sidebar would otherwise show the row
      // gone with a red toast and no way to recover ( F22).
      // `rollback()` undoes the pending delete (and any other
      // unsaved mutations in this context); the row reappears on
      // the next `@Query` tick. Reselect untouched — the row is
      // back, the user can retry.
      modelContext.rollback()
      persistenceStatus.report(error, context: "ChatListView.delete")
      return
    }
    if wasSelected {
      selectedItemID = nil
    }
  }
}
