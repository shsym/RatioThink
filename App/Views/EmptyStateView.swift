import SwiftUI
import SwiftData

/// Detail empty-state shown when no item is selected. Design §5 specifies
/// large `Start Chat` + `Add Endpoint` CTAs as the zero-state for col 3.
struct EmptyStateView: View {
  @EnvironmentObject private var windowState: WindowState
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  @Environment(\.modelContext) private var modelContext

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "sparkles")
        .font(.system(size: 56, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Welcome to RatioThink")
        .font(.title2.weight(.semibold))
      Text("Run local models. Serve them over HTTP.")
        .font(.body)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ctaButton(title: "Start Chat", systemImage: "bubble.left.and.bubble.right", action: startChat)
        // v0.1.1: "Add Endpoint" hidden — the API Endpoints feature is not
        // shipping yet (mirrors the hidden sidebar row). Re-add this CTA (and
        // `addEndpoint()` + the `endpointStore` injection) to re-enable.
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func ctaButton(
    title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
        Text(title)
      }
      .frame(minWidth: 140)
    }
    .controlSize(.large)
    .accessibilityIdentifier(title)
  }

  /// Create a chat and route the shell to it — mirrors the chat-list
  /// New Chat affordance so the zero-state CTA lands the user in a live
  /// chat rather than dead-ending.
  private func startChat() {
    guard let id = ChatCreation.create(
      in: modelContext,
      persistenceStatus: persistenceStatus,
      contextLabel: "EmptyStateView.startChat"
    ) else { return }
    windowState.selectedSection = .chats
    windowState.selectedItemID = id
  }
}
