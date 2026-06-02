import SwiftUI

/// Window content-toolbar engine-status pip. A single, always-present
/// affordance that folds the engine lifecycle (`EngineStatusStore`) and the
/// in-flight model load (`ModelLoadCenter`) into one quiet indicator via the
/// pure `EngineIndicatorState` reducer.
///
/// Render per state (design locked with the user):
///   · `.offline`  → small grey filled dot, no inline text.
///   · `.starting` → small amber filled dot, no inline text (tooltip detail).
///   · `.running`  → small green filled dot, no inline text.
///   · `.loading`  → progress ring (determinate `Circle().trim` / indeterminate
///     `TimelineView` arc, accent) + inline "Loading <leaf>… N%" (determinate)
///     or "Loading <leaf>" + AnimatedEllipsis (indeterminate).
///   · `.error`    → red filled dot + short red label (the error title).
///
/// Unlike the prior model-load-only widget, the pip is ALWAYS visible (it
/// reflects the engine even at rest) — there is no opacity-hiding. The dot
/// is a bare `.plain` button (no background box) so the toolbar chrome shows
/// through. The popover lifecycle `onChange` still acks any terminal load
/// state on dismissal so a stuck `.failed`/`.cancelled`/`.engineNotReady`
/// clears when the popover closes from any path.
struct ModelLoadIndicator: View {
  @ObservedObject var center: ModelLoadCenter
  /// : engine lifecycle source. Required so the pip reflects engine
  /// state (offline/starting/running) even when no load is in flight, and
  /// so the popover can read on-demand engine memory.
  @ObservedObject var engineStatus: EngineStatusStore
  /// : invoked from the running/ready popover's Unload button. Wired in
  /// `ChatScaffoldView` to stop the engine (free RAM) then `markUnloaded()`.
  var onUnload: () -> Void = {}

  @State private var showPopover = false

  /// The single semantic state the pip renders, folded from both sources.
  private var indicatorState: EngineIndicatorState {
    EngineIndicatorState.make(
      engine: engineStatus.status,
      engineDetail: engineStatus.statusDetail,
      load: center.state,
      residentModelID: center.residentModelID
    )
  }

  var body: some View {
    let state = indicatorState
    return Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: 5) {
        if let prefix = Self.pipLabel(for: state) {
          HStack(spacing: 0) {
            // Cap width + middle-truncate so a long HF-style leaf can't
            // render unbounded and crowd other toolbar items.
            Text(prefix)
              .monospacedDigit()
              .lineLimit(1)
              .truncationMode(.middle)
            if Self.pipLabelAnimatesEllipsis(for: state) {
              AnimatedEllipsis()
            }
          }
          .font(.callout)
          .foregroundStyle(Self.labelTint(for: state))
          .frame(maxWidth: 200, alignment: .trailing)
        }
        indicatorShape(for: state)
      }
    }
    .buttonStyle(.plain)
    .help(Self.helpText(for: state))
    .accessibilityIdentifier("toolbar.modelLoadIndicator")
    .accessibilityLabel(Self.accessibilityLabelText(for: state))
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      ModelLoadPopover(
        center: center,
        engineStatus: engineStatus,
        isPresented: $showPopover,
        onUnload: onUnload
      )
    }
    // Clicking outside the popover dismisses it but does NOT clear a
    // terminal load (`.failed` / `.cancelled` / `.engineNotReady`),
    // leaving it stuck. When the popover closes from any path while the
    // load is terminal, ack the terminal and return to .idle. The
    // Dismiss button also works — it calls dismissTerminalState directly.
    .onChange(of: showPopover) { wasShown, isShown in
      if wasShown, !isShown {
        switch center.state {
        case .failed, .cancelled, .engineNotReady:
          center.dismissTerminalState()
        default:
          break
        }
      }
    }
  }

  // MARK: - shape

  /// The dot/ring at the trailing edge. A filled dot for the quiet states
  /// (offline/starting/running/error); the progress ring for `.loading`.
  @ViewBuilder
  private func indicatorShape(for state: EngineIndicatorState) -> some View {
    switch state {
    case let .loading(_, fraction):
      loadingRing(fraction: fraction)
        .frame(width: 18, height: 18)
    default:
      Circle()
        .fill(Self.dotColor(for: state))
        .frame(width: 9, height: 9)
        // Match the loading ring's slot so the trailing edge never
        // shifts horizontally when the state flips dot↔ring.
        .frame(width: 18, height: 18)
    }
  }

  @ViewBuilder
  private func loadingRing(fraction: Double?) -> some View {
    ZStack {
      Image(systemName: "circle")
        .imageScale(.medium)
        .foregroundStyle(.secondary)
      Group {
        if let fraction {
          Circle()
            .trim(from: 0, to: fraction)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
        } else {
          indeterminateArc
        }
      }
      .frame(width: 14, height: 14)
    }
  }

  /// Spinner driven by `TimelineView(.animation)` so the rotation is a
  /// deterministic function of `Date` whose lifetime ends with the view,
  /// rather than an open-ended `withAnimation(.repeatForever)`.
  private var indeterminateArc: some View {
    TimelineView(.animation) { context in
      let seconds = context.date.timeIntervalSinceReferenceDate
      let angle = seconds.truncatingRemainder(dividingBy: 1.0) * 360.0
      Circle()
        .trim(from: 0, to: 0.25)
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(angle - 90))
    }
  }

  // MARK: - pure presentation helpers

  /// Inline pip label, or nil when the state should be a bare dot.
  /// Pure function of `EngineIndicatorState` so it is unit-testable
  /// without SwiftUI (`ModelLoadIndicatorLabelTests`):
  ///   · `.offline` / `.running` / `.starting` → nil (quiet dot; the
  ///     tooltip carries any detail).
  ///   · `.loading(id, fraction)` → "Loading <leaf>… N%" (determinate)
  ///     or "Loading <leaf>" (indeterminate — the ellipsis is appended
  ///     separately as an animated view).
  ///   · `.error(err)` → the error title.
  static func pipLabel(for state: EngineIndicatorState) -> String? {
    switch state {
    case let .loading(modelID, fraction):
      let leaf = ModelDisplayName.leaf(modelID)
      if let fraction {
        return "Loading \(leaf)… \(Int(fraction * 100))%"
      }
      return "Loading \(leaf)"
    case let .error(error):
      return error.title
    case .offline, .starting, .running:
      return nil
    }
  }

  /// Whether the label animates a trailing ellipsis. Only the
  /// indeterminate load does — a determinate load already shows a
  /// percent that cycling dots would jitter, and the error title is
  /// static. Keyed off the same state as the label and the ring so the
  /// three can never disagree.
  static func pipLabelAnimatesEllipsis(for state: EngineIndicatorState) -> Bool {
    if case let .loading(_, fraction) = state {
      return fraction == nil
    }
    return false
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
  static func dotColor(for state: EngineIndicatorState) -> Color {
    switch state.dot {
    case .offline: return .secondary
    case .busy:    return .orange
    case .running: return .primary
    case .error:   return .red
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
    case let .loading(modelID, _):
      return "Loading \(ModelDisplayName.leaf(modelID))…"
    case let .running(modelID):
      if let modelID {
        return "Engine running — \(ModelDisplayName.leaf(modelID)) (click to unload)"
      }
      return "Engine running"
    case let .error(error):
      return "\(error.title): \(error.message)"
    }
  }

  /// VoiceOver label per state.
  static func accessibilityLabelText(for state: EngineIndicatorState) -> String {
    switch state {
    case .offline:
      return "Engine stopped"
    case .starting:
      return "Engine starting"
    case let .loading(modelID, fraction):
      let leaf = ModelDisplayName.leaf(modelID)
      if let fraction {
        return "Loading model \(leaf), \(Int(fraction * 100)) percent complete"
      }
      return "Loading model \(leaf)"
    case let .running(modelID):
      if let modelID {
        return "Engine running, model \(ModelDisplayName.leaf(modelID)) resident"
      }
      return "Engine running"
    case let .error(error):
      return "\(error.title). \(error.message)"
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
  @Binding var isPresented: Bool
  var onUnload: () -> Void = {}

  /// Latest engine RSS sample, refreshed every ~2s while the popover is
  /// open and the engine is running/ready. Local-only; nil hides the row.
  @State private var memory: EngineMemorySample?

  /// The destructive action the user armed — Cancel a live load or
  /// Unload a resident model — CAPTURED at arm time. The confirm acts on
  /// this captured intent, NOT a re-read of `center.state` at click time:
  /// if the load resolves (`.loading → .ready`) in the frame between the
  /// user reading the prompt and the click landing, a stale click can no
  /// longer perform the WRONG destructive action — `performDestructive()`
  /// checks the captured kind against the current state and no-ops on a
  /// mismatch. Local `@State`, so it resets to nil every time the popover
  /// is re-presented (fresh content view per presentation) — a stale
  /// armed confirm can never survive a close/reopen. Also cleared
  /// whenever the load resolves under it (see `.onChange(of: stateCategory)`).
  @State private var armedAction: ArmedAction?

  /// Which destructive action a trigger armed. Distinguishing the two at
  /// arm time (rather than re-deriving from `center.state`) is what makes
  /// the confirm honour the user's intent across a state flip.
  private enum ArmedAction { case cancel, unload }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Divider()
      switch center.state {
      case let .failed(_, message):
        failureBlock(message: message)
      case let .engineNotReady(_, detail):
        engineNotReadyBlock(detail: detail)
      default:
        loadDetailRows
        if let memory, Self.showsMemoryRow(centerState: center.state, engineRunningOrReady: isEngineRunningOrReady) {
          memoryRow(memory)
        }
      }
      Divider()
      actionArea
    }
    .padding(14)
    .frame(width: 280)
    .accessibilityIdentifier("modelLoad.popover")
    // If the load resolves (completes, fails, or is cancelled by another
    // path) while the confirm prompt is armed, collapse back to the info
    // view for the NEW state instead of letting the user confirm against
    // stale intent. Keyed on the coarse category, NOT `center.state`:
    // a determinate load mutates the `.loading` byte/eta payload every
    // frame, and resetting on each frame would make the confirm prompt
    // un-openable mid-load.
    .onChange(of: stateCategory) { _, _ in
      armedAction = nil
    }
    // On-demand memory poll: only while the popover is open and the
    // engine is running/ready. Re-armed by `.task(id:)` when the engine
    // state flips so an engine that comes up after the popover opened
    // still starts sampling. Cancelled automatically on disappear.
    .task(id: isEngineRunningOrReady) {
      guard isEngineRunningOrReady else {
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
    if armedAction != nil, let confirm = Self.destructiveConfirm(for: center.state) {
      confirmBlock(confirm)
    } else {
      HStack {
        Spacer()
        actionButton
      }
    }
  }

  /// Engine is in a state where a memory readout is meaningful (a model
  /// is resident / the engine is serving). Drives the `.task` gate and
  /// the row's presence.
  private var isEngineRunningOrReady: Bool {
    if case .running = engineStatus.status {
      return true
    }
    if case .ready = center.state {
      return true
    }
    return false
  }

  /// Whether the on-demand `Memory` row should render. Pure so the gate
  /// is unit-testable (`ModelLoadPopoverMemoryRowTests`): the row shows
  /// only in the steady/loading branch (never over a `.failed` /
  /// `.engineNotReady` block) AND while the engine is running/ready. The
  /// caller still requires a non-nil sample — a nil sample (engine
  /// answered "unavailable", or hasn't answered yet) hides the row.
  static func showsMemoryRow(
    centerState: ModelLoadCenter.State,
    engineRunningOrReady: Bool
  ) -> Bool {
    switch centerState {
    case .failed, .engineNotReady:
      return false
    default:
      return engineRunningOrReady
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: glyphForState)
        .foregroundStyle(.secondary)
      Text(modelID)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch center.state {
    case .ready:
      // : free the resident model's RAM. Destructive/interrupting, so
      // it only ARMS the confirm step — the next send otherwise re-enters
      // the no-model confirm gate with no model resident (#359).
      Button("Unload", role: .destructive) {
        armedAction = .unload
      }
      .accessibilityIdentifier("modelLoad.popover.unload")
    case .failed, .engineNotReady:
      // #396: a failed/deferred load is otherwise a dead end with only
      // "Dismiss". Offer Retry as the recovery action — re-runs the same
      // load via the center's retained factory (`retryLast`). Not
      // destructive (it starts work, doesn't stop it), so no confirm
      // gate; Dismiss stays the default key so the safe non-reloading
      // choice is the accidental one.
      Button("Retry") {
        center.retryLast()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.retry")
      Button("Dismiss") {
        // Use the documented public API instead of the test-only
        // `_testOverrideState` seam — the seam internally calls
        // `cancel()` which bumps the load generation and would kill any
        // new load racing the user's tap. Dismiss only clears an
        // already-finished error ring — not destructive — so it stays a
        // single tap (no confirm gate).
        center.dismissTerminalState()
        isPresented = false
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("modelLoad.popover.dismiss")
    default:
      // Interrupts an in-flight load — arm the confirm rather than
      // cancelling on the first click (#359).
      Button("Cancel", role: .destructive) {
        armedAction = .cancel
      }
      .accessibilityIdentifier("modelLoad.popover.cancel")
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
          armedAction = nil
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

  /// Run the CONFIRMED destructive action — the only path that reaches
  /// `center.cancel()` / `onUnload()` from the status UI. Acts on the
  /// kind the user ARMED, not a fresh read of `center.state` (review v1
  /// F2), and additionally guards that the live state still matches: if
  /// the load flipped `.loading → .ready` between arming and the click,
  /// an armed "Stop Loading" must NOT fall through to unloading the
  /// now-resident model — it no-ops and lets the user re-decide. Every
  /// other interaction (indicator click, arming the trigger, keep/escape)
  /// is non-destructive (#359).
  private func performDestructive() {
    switch armedAction {
    case .cancel:
      if case .loading = center.state { center.cancel() }
    case .unload:
      if case .ready = center.state { onUnload() }
    case nil:
      break
    }
    isPresented = false
  }

  // MARK: - confirm copy (pure)

  /// Plain-language copy + accessibility ids for the explicit confirm
  /// step. Pure function of `state` so the wording (and crucially WHICH
  /// states are destructive) is unit-testable without standing up the
  /// view. Returns nil for every non-destructive state — `.idle` /
  /// `.cancelled` have no action, and `.failed` / `.engineNotReady` use
  /// the one-tap Dismiss — guaranteeing the only `.some` results are the
  /// two interrupting actions (#359). Each message names what stops AND
  /// that it can be resumed, per the ticket's "clear copy" requirement.
  struct DestructiveConfirm: Equatable {
    let message: String
    let confirmTitle: String
    let keepTitle: String
    let confirmIdentifier: String
    let keepIdentifier: String
  }

  static func destructiveConfirm(for state: ModelLoadCenter.State) -> DestructiveConfirm? {
    switch state {
    case let .loading(modelID, _, _, _):
      return DestructiveConfirm(
        message: "Stop loading \(modelID)? The partial load is discarded. You can start it again anytime.",
        confirmTitle: "Stop Loading",
        keepTitle: "Keep Loading",
        confirmIdentifier: "modelLoad.popover.confirmCancel",
        keepIdentifier: "modelLoad.popover.keepLoading"
      )
    case let .ready(modelID):
      return DestructiveConfirm(
        message: "Unload \(modelID)? This frees its memory. The engine keeps running — you'll need to reload the model before your next message.",
        confirmTitle: "Unload",
        keepTitle: "Keep Loaded",
        confirmIdentifier: "modelLoad.popover.confirmUnload",
        keepIdentifier: "modelLoad.popover.keepLoaded"
      )
    case .idle, .cancelled, .failed, .engineNotReady:
      return nil
    }
  }

  // MARK: - state category

  /// Coarse classification of `ModelLoadCenter.State` that ignores the
  /// per-frame `.loading` byte/eta payload. Drives the confirm-reset
  /// `.onChange` so an in-progress determinate load (whose state value
  /// changes every frame) does not collapse the armed confirm prompt,
  /// while a genuine resolution (loading→ready/failed/cancelled) does.
  enum StateCategory: Equatable {
    case idle, loading, ready, cancelled, failed, engineNotReady
  }

  private var stateCategory: StateCategory {
    switch center.state {
    case .idle:           return .idle
    case .loading:        return .loading
    case .ready:          return .ready
    case .cancelled:      return .cancelled
    case .failed:         return .failed
    case .engineNotReady: return .engineNotReady
    }
  }

  private func failureBlock(message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Load failed")
        .font(.callout.weight(.medium))
        .foregroundStyle(Color.red)
      Text(message)
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
  @ViewBuilder
  private var loadDetailRows: some View {
    switch center.state {
    case .loading:
      switch Self.loadingDetail(for: center.state, fraction: center.progress) {
      case .preparing:
        // No byte total and nothing transferred yet — the only honest
        // thing to say is "working on it". The spinning ring carries the
        // motion; this avoids a bogus "Loaded —" / "ETA —" pair.
        detailRow("Status", "Preparing…")
      case let .indeterminate(loaded):
        detailRow("Loaded", loaded)
        detailRow("ETA", "Estimating…")
      case let .determinate(loaded, eta):
        detailRow("Loaded", loaded)
        detailRow("ETA", eta)
      case .none:
        EmptyView()
      }
    case .ready:
      // Resident model — the load is done, so no bytes/ETA rows (the
      // old code showed a stale "—/—" pair here). The memory row below
      // carries the useful readout.
      detailRow("Status", "Loaded — resident")
    case .cancelled:
      detailRow("Status", "Load cancelled")
    case .idle, .failed, .engineNotReady:
      EmptyView()
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

  private var modelID: String {
    switch center.state {
    case let .loading(id, _, _, _):    return id
    case let .ready(id):               return id
    case let .cancelled(id):           return id
    case let .failed(id, _):           return id
    case let .engineNotReady(id, _):   return id
    case .idle:                        return "—"
    }
  }

  private var glyphForState: String {
    switch center.state {
    case .failed:          return "exclamationmark.triangle"
    case .engineNotReady:  return "hourglass"
    default:               return "shippingbox"
    }
  }

  // MARK: - load detail (pure, #396)

  /// Pure description of the in-progress load detail, so the
  /// "never render — for a live load" rule (#396) is unit-testable
  /// without standing up the SwiftUI view.
  enum LoadingDetail: Equatable {
    /// Indeterminate with no byte info yet → single "Preparing…" line.
    case preparing
    /// Bytes flowing but no transfer-rate sample yet → loaded amount +
    /// an honest "Estimating…" ETA.
    case indeterminate(loaded: String)
    /// Byte progress (and possibly ETA) known. `eta` is already the
    /// honest string — a real duration, or "Estimating…" when the rate
    /// sample is still missing — never "—".
    case determinate(loaded: String, eta: String)
  }

  static func loadingDetail(for state: ModelLoadCenter.State, fraction: Double?) -> LoadingDetail? {
    guard case let .loading(_, loaded, total, eta) = state else { return nil }
    // `fraction != nil` is the single determinacy source shared with the
    // ring + label (matches ModelLoadCenter.progress).
    if fraction != nil {
      return .determinate(loaded: bytesPair(loaded, total), eta: etaString(eta))
    }
    if loaded > 0 {
      return .indeterminate(loaded: formatMB(loaded))
    }
    return .preparing
  }

  /// Honest ETA copy. Unknown ETA is metadata-not-yet-known, not an
  /// error, so it reads "Estimating…" — never a meaningless dash (#396).
  static func etaString(_ eta: Double?) -> String {
    guard let eta else { return "Estimating…" }
    if eta < 1 { return "< 1 s" }
    if eta < 60 { return "\(Int(eta.rounded())) s" }
    let mins = Int(eta) / 60
    let secs = Int(eta) % 60
    return "\(mins) min \(secs) s"
  }

  static func bytesPair(_ loaded: UInt64, _ total: UInt64) -> String {
    "\(formatMB(loaded)) / \(formatMB(total))"
  }

  static func formatMB(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024.0 * 1024.0)
    if mb >= 1024 {
      return String(format: "%.2f GB", mb / 1024.0)
    }
    return String(format: "%.0f MB", mb)
  }
}

/// Trailing `…` rendered as three dots that cycle `.` → `..` → `...`.
/// All three dots always occupy layout space — only their opacity
/// animates — so the dots never reflow the text that follows. Driven by
/// `TimelineView(.periodic)` so the cadence is a deterministic function
/// of `Date` whose lifetime ends with the view (matching the
/// indeterminate-arc rationale).
private struct AnimatedEllipsis: View {
  /// Seconds per dot step; full `.`→`..`→`...` cycle is 3× this.
  private let step: TimeInterval = 0.4

  var body: some View {
    TimelineView(.periodic(from: .now, by: step)) { context in
      let phase = Int(context.date.timeIntervalSinceReferenceDate / step)
      let visible = phase % 3 + 1   // 1, 2, or 3
      HStack(spacing: 0) {
        ForEach(0..<3, id: \.self) { i in
          Text(".").opacity(i < visible ? 1 : 0)
        }
      }
      .monospacedDigit()
    }
    .accessibilityHidden(true)
  }
}
