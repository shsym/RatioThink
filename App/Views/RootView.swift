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
  @EnvironmentObject private var modelLoadCenter: ModelLoadCenter

  var body: some View {
    VStack(spacing: 0) {
      PersistenceBanner(status: persistenceStatus)
      // Loud surface for engine/load failures only; quiet for everything
      // else. Self-hides via the reducer + dedup signature.
      EngineStatusBanner(
        indicatorState: EngineIndicatorState.make(
          engine: engineStatusStore.status,
          engineDetail: engineStatusStore.statusDetail,
          load: modelLoadCenter.state,
          residentModelID: modelLoadCenter.residentModelID
        ),
        engineStatus: engineStatusStore
      )
      NavigationSplitView(columnVisibility: $windowState.columnVisibility) {
        SidebarView(selection: $windowState.selectedSection)
      } content: {
        if windowState.isItemListHidden {
          // Collapse col 2 to zero width when toggled off via View > Hide List.
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
      .navigationTitle("RatioThink")
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
