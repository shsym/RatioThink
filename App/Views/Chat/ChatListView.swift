import SwiftUI
import SwiftData

/// Chat list embedded under the left Chat navigation entry. Backed by
/// SwiftData: pinned chats sort to the top, then most-recently-updated.
/// New chats are started from the titlebar new-chat button; per-row delete
/// cascades to its messages via `Chat.messages`' `.cascade` rule.
///
/// Conversation search is a sibling sidebar destination (`SidebarSection.search`
/// → `ConversationSearchView`), not an inline filter here.
struct ChatListView: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  /// #507: per-chat in-flight state — streaming rows show a right-aligned
  /// spinner, and deleting a chat first cancels + drops its send pipeline.
  @EnvironmentObject private var sendCoordinator: ChatSendCoordinator
  /// Sort by `updatedAt` desc at the query layer; pinned-first ordering happens
  /// client-side in `sortedChats` because `Bool` doesn't conform to
  /// `Comparable` and SwiftData rejects `SortDescriptor(\.pinned)` at compile
  /// time.
  @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
  @Binding var selectedItemID: UUID?
  /// The chat list is an always-mounted bottom region of the sidebar, visible
  /// regardless of the selected section. Selecting a row (or creating a chat)
  /// must therefore also route the main view back to `.chats`, so a chat opened
  /// while the Search/API view is up actually switches the detail surface to
  /// that chat.
  @Binding var selectedSection: SidebarSection?
  @State private var hoveredChatID: UUID?
  /// #512 manual rename: the chat being renamed (drives the alert) and
  /// the in-flight title draft. Kept as the chat's stable UUID, not the
  /// `Chat` reference, so a row deleted while the alert is up can't leave
  /// a dangling @Model in view state.
  @State private var renamingChatID: UUID?
  @State private var renameDraft: String = ""

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

  // De-emphasized list header: renamed "Chat List" → "Conversations" and
  // dropped the bold headline weight for a quiet secondary label.
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

  /// Row selection routes through this binding so picking a chat both
  /// selects it AND switches the main view to `.chats` — a chat chosen while
  /// the Search/API view is up replaces the detail surface.
  ///
  /// The getter is section-aware: it reports a selected row ONLY while the
  /// `.chats` section is active. In any other section the list shows no
  /// selection, so clicking even the previously-selected row is a genuine
  /// change and fires the setter — otherwise `List(selection:)` (which only
  /// fires on change) would swallow the tap and leave the user stuck in the
  /// other view.
  private var rowSelection: Binding<UUID?> {
    Binding(
      get: { selectedSection == .chats ? selectedItemID : nil },
      set: { newID in
        selectedItemID = newID
        if newID != nil { selectedSection = .chats }
      }
    )
  }

  private var list: some View {
    List(selection: rowSelection) {
      ForEach(sortedChats) { chat in
        row(for: chat)
          .tag(chat.id)
          // Share the left-menu metric so rows line up with the nav rows and
          // the header above them.
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
            Button("Rename") {
              renameDraft = chat.title
              renamingChatID = chat.id
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
    // #512 manual rename. An alert (not an inline TextField) keeps the
    // row view free of per-row edit state; the alert's implicit Cancel
    // dismisses without touching the chat.
    .alert(
      "Rename Chat",
      isPresented: Binding(
        get: { renamingChatID != nil },
        set: { if !$0 { renamingChatID = nil } }
      )
    ) {
      // No accessibilityIdentifiers here: macOS alert accessories drop
      // them, so GUI tests anchor on the field itself + button label.
      TextField("Title", text: $renameDraft)
      Button("Rename") {
        commitRename()
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func row(for chat: Chat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      ChatRowLabel(title: chat.title,
                   updatedAt: chat.updatedAt,
                   pinned: chat.pinned,
                   // #507: compact waiting indicator after the title while this
                   // chat's response streams — clears on finish/fail.
                   isStreaming: sendCoordinator.isInFlight(chat.id))
      Spacer(minLength: 6)
      if hoveredChatID == chat.id {
        Button {
          delete(chat)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Delete Chat")
        .accessibilityLabel("Delete \(chat.title)")
        .accessibilityIdentifier("chats.row.deleteButton")
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      hoveredChatID = hovering ? chat.id : (hoveredChatID == chat.id ? nil : hoveredChatID)
    }
  }

  /// Top-aligned empty placeholder + inline New Chat button. The trailing
  /// `Spacer` pins the placeholder directly under the header rather than
  /// letting it float to the vertical center.
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
      // The list is visible from any section; a New Chat created here must
      // also route the main view to the chat surface.
      selectedSection = .chats
    }
  }

  /// #512 manual rename: trim, refuse an empty result (keep the old
  /// title), set `userTitled` so the title is permanent user intent —
  /// never auto-overwritten and never pruned, even when the typed text
  /// equals the "New Chat" placeholder. `updatedAt` is untouched, like
  /// `togglePin`: the sidebar sorts on message-activity recency, and a
  /// rename would otherwise float the chat to a wrong position.
  private func commitRename() {
    defer { renamingChatID = nil }
    guard let id = renamingChatID,
          let chat = chats.first(where: { $0.id == id }) else { return }
    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let previousTitle = chat.title
    let previousUserTitled = chat.userTitled
    chat.title = trimmed
    chat.userTitled = true
    do {
      try modelContext.save()
    } catch {
      chat.title = previousTitle
      chat.userTitled = previousUserTitled
      persistenceStatus.report(error, context: "ChatListView.rename")
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
    // #507: stop any in-flight stream FIRST and drop its controller — the
    // stream writer must never write onto a Message row the cascade is
    // about to delete.
    sendCoordinator.forget(chatID: chat.id)
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
  /// #507: show the compact per-row streaming indicator
  /// (`chats.row.streaming`) while this chat has a turn in flight.
  var isStreaming: Bool = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if pinned {
        Image(systemName: "pin.fill")
          .sidebarIcon()
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .lineLimit(1)
          .truncationMode(.tail)
          .accessibilityIdentifier("chats.row.title")
        Text(updatedAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("chats.row.timestamp")
      }
      if isStreaming {
        Spacer(minLength: 4)
        ProgressView()
          .controlSize(.small)
          .accessibilityIdentifier("chats.row.streaming")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chats.row")
  }
}
