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

  var body: some View {
    let snapshot = TranscriptSnapshot(messages: chat.messages)

    return ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 12) {
          if snapshot.items.isEmpty {
            emptyStatePlaceholder
          }
          ForEach(snapshot.items) { item in
            MessageBubble(message: item)
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
