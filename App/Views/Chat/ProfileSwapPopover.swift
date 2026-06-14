import SwiftUI
import AppKit

/// Cross-model profile-swap confirmation (Phase 3.6, design §R8).
///
/// Surfaces:
///   · target model name (`shippingbox` glyph)
///   · "From → To" model summary row
///   · optional size (engine-reported total bytes) — hidden when
///     unknown; v1 wires no source for this yet, kept as a slot so
///     Phase 6's `/v1/models` listing can populate it without a
///     follow-up view change.
///   · optional ETA — same shape as size.
///   · "Set as default for this profile" checkbox — shown only
///     when `pending.canSetAsDefault` (a runtime model override).
///   · Cancel / Switch buttons (Switch is default).
///
/// Bound to a `ProfileSwapCoordinator.PendingSwap` via `Binding<Bool>`
/// on `isPresented`; the coordinator owns the state machine so the
/// popover stays a dumb form.
struct ProfileSwapPopover: View {
  let pending: ProfileSwapCoordinator.PendingSwap
  /// Optional size / ETA hints. v1 callers pass nil; Phase 6 can
  /// thread `ModelInfo.size_bytes` + a cached transfer-rate estimate.
  let estimatedTotalBytes: UInt64?
  let estimatedEtaSeconds: Double?
  let onConfirm: (_ setAsDefault: Bool) -> Void
  let onCancel: () -> Void
  /// #459 third outcome (profile-swap path only): switch the profile but
  /// keep the already-resident model loaded, with no reload. Rendered only
  /// when `pending.canKeepCurrentModel`.
  let onKeepCurrent: () -> Void

  /// : only meaningful for a runtime model override
  /// (`pending.canSetAsDefault`). Checking it persists the picked model
  /// as the active profile's default.
  @State private var setAsDefault: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      swapRow
      if let totalBytes = estimatedTotalBytes {
        labeledRow("Size", value: formatMB(totalBytes))
      }
      if let eta = estimatedEtaSeconds {
        labeledRow("ETA", value: formatEta(eta))
      }
      if pending.canSetAsDefault {
        Divider()
        Toggle(isOn: $setAsDefault) {
          Text("Set as default for this profile")
            .font(.callout)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("profileSwap.setAsDefaultToggle")
      }
      HStack {
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
        // #459: third outcome on the profile-swap path — switch the profile
        // but keep the model already loaded (no reload). Not offered on the
        // model-override path (the user explicitly picked a model to load).
        if pending.canKeepCurrentModel {
          Button("Keep Current Model") {
            onKeepCurrent()
          }
          .accessibilityIdentifier("profileSwap.keepCurrent")
        }
        Button("Switch") {
          onConfirm(setAsDefault)
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("profileSwap.switch")
      }
    }
    .padding(16)
    .frame(width: 320)
    .accessibilityIdentifier("profileSwap.popover")
  }

  // MARK: - rows

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.swap")
        .foregroundStyle(.secondary)
      Text("Switch model?")
        .font(.headline)
    }
  }

  private var swapRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "shippingbox")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(pending.fromModelID ?? "no model")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(pending.toModelID)
          .font(.body.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
    }
  }

  private func labeledRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.callout)
  }

  // MARK: - formatting

  private func formatMB(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024.0 * 1024.0)
    if mb >= 1024 {
      return String(format: "%.2f GB", mb / 1024.0)
    }
    return String(format: "%.0f MB", mb)
  }

  private func formatEta(_ seconds: Double) -> String {
    if seconds < 1 { return "< 1 s" }
    if seconds < 60 { return "\(Int(seconds.rounded())) s" }
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return "\(mins) min \(secs) s"
  }
}

// MARK: - resign-key-surviving host (#582)

/// Hosts `ProfileSwapPopover` in a coordinator-owned `NSPopover` whose
/// `.applicationDefined` behavior survives the window resigning key — Cmd-Tab,
/// a Dock click, Spotlight, a notification stealing focus, etc. SwiftUI's
/// `.popover` (whether `isPresented:` or `item:`) is `.transient`, so AppKit
/// auto-closes it the instant the window loses key, silently dropping a pending
/// cross-model swap (#582). With `.applicationDefined` AppKit never closes it on
/// its own: only the coordinator does, by clearing `pending` — which the
/// token-checked Cancel / Keep Current / Switch actions (or `Esc`) do, and which
/// `sync` then tears the popover down for.
///
/// Attach via `.background(...)` on the profile menu so the empty anchor
/// `NSView` tracks the menu's frame; the popover presents below it. The anchor
/// is a plain unflipped `NSView` (`isFlipped == false`), so its bottom edge is
/// `.minY` in AppKit geometry — that is the `preferredEdge` for a below-the-menu
/// placement matching the former `arrowEdge: .bottom`.
///
/// Token capture (review v2 F4) is preserved: `sync` captures `pending.id` when
/// it builds the content, so each button callback carries the token that was
/// live at present time. A re-entrant swap publishes a new token, `sync`
/// rebuilds, and any stale callback from the superseded popover is
/// token-mismatched and dropped by the coordinator.
struct ProfileSwapPopoverHost: NSViewRepresentable {
  let pending: ProfileSwapCoordinator.PendingSwap?
  let onConfirm: (_ token: UUID, _ setAsDefault: Bool) -> Void
  let onCancel: (_ token: UUID) -> Void
  let onKeepCurrent: (_ token: UUID) -> Void

  func makeCoordinator() -> Host { Host() }

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.sync(
      pending: pending,
      anchor: nsView,
      onConfirm: onConfirm,
      onCancel: onCancel,
      onKeepCurrent: onKeepCurrent
    )
  }

  @MainActor
  final class Host {
    private var popover: NSPopover?
    private var shownToken: UUID?

    func sync(
      pending: ProfileSwapCoordinator.PendingSwap?,
      anchor: NSView,
      onConfirm: @escaping (UUID, Bool) -> Void,
      onCancel: @escaping (UUID) -> Void,
      onKeepCurrent: @escaping (UUID) -> Void
    ) {
      guard let pending else {
        close()
        return
      }
      // The same pending is already on screen — leave it (and its anchored
      // arrow) untouched so a focus blip never tears it down and rebuilds it.
      if shownToken == pending.id, popover?.isShown == true { return }
      // A re-entrant swap published a new token — replace the content.
      close()
      // Anchor not yet in a window (first layout pass) — a later update, once
      // `pending` triggers a re-render with the view hosted, presents it.
      guard anchor.window != nil else { return }

      let token = pending.id
      let hosting = NSHostingController(rootView: ProfileSwapPopover(
        pending: pending,
        estimatedTotalBytes: nil,
        estimatedEtaSeconds: nil,
        onConfirm: { onConfirm(token, $0) },
        onCancel: { onCancel(token) },
        onKeepCurrent: { onKeepCurrent(token) }
      ))
      hosting.sizingOptions = [.preferredContentSize]

      let popover = NSPopover()
      popover.behavior = .applicationDefined   // #582: survive resign-key
      popover.contentViewController = hosting
      // `.minY` = the anchor's bottom edge (unflipped NSView), so the popover
      // presents below the profile menu — the former `arrowEdge: .bottom`.
      popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
      self.popover = popover
      self.shownToken = token
    }

    private func close() {
      popover?.performClose(nil)
      popover = nil
      shownToken = nil
    }
  }
}
