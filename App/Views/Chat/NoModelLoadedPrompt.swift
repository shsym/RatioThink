import SwiftUI

/// The chat send gate, shown when a send is blocked because no model
/// resolves yet. It fuses two decision layers:
///
/// #326 — model AVAILABILITY (`MissingModelRecovery.PromptAction`):
///   `.load` (on disk → Load), `.download` (not on disk → inline
///   download CTA), `.unavailable` (no default / not downloadable).
///
/// #397 — engine/model LIFECYCLE (`ChatStartGate.State`): the prompt
/// renders the real reason AND the correct action for every gate state,
/// instead of always falling through to the availability action:
///   · busy(starting/stopping/loading) → calm wait (with the download
///     CTA still visible if a fresh-install model needs downloading);
///   · engineFailed → the reason + Retry (retryable) / Open Models
///     settings (model-choice faults: missing/too-large/profile) /
///     inline download (missing + downloadable);
///   · loadFailed → the reason + Retry the load;
///   · helperUnreachable → the reason + Retry (re-poll);
///   · configBroken → the reason + Open Settings;
///   · needsDefaultLoad / noDefault → the #326 availability action.
///
/// The decision is a pure function (`plan(state:action:)`) so the
/// per-state copy + affordances are unit-tested without a view
/// hierarchy; the body is thin glue over it. Loading/downloading spends
/// resources only as a direct consequence of the user acting here.
struct NoModelLoadedPrompt: View {
  /// #397 lifecycle state.
  let gateState: ChatStartGate.State
  /// #326 model-availability action.
  let action: MissingModelRecovery.PromptAction
  let onLoad: (String) -> Void
  /// Called once the inline download completes — the parent starts the
  /// engine on the active profile so the freshly-downloaded model loads.
  let onDownloaded: () -> Void
  /// Retry starting the engine after a retryable engine failure.
  let onRetryEngineStart: () -> Void
  /// Retry a failed model load.
  let onRetryLoad: (String) -> Void
  /// Re-poll the helper after an unreachable-transport failure.
  let onRefresh: () -> Void
  let onCancel: () -> Void
  /// Live engine status, threaded into the download CTA (PR#15 F1).
  let engineStatus: EngineStatus

  // MARK: - pure decision (testable)

  /// Which primary (default-action) button the gate offers.
  enum Primary: Equatable {
    case none
    case load          // load the on-disk default (ensures engine running first)
    case retryEngine   // re-start the engine after a retryable failure
    case retryLoad     // re-run a failed model load
    case refresh       // re-poll an unreachable helper
  }

  /// Pure, Equatable description of what the prompt renders. The view
  /// maps this to SwiftUI and binds the primary button's callback to the
  /// model id it pulls from `gateState`/`action`.
  struct Plan: Equatable {
    var headline: String
    /// Failure reason shown at the gate (not only in the banner behind
    /// the sheet). Nil for non-failure states.
    var reason: String?
    var showsWaitSpinner: Bool
    var showsModelChip: Bool        // ".load" copy + slug chip
    var showsDownloadCTA: Bool      // inline MissingModelDownloadCTA
    var showsUnavailableCopy: Bool
    var primary: Primary
    var showsOpenSettings: Bool
  }

  /// Fold the lifecycle state + availability action into a render plan.
  static func plan(state: ChatStartGate.State,
                   action: MissingModelRecovery.PromptAction) -> Plan {
    switch state {
    case .ready:
      // Gate not shown; render nothing if a race presents it for a frame.
      return Plan(headline: "", reason: nil, showsWaitSpinner: false,
                  showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false, primary: .none,
                  showsOpenSettings: false)

    case let .busy(phase):
      // F2: while the engine is starting on a fresh install whose model
      // is not downloaded, keep the #326 download CTA visible instead of
      // a dead "Starting…" the start can never complete.
      let keepDownload: Bool = {
        if case .startingEngine = phase, case .download = action { return true }
        return false
      }()
      return Plan(headline: busyTitle(phase), reason: nil, showsWaitSpinner: true,
                  showsModelChip: false, showsDownloadCTA: keepDownload,
                  showsUnavailableCopy: false, primary: .none,
                  showsOpenSettings: false)

    case .needsDefaultLoad:
      // #326 availability action is authoritative for load-vs-download.
      switch action {
      case .load:
        return Plan(headline: "Model not loaded yet", reason: nil, showsWaitSpinner: false,
                    showsModelChip: true, showsDownloadCTA: false,
                    showsUnavailableCopy: false, primary: .load,
                    showsOpenSettings: false)
      case .download:
        return Plan(headline: "No model loaded", reason: nil, showsWaitSpinner: false,
                    showsModelChip: false, showsDownloadCTA: true,
                    showsUnavailableCopy: false, primary: .none,
                    showsOpenSettings: false)
      case .unavailable:
        return unavailablePlan()
      }

    case .noDefault:
      return unavailablePlan()

    case let .engineFailed(code, reason, retryable):
      // modelMissing + downloadable → the #326 inline download IS the fix.
      if code == .modelMissing, case .download = action {
        return Plan(headline: "Default model isn't downloaded", reason: reason,
                    showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: true,
                    showsUnavailableCopy: false, primary: .none,
                    showsOpenSettings: false)
      }
      // Model-choice faults (missing-not-downloadable / too-large /
      // profile) route to Models settings, never a re-fire (F3).
      if isModelChoiceFault(code) {
        return Plan(headline: engineFailedTitle(code), reason: reason,
                    showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                    showsUnavailableCopy: false, primary: .none,
                    showsOpenSettings: true)
      }
      // Retryable engine fault (spawnFailed / engineGone / …) → Retry.
      // Non-retryable, non-model-choice (killRejected) → terminal: reason
      // only, no Retry that would re-fire a refused start (F3).
      return Plan(headline: engineFailedTitle(code), reason: reason,
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false,
                  primary: retryable ? .retryEngine : .none,
                  showsOpenSettings: false)

    case let .loadFailed(_, reason):
      return Plan(headline: "Couldn't load the model", reason: reason,
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false, primary: .retryLoad,
                  showsOpenSettings: false)

    case let .helperUnreachable(reason):
      return Plan(headline: "Can't reach the engine", reason: reason,
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false, primary: .refresh,
                  showsOpenSettings: false)

    case let .configBroken(reason):
      return Plan(headline: "Can't read your profile selection", reason: reason,
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false, primary: .none,
                  showsOpenSettings: true)
    }
  }

  private static func unavailablePlan() -> Plan {
    Plan(headline: "No model loaded", reason: nil, showsWaitSpinner: false,
         showsModelChip: false, showsDownloadCTA: false,
         showsUnavailableCopy: true, primary: .none,
         showsOpenSettings: true)
  }

  static func isModelChoiceFault(_ code: EngineErrorCode) -> Bool {
    switch code {
    case .modelMissing, .memoryRisk, .profileMissing: return true
    default:                                          return false
    }
  }

  static func engineFailedTitle(_ code: EngineErrorCode) -> String {
    switch code {
    case .modelMissing:   return "Default model isn't downloaded"
    case .memoryRisk:     return "Model is too large to load"
    case .profileMissing: return "Profile configuration problem"
    case .engineGone:     return "Engine stopped unexpectedly"
    default:              return "The engine couldn't start"
    }
  }

  static func busyTitle(_ phase: ChatStartGate.BusyPhase) -> String {
    switch phase {
    case .startingEngine:          return "Starting the engine…"
    case .stoppingEngine:          return "Stopping the engine…"
    case let .loadingModel(model): return "Loading \(ModelDisplayName.leaf(model))…"
    }
  }

  // MARK: - body

  var body: some View {
    let plan = Self.plan(state: gateState, action: action)
    return VStack(alignment: .leading, spacing: 14) {
      if case .ready = gateState {
        EmptyView()
      } else {
        header(plan)
        content(plan)
        actions(plan)
      }
    }
    .padding(20)
    .frame(width: 360)
    // NOTE: do NOT put an `.accessibilityIdentifier` on this container — on
    // current SwiftUI it propagates down and OVERRIDES the child controls'
    // own identifiers (the Cancel/Load/Retry buttons and the embedded
    // `MissingModelDownloadCTA`), so `noModel.cancel` / `missingModel.download`
    // become unqueryable (they all reported `noModel.prompt`). The gate's
    // controls carry their own identifiers; the container needs none.
  }

  private func header(_ plan: Plan) -> some View {
    HStack(spacing: 8) {
      Image(systemName: glyph)
        .foregroundStyle(tint)
      Text(plan.headline)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func content(_ plan: Plan) -> some View {
    if plan.showsWaitSpinner {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(busyDetail).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    if let reason = plan.reason {
      reasonText(reason)
    }
    if plan.showsModelChip, case let .load(model) = action {
      Text("Load this profile's default model to send your message?")
        .fixedSize(horizontal: false, vertical: true)
      modelChip(model)
    }
    if plan.showsDownloadCTA, case let .download(target) = action {
      if plan.reason == nil, !plan.showsWaitSpinner {
        Text("This profile's model isn't downloaded yet. Download it to send your message.")
          .fixedSize(horizontal: false, vertical: true)
      }
      MissingModelDownloadCTA(target: target, onDownloaded: onDownloaded, engineStatus: engineStatus)
    }
    if plan.showsUnavailableCopy {
      Text("This profile has no model ready. Choose one from the Model menu in the toolbar, or add one in Settings → Models.")
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func actions(_ plan: Plan) -> some View {
    HStack {
      Button("Cancel", role: .cancel) { onCancel() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("noModel.cancel")
      Spacer()
      if plan.showsOpenSettings {
        SettingsLink { Text("Open Settings…") }
          .accessibilityIdentifier("noModel.openSettings")
      }
      primaryButton(plan.primary)
    }
  }

  @ViewBuilder
  private func primaryButton(_ primary: Primary) -> some View {
    switch primary {
    case .none:
      EmptyView()
    case .load:
      if case let .load(model) = action {
        Button("Load") { onLoad(model) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("noModel.load")
      }
    case .retryEngine:
      Button("Retry") { onRetryEngineStart() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("noModel.retry")
    case .retryLoad:
      Button("Retry") {
        if case let .loadFailed(model, _) = gateState { onRetryLoad(model) }
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("noModel.retry")
    case .refresh:
      Button("Retry") { onRefresh() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("noModel.retry")
    }
  }

  // MARK: - shared pieces

  private var glyph: String {
    switch gateState {
    case .busy:                                                    return "hourglass"
    case .engineFailed, .loadFailed, .helperUnreachable, .configBroken:
      return "exclamationmark.triangle"
    default:                                                       return "cpu"
    }
  }

  private var tint: Color {
    switch gateState {
    case .engineFailed, .loadFailed, .helperUnreachable, .configBroken: return .orange
    default:                                                            return .secondary
    }
  }

  private var busyDetail: String {
    if case let .busy(phase) = gateState {
      switch phase {
      case .startingEngine:
        if case .download = action {
          return "This profile's model isn't downloaded yet — download it to continue."
        }
        return "Your model is loading — your message will send once it's ready."
      case .stoppingEngine: return "One moment…"
      case .loadingModel:   return "Hang tight — the model is loading."
      }
    }
    return ""
  }

  private func reasonText(_ reason: String) -> some View {
    Text(reason.isEmpty ? "No further detail was reported." : reason)
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(5)
      .truncationMode(.tail)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
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
