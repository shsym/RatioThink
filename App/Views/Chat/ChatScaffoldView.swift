import SwiftUI
import SwiftData

/// Composes the three pieces a chat detail surface needs:
///
///   ┌─ ContentToolbar (flat, no rectangle) ───────────────────────┐
///   ├─ TranscriptView (Messages-style bubbles, auto-scroll) ──────┤
///   └─ ComposerView   (auto-grow 1–8 lines, Enter / Shift+Enter) ─┘
///
/// `DetailView` mounts this with the `chatID` of the currently
/// selected row. A `@Query` predicate filters the SwiftData store
/// to that single chat; SwiftData's `Observable` conformance pushes
/// re-renders for any field change (title, messages append,
/// updatedAt bump) without manual observation.
struct ChatScaffoldView: View {
  @Query private var chats: [Chat]
  @Environment(\.modelContext) private var modelContext
  @StateObject private var viewModel: ChatTranscriptViewModel
  @StateObject private var sendController = ChatSendController()
  let availableProfiles: [String]
  let availableModels: [String]
  @EnvironmentObject private var swapCoordinator: ProfileSwapCoordinator
  @EnvironmentObject private var persistenceStatus: PersistenceStatus
  @EnvironmentObject private var engineStore: EngineClientStore
  @EnvironmentObject private var modelLoadCenter: ModelLoadCenter
  @EnvironmentObject private var engineStatusStore: EngineStatusStore
  @EnvironmentObject private var profileStore: ProfileStore
  /// : shown when the user tries to send with no model resolvable
  /// (no per-chat override, nothing resident). Blocks the send and
  /// offers to load the active profile's default model — never silent.
  @State private var showNoModelPrompt = false
  /// The active profile's default model, captured at the instant the
  /// send is blocked (when `selectedProfileID` is settled and the store
  /// is loaded) rather than at sheet-build time. Drives the prompt's
  /// Load affordance.
  @State private var noModelProfileDefault: String?
  /// What the toolbar model menu should offer. `.unknown` (→ injected
  /// `availableModels`) only until the first reconcile; afterwards it is
  /// the engine's real served list (`.known`, possibly empty), so a
  /// verified empty/not-running/unreachable engine never re-surfaces
  /// placeholder models the engine would reject ( F2).
  @State private var engineModels: ToolbarModelList = .unknown

  init(
    chatID: UUID,
    availableProfiles: [String] = ["chat"],
    availableModels: [String] = ChatTranscriptViewModel.placeholderModels
  ) {
    // Capture the id into a local so the predicate closure does not
    // retain `self` (which doesn't exist yet during `init`).
    let id = chatID
    _chats = Query(filter: #Predicate<Chat> { $0.id == id })
    _viewModel = StateObject(wrappedValue: ChatTranscriptViewModel())
    self.availableProfiles = availableProfiles
    self.availableModels = availableModels
  }

  var body: some View {
    Group {
      if let chat = chats.first {
        scaffold(for: chat)
      } else {
        // Selection points at a chat that no longer exists (deleted
        // from another window, or the store was reset). Render a
        // neutral placeholder rather than crash — the sidebar list
        // will refresh selection on the next render tick.
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.bubble")
            .foregroundStyle(.secondary)
          Text("Chat not found")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
      }
    }
  }

  ///  Unload: stop the engine (frees the resident model's RAM) and,
  /// only on success, clear the app-side resident state. If the stop is
  /// rejected the resident model stays put so the indicator does not lie
  /// about freed memory. Moved here with the indicator.
  private func unloadModel() {
    Task { @MainActor in
      do {
        try await engineStatusStore.stopEngine()
        modelLoadCenter.markUnloaded()
      } catch {
        persistenceStatus.report(error, context: "ChatScaffoldView.unloadModel")
      }
    }
  }

  private func scaffold(for chat: Chat) -> some View {
    VStack(spacing: 0) {
      ContentToolbar(
        viewModel: viewModel,
        availableProfiles: availableProfiles,
        // Reflect the models the engine ACTUALLY serves (from
        // `/v1/models`) rather than the static placeholder list — pie
        // serves only its single registered model and rejects a
        // `/v1/models/load` for anything else with `model_not_found`, so
        // offering unavailable names guarantees a failed "Switch model"
        // ( follow-up). Falls back to the injected list only until
        // the first reconcile lands (previews/tests/first paint).
        availableModels: engineModels.resolved(fallback: availableModels),
        swapCoordinator: swapCoordinator,
        modelLoadCenter: modelLoadCenter,
        engineStatus: engineStatusStore,
        onUnload: unloadModel
      )
      Divider().opacity(0.0001) // structural breather; no visible line per §5
      TranscriptView(chat: chat)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      ComposerView(
        chat: chat,
        viewModel: viewModel,
        isSending: sendController.isInFlight,
        shouldAllowSend: { currentModelID() != nil },
        onSendBlocked: {
          noModelProfileDefault = profileStore.model(forProfileID: viewModel.selectedProfileID)
          showNoModelPrompt = true
        },
        onUserMessageSaved: { _ in sendAssistantTurn(for: chat) }
      )
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showNoModelPrompt) {
      NoModelLoadedPrompt(
        profileDefaultModel: noModelProfileDefault,
        onLoad: { model in
          swapCoordinator.loadDirect(modelID: model)
          showNoModelPrompt = false
        },
        onChooseAnother: { showNoModelPrompt = false },
        onCancel: { showNoModelPrompt = false }
      )
    }
    .onAppear {
      // Seed the toolbar from the persisted profile so the menu
      // label matches what the chat was created with.
      viewModel.selectedProfileID = chat.profileID
    }
    .onChange(of: viewModel.selectedProfileID) { _, new in
      // Mirror toolbar swaps back into the persistent chat — the
      // schema column exists explicitly so a profile switch
      // survives navigation + relaunch. Does NOT bump `updatedAt`
      // ( F2 / F10): `updatedAt` tracks message-activity
      // recency, not config edits — bumping it on a profile swap
      // would float the chat ahead of more-recently-talked chats in
      // the sidebar. Save explicitly so a quick relaunch lands the
      // new profile durably.
      guard chat.profileID != new else { return }
      let previous = chat.profileID
      chat.profileID = new
      do {
        try modelContext.save()
      } catch {
        chat.profileID = previous
        // Also revert the toolbar selection so the menu label
        // stops lying about the persisted state ( F20). Guard
        // by inequality so this assignment does not re-enter the
        // `.onChange` handler and trigger an infinite swap loop.
        if viewModel.selectedProfileID != previous {
          viewModel.selectedProfileID = previous
        }
        persistenceStatus.report(error, context: "ChatScaffoldView.profileSwap")
      }
    }
    .onDisappear {
      sendController.cancel()
    }
    // Reflect a model the engine already has resident (e.g. the Helper
    // auto-resumed the active profile at boot) so the composer doesn't
    // block every send behind the no-model prompt despite a ready engine
    // ( follow-up). Re-runs whenever the engine status flips.
    .task(id: engineStatusStore.status) {
      await reconcileEngineResidentModel()
    }
  }

  /// When the engine is running, sync `residentModelID` to the id the
  /// engine actually serves (`GET /v1/models`) — the only id its chat
  /// endpoint accepts. No-op when the engine isn't running or a load is
  /// already in flight.
  private func reconcileEngineResidentModel() async {
    // Bounded retry while the engine stays running — a single transient
    // /v1/models failure must not strand residentModelID unset until a
    // status flip that may never come on equal .running polls (F2).
    let result = await EngineModelReconciler.reconcile(
      isRunning: {
        if case .running = engineStatusStore.status { return true }
        return false
      },
      fetchModelIDs: { try await engineStore.client.models().map(\.id) }
    )
    // Fold into the toolbar state. `.empty`/`.notRunning` become
    // `.known([])` (no placeholders for a verified empty/dead engine);
    // `.failedAfterRetries` keeps any prior known list. Placeholders show
    // only before the first fetch (F2).
    engineModels = ToolbarModelList.from(result, previous: engineModels)
    switch result {
    case .models(let ids):
      // reconcileEngineResident is internally guarded against clobbering
      // an in-flight load.
      modelLoadCenter.reconcileEngineResident(ids[0])
    case .failedAfterRetries(let attempts):
      // Don't silently drop: engine running but unreachable for models.
      NSLog("ChatScaffold: /v1/models reconcile failed after \(attempts) attempts while engine .running")
    case .empty, .notRunning:
      break
    }
  }

  private func sendAssistantTurn(for chat: Chat) {
    // Defensive: ComposerView only invokes this after `shouldAllowSend`
    // passed, but never ask the engine to load a model the user did not
    // choose ( invariant).
    guard let modelID = currentModelID() else {
      noModelProfileDefault = profileStore.model(forProfileID: viewModel.selectedProfileID)
      showNoModelPrompt = true
      return
    }
    sendController.send(
      chat: chat,
      context: modelContext,
      engine: engineStore.client,
      modelLoadCenter: modelLoadCenter,
      persistenceStatus: persistenceStatus,
      options: ChatSendRequestOptions(
        modelID: modelID,
        sampling: viewModel.sampling,
        systemPromptOverride: viewModel.systemPromptOverride
      ),
      // `EngineStatusStore` conforms to `ChatRecoveryGate`; passing it
      // here lets the send pipeline classify a mid-stream
      // `HTTPEngineError.engineGone` (or a transport throw racing the
      // helper's auto-relaunch) and ride the same chat turn through the
      // recovery without the user re-clicking Send.
      recoveryGate: engineStatusStore
    )
  }

  private func currentModelID() -> String? {
    Self.requestModelID(
      modelOverride: viewModel.modelOverride,
      residentModelID: modelLoadCenter.residentModelID,
      testModelID: ProcessInfo.processInfo.environment["PIE_TEST_CHAT_MODEL"]
    )
  }

  /// Resolve the model a send should target. : no hidden fallback —
  /// when the user has set no per-chat override and nothing is resident,
  /// this returns nil and the caller blocks the send behind the
  /// no-model confirm rather than asking the engine to load something
  /// the user never chose.
  static func requestModelID(
    modelOverride: String?,
    residentModelID: String?,
    testModelID: String? = nil
  ) -> String? {
    if let testModel = testModelID, !testModel.isEmpty {
      return testModel
    }
    if let modelOverride, !modelOverride.isEmpty {
      return modelOverride
    }
    if let residentModelID, !residentModelID.isEmpty {
      return residentModelID
    }
    return nil
  }
}
