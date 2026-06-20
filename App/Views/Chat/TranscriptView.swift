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
  /// #690: invoked with a Best-of-N round message + the user's action (pick /
  /// think-more / stop). Nil hides the affordance; the scaffold passes it only
  /// when no stream is in flight, and only the latest uncommitted round gets a
  /// live callback (see `bestOfNLiveID`).
  var onBestOfN: ((UUID, BestOfNAction) -> Void)? = nil
  /// The id of the one Best-of-N round that is currently interactive (the last
  /// uncommitted round, set by the scaffold while idle). Only that row shows the
  /// pick + think-more/stop controls; older rounds render read-only.
  var bestOfNLiveID: UUID? = nil
  /// #736: Best-of-N think-more guidance drafts, keyed by round message id and
  /// owned by the stable scaffold so a typed comment survives the LazyVStack
  /// row teardown that was wiping the bubble's local `@State`. Default
  /// `.constant([:])` keeps previews/tests on the per-row fallback.
  var bestOfNCommentDrafts: Binding<[UUID: String]> = .constant([:])

  /// #521/#530: THE render-path projection seam. The body builds the transcript
  /// snapshot exactly once per evaluation by calling this; the unit test renders
  /// the view and asserts a single sort pass (`TranscriptSortProbe`), so the
  /// pre-#521 "re-sort `chat.messages` N times per body" churn is caught as an
  /// exact count, not a flaky timing.
  static func projectedSnapshot(_ messages: [Message]) -> TranscriptSnapshot {
    TranscriptSnapshot(messages: messages)
  }

  var body: some View {
    let snapshot = Self.projectedSnapshot(chat.messages)
    // #513 review v1 F2: retry-anchor validity in ONE pass over the
    // already-sorted snapshot rows — a per-row `ChatRetryPlan.plan` call
    // re-sorted the transcript for every row (O(n² log n) on the render
    // path). The click path still re-plans via `ChatRetryPlan`, which
    // stays the single validity authority.
    let retryableIDs = onRetryTurn == nil
      ? Set<UUID>()
      : ChatRetryPlan.validRetryPointIDs(
          sortedRoles: snapshot.items.map { ($0.id, $0.role.rawValue) })

    return GeometryReader { geo in
      // Cap each bubble at ~72% of the row's content width (the pane minus the
      // LazyVStack's 16pt horizontal padding on each side) so bubbles hug their
      // own content instead of stretching the pane; floored, with a small floor
      // for very narrow panes.
      let maxBubble = max(120, floor((geo.size.width - 32) * 0.72))
      ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 12) {
          if snapshot.items.isEmpty {
            emptyStatePlaceholder
          }
          ForEach(snapshot.items) { item in
            MessageBubble(message: item,
                          onRetry: retryAction(for: item, retryableIDs: retryableIDs),
                          onEdit: editAction(for: item),
                          maxBubbleWidth: maxBubble,
                          onBestOfN: bestOfNAction(for: item),
                          bestOfNCommentDraft: bestOfNAction(for: item) == nil
                            ? nil
                            : Binding(
                                get: { bestOfNCommentDrafts.wrappedValue[item.id] ?? "" },
                                set: { bestOfNCommentDrafts.wrappedValue[item.id] = $0 }))
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
      // Scopes message-body queries to the transcript. The chat-list sidebar
      // (`chats.row.title`) auto-titles to the first user message (#512), and
      // the composer holds the live draft — both carry message text and live
      // OUTSIDE this scroll. A GUI count that means "how many message bubbles
      // carry this text" must search here, not app-wide (Helpers.swift
      // `transcriptTextMatchCount`).
      .accessibilityIdentifier("transcript.list")
      // #669: drop the macOS 26 top-edge scroll-edge blur here so the toolbar
      // model picker / menus opening over the transcript's top strip render on a
      // clean backdrop instead of a doubly-blurred one. No-op below macOS 26.
      .hidingTopScrollEdgeBlur()
      // Content growth within the open chat (streaming tokens, a new
      // turn) scrolls smoothly to follow the latest bubble.
      .onChange(of: snapshot.scrollKey) { _, _ in
        scrollToBottom(proxy, animated: true)
      }
      // #634: first layout of this chat (incl. a chat switch, which
      // rebuilds the scaffold via DetailView's `.id(id)`) jumps straight
      // to the bottom. Animating here replayed a scroll up from y=0 on
      // every switch — the reported redundant-scroll effect (GH #163).
      .onAppear { scrollToBottom(proxy, animated: false) }
      }
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

  /// #690: the Best-of-N interaction closure for a row, or nil for non-round
  /// rows, while a stream is in flight (`onBestOfN == nil`), and for any round
  /// other than the live one — so only the latest uncommitted round is
  /// interactive.
  private func bestOfNAction(for item: ChatMessageItem) -> ((BestOfNAction) -> Void)? {
    guard let onBestOfN, item.bestOfN != nil, item.id == bestOfNLiveID else { return nil }
    let id = item.id
    return { action in onBestOfN(id, action) }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    withAnimation(Self.scrollAnimation(animated: animated)) {
      proxy.scrollTo(Self.bottomSentinel, anchor: .bottom)
    }
  }

  /// #634: in-session content growth animates the scroll; first layout /
  /// chat switch passes `nil` so `withAnimation` is a no-op and the
  /// transcript snaps to the bottom with no visible scroll from y=0.
  static func scrollAnimation(animated: Bool) -> Animation? {
    animated ? .easeOut(duration: 0.15) : nil
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
