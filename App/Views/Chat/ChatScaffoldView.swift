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
  /// The recovery action for the no-model prompt, captured at the
  /// instant the send is blocked (when `selectedProfileID` is settled
  /// and the store is loaded) rather than at sheet-build time. #326:
  /// Load when the default model is on disk, Download when it isn't,
  /// unavailable otherwise.
  @State private var noModelAction: MissingModelRecovery.PromptAction = .unavailable
  /// What the toolbar model menu should offer. `.unknown` (→ injected
  /// `availableModels`) only until the first reconcile; afterwards it is
  /// the engine's real served list (`.known`, possibly empty), so a
  /// verified empty/not-running/unreachable engine never re-surfaces
  /// placeholder models the engine would reject ( F2).
  @State private var engineModels: ToolbarModelList = .unknown
  /// PR#15 F2/F3: a thrown engine start/stop error (transport failure, a
  /// stop that left the engine running) that the status poll won't
  /// reflect. Surfaced via the in-chat engine-failure banner — NOT the
  /// persistence "Couldn't save" banner. Cleared when the engine status
  /// changes to a non-failed state.
  @State private var engineActionError: String?

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
        engineActionError = nil
        try await engineStatusStore.stopEngine()
        modelLoadCenter.markUnloaded()
      } catch {
        // PR#15 F3: an engine STOP failure is an engine fault, not a
        // persistence/durability failure — route it to the engine-failure
        // banner, never the "Couldn't save" persistence banner.
        engineActionError = Self.engineErrorMessage(error, verb: "stop")
      }
    }
  }

  /// Decide and raise the no-model prompt for the chat's selected
  /// profile. The Load-vs-Download choice turns on whether the profile's
  /// default model is staged on disk (#326).
  private func presentNoModelPrompt() {
    let slug = profileStore.model(forProfileID: viewModel.selectedProfileID)
    noModelAction = MissingModelRecovery.promptAction(
      profileDefaultModel: slug,
      isInstalled: slug.map(Self.isModelInstalled) ?? false)
    showNoModelPrompt = true
  }

  /// True when the slug's app-staged model file exists — the engine's
  /// primary model source. A miss means the prompt offers Download
  /// instead of Load.
  ///
  /// Intentionally checks ONLY the app-staged path, not the HF cache
  /// (the resolver's secondary fallback). A model present only in
  /// `~/.cache/huggingface` is offered a Download here, which simply
  /// stages a second copy into the app models dir before it resolves —
  /// benign redundancy, not a wrong result. Mirroring the resolver's
  /// two-stage check would couple this UI gate to resolver internals.
  static func isModelInstalled(_ slug: String) -> Bool {
    let modelsRoot: URL
    do {
      modelsRoot = try PieDirs.models()
    } catch {
      // PR#15 F4: don't silently swallow a transient FS/permissions
      // failure — log it. The fall-through to Download is self-recovering
      // (a visible affordance remains; re-download re-stages the file),
      // but the cause must be greppable, not lost to `try?`.
      NSLog("ChatScaffold.isModelInstalled: PieDirs.models() failed (\(error)); treating model as not-installed")
      return false
    }
    let path = LaunchSpecResolver.joinModelPath(modelsRoot: modelsRoot, slug: slug)
    return FileManager.default.fileExists(atPath: path)
  }

  /// Kick the helper to (re)start the engine on this chat's profile —
  /// fire-and-forget; the engine-status poll surfaces the outcome. A
  /// resolver-level failure publishes `.failed` (surfaced by the in-chat
  /// failure banner); a thrown transport error routes to
  /// `engineActionError` (PR#15 F3) — never the persistence banner.
  private func startEngineForSelectedProfile() {
    let profileID = viewModel.selectedProfileID
    Task { @MainActor in
      do {
        engineActionError = nil
        try await engineStatusStore.startEngine(profileID: profileID)
      } catch {
        engineActionError = Self.engineErrorMessage(error, verb: "start")
      }
    }
  }

  /// Human, fault-domain-correct message for an engine start/stop error.
  static func engineErrorMessage(_ error: Error, verb: String) -> String {
    if let e = error as? EngineError {
      return "Couldn't \(verb) the engine: \(e.message)"
    }
    return "Couldn't \(verb) the engine: \(error)"
  }

  /// Message for the in-chat engine-failure banner (PR#15 F2/F3), or nil
  /// when it should stay hidden. modelMissing is owned by the download
  /// banner; other `.failed` codes show the live status detail; a thrown
  /// action error shows when the status itself isn't `.failed`.
  private var engineFailureMessage: String? {
    // PR#15 v2 F1: only suppress modelMissing when the download banner
    // will actually own it (a single-file-GGUF slug). A non-downloadable
    // modelMissing has no download banner, so it must fall through to the
    // engine-failure banner rather than be menu-bar-dot-only.
    let slug = profileStore.model(forProfileID: viewModel.selectedProfileID)
    let hasDownloadTarget = MissingModelRecovery.bannerTarget(
      engineStatus: engineStatusStore.status,
      profileDefaultModel: slug) != nil
    return MissingModelRecovery.engineFailureBannerMessage(
      engineStatus: engineStatusStore.status,
      actionError: engineActionError,
      statusDetail: engineStatusStore.statusDetail,
      hasDownloadTarget: hasDownloadTarget)
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
        onUnload: unloadModel
      )
      Divider().opacity(0.0001) // structural breather; no visible line per §5
      // #326 Path 2: surface a swallowed failed(modelMissing) engine
      // state with an inline download + auto-start, instead of leaving
      // the user to discover it by failing a send.
      if let bannerTarget = MissingModelRecovery.bannerTarget(
        engineStatus: engineStatusStore.status,
        profileDefaultModel: profileStore.model(forProfileID: viewModel.selectedProfileID)
      ) {
        ModelMissingBanner(
          target: bannerTarget,
          onDownloaded: { startEngineForSelectedProfile() },
          engineStatus: engineStatusStore.status
        )
      } else if let message = engineFailureMessage {
        // PR#15 F2/F3: surface a non-modelMissing engine failure (or a
        // thrown start/stop error) in-chat — the user just acted; it must
        // not be menu-bar-dot-only or hidden under "Couldn't save". v2 F2:
        // only offer Dismiss for a dismissable (thrown action-error)
        // message; a live `.failed` status self-clears on recovery, so its
        // Dismiss would be a no-op and is hidden.
        EngineFailureBanner(
          message: message,
          onDismiss: MissingModelRecovery.engineFailureDismissable(
            engineStatus: engineStatusStore.status) ? { engineActionError = nil } : nil)
      }
      TranscriptView(chat: chat)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      ComposerView(
        chat: chat,
        viewModel: viewModel,
        isSending: sendController.isInFlight,
        shouldAllowSend: { currentModelID() != nil },
        onSendBlocked: { presentNoModelPrompt() },
        onUserMessageSaved: { _ in sendAssistantTurn(for: chat) }
      )
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showNoModelPrompt) {
      NoModelLoadedPrompt(
        action: noModelAction,
        onLoad: { model in
          swapCoordinator.loadDirect(modelID: model)
          showNoModelPrompt = false
        },
        onDownloaded: {
          // Model is now on disk — boot the engine on this chat's
          // profile so it loads (#326 auto-start). The status poll +
          // model-load indicator surface the rest; the composer
          // unblocks once the engine serves the model.
          startEngineForSelectedProfile()
          showNoModelPrompt = false
        },
        onChooseAnother: { showNoModelPrompt = false },
        onCancel: { showNoModelPrompt = false },
        engineStatus: engineStatusStore.status
      )
    }
    .onChange(of: engineStatusStore.status) { _, new in
      // PR#15 F3: a thrown start/stop error is transient — once the poll
      // observes the engine in any non-failed state, drop it so a stale
      // action error can't outlive the condition it described.
      if case .failed = new {} else { engineActionError = nil }
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
      presentNoModelPrompt()
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
      )
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
