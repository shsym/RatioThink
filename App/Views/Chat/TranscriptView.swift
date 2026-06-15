import SwiftUI

/// Scrolling list of `MessageBubble`s for one persisted `Chat`.
///
/// SwiftData remains the source of truth, but each body evaluation first
/// projects `chat.messages` into a single `TranscriptSnapshot`. SwiftUI then
/// lays out and identities cheap value rows (`ChatMessageItem`) instead of
/// repeatedly sorting/traversing `Message` @Model objects while the assistant
/// is streaming.
///
/// Auto-scroll uses `ScrollViewReader` keyed on the snapshot's `(count,
/// rolling-rendered-text-length)`. Bumping `count` covers insertions/removals;
/// the rolling content+reasoning sum covers in-place edits that change visible
/// transcript height, including reasoning-only thinking streams before answer
/// content starts. Hashing the full strings would be more precise, but rendered
/// text lengths are cheap and have zero false negatives for token growth.
struct TranscriptView: View {
  let chat: Chat
  /// #513: invoked with the assistant message id the user wants to retry
  /// from. Nil (the default) hides every retry control — the scaffold
  /// passes nil while this chat has a stream in flight, so retry waits for
  /// the active stream to end.
  var onRetryTurn: ((UUID) -> Void)? = nil
  /// #624: invoked with a prior USER message id + its edited text to fork
  /// the conversation from there and re-run it. Nil (the default) hides the
  /// edit affordance — the scaffold passes nil while a stream is in flight,
  /// so an edit can't race the active turn.
  var onEditUserTurn: ((UUID, String) -> Void)? = nil

  var body: some View {
    let snapshot = TranscriptSnapshot(messages: chat.messages)
    // #513 review v1 F2: retry-anchor validity in ONE pass over the
    // already-sorted snapshot rows — a per-row `ChatRetryPlan.plan` call
    // re-sorted the transcript for every row (O(n² log n) on the render
    // path). The click path still re-plans via `ChatRetryPlan`, which
    // stays the single validity authority.
    let retryableIDs = onRetryTurn == nil
      ? Set<UUID>()
      : ChatRetryPlan.validRetryPointIDs(
          sortedRoles: snapshot.items.map { ($0.id, $0.role.rawValue) })

    return ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 12) {
          if snapshot.items.isEmpty {
            emptyStatePlaceholder
          }
          ForEach(snapshot.items) { item in
            MessageBubble(message: item,
                          onRetry: retryAction(for: item, retryableIDs: retryableIDs),
                          onEdit: editAction(for: item))
              .id(item.id)
          }
          // Sentinel row so `scrollTo(.bottomSentinel)` lands at the
          // true visual bottom regardless of last-bubble height.
          Color.clear
            .frame(height: 1)
            .id(Self.bottomSentinel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .onChange(of: snapshot.scrollKey) { _, _ in
        scrollToBottom(proxy)
      }
      .onAppear { scrollToBottom(proxy) }
    }
  }

  /// #513: the row's retry closure, or nil when retry is invalid there —
  /// not an assistant turn, or no user turn precedes it. Validity comes
  /// from the per-render `retryableIDs` set (a hidden button beats one
  /// that silently no-ops).
  private func retryAction(for item: ChatMessageItem, retryableIDs: Set<UUID>) -> (() -> Void)? {
    guard let onRetryTurn, retryableIDs.contains(item.id) else { return nil }
    let id = item.id
    return { onRetryTurn(id) }
  }

  /// #624: the row's edit-and-fork closure, or nil for non-user rows / when
  /// the scaffold withholds the hook (a stream is in flight).
  private func editAction(for item: ChatMessageItem) -> ((String) -> Void)? {
    guard let onEditUserTurn, item.role == .user else { return nil }
    let id = item.id
    return { newText in onEditUserTurn(id, newText) }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.15)) {
      proxy.scrollTo(Self.bottomSentinel, anchor: .bottom)
    }
  }

  private var emptyStatePlaceholder: some View {
    HStack(spacing: 6) {
      Image(systemName: "tray")
        .foregroundStyle(.secondary)
      Text("No messages yet — type below to start the conversation.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 24)
    .frame(maxWidth: .infinity, alignment: .center)
    .accessibilityIdentifier("transcript.empty")
  }

  private static let bottomSentinel = "transcript.bottom"
}
