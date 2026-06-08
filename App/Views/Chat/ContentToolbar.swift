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
  /// #459's option list for the model menu (checkmark on current,
  /// profile-default annotation, unavailable reasons, "Manage Models…").
  /// Built by `ChatScaffoldView` from `Chat.modelID` (the #460 authority) +
  /// the served/discovered models.
  let modelOptions: [ToolbarModelOptions.Option]
  /// #459's collapsed model-menu summary (concrete leaf + optional
  /// annotation). `ChatScaffoldView` derives it from `Chat.modelID`.
  let currentModelSummary: ToolbarModelOptions.CurrentSummary?
  /// #460: the chat's persisted selected model (`Chat.modelID`) — the single
  /// selection authority. Resolves the swap-policy "from model" and the
  /// model-menu clear-vs-load decision; `nil` ⇒ the chat follows the active
  /// profile's default. NOT engine residency (residency is not a selection
  /// source under the single authority).
  let selectedModelID: String?
  /// #460: the active profile's default model — resolves the effective
  /// "from model" (`selectedModelID ?? profileDefaultModel`) the swap policy
  /// compares against.
  let profileDefaultModel: String?
  /// #460: persists a confirmed profile swap (profile + optional pinned
  /// model) — wired by `ChatScaffoldView`, which owns the SwiftData write.
  /// Returns `false` when the model-pin save failed (review F2) so the
  /// coordinator skips the load and the profile is left unswitched.
  let commitSwap: ProfileSwapCoordinator.SwapCommit
  /// #460: persists a per-chat model selection — wired by `ChatScaffoldView`.
  /// Returns `false` on a save failure so the coordinator skips the load.
  let commitModel: (String) -> Bool
  /// #460: clears the per-chat model pin so the chat follows the profile
  /// default again — wired by `ChatScaffoldView`.
  let onUseProfileDefault: () -> Void
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
  /// The reconciled engine-lifecycle fold for the pip + its popover. Optional
  /// like the others so snapshot/preview sites stay pip-less; the pip renders
  /// only when it (with center/engineStatus/helperHealth) is wired.
  let engineLifecycle: EngineLifecycle?
  /// Forwarded to the indicator's running/ready popover Unload action.
  let onUnload: () -> Void
  /// Forwarded to the indicator's offline (engine-stopped) popover "Start
  /// engine" action.
  let onStartEngine: () -> Void

  @Environment(\.openSettings) private var openSettings
  @EnvironmentObject private var settingsNavigation: SettingsNavigation

  @State private var showParamsPopover = false
  @State private var showSystemPopover = false

  init(
    viewModel: ChatTranscriptViewModel,
    availableProfiles: [String] = ["chat"],
    modelOptions: [ToolbarModelOptions.Option] = [],
    currentModelSummary: ToolbarModelOptions.CurrentSummary? = nil,
    selectedModelID: String? = nil,
    profileDefaultModel: String? = nil,
    commitSwap: @escaping ProfileSwapCoordinator.SwapCommit = { _, _ in true },
    commitModel: @escaping (String) -> Bool = { _ in true },
    onUseProfileDefault: @escaping () -> Void = {},
    swapCoordinator: ProfileSwapCoordinator,
    modelLoadCenter: ModelLoadCenter?,
    engineStatus: EngineStatusStore?,
    helperHealth: HelperHealthController?,
    engineLifecycle: EngineLifecycle?,
    onUnload: @escaping () -> Void,
    onStartEngine: @escaping () -> Void = {}
  ) {
    self.viewModel = viewModel
    self.availableProfiles = availableProfiles
    self.modelOptions = modelOptions
    self.currentModelSummary = currentModelSummary
    self.selectedModelID = selectedModelID
    self.profileDefaultModel = profileDefaultModel
    self.commitSwap = commitSwap
    self.commitModel = commitModel
    self.onUseProfileDefault = onUseProfileDefault
    self.swapCoordinator = swapCoordinator
    self.modelLoadCenter = modelLoadCenter
    self.engineStatus = engineStatus
    self.helperHealth = helperHealth
    self.engineLifecycle = engineLifecycle
    self.onUnload = onUnload
    self.onStartEngine = onStartEngine
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
      if let modelLoadCenter, let engineStatus, let helperHealth, let engineLifecycle {
        ModelLoadIndicator(
          center: modelLoadCenter,
          engineStatus: engineStatus,
          helperHealth: helperHealth,
          lifecycle: engineLifecycle,
          onUnload: onUnload,
          onStartEngine: onStartEngine
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
          onCancel:  { swapCoordinator.cancel(token: capturedToken) },
          onKeepCurrent: { swapCoordinator.keepCurrentModel(token: capturedToken) }
        )
      }
    }
  }

  /// #460: the chat's effective current model — the explicit pin
  /// (`selectedModelID`) or, when unpinned, the active profile's default.
  /// This is the single value the swap policy treats as "the current
  /// model", so it stays correct whether the model is loaded or loading.
  private var effectiveModelID: String? {
    selectedModelID ?? profileDefaultModel
  }

  private var modelMenu: some View {
    Menu {
      // #459's richer option list (checkmark on current, profile-default
      // annotation, unavailable reasons, "Manage Models…") kept; the write
      // is routed to `Chat.modelID` (the #460 authority) in `selectModel`.
      ForEach(modelOptions) { option in
        Button {
          selectModel(option)
        } label: {
          modelOptionLabel(option)
        }
        .help(option.unavailableReason.map { "\(option.slug) — \($0)" } ?? option.slug)
        .accessibilityValue(option.unavailableReason.map { "\(option.slug), \($0)" } ?? option.slug)
        .disabled(!option.isSelectable)
      }
      if !modelOptions.isEmpty { Divider() }
      Button {
        openModelsSettings()
      } label: {
        Label("Manage Models…", systemImage: "gearshape")
      }
      .help("Open Settings → Models")
      .accessibilityIdentifier("toolbar.model.manageModels")
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "shippingbox")
        // #462: bound the title so a long model name truncates rather than
        // pushing the toolbar past the window edge. No `.fixedSize()` — it
        // would pin the label non-compressible and re-break layout. The full
        // id stays inspectable via the menu-level `.help(modelMenuHelp)` +
        // accessibility value below. #460: `modelMenuTitle` reads
        // `currentModelSummary`, which `ChatScaffoldView` builds from
        // `Chat.modelID` (the authority).
        Text("Model: \(modelMenuTitle)")
          .boundedModelName()
      }
    }
    .menuStyle(.borderlessButton)
    .help(modelMenuHelp)
    .accessibilityIdentifier("toolbar.model")
    .accessibilityLabel("Model")
    .accessibilityValue(modelMenuAccessibilityValue)
  }

  @ViewBuilder
  private func modelOptionLabel(_ option: ToolbarModelOptions.Option) -> some View {
    let text = modelOptionText(option)
    if option.isCurrent {
      Label(text, systemImage: "checkmark")
    } else if option.unavailableReason != nil {
      Label(text, systemImage: "exclamationmark.triangle")
    } else {
      Text(text)
    }
  }

  private func modelOptionText(_ option: ToolbarModelOptions.Option) -> String {
    var text = option.displayName + (option.isProfileDefault ? " (profile default)" : "")
    if let reason = option.unavailableReason { text += " — \(reason)" }
    return text
  }

  private var modelMenuTitle: String {
    guard let currentModelSummary else { return "Choose model" }
    if currentModelSummary.annotation != nil {
      return "\(currentModelSummary.displayName) (Default)"
    }
    return currentModelSummary.displayName
  }

  private var modelMenuHelp: String {
    guard let currentModelSummary else { return "Choose a model" }
    if let annotation = currentModelSummary.annotation {
      return "\(annotation): \(currentModelSummary.slug)"
    }
    return currentModelSummary.slug
  }

  private var modelMenuAccessibilityValue: String {
    guard let currentModelSummary else { return "No model selected" }
    if let annotation = currentModelSummary.annotation {
      return "\(currentModelSummary.slug), \(annotation)"
    }
    return currentModelSummary.slug
  }

  /// Pure label derivation (#460) — `internal` (not `private`) so the
  /// label-stability contract is unit-tested without a view host: the same
  /// inputs always yield the same friendly leaf, so a preserved selection
  /// renders an unchanged label across a profile switch / new chat. The
  /// collapsed toolbar label itself now renders the richer #459
  /// `modelMenuTitle` (built from `currentModelSummary`); this pure helper
  /// pins the leaf-derivation contract that the summary relies on.
  static func modelLabel(selectedModelID: String?, profileDefaultModel: String?) -> String {
    if let selectedModelID, !selectedModelID.isEmpty { return ModelDisplayName.leaf(selectedModelID) }
    if let profileDefaultModel, !profileDefaultModel.isEmpty { return ModelDisplayName.leaf(profileDefaultModel) }
    return "Profile default"
  }

  // MARK: - swap helpers

  private func selectProfile(_ id: String) {
    // #460: compare against the chat's CURRENT model (`effectiveModelID`),
    // not engine residency. `commitSwap` persists the profile and — only on
    // a confirm-and-switch — the new pinned model; a silent swap preserves
    // the current model (`pinModel == nil`).
    // #459 "Keep Current Model" needs no `setOverride` under the single
    // authority: the coordinator builds the keep-current action from this
    // same `commitSwap`, pinning the CURRENT model (`fromModel`) instead of
    // the new default — both write `Chat.modelID`.
    swapCoordinator.requestSwap(
      toProfileID: id,
      fromModel: effectiveModelID,
      commit: commitSwap
    )
  }

  private func selectModel(_ option: ToolbarModelOptions.Option) {
    // #460: the clear-vs-load decision keys on the chat's SELECTION
    // (`selectedModelID` = `Chat.modelID`), NOT engine residency — residency
    // must not be a selection source. `selectionAction`'s `residentModelID`
    // parameter is the "current concrete model" it compares the picked row
    // against; under the single authority that is the chat's pin.
    switch ToolbarModelOptions.selectionAction(for: option,
                                               residentModelID: selectedModelID) {
    case .unavailable:
      return
    case .clearOverride:
      // Picking the profile-default row while it is already the chat's
      // selection clears the pin so the chat follows the profile default.
      onUseProfileDefault()
    case let .requestModel(modelID, overrideAfterConfirmation):
      // Confirm gate against the chat's current pin; on confirm, persist the
      // result onto `Chat.modelID`. A `nil` `overrideAfterConfirmation`
      // (concrete profile-default row) clears the pin so the chat keeps
      // profile-default semantics rather than persisting a redundant pin.
      swapCoordinator.requestModelOverride(
        modelID: modelID,
        activeProfileID: viewModel.selectedProfileID,
        fromModel: selectedModelID
      ) { _ in
        if let overrideAfterConfirmation {
          return commitModel(overrideAfterConfirmation)
        }
        onUseProfileDefault()
        return true
      }
    }
  }

  private func openModelsSettings() {
    settingsNavigation.open(.models)
    openSettings()
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

/// `internal` (not `private`) so the #421 slider polish — coarse labelled
/// ticks and the removed Max-tokens row — can be rendered to a PNG via
/// `ImageRenderer` in a snapshot test (`SamplingAndIndicatorSnapshotTests`).
struct ParamsPopover: View {
  @Binding var sampling: ChatSampling
  @State private var temperature: Double
  @State private var topP: Double
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
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sampling").font(.headline)
      slider("Temperature", value: $temperature, range: 0...2, format: "%.2f",
             ticks: SliderTickScale.evenTicks(0...2, step: 0.25),
             labels: SliderTickScale.labels([0, 0.5, 1, 1.5, 2], format: "%g"))
      slider("Top-p", value: $topP, range: 0...1, format: "%.2f",
             ticks: SliderTickScale.evenTicks(0...1, step: 0.25),
             labels: SliderTickScale.labels([0, 0.25, 0.5, 0.75, 1], format: "%g"))
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
    ticks: [Double],
    labels: [SliderTickScale.Label]
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text(String(format: format, value.wrappedValue))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      // #421: a CONTINUOUS slider (no `step:`). The stepped initialiser
      // makes macOS draw one NSSlider tick per step — 200 for 0–2 @0.01 —
      // a cluttered swarm. We render a few coarse labelled ticks below
      // instead; the value stays fine-grained (no snap yet, see #438).
      Slider(value: value, in: range)
      SliderTickScale(range: range, ticks: ticks, labels: labels)
    }
  }

  private func commit() {
    // #421: the Max tokens slider was removed — its real ceiling is an
    // engine-launch concern (#438), not a per-chat knob. Preserve the
    // existing max_tokens (profile default) so dropping the control never
    // silently resets it.
    sampling = ChatSampling(
      temperature: temperature,
      topP: topP,
      maxTokens: sampling.maxTokens
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

/// Coarse, labelled tick scale rendered under a continuous sampling
/// `Slider` (#421). `Slider(value:in:step:)` makes macOS draw one NSSlider
/// tick PER step (200 for 0–2 @0.01) — a cluttered swarm that read as
/// "ugly". Dropping `step` removes them; this renders a few evenly-spaced
/// notches + sparse numeric labels instead, positioned by value-fraction
/// so the scale aligns with the track and reflows with the popover width.
/// `internal` (not `private`) so the pure geometry is unit-testable
/// (`SliderTickScaleTests`); the view itself is decoration, hidden from
/// accessibility (the slider already exposes its value).
struct SliderTickScale: View {
  /// One labelled stop on the scale. `id` = the value so a label list
  /// carries no duplicate positions.
  struct Label: Identifiable {
    let value: Double
    let text: String
    var id: Double { value }
  }

  let range: ClosedRange<Double>
  let ticks: [Double]
  let labels: [Label]

  /// Horizontal inset (~slider thumb radius) so fraction 0/1 line up with
  /// the track ends rather than the raw view bounds.
  private let inset: CGFloat = 7

  var body: some View {
    VStack(spacing: 2) {
      GeometryReader { geo in
        let usable = max(0, geo.size.width - inset * 2)
        ForEach(ticks, id: \.self) { v in
          Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 1.5, height: 5)
            .position(x: inset + CGFloat(Self.fraction(v, in: range)) * usable, y: 2.5)
        }
      }
      .frame(height: 5)
      GeometryReader { geo in
        let usable = max(0, geo.size.width - inset * 2)
        ForEach(labels) { lab in
          Text(lab.text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            .position(x: inset + CGFloat(Self.fraction(lab.value, in: range)) * usable, y: 7)
        }
      }
      .frame(height: 14)
    }
    .accessibilityHidden(true)
  }

  // MARK: - pure geometry (unit-tested)

  /// 0…1 position of `v` within `r`, clamped to the ends. A degenerate
  /// (zero-width) range maps everything to 0.
  static func fraction(_ v: Double, in r: ClosedRange<Double>) -> Double {
    guard r.upperBound > r.lowerBound else { return 0 }
    return min(1, max(0, (v - r.lowerBound) / (r.upperBound - r.lowerBound)))
  }

  /// Evenly-spaced tick values from `lowerBound` to `upperBound` inclusive
  /// by `step`. The float epsilon admits the exact endpoint (e.g. 2.0
  /// reached by 0.25 steps); the final value is clamped so it can never
  /// overrun the range.
  static func evenTicks(_ r: ClosedRange<Double>, step: Double) -> [Double] {
    guard step > 0, r.upperBound > r.lowerBound else { return [r.lowerBound] }
    var out: [Double] = []
    var v = r.lowerBound
    while v <= r.upperBound + 1e-9 {
      out.append(min(v, r.upperBound))
      v += step
    }
    return out
  }

  /// Build `Label`s from raw values with a printf format (e.g. "%g" drops
  /// trailing zeros: 0.5 → "0.5", 1 → "1").
  static func labels(_ values: [Double], format: String) -> [Label] {
    values.map { Label(value: $0, text: String(format: format, $0)) }
  }
}
