import SwiftUI

/// Window-toolbar load indicator (design §R8, Phase 3.5).
///
///   ┌─ Circle (SF Symbol "circle", secondary) ────────────────────┐
///   │     overlaid with                                            │
///   │  Circle().trim(from: 0, to: p).rotation(-90°).stroke(...)    │
///   │     determinate when engine reports total bytes,             │
///   │     indeterminate (rotating short arc) otherwise.            │
///   └──────────────────────────────────────────────────────────────┘
///
/// Click → popover with model name, loaded/total MB, ETA, Cancel.
///
/// Visibility:
///   · `.loading` → indicator visible, accent stroke.
///   · `.failed`  → indicator visible, red stroke (review v1 F7 —
///     a hidden failure offers the user no signal; popover surfaces
///     the message and a Dismiss action that clears the state).
///   · everything else → `.opacity(0)` so the toolbar layout never
///     reflows mid-load.
struct ModelLoadIndicator: View {
  @ObservedObject var center: ModelLoadCenter
  /// : invoked from the `.ready` popover's Unload button. Wired in
  /// `RootView` to stop the engine (free RAM) then `markUnloaded()`.
  var onUnload: () -> Void = {}
  /// #218 F3: invoked from the `.engineNotReady` popover's "Stop Engine"
  /// button. Stop-only (no `markUnloaded`) — see `ModelLoadPopover.onStopEngine`.
  var onStopEngine: () -> Void = {}

  @State private var showPopover = false

  var body: some View {
    // Single source of determinacy (review v1 F2): `center.progress` is
    // the one place that decides determinate-vs-indeterminate (and
    // latch-logs a `loaded > total` protocol bug). The label percent,
    // the ring fill, and the ellipsis-animation flag all read from this
    // one value so they can never drift — an overflow frame falls back
    // to indeterminate copy AND a spinning ring AND animated dots.
    let fraction = center.progress
    return Button {
      showPopover.toggle()
    } label: {
      // : pair the ring with self-explanatory text on its
      // left so the indicator reads as a labeled control rather than
      // an ambiguous floating wheel. No `.background` here — the bare
      // `.plain` button lets the toolbar chrome show through, which is
      // what removes the "odd boxed background" the icon-only widget
      // appeared to have in review snapshots.
      HStack(spacing: 5) {
        if let prefix = Self.labelPrefix(for: center.state, fraction: fraction) {
          HStack(spacing: 0) {
            // Review v1 F1: cap width + middle-truncate so a long
            // HF-style repo ID can't render unbounded and crowd other
            // toolbar items — mirrors the popover header treatment.
            Text(prefix)
              .monospacedDigit()
              .lineLimit(1)
              .truncationMode(.middle)
            if Self.labelAnimatesEllipsis(for: center.state, fraction: fraction) {
              AnimatedEllipsis()
            }
          }
          .font(.callout)
          .foregroundStyle(labelTint)
          .frame(maxWidth: 200, alignment: .trailing)
        }
        indicatorShape(fraction: fraction)
      }
    }
    .buttonStyle(.plain)
    .opacity(isSurfaceVisible ? 1 : 0)
    .allowsHitTesting(isSurfaceVisible)
    .help(helpText)
    .accessibilityIdentifier("toolbar.modelLoadIndicator")
    .accessibilityLabel(accessibilityLabelText)
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      ModelLoadPopover(center: center, isPresented: $showPopover, onUnload: onUnload, onStopEngine: onStopEngine)
    }
    // Review v1 F11: a popover opened during load A must close when
    // the surface goes invisible between load A and load B, otherwise
    // a stale popover reappears anchored at the next load's indicator.
    .onChange(of: isSurfaceVisible) { _, visible in
      if !visible { showPopover = false }
    }
    // Review v2 F7: clicking outside the popover dismisses it but
    // does NOT clear `.failed` / `.cancelled`, leaving the red ring
    // (or invisible-but-terminal state) stuck. When the popover
    // closes from any path while state is terminal, ack the terminal
    // and return to .idle. Confirms via Dismiss button still work
    // — they call dismissTerminalState directly, then close.
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

  private func indicatorShape(fraction: Double?) -> some View {
    ZStack {
      Image(systemName: "circle")
        .imageScale(.medium)
        .foregroundStyle(.secondary)
      progressOverlay(fraction: fraction)
        .frame(width: 14, height: 14)
    }
    .frame(width: 18, height: 18)
  }

  @ViewBuilder
  private func progressOverlay(fraction: Double?) -> some View {
    switch center.state {
    case .loading:
      if let fraction {
        Circle()
          .trim(from: 0, to: fraction)
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-90))
      } else {
        indeterminateArc
      }
    case .failed:
      // Static red ring so the failure is unmissable; the popover
      // carries the actionable message (review v1 F7).
      Circle()
        .stroke(Color.red, style: StrokeStyle(lineWidth: 2))
    case .engineNotReady:
      // : yellow ring distinguishes "engine still booting"
      // from "load failed" — same wait-and-retry shape the helper
      // menu-bar dot uses for `.starting`/`.stopping`.
      Circle()
        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2))
    case .ready:
      // : a resident model gets a solid green ring so the user has
      // a visible, clickable affordance to Unload (free RAM). Without
      // this the indicator was invisible once loaded.
      Circle()
        .stroke(Color.green, style: StrokeStyle(lineWidth: 2))
    default:
      EmptyView()
    }
  }

  /// Spinner driven by `TimelineView(.animation)` (review v1 F10) so
  /// the rotation is a deterministic function of `Date` rather than
  /// an open-ended `withAnimation(.repeatForever)` whose lifetime
  /// outlives view teardown.
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

  // MARK: - toolbar label

  /// Stable prefix for the toolbar label (no trailing ellipsis — the
  /// animated dots are appended separately for the active states).
  /// `fraction` is `ModelLoadCenter.progress` — the single source of
  /// the determinate-vs-indeterminate decision (review v1 F2). Pure
  /// function of `(state, fraction)` so it can be asserted in unit
  /// tests. `.ready` deliberately returns nil so a resident model
  /// leaves the toolbar quiet; every *waiting/error* state gets
  /// self-explanatory copy so the ring is never an ambiguous wheel.
  static func labelPrefix(for state: ModelLoadCenter.State, fraction: Double?) -> String? {
    switch state {
    case let .loading(modelID, _, _, _):
      if let fraction {
        return "Loading \(modelID)… \(Int(fraction * 100))%"
      }
      return "Loading \(modelID)"
    case .failed:          return "Load failed"
    case .engineNotReady:  return "Engine starting"
    default:               return nil
    }
  }

  /// Whether the label animates a trailing ellipsis. Determinate loads
  /// already show a percent that cycling dots would jitter, so only the
  /// indeterminate waiting states (`Loading id`, `Engine starting`,
  /// and an overflow `loaded > total` frame) get the dots. Keyed off
  /// the same `fraction` as the percent and the ring (review v1 F2) so
  /// the three can never disagree.
  static func labelAnimatesEllipsis(for state: ModelLoadCenter.State, fraction: Double?) -> Bool {
    switch state {
    case .loading:        return fraction == nil
    case .engineNotReady: return true
    default:              return false
    }
  }

  /// Match the label colour to the ring so the control reads as one
  /// unit: muted for in-progress/engine-starting, red for failure.
  private var labelTint: Color {
    switch center.state {
    case .failed: return .red
    default:      return .secondary
    }
  }

  // MARK: - state helpers

  /// True when the indicator should render at full opacity. Loading
  /// AND failed both qualify (failure is otherwise undetectable —
  /// review v1 F7).
  private var isSurfaceVisible: Bool {
    switch center.state {
    case .loading, .failed, .engineNotReady, .ready: return true
    default: return false
    }
  }

  private var helpText: String {
    switch center.state {
    case let .loading(modelID, _, _, _):    return "Loading \(modelID)…"
    case let .failed(modelID, _):           return "Load failed: \(modelID)"
    case let .engineNotReady(modelID, _):   return "Engine starting… (\(modelID) load deferred)"
    case let .ready(modelID):               return "Model loaded: \(modelID) — click to unload"
    default:                                return ""
    }
  }

  private var accessibilityLabelText: String {
    switch center.state {
    case let .loading(modelID, _, _, _):
      // Same single-source fraction as the visible label/ring (F2).
      if let fraction = center.progress {
        return "Loading model \(modelID), \(Int(fraction * 100)) percent complete"
      }
      return "Loading model \(modelID)"
    case let .failed(modelID, _):
      return "Model load failed: \(modelID)"
    case let .engineNotReady(modelID, _):
      return "Engine starting, model \(modelID) load deferred"
    case let .ready(modelID):
      return "Model loaded: \(modelID)"
    default:
      return ""
    }
  }
}

/// Popover surfaced from the toolbar indicator. Read-only details +
/// the active control for the current state — `Cancel` while loading,
/// `Dismiss` after a failure (review v1 F7) so the user can clear the
/// red ring without restarting the load. Both end-states dismiss the
/// popover so the user does not have to click outside.
struct ModelLoadPopover: View {
  @ObservedObject var center: ModelLoadCenter
  @Binding var isPresented: Bool
  var onUnload: () -> Void = {}
  /// #218 F3: stop-only action for the `.engineNotReady` "Stop Engine"
  /// path. Calls ONLY `stopEngine()` — NOT the RAM-freeing `onUnload`
  /// (= `markUnloaded()` → `cancel()`), whose async, epoch-unguarded
  /// `cancel()` could land in the post-stop window and silently kill a
  /// load the user just started. The app-side `.engineNotReady` → `.idle`
  /// reset is handled epoch-safely by the popover-close
  /// `dismissTerminalState()` (see `ModelLoadIndicator`), mirroring the
  /// Dismiss path's race avoidance.
  var onStopEngine: () -> Void = {}

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

  /// The single control surfaced for a given load state. Pure mapping
  /// (testable without the view) so the popover button can't drift from
  /// intent — mirrors the `labelPrefix`/`labelAnimatesEllipsis` seams.
  enum PrimaryAction: Equatable {
    /// `.loading` — cancel the in-flight load (client-side stream only;
    /// the engine keeps running).
    case cancel
    /// `.engineNotReady` (#218) — the slow "Engine starting…" the user
    /// wants to abort IS the engine booting. Terminate it (stop-only,
    /// via `onStopEngine`) and let the popover-close `dismissTerminalState()`
    /// reset to a clean idle slate so the user can pick another model and
    /// Resume without stale state.
    case stopEngine
    /// `.ready` — free the resident model's RAM.
    case unload
    /// `.failed` — clear the error ring; the engine state is untouched.
    case dismiss
    /// `.idle`/`.cancelled` — no actionable control (indicator is hidden
    /// in these states, so this is normally unreachable).
    case none
  }

  static func primaryAction(for state: ModelLoadCenter.State) -> PrimaryAction {
    switch state {
    case .loading:          return .cancel
    case .engineNotReady:   return .stopEngine
    case .ready:            return .unload
    case .failed:           return .dismiss
    case .idle, .cancelled: return .none
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch Self.primaryAction(for: center.state) {
    case .unload:
      // : free the resident model's RAM. The next send re-enters
      // the no-model confirm gate.
      Button("Unload", role: .destructive) {
        onUnload()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.unload")
    case .stopEngine:
      // #218 (F3): terminate the booting engine via the STOP-ONLY action
      // — not `onUnload`. `onUnload` = `markUnloaded()` → `cancel()`,
      // which runs asynchronously after the stopEngine XPC round-trip and
      // is epoch-unguarded, so it could cancel a load the user started in
      // the "stop → pick another model" window. Setting `isPresented =
      // false` routes the app-side `.engineNotReady` → `.idle` reset
      // through the popover-close `dismissTerminalState()` (epoch-safe;
      // does not touch the load task), mirroring the Dismiss path.
      Button("Stop Engine", role: .destructive) {
        onStopEngine()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.stopEngine")
    case .dismiss:
      Button("Dismiss") {
        // Review v2 F3: use the documented public API instead of the
        // test-only `_testOverrideState` seam — the seam internally
        // calls `cancel()` which bumps the load generation and would
        // kill any new load racing the user's tap.
        center.dismissTerminalState()
        isPresented = false
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("modelLoad.popover.dismiss")
    case .cancel:
      Button("Cancel", role: .destructive) {
        center.cancel()
        isPresented = false
      }
      .accessibilityIdentifier("modelLoad.popover.cancel")
    case .none:
      EmptyView()
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

  /// : `.engineNotReady` placeholder block. Reads as
  /// "Engine starting…" + the store's status detail (e.g. "Engine
  /// stopped" or "Helper unreachable: <error>"). Distinct copy +
  /// muted (not red) tint so the user reads "the engine is still
  /// coming up, my click is queued in spirit" instead of "the load
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

/// Trailing `…` rendered as three dots that cycle `.` → `..` → `...`
///. All three dots always occupy layout space — only
/// their opacity animates — so the dots never reflow the text that
/// follows (the percent) or shift the ring beside it. Driven by
/// `TimelineView(.periodic)` rather than `withAnimation(.repeatForever)`
/// so the cadence is a deterministic function of `Date` whose lifetime
/// ends with the view (matching the indeterminate-arc rationale, F10).
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
