import Foundation
import SwiftUI

/// Transient per-chat toolbar state — profile selection (mirrored into
/// `Chat.profileID` by `ChatScaffoldView`), explicit sampling override and
/// system-prompt override. The transcript itself lives in SwiftData as of
/// Phase 4: `TranscriptView` reads `chat.messages` directly and
/// `ComposerView` inserts a `Message` row through `ModelContext`.
///
/// #460: the selected MODEL is no longer a transient view-model field. It
/// is persisted on `Chat.modelID` (the single selection authority) and the
/// toolbar reads/writes it directly through `ChatScaffoldView`, so the
/// selection survives navigation/relaunch and a profile switch instead of
/// resetting. Sampling / system-prompt override stay transient for v1 —
/// they reset to defaults when navigating away, matching how popovers
/// behave today; persisting them onto `Chat` is a separate follow-up.
final class ChatTranscriptViewModel: ObservableObject {
  @Published var selectedProfileID: String
  @Published var samplingOverride: ChatSampling?
  @Published var systemPromptOverride: String?

  /// Default model surface in the model pull-down until Phase 6 wires
  /// the engine `/v1/models` listing in. Static so previews and tests
  /// can read it without instantiating the view model.
  static let placeholderModels: [String] = [
    ProfileStore.defaultChatModelID,
    "llama-3.1-8b-instruct",
    "llama-3.2-3b-instruct",
    "qwen2.5-7b-instruct",
  ]

  init(
    selectedProfileID: String = "chat",
    samplingOverride: ChatSampling? = nil,
    systemPromptOverride: String? = nil
  ) {
    self.selectedProfileID = selectedProfileID
    self.samplingOverride = samplingOverride
    self.systemPromptOverride = systemPromptOverride
  }
}
