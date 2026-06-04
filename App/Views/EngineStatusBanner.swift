import SwiftUI

/// In-window engine-error banner. The one loud surface in the
/// otherwise-quiet engine-status design: a sticky bar above the chat
/// surface that appears ONLY for a genuine engine/load failure
/// (`EngineIndicatorState.error`), reusing `PersistenceBanner`'s bar
/// styling so the two read as the same kind of app-level alert.
///
/// Loading and steady states never banner — the reducer already maps a
/// transient poll failure (helper briefly unreachable) to `.starting`,
/// so `bannerError` is non-nil only for real failures and this view can
/// gate purely on it.
///
/// Dedup: Dismiss records the failure's signature on `EngineStatusStore`;
/// the banner then suppresses THIS failure but re-shows on a DIFFERENT
/// one (mirrors `PersistenceBanner`'s `acknowledgeLastError`). The gating
/// + signature are pure (`model(from:acknowledgedSignature:)` /
/// `signature(for:)`) so the dedup is unit-tested without SwiftUI.
struct EngineStatusBanner: View {
  /// The current unified indicator state, computed by the caller from
  /// both stores. Only its `.error` payload is consulted.
  let indicatorState: EngineIndicatorState
  /// Source of truth for the acknowledged-failure signature + the
  /// Dismiss action.
  @ObservedObject var engineStatus: EngineStatusStore

  /// Presentation model for a banner that should render. Nil ⇒ no banner.
  struct Model: Equatable {
    let title: String
    let message: String
    /// Stable id of the failure, recorded on Dismiss for dedup.
    let signature: String
  }

  /// Stable signature for an engine failure: its kind + message. Two
  /// failures with the same kind and text are "the same failure" for
  /// dedup; a changed code or message re-shows the banner.
  static func signature(for error: EngineIndicatorError) -> String {
    "\(error.kind)|\(error.message)"
  }

  /// Pure gating + content. Returns a `Model` when the banner should
  /// render (a live failure that hasn't been dismissed), else nil:
  ///   · no `.error` state → nil (loading/steady never banner).
  ///   · failure whose signature was already acknowledged → nil.
  ///   · otherwise → the title/message (+ a Model-menu hint when the
  ///     failure `invitesModelChoice`).
  static func model(
    from state: EngineIndicatorState,
    acknowledgedSignature: String?
  ) -> Model? {
    guard let error = state.bannerError else { return nil }
    let sig = signature(for: error)
    guard sig != acknowledgedSignature else { return nil }
    let message = error.invitesModelChoice
      ? error.message + " Pick a smaller model from the Model menu."
      : error.message
    return Model(title: error.title, message: message, signature: sig)
  }

  var body: some View {
    if let model = Self.model(
      from: indicatorState,
      acknowledgedSignature: engineStatus.acknowledgedEngineFailureSignature
    ) {
      bar(model)
        .accessibilityIdentifier("engineStatus.banner")
    }
  }

  /// Mirrors `PersistenceBanner.bar(...)` (red, dismissable) so the two
  /// app-level alerts are visually consistent.
  private func bar(_ model: Model) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "xmark.octagon.fill")
        .foregroundStyle(Color.red)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.title).font(.callout).fontWeight(.medium)
        Text(model.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      Spacer()
      Button {
        engineStatus.acknowledgeEngineFailure(model.signature)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
      .accessibilityIdentifier("engineStatus.banner.dismiss")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.red.opacity(0.12))
    .overlay(
      Rectangle().frame(height: 0.5).foregroundStyle(Color.red.opacity(0.5)),
      alignment: .bottom
    )
  }
}
