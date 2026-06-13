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
    // `children: .contain` keeps the nested composer/placeholder identifiers
    // reachable — a bare container id would swallow them (the lesson from
    // `NoModelLoadedPrompt` / `ChatRowLabel`).
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("newChat.view")
  }

  /// First send: create + persist the chat, select it, and hand the typed
  /// text to the mounting scaffold. Returns `true` on success so the composer
  /// clears its draft; on a create failure it returns `false` (the error is
  /// already reported by `ChatCreation.create`) so the composer KEEPS the
  /// typed text for the user to retry — matching the existing-chat persist
  /// path's draft-retry contract (review v1 F1).
  private func startChat(with text: String) -> Bool {
    guard let id = ChatCreation.create(
      in: modelContext,
      persistenceStatus: persistenceStatus,
      contextLabel: "NewChatView.startChat"
    ) else { return false }
    windowState.selectedSection = .chats
    windowState.selectedItemID = id
    windowState.pendingFirstMessage = PendingFirstMessage(chatID: id, text: text)
    return true
  }
}
