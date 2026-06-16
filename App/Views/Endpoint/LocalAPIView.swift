import SwiftUI

/// The single "Local API" surface (#422).
///
/// The app serves exactly ONE OpenAI-compatible HTTP endpoint: the pie
/// engine's loopback server, the same one in-app chat uses. This view mirrors
/// the real endpoint and exposes the one supported endpoint policy knob:
/// whether the shared engine should start automatically on app launch. Port,
/// auth, and CORS remain fixed by the current engine launch contract.
///
/// Everything shown is bound to a real source:
///  · status / base URL / port ← `EngineStatusStore` (`EngineStatus.running`)
///  · served model            ← `LocalAPIState.servedModelID` (authoritative
///                               `EngineSessionSnapshot.servedModelID`; never
///                               a `/v1/models` re-fetch or profile fallback)
///  · health                  ← `/healthz` (`EngineClient.health()`)
///  · resident memory (RSS)   ← `EngineStatusStore.engineMemory()`
///  · security posture        ← `EngineHTTPPosture` (pinned to the launch
///                               config by `LocalAPIStateTests`)
///
/// The on/off control binds to engine start/stop because the engine's HTTP
/// listener IS the API — it can't be toggled independently (the honest
/// binding the ticket asks for, surfaced with a caption + a confirm on stop).
struct LocalAPIView: View {
  @EnvironmentObject private var engineStatusStore: EngineStatusStore
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var engineClientStore: EngineClientStore
  @EnvironmentObject private var appPreferences: AppPreferences
  /// #616: the shared engine coordinator. All engine actuation on this surface
  /// (start / stop, plus the bind-mode change and profile-restart sequences
  /// composed below) routes through it, so the chat scaffold and the Local API
  /// view never open-code two separate paths to start or stop the one engine.
  /// The Local-API-specific orchestration (external-access bind-mode change,
  /// profile-switch restart) stays here — it composes the coordinator's
  /// primitives rather than duplicating them.
  @EnvironmentObject private var engineCoordinator: ChatEngineCoordinator

  @State private var memory: EngineMemorySample?
  @State private var health: EngineHealth.Status?
  @State private var confirmStop = false
  @State private var selectedProfileID: String?
  @State private var profileRestartInFlight = false
  /// #654: drives the example/route surface only — `stream: true` (SSE) vs
  /// `stream: false` (single JSON body). The engine serves both; this toggle
  /// shapes the curl snippet and the chat-completions route summary so a user
  /// can see how to request each mode. It does NOT change engine launch state.
  @State private var streamingEnabled = true
  /// Last engine start/stop failure, surfaced near the status card. The
  /// engine's poll channel does NOT cover resolver-stage start rejections
  /// (`.profileMissing`/`.invalidInput`/`.spawnFailed`/`.modelMissing`):
  /// the helper replies the error but leaves status `.stopped`, so without
  /// this the toggle would snap back silently. A stop rejection likewise
  /// leaves status `.running` (toggle stuck on). Mirrors
  /// `ChatScaffoldView`'s `engineActionError` channel.
  @State private var engineActionError: String?
  /// #496: a start/stop refused because the background Helper isn't healthy.
  /// Surfaced as a helper-framed inline notice, never the engine action-error
  /// row, so a Helper state never reads as an engine fault.
  @State private var helperBlock: HelperUnavailable?

  private var state: LocalAPIState {
    LocalAPIState.make(
      status: engineStatusStore.status,
      hasActiveProfile: profileStore.activeProfileID != nil
    )
  }

  private var bindMode: EngineHTTPBindMode {
    state.isServing ? engineStatusStore.runtimeDaemonBindMode : appPreferences.localAPIBindMode
  }
  private var profileSelectionEnabled: Bool {
    state.profileSelectionEnabled && !profileRestartInFlight
  }
  private var posture: EngineHTTPPosture { EngineHTTPPosture.make(bindMode: bindMode) }

  private var runtimeProfileID: String? {
    if case .running(let snapshot) = engineStatusStore.status { return snapshot.profileID }
    return nil
  }

  /// The model the running engine actually serves (#654). Used to decide
  /// whether a profile switch needs an engine relaunch — a same-model switch
  /// does not. `nil` when not running or the snapshot carries no served model.
  private var runtimeServedModelID: String? {
    if case .running(let snapshot) = engineStatusStore.status {
      return snapshot.servedModelID.isEmpty ? nil : snapshot.servedModelID
    }
    return nil
  }

  private var profileOptions: [LocalAPIProfileOption] {
    LocalAPIProfileOption.make(entries: profileStore.entries, runtimeProfileID: runtimeProfileID)
  }

  private var selectedOrActiveProfileID: String? {
    selectedProfileID ?? runtimeProfileID ?? profileStore.activeProfileID ?? profileOptions.first?.id
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        statusCard
        if let engineActionError {
          actionErrorRow(engineActionError)
        }
        profileExplorerSection
        if let helperBlock {
          HelperUnavailableNotice(reason: helperBlock, onDismiss: { self.helperBlock = nil })
        }
        if state.isServing {
          servingDetails
        }
        configurationSection
        securitySection
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("LocalAPIView")
    .task(id: state.port) { await runLiveStats() }
    // Clear a stale start/stop error once the engine actually reaches
    // `.running` (the action succeeded, possibly via another surface).
    .onChange(of: state.isServing) { _, serving in
      if serving { engineActionError = nil; helperBlock = nil }
    }
    .onChange(of: engineStatusStore.status) { _, newStatus in
      if case .running(let snapshot) = newStatus {
        selectedProfileID = snapshot.profileID
      } else if selectedProfileID == nil {
        selectedProfileID = profileStore.activeProfileID ?? profileOptions.first?.id
      }
    }
    .onAppear {
      selectedProfileID = selectedOrActiveProfileID
    }
    .confirmationDialog(
      "Turn off the local API?",
      isPresented: $confirmStop,
      titleVisibility: .visible
    ) {
      Button("Turn Off", role: .destructive) { stop() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This stops the engine. In-app chat stops too.")
    }
  }

  // MARK: - header + on/off

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Local API")
          .font(.title2.weight(.semibold))
        Text("An OpenAI-compatible HTTP endpoint on this Mac. One engine serves both this API and in-app chat — there is no separate API server.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 16)
      Toggle("Local API", isOn: powerBinding)
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(!state.toggleEnabled)
        .accessibilityIdentifier("LocalAPIToggle")
    }
  }

  /// Binds the switch to real engine state. Flipping ON starts the engine on
  /// the active profile; flipping OFF asks for confirmation first (stopping
  /// the shared engine also stops chat). The visual reflects the live status,
  /// so a cancelled stop snaps back and a slow start shows "Starting…".
  private var powerBinding: Binding<Bool> {
    Binding(
      get: { state.toggleOn },
      set: { newOn in
        if newOn {
          start()
        } else {
          confirmStop = true
        }
      }
    )
  }

  // MARK: - status

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 9, height: 9)
          .accessibilityHidden(true)
        Text(state.statusLabel)
          .font(.headline)
          .accessibilityIdentifier("LocalAPIStatus")
      }
      if let detail = state.detail {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
  }

  /// Engine start/stop failure surface. Required because resolver-stage
  /// rejections don't move the polled status, so the reducer can't show them.
  private func actionErrorRow(_ message: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    .accessibilityIdentifier("LocalAPIActionError")
  }

  private var statusColor: Color {
    switch state.phase {
    case .serving:  return .green
    case .starting, .stopping: return .yellow
    case .off:      return .gray
    case .failed:   return .red
    }
  }

  // MARK: - serving details (only while running)

  @ViewBuilder
  private var servingDetails: some View {
    if let baseURL = visibleBaseURL {
      labeledCopyRow(
        title: "Base URL",
        value: baseURL,
        caption: baseURLCaption,
        identifier: "LocalAPIBaseURL"
      )

      if let model = state.servedModelID {
        VStack(alignment: .leading, spacing: 4) {
          infoRow(title: "Model", value: model, identifier: "LocalAPIModel")
          Text("Serves only this model. Requests must use this exact model id.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let memory {
        infoRow(title: "Memory (RSS)", value: memory.formattedResident, identifier: "LocalAPIMemory")
      }
      if let health {
        infoRow(
          title: "Health",
          value: health == .ok ? "Healthy" : "Degraded",
          identifier: "LocalAPIHealth"
        )
      }

      endpointsSection
      if let model = state.servedModelID {
        curlSection(baseURL: baseURL, model: model)
      }
    }
  }

  private var visibleBaseURL: String? {
    guard state.port != nil else { return engineStatusStore.localAPIBaseURL?.absoluteString }
    return engineStatusStore.localAPIBaseURL?.absoluteString
  }

  private var baseURLCaption: String {
    switch bindMode {
    case .loopback:
      return "Loopback only. The port is assigned fresh each time the engine starts."
    case .external:
      return "External access is enabled. From another device, replace 0.0.0.0 with this Mac’s LAN IP address."
    }
  }

  private var profileExplorerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Profiles")
      if profileOptions.isEmpty {
        Text("No valid profiles are available yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Picker("Profile", selection: profileSelectionBinding) {
          ForEach(profileOptions) { option in
            Text(option.title).tag(option.id)
          }
        }
        .pickerStyle(.segmented)
        .disabled(!profileSelectionEnabled)
        .accessibilityIdentifier("LocalAPIProfileTabs")

        if let selected = selectedProfileOption {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Model")
              .foregroundStyle(.secondary)
            Spacer()
            Text(selected.modelDisplayName)
              .font(.system(.body, design: .monospaced))
              .lineLimit(1)
            if selected.isRuntimeProfile {
              Text("Running")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            }
          }
          .accessibilityIdentifier("LocalAPISelectedProfile")
        }
      }
    }
  }

  private var selectedProfileOption: LocalAPIProfileOption? {
    guard let selectedOrActiveProfileID else { return nil }
    return profileOptions.first { $0.id == selectedOrActiveProfileID }
  }

  private var profileSelectionBinding: Binding<String> {
    Binding(
      get: { selectedOrActiveProfileID ?? "" },
      set: { selectProfile($0) }
    )
  }

  private var endpointsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionHeader("Endpoints")
      ForEach(LocalAPIRoute.clientFacing(streaming: streamingEnabled)) { route in
        HStack(spacing: 8) {
          Text(route.method)
            .font(.caption.monospaced().weight(.semibold))
            .frame(width: 44, alignment: .leading)
            .foregroundStyle(.secondary)
          Text(route.path)
            .font(.system(.body, design: .monospaced))
          Spacer(minLength: 8)
          Text(route.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .accessibilityIdentifier("LocalAPIEndpoints")
  }

  private func curlSection(baseURL: String, model: String) -> some View {
    let snippet = LocalAPICurl.chatCompletions(baseURL: baseURL, model: model, streaming: streamingEnabled)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        sectionHeader("curl example")
        Spacer()
        Button {
          copy(snippet)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
      }
      Toggle(isOn: $streamingEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Streaming responses")
          Text(streamingEnabled
               ? "stream: true — tokens arrive as Server-Sent Events."
               : "stream: false — one complete JSON response per request.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .accessibilityIdentifier("LocalAPIStreamingToggle")
      Text(snippet)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .accessibilityIdentifier("LocalAPICurl")
    }
  }

  // MARK: - security posture (always visible, read-only)

  private var configurationSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Configuration")
      Toggle(isOn: autoStartBinding) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Start Local API when RatioThink opens")
          Text("When enabled, the engine starts after launch; API and chat both come online.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .accessibilityIdentifier("LocalAPIAutoStartToggle")

      postureRow(title: "Profile", value: profileStore.activeProfileID ?? "Choose a profile in the chat toolbar.")
      Text("Port and authentication are fixed and can’t be configured. Use the switch at the top for on/off.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("LocalAPIConfiguration")
  }

  private var autoStartBinding: Binding<Bool> {
    Binding(
      get: { appPreferences.localAPIAutoStartEnabled },
      set: { appPreferences.setLocalAPIAutoStartEnabled($0) }
    )
  }

  private var securitySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Security")
      Toggle("Allow access from other devices", isOn: externalAccessBinding)
        .toggleStyle(.switch)
        .disabled(!state.externalAccessToggleEnabled)
        .accessibilityIdentifier("LocalAPIExternalAccessToggle")
      if let warningTitle = posture.warningTitle,
         let warningDetail = posture.warningDetail {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(warningTitle)
              .font(.callout.weight(.semibold))
            Text(warningDetail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .accessibilityIdentifier("LocalAPIExternalAccessWarning")
      }
      Text("This endpoint is unauthenticated. Don’t treat it as a secured service.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      postureRow(title: "Network", value: posture.networkSummary)
      postureRow(title: "Authentication", value: posture.authSummary)
      postureRow(title: "CORS", value: posture.corsSummary)
    }
    .accessibilityIdentifier("LocalAPISecurity")
  }

  private var externalAccessBinding: Binding<Bool> {
    Binding(
      get: { appPreferences.localAPIExternalAccessEnabled },
      set: { setExternalAccess($0) }
    )
  }

  private func postureRow(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - row builders

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.headline)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func infoRow(title: String, value: String, identifier: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
        .accessibilityIdentifier(identifier)
    }
  }

  private func labeledCopyRow(title: String, value: String, caption: String, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Text(value)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .accessibilityIdentifier(identifier)
        Spacer()
        Button { copy(value) } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
      }
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - actions

  /// Start the engine on the active profile. A resolver-stage rejection
  /// (`.profileMissing`/`.modelMissing`/…) is re-thrown by
  /// `EngineStatusStore.startEngine` and leaves the polled status `.stopped`,
  /// so it MUST surface here — the reducer never sees it. Only
  /// App-side `.replyTimeout` is swallowed by the store because the
  /// helper start remains in flight; same-profile idempotency is handled
  /// inside `HelperExportedAPI` / `PieEngineHost.startOrAttach`, so any
  /// `.alreadyRunning` that reaches the app is an incompatible-start
  /// conflict and surfaces to the caller.
  private func start() {
    guard let profileID = selectedOrActiveProfileID, !profileID.isEmpty else { return }
    Task { @MainActor in
      engineActionError = nil
      helperBlock = nil
      do {
        try await engineCoordinator.startEngine(profileID: profileID, daemonBindHost: bindMode)
      } catch let block as HelperUnavailable {
        helperBlock = block
      } catch {
        engineActionError = ChatScaffoldView.engineErrorMessage(error, verb: "start")
      }
    }
  }

  /// Stop the engine. A rejected stop (e.g. `.killRejected`) leaves status
  /// `.running`, so the toggle would otherwise stay on with no explanation —
  /// surface the reason after this user-confirmed destructive action.
  private func stop() {
    Task { @MainActor in
      engineActionError = nil
      helperBlock = nil
      do {
        try await engineCoordinator.stopEngine()
      } catch let block as HelperUnavailable {
        helperBlock = block
      } catch {
        engineActionError = ChatScaffoldView.engineErrorMessage(error, verb: "stop")
      }
    }
  }

  private func selectProfile(_ profileID: String) {
    // #654: only a switch that changes the SERVED MODEL relaunches the engine.
    // A same-model switch (e.g. Chat → Repeat Boost, both Qwen3-0.6B) keeps the
    // engine up — the new profile's sampling / speculation / constraint /
    // tree-of-thought params apply per request, not at boot.
    let outcome = LocalAPIProfileSwitchGate.decide(
      selectedProfileID: profileID,
      selectedModelID: profileOptions.first { $0.id == profileID }?.modelID,
      runtimeProfileID: runtimeProfileID,
      runtimeModelID: runtimeServedModelID,
      state: state,
      restartInFlight: &profileRestartInFlight
    )
    guard outcome != .reject else { return }
    selectedProfileID = profileID
    do {
      try profileStore.setActiveProfileID(profileID)
    } catch {
      profileRestartInFlight = false
      engineActionError = "Couldn't select profile: \(error)"
      return
    }
    if outcome == .restart {
      restartEngine(profileID: profileID)
    }
  }

  private func setExternalAccess(_ enabled: Bool) {
    let profileID = runtimeProfileID ?? selectedOrActiveProfileID
    Task { @MainActor in
      engineActionError = nil
      do {
        try await LocalAPIBindModeChange.apply(
          enabled: enabled,
          phase: state.phase,
          profileID: profileID,
          setPreference: { try appPreferences.setLocalAPIExternalAccessEnabled($0) },
          stopEngine: { try await engineCoordinator.stopEngine() },
          startEngine: { requestedMode in
            guard let profileID, !profileID.isEmpty else { return }
            try await engineCoordinator.startEngine(profileID: profileID, daemonBindHost: requestedMode)
          }
        )
      } catch {
        engineActionError = ChatScaffoldView.engineErrorMessage(error, verb: "switch")
      }
    }
  }

  private func restartEngine(profileID: String) {
    Task { @MainActor in
      engineActionError = nil
      defer { profileRestartInFlight = false }
      do {
        try await engineCoordinator.stopEngine()
        try await engineCoordinator.startEngine(
          profileID: profileID,
          daemonBindHost: bindMode
        )
      } catch {
        engineActionError = ChatScaffoldView.engineErrorMessage(error, verb: "switch")
      }
    }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

  /// Populate the live stats while the engine is running; clear them when it
  /// isn't. Runs (and is cancelled) by `.task(id: state.port)`, so it re-runs
  /// on every fresh launch (the port changes) and tears down when the view
  /// goes away.
  ///
  /// Health is read once per launch — it is stable for a given engine (the
  /// served-model id comes from the running snapshot via `LocalAPIState`,
  /// not from a fetch). Resident memory drifts, so it refreshes on a
  /// modest interval to stay an honest *live* figure. The refresh loop is
  /// skipped on test launches so GUI/E2E suites don't see per-tick churn
  /// (the same gate `RootView` uses for its launch-time work); the values are
  /// view-local `@State` (never `@Published`), so this can't reproduce the
  /// status-popover flap #327 warns about.
  private func runLiveStats() async {
    guard state.isServing else {
      memory = nil; health = nil
      return
    }
    let client = engineClientStore.client
    health = (try? await client.health())?.status
    memory = await engineStatusStore.engineMemory()

    guard !HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment) else {
      return
    }
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if Task.isCancelled || !state.isServing { break }
      memory = await engineStatusStore.engineMemory()
    }
  }
}
