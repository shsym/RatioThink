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
  /// Shown when a send is blocked because no model resolves yet. #326
  /// decides the model-availability action (Load / Download / unavailable
  /// via the live `noModelAction`); #397 layers the engine/model lifecycle
  /// framing on top (`chatStartState` → calm "starting / loading…" instead
  /// of the error-toned "No model loaded" while the engine is still coming
  /// up). Both axes are LIVE computed properties (no stored copy), so on
  /// any given render they derive from current state together — neither
  /// freezes a value the other has moved past (#400 intra-render parity;
  /// this is not filesystem-freshness — see `noModelAction`).
  @State private var showNoModelPrompt = false
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

  /// Raise the no-model prompt. The model-availability action and the
  /// lifecycle framing are both derived from current state on each render
  /// (`noModelAction` / `chatStartState`), so this only flips the
  /// presentation flag — there is no captured copy to freeze (#400).
  private func presentNoModelPrompt() {
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
    // Read-only existence check that runs on the render path (the live
    // `noModelAction` / the download CTA): resolve the models dir path
    // WITHOUT creating it or touching xattrs. The mutating `PieDirs
    // .models()` does `createDirectory` + `setResourceValues
    // (isExcludedFromBackup)` on every call, so calling it here would emit
    // main-thread filesystem WRITES on every render while the no-model
    // sheet is open. `modelsURL()` is pure path composition; the
    // download/staging writers still call the mutating `models()`.
    let path = LaunchSpecResolver.joinModelPath(modelsRoot: PieDirs.modelsURL(), slug: slug)
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
    let slug = selectedProfileDefault
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
        engineStatus: engineStatusStore,
        onUnload: unloadModel
      )
      Divider().opacity(0.0001) // structural breather; no visible line per §5
      // #326 Path 2: surface a swallowed failed(modelMissing) engine
      // state with an inline download + auto-start, instead of leaving
      // the user to discover it by failing a send.
      if let bannerTarget = MissingModelRecovery.bannerTarget(
        engineStatus: engineStatusStore.status,
        profileDefaultModel: selectedProfileDefault
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
        // #397: the lifecycle state gives the prompt its "starting /
        // loading…" framing while the engine/model comes up.
        gateState: chatStartState,
        // #326: the model-availability action (Load / Download /
        // unavailable) captured when the send was blocked.
        action: noModelAction,
        onLoad: { model in
          // #397: ensure the engine is running FIRST, then load — the
          // pre-#397 `loadDirect` no-opped on a stopped engine. The sheet
          // stays open, reflects busy→ready, and auto-dismisses below.
          loadDefaultModel(model)
        },
        onDownloaded: {
          // Model is now on disk — boot the engine on this chat's
          // profile so it loads (#326 auto-start). The status poll +
          // model-load indicator surface the rest; the composer
          // unblocks once the engine serves the model.
          startEngineForSelectedProfile()
          showNoModelPrompt = false
        },
        // #397 F1: retryable engine failure → re-start the engine.
        onRetryEngineStart: { startEngineForSelectedProfile() },
        // #397 F1: failed model load → re-run it via the ensure-engine
        // -then-load path (restarts the engine if it has since stopped).
        onRetryLoad: { model in loadDefaultModel(model) },
        // #397 F1: helper unreachable → force an immediate status re-poll.
        onRefresh: { refreshEngineStatus() },
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
    // #397: auto-dismiss the gate once a model resolves (engine came up
    // and reconciled, or a load completed) so the user lands back at the
    // composer with their draft intact — no stale "starting…" sheet.
    .onChange(of: modelLoadCenter.residentModelID) { _, _ in dismissPromptIfResolved() }
    .onChange(of: viewModel.modelOverride) { _, _ in dismissPromptIfResolved() }
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

  /// The active chat profile's default model slug — the ONE definition of
  /// the profile→default lookup, reused by every reader below (the
  /// lifecycle axis `chatStartState`, the availability axis
  /// `noModelAction`, the engine-failure message, and the inline
  /// missing-model banner). Centralizing it means the readers can't
  /// disagree because one copied the `selectedProfileID` key wrong, and
  /// the `profileStore` lookup is expressed once rather than four times.
  private var selectedProfileDefault: String? {
    profileStore.model(forProfileID: viewModel.selectedProfileID)
  }

  /// #397: the live engine/model lifecycle state driving the gate's
  /// "starting / loading…" framing. Folds engine status + helper
  /// reachability + model-load state + the active profile's default into
  /// one explicit state. The model-availability action (Load / Download /
  /// unavailable) stays #326's `MissingModelRecovery`; this only decides
  /// the lifecycle framing (chiefly: is the engine/model still busy?).
  private var chatStartState: ChatStartGate.State {
    ChatStartGate.evaluate(
      engineStatus: engineStatusStore.status,
      helperError: engineStatusStore.lastError,
      load: modelLoadCenter.state,
      resolvedModelID: currentModelID(),
      profileDefault: selectedProfileDefault,
      profileError: profileStore.lastActiveProfileError?.description
    )
  }

  /// #326 model-AVAILABILITY axis — the sibling of `chatStartState`'s
  /// lifecycle axis: Load when the profile's default model is staged on
  /// disk, Download when it isn't but resolves to a curated GGUF,
  /// unavailable otherwise. Computed (not stored): on each render it
  /// derives from current state alongside `chatStartState`, so the two
  /// axes are consistent within a render — neither freezes a value the
  /// other has moved past, which is the drift #400 removes. (This is
  /// intra-render parity, NOT filesystem-freshness: install-state is read
  /// by `isModelInstalled`, which is not a SwiftUI-observable input, so a
  /// model that lands on disk mid-sheet from another surface does not by
  /// itself re-render this prompt. The #326 download path re-renders via
  /// the shared `ModelDownloadController` and then dismisses on
  /// completion.) The decision itself stays #326's pure
  /// `MissingModelRecovery.promptAction`.
  private var noModelAction: MissingModelRecovery.PromptAction {
    Self.availabilityAction(profileDefault: selectedProfileDefault,
                            isModelInstalled: Self.isModelInstalled)
  }

  /// Pure availability derivation that `noModelAction` delegates to —
  /// extracted so it can be exercised across an install-state flip without
  /// a view host (and so no stored/memoized copy can hide here): it
  /// re-reads `isModelInstalled` on every call, which is what keeps the
  /// availability axis live per render. `isModelInstalled` is injected so a
  /// test can drive it; production passes `Self.isModelInstalled`.
  static func availabilityAction(profileDefault slug: String?,
                                 isModelInstalled: (String) -> Bool)
    -> MissingModelRecovery.PromptAction {
    MissingModelRecovery.promptAction(
      profileDefaultModel: slug,
      isInstalled: slug.map(isModelInstalled) ?? false)
  }

  /// "Load default" action. Honors the no-eager-load invariant — only
  /// runs because the user tapped Load. #397: ensures the engine is
  /// running FIRST (the App's only engine-start path), since a load
  /// against a stopped engine would otherwise just defer on
  /// `engineNotReady`. The sheet stays open and reflects busy→ready, then
  /// auto-dismisses via `dismissPromptIfResolved`.
  private func loadDefaultModel(_ model: String) {
    switch engineStatusStore.status {
    case .running:
      // Engine up — load the model directly (`/v1/models/load`).
      swapCoordinator.loadDirect(modelID: model)
    case .stopped:
      // Bring the engine up bound to this chat's profile; v1 pie loads
      // the profile's model at boot, and `reconcileEngineResidentModel`
      // picks it up once `.running`.
      startEngineForSelectedProfile()
    case let .failed(code, _):
      // #397 F3: only re-start for a retryable failure. memoryRisk /
      // killRejected re-fire a guaranteed-to-fail or refused start, so
      // do NOT — the prompt shows those as terminal (Open Settings /
      // reason), never an active Load/Retry that loops.
      if code.invitesResumeRetry { startEngineForSelectedProfile() }
    case .starting, .stopping:
      break  // already in flight — the busy state already reflects this
    }
  }

  /// #397 F1: re-poll the helper after an unreachable-transport failure.
  /// The 1 Hz loop would catch up anyway; this makes Retry immediate.
  private func refreshEngineStatus() {
    Task { @MainActor in
      _ = try? await engineStatusStore.refresh()
    }
  }

  /// #397: close the gate once a model resolves so the user lands back at
  /// the composer with their draft intact.
  private func dismissPromptIfResolved() {
    if showNoModelPrompt, currentModelID() != nil {
      showNoModelPrompt = false
    }
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
