import SwiftUI

/// Settings editor for one profile. The model picker persists the profile's
/// default model; system prompt plus user-facing sampling defaults
/// (temperature/top_p) are editable here. Max tokens remains engine/config
/// owned and is intentionally not exposed as a normal profile setting.
struct ProfileEditor: View {
  let entry: ProfileLoadResult
  /// Invoked after a successful profile write so the parent re-scans and hands
  /// back a refreshed `entry`.
  var onModelChanged: () -> Void = {}
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var downloads: ModelDownloadController
  @EnvironmentObject private var settingsNavigation: SettingsNavigation
  @EnvironmentObject private var engineStatusStore: EngineStatusStore
  /// Bumped by the Models-tab guardrail dial on a fraction write. Keying
  /// the model-options refresh on it recomputes the over-limit badges
  /// against the just-saved ceiling instead of letting them go stale
  /// until this view reappears (#334).
  @EnvironmentObject private var guardrailRevision: GuardrailRevision
  /// #621: read-only speculative-decode telemetry for the "last run" badge.
  /// The editor never WRITES this (it's runtime telemetry, not config) — it
  /// only observes the per-profile aggregate the chat send loop records.
  @EnvironmentObject private var specMetricsStore: SpecMetricsStore
  /// Discovered model options (app-managed + HF cache), each carrying
  /// size + over-limit / unsupported state for the model-size guardrail.
  @State private var modelOptions: [ProfileModelOptions.Option] = []
  /// Guardrail policy (ceiling), shown in the "exceeds …" reason on
  /// over-limit options. `nil` until the first scan.
  @State private var memoryPolicy: ModelMemoryGuardrail.Policy?
  /// Failure of the DEFAULT-MODEL SAVE itself (`ProfileStore.setModel`).
  /// Kept strictly separate from an engine reload failure (#459 repro 2):
  /// a saved default must never be reported as "couldn't save" just because
  /// the engine rebuild that follows it failed. Short, single-line copy.
  @State private var modelWriteError: String?
  @State private var defaultsWriteError: String?
  @State private var systemPromptDraft = ""
  @State private var temperatureDraft = Sampling().temperature
  @State private var topPDraft = Sampling().topP
  /// Set when the model scan throws. Without this the picker silently
  /// rendered empty on a scan failure, so a permission glitch on the
  /// models dir looked like "no models installed". Mirrors
  /// `ModelsSettingsTab`'s `scanError` surfacing.
  @State private var modelScanError: String?
  /// Lifecycle of the post-save engine rebuild (#459 repro 2/3). The save
  /// already succeeded; this tracks the SEPARATE reload so the route shows a
  /// loading indicator while the engine restarts and surfaces any failure in
  /// a bounded banner — never as layout-breaking inline error text.
  @State private var engineReload: EngineReloadState = .idle

  enum EngineReloadState: Equatable {
    case idle
    case reloading
    case failed(String)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let profile = entry.profile {
          headerRow(profile: profile)
          coreSection(profile: profile)
          editableDefaultsSection(profile: profile)
          if profile.speculation != nil {
            speculationSection(profile: profile)
          }
          warningsSection
        } else if let error = entry.error {
          unparsableSection(error)
        }
        Spacer(minLength: 0)
      }
      .padding(20)
    }
    .accessibilityIdentifier("ProfileEditor")
    .task(id: entry.url) {
      resetEditableDefaults(from: entry.profile)
      await refreshModelOptions(current: entry.profile?.model ?? "")
    }
    .onChange(of: downloads.completionTick) { _, _ in
      Task { await refreshModelOptions(current: entry.profile?.model ?? "") }
    }
    // A guardrail-dial write recomputes ONLY the picker over-limit badges
    // (#334). It deliberately mirrors the download-tick onChange and does
    // NOT re-run the draft-reset task: folding the revision into
    // `.task(id:)` would re-run `resetEditableDefaults` and discard
    // unsaved systemPrompt/temperature/topP edits on a dial change.
    .onChange(of: guardrailRevision.revision) { _, _ in
      Task { await refreshModelOptions(current: entry.profile?.model ?? "") }
    }
  }

  // MARK: - Sections

  private func headerRow(profile: Profile) -> some View {
    HStack(alignment: .firstTextBaseline) {
      if let icon = profile.icon, !icon.isEmpty {
        Image(systemName: icon).foregroundStyle(.secondary)
      }
      Text(profile.name).font(.title3).bold()
      Spacer()
      Text(profile.id).monospaced().foregroundStyle(.tertiary)
    }
  }

  private func coreSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Model")
      SettingsLabeledRow(label: "Default model") {
        modelPicker(profile: profile)
      }
      if let modelWriteError {
        Text(modelWriteError)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("ProfileEditorModelWriteError")
      }
      engineReloadStatus
      if let modelScanError {
        Text(modelScanError)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("ProfileEditorModelScanError")
      }
      SettingsLabeledRow(label: "Inferlet") {
        Text(profile.inferlet).monospaced().textSelection(.enabled)
      }
      SettingsLabeledRow(label: "File") {
        Text(entry.url.lastPathComponent).monospaced().foregroundStyle(.secondary)
      }
    }
  }

  /// Pull-down of discovered models — app-managed GGUF + Hugging Face
  /// cache (safetensors/GGUF) — plus the profile's current model even
  /// if uninstalled. Each row shows its resolved size; a model that
  /// exceeds the guardrail ceiling, or that the engine can't load (a
  /// split GGUF), is disabled with a reason since selecting it could
  /// never launch. Selecting a model persists it as the profile's
  /// default via `ProfileStore.setModel`. This is a default for the
  /// swap-confirm PRE-FILL only — it never triggers a load.
  private func modelPicker(profile: Profile) -> some View {
    let selectedLabelModel = ProfileModelPickerSelectionLabelModel(
      fallbackModel: profile.model,
      selectedOption: modelOptions.first { $0.slug == profile.model },
      memoryPolicy: memoryPolicy
    )
    let selectedAccessibilityText = ProfileModelPickerLabel.controlAccessibilityText(
      for: profile.model,
      model: selectedLabelModel
    )

    return Menu {
      // #580 #4: cluster all quants of a family under one base-name header
      // so the menu reads as "Llama 3.2 1B Instruct → Q4 / Q8" instead of a
      // flat list of long leaf names. The header is a disabled `Text` row
      // (NOT a SwiftUI `Section`): a `Section` header inside a
      // `.borderlessButton` Menu breaks the NSMenu so it never opens —
      // verified by S365. A plain `Text` renders as a disabled label and
      // keeps every Button a direct, selectable menu item.
      ForEach(ModelIdentityGrouping.grouped(modelOptions, slug: \.slug)) { group in
        Text(group.base)
        ForEach(group.items) { option in
          Button {
            persistModel(option.slug, profileID: profile.id)
          } label: {
            // The row's primary text is the quant tag (the distinguishing
            // part) plus size + over-limit / unsupported reason.
            modelOptionLabel(option)
          }
          // Block selecting an unloadable model — over-limit (too large for
          // this host) or unsupported (a split GGUF the engine can't load) —
          // but never the current value, which stays a no-op.
          .help(option.slug)
          .accessibilityValue(option.slug)
          .disabled((option.isOverLimit || option.unsupportedReason != nil) && !option.isCurrent)
        }
      }
      Divider()
      Button {
        settingsNavigation.open(.models)
      } label: {
        Label("Manage Models…", systemImage: "gearshape")
      }
      .help("Open Settings → Models")
      .accessibilityIdentifier("ProfileEditorModelPickerManageModels")
    } label: {
      ProfileModelPickerLabel(
        model: selectedLabelModel,
        modelID: profile.model
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help(selectedAccessibilityText)
    .accessibilityValue(selectedAccessibilityText)
    .accessibilityIdentifier("ProfileEditorModelPicker")
  }

  @ViewBuilder
  private func modelOptionLabel(_ option: ProfileModelOptions.Option) -> some View {
    let text = modelOptionText(option)
    // One systemImage per native menu row: current (checkmark) wins, then a
    // blocking reason (triangle), then the unverified shield (#580 #5).
    if option.isCurrent {
      Label(text, systemImage: "checkmark")
    } else if option.isOverLimit || option.unsupportedReason != nil {
      Label(text, systemImage: "exclamationmark.triangle")
    } else if option.supportWarning != nil {
      Label(text, systemImage: "exclamationmark.triangle")
    } else if option.isUnverified {
      Label(text, systemImage: "exclamationmark.shield")
    } else {
      Text(text)
    }
  }

  /// "<quant>  <size>" plus "— exceeds <limit> limit" when too large for
  /// this host, or "— <reason>" when the engine can't load it. When there
  /// is no clean quant (a safetensors dir, a split GGUF) the row keeps the
  /// FULL leaf — the only stable identifier for such a row — rather than a
  /// stem that dropped `.gguf`. Size is omitted when unknown (the
  /// synthesized current-model entry).
  private func modelOptionText(_ option: ProfileModelOptions.Option) -> String {
    var text = option.parts.quantOrLeaf
    // An HF-cache source suffix disambiguates a same-quant app-vs-cache pair the
    // full-slug dedup keeps as two rows (#590, mirrors the chat dropdown).
    if let tag = option.sourceTag { text += " (\(tag))" }
    if let size = option.sizeBytes {
      text += "  \(InstalledModels.formattedSize(size))"
    }
    if option.isOverLimit, let policy = memoryPolicy {
      text += " — exceeds \(InstalledModels.formattedSize(policy.maxResolvedModelBytes)) limit"
    } else if let reason = option.unsupportedReason {
      text += " — \(reason)"
    } else if let warning = option.supportWarning {
      text += " — \(warning)"
    }
    return text
  }

  private func editableDefaultsSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SettingsSectionHeader(title: "Profile defaults")
      Text("These defaults initialize chats that use this profile. Toolbar edits remain temporary per-chat overrides.")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Text("System prompt")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextEditor(text: $systemPromptDraft)
          .font(.body)
          .frame(minHeight: 88)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(Color.secondary.opacity(0.3))
          )
          .accessibilityIdentifier("ProfileEditorSystemPromptEditor")
        Text("Leave blank to omit the profile system prompt.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        SettingsSectionHeader(title: "Sampling")
        profileSlider(
          "Temperature",
          value: $temperatureDraft,
          range: 0...2,
          format: "%.2f",
          accessibilityID: "ProfileEditorTemperatureSlider")
        profileSlider(
          "Top P",
          value: $topPDraft,
          range: 0...1,
          format: "%.2f",
          accessibilityID: "ProfileEditorTopPSlider")
        Text("Max tokens is controlled by the launched engine/config and is not a normal profile setting.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let defaultsWriteError {
        Text(defaultsWriteError)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("ProfileEditorDefaultsWriteError")
      }

      HStack {
        Button("Save defaults") { persistEditableDefaults(profileID: profile.id) }
          .keyboardShortcut(.defaultAction)
          .disabled(!defaultsDirty(comparedTo: profile))
          .accessibilityIdentifier("ProfileEditorSaveDefaultsButton")
        Button("Revert") { resetEditableDefaults(from: profile) }
          .disabled(!defaultsDirty(comparedTo: profile))
        Spacer()
      }
    }
  }

  private func profileSlider(_ label: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             format: String,
                             accessibilityID: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text(String(format: format, value.wrappedValue))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: value, in: range)
        .accessibilityIdentifier(accessibilityID)
    }
  }

  /// Read-only speculative-decode diagnostics for a "Fast Think" profile
  /// (`[speculation]` present). Surfaces the most recent run's accept ratio
  /// + throughput from `SpecMetricsStore`. This is a DIAGNOSTICS badge, not
  /// an editable field: the editor edits config, while accept ratio is
  /// runtime telemetry the chat send loop records (#621).
  private func speculationSection(profile: Profile) -> some View {
    let aggregate = specMetricsStore.aggregate(forProfileID: profile.id)
    return VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Speculation")
      SettingsLabeledRow(label: "Last run") {
        Text(aggregate?.lastRunSummary ?? "No runs yet")
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("ProfileEditorSpecLastRun")
      }
      if let average = aggregate?.averageSummary {
        SettingsLabeledRow(label: "Average") {
          Text(average)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("ProfileEditorSpecAverage")
        }
      }
    }
  }

  @ViewBuilder
  private var warningsSection: some View {
    if !entry.warnings.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        SettingsSectionHeader(title: "Warnings")
        ForEach(entry.warnings, id: \.section) { w in
          HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Text(w.description).font(.callout)
          }
        }
      }
    }
  }

  private func unparsableSection(_ error: ProfileError) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Cannot parse")
      Text(error.description)
        .foregroundStyle(.red)
        .textSelection(.enabled)
      SettingsLabeledRow(label: "File") {
        Text(entry.url.path).monospaced().lineLimit(2).truncationMode(.middle)
      }
    }
  }

  private func persistEditableDefaults(profileID: String) {
    do {
      try profileStore.setEditableDefaults(
        systemPrompt: systemPromptDraft,
        temperature: temperatureDraft,
        topP: topPDraft,
        forProfileID: profileID)
      defaultsWriteError = nil
      onModelChanged()
    } catch {
      defaultsWriteError = "Could not save profile defaults: \(error)"
    }
  }

  // MARK: - side effects

  private func persistModel(_ model: String, profileID: String) {
    guard model != entry.profile?.model else { return }
    // Fresh interaction — clear any prior reload banner so a new save's
    // outcome can't read against a stale one.
    engineReload = .idle
    do {
      try profileStore.setModel(model, forProfileID: profileID)
      modelWriteError = nil
      onModelChanged()
      Task { await refreshModelOptions(current: model) }
      restartActiveEngineIfNeeded(profileID: profileID)
    } catch {
      modelWriteError = "Could not set default model: \(error)"
    }
  }

  /// If the edited profile is the active engine target, rebuild the
  /// helper engine after the default-model write so pie's boot-time
  /// model registry contains the newly selected model. Without this,
  /// `/v1/models/load` keeps rejecting the fresh slug as
  /// `model_not_found` until the user restarts the whole product.
  ///
  /// The default-model SAVE has already succeeded by the time this runs
  /// (#459 repro 2): a reload failure is reported on its own
  /// `engineReload` channel — never folded back into `modelWriteError`,
  /// which would mislabel a saved default as a failed save. The route shows
  /// a loading indicator while the rebuild is in flight (#459 repro 3) and a
  /// bounded banner if it fails (#459 acceptance: stable surface, no
  /// layout-breaking inline text).
  private func restartActiveEngineIfNeeded(profileID: String) {
    guard profileStore.activeProfileID == profileID else { return }
    engineReload = .reloading
    Task { @MainActor in
      do {
        try await engineStatusStore.restartEngine(profileID: profileID)
        engineReload = .idle
      } catch {
        engineReload = .failed(Self.engineReloadMessage(error))
      }
    }
  }

  /// Human, fault-domain-correct copy for a failed post-save engine reload.
  /// Frames the save as done and the reload as the failed step. #477:
  /// `EngineError.message` is a raw diagnostic — show the shared
  /// taxonomy's curated line and log the raw text instead.
  static func engineReloadMessage(_ error: Error) -> String {
    if let e = error as? EngineError {
      let problem = EngineProblem(statusCode: e.code, rawMessage: e.message)
      if let detail = problem.technicalDetail {
        Log.engine.error("ProfileEditor: engine reload failed: \(detail, privacy: .public)")
      }
      return "The new default was saved, but the engine couldn’t reload. \(problem.message)"
    }
    Log.engine.error("ProfileEditor: engine reload failed: \(String(describing: error), privacy: .public)")
    return "The new default was saved, but the engine couldn’t reload."
  }

  /// Loading indicator (rebuild in flight) / bounded failure banner for the
  /// post-save engine reload. Idle renders nothing.
  @ViewBuilder
  private var engineReloadStatus: some View {
    switch engineReload {
    case .idle:
      EmptyView()
    case .reloading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reloading the engine with the new default model…")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("ProfileEditorEngineReloading")
    case .failed(let message):
      EngineFailureBanner(message: message, onDismiss: { engineReload = .idle })
        .accessibilityIdentifier("ProfileEditorEngineReloadFailed")
    }
  }

  @MainActor
  private func refreshModelOptions(current: String) async {
    // Use the LIVE dial-derived policy, not the 0.65-pinned `defaultPolicy`,
    // and the SAME derivation the Helper's launch gate uses — so the
    // picker's "exceeds …" badge can't disagree with what actually loads (#334).
    let policy = ModelMemoryGuardrail.livePolicy()
    memoryPolicy = policy
    // Filesystem walks (app dir + HF cache) run off the main actor. HF
    // rows survive a models-dir prepare/scan failure; that failure still
    // surfaces with its detail. The current model is merged in by
    // `ProfileModelOptions.build`, so the picker is never silently empty.
    let scan = await CachedModelScan.run()
    modelOptions = ProfileModelOptions.build(
      models: scan.appManaged + scan.huggingFaceCache,
      current: current,
      limitBytes: policy.maxResolvedModelBytes)
    modelScanError = scan.appError
  }

  // MARK: - helpers

  private func resetEditableDefaults(from profile: Profile?) {
    systemPromptDraft = profile?.systemPrompt ?? ""
    temperatureDraft = profile?.sampling.temperature ?? Sampling().temperature
    topPDraft = profile?.sampling.topP ?? Sampling().topP
    defaultsWriteError = nil
  }

  private func defaultsDirty(comparedTo profile: Profile) -> Bool {
    normalizedPrompt(systemPromptDraft) != normalizedPrompt(profile.systemPrompt ?? "")
      || abs(temperatureDraft - profile.sampling.temperature) > 0.0001
      || abs(topPDraft - profile.sampling.topP) > 0.0001
  }

  private func normalizedPrompt(_ prompt: String) -> String {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
typealias ProfileModelPickerSelectionLabelModel = ProfileModelSelectionLabelContent

/// Bounded selected-model label for the Profile editor's model `Menu`.
///
/// Long Hugging Face ids are useful to inspect, but they must not become the
/// row's ideal width: `SettingsLabeledRow` has neighboring fixed-width labels,
/// so an unbounded/fixed-size menu label pushes the whole Profile pane wider.
/// Keep the label flexible, cap its ideal size, and let SwiftUI middle-truncate
/// inside that cap while exposing the unmodified id through help + a11y. When
/// the current/default model is unloadable, the same selected label also shows
/// the warning icon so users see the problem without opening the menu.
struct ProfileModelPickerLabel: View {
  static let maxLayoutWidth: CGFloat = 360

  let model: ProfileModelPickerSelectionLabelModel
  let modelID: String?

  init(modelID: String?) {
    self.modelID = modelID
    self.model = ProfileModelPickerSelectionLabelModel(
      fallbackModel: modelID,
      selectedOption: nil,
      memoryPolicy: nil
    )
  }

  init(model: ProfileModelPickerSelectionLabelModel, modelID: String?) {
    self.model = model
    self.modelID = modelID
  }

  var body: some View {
    HStack(spacing: 4) {
      if let warningText = model.warningText {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .help(warningText)
          .accessibilityHidden(true)
      }

      // #462: shared truncation primitive — middle-truncate one line and
      // fill the slot whose width the outer `.frame` fixes below. The full
      // id stays inspectable via the `.help`/a11y on the outer frame.
      Text(model.displayName)
        .monospaced()
        .foregroundStyle(modelID == nil ? .secondary : .primary)
        .boundedModelName(maxWidth: .infinity)

      Image(systemName: "chevron.up.chevron.down")
        .font(.caption)
        .accessibilityHidden(true)
    }
    .frame(idealWidth: Self.maxLayoutWidth,
           maxWidth: Self.maxLayoutWidth,
           alignment: .leading)
    .help(Self.controlAccessibilityText(for: modelID, model: model))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.accessibilityLabel)
    .accessibilityHint(Self.controlAccessibilityText(for: modelID, model: model))
    .accessibilityValue(Self.controlAccessibilityText(for: modelID, model: model))
  }

  static func displayText(for modelID: String?) -> String {
    ProfileModelPickerSelectionLabelModel.displayText(for: modelID)
  }

  static func accessibilityHelpText(for modelID: String?) -> String {
    modelID ?? displayText(for: modelID)
  }

  static func controlAccessibilityText(
    for modelID: String?,
    model: ProfileModelPickerSelectionLabelModel
  ) -> String {
    accessibilityHelpText(for: modelID, warningText: model.warningText)
  }

  static func accessibilityHelpText(for modelID: String?, warningText: String?) -> String {
    guard let warningText else { return accessibilityHelpText(for: modelID) }
    return "\(warningText)\n\(accessibilityHelpText(for: modelID))"
  }

  static func accessibilityText(for displayName: String) -> String {
    "Default model: \(displayName)"
  }
}
