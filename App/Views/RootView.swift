import SwiftUI

/// Three-column shell per design §5 (Notes-style information disclosure).
/// Sidebar + item-list are independently collapsible via menu commands wired
/// in `RatioThinkApp` against `WindowState`.
struct RootView: View {
  @EnvironmentObject private var windowState: WindowState
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
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
  /// Backing store for the titlebar new-chat affordance (below). The chat
  /// list owns its own context for its own mutations; this one drives the
  /// global "new chat" that replaced the window branding.
  @Environment(\.modelContext) private var modelContext

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
        onRestartEngine: { restartEngineFromBanner() }
      )
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
        SidebarView(selection: $windowState.selectedSection)
      } content: {
        if windowState.isItemListHidden || !(windowState.selectedSection?.hasItemList ?? false) {
          // Collapse col 2 to zero width when toggled off via View > Hide
          // List, or for sections with no item list (API Endpoints → its
          // single `LocalAPIView` fills the detail column, #422; Search →
          // its panel fills the detail column).
          Color.clear
            .navigationSplitViewColumnWidth(min: 0, ideal: 0, max: 0)
        } else {
          ItemListView(
            section: windowState.selectedSection,
            selectedItemID: $windowState.selectedItemID
          )
        }
      } detail: {
        DetailView(
          section: windowState.selectedSection,
          selectedItemID: windowState.selectedItemID
        )
        .navigationSplitViewColumnWidth(min: 480, ideal: 720)
      }
      // Branding removed from the titlebar (was `.navigationTitle("RatioThink")`);
      // an emphasized new-chat button now occupies that spot. Empty title keeps
      // the titlebar clear rather than falling back to the bundle name.
      .navigationTitle("")
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button(action: createChat) {
            Image(systemName: "square.and.pencil")
          }
          .help("New Chat")
          .accessibilityIdentifier("chats.newButton")
        }
      }
    }
    .task { await runLaunchUpdateCheck() }
  }

  /// Global new-chat affordance hosted in the titlebar where the app name
  /// used to render. Creates a chat, switches to the Chats section, and
  /// selects it so the new conversation opens regardless of which section
  /// was active. Routes through the same `ChatCreation` seam as the
  /// list/empty-state buttons so the "don't persist until first send"
  /// scaffold policy stays in one place.
  private func createChat() {
    if let id = ChatCreation.create(
      in: modelContext,
      persistenceStatus: persistenceStatus,
      contextLabel: "RootView.newChat"
    ) {
      windowState.selectedSection = .chats
      windowState.selectedItemID = id
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
