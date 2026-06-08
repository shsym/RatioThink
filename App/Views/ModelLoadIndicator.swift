import SwiftUI

/// Window content-toolbar engine-status pip. A single, always-present
/// affordance that reflects the engine lifecycle (`EngineStatusStore`) plus
/// the resident model (`ModelLoadCenter`) via the pure `EngineIndicatorState`
/// reducer.
///
/// Render per state (design locked with the user):
///   · `.offline`  → small grey filled dot + quiet "Model not loaded" (#421).
///   · `.starting` → small amber filled dot + live "Starting… (Ns)" — a model
///     switch is an engine restart, so loading a model reads here (#469).
///   · `.running`  → small green filled dot, no inline text.
///   · `.error`    → red filled dot + short red label (the error title).
///
/// The pip is ALWAYS visible (it reflects the engine even at rest) — there is
/// no opacity-hiding. The dot is a bare `.plain` button (no background box) so
/// the toolbar chrome shows through.
struct ModelLoadIndicator: View {
  @ObservedObject var center: ModelLoadCenter
  /// : engine lifecycle source. Required so the pip reflects engine
  /// state (offline/starting/running) even when no load is in flight, and
  /// so the popover can read on-demand engine memory.
  @ObservedObject var engineStatus: EngineStatusStore
  /// #412: background-helper health. Drives the OUTER ring of the pip
  /// (ring = helper, dot = engine). When the helper is reachable the ring is
  /// quiet; while it is reconnecting/repairing/unreachable the ring blinks
  /// white/amber/red and the engine dot dims (its state is then unknown).
  @ObservedObject var helperHealth: HelperHealthController
  /// The single reconciled engine-lifecycle fold. The dot AND the popover
  /// read `lifecycle.indicator` (one published `EngineIndicatorState`) so they
  /// can never disagree — e.g. the popover can't show a resident model while
  /// the dot is offline.
  @ObservedObject var lifecycle: EngineLifecycle
  /// : invoked from the running/ready popover's Unload button. Wired in
  /// `ChatScaffoldView` to stop the engine (free RAM) then `markUnloaded()`.
  var onUnload: () -> Void = {}
  /// Invoked from the popover's `.offline` (engine-stopped) block "Start
  /// engine" action. Wired in `ChatScaffoldView` to start the engine on the
  /// active profile.
  var onStartEngine: () -> Void = {}

  @State private var showPopover = false

  /// The single semantic ENGINE state — the published fold from
  /// `EngineLifecycle` (engine lifecycle + model load), shared with the
  /// popover so the two surfaces derive from one value.
  private var indicatorState: EngineIndicatorState {
    lifecycle.indicator
  }

  /// The folded toolbar pip: outer ring (helper) + inner dot (engine), via
  /// the pure `HelperEngineIndicator` reducer.
  private var folded: (ring: StatusLED?, dot: IndicatorDot) {
    HelperEngineIndicator.make(helper: helperHealth.health, engine: indicatorState)
  }

  var body: some View {
    let state = indicatorState
    return Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: 5) {
        if case .starting = state {
          // #1: a starting engine reads honestly as "Starting… (Ns)" with
          // a live elapsed counter — never a fault, even on a slow boot.
          // The amber dot stays; this replaces the previously-bare
          // starting pip so a long start is visibly progressing, not
          // stuck. Driven by a view-local TimelineView off the store's
          // `startingSince`, so it never adds a per-second @Published
          // churn source (the #327 popover-stability rule). #421: no
          // width-cap frame here — the short label sizes to content so it
          // sits snug against the dot, aligned with the neighbouring
          // toolbar icons instead of right-pushed inside a reserved slot.
          StartingElapsedLabel(since: engineStatus.startingSince)
        } else if let prefix = Self.pipLabel(for: state) {
          Text(prefix)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.callout)
            .foregroundStyle(Self.labelTint(for: state))
        }
        indicatorShape(folded)
      }
    }
    .buttonStyle(.plain)
    .help(Self.helpText(helper: helperHealth.health, engine: state))
    .accessibilityIdentifier("toolbar.modelLoadIndicator")
    .accessibilityLabel(Self.accessibilityLabelText(helper: helperHealth.health, engine: state))
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      ModelLoadPopover(
        center: center,
        engineStatus: engineStatus,
        lifecycle: lifecycle,
        isPresented: $showPopover,
        onUnload: onUnload,
        onStartEngine: onStartEngine
      )
    }
  }

  // MARK: - shape

  /// The trailing-edge indicator: an outer helper-health ring composed over
  /// the inner engine LED dot (#412). The ring is present only when the helper
  /// is not healthy. Both blink slowly when the reducer asks (`StatusLED.blink`).
  @ViewBuilder
  private func indicatorShape(_ folded: (ring: StatusLED?, dot: IndicatorDot)) -> some View {
    ZStack {
      // Outer helper-health ring (quiet/absent when the helper is reachable).
      if let ring = folded.ring {
        Circle()
          .stroke(Self.color(for: ring.tint), lineWidth: 1.5)
          .frame(width: 17, height: 17)
          .modifier(SlowBlink(active: ring.blink))
      }
      // Inner engine element.
      switch folded.dot {
      case let .led(led):
        Circle()
          .fill(Self.color(for: led.tint))
          .frame(width: 9, height: 9)
          .modifier(SlowBlink(active: led.blink))
      }
    }
    // Fixed slot so the trailing edge never shifts as the shape changes.
    .frame(width: 18, height: 18)
  }

  // MARK: - pure presentation helpers

  /// Inline pip label, or nil when the state should be a bare dot.
  /// Pure function of `EngineIndicatorState` so it is unit-testable
  /// without SwiftUI (`ModelLoadIndicatorLabelTests`):
  ///   · `.offline` → "Model not loaded" (#421 — the one idle state that
  ///     otherwise had no inline copy; a stopped engine = no resident model).
  ///   · `.running` / `.starting` → nil (quiet dot; the running state stays
  ///     silent, and `.starting` renders its own live "Starting… (Ns)"
  ///     counter outside this helper. The tooltip carries any detail).
  ///   · `.loading(id, fraction)` → "Loading <leaf>… N%" (determinate)
  ///     or "Loading <leaf>" (indeterminate — the ellipsis is appended
  ///     separately as an animated view).
  ///   · `.error(err)` → the error title.
  static func pipLabel(for state: EngineIndicatorState) -> String? {
    switch state {
    case let .error(error):
      return error.title
    case .offline:
      return "Model not loaded"
    case .starting, .running:
      return nil
    }
  }

  /// Concrete dot colour for the bare-dot states. The reducer owns the
  /// abstract `Dot` intent; the view maps it to a SwiftUI `Color`:
  /// grey (offline) / amber (busy: starting) / neutral adaptive ink
  /// (running) / red (error).
  ///
  /// The running dot is `Color.primary` — the system label ink — so a
  /// healthy engine reads as a QUIET neutral (near-black in light mode,
  /// near-white in dark) rather than a loud green, matching 's "quiet
  /// when healthy, loud on problems" intent. `Color.primary` is
  /// appearance-adaptive, so it stays clearly visible in BOTH light and
  /// dark toolbars (a hardcoded white would vanish on a light toolbar),
  /// and its full-strength ink stays distinct from `.offline`'s muted
  /// `.secondary` grey. `.loading` also maps via `.busy` but renders the
  /// accent ring instead of a dot, so its colour here is never shown.
  /// Map a pure `StatusLED.Tint` to a concrete, appearance-adaptive SwiftUI
  /// `Color` (#412). `.white` uses `Color.primary` — the system label ink —
  /// so the "blink white" waiting LED stays clearly visible in BOTH a light
  /// and a dark toolbar (a hardcoded white would vanish on a light one),
  /// reading as a near-white pulse in dark mode like a Mac mini's sleep LED.
  /// `.greenWhite` is the quiet healthy success tint; `.amber`/`.red` are the
  /// trouble/given-up tints.
  static func color(for tint: StatusLED.Tint) -> Color {
    switch tint {
    case .off:        return .secondary
    case .white:      return .primary
    case .greenWhite: return .green
    case .amber:      return .orange
    case .red:        return .red
    }
  }

  /// Match the inline label colour to the state: red for an error, muted
  /// for the (only other labelled) loading state.
  static func labelTint(for state: EngineIndicatorState) -> Color {
    switch state {
    case .error: return .red
    default:     return .secondary
    }
  }

  /// Tooltip text per state. The quiet dots carry their detail here
  /// (especially `.starting`, whose amber dot has no inline text).
  static func helpText(for state: EngineIndicatorState) -> String {
    switch state {
    case .offline:
      return "Engine stopped"
    case let .starting(detail):
      return detail
    case let .running(modelID):
      if let modelID {
        return "Engine running — \(ModelDisplayName.leaf(modelID)) (click to unload)"
      }
      return "Engine running"
    case let .error(error):
      return "\(error.title): \(error.message)"
    }
  }

  /// Helper-aware tooltip (#412): when the background helper is not healthy
  /// the ring is the story, so its message wins over the (stale/unknown)
  /// engine detail. A healthy helper falls through to the engine tooltip.
  static func helpText(helper: HelperHealth, engine: EngineIndicatorState) -> String {
    if let helperText = helperStatusText(helper) { return helperText }
    return helpText(for: engine)
  }

  /// Short message for a non-healthy background helper, or nil when healthy.
  /// Shared by the tooltip + the VoiceOver label so they never drift.
  static func helperStatusText(_ health: HelperHealth) -> String? {
    switch health {
    case .healthy:
      return nil
    case .reconnecting:
      return "Reconnecting to the background helper…"
    case .repairing, .repairCoolingDown:
      return "Background helper isn’t responding — restarting it…"
    case .unreachable:
      return "Background helper isn’t responding"
    }
  }

  /// VoiceOver label per state.
  static func accessibilityLabelText(for state: EngineIndicatorState) -> String {
    switch state {
    case .offline:
      return "Engine stopped"
    case .starting:
      return "Engine starting"
    case let .running(modelID):
      if let modelID {
        return "Engine running, model \(ModelDisplayName.leaf(modelID)) resident"
      }
      return "Engine running"
    case let .error(error):
      return "\(error.title). \(error.message)"
    }
  }

  /// Helper-aware VoiceOver label (#412): helper trouble wins over the engine
  /// label, mirroring the tooltip.
  static func accessibilityLabelText(helper: HelperHealth, engine: EngineIndicatorState) -> String {
    if let helperText = helperStatusText(helper) { return helperText }
    return accessibilityLabelText(for: engine)
  }
}

/// Slow opacity pulse for the LED indicator elements (#412) — like a Mac
/// mini's sleeping power LED. Driven by `TimelineView(.animation)` so the
/// cadence is a deterministic function of `Date` whose lifetime ends with the
/// view (no open-ended `repeatForever` animation to leak), matching the
/// existing `indeterminateArc` / `AnimatedEllipsis` rationale. Inert when
/// `active` is false so steady states (healthy running, stopped) hold still.
private struct SlowBlink: ViewModifier {
  let active: Bool
  func body(content: Content) -> some View {
    if active {
      TimelineView(.animation) { context in
        // ~1.4s period, opacity 0.35…1.0.
        let t = context.date.timeIntervalSinceReferenceDate
        let phase = (sin(t * .pi / 0.7) + 1) / 2
        content.opacity(0.35 + 0.65 * phase)
      }
    } else {
      content
    }
  }
}

/// Popover surfaced from the toolbar indicator. Read-only details +
/// the active control for the current state. Opening the popover is
/// pure info — it never stops a load or frees RAM. The two
/// destructive/interrupting actions (`Cancel` a live load, `Unload` a
/// resident model) are gated behind an explicit in-popover confirm step
/// rather than firing on the first click, so a user inspecting the load
/// cannot accidentally interrupt it. `Dismiss` after a `.failed` /
/// `.engineNotReady` terminal stays a single tap — clearing an
/// already-finished error ring is not destructive.
///
/// When the engine is running/ready it also shows an on-demand `Memory`
/// row sampled from the helper while the popover is open (never a
/// published field — a per-second RSS publish would re-render the
/// toolbar hosting this popover and dismiss it).
///
/// The confirm step is rendered inline (not a system
/// `.confirmationDialog`) so it stays inside the one popover surface
/// hardened for reliable presentation, and so it is driveable by the
/// same `app.popovers.buttons` GUI-test path as every sibling control.
struct ModelLoadPopover: View {
  @ObservedObject var center: ModelLoadCenter
  /// : source for the on-demand engine-memory readout. Polled only
  /// while this popover is open (a `.task` cancelled on disappear), never
  /// as a published field — a per-second RSS publish would re-render the
  /// toolbar hosting this popover and dismiss it.
  @ObservedObject var engineStatus: EngineStatusStore
  /// The reconciled engine-lifecycle fold. The popover branches its top-level
  /// content + action on `lifecycle.indicator` (not raw `center.state`) so the
  /// resident/offline distinction can never drift from the dot: `Loaded —
  /// resident` + Unload + the memory poll render ONLY for `.running`; a
  /// stopped engine shows the offline block + Start engine.
  @ObservedObject var lifecycle: EngineLifecycle
  @Binding var isPresented: Bool
  var onUnload: () -> Void = {}
  /// Start the engine on the active profile — the `.offline` block's action.
  var onStartEngine: () -> Void = {}

  /// Latest engine RSS sample, refreshed every ~2s while the popover is
  /// open and the engine is running/ready. Local-only; nil hides the row.
  @State private var memory: EngineMemorySample?

  /// Whether the user armed the one destructive action — Unload a resident
  /// model (#359). The confirm step acts on this; the indicator click only
  /// ever arms it, never unloads directly. Local `@State`, so it resets to
  /// false every time the popover is re-presented and is cleared whenever the
  /// engine leaves `.running` under it (see `.onChange(of: isEngineRunning)`).
  @State private var armedUnload = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Divider()
      contentBlock
      Divider()
      actionArea
    }
    .padding(14)
    .frame(width: 280)
    .accessibilityIdentifier("modelLoad.popover")
    // If the engine leaves `.running` (stopped / failed) while the unload
    // confirm is armed, collapse back to the info view rather than letting the
    // user confirm against a model that is no longer resident.
    .onChange(of: isEngineRunning) { _, _ in
      armedUnload = false
    }
    // On-demand memory poll: only while the popover is open and the engine
    // is actually `.running`. Re-armed by `.task(id:)` when the engine state
    // flips so an engine that comes up after the popover opened still starts
    // sampling. Cancelled automatically on disappear. Gated on the engine
    // alone (not `center.state == .ready`) — a stale resident must never keep
    // the popover polling a stopped engine.
    .task(id: isEngineRunning) {
      guard isEngineRunning else {
        memory = nil
        return
      }
      while !Task.isCancelled {
        memory = await engineStatus.engineMemory()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  /// Either the single destructive trigger button (the default,
  /// info-only state of the popover) or — once that trigger is tapped —
  /// the explicit confirm prompt. The indicator click only ever reaches
  /// the former; performing a stop/unload requires the second deliberate
  /// click inside `confirmBlock` (#359).
  @ViewBuilder
  private var actionArea: some View {
    if armedUnload, isEngineRunning, let resident = center.residentModelID,
       let confirm = Self.unloadConfirm(residentModelID: resident) {
      confirmBlock(confirm)
    } else {
      HStack {
        Spacer()
        actionButton
      }
    }
  }

  /// Engine is actually `.running` — the only state where a memory readout
  /// (and a resident model) is meaningful. Drives the `.task` gate and the
  /// row's presence. Read from the engine ALONE: a stale `center.state ==
  /// .ready` must never make a stopped engine look running.
  private var isEngineRunning: Bool {
    if case .running = engineStatus.status { return true }
    return false
  }

  /// Top-level popover content, branched on the single `lifecycle.indicator`
  /// fold so the resident/offline distinction can't drift from the dot:
  /// `Loaded — resident` + the memory row render ONLY for `.running` (engine
  /// up); a stopped engine shows the offline block; an engine failure shows
  /// the error; a starting engine (incl. a model-switch restart) shows the
  /// "Engine starting…" placeholder.
  @ViewBuilder
  private var contentBlock: some View {
    switch lifecycle.indicator {
    case .offline:
      engineStoppedBlock
    case let .starting(detail):
      engineNotReadyBlock(detail: detail)
    case let .error(error):
      indicatorErrorBlock(error)
    case .running:
      residentRows
      if let memory, isEngineRunning {
        memoryRow(memory)
      }
    }
  }

  /// `.offline` (engine stopped) block: an honest "engine isn't running"
  /// statement — never a stale "Loaded — resident". The action area pairs it
  /// with a "Start engine" button (not Unload).
  private var engineStoppedBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Engine stopped")
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      Text("No model is loaded. Start the engine to load this profile's model.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("modelLoad.popover.engineStopped")
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: glyphForState)
        .foregroundStyle(.secondary)
      // The popover is the designated place to inspect the FULL id: the
      // headline middle-truncates a long slug so it can't widen the
      // 280pt popover (#462), and the tooltip + text selection recover
      // the complete identifier the truncation hides.
      Text(modelID)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(modelID)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch lifecycle.indicator {
    case .offline:
      // Engine stopped — the one constructive action is to start it (NOT
      // Unload, which would be nonsensical on a dead engine). Wired to the
      // active-profile engine start in `ChatScaffoldView`.
      Button("Start engine") {
        onStartEngine()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.startEngine")
    case .running:
      // Engine up. A resident model can be unloaded; otherwise (running but
      // serving nothing) there is no destructive action to offer.
      if center.residentModelID != nil {
        // : free the resident model's RAM. Destructive/interrupting, so
        // it only ARMS the confirm step — the next send otherwise re-enters
        // the no-model confirm gate with no model resident (#359).
        Button("Unload", role: .destructive) {
          armedUnload = true
        }
        .accessibilityIdentifier("modelLoad.popover.unload")
      }
    case .starting, .error:
      // A model switch / restart is owned by the engine status (the pip +
      // the status banner); there is no separate load to retry here (#469).
      EmptyView()
    }
  }

  /// The explicit confirm prompt shown after a destructive trigger is
  /// armed: a plain-language statement of what stops and whether it can
  /// be resumed, plus a non-destructive "keep" escape (also bound to
  /// Esc) and the destructive confirm. The confirm carries NO
  /// `.defaultAction`, so a stray Return can never trigger the
  /// stop/unload — it takes a deliberate click.
  private func confirmBlock(_ confirm: DestructiveConfirm) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(confirm.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(confirm.keepTitle) {
          armedUnload = false
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(confirm.keepIdentifier)
        Button(confirm.confirmTitle, role: .destructive) {
          performDestructive()
        }
        .accessibilityIdentifier(confirm.confirmIdentifier)
      }
    }
    .accessibilityIdentifier("modelLoad.popover.confirm")
  }

  /// Run the CONFIRMED unload — the only path that reaches `onUnload()` from
  /// the status UI. Guards that the engine is still running with a resident
  /// model: if the engine stopped between arming and the click, the unload
  /// no-ops and lets the user re-decide. Every other interaction (indicator
  /// click, arming the trigger, keep/escape) is non-destructive (#359).
  private func performDestructive() {
    if isEngineRunning, center.residentModelID != nil {
      onUnload()
    }
    isPresented = false
  }

  // MARK: - confirm copy (pure)

  /// Plain-language copy + accessibility ids for the explicit Unload confirm
  /// step (#359). Pure function of the resident model id so the wording is
  /// unit-testable without standing up the view. Returns nil only when there
  /// is nothing resident to unload.
  struct DestructiveConfirm: Equatable {
    let message: String
    let confirmTitle: String
    let keepTitle: String
    let confirmIdentifier: String
    let keepIdentifier: String
  }

  static func unloadConfirm(residentModelID: String) -> DestructiveConfirm? {
    // #462: name the model by its friendly leaf, never the raw `<repo>/<file>`
    // slug — an unbreakable slug token forces the fixed-width confirm popover
    // to clip. The full id stays visible (middle-truncated, copyable) in the
    // popover header.
    let name = ModelDisplayName.leaf(residentModelID)
    return DestructiveConfirm(
      message: "Unload \(name)? This frees its memory. The engine keeps running — you'll need to reload the model before your next message.",
      confirmTitle: "Unload",
      keepTitle: "Keep Loaded",
      confirmIdentifier: "modelLoad.popover.confirmUnload",
      keepIdentifier: "modelLoad.popover.keepLoaded"
    )
  }

  /// `.error` block, driven by the folded `EngineIndicatorError` so it covers
  /// BOTH a load failure (`Load failed`) and an engine-level failure (e.g.
  /// `Engine stopped unexpectedly`) with the reducer's routed title + message
  /// — replacing the prior load-only `failureBlock`.
  private func indicatorErrorBlock(_ error: EngineIndicatorError) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(error.title)
        .font(.callout.weight(.medium))
        .foregroundStyle(Color.red)
      Text(error.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(4)
        .truncationMode(.tail)
        .textSelection(.enabled)
    }
  }

  /// `.engineNotReady` placeholder block. Reads as "Engine starting…" +
  /// the store's status detail (e.g. "Engine stopped" or "Helper
  /// unreachable: <error>"). Distinct copy + muted (not red) tint so the
  /// user reads "the engine is still coming up" rather than "the load
  /// failed for some technical reason."
  private func engineNotReadyBlock(detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Engine starting…")
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(4)
        .truncationMode(.tail)
        .textSelection(.enabled)
    }
    .accessibilityIdentifier("modelLoad.popover.engineNotReady")
  }

  /// In-progress / settled load detail. #396: a live load never shows
  /// "—" as a primary value. Covers the body switch's `default:` branch
  /// (`.loading` / `.ready` / `.idle` / `.cancelled` — the failed &
  /// engine-not-ready states render their own blocks above). The memory
  /// row is still appended separately by the body.
  /// Resident-model rows for a `.running` engine. #469: the engine binds its
  /// model at boot, so there is no in-flight load to report bytes/ETA for —
  /// just whether a model is resident. The memory row is appended separately.
  @ViewBuilder
  private var residentRows: some View {
    if center.residentModelID != nil {
      detailRow("Status", "Loaded — resident")
    } else {
      detailRow("Status", "No model loaded")
    }
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .monospacedDigit()
    }
    .font(.callout)
  }

  /// On-demand engine resident-memory row. Rendered only when a
  /// sample is present (engine running/ready and the helper answered).
  private func memoryRow(_ sample: EngineMemorySample) -> some View {
    HStack {
      Text("Memory")
        .foregroundStyle(.secondary)
      Spacer()
      //  e2e: the id sits on the VALUE Text (not the HStack container)
      // so a GUI test can read the rendered RSS string off
      // `popovers.staticTexts["modelLoad.popover.memory"].label` and
      // assert a plausible non-zero readout — a container HStack exposes
      // no readable label.
      Text(sample.formattedResident)
        .monospacedDigit()
        .accessibilityIdentifier("modelLoad.popover.memory")
    }
    .font(.callout)
  }

  // MARK: - derived

  /// Headline model id — the resident model when one is served, else a
  /// neutral placeholder. (#469: no transient load id to surface anymore.)
  private var modelID: String {
    center.residentModelID ?? "—"
  }

  private var glyphForState: String {
    switch lifecycle.indicator {
    case .error:    return "exclamationmark.triangle"
    case .starting: return "hourglass"
    default:        return "shippingbox"
    }
  }
}

/// #1: honest "Starting… (Ns)" pip label. The engine-start path used to
/// render a bare amber dot whose tooltip flipped to "Helper unreachable: …"
/// the instant a single status poll hit the 2 s reply timeout, so a normal
/// slow boot read as a fault. This shows a calm, live elapsed counter
/// instead — `EngineStatusStore` now escalates to a real `.failed(.engineGone)`
/// only on SUSTAINED transport loss, so reaching this view always means a
/// genuine in-progress start. Driven by `TimelineView(.periodic)` so the
/// tick is a deterministic function of `Date` whose lifetime ends with the
/// view (matching the indeterminate-arc / ellipsis rationale) — never a
/// per-second `@Published` source.
private struct StartingElapsedLabel: View {
  let since: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(Self.text(since: since, now: context.date))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("toolbar.modelLoadIndicator.starting")
  }

  /// Pure formatter so the copy is unit-testable without a view host.
  /// `nil`/future `since` (clock skew) collapses to the bare "Starting…".
  static func text(since: Date?, now: Date) -> String {
    guard let since else { return "Starting…" }
    let elapsed = Int(now.timeIntervalSince(since))
    guard elapsed >= 1 else { return "Starting…" }
    return "Starting… (\(elapsed)s)"
  }
}
