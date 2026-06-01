import SwiftUI

/// Shown when the user sends a chat with no model resolvable (no
/// per-chat override and nothing resident). The send is blocked —
/// RatioThink never loads a model the user did not explicitly choose.
///
/// #326: the prompt is download-aware. The action is decided by
/// `MissingModelRecovery.promptAction`:
///   · `.load`     — the model is on disk; offer to load it now.
///   · `.download`  — the model isn't downloaded yet; offer to download
///     it inline (no detour to Settings), then auto-start the engine.
///   · `.unavailable` — no default / not single-file-downloadable; point
///     the user at the toolbar Model menu or Settings → Models.
/// Loading or downloading spends resources only as a direct consequence
/// of the user acting here.
struct NoModelLoadedPrompt: View {
  let action: MissingModelRecovery.PromptAction
  let onLoad: (String) -> Void
  /// Called once the inline download completes — the parent starts the
  /// engine on the active profile so the freshly-downloaded model loads.
  let onDownloaded: () -> Void
  let onChooseAnother: () -> Void
  let onCancel: () -> Void
  /// Live engine status, threaded into the download CTA (PR#15 F1).
  let engineStatus: EngineStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: "cpu")
          .foregroundStyle(.secondary)
        Text("No model loaded")
          .font(.headline)
      }

      switch action {
      case let .load(model):
        Text("Load this profile's default model to send your message?")
          .fixedSize(horizontal: false, vertical: true)
        modelChip(model)
      case let .download(target):
        Text("This profile's model isn't downloaded yet. Download it to send your message.")
          .fixedSize(horizontal: false, vertical: true)
        MissingModelDownloadCTA(target: target, onDownloaded: onDownloaded, engineStatus: engineStatus)
      case .unavailable:
        Text("This profile has no model ready. Choose one from the Model menu in the toolbar, or add one in Settings → Models.")
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Choose another") { onChooseAnother() }
          .accessibilityIdentifier("noModel.chooseAnother")
        if case let .load(model) = action {
          Button("Load") { onLoad(model) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("noModel.load")
        }
      }
    }
    .padding(20)
    .frame(width: 360)
    .accessibilityIdentifier("noModel.prompt")
  }

  /// Stored model is the resolvable slug; show the friendly leaf.
  private func modelChip(_ model: String) -> some View {
    Text(ModelDisplayName.leaf(model))
      .monospaced()
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
  }
}
