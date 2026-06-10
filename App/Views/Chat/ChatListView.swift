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

  private var header: some View {
    HStack {
      Text("Chats")
        .font(.headline)
      Spacer()
      Button(action: createChat) {
        Image(systemName: "square.and.pencil")
      }
      .buttonStyle(.plain)
      .help("New Chat")
      .accessibilityIdentifier("chats.newButton")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var list: some View {
    List(selection: $selectedItemID) {
      ForEach(sortedChats) { chat in
        row(for: chat)
          .tag(chat.id)
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
    ChatRowLabel(title: chat.title, updatedAt: chat.updatedAt, pinned: chat.pinned)
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
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - mutations

  private func createChat() {
    // #460: inherit the active profile + concrete model from the chat the
    // user was already in, so "New Chat" preserves the same profile/model
    // context. With no current selection (e.g. first chat) fall back to the
    // creation defaults.
    let source = selectedItemID.flatMap { id in chats.first { $0.id == id } }
    if let id = ChatCreation.create(
      in: modelContext,
      persistenceStatus: persistenceStatus,
      contextLabel: "ChatListView.createChat",
      profileID: source?.profileID ?? "chat",
      modelID: source?.modelID
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

/// #511: chat-list row content as a standalone, SwiftData-free view — its
/// real job is carrying the stable accessibility identifiers the S511
/// geometry guard asserts on (and keeping the row hostable headlessly
/// without a model container if a unit-tier layout test is ever added).
///
/// Accessibility identifiers are load-bearing for S511: the container is
/// `chats.row` and the texts are `chats.row.title` / `chats.row.timestamp`.
/// `children: .contain` keeps the child identifiers reachable (a bare
/// container id would swallow them — see `NoModelLoadedPrompt.body`).
struct ChatRowLabel: View {
  let title: String
  let updatedAt: Date
  let pinned: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if pinned {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .lineLimit(1)
          .accessibilityIdentifier("chats.row.title")
        Text(updatedAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("chats.row.timestamp")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chats.row")
  }
}
