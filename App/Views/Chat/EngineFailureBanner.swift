import SwiftUI

/// In-chat banner for thrown engine-action errors that the live status
/// poll does not own (for example, a stop that left the engine running or
/// a transport error while status remains non-failed). Live
/// `EngineStatus.failed` is rendered once by the app-level unified status
/// banner; keeping this view for distinct action errors avoids routing
/// engine faults to the persistence "Couldn't save" banner (wrong fault
/// domain) without duplicating the global failure copy inside chat.
///
/// The message is decided by `MissingModelRecovery.engineActionFailureBannerMessage`;
/// this view only renders it. `onDismiss` is non-nil only for a dismissable
/// thrown action error.
struct EngineFailureBanner: View {
  let message: String
  let onDismiss: (() -> Void)?

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "exclamationmark.octagon.fill")
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 2) {
        Text("Engine problem")
          .font(.callout.weight(.medium))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if let onDismiss {
        Button("Dismiss", action: onDismiss)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("engineFailure.dismiss")
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.red.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.red.opacity(0.30))
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .accessibilityIdentifier("engineFailure.banner")
  }
}
