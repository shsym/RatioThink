import SwiftUI
import ServiceManagement

/// Full-bleed overlay over the chat body (#496).
///
/// While the background Helper is being brought up at launch it renders a calm,
/// bounded "Starting background helper…" wait; once the App-side restart ladder
/// has given up it renders the action-oriented escalation. It replaces the
/// transcript + composer (the toolbar + status banner stay visible above it) so
/// the user never sees an inert / missing-helper chat, and never an engine-framed
/// "Engine stopped" for a Helper that simply hadn't come up.
///
/// Driven by `HelperRecoveryGate` (pure, SPM-tested); this view is thin
/// presentation. The escalation's three actions are the complete recovery menu
/// for a dead background Helper — restart it (re-run the launchd registration
/// repair), re-enable it in System Settings → Login Items (the only path that
/// clears the macOS consent gate), or collect a redacted diagnostics bundle.
/// None of them start the engine or load a model, so #286's no-hidden-fallback /
/// no-surprise-memory policy holds.
struct HelperRecoveryOverlay: View {
  let state: HelperRecoveryGate.State
  /// Re-run the registration repair / restart ladder from attempt 1.
  let onRestartHelper: () -> Void
  /// Open System Settings → Login Items (clears the macOS consent gate).
  let onOpenLoginItems: () -> Void
  /// Collect the redacted diagnostics bundle and reveal it in Finder.
  let onCollectDiagnostics: () -> Void

  var body: some View {
    // Copy lives in the pure, SPM-tested `HelperRecoveryGate` (mirroring
    // `StatusBannerReducer`); this view is thin presentation over it.
    if let copy = HelperRecoveryGate.copy(for: state) {
      // NOTE: no `.accessibilityIdentifier` on this container — on current
      // SwiftUI a container id propagates down and OVERRIDES the child controls'
      // own identifiers (the title + the Restart/LoginItems/Diagnostics
      // buttons), making them unqueryable (the same trap documented in
      // `NoModelLoadedPrompt.body`). The title (`helperRecovery.title`) is the
      // state-independent "overlay is up" marker; the controls carry their own
      // ids.
      surface(copy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
  }

  @ViewBuilder
  private func surface(_ copy: HelperRecoveryGate.Copy) -> some View {
    VStack(spacing: 14) {
      header(copy)
      if state == .unreachable {
        actions
      }
    }
    .padding(28)
    .frame(maxWidth: 420)
  }

  private func header(_ copy: HelperRecoveryGate.Copy) -> some View {
    VStack(spacing: 10) {
      icon
      // NOTE: no `.accessibilityIdentifier` here — applying one to a `Text`
      // suppresses its accessibility LABEL (XCUITest then reads an empty
      // string), so the title is queried by its visible copy instead. The
      // copy itself is the state marker (and is pinned in HelperRecoveryGate).
      Text(copy.title)
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(copy.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var icon: some View {
    switch state {
    case .startingHelper:
      ProgressView().controlSize(.large)
    case .unreachable:
      Image(systemName: "bolt.horizontal.circle.fill")
        .font(.system(size: 34))
        .foregroundStyle(.red)
    case .hidden:
      EmptyView()
    }
  }

  private var actions: some View {
    HStack(spacing: 12) {
      Button("Restart Helper") { onRestartHelper() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("helperRecovery.restart")
      Button("Open Login Items…") { onOpenLoginItems() }
        .accessibilityIdentifier("helperRecovery.loginItems")
      Button("Collect Diagnostics…") { onCollectDiagnostics() }
        .accessibilityIdentifier("helperRecovery.diagnostics")
    }
    .padding(.top, 2)
  }
}
