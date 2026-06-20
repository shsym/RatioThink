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
///     settings (`.chooseModel`, including unsupported models) / inline
///     download (missing + downloadable) / none (helper-restart or
///     terminal faults);
///   · helperUnreachable → the reason + Retry (re-poll);
///   · configBroken → the reason + Open Settings;
///   · needsLoad / noDefault → the #326 availability action, framed
///     for the resolved `ModelTarget` (pinned selection vs profile
///     default — #497).
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
  /// #516: true when a blocked send is armed to auto-submit once the load
  /// target resolves. Drives the "…to send your message" copy — the same
  /// sheet is also raised by the launch-time engine-start prompt with an
  /// empty composer, where that promise would be a lie.
  let willAutoSend: Bool

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
  /// model id it pulls from `gateState`/`action`. Review v1 F5: every line
  /// of copy — including the source-honest captions — lives HERE so it is
  /// unit-tested without a view hierarchy; the view renders strings only.
  struct Plan: Equatable {
    var headline: String
    /// Failure reason shown at the gate (not only in the banner behind
    /// the sheet). Nil for non-failure states.
    var reason: String?
    var showsWaitSpinner: Bool
    var showsModelChip: Bool        // ".load" copy + slug chip
    var showsDownloadCTA: Bool      // inline MissingModelDownloadCTA
    var primary: Primary
    var showsOpenSettings: Bool
    /// Spinner detail line for `.busy` states. Nil otherwise.
    var detail: String? = nil
    /// Caption above the model chip (`showsModelChip`). Source-honest:
    /// a pinned selection is never called the profile default (#497).
    var loadCaption: String? = nil
    /// Caption above the download CTA. Nil when the headline, a reason,
    /// or the spinner detail already explains the state (the
    /// `engineFailed(.modelMissing)` and `.busy` download cells).
    var downloadCaption: String? = nil
    /// Body copy for the unavailable state. Non-nil replaces the old
    /// `showsUnavailableCopy` flag and carries pin-framed copy when the
    /// dropped target was a selection (review v1 F1).
    var unavailableCopy: String? = nil
  }

  /// Fold the lifecycle state + availability action into a render plan.
  /// #516: `willAutoSend` selects between the promise copy ("…to send your
  /// message") and the neutral copy — the promise is rendered only when the
  /// pending auto-send is actually armed to keep it.
  static func plan(state: ChatStartGate.State,
                   action: MissingModelRecovery.PromptAction,
                   willAutoSend: Bool) -> Plan {
    switch state {
    case .ready:
      // Gate not shown; render nothing if a race presents it for a frame.
      return Plan(headline: "", reason: nil, showsWaitSpinner: false,
                  showsModelChip: false, showsDownloadCTA: false,
                  primary: .none, showsOpenSettings: false)

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
                  primary: .none, showsOpenSettings: false,
                  detail: busyDetail(phase, action: action, willAutoSend: willAutoSend))

    case let .needsLoad(target):
      // #326 availability action is authoritative for load-vs-download.
      switch action {
      case .load:
        return Plan(headline: "Model not loaded yet", reason: nil, showsWaitSpinner: false,
                    showsModelChip: true, showsDownloadCTA: false,
                    primary: .load, showsOpenSettings: false,
                    loadCaption: {
                      // #516: promise the send only when it will happen.
                      switch (target.source, willAutoSend) {
                      case (.selected, true):
                        return "Load your selected model to send your message?"
                      case (.selected, false):
                        return "Load your selected model?"
                      case (_, true):
                        return "Load this profile's default model to send your message?"
                      case (_, false):
                        return "Load this profile's default model?"
                      }
                    }())
      case .download:
        // #446: the body says "isn't downloaded yet" — the headline must
        // agree. A target IS configured (this is `.needsLoad`); it simply
        // isn't on disk. "No model loaded" read as "nothing is set up".
        // #497: name the provenance honestly — a pinned selection is
        // never described as the profile's default. The
        // `.engineFailed(.modelMissing)` + `.download` sibling below is
        // target-NEUTRAL instead (that failure state has no target axis).
        return Plan(headline: target.source == .selected
                      ? "Selected model isn't downloaded"
                      : "Default model isn't downloaded",
                    reason: nil, showsWaitSpinner: false,
                    showsModelChip: false, showsDownloadCTA: true,
                    primary: .none, showsOpenSettings: false,
                    downloadCaption: {
                      // #516: promise the send only when it will happen.
                      switch (target.source, willAutoSend) {
                      case (.selected, true):
                        return "Your selected model isn't downloaded yet. Download it to send your message."
                      case (.selected, false):
                        return "Your selected model isn't downloaded yet. Download it to use it here."
                      case (_, true):
                        return "This profile's model isn't downloaded yet. Download it to send your message."
                      case (_, false):
                        return "This profile's model isn't downloaded yet. Download it to use it here."
                      }
                    }())
      case .unavailable:
        // Review v1 F1: the target is in hand — don't drop it. A pinned
        // selection that can't be loaded or downloaded must be named as
        // the selection, never blamed on the profile.
        return unavailablePlan(target: target)
      }

    case .noDefault:
      return unavailablePlan(target: nil)

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
        // Review v2 F1: the CTA downloads the GATE target (the chat's pin
        // when present), but this failure state carries no target axis —
        // so the headline is target-NEUTRAL, like `busyDetail`. It must
        // never claim "Default" above a button that downloads a pin. The
        // headline explains the state, so `downloadCaption` stays nil.
        return Plan(headline: "Model isn't downloaded", reason: nil,
                    showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: true,
                    primary: .none, showsOpenSettings: false)
      }
      // `.chooseModel` routes to Models settings, never a re-fire (F3);
      // this includes unsupported cached model artifacts. Only
      // `.restartEngine` earns a Retry — `.restartHelper`/`none` faults
      // would re-fail (or be refused) on a blind engine start.
      return Plan(headline: problem.title, reason: problem.message,
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  primary: problem.recovery == .restartEngine ? .retryEngine : .none,
                  showsOpenSettings: problem.recovery == .chooseModel)

    case .helperUnreachable:
      // #477: the raw XPC transport error stays in logs; show fixed copy.
      return Plan(headline: "Can't reach the engine",
                  reason: "The app can't reach its background helper right now. Try again in a moment.",
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  primary: .refresh, showsOpenSettings: false)

    case .configBroken:
      // #477: the raw profile-store error stays in logs; show fixed copy.
      return Plan(headline: "Can't read your profile selection",
                  reason: "Your profile settings couldn't be read. Open Settings → Models to fix them.",
                  showsWaitSpinner: false, showsModelChip: false, showsDownloadCTA: false,
                  primary: .none, showsOpenSettings: true)
    }
  }

  private static func unavailablePlan(target: ModelTarget?) -> Plan {
    if let target, target.source == .selected {
      return Plan(headline: "Selected model isn't available", reason: nil,
                  showsWaitSpinner: false, showsModelChip: false,
                  showsDownloadCTA: false, primary: .none,
                  showsOpenSettings: true,
                  unavailableCopy: "Your selected model isn't available on this Mac. Choose another from the Model menu in the toolbar, or add one in Settings → Models.")
    }
    return Plan(headline: "No model loaded", reason: nil, showsWaitSpinner: false,
                showsModelChip: false, showsDownloadCTA: false,
                primary: .none, showsOpenSettings: true,
                unavailableCopy: "This profile has no model ready. Choose one from the Model menu in the toolbar, or add one in Settings → Models.")
  }

  static func busyTitle(_ phase: ChatStartGate.BusyPhase) -> String {
    switch phase {
    case .startingEngine: return "Starting the engine…"
    case .stoppingEngine: return "Stopping the engine…"
    }
  }

  /// Review v1 F2: `.busy` carries no target axis, so this copy is
  /// deliberately target-NEUTRAL — it must never claim "this profile's
  /// model" while the CTA below downloads a pinned selection.
  static func busyDetail(_ phase: ChatStartGate.BusyPhase,
                         action: MissingModelRecovery.PromptAction,
                         willAutoSend: Bool) -> String {
    switch phase {
    case .startingEngine:
      if case .download = action {
        return "The model isn't downloaded yet — download it to continue."
      }
      // #516: "your message will send" is now a kept promise (the armed
      // pending send fires on resolution); without one armed, stay neutral.
      return willAutoSend
        ? "Your model is loading — your message will send once it's ready."
        : "Your model is loading."
    case .stoppingEngine:
      return "One moment…"
    }
  }

  // MARK: - body

  /// #736: latched the instant the user taps Load, so the button disables and
  /// reads "Starting…" immediately — before the async engine-start round-trip
  /// flips `gateState` to `.busy(.startingEngine)`. This closes the click→
  /// `.starting` lag window where the operator could stack ~10 Load taps, and
  /// gives the in-flight feedback the dead countdown lacked. Reset on the next
  /// `gateState` transition (the plan-driven spinner/retry then takes over).
  @State private var startRequested = false

  var body: some View {
    let plan = Self.plan(state: gateState, action: action, willAutoSend: willAutoSend)
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
    .onChange(of: gateState) { _, _ in
      // Any lifecycle transition (→ busy / failed / ready / …) means the start
      // request has been observed; hand feedback back to the plan-driven UI and
      // re-enable Load only if the gate genuinely returns to `.needsLoad`.
      startRequested = false
    }
    .task(id: startRequested) {
      // Safety auto-release: if a Load tap never moves `gateState` (a dropped
      // start), re-enable the button after a bounded delay so the user can
      // retry. A real start flips the gate first, and `onChange` clears the
      // latch (cancelling this) well before the timeout — so during a genuine
      // in-flight start the button is already hidden by the plan, not this.
      guard startRequested else { return }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if !Task.isCancelled { startRequested = false }
    }
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
        if let detail = plan.detail {
          Text(detail).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    if let reason = plan.reason {
      reasonText(reason)
    }
    if plan.showsModelChip, case let .load(model) = action {
      if let caption = plan.loadCaption {
        Text(caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      modelChip(model)
    }
    if plan.showsDownloadCTA, case let .download(target) = action {
      if let caption = plan.downloadCaption {
        Text(caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      MissingModelDownloadCTA(target: target, onDownloaded: onDownloaded, engineStatus: engineStatus)
    }
    if let unavailable = plan.unavailableCopy {
      Text(unavailable)
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
        Button {
          // #736: latch first so a second tap is a no-op (disabled) before the
          // async start flips the gate — repeated taps can't stack bringups.
          startRequested = true
          onLoad(model)
        } label: {
          if startRequested {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Starting…")
            }
          } else {
            Text("Load")
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(startRequested)
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
