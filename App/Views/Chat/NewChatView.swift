import SwiftUI
import SwiftData

/// #577: the ready new-chat composer shown for the `.chats` section with no
/// selected chat (the "start" landing). It mirrors the chat scaffold's
/// bottom-composer layout but persists NOTHING until the first send — no
/// `Chat` row exists while the user is just looking at it, so the start
/// entry can never spawn an orphan draft (the #512 prune stays a
/// belt-and-braces safety net for shells from other paths).
///
/// On the first send the draft composer forwards the typed text; this view
/// creates + selects the chat and stashes the text on
/// `WindowState.pendingFirstMessage`. `DetailView` then mounts the real
/// `ChatScaffoldView`, which consumes the handoff and runs the normal send
/// path (persist user message + auto-title + assistant turn + no-model gate).
struct NewChatView: View {
  @EnvironmentObject private var windowState: WindowState
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  @Environment(\.modelContext) private var modelContext
  /// A throwaway view-model: `ComposerView` requires one, but a draft-mode
  /// composer (chat: nil) never reads it — the real one is created with the
  /// chat once the scaffold mounts.
  @StateObject private var draftViewModel = ChatTranscriptViewModel()

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 16) {
        Spacer()
        Image(systemName: "sparkles")
          .font(.system(size: 48, weight: .regular))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("New chat")
          .font(.title2.weight(.semibold))
        Text("Type a message below to start. Nothing is saved until you send.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("newChat.placeholder")

      ComposerView(
        chat: nil,
        viewModel: draftViewModel,
        onDraftSubmit: startChat(with:)
      )
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("newChat.view")
  }

  /// First send: create + persist the chat, select it, and hand the typed
  /// text to the mounting scaffold. If creation fails the text is dropped
  /// (the error is already reported by `ChatCreation.create`); the composer
  /// has cleared its draft, mirroring a failed persist on an existing chat.
  private func startChat(with text: String) {
    guard let id = ChatCreation.create(
      in: modelContext,
      persistenceStatus: persistenceStatus,
      contextLabel: "NewChatView.startChat"
    ) else { return }
    windowState.selectedSection = .chats
    windowState.selectedItemID = id
    windowState.pendingFirstMessage = PendingFirstMessage(chatID: id, text: text)
  }
}
