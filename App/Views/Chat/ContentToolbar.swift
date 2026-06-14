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
  /// Compatibility preference. Default false means a concrete model row acts
  /// as an explicit pin across later profile changes; true restores the older
  /// follow-profile-default prompt behavior.
  let followProfileDefaultModel: Bool
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
  /// Current selected-profile sampling defaults. Read through a closure so
  /// Settings saves affect newly opened params popovers even though
  /// `ProfileStore` does not publish SwiftUI updates.
  let profileSampling: () -> ChatSampling
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
    followProfileDefaultModel: Bool = false,
    swapCoordinator: ProfileSwapCoordinator,
    modelLoadCenter: ModelLoadCenter?,
    engineStatus: EngineStatusStore?,
    helperHealth: HelperHealthController?,
    engineLifecycle: EngineLifecycle?,
    profileSampling: @escaping () -> ChatSampling = { ChatSampling() },
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
    self.followProfileDefaultModel = followProfileDefaultModel
    self.swapCoordinator = swapCoordinator
    self.modelLoadCenter = modelLoadCenter
    self.engineStatus = engineStatus
    self.helperHealth = helperHealth
    self.engineLifecycle = engineLifecycle
    self.profileSampling = profileSampling
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

      if let serveError = swapCoordinator.serveModelError {
        // #469: surface a model pick that failed to (re)launch the engine
        // (a resolver reject the status poll won't reflect) so a silently
        // dropped pick is never invisible. Mirrors `defaultModelWriteError`.
        Label(serveError, systemImage: "exclamationmark.triangle.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.red)
          .help(serveError)
          .accessibilityIdentifier("toolbar.serveModelError")
          .accessibilityLabel(serveError)
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
#if DEBUG
    .task(id: testAutoProfilePickTaskID) {
      await runTestAutoProfilePickIfNeeded()
    }
#endif
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
    // Anchor for the Phase 3.6 confirmation popover. #582: a coordinator-owned
    // `.applicationDefined` NSPopover (`ProfileSwapPopoverHost`) replaces the
    // transient SwiftUI `.popover`, which AppKit auto-closed on resign-key —
    // silently dropping a pending swap when the user Cmd-Tabbed / clicked
    // another app. The host captures the pending token at present time (review
    // v2 F4) and hands it back through `confirm(token:)` / `cancel(token:)` /
    // `keepCurrentModel(token:)`, so a stale callback from a superseded swap is
    // token-mismatched and dropped.
    .background(
      ProfileSwapPopoverHost(
        pending: swapCoordinator.pending,
        onConfirm: { token, setAsDefault in
          swapCoordinator.confirm(token: token, setAsDefault: setAsDefault)
        },
        onCancel: { token in swapCoordinator.cancel(token: token) },
        onKeepCurrent: { token in swapCoordinator.keepCurrentModel(token: token) }
      )
    )
  }

#if DEBUG
  private static var testAutoPickProfileID: String? {
    guard let id = ProcessInfo.processInfo.environment["PIE_TEST_AUTO_PICK_PROFILE"],
          !id.isEmpty
    else { return nil }
    return id
  }

  private var testAutoProfilePickTaskID: String {
    // #582: the production swap popover is now a coordinator-owned
    // `.applicationDefined` NSPopover that survives the window resigning key,
    // so the seam no longer tracks pending-presence to re-raise a popover that
    // a focus blip killed. #579 added that re-raise because the old transient
    // `.popover` died on resign-key under a contended seated session — but that
    // re-raise also MASKED the real production gap. With the gap fixed at the
    // source, the auto-pick fires exactly once per stable pendable state, and
    // S459's resign-key-survival case asserts the production NSPopover itself.
    //
    // #581 — CONSTRAINT (do not re-key this on `swapCoordinator.pending`):
    // keying on pending-presence is what made #579's seam incompatible with a
    // Cancel-outcome assertion. `cancel(token:)` / `dismissCurrentPending()`
    // clear `pending` WITHOUT mutating `selectedProfileID` (only `commitSwap`
    // sets it), so a pending-keyed taskID flips back to its pendable value the
    // instant a deliberate Cancel clears the popover — re-raising the swap once
    // and bouncing the popover back into a test that asserted it stayed
    // dismissed. Keying on the stable `(profile, model)` selection instead
    // means a Cancel leaves the axis untouched (no re-fire), a Confirm trips
    // the `selectedProfileID != target` guard (no re-fire), so every outcome —
    // Confirm, Keep-Current, AND Cancel — is safe to assert. A future
    // cancel-driving GUI scenario relies on this; do not reintroduce pending.
    [
      Self.testAutoPickProfileID ?? "",
      viewModel.selectedProfileID,
      selectedModelID ?? "",
    ].joined(separator: "|")
  }

  @MainActor
  private func runTestAutoProfilePickIfNeeded() async {
    guard let target = Self.testAutoPickProfileID,
          selectedModelID != nil,
          viewModel.selectedProfileID != target,
          swapCoordinator.pending == nil
    else { return }

    // Settle briefly so a still-resolving model selection doesn't race the
    // pick. NO one-shot latch: the latch-before-await was the solo flake —
    // `.task(id:)` cancels this task whenever the id changes (e.g.
    // `selectedModelID` resolves nil→X during the sleep), so a latch set here
    // permanently skipped the cancelled `selectProfile` and the popover never
    // appeared. Re-checking after the await fires exactly once per stable
    // pendable state instead.
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard !Task.isCancelled,
          viewModel.selectedProfileID != target,
          swapCoordinator.pending == nil
    else { return }
    selectProfile(target)
  }
#endif

  /// #460: the chat's effective current model — the explicit pin
  /// (`selectedModelID`) or, when unpinned, the active profile's default.
  /// This is the single value the swap policy treats as "the current
  /// model", so it stays correct whether the model is loaded or loading.
  private var effectiveModelID: String? {
    Self.effectiveModelID(selectedModelID: selectedModelID,
                          profileDefaultModel: profileDefaultModel)
  }

  /// Pure pin-over-default derivation, routed through the one resolver
  /// (`ModelTarget.resolve`) so the swap policy's "current model" can never
  /// disagree with the gate/send/label derivation. Static so the precedence
  /// is unit-tested without a view host (mirrors `modelLabel`).
  static func effectiveModelID(selectedModelID: String?,
                               profileDefaultModel: String?) -> String? {
    ModelTarget.resolve(selectedModelID: selectedModelID,
                        profileDefault: profileDefaultModel)?.modelID
  }

  static func shouldPreserveExplicitModelSelection(selectedModelID: String?,
                                                   followProfileDefaultModel: Bool) -> Bool {
    guard !followProfileDefaultModel else { return false }
    let trimmed = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !trimmed.isEmpty
  }

  private var modelMenu: some View {
    Menu {
      // #459's richer option list (checkmark on current, profile-default
      // annotation, unavailable reasons, "Manage Models…") kept; the write is
      // routed to `Chat.modelID` (the #460 authority) in `selectModel`.
      // #580: structured identity — cluster all quants of a family under one
      // base-name header (a disabled `Text` row, NOT a SwiftUI `Section`: a
      // Section header in a `.borderlessButton` Menu breaks the NSMenu so it
      // never opens, verified via the profile picker's S365). The row's text is
      // the quant TAG (Q1: base prominent in the header + quant as the row tag;
      // Q3: GGUF format dropped), with the unverified shield (#580 #5) via
      // `modelOptionLabel`. Each row carries `ModelRow-<slug>` as its
      // accessibility IDENTIFIER (which DOES surface on an NSMenuItem, unlike
      // `.accessibilityValue`) so automation (S486/S260) can target a concrete
      // model without depending on the no-longer-leaf row text.
      // Long lists scroll natively: a SwiftUI `Menu` renders an NSMenu, which
      // auto-scrolls past a screen-height threshold (a `ScrollView` cannot be
      // embedded in a `Menu`), so a long grouped list never runs off-screen.
      // The grouped pipeline that feeds it is guarded against truncation by
      // `ModelIdentityGroupingTests.test_long_multi_family_list_is_never_truncated`.
      // `prefer: \.isCurrent` keeps the persisted/served row on an identity
      // tie (app-managed bare slug vs served full-path copy) so the surviving
      // row's slug matches `selectedModelID` — checkmark renders and the tap
      // writes the persisted slug, not the sort-first duplicate.
      ForEach(ModelIdentityGrouping.grouped(
        ModelIdentityGrouping.deduped(modelOptions, slug: \.slug, prefer: { $0.isCurrent }),
        slug: \.slug)) { group in
        Text(group.base)
        ForEach(group.items) { option in
          Button {
            selectModel(option)
          } label: {
            modelOptionLabel(option)
          }
          .help(option.unavailableReason.map { "\(option.slug) — \($0)" } ?? option.slug)
          .accessibilityIdentifier("ModelRow-\(option.slug)")
          .disabled(!option.isSelectable)
        }
      }
      // No heavy Divider before the action: an NSMenu separator (what
      // SwiftUI's `Divider` becomes in a `.borderlessButton` Menu) is the
      // OS-standard line and is NOT restylable to a lighter weight, so the
      // subtlest option the operator asked for is to drop it — the disabled
      // base-name headers already structure the list, and the gearshape icon
      // sets "Manage Models…" apart from the model rows.
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
    // One systemImage per native menu row: current (checkmark) wins, then a
    // blocking reason (triangle), then the unverified shield (#580 #5).
    if option.isCurrent {
      Label(text, systemImage: "checkmark")
    } else if option.unavailableReason != nil {
      Label(text, systemImage: "exclamationmark.triangle")
    } else if option.isUnverified {
      Label(text, systemImage: "exclamationmark.shield")
    } else {
      Text(text)
    }
  }

  /// Row text is the quant TAG (#580 Q1/Q3: the base-name header supplies the
  /// family name, the row distinguishes by quant, GGUF format dropped), falling
  /// back to the full leaf when there is no clean quant (a safetensors dir / a
  /// split GGUF). Keeps the profile-default annotation + any unavailable reason.
  /// The concrete model stays automation-targetable via the row's
  /// `ModelRow-<slug>` accessibility identifier.
  private func modelOptionText(_ option: ToolbarModelOptions.Option) -> String {
    // Quant tag is the primary text; an HF-cache source suffix disambiguates
    // a same-quant app-vs-cache pair that the full-slug dedup keeps as two rows.
    var text = option.parts.quantOrLeaf
    if let tag = option.sourceTag { text += " (\(tag))" }
    if option.isProfileDefault { text += " (profile default)" }
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
    // Pin-over-default precedence via the one resolver, so the collapsed
    // label names the same model the gate/send paths resolve. The nil tail
    // (nothing pinned or defaulted) keeps the generic "Profile default" text.
    if let target = ModelTarget.resolve(selectedModelID: selectedModelID,
                                        profileDefault: profileDefaultModel) {
      // Leaf — consistent with the live collapsed label (#459
      // `currentModelSummary` / `modelMenuTitle`, also leaf-derived). #580's
      // structured base+quant rendering applies to the DROPDOWN ROWS, not this
      // collapsed-title contract.
      return ModelDisplayName.leaf(target.modelID)
    }
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
      preserveExplicitModelSelection: Self.shouldPreserveExplicitModelSelection(
        selectedModelID: selectedModelID,
        followProfileDefaultModel: followProfileDefaultModel),
      commit: commitSwap
    )
  }

  private func selectModel(_ option: ToolbarModelOptions.Option) {
    Self.performModelSelection(
      option,
      selectedModelID: selectedModelID,
      profileDefaultModel: profileDefaultModel,
      activeProfileID: viewModel.selectedProfileID,
      swapCoordinator: swapCoordinator,
      commitModel: commitModel,
      onUseProfileDefault: onUseProfileDefault)
  }

  static func performModelSelection(
    _ option: ToolbarModelOptions.Option,
    selectedModelID: String?,
    profileDefaultModel: String?,
    activeProfileID: String,
    swapCoordinator: ProfileSwapCoordinator,
    commitModel: @escaping (String) -> Bool,
    onUseProfileDefault: @escaping () -> Void
  ) {
    // #460/#527 review v1 F1: model-override decisions compare the picked row
    // against the chat's EFFECTIVE current selection (explicit pin, else
    // profile default), not just the raw pin. An unpinned chat following
    // default A that picks B must raise/execute the override path instead of
    // silently pinning B while the engine remains on A. Nil is reserved for
    // the genuinely no-resolvable-model case, where there is no model to
    // replace and the normal start gate will serve the new pin later.
    let fromModel = effectiveModelID(selectedModelID: selectedModelID,
                                     profileDefaultModel: profileDefaultModel)
    switch ToolbarModelOptions.selectionAction(for: option,
                                               residentModelID: selectedModelID) {
    case .unavailable:
      return
    case let .requestModel(modelID, overrideAfterConfirmation):
      // Confirm gate against the effective current model; on confirm, persist
      // the result onto `Chat.modelID`. All selectable concrete rows pass
      // their slug as `overrideAfterConfirmation`; choosing the
      // profile-default row is still an explicit model pick, not a request to
      // follow defaults.
      swapCoordinator.requestModelOverride(
        modelID: modelID,
        activeProfileID: activeProfileID,
        fromModel: fromModel
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

  private var paramsButton: some View {
    Button {
      showParamsPopover.toggle()
    } label: {
      Image(systemName: "slider.horizontal.3")
    }
    .buttonStyle(.plain)
    .help("Sampling parameters")
    .popover(isPresented: $showParamsPopover, arrowEdge: .top) {
      let sourceSampling = profileSampling()
      ParamsPopover(sampling: viewModel.samplingOverride ?? sourceSampling) { committed in
        viewModel.samplingOverride = Self.samplingOverrideAfterParamsCommit(
          currentOverride: viewModel.samplingOverride,
          sourceSampling: sourceSampling,
          committed: committed)
      }
    }
    .accessibilityIdentifier("toolbar.params")
  }

  static func samplingOverrideAfterParamsCommit(currentOverride: ChatSampling?,
                                                sourceSampling: ChatSampling,
                                                committed: ChatSampling) -> ChatSampling? {
    if committed == sourceSampling {
      return nil
    }
    if committed == currentOverride {
      return currentOverride
    }
    return committed
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
  let sampling: ChatSampling
  let onCommit: (ChatSampling) -> Void
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

  init(sampling: ChatSampling,
       onCommit: @escaping (ChatSampling) -> Void = { _ in }) {
    self.sampling = sampling
    self.onCommit = onCommit
    _temperature = State(initialValue: sampling.temperature)
    _topP = State(initialValue: sampling.topP)
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
    // second edit. Review v4 F1. `commit()` sends the buffered value through
    // `onCommit` only (not back into the local @State values), so these
    // `onChange` handlers are not retriggered by `commit()` itself — no
    // feedback loop. Whether that buffered value is an actual override is
    // decided by comparing it to the source profile sampling at the toolbar
    // boundary, not by whether any transient slider event occurred.
    .onChange(of: temperature) { _, _ in didCommit = false }
    .onChange(of: topP) { _, _ in didCommit = false }
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
    onCommit(ChatSampling(
      temperature: temperature,
      topP: topP,
      maxTokens: sampling.maxTokens
    ))
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
