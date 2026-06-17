import Foundation

/// App-wide, engine-true context-window observability (#711).
///
/// Holds the effective KV-budget context window (in tokens) of the
/// loaded model — `budget_pages × tokens_per_page`, as reported on each
/// chat turn's `usage` frame. Distinct from the per-conversation meter
/// (`ChatTranscriptViewModel.contextUsage`, which also tracks occupancy):
/// the window is a model-global value, so the memory-settings screen reads
/// it to show the expected max context without standing up a chat.
///
/// Session-scoped: republished from live turns, not persisted. Until the
/// engine reports a budget this session, `tokens` is `nil` and readers
/// render a "run a turn to measure" fallback rather than a wrong number.
@MainActor
public final class EngineContextWindow: ObservableObject {
  @Published public private(set) var tokens: Int?

  public init(tokens: Int? = nil) {
    self.tokens = tokens
  }

  /// Record a window observed from a chat `usage` frame. A `nil` or
  /// non-positive window (engine could not measure the budget) must not
  /// erase a previously known good value, so it is ignored.
  public func record(_ window: Int?) {
    guard let window, window > 0 else { return }
    tokens = window
  }
}
