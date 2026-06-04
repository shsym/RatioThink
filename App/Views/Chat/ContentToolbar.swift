import SwiftUI

/// Flat content-toolbar (design §5).
///
///   `[Profile: default ▾]  ─  [Model: L3.2-3B ▾]  │  [𝑇 params]  [📎 attach]  [📜 sys]`
///
/// Visual contract — verified by `ContentToolbarSnapshotTests`:
///   · No surrounding rectangle, no panel background. Sits flat on
///     `NSColor.windowBackgroundColor`.
///   · Native `SwiftUI.Menu` for pull-downs (renders as NSPopUpButton).
///   · Vertical hairline dividers (`FlatDivider`) between logical
///     groups: profile/model on one side, params/attach/sys on the
///     other.
///   · SF Symbol leading glyph per control, plain `Button`/`Menu`
///     styles only — no `.borderedProminent`, no rounded backgrounds.
///   · Subtle hover tint via `.buttonStyle(.plain)` defaults.
///
/// Attach is wired to `disabled(true)` in v1 per plan §3.4 (tooltip
/// "Available in v2"). Params / system-prompt popovers are local
/// `@State` toggles — the actual sliders/TextEditor inside live with
/// the popover content views; this file owns layout + anchoring only.
struct ContentToolbar: View {
  @ObservedObject var viewModel: ChatTranscriptViewModel
  let availableProfiles: [String]
  let availableModels: [String]
  /// Swap coordinator. Required — review v1 F9: defaulting this to a
  /// preview-only `previewDefault()` let a forgotten injection at any
  /// call site silently fall through to an orphan coordinator the
  /// rest of the app does not observe. Snapshot tests and previews
  /// build a `previewDefault()` instance at the call site explicitly.
  @ObservedObject var swapCoordinator: ProfileSwapCoordinator
  /// : the model-load indicator lives here (content toolbar) rather
  /// than the window `NSToolbar`. Optional only so snapshot/preview call
  /// sites can render the toolbar without standing up a center —
  /// `modelLoadCenter` and `onUnload` are *required* init params (no
  /// defaults) so the production wiring is compile-enforced; a missed
  /// argument in a `ChatScaffoldView` refactor would otherwise silently
  /// drop the indicator (review F2). `nil` ⇒ not shown.
  let modelLoadCenter: ModelLoadCenter?
  /// : engine lifecycle source for the status pip. Optional only so
  /// snapshot/preview call sites can render the toolbar without standing
  /// up a store; like `modelLoadCenter` it is a *required* init param (no
  /// default) so production wiring is compile-enforced. The pip shows only
  /// when BOTH `modelLoadCenter` and `engineStatus` are present.
  let engineStatus: EngineStatusStore?
  /// #412: background-helper health for the pip's outer ring. Optional like
  /// `engineStatus` so snapshot/preview call sites stay pip-less; the pip
  /// renders only when all three (center, engineStatus, helperHealth) are
  /// wired (production).
  let helperHealth: HelperHealthController?
  /// Forwarded to the indicator's running/ready popover Unload action.
  let onUnload: () -> Void

  @State private var showParamsPopover = false
  @State private var showSystemPopover = false

  init(
    viewModel: ChatTranscriptViewModel,
    availableProfiles: [String] = ["chat"],
    availableModels: [String] = ChatTranscriptViewModel.placeholderModels,
    swapCoordinator: ProfileSwapCoordinator,
    modelLoadCenter: ModelLoadCenter?,
    engineStatus: EngineStatusStore?,
    helperHealth: HelperHealthController?,
    onUnload: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self.availableProfiles = availableProfiles
    self.availableModels = availableModels
    self.swapCoordinator = swapCoordinator
    self.modelLoadCenter = modelLoadCenter
    self.engineStatus = engineStatus
    self.helperHealth = helperHealth
    self.onUnload = onUnload
  }

  var body: some View {
    HStack(spacing: 10) {
      profileMenu
      FlatDivider()
      modelMenu

      if let writeError = swapCoordinator.defaultModelWriteError {
        //  review F2: surface a failed "Set as default" write from
        // the swap popover (mirrors ProfileEditor.modelWriteError).
        Label(writeError, systemImage: "exclamationmark.triangle.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.red)
          .help(writeError)
          .accessibilityIdentifier("toolbar.setDefaultError")
          .accessibilityLabel(writeError)
      }

      Spacer(minLength: 12)

      paramsButton
      attachButton
      systemPromptButton

      // : engine-status pip on the trailing edge. Content-hosted (not
      // the window NSToolbar) so its popover presents reliably. Shown only
      // when both the load center and the engine-status store are wired
      // (production); snapshot/preview call sites pass nil and stay
      // pip-less so their reference PNGs are unchanged.
      if let modelLoadCenter, let engineStatus, let helperHealth {
        ModelLoadIndicator(
          center: modelLoadCenter,
          engineStatus: engineStatus,
          helperHealth: helperHealth,
          onUnload: onUnload
        )
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("content.toolbar")
  }

  // MARK: - controls

  private var profileMenu: some View {
    Menu {
      ForEach(availableProfiles, id: \.self) { id in
        Button(id) { selectProfile(id) }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "person.crop.circle")
        Text("Profile: \(viewModel.selectedProfileID)")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("toolbar.profile")
    // Anchor for Phase 3.6 confirmation popover. The popover content
    // closure captures the token at present time (review v2 F4) and
    // hands it back through `confirm(token:)` / `cancel(token:)` so a
    // stale callback from a superseded swap is token-mismatched and
    // dropped.
    .popover(isPresented: swapPopoverBinding, arrowEdge: .bottom) {
      if let pending = swapCoordinator.pending {
        let capturedToken = pending.id
        ProfileSwapPopover(
          pending: pending,
          estimatedTotalBytes: nil,
          estimatedEtaSeconds: nil,
          onConfirm: { setAsDefault in swapCoordinator.confirm(token: capturedToken, setAsDefault: setAsDefault) },
          onCancel:  { swapCoordinator.cancel(token: capturedToken) }
        )
      }
    }
  }

  private var modelMenu: some View {
    Menu {
      Button("Use profile default") { viewModel.modelOverride = nil }
      Divider()
      ForEach(availableModels, id: \.self) { id in
        // Stored id is the resolvable `<repo>/<file>` slug; show the
        // friendly leaf.
        Button(ModelDisplayName.leaf(id)) {
          // : route through the confirm gate. Picking a model that
          // differs from the resident model publishes a swap confirm
          // (with "Set as default for this profile"); picking the
          // already-resident model just sets the override, no load.
          swapCoordinator.requestModelOverride(
            modelID: id,
            activeProfileID: viewModel.selectedProfileID
          ) { viewModel.modelOverride = $0 }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "shippingbox")
        Text("Model: \(viewModel.modelOverride.map(ModelDisplayName.leaf) ?? "Profile default")")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("toolbar.model")
  }

  // MARK: - swap helpers

  private func selectProfile(_ id: String) {
    swapCoordinator.requestSwap(
      toProfileID: id,
      commit: { committed in viewModel.selectedProfileID = committed }
    )
  }

  /// `Binding<Bool>` derived from the coordinator's optional pending
  /// swap. Setting `false` (popover dismissal — click-outside, Esc)
  /// routes through `dismissCurrentPending()` which clears whatever
  /// pending exists at that instant. The button callbacks above use
  /// the token-checked `cancel(token:)` / `confirm(token:)` paths.
  private var swapPopoverBinding: Binding<Bool> {
    Binding(
      get: { swapCoordinator.pending != nil },
      set: { isPresented in
        if !isPresented { swapCoordinator.dismissCurrentPending() }
      }
    )
  }

  private var paramsButton: some View {
    Button {
      showParamsPopover.toggle()
    } label: {
      Image(systemName: "slider.horizontal.3")
    }
    .buttonStyle(.plain)
    .help("Sampling parameters")
    .popover(isPresented: $showParamsPopover, arrowEdge: .top) {
      ParamsPopover(sampling: $viewModel.sampling)
    }
    .accessibilityIdentifier("toolbar.params")
  }

  private var attachButton: some View {
    Button {
      // v1: disabled. v2 wires file picker + multimodal payload here.
    } label: {
      Image(systemName: "paperclip")
    }
    .buttonStyle(.plain)
    .disabled(true)
    .help("Attach (available in v2)")
    .accessibilityIdentifier("toolbar.attach")
  }

  private var systemPromptButton: some View {
    Button {
      showSystemPopover.toggle()
    } label: {
      Image(systemName: "scroll")
    }
    .buttonStyle(.plain)
    .help("System prompt")
    .popover(isPresented: $showSystemPopover, arrowEdge: .top) {
      SystemPromptPopover(text: Binding(
        get: { viewModel.systemPromptOverride ?? "" },
        set: { viewModel.systemPromptOverride = $0.isEmpty ? nil : $0 }
      ))
    }
    .accessibilityIdentifier("toolbar.sys")
  }
}

// MARK: - popover contents

private struct ParamsPopover: View {
  @Binding var sampling: ChatSampling
  @State private var temperature: Double
  @State private var topP: Double
  @State private var maxTokens: Double
  /// Latches once `commit()` runs so the dismissal flush on
  /// `.onDisappear` does not re-fire after an explicit Apply click.
  /// Today `commit()` is pure value-assignment, but Phase 6 wiring
  /// (engine POST, telemetry) would duplicate without this guard.
  /// Review v3 F1.
  ///
  /// macOS popovers do NOT auto-dismiss on `.keyboardShortcut(
  /// .defaultAction)`, so Apply leaves the popover open and the user
  /// can keep editing. Each slider's `.onChange` re-arms the latch
  /// (`didCommit = false`) so any post-Apply edit still flushes on
  /// dismissal. Review v4 F1.
  @State private var didCommit = false

  init(sampling: Binding<ChatSampling>) {
    self._sampling = sampling
    _temperature = State(initialValue: sampling.wrappedValue.temperature)
    _topP = State(initialValue: sampling.wrappedValue.topP)
    _maxTokens = State(initialValue: Double(sampling.wrappedValue.maxTokens))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sampling").font(.headline)
      slider("Temperature", value: $temperature, range: 0...2, format: "%.2f")
      slider("Top-p",       value: $topP,        range: 0...1, format: "%.2f")
      slider("Max tokens",  value: $maxTokens,   range: 64...8192, format: "%.0f", step: 64)
      Divider()
      HStack {
        Text("Changes apply on close")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Apply") { commit() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 280)
    // Any post-Apply slider edit re-arms the dismissal flush so an
    // Apply-then-edit-then-Esc sequence does not silently drop the
    // second edit. Review v4 F1. `commit()` writes to `sampling` only
    // (not the local @State values), so these `onChange` handlers are
    // not retriggered by `commit()` itself — no feedback loop.
    .onChange(of: temperature) { _, _ in didCommit = false }
    .onChange(of: topP)        { _, _ in didCommit = false }
    .onChange(of: maxTokens)   { _, _ in didCommit = false }
    // macOS popover dismissal (click-outside, Esc) is treated as
    // accept — flush the local buffer so silent edit loss is not a
    // thing. Review v1 F4. Latch prevents double-commit when Apply
    // fires immediately before dismissal. Review v3 F1.
    .onDisappear {
      if !didCommit { commit() }
    }
  }

  private func slider(
    _ label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    format: String,
    step: Double = 0.01
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text(String(format: format, value.wrappedValue))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: value, in: range, step: step)
    }
  }

  private func commit() {
    sampling = ChatSampling(
      temperature: temperature,
      topP: topP,
      maxTokens: Int(maxTokens.rounded())
    )
    didCommit = true
  }
}

private struct SystemPromptPopover: View {
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("System prompt").font(.headline)
      TextEditor(text: $text)
        .font(.body)
        .frame(width: 360, height: 160)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.secondary.opacity(0.3))
        )
      Text("Leave blank to use the profile's system prompt.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
  }
}
