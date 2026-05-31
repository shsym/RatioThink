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

/// Popover surfaced from the toolbar pip. Read-only details + the active
/// control for the current load state — `Unload` while running/ready,
/// `Cancel` while loading, `Dismiss` after a failure / engine-not-ready.
/// When the engine is running/ready it also shows an on-demand `Memory`
/// row sampled from the helper while the popover is open. Both
/// end-states dismiss the popover so the user does not have to click out.
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
        bytesRow
        etaRow
        if let memory, Self.showsMemoryRow(centerState: center.state, engineRunningOrReady: isEngineRunningOrReady) {
          memoryRow(memory)
        }
      }
      Divider()
      HStack {
        Spacer()
        actionButton
      }
    }
    .padding(14)
    .frame(width: 280)
    .accessibilityIdentifier("modelLoad.popover")
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
      // : free the resident model's RAM. The next send re-enters
      // the no-model confirm gate.
      Button("Unload", role: .destructive) {
        onUnload()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.unload")
    case .failed, .engineNotReady:
      Button("Dismiss") {
        // Use the documented public API instead of the test-only
        // `_testOverrideState` seam — the seam internally calls
        // `cancel()` which bumps the load generation and would kill any
        // new load racing the user's tap.
        center.dismissTerminalState()
        isPresented = false
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("modelLoad.popover.dismiss")
    default:
      Button("Cancel", role: .destructive) {
        center.cancel()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.cancel")
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

  private var bytesRow: some View {
    HStack {
      Text("Loaded")
        .foregroundStyle(.secondary)
      Spacer()
      Text(bytesText)
        .monospacedDigit()
    }
    .font(.callout)
  }

  private var etaRow: some View {
    HStack {
      Text("ETA")
        .foregroundStyle(.secondary)
      Spacer()
      Text(etaText)
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

  private var bytesText: String {
    guard case let .loading(_, loaded, total, _) = center.state else {
      return "—"
    }
    if total == 0 {
      return formatMB(loaded)
    }
    return "\(formatMB(loaded)) / \(formatMB(total))"
  }

  private var etaText: String {
    guard case let .loading(_, _, _, eta) = center.state, let eta else {
      return "—"
    }
    if eta < 1 { return "< 1 s" }
    if eta < 60 { return "\(Int(eta.rounded())) s" }
    let mins = Int(eta) / 60
    let secs = Int(eta) % 60
    return "\(mins) min \(secs) s"
  }

  private func formatMB(_ bytes: UInt64) -> String {
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
