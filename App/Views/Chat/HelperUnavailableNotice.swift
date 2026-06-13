import SwiftUI

/// Inline, helper-framed refusal shown when a user action (Load / start / stop
/// the engine) is gated because the background Helper isn't healthy (#496).
///
/// Deliberately NOT the red `EngineFailureBanner` ("Engine problem"): the whole
/// point of #496 is that a Helper state must never read as an engine fault. The
/// authoritative helper status lives in the window-level `UnifiedStatusBanner`
/// above; this is the immediate, near-the-tap acknowledgment that the action
/// was refused and why. Copy comes from the pure `HelperUnavailable`.
struct HelperUnavailableNotice: View {
  let reason: HelperUnavailable
  let onDismiss: (() -> Void)?

  private var tint: Color { reason == .unreachable ? .red : .orange }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: reason == .unreachable
            ? "bolt.horizontal.circle.fill" : "clock.arrow.circlepath")
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Background helper")
          .font(.callout.weight(.medium))
        Text(reason.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if let onDismiss {
        Button("Dismiss", action: onDismiss)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("helperUnavailable.dismiss")
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.30)))
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .accessibilityIdentifier("helperUnavailable.notice")
  }
}
