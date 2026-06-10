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
///   · busy(starting/stopping) → calm wait (with the download
///     CTA still visible if a fresh-install model needs downloading);
///   · engineFailed → EngineProblem copy + the affordance its
///     `recovery` names (#477): Retry (`.restartEngine`) / Open Models
///     settings (`.chooseModel`) / inline download (missing +
///     downloadable) / none (helper-restart or terminal faults);
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
        // #446: the body says "isn't downloaded yet" — the headline must
        // agree. A default IS configured (this is `.needsDefaultLoad`); it
        // simply isn't on disk. "No model loaded" read as "nothing is set
        // up". Match the `.engineFailed(.modelMissing)` + `.download`
        // sibling below so both download entry points say the same thing.
        return Plan(headline: "Default model isn't downloaded", reason: nil, showsWaitSpinner: false,
                    showsModelChip: false, showsDownloadCTA: true,
                    showsUnavailableCopy: false, primary: .none,
                    showsOpenSettings: false)
      case .unavailable:
        return unavailablePlan()
      }

    case .noDefault:
      return unavailablePlan()

    case let .engineFailed(code, reason):
      // #477: headline, reason, AND the primary affordance all derive
      // from the one taxonomy — copy and action can't diverge (review F2:
      // a `.degraded` helper must not pair "restart the helper" copy with
      // a Retry-engine button; `.killRejected` must not headline "couldn't
      // start" over "refused to stop" body). The gate's raw `reason`
      // diagnostic stays in logs.
      let problem = EngineProblem(statusCode: code, rawMessage: reason)
      // modelMissing + downloadable → the #326 inline download IS the fix;
      // the CTA says it all, so no reason line (matches the
      // `.needsDefaultLoad` + `.download` sibling above; the #446
      // download framing keeps its bespoke headline).
      if code == .modelMissing, case .download = action {
        return Plan(headline: "Default model isn't downloaded", reason: nil,
                    showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: true,
                    showsUnavailableCopy: false, primary: .none,
                    showsOpenSettings: false)
      }
      // `.chooseModel` routes to Models settings, never a re-fire (F3);
      // only `.restartEngine` earns a Retry — `.restartHelper`/`none`
      // faults would re-fail (or be refused) on a blind engine start.
      return Plan(headline: problem.title, reason: problem.message,
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false,
                  primary: problem.recovery == .restartEngine ? .retryEngine : .none,
                  showsOpenSettings: problem.recovery == .chooseModel)

    case .helperUnreachable:
      // #477: the raw XPC transport error stays in logs; show fixed copy.
      return Plan(headline: "Can't reach the engine",
                  reason: "The app can't reach its background helper right now. Try again in a moment.",
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  showsUnavailableCopy: false, primary: .refresh,
                  showsOpenSettings: false)

    case .configBroken:
      // #477: the raw profile-store error stays in logs; show fixed copy.
      return Plan(headline: "Can't read your profile selection",
                  reason: "Your profile settings couldn't be read. Open Settings → Models to fix them.",
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

  static func busyTitle(_ phase: ChatStartGate.BusyPhase) -> String {
    switch phase {
    case .startingEngine: return "Starting the engine…"
    case .stoppingEngine: return "Stopping the engine…"
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
    case .busy:                                              return "hourglass"
    case .engineFailed, .helperUnreachable, .configBroken:
      return "exclamationmark.triangle"
    default:                                                 return "cpu"
    }
  }

  private var tint: Color {
    switch gateState {
    case .engineFailed, .helperUnreachable, .configBroken: return .orange
    default:                                                return .secondary
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
