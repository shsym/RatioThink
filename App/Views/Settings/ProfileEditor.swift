import SwiftUI
import TOMLKit

/// Read-only per-profile editor (Phase 3.8). The *Show advanced*
/// toggle uncovers the inferlet picker + raw `inferlet_args` so users
/// can inspect what would be sent to the engine; writing is deferred
/// to a follow-up so this pane can land without touching the
/// `ProfileStore` FS-watcher path.
struct ProfileEditor: View {
  let entry: ProfileLoadResult
  /// Invoked after a successful model write so the parent re-scans and
  /// hands back a refreshed `entry`. .
  var onModelChanged: () -> Void = {}
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var downloads: ModelDownloadController
  @EnvironmentObject private var engineStatusStore: EngineStatusStore
  @State private var showAdvanced: Bool = false
  /// Discovered model options (app-managed + HF cache), each carrying
  /// size + over-limit / unsupported state for the model-size guardrail.
  @State private var modelOptions: [ProfileModelOptions.Option] = []
  /// Guardrail policy (ceiling), shown in the "exceeds …" reason on
  /// over-limit options. `nil` until the first scan.
  @State private var memoryPolicy: ModelMemoryGuardrail.Policy?
  @State private var modelWriteError: String?
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
          if !(profile.systemPrompt ?? "").isEmpty {
            systemPromptSection(profile.systemPrompt!)
          }
          samplingSection(profile: profile)
          warningsSection
          advancedToggle
          if showAdvanced {
            advancedSection(profile: profile)
          }
        } else if let error = entry.error {
          unparsableSection(error)
        }
        Spacer(minLength: 0)
      }
      .padding(20)
    }
    .accessibilityIdentifier("ProfileEditor")
    .task { await refreshModelOptions(current: entry.profile?.model ?? "") }
    .onChange(of: downloads.completionTick) { _, _ in
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
      ProfileModelPickerLabel(modelID: profile.model)
    }
    .menuStyle(.borderlessButton)
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

  private func systemPromptSection(_ prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "System prompt")
      Text(prompt)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
  }

  private func samplingSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Sampling")
      SettingsLabeledRow(label: "Temperature") {
        Text(String(format: "%.2f", profile.sampling.temperature))
          .monospaced()
      }
      SettingsLabeledRow(label: "Top P") {
        Text(String(format: "%.2f", profile.sampling.topP))
          .monospaced()
      }
      SettingsLabeledRow(label: "Max tokens") {
        Text("\(profile.sampling.maxTokens)").monospaced()
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

  private var advancedToggle: some View {
    Toggle("Show advanced", isOn: $showAdvanced)
      .toggleStyle(.switch)
      .accessibilityIdentifier("ProfileEditorShowAdvancedToggle")
  }

  private func advancedSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Inferlet picker")
      // Phase 3.8: picker shows the current inferlet only — actual
      // wasm enumeration lives in RatioThinkHelper and is not yet exposed
      // back to the App for selection. Surfacing the field here
      // documents the eventual interaction without faking choices
      // the engine wouldn't accept.
      SettingsLabeledRow(label: "Inferlet binary") {
        Text(profile.inferlet).monospaced().textSelection(.enabled)
      }

      Text("`inferlet_args` (raw)")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      Text(rawInferletArgs(profile.inferletArgs))
        .monospaced()
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
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
  private func restartActiveEngineIfNeeded(profileID: String) {
    guard profileStore.activeProfileID == profileID else { return }
    Task { @MainActor in
      do {
        try await engineStatusStore.restartEngine(profileID: profileID)
      } catch {
        modelWriteError = "Default saved, but couldn’t reload the engine: \(error)"
      }
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

  /// Stable, locale-free dump of `inferlet_args`. Encoding through a
  /// `TOMLTable` keeps the string identical to what would land on
  /// disk when write-back ships.
  private func rawInferletArgs(_ args: [String: TOMLValueConvertible]) -> String {
    if args.isEmpty { return "(none)" }
    let table = TOMLTable()
    for k in args.keys.sorted() {
      if let v = args[k] { table[k] = v }
    }
    return table.convert()
  }
}

/// Bounded selected-model label for the Profile editor's model `Menu`.
///
/// Long Hugging Face ids are useful to inspect, but they must not become the
/// row's ideal width: `SettingsLabeledRow` has neighboring fixed-width labels,
/// so an unbounded/fixed-size menu label pushes the whole Profile pane wider.
/// Keep the label flexible, cap its ideal size, and let SwiftUI middle-truncate
/// inside that cap while exposing the unmodified id through help + a11y.
struct ProfileModelPickerLabel: View {
  static let maxLayoutWidth: CGFloat = 360

  let modelID: String?

  var body: some View {
    HStack(spacing: 4) {
      Text(displayName)
        .monospaced()
        .foregroundStyle(modelID == nil ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "chevron.up.chevron.down")
        .font(.caption)
        .accessibilityHidden(true)
    }
    .frame(idealWidth: Self.maxLayoutWidth,
           maxWidth: Self.maxLayoutWidth,
           alignment: .leading)
    .help(helpText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityText(for: displayName))
    .accessibilityHint(helpText)
    .accessibilityValue(helpText)
  }

  private var displayName: String {
    Self.displayText(for: modelID)
  }

  private var helpText: String {
    modelID ?? displayName
  }

  static func displayText(for modelID: String?) -> String {
    modelID.map(ModelDisplayName.leaf) ?? "No default model"
  }

  static func accessibilityText(for displayName: String) -> String {
    "Default model: \(displayName)"
  }
}
