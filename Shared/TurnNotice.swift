import Foundation

/// Terminal-state classification for an assistant turn, derived from the
/// engine's `finish_reason` plus what the turn actually produced.
///
/// Background (#434): a reasoning model can spend its whole `max_tokens`
/// budget inside the `<think>` phase and truncate (`finish_reason "length"`)
/// before emitting any answer. The turn is persisted with empty `content`
/// and a full `reasoning` block; without a notice the renderer shows only
/// the collapsible Thinking section and the reply looks blank. This type
/// lets the renderer keep its "never show a silent blank turn" rule while
/// always showing whatever output WAS produced.
///
/// Pure + value-type so the full state matrix is unit-tested without a
/// `ModelContainer` or a live engine.
public enum TurnNotice: Equatable, Sendable {
  /// Normal turn, or still streaming — render content / thinking as-is.
  case none
  /// `length` with a (partial) answer present: show the answer and attach
  /// a footnote inviting a higher limit. (Row 2.)
  case truncatedPartial
  /// `length` with reasoning but no answer — the budget went to thinking.
  /// (Row 3, the reported bug.)
  case truncatedAfterThinking
  /// `length` with nothing produced at all — no reasoning, no answer.
  /// (Row 4.)
  case truncatedNoOutput
  /// Finished cleanly (`stop` or any non-length reason) yet produced no
  /// answer. (Rows 5/6.)
  case finishedWithoutAnswer

  /// Classify a turn from its persisted state. `finishReason == nil` means
  /// no terminal chunk has arrived yet (still streaming) → `.none`, so a
  /// freshly-inserted empty bubble never flashes a truncation warning
  /// mid-stream. Whitespace-only `content` counts as "no answer".
  public static func classify(content: String, reasoning: String, finishReason: String?) -> TurnNotice {
    guard let finishReason else { return .none }
    let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasReasoning = !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch finishReason {
    case "length":
      if hasContent { return .truncatedPartial }
      return hasReasoning ? .truncatedAfterThinking : .truncatedNoOutput
    case "cancelled":
      // The send pipeline owns cancel: it keeps coherent partial content
      // and deletes empty rows, so the renderer adds nothing.
      return .none
    default:
      // "stop" and any unknown/future reason. A produced answer is normal;
      // an empty one is surfaced rather than blanked.
      return hasContent ? .none : .finishedWithoutAnswer
    }
  }

  /// One-line user-facing notice, or `nil` when nothing should be shown
  /// beyond the normal content / thinking. Copy points at the composer's
  /// "Max tokens" slider for the actionable (token-limit) cases.
  public var message: String? {
    switch self {
    case .none:
      return nil
    case .truncatedPartial:
      return "Response truncated — raise the Max tokens limit for a longer answer."
    case .truncatedAfterThinking:
      return "No answer — the model used its whole token budget thinking. Raise the Max tokens limit and ask again."
    case .truncatedNoOutput:
      return "No output — the model hit the Max tokens limit before replying. Raise it and ask again."
    case .finishedWithoutAnswer:
      return "No reply — the model finished without producing an answer."
    }
  }

  /// True when the notice is a footnote attached to an existing answer
  /// bubble (partial truncation), vs a stand-alone row that replaces a
  /// missing answer.
  public var isFootnote: Bool { self == .truncatedPartial }
}
