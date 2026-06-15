import SwiftUI

/// Scrolling list of `MessageBubble`s for one persisted `Chat`. Reads
/// directly off the `@Model` `Chat.messages` relationship, which
/// SwiftUI observes through SwiftData's `Observable` conformance —
/// inserting a new `Message` (or appending streaming deltas to an
/// existing row's `content` via `MessageStreamWriter`) re-runs the
/// body and pushes the scroller to the latest bubble.
///
/// Auto-scroll uses `ScrollViewReader` keyed on `(count,
/// rolling-content-length)`. Bumping `count` covers insertions /
/// removals; the rolling sum covers in-place edits (streaming-token
/// growth). Hashing/checksumming the full content string would be
/// more precise but `&+`-summed lengths are cheap enough to compute
/// on every redraw and have zero false negatives for "something
/// changed."
struct TranscriptView: View {
  let chat: Chat
  /// True while a turn is streaming — suppresses the edit affordance so a
  /// prior user turn can't be forked mid-stream (#624).
  var isSending: Bool = false
  /// Edit-and-resend hook (#624): fork the conversation from `message`
  /// (a user turn) with new text. Holds the persisted `Message` the
  /// renderer's value projection can't carry up on its own.
  var onEditAndResend: (Message, String) -> Void = { _, _ in }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 12) {
          if sortedMessages.isEmpty {
            emptyStatePlaceholder
          }
          ForEach(sortedMessages) { msg in
            MessageBubble(
              message: ChatMessageItem(msg),
              // Editable only for a user turn, and never mid-stream.
              onEdit: (!isSending && msg.role == ChatMessage.Role.user.rawValue)
                ? { newText in onEditAndResend(msg, newText) }
                : nil
            )
            .id(msg.id)
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
      .onChange(of: scrollKey) { _, _ in
        scrollToBottom(proxy)
      }
      .onAppear { scrollToBottom(proxy) }
    }
  }

  private var sortedMessages: [Message] {
    chat.messages.sorted { $0.ts < $1.ts }
  }

  /// Watches the full transcript so insertions / removals / in-place
  /// edits *anywhere* trigger a scroll, not just on the tail message.
  private var scrollKey: String {
    let lengthSum = sortedMessages.reduce(0) { $0 &+ $1.content.count }
    return "\(sortedMessages.count):\(lengthSum)"
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
