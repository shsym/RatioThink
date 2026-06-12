import Foundation
import SwiftUI

/// Transient per-chat toolbar state — profile selection (mirrored into
/// `Chat.profileID` by `ChatScaffoldView`), per-turn model override,
/// explicit sampling override, and system-prompt override. The transcript itself
/// lives in SwiftData as of Phase 4: `TranscriptView` reads
/// `chat.messages` directly and `ComposerView` inserts a `Message`
/// row through `ModelContext`.
///
/// Model override / sampling override / system-prompt override stay transient
/// for v1 — they reset to defaults when navigating away from a chat,
/// matching how popovers behave today. Persisting them onto `Chat`
/// columns is a v2 follow-up; the schema column for `profileID`
/// is the one piece that travels across navigations because the
/// design doc lists the profile as the chat's identity.
final class ChatTranscriptViewModel: ObservableObject {
  @Published var selectedProfileID: String
  @Published var modelOverride: String?
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
    modelOverride: String? = nil,
    samplingOverride: ChatSampling? = nil,
    systemPromptOverride: String? = nil
  ) {
    self.selectedProfileID = selectedProfileID
    self.modelOverride = modelOverride
    self.samplingOverride = samplingOverride
    self.systemPromptOverride = systemPromptOverride
  }
}
