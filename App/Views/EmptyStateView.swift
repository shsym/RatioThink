import SwiftUI

/// Detail empty-state shown when no item is selected: a large `Start Chat`
/// CTA for col 3. (The former `Add Endpoint` CTA is gone — the local API is
/// the engine's single endpoint, surfaced via the API Endpoints section.)
struct EmptyStateView: View {
  @EnvironmentObject private var windowState: WindowState

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "sparkles")
        .font(.system(size: 56, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Welcome to Rational")
        .font(.title2.weight(.semibold))
      Text("Run local models. Serve them over HTTP.")
        .font(.body)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ctaButton(title: "Start Chat", systemImage: "bubble.left.and.bubble.right", action: startChat)
        // No "Add Endpoint" CTA: the local API is the engine's single
        // endpoint, viewed via the sidebar's API Endpoints section
        // (LocalAPIView, #422) — there is nothing to create here.
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

  /// Open the same non-persisting draft as the conversation-list affordance.
  /// The chat appears in the sidebar only after its first message is saved.
  private func startChat() {
    windowState.beginChatDraft(profileID: ProfileStore.defaultProfileID)
  }
}
