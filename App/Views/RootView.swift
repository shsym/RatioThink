import SwiftUI
import ServiceManagement

/// Simplified chat shell: primary navigation plus the searchable chat list live
/// in the left column, while the middle split-view column stays collapsed.
/// Sidebar visibility remains wired through `WindowState`.
struct RootView: View {
  @EnvironmentObject private var windowState: WindowState
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  /// #512: empty-chat pruning needs the store — runs on selection change
  /// (prune the chat the user just left) and once at launch (reconcile
  /// shells left behind by quit or by pre-prune builds).
  @Environment(\.modelContext) private var modelContext
  /// Engine lifecycle + in-flight load, folded into the unified
  /// indicator state that gates the engine-error banner. Both are
  /// injected at app scope (`RatioThinkApp`).
  @EnvironmentObject private var engineStatusStore: EngineStatusStore
  /// #412: background-helper health. Drives the helper axis of the unified
  /// status banner (calm "reconnecting" → loud "can't reach helper").
  @EnvironmentObject private var helperHealth: HelperHealthController
  /// Active-profile lookup, for the engine-axis Force Restart target.
  @EnvironmentObject private var profileStore: ProfileStore
  /// #411: persisted ignore-set for update versions + the launch-time update
  /// check state that drives the non-modal `UpdateAvailableBanner`.
  @EnvironmentObject private var appPreferences: AppPreferences
  @EnvironmentObject private var updateAvailability: UpdateAvailabilityModel
  @Environment(\.openURL) private var openURL
  @State private var didEvaluateLocalAPIAutoStart = false
  @State private var localAPIAutoStartError: String?

  var body: some View {
    VStack(spacing: 0) {
      PersistenceBanner(status: persistenceStatus)
      // Unified, source-labeled engine/helper status banner (one poll-count
      // policy, both axes). Tier 0 renders nothing (the toolbar pip shows
      // "Starting… (Ns)"); Tier 1 a calm "reconnecting" bar; Tier 2 a loud
      // error bar with a source-aware Force Restart. Supersedes the separate
      // HelperUnreachableBanner + EngineStatusBanner.
      UnifiedStatusBannerView(
        banner: StatusBannerReducer.make(
          engine: engineStatusStore.status,
          wasEverRunning: engineStatusStore.wasEverRunning,
          helper: helperHealth.health,
          engineGonePolls: engineStatusStore.engineGonePolls,
          policy: engineStatusStore.tierPolicy
        ),
        onRestartHelper: { helperHealth.restartHelperManually() },
        onRestartEngine: { restartEngineFromBanner() },
        onOpenLoginItems: { SMAppService.openSystemSettingsLoginItems() },
        onCollectDiagnostics: { Task { await DiagnosticsCollector.collectAndReveal() } }
      )
      if let localAPIAutoStartError {
        LocalAPIAutoStartErrorBanner(message: localAPIAutoStartError) {
          self.localAPIAutoStartError = nil
        }
      }
      // #411: low-urgency, non-modal update prompt. Only present for a newer,
      // non-ignored release found by the once-per-launch check.
      if let pending = updateAvailability.pending {
        UpdateAvailableBanner(
          pending: pending,
          onDownload: {
            openURL(pending.release.htmlURL)
            updateAvailability.dismissPending()
          },
          onIgnore: { updateAvailability.ignorePending(into: appPreferences) }
        )
      }
      NavigationSplitView(columnVisibility: $windowState.columnVisibility) {
        SidebarView(
          selection: $windowState.selectedSection,
          selectedItemID: $windowState.selectedItemID,
          isItemListHidden: windowState.isItemListHidden
        )
      } content: {
        // Ticket #565 simplifies the shell: the searchable chat list now
        // lives under the primary Chat entry in the left navigation panel.
        // Keep the split view's content column collapsed so API Endpoints is
        // also a direct left-nav → detail route.
        Color.clear
          .navigationSplitViewColumnWidth(min: 0, ideal: 0, max: 0)
      } detail: {
        DetailView(
          section: windowState.selectedSection,
          selectedItemID: windowState.selectedItemID
        )
        .navigationSplitViewColumnWidth(min: 480, ideal: 720)
      }
      .navigationTitle("Rational")
    }
    .task { await runLaunchUpdateCheck() }
    .onAppear { maybeAutoStartLocalAPIOnLaunch() }
    .onChange(of: engineStatusStore.status) { _, new in
      if case .running = new {
        localAPIAutoStartError = nil
      }
      maybeAutoStartLocalAPIOnLaunch()
    }
    // #512: leaving an empty "New Chat" shell deletes it. Hooked on the
    // selection (not view teardown) so it covers chat-switch, new-chat
    // creation, and deselect alike — and only ever prunes the chat the
    // user LEFT, never the selected one, so selection stays untouched.
    .onChange(of: windowState.selectedItemID) { previous, current in
      guard let previous, previous != current else { return }
      ChatLifecycle.pruneIfEmpty(
        chatID: previous, in: modelContext, persistenceStatus: persistenceStatus)
    }
    // #512: launch-time reconcile for persisted empty shells (quit with an
    // empty chat selected, or user data from builds before pruning).
    // Selection starts nil at launch, so `excluding` is belt-and-braces.
    .task {
      ChatLifecycle.pruneAllEmptyChats(
        in: modelContext,
        excluding: windowState.selectedItemID,
        persistenceStatus: persistenceStatus)
    }
  }

  /// #411: run the once-per-launch update check. Skipped on test/automation
  /// launches so GUI/E2E suites never make the one real GitHub network call;
  /// the model's own guard makes a re-`task` a no-op in production.
  private func runLaunchUpdateCheck() async {
    guard !HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment) else {
      return
    }
    await updateAvailability.checkOnLaunch(preferences: appPreferences)
  }

  /// Engine-axis Force Restart (Tier 2, helper alive): re-start the engine on
  /// the active profile. The helper is reachable here, so no registration
  /// reconcile is needed — just a fresh start; the status poll surfaces the
  /// outcome. A slow-start `replyTimeout` is swallowed by
  /// `EngineStatusStore.startEngine`.
  private func restartEngineFromBanner() {
    let profileID = profileStore.activeProfileID
    Task { @MainActor in
      guard let profileID, !profileID.isEmpty else { return }
      try? await engineStatusStore.startEngine(profileID: profileID)
    }
  }

  /// Honor the Local API startup preference once per window lifetime after
  /// the helper's initial placeholder status settles. Default-off preserves
  /// the no-surprise model-load contract; when enabled, this starts the same
  /// shared engine that in-app chat and the Local API page use.
  private func maybeAutoStartLocalAPIOnLaunch() {
    guard !didEvaluateLocalAPIAutoStart else { return }
    if case .starting = engineStatusStore.status { return }
    didEvaluateLocalAPIAutoStart = true

    guard LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: appPreferences.localAPIAutoStartEnabled,
      status: engineStatusStore.status,
      activeProfileID: profileStore.activeProfileID
    ), let profileID = profileStore.activeProfileID else {
      return
    }

    Task { @MainActor in
      let result = await LocalAPIAutoStartLauncher.run(
        enabled: appPreferences.localAPIAutoStartEnabled,
        status: engineStatusStore.status,
        activeProfileID: profileID,
        startEngine: { try await engineStatusStore.startEngine(profileID: $0) },
        errorMessage: { ChatScaffoldView.engineErrorMessage($0, verb: "start") }
      )
      switch result {
      case .skipped, .started:
        localAPIAutoStartError = nil
      case .failed(let message):
        localAPIAutoStartError = message
      }
    }
  }
}

private struct LocalAPIAutoStartErrorBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Local API didn't start")
          .font(.callout)
          .fontWeight(.medium)
        Text(message)
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .imageScale(.small)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.12))
    .accessibilityIdentifier("LocalAPIAutoStartError")
  }
}

/// Phase 4 ( F3) durability banner. Renders a sticky bar above
/// the chat surface whenever the app fell back to the in-memory
/// store, and a transient bar for the most recent persistence error
/// (save failure / delete failure / stream-flush failure). Hidden
/// entirely when both surfaces are clean.
private struct PersistenceBanner: View {
  @ObservedObject var status: PersistenceStatus

  var body: some View {
    VStack(spacing: 0) {
      if case .inMemoryFallback(let reason) = status.storage {
        bar(
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange,
          title: "Chats won't persist after quit",
          detail: "On-disk store unavailable: \(reason)",
          dismissable: false
        )
      }
      if let err = status.lastError {
        bar(
          systemImage: "xmark.octagon.fill",
          tint: .red,
          title: "Couldn't save (\(err.context))",
          detail: err.message,
          dismissable: true,
          onDismiss: status.acknowledgeLastError
        )
      }
    }
    .accessibilityIdentifier("persistence.banner")
  }

  private func bar(
    systemImage: String,
    tint: Color,
    title: String,
    detail: String,
    dismissable: Bool,
    onDismiss: (() -> Void)? = nil
  ) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout).fontWeight(.medium)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      Spacer()
      if dismissable {
        Button {
          onDismiss?()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(tint.opacity(0.12))
    .overlay(Rectangle().frame(height: 0.5).foregroundStyle(tint.opacity(0.5)), alignment: .bottom)
  }
}
