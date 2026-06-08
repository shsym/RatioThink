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
  let chat: Chat
  @ObservedObject var viewModel: ChatTranscriptViewModel
  let isSending: Bool
  /// : gate evaluated before the user message is persisted. When it
  /// returns false the draft is kept and `onSendBlocked` fires (the
  /// no-model confirm) — no user message is committed without a model
  /// to answer it.
  let shouldAllowSend: () -> Bool
  let onSendBlocked: () -> Void
  let onUserMessageSaved: (Message) -> Void
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  @State private var draft: String = ""
  @FocusState private var isFocused: Bool

  /// Single line height target. SwiftUI's `TextEditor` measures itself
  /// from intrinsic content height; we sample once via `lineHeight`
  /// helper and clamp `1...maxLines` lines for the visual box.
  private static let minLines = 1
  private static let maxLines = 8
  /// Empirically measured at 13pt system body; matches the `NSTextView`
  /// default line height closely enough to avoid one-pixel jitter on
  /// the first line.
  private static let lineHeight: CGFloat = 18
  private static let verticalPadding: CGFloat = 8

  init(
    chat: Chat,
    viewModel: ChatTranscriptViewModel,
    isSending: Bool = false,
    shouldAllowSend: @escaping () -> Bool = { true },
    onSendBlocked: @escaping () -> Void = {},
    onUserMessageSaved: @escaping (Message) -> Void = { _ in }
  ) {
    self.chat = chat
    self.viewModel = viewModel
    self.isSending = isSending
    self.shouldAllowSend = shouldAllowSend
    self.onSendBlocked = onSendBlocked
    self.onUserMessageSaved = onUserMessageSaved
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ComposerTextEditor(
        text: $draft,
        onSubmit: submit
      )
      .frame(minHeight: minHeight, maxHeight: maxHeight)
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

      Button(action: submit) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 26, weight: .regular))
      }
      .buttonStyle(.plain)
      .disabled(trimmedDraft.isEmpty || isSending)
      .help("Send (Return). Shift+Return inserts a newline.")
      .accessibilityIdentifier("composer.send")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .onAppear { isFocused = true }
  }

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var lineCount: Int {
    // +1 because N newlines means N+1 lines; clamp to [min, max] for
    // the visual envelope — overflow scrolls inside the editor.
    let newlines = draft.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    return max(Self.minLines, min(Self.maxLines, newlines + 1))
  }

  private var minHeight: CGFloat { Self.lineHeight }
  private var maxHeight: CGFloat { Self.lineHeight * CGFloat(lineCount) }

  private func submit() {
    let payload = trimmedDraft
    guard !payload.isEmpty, !isSending else { return }
    // : block before persisting if no model is resolvable. Keep the
    // draft so the user can send it once they load/choose a model.
    guard shouldAllowSend() else {
      onSendBlocked()
      return
    }
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
    modelContext.insert(message)
    chat.messages.append(message)
    chat.updatedAt = message.ts
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
      persistenceStatus.report(error, context: "ComposerView.submit")
    }
  }
}

// MARK: - AppKit bridge

private let composerLog = Logger(subsystem: "com.ratiothink.app", category: "composer")

/// NSTextView-backed editor that:
///   · forwards plain Return to `onSubmit`
///   · lets any modifier+Return fall through to `super` (Shift / Opt
///     insert a newline; Cmd / Ctrl reach menu shortcuts) — review v1 F1.
///   · auto-resizes by reporting its intrinsic content size through the
///     SwiftUI layout system
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
    // the seed frame height (14pt). Frozen below the ~16pt line height, the
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
/// its seed-frame height (14pt) — shorter than the line height — so the
/// bottom of each line (descenders + underlines) is clipped (#463). Internal
/// so the descender-clip regression can be unit-tested.
func applyResizableTextViewGeometry(to textView: NSTextView) {
  textView.isVerticallyResizable = true
  textView.isHorizontallyResizable = false
  textView.minSize = NSSize(width: 0, height: 0)
  textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
}

private final class SubmitNSTextView: NSTextView {
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
