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
  /// Discovered model options (app-managed + HF cache), each carrying
  /// size + over-limit / unsupported state for the model-size guardrail.
  @State private var modelOptions: [ProfileModelOptions.Option] = []
  /// Guardrail policy (ceiling), shown in the "exceeds …" reason on
  /// over-limit options. `nil` until the first scan.
  @State private var memoryPolicy: ModelMemoryGuardrail.Policy?
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

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let profile = entry.profile {
          headerRow(profile: profile)
          coreSection(profile: profile)
          editableDefaultsSection(profile: profile)
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
      }
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
    Menu {
      ForEach(modelOptions) { option in
        Button {
          persistModel(option.slug, profileID: profile.id)
        } label: {
          // Value is the resolvable slug; label is the friendly leaf
          // plus size + over-limit / unsupported reason.
          modelOptionLabel(option)
        }
        // Block selecting an unloadable model — over-limit (too large for
        // this host) or unsupported (a split GGUF the engine can't load)
        // — but never the current value, which stays a no-op.
        .disabled((option.isOverLimit || option.unsupportedReason != nil) && !option.isCurrent)
      }
    } label: {
      HStack(spacing: 4) {
        Text(ModelDisplayName.leaf(profile.model)).monospaced()
        Image(systemName: "chevron.up.chevron.down").font(.caption)
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("ProfileEditorModelPicker")
  }

  @ViewBuilder
  private func modelOptionLabel(_ option: ProfileModelOptions.Option) -> some View {
    let text = modelOptionText(option)
    if option.isCurrent {
      Label(text, systemImage: "checkmark")
    } else if option.isOverLimit || option.unsupportedReason != nil {
      Label(text, systemImage: "exclamationmark.triangle")
    } else {
      Text(text)
    }
  }

  /// "<leaf>  <size>" plus "— exceeds <limit> limit" when the model is
  /// too large for this host, or "— <reason>" when the engine can't load
  /// it at all. Size is omitted when unknown (the synthesized
  /// current-model entry).
  private func modelOptionText(_ option: ProfileModelOptions.Option) -> String {
    var text = option.displayName
    if let size = option.sizeBytes {
      text += "  \(InstalledModels.formattedSize(size))"
    }
    if option.isOverLimit, let policy = memoryPolicy {
      text += " — exceeds \(InstalledModels.formattedSize(policy.maxResolvedModelBytes)) limit"
    } else if let reason = option.unsupportedReason {
      text += " — \(reason)"
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

  // MARK: - side effects

  private func persistModel(_ model: String, profileID: String) {
    guard model != entry.profile?.model else { return }
    do {
      try profileStore.setModel(model, forProfileID: profileID)
      modelWriteError = nil
      onModelChanged()
    } catch {
      modelWriteError = "Could not set default model: \(error)"
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

  @MainActor
  private func refreshModelOptions(current: String) async {
    let policy = ModelMemoryGuardrail.defaultPolicy
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
