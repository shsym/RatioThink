import SwiftUI

/// The single "Local API" surface (#422).
///
/// The app serves exactly ONE OpenAI-compatible HTTP endpoint: the pie
/// engine's loopback server, the same one in-app chat uses. This view is a
/// live, read-mostly mirror of that real endpoint — there is nothing to
/// "create" or configure per-endpoint (that placeholder CRUD is gone).
///
/// Everything shown is bound to a real source:
///  · status / base URL / port ← `EngineStatusStore` (`EngineStatus.running`)
///  · served model            ← `/v1/models` (`EngineClient.models()`),
///                               cross-checked with the active profile
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

  @State private var memory: EngineMemorySample?
  @State private var servedModel: String?
  @State private var health: EngineHealth.Status?
  @State private var confirmStop = false
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

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        statusCard
        if let engineActionError {
          actionErrorRow(engineActionError)
        }
        if let helperBlock {
          HelperUnavailableNotice(reason: helperBlock, onDismiss: { self.helperBlock = nil })
        }
        if state.isServing {
          servingDetails
        }
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
    .confirmationDialog(
      "Turn off the local API?",
      isPresented: $confirmStop,
      titleVisibility: .visible
    ) {
      Button("Turn Off", role: .destructive) { stop() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This stops the Rational engine. In-app chat will also stop until you turn it back on.")
    }
  }

  // MARK: - header + on/off

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Local API")
          .font(.title2.weight(.semibold))
        Text("An OpenAI-compatible HTTP endpoint served by the Rational engine on this Mac. It’s the same engine that powers in-app chat.")
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
    if let baseURL = engineStatusStore.baseURL?.absoluteString {
      labeledCopyRow(
        title: "Base URL",
        value: baseURL,
        caption: "Loopback only. The port is assigned fresh each time the engine starts.",
        identifier: "LocalAPIBaseURL"
      )

      if let model = servedModel {
        infoRow(title: "Model", value: model, identifier: "LocalAPIModel")
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
      curlSection(baseURL: baseURL)
    }
  }

  private var endpointsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionHeader("Endpoints")
      ForEach(LocalAPIRoute.clientFacing) { route in
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

  private func curlSection(baseURL: String) -> some View {
    let snippet = LocalAPICurl.chatCompletions(baseURL: baseURL, model: servedModel ?? "<model>")
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

  private var securitySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Security")
      Text("This endpoint is unauthenticated and local-only for 0.1.2. Don’t treat it as a secured service.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      postureRow(title: "Network", value: EngineHTTPPosture.networkSummary)
      postureRow(title: "Authentication", value: EngineHTTPPosture.authSummary)
      postureRow(title: "CORS", value: EngineHTTPPosture.corsSummary)
    }
    .accessibilityIdentifier("LocalAPISecurity")
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
    guard let profileID = profileStore.activeProfileID, !profileID.isEmpty else { return }
    Task { @MainActor in
      engineActionError = nil
      helperBlock = nil
      do {
        try await engineStatusStore.startEngine(profileID: profileID)
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
        try await engineStatusStore.stopEngine()
      } catch let block as HelperUnavailable {
        helperBlock = block
      } catch {
        engineActionError = ChatScaffoldView.engineErrorMessage(error, verb: "stop")
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
  /// The served-model id and health are read once per launch — both are
  /// stable for a given engine. Resident memory drifts, so it refreshes on a
  /// modest interval to stay an honest *live* figure. The refresh loop is
  /// skipped on test launches so GUI/E2E suites don't see per-tick churn
  /// (the same gate `RootView` uses for its launch-time work); the values are
  /// view-local `@State` (never `@Published`), so this can't reproduce the
  /// status-popover flap #327 warns about.
  private func runLiveStats() async {
    guard state.isServing else {
      memory = nil; servedModel = nil; health = nil
      return
    }
    let client = engineClientStore.client
    servedModel = (try? await client.models())?.first?.id
      ?? profileStore.activeProfile?.model
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
