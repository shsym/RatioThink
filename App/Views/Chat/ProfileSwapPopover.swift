import SwiftUI

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
