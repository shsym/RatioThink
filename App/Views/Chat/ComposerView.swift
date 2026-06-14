import SwiftUI
import SwiftData
import AppKit
import os

/// Bottom-of-detail input row. Single `TextEditor` that auto-grows from
/// 1 line up to a hard 8-line ceiling, then internally scrolls.
///
/// Key handling is non-trivial on macOS: SwiftUI's `TextEditor`
/// (`NSTextView` under the hood) consumes Return for newline insertion,
/// so there is no public Combine/EnvironmentValue hook to intercept
/// "Enter submits, Shift+Enter newlines". We bridge through a tiny
/// `NSViewRepresentable` (`ComposerTextEditor`) that overrides
/// `keyDown` on a custom `NSTextView` subclass — plain Return calls
/// `onSubmit`. Any modifier (Shift/Opt/Cmd/Ctrl) falls through to
/// `super.keyDown` so the system performs its default action (Shift /
/// Opt insert a newline, Cmd-Return is reserved for menu shortcuts,
/// etc.) — review v1 F1.
struct ComposerView: View {
  /// The owning chat. Optional only as a defensive guard — a persisting
  /// composer always has a chat; `submit()` bails if it is `nil`.
  let chat: Chat?
  @ObservedObject var viewModel: ChatTranscriptViewModel
  let isSending: Bool
  /// : gate evaluated before the user message is persisted. When it
  /// returns false the draft is kept and `onSendBlocked` fires (the
  /// no-model confirm) — no user message is committed without a model
  /// to answer it.
  let shouldAllowSend: () -> Bool
  /// #516: carries the blocked draft so the parent can arm the pending
  /// auto-send with the exact text the gate is promising to deliver.
  let onSendBlocked: (String) -> Void
  let onUserMessageSaved: (Message) -> Void
  /// #507: user-intent cancel of the selected chat's in-flight turn — the
  /// composer's trailing button becomes a stop control while `isSending`.
  /// `ChatSendController.cancel` keeps a non-empty partial bubble as a
  /// cancelled turn (excluded from future request history).
  let onStop: () -> Void
  /// #516: a fired pending auto-send. The composer re-runs its normal
  /// `submit()` path — same persistence, same gate, same in-flight
  /// lifecycle as a manual send — but ONLY while the live draft still
  /// matches the text the gate promised; an edit made during the model
  /// load cancels the auto-send rather than sending mid-rewrite text.
  let autoSubmit: ComposerAutoSubmit?
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  @State private var draft: String = ""
  /// The editor's live laid-out width, captured from SwiftUI via a
  /// background `GeometryReader`. The box height is derived from `draft` +
  /// this width (see `editorHeight`), so it is computed where both inputs
  /// are known — no `NSTextView` round-trip whose width isn't valid yet at
  /// `updateNSView` time (the timing trap the first cut of #446 hit).
  @State private var editorWidth: CGFloat = 0
  @FocusState private var isFocused: Bool

  /// Auto-grow envelope. The box height tracks the editor's REAL laid-out
  /// content height (`draft` measured at the live `editorWidth`), clamped to
  /// `[lineHeight, lineHeight * maxLines]`. #446: the previous height counted
  /// only hard `\n`s, so a long line that SOFT-WRAPS stayed one line tall and
  /// the wrapped text (descenders included) clipped. Real layout accounts for
  /// wraps, hard newlines, and the font's actual metrics.
  private static let maxLines = 8
  /// Single-line floor for the box. 13pt system body lays out at ~16pt; the
  /// 18pt floor adds ~2pt of breathing room so a single line's descenders
  /// never touch the bottom edge, and serves as the per-line unit for the
  /// `maxLines` ceiling.
  private static let lineHeight: CGFloat = 18
  private static let verticalPadding: CGFloat = 8
  /// The 8-line ceiling; past it the editor scrolls internally.
  private static var maxBoxHeight: CGFloat { lineHeight * CGFloat(maxLines) }

  /// Clamp the editor's real content height into the visible box envelope.
  /// Pure + static so the auto-grow contract is unit-tested without a view
  /// host (the regression: a soft-wrapped line must yield a taller box than
  /// a single short line — newline-counting could not tell them apart).
  static func editorBoxHeight(forContentHeight h: CGFloat) -> CGFloat {
    min(max(h, lineHeight), maxBoxHeight)
  }

  /// The text's real laid-out height at a given container width — the
  /// measurement that drives auto-grow. Pure (throwaway TextKit stack, no
  /// view host) and the single source the live editor also calls, so the
  /// wrap contract is unit-testable: a soft-wrapped line is TALLER than a
  /// short one — the distinction the old hard-`\n` count could not make.
  static func contentHeight(forText text: String,
                            containerWidth: CGFloat,
                            inset: CGFloat = 0,
                            lineFragmentPadding: CGFloat = 5,
                            font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) -> CGFloat {
    guard containerWidth > 1 else { return lineHeight }
    let storage = NSTextStorage(string: text, attributes: [.font: font])
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: containerWidth, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = lineFragmentPadding
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    return layout.usedRect(for: container).height + inset * 2
  }

  /// The box height for the current draft at the live editor width.
  private var editorHeight: CGFloat {
    Self.editorHeight(forDraft: draft, editorWidth: editorWidth)
  }

  /// Compose the measure + clamp: the draft's real wrapped height at the live
  /// editor width, clamped into the 1..maxLines envelope. The `NSTextView`'s
  /// container tracks the view width, so measuring at `editorWidth` reproduces
  /// the editor's own `usedRect` (verified). Static so the auto-grow contract
  /// — a soft-wrapped draft yields a TALLER box than a short one at the same
  /// width — is unit-tested without a view host (the wiring gap the first cut
  /// of #446 missed).
  static func editorHeight(forDraft draft: String, editorWidth: CGFloat) -> CGFloat {
    editorBoxHeight(forContentHeight: contentHeight(forText: draft, containerWidth: editorWidth))
  }

  init(
    chat: Chat?,
    viewModel: ChatTranscriptViewModel,
    isSending: Bool = false,
    shouldAllowSend: @escaping () -> Bool = { true },
    onSendBlocked: @escaping (String) -> Void = { _ in },
    onUserMessageSaved: @escaping (Message) -> Void = { _ in },
    onStop: @escaping () -> Void = {},
    autoSubmit: ComposerAutoSubmit? = nil
  ) {
    self.chat = chat
    self.viewModel = viewModel
    self.isSending = isSending
    self.shouldAllowSend = shouldAllowSend
    self.onSendBlocked = onSendBlocked
    self.onUserMessageSaved = onUserMessageSaved
    self.onStop = onStop
    self.autoSubmit = autoSubmit
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ComposerTextEditor(
        text: $draft,
        onSubmit: submit
      )
      .frame(height: editorHeight)
      // Capture the editor's live width so `editorHeight` can wrap-measure
      // the draft at the real width (#446). Width is set by the HStack and is
      // independent of height, so this never feeds back into a layout loop.
      .background(
        GeometryReader { geo in
          Color.clear.preference(key: ComposerEditorWidthKey.self, value: geo.size.width)
        }
      )
      .onPreferenceChange(ComposerEditorWidthKey.self) { editorWidth = $0 }
      .padding(.horizontal, 10)
      .padding(.vertical, Self.verticalPadding)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color(nsColor: .textBackgroundColor))
          )
      )
      .focused($isFocused)
      .accessibilityIdentifier("composer.text")

      if isSending {
        // #507: while this chat's turn streams, the trailing control is a
        // stop button — the user-reachable cancel (the navigate-away cancel
        // is gone; switching chats no longer touches the stream).
        Button(action: onStop) {
          Image(systemName: "stop.circle.fill")
            .font(.system(size: 26, weight: .regular))
        }
        .buttonStyle(.plain)
        .help("Stop generating")
        .accessibilityIdentifier("composer.stop")
      } else {
        Button(action: submit) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 26, weight: .regular))
        }
        .buttonStyle(.plain)
        .disabled(trimmedDraft.isEmpty)
        .help("Send (Return). Shift+Return inserts a newline.")
        .accessibilityIdentifier("composer.send")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .onAppear {
      isFocused = true
    }
    // #516: a fired pending auto-send rides the normal submit path. The
    // tick makes consecutive fires distinguishable; the text match is the
    // edit guard (see `autoSubmit` doc).
    .onChange(of: autoSubmit) { _, request in
      guard let request, trimmedDraft == request.expectedText else { return }
      submit()
    }
  }

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submit() {
    let payload = trimmedDraft
    guard !payload.isEmpty, !isSending else { return }
    // : block before persisting if no model is resolvable. Keep the
    // draft so the user can send it once they load/choose a model.
    guard shouldAllowSend() else {
      onSendBlocked(payload)
      return
    }
    // A persisting composer always has a chat; bail rather than crash if the
    // defensive optional is ever nil.
    guard let chat else { return }
    // Establish the relationship from the to-many owning side
    // exclusively ( F11). Setting `Message.chat` AND appending
    // to `chat.messages` double-wires the inverse and has surfaced
    // duplicate to-many entries on some OS versions. SwiftData's
    // `@Relationship(inverse:)` maintains the back-pointer when
    // the message is inserted into the chat's collection.
    let message = Message(
      role: ChatMessage.Role.user.rawValue,
      content: payload,
      ts: Date()
    )
    let previousUpdatedAt = chat.updatedAt
    let previousTitle = chat.title
    modelContext.insert(message)
    chat.messages.append(message)
    chat.updatedAt = message.ts
    // #512: first real user message titles the chat — a deterministic
    // local heuristic (trim/collapse/cap), committed in the SAME save as
    // the message so it can never block or outlive the send. Only a
    // never-user-titled chat still carrying the placeholder is renamed
    // (`shouldAutoTitle`), so a manual rename wins permanently.
    if ChatLifecycle.shouldAutoTitle(chat), let title = ChatAutoTitle.derive(from: payload) {
      chat.title = title
    }
    do {
      try modelContext.save()
      draft = ""
      onUserMessageSaved(message)
    } catch {
      // UI / store divergence repair ( F8): peel the in-memory
      // mutation back so the transcript and the on-disk store stay
      // in sync. Leave the draft populated so the user can retry.
      chat.messages.removeAll { $0.id == message.id }
      modelContext.delete(message)
      chat.updatedAt = previousUpdatedAt
      chat.title = previousTitle
      persistenceStatus.report(error, context: "ComposerView.submit")
    }
  }
}

/// #516: one fired pending auto-send. `tick` increments per fire so equal
/// text on a later block still triggers `.onChange`; `expectedText` is the
/// edit guard the composer checks against its live draft.
struct ComposerAutoSubmit: Equatable {
  let tick: Int
  let expectedText: String
}

// MARK: - AppKit bridge

private let composerLog = Logger(subsystem: "com.ratiothink.app", category: "composer")

/// Carries the composer editor's measured width up so `ComposerView` can
/// wrap-measure the draft at the real width (#446 auto-grow).
private struct ComposerEditorWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// NSTextView-backed editor that:
///   · forwards plain Return to `onSubmit`
///   · lets any modifier+Return fall through to `super` (Shift / Opt
///     insert a newline; Cmd / Ctrl reach menu shortcuts) — review v1 F1.
///
/// Sizing is owned by SwiftUI (`ComposerView.editorHeight` from the draft +
/// the live editor width), not by this view — so there is no intrinsic-size
/// or height-binding plumbing here.
private struct ComposerTextEditor: NSViewRepresentable {
  @Binding var text: String
  let onSubmit: () -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    installSubmitTextView(into: scroll, coordinator: context.coordinator)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let textView: SubmitNSTextView
    if let existing = scroll.documentView as? SubmitNSTextView {
      textView = existing
    } else {
      // Document view drifted off our subclass (system-replaced
      // documentView, restoration glitch, etc.). Don't silently no-op
      // the binding — reinstall and continue. Review v1 F6.
      assertionFailure("ComposerTextEditor.updateNSView: documentView is not SubmitNSTextView; reinstalling.")
      composerLog.error("documentView lost SubmitNSTextView identity; reinstalling")
      textView = installSubmitTextView(into: scroll, coordinator: context.coordinator)
    }
    textView.onSubmit = onSubmit

    // Suppress assignment during IME composition (CJK, dictation) —
    // overwriting `.string` tears down `markedRange`. Review v1 F2.
    if textView.hasMarkedText() { return }
    if textView.string != text {
      // Preserve caret + selection across the assignment so external
      // mutations to `draft` don't yank the cursor. Review v1 F2.
      let selected = textView.selectedRanges
      textView.string = text
      textView.selectedRanges = clampedRanges(selected, to: text.utf16.count)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let parent: ComposerTextEditor
    init(_ parent: ComposerTextEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
    }
  }

  // MARK: - helpers

  /// Replaces `scroll.documentView` with a configured `SubmitNSTextView`
  /// and returns it. Used by both `makeNSView` and the
  /// `updateNSView` recovery path (F5/F6).
  @discardableResult
  private func installSubmitTextView(into scroll: NSScrollView, coordinator: Coordinator) -> SubmitNSTextView {
    // Inherit the system-provided container if `scrollableTextView()`
    // populated one — keeps layout-manager wiring intact. Otherwise
    // construct a default container so we never return an empty
    // scroll view (review v1 F5).
    let container: NSTextContainer
    let frame: NSRect
    if let existing = scroll.documentView as? NSTextView, let existingContainer = existing.textContainer {
      container = existingContainer
      frame = existing.frame
    } else {
      assertionFailure("ComposerTextEditor: scrollableTextView() did not vend an NSTextView; falling back to fresh container.")
      composerLog.error("scrollableTextView() did not vend an NSTextView; constructing fresh container")
      container = NSTextContainer(containerSize: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
      container.widthTracksTextView = true
      let layoutManager = NSLayoutManager()
      let textStorage = NSTextStorage()
      textStorage.addLayoutManager(layoutManager)
      layoutManager.addTextContainer(container)
      frame = NSRect(origin: .zero, size: scroll.contentSize)
    }

    let custom = SubmitNSTextView(frame: frame, textContainer: container)
    // `init(frame:textContainer:)` does NOT replicate the geometry contract
    // that `NSTextView.scrollableTextView()` applies to its own documentView:
    // it leaves `isVerticallyResizable == false` and clamps `min/maxSize` to
    // the seed frame height (measured ~14pt, whatever scrollableTextView()
    // vends). Frozen below the ~16pt line height, the
    // bottom of every line — descenders (q/g/p/y/j) and underline/marked
    // decorations — is clipped (#463). Restore the resizable contract so the
    // view grows to the full laid-out line height. (#446 auto-grow is the
    // SwiftUI frame envelope; this is the AppKit-side per-line layout.)
    applyResizableTextViewGeometry(to: custom)
    custom.delegate = coordinator
    custom.isEditable = true
    custom.isRichText = false
    custom.allowsUndo = true
    custom.drawsBackground = false
    custom.font = .systemFont(ofSize: NSFont.systemFontSize)
    custom.textColor = .labelColor
    custom.insertionPointColor = .labelColor
    custom.isAutomaticQuoteSubstitutionEnabled = false
    custom.isAutomaticDashSubstitutionEnabled = false
    custom.isAutomaticTextReplacementEnabled = false
    custom.isAutomaticSpellingCorrectionEnabled = false
    custom.autoresizingMask = [.width]
    custom.onSubmit = onSubmit
    scroll.documentView = custom
    return custom
  }

  /// Clamps a list of saved `NSRange`s to the new string length so
  /// shortening edits don't crash `setSelectedRanges:` with an
  /// out-of-bounds range.
  ///
  /// `NSTextView.selectedRanges` is documented non-empty for a live
  /// text view, so the post-clamp empty-array branch isn't a real
  /// dismissal path — but we still cover it for defensive parity
  /// with the AppKit contract. Review v3 F2:
  ///
  /// 1. If *every* original range started past `length` (text
  ///    shortened beyond the prior selection anchor), snap to a
  ///    single `{length, 0}` caret rather than collapse N anchors
  ///    onto the same point and rely on AppKit's implicit dedupe.
  /// 2. Otherwise dedupe collapsed zero-length ranges so a
  ///    discontiguous multi-selection that mostly survived the
  ///    shorten doesn't carry stale duplicate carets.
  private func clampedRanges(_ ranges: [NSValue], to length: Int) -> [NSValue] {
    let allBeyond = !ranges.isEmpty && ranges.allSatisfy { $0.rangeValue.location > length }
    if allBeyond {
      return [NSValue(range: NSRange(location: length, length: 0))]
    }

    let safe = ranges.map { value -> NSRange in
      let r = value.rangeValue
      let location = min(r.location, length)
      let len = min(r.length, max(0, length - location))
      return NSRange(location: location, length: len)
    }
    let deduped = dedupeCollapsedRanges(safe)
    return deduped.isEmpty
      ? [NSValue(range: NSRange(location: length, length: 0))]
      : deduped.map { NSValue(range: $0) }
  }

  /// Drops duplicate zero-length ranges while preserving order. Real
  /// (non-empty) ranges always pass through — only `{loc, 0}` clones
  /// at the same location get folded.
  private func dedupeCollapsedRanges(_ ranges: [NSRange]) -> [NSRange] {
    var seenCaretLocations = Set<Int>()
    var out: [NSRange] = []
    out.reserveCapacity(ranges.count)
    for r in ranges {
      if r.length == 0 {
        if seenCaretLocations.insert(r.location).inserted {
          out.append(r)
        }
      } else {
        out.append(r)
      }
    }
    return out
  }
}

/// Reapplies the vertically-resizable geometry that
/// `NSTextView.scrollableTextView()` gives its documentView but
/// `init(frame:textContainer:)` drops. Without it the text view is frozen at
/// its seed-frame height (measured ~14pt, whatever scrollableTextView()
/// vends) — shorter than the line height — so the bottom of each line
/// (descenders + underlines) is clipped (#463). Internal so the
/// descender-clip regression can be unit-tested.
func applyResizableTextViewGeometry(to textView: NSTextView) {
  textView.isVerticallyResizable = true
  textView.isHorizontallyResizable = false
  textView.minSize = NSSize(width: 0, height: 0)
  textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
}

/// Internal (not `private`) so the #463 descender-clip regression test can
/// install one as the scroll view's documentView and exercise the real seam.
final class SubmitNSTextView: NSTextView {
  var onSubmit: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    // Submit ONLY on bare Return / numpad Enter — any modifier
    // (Shift / Option / Command / Control) falls through to
    // `super.keyDown` so the system handles newline insertion or
    // routes the event to a menu shortcut. Review v1 F1.
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    let modifierMask: NSEvent.ModifierFlags = [.shift, .option, .command, .control]
    let hasModifier = !event.modifierFlags.intersection(modifierMask).isEmpty
    if isReturn && !hasModifier {
      onSubmit?()
      return
    }
    super.keyDown(with: event)
  }
}
