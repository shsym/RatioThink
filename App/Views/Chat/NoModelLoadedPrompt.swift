import SwiftUI

/// Shown when the user sends a chat with no model resolvable (no
/// per-chat override and nothing resident). The send is blocked —
/// RatioThink never loads a model the user did not explicitly choose.
///
/// #326: the prompt is download-aware. `MissingModelRecovery.promptAction`
/// decides the model-availability action:
///   · `.load`     — the model is on disk; offer to load it now.
///   · `.download`  — the model isn't downloaded yet; offer to download
///     it inline (no detour to Settings), then auto-start the engine.
///   · `.unavailable` — no default / not single-file-downloadable; point
///     the user at the toolbar Model menu or Settings → Models.
///
/// #397: the prompt is also lifecycle-aware. When the engine or a model
/// load is still in flight (`ChatStartGate.State.busy`) it shows a calm
/// "starting / loading…" wait instead of the misleading "No model
/// loaded" — and for the `.load` case the headline is the benign "Model
/// not loaded yet" (the model is on disk, just not loaded), not the
/// error-toned "No model loaded". The `.load` action starts a stopped
/// engine first (see `ChatScaffoldView.loadDefaultModel`), where the
/// pre-#397 `loadDirect` would have no-opped against a stopped engine.
///
/// Loading or downloading spends resources only as a direct consequence
/// of the user acting here.
struct NoModelLoadedPrompt: View {
  /// #397 lifecycle state — gates the "busy" wait-framing.
  let gateState: ChatStartGate.State
  /// #326 model-availability action.
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
      if case let .busy(phase) = gateState {
        busyContent(phase)
      } else {
        availabilityContent
      }
    }
    .padding(20)
    .frame(width: 360)
    .accessibilityIdentifier("noModel.prompt")
  }

  // MARK: - #397 busy wait

  /// Engine/model still coming up. Calm wait copy, no Load/Download
  /// affordance that would double-fire — the caller auto-dismisses the
  /// sheet once a model resolves.
  @ViewBuilder
  private func busyContent(_ phase: ChatStartGate.BusyPhase) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "hourglass").foregroundStyle(.secondary)
      Text(busyTitle(phase)).font(.headline)
    }
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(busyDetail(phase))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    HStack {
      Button("Cancel", role: .cancel) { onCancel() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("noModel.cancel")
      Spacer()
    }
  }

  // MARK: - #326 model-availability

  @ViewBuilder
  private var availabilityContent: some View {
    HStack(spacing: 8) {
      Image(systemName: "cpu").foregroundStyle(.secondary)
      Text(availabilityTitle).font(.headline)
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
        .accessibilityIdentifier("noModel.cancel")
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

  // MARK: - copy

  /// #397 framing: `.load` means the model is on disk, just not loaded
  /// yet — benign. `.download` / `.unavailable` genuinely have no model
  /// ready, so they keep "No model loaded" (also what the #326
  /// fresh-install download GUI test pins).
  private var availabilityTitle: String {
    if case .load = action { return "Model not loaded yet" }
    return "No model loaded"
  }

  private func busyTitle(_ phase: ChatStartGate.BusyPhase) -> String {
    switch phase {
    case .startingEngine:          return "Starting the engine…"
    case .stoppingEngine:          return "Stopping the engine…"
    case let .loadingModel(model): return "Loading \(ModelDisplayName.leaf(model))…"
    }
  }

  private func busyDetail(_ phase: ChatStartGate.BusyPhase) -> String {
    switch phase {
    case .startingEngine:
      return "Your model is loading — your message will send once it's ready."
    case .stoppingEngine:
      return "One moment…"
    case .loadingModel:
      return "Hang tight — the model is loading."
    }
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
