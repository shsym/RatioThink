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
  /// #412: background-helper health, forwarded to the toolbar pip's outer ring.
  @EnvironmentObject private var helperHealth: HelperHealthController
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var downloadController: ModelDownloadController
  /// The reconciled engine-lifecycle fold, forwarded to the toolbar pip +
  /// popover so they derive the resident/offline distinction from the single
  /// published `indicator`.
  @EnvironmentObject private var engineLifecycle: EngineLifecycle
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
  @State private var toolbarDiscoveredModels: [InstalledModel] = []
  @State private var didScanToolbarModels = false
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

  /// #4: closes after the engine status FIRST settles this launch, so the
  /// launch prompt is evaluated exactly once and a later mid-session stop
  /// never re-pops it. Process-scoped (static) — resets every launch, so
  /// the app ALWAYS asks once per launch.
  @MainActor private static var didEvaluateLaunchStartPrompt = false

  /// #4: the engine no longer auto-starts on boot (see
  /// `HelperMain.autoResumeEngineOnBoot`). Once the status settles, if the
  /// engine is idle with a default model, proactively raise the existing
  /// no-model prompt — whose Load action starts the engine — so the user
  /// explicitly confirms the start instead of it happening silently. The
  /// initial `.starting` placeholder is skipped so we evaluate the real
  /// post-launch state, not the "reachability unknown" default.
  private func maybePromptEngineStartOnLaunch() {
    guard !Self.didEvaluateLaunchStartPrompt else { return }
    if case .starting = engineStatusStore.status { return }
    Self.didEvaluateLaunchStartPrompt = true
    if LaunchEngineStartPrompt.shouldAsk(
        status: engineStatusStore.status,
        // #497: ask about the model the Load tap will BOOT (the chat's pin
        // when present), not the bare profile default the boot path may
        // ignore — the same target the gate sheet then names.
        target: Self.gateTarget(selectedModelID: chats.first?.modelID,
                                profileDefaultModel: selectedProfileDefault)) {
      showNoModelPrompt = true
    }
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
    // Honor an explicit per-chat model pick as the boot model (#459 repro 1).
    // v1 pie loads the model at `pie serve` boot from the profile, so a
    // selection that only lives in App state would never reach the engine — a
    // no-default profile would fail with `has no default model` despite the
    // user having chosen one. Thread the selection in the start call so the
    // helper boots it without depending on the profile default (race-free
    // against the helper's own profile store). A nil/blank selection falls
    // back to the profile default. #460: the selection is `Chat.modelID` (the
    // single authority), read from this view's single chat.
    let modelOverride = chats.first?.modelID
    Task { @MainActor in
      do {
        engineActionError = nil
        try await engineStatusStore.startEngine(profileID: profileID, modelOverride: modelOverride)
      } catch {
        engineActionError = Self.engineErrorMessage(error, verb: "start")
      }
    }
  }

  /// Human, fault-domain-correct message for an engine start/stop error.
  /// #477: `EngineError.message` is a raw diagnostic — show the shared
  /// taxonomy's curated line instead and log the raw text here, so the
  /// in-chat banner never carries launcher/resolver internals.
  static func engineErrorMessage(_ error: Error, verb: String) -> String {
    if let e = error as? EngineError {
      let problem = EngineProblem(statusCode: e.code, rawMessage: e.message)
      if let detail = problem.technicalDetail {
        Log.engine.error("ChatScaffoldView: \(verb) engine failed: \(detail, privacy: .public)")
      }
      return "Couldn't \(verb) the engine. \(problem.message)"
    }
    Log.engine.error("ChatScaffoldView: \(verb) engine failed: \(String(describing: error), privacy: .public)")
    return "Couldn't \(verb) the engine."
  }

  /// Message for the in-chat engine-failure banner (PR#15 F2/F3), or nil
  /// when it should stay hidden. modelMissing is owned by the download
  /// banner; other `.failed` codes show the live status detail; a thrown
  /// action error shows when the status itself isn't `.failed`.
  private func engineFailureMessage(for chat: Chat) -> String? {
    // PR#15 v2 F1: only suppress modelMissing when the download banner
    // will actually own it (a single-file-GGUF slug). A non-downloadable
    // modelMissing has no download banner, so it must fall through to the
    // engine-failure banner rather than be menu-bar-dot-only. Keyed on the
    // same GATE model as the display banner — if the two axes disagree
    // (non-downloadable pick + downloadable default), both banners vanish
    // and modelMissing becomes menu-bar-dot-only.
    let slug = gateTarget(for: chat)?.modelID
    let hasDownloadTarget = MissingModelRecovery.bannerTarget(
      engineStatus: engineStatusStore.status,
      profileDefaultModel: slug) != nil
    return MissingModelRecovery.engineFailureBannerMessage(
      engineStatus: engineStatusStore.status,
      actionError: engineActionError,
      statusDetail: engineStatusStore.statusDetail,
      hasDownloadTarget: hasDownloadTarget)
  }

  /// Model ids offered by the toolbar switcher. Merges the engine's served
  /// ids with discovered app/HF-cache files so selectable rows include
  /// installed and cached models without falling back to stale placeholders.
  private var toolbarServedModelIDs: [String] {
    switch engineModels {
    case .unknown:
      // First paint/previews keep the injected list only until either the
      // engine reconcile or the filesystem scan has supplied real choices.
      return didScanToolbarModels ? [] : availableModels
    case .known(let ids):
      return ids
    }
  }

  /// #460: the chat's current model SELECTION drives the menu's "current"
  /// row + collapsed summary — `Chat.modelID` (the authority), NOT engine
  /// residency. Residency is not a selection source under the single
  /// authority, so it is NOT fed into `currentSummary`/`build`'s
  /// `residentModelID` (the served model still appears as a pickable row via
  /// `toolbarServedModelIDs`). `chats.first` is this view's single chat.
  private var toolbarCurrentModelSummary: ToolbarModelOptions.CurrentSummary? {
    ToolbarModelOptions.currentSummary(
      modelOverride: chats.first?.modelID,
      residentModelID: nil,
      profileDefaultModelID: selectedProfileDefault)
  }

  private var toolbarModelOptions: [ToolbarModelOptions.Option] {
    ToolbarModelOptions.build(
      discoveredModels: toolbarDiscoveredModels,
      servedModelIDs: toolbarServedModelIDs,
      profileDefaultModelID: selectedProfileDefault,
      modelOverride: chats.first?.modelID,
      residentModelID: nil)
  }

  private func scaffold(for chat: Chat) -> some View {
    VStack(spacing: 0) {
      ContentToolbar(
        viewModel: viewModel,
        availableProfiles: pickerProfileIDs,
        // #459's richer model menu (option list + collapsed summary), built
        // from `Chat.modelID` (the #460 authority).
        modelOptions: toolbarModelOptions,
        currentModelSummary: toolbarCurrentModelSummary,
        // #460: the chat's persisted selection authority + the active
        // profile's default. The commits write the SwiftData authority
        // (`Chat.modelID` / `Chat.profileID`); policy lives in the
        // coordinator, persistence here.
        selectedModelID: chat.modelID,
        profileDefaultModel: selectedProfileDefault,
        commitSwap: { profileID, pinModel in
          commitSwap(profileID: profileID, pinModel: pinModel, chat: chat)
        },
        commitModel: { modelID in persistChatModel(modelID, on: chat) },
        onUseProfileDefault: { _ = persistChatModel(nil, on: chat) },
        swapCoordinator: swapCoordinator,
        modelLoadCenter: modelLoadCenter,
        engineStatus: engineStatusStore,
        helperHealth: helperHealth,
        engineLifecycle: engineLifecycle,
        onUnload: unloadModel,
        onStartEngine: startEngineForSelectedProfile
      )
      Divider().opacity(0.0001) // structural breather; no visible line per §5
      // #326 Path 2: surface a swallowed failed(modelMissing) engine
      // state with an inline download + auto-start, instead of leaving
      // the user to discover it by failing a send.
      // #446: suppress the banner ONLY when the send-gate sheet is presented
      // AND is itself showing the same inline download (action `.download`),
      // so the user never sees two download prompts for one model. Review F1:
      // gate on the sheet's REAL download condition, not bare presentation —
      // in the present-but-invalid staged-model edge the sheet shows Open
      // Settings (action `.load`), which does NOT duplicate the banner, so the
      // banner (the only one-click download there) must stay visible.
      if let bannerTarget = MissingModelRecovery.bannerTarget(
        engineStatus: engineStatusStore.status,
        // Keyed on the GATE model (pick ?? default) like the suppression
        // axis below and the boot path — the banner must never offer a
        // download for a default the Load tap wouldn't boot.
        profileDefaultModel: gateTarget(for: chat)?.modelID,
        sendGatePresented: showNoModelPrompt && noModelAction(for: chat).isDownload
      ) {
        ModelMissingBanner(
          target: bannerTarget,
          onDownloaded: { startEngineForSelectedProfile() },
          engineStatus: engineStatusStore.status
        )
      } else if let message = engineFailureMessage(for: chat) {
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
        shouldAllowSend: { currentModelID(for: chat) != nil },
        onSendBlocked: { presentNoModelPrompt() },
        onUserMessageSaved: { _ in sendAssistantTurn(for: chat) }
      )
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showNoModelPrompt) {
      NoModelLoadedPrompt(
        // #397: the lifecycle state gives the prompt its "starting /
        // loading…" framing while the engine/model comes up.
        gateState: chatStartState(for: chat),
        // #326: the model-availability action (Load / Download /
        // unavailable) captured when the send was blocked.
        action: noModelAction(for: chat),
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
        // #397 F1: helper unreachable → force an immediate status re-poll.
        onRefresh: { refreshEngineStatus() },
        onCancel: { showNoModelPrompt = false },
        engineStatus: engineStatusStore.status
      )
    }
    .onChange(of: engineStatusStore.status) { _, new in
      // PR#15 F3: a thrown start/stop error is transient — once the poll
      // observes the engine in any non-failed state, drop it so a stale
      // action error can't outlive the condition it described.
      if case .failed = new {} else { engineActionError = nil }
      // #4: the engine no longer auto-starts on boot — once status settles
      // (.starting → .stopped), proactively ask to start the model.
      maybePromptEngineStartOnLaunch()
    }
    // #397: auto-dismiss the gate once a model resolves (engine came up
    // and reconciled, or a load completed) so the user lands back at the
    // composer with their draft intact — no stale "starting…" sheet.
    .onChange(of: modelLoadCenter.residentModelID) { _, _ in dismissPromptIfResolved(for: chat) }
    .onChange(of: chat.modelID) { _, _ in dismissPromptIfResolved(for: chat) }
    // #413: open/close the helper-health generation gate around every stream.
    // While a chat / ToT generation is in flight a saturated engineStatus poll
    // path can time out for many consecutive polls; without this gate the
    // restart ladder reads those busy-timeouts as an unreachable helper and
    // bounces it — killing the engine mid-search and closing the SSE. The gate
    // holds those failed polls; genuine death still surfaces (the stream drops,
    // ending the generation and releasing the gate).
    .onChange(of: sendController.isInFlight) { _, inFlight in
      helperHealth.setGenerating(inFlight)
    }
    .onAppear {
      // Seed the toolbar from the persisted profile so the menu
      // label matches what the chat was created with.
      viewModel.selectedProfileID = chat.profileID
      // #4: covers the case where the engine status already settled before
      // this view appeared (no .onChange fires) — evaluate the launch ask
      // here too; the once-flag keeps it from double-prompting.
      maybePromptEngineStartOnLaunch()
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
        // #3: a profile swap chooses which profile is active. The menu-bar
        // (menu-icon) engine start reads the GLOBAL active-profile marker
        // (HelperResumeAction → ProfileStore.activeProfileID), NOT this
        // per-chat selection — so persist the swap to the marker too.
        // Otherwise a swap while the engine is stopped leaves the marker on
        // the old profile and a later menu-icon start launches the OLD
        // model. Stage-only: this updates the start TARGET, it does not
        // auto-start the engine. `setActiveProfileID` logs internally on a
        // write failure (the marker simply stays on the prior profile), so
        // the `try?` does not silently drop the signal.
        try? profileStore.setActiveProfileID(new)
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
    .task(id: downloadController.completionTick) {
      await refreshToolbarModelOptions()
    }
    // Reflect a model the engine already has resident (e.g. after the launch
    // prompt/user-confirm path, explicit Restart, Local API start,
    // post-download startEngine, or crash auto-relaunch) so the composer
    // doesn't block every send behind the no-model prompt despite a ready
    // engine ( follow-up). Re-runs whenever the engine status flips.
    .task(id: engineStatusStore.status) {
      await reconcileEngineResidentModel(for: chat)
    }
  }

  @MainActor
  private func refreshToolbarModelOptions() async {
    let scan = await CachedModelScan.run()
    toolbarDiscoveredModels = scan.appManaged + scan.huggingFaceCache
    didScanToolbarModels = true
    if let appError = scan.appError {
      NSLog("ChatScaffold: model picker scan warning: \(appError)")
    }
  }

  /// When the engine is running, sync `residentModelID` to the id the
  /// engine actually serves (`GET /v1/models`) — the only id its chat
  /// endpoint accepts. No-op when the engine isn't running or a load is
  /// already in flight.
  private func reconcileEngineResidentModel(for chat: Chat) async {
    // Bounded retry while the engine stays running — a single transient
    // /v1/models failure must not strand residentModelID unset until a
    // status flip that may never come on equal .running polls (F2).
    // #474: capture the engine's effective max_tokens ceiling alongside the
    // resident-model fetch. The reconciler is generic over ids; the ceiling
    // rides the same `GET /v1/models` response (`ModelInfo.maxOutputTokens`,
    // engine-global so the first entry's value is authoritative), stashed
    // here on the successful fetch and applied below with residency.
    var fetchedCeiling: Int?
    let result = await EngineModelReconciler.reconcile(
      isRunning: {
        if case .running = engineStatusStore.status { return true }
        return false
      },
      fetchModelIDs: {
        let infos = try await engineStore.client.models()
        fetchedCeiling = infos.first?.maxOutputTokens
        return infos.map(\.id)
      }
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
      // #460 (review F1): seed the chat's SELECTION authority (`Chat.modelID`)
      // from the served model ONLY when it matches THIS chat's profile
      // default — never the engine's single GLOBAL resident model when it
      // differs. The engine serves one global model; `ids[0]` is that, not
      // necessarily this chat's selection, and navigating between chats does
      // NOT reload the engine to the new chat's profile (the active-profile
      // write is stage-only). Adopting `ids[0]` unconditionally would durably
      // pin an unpinned chat to the wrong model. When the served model is not
      // this chat's default, leave `modelID` nil (follow the profile default).
      // `seededModelID` is the pure decision; seed-only (never overwrites a
      // pick) and no-op while a load is in flight.
      if let toPin = Self.seededModelID(
        currentPin: chat.modelID,
        servedID: ids[0],
        profileDefault: selectedProfileDefault,
        // #469: the residency-only ModelLoadCenter has no in-flight-load state
        // (`/v1/models/load` is gone; the served model is bound at engine boot).
        // This block runs on a successful `/v1/models` reconcile — the engine is
        // serving, never mid-load — so the seed guard is never "in flight" here.
        isLoading: false
      ) {
        _ = persistChatModel(toPin, on: chat)
      }
      // #474: apply the launched ceiling unconditionally (a guardrail change
      // or reload can hand the same model a different ceiling). The setter
      // no-ops on an unchanged value and while a load is in flight. Orthogonal
      // to the #460 selection seed above — model identity vs token ceiling.
      modelLoadCenter.setResidentMaxOutputTokens(fetchedCeiling)
    case .failedAfterRetries(let attempts):
      // Don't silently drop: engine running but unreachable for models.
      NSLog("ChatScaffold: /v1/models reconcile failed after \(attempts) attempts while engine .running")
    case .empty:
      // Engine running but serving NO model — clear any stale residency so
      // the send gate doesn't pass a model the engine no longer has (the
      // sibling gap to the leave-`.running` invalidation). No-op while a load
      // is in flight.
      modelLoadCenter.engineServesNoModel()
    case .notRunning:
      // Engine isn't running — `EngineLifecycle` already invalidated residency
      // on the leave-`.running` edge; nothing to do here.
      break
    }
  }

  private func sendAssistantTurn(for chat: Chat) {
    // Defensive: ComposerView only invokes this after `shouldAllowSend`
    // passed, but never ask the engine to load a model the user did not
    // choose ( invariant).
    guard let modelID = currentModelID(for: chat) else {
      presentNoModelPrompt()
      return
    }
    let options = ChatSendRequestOptions(
      modelID: modelID,
      sampling: viewModel.sampling,
      systemPromptOverride: viewModel.systemPromptOverride,
      // #426: thread the selected profile's Fast Think (speculative-decoding)
      // settings into the request — a Fast Think profile attaches speculation
      // + forces greedy; a normal or tree-of-thought profile carries none.
      // Built once here so both the ToT dispatch and the normal send get it.
      speculation: profileStore.speculation(forProfileID: viewModel.selectedProfileID),
      // #474: the launched engine's effective max_tokens ceiling, learned
      // from GET /v1/models during resident-model reconcile. `makeRequest`
      // clamps the profile's max_tokens down to this so a memory-squeezed
      // launch never trips the engine's clean 400.
      maxOutputTokensCeiling: modelLoadCenter.residentMaxOutputTokens
    )

    // #413: when the active profile declares `mode = "tree-of-thought"`,
    // route the turn to the ToT dispatch (streamed tree search rendered
    // inline) instead of a chat completion. The launched inferlet is
    // still chat-apc — ToT is a per-request dispatch mode.
    if let totConfig = profileStore.profile(forProfileID: viewModel.selectedProfileID)?.treeOfThought {
      sendController.sendTreeOfThought(
        chat: chat,
        context: modelContext,
        engine: engineStore.client,
        config: totConfig,
        persistenceStatus: persistenceStatus,
        options: options
      )
      return
    }

    sendController.send(
      chat: chat,
      context: modelContext,
      engine: engineStore.client,
      modelLoadCenter: modelLoadCenter,
      persistenceStatus: persistenceStatus,
      // Reuses the `options` built above (now carrying #426 speculation), so
      // the normal send and the ToT dispatch share one options value.
      options: options,
      // `EngineStatusStore` conforms to `ChatRecoveryGate`; passing it
      // here lets the send pipeline classify a mid-stream
      // `HTTPEngineError.engineGone` (or a transport throw racing the
      // helper's auto-relaunch) and ride the same chat turn through the
      // recovery without the user re-clicking Send.
      recoveryGate: engineStatusStore
    )
  }

  /// #460: resolve the model a send should target from the SINGLE selection
  /// authority — the chat's pinned `modelID`, or the active profile's
  /// default when unpinned. The engine must actually be `.running` for the
  /// selection to count (a stopped engine yields a "Load X?" prompt rather
  /// than a send that passes the gate then fails at HTTP); `EngineLifecycle`
  /// clears residency on the leave-`.running` edge and `reconcileEngine
  /// ResidentModel` re-seeds `chat.modelID` to the served id once running,
  /// so by send time the authority matches what the engine serves. The
  /// test override (`PIE_TEST_CHAT_MODEL`) bypasses the running gate for the
  /// GUI harness. No `residentModelID` read here — residency is an engine
  /// fact reconciled INTO the authority, not a parallel selection source.
  private func currentModelID(for chat: Chat) -> String? {
    let engineRunning: Bool = {
      if case .running = engineStatusStore.status { return true }
      return false
    }()
    return Self.requestModelID(
      selectedModelID: engineRunning ? chat.modelID : nil,
      profileDefaultModel: engineRunning ? selectedProfileDefault : nil,
      testModelID: ProcessInfo.processInfo.environment["PIE_TEST_CHAT_MODEL"]
    )
  }

  /// #460: durably set (or clear) the chat's selected model — the single
  /// selection authority. `nil` clears the pin so the chat follows the
  /// active profile's default again. Does NOT bump `updatedAt` (a config
  /// edit, like a profile swap — it must not float the chat ahead of
  /// more-recently-talked chats in the recency-sorted sidebar). Returns
  /// `true` when the value is durably set (including the no-op case);
  /// `false` when the save failed. Review F2: on failure use
  /// `modelContext.rollback()` (like `ChatListView.delete`) so ALL pending
  /// edits are discarded rather than only field-restoring `modelID` and
  /// leaving a second pending write to flush later.
  @discardableResult
  private func persistChatModel(_ modelID: String?, on chat: Chat) -> Bool {
    guard chat.modelID != modelID else { return true }
    chat.modelID = modelID
    do {
      try modelContext.save()
      return true
    } catch {
      modelContext.rollback()
      persistenceStatus.report(error, context: "ChatScaffoldView.modelSelect")
      return false
    }
  }

  /// #460: persist a profile swap on this chat. The model pin is written
  /// FIRST and the profile is switched ONLY if it succeeded (review F2 —
  /// a failed pin must not leave the chat with a switched profile + a
  /// loaded new model while `modelID` reverts). Returns `false` on a pin
  /// failure so `ProfileSwapCoordinator.confirm` skips the load; the swap is
  /// then fully aborted (profile unchanged, no load). A silent / no-default
  /// swap passes `pinModel == nil` so the chat's current model is PRESERVED.
  /// The profile change routes through `viewModel.selectedProfileID`, whose
  /// `.onChange` owns the durable profile write (+ active-profile marker +
  /// rollback). The preserve-vs-switch policy was already decided in
  /// `ProfileSwapCoordinator`; this only performs the persistence.
  private func commitSwap(profileID: String, pinModel: String?, chat: Chat) -> Bool {
    if let pinModel, !persistChatModel(pinModel, on: chat) {
      return false  // pin save failed → do NOT switch the profile or load
    }
    viewModel.selectedProfileID = profileID
    return true
  }

  /// #460 (review F1): pure decision for the residency seed. Adopt the
  /// served model as this chat's pin ONLY when the chat is unpinned, not
  /// loading, and the served model is exactly this chat's profile default —
  /// so the seed never durably pins an unpinned chat to the engine's GLOBAL
  /// resident model when that differs from the chat's own default. Returns
  /// the id to pin, or `nil` to leave `modelID` untouched (follow the
  /// profile default). Static + pure so the matrix is unit-testable without
  /// a view host.
  static func seededModelID(
    currentPin: String?,
    servedID: String?,
    profileDefault: String?,
    isLoading: Bool
  ) -> String? {
    guard !isLoading else { return nil }          // load in flight → no-op
    guard currentPin == nil else { return nil }   // already pinned → never overwrite
    guard let servedID, !servedID.isEmpty else { return nil }
    guard servedID == profileDefault else { return nil }  // served != this chat's default → don't seed
    return servedID
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

  /// Profile ids the toolbar picker offers — the SAME set the Settings
  /// editor lists (every valid `*.toml`), derived live from the store so a
  /// user can actually switch to a non-`chat` profile (e.g. the seeded
  /// `tree-of-thought` or a `fast-think`). The previous default `["chat"]`
  /// was never wired to `ProfileStore`, so the picker only ever showed
  /// `chat`. Re-read each render: `ProfileStore` publishes nothing, but
  /// this view re-renders on the ~1 Hz engine-status publishes, so a newly
  /// seeded/edited profile appears without an app restart. Falls back to
  /// the injected `availableProfiles` (previews/tests) when the store has
  /// no valid entries yet. The selected id is kept present so the picker
  /// always offers the active profile even mid-scan.
  private var pickerProfileIDs: [String] {
    var ids = profileStore.entries.compactMap { $0.profile?.id }
    if ids.isEmpty { ids = availableProfiles }
    if !ids.contains(viewModel.selectedProfileID) {
      ids.append(viewModel.selectedProfileID)
    }
    return ids.sorted()
  }

  /// #397: the live engine/model lifecycle state driving the gate's
  /// "starting / loading…" framing. Folds engine status + helper
  /// reachability + model-load state + the active profile's default into
  /// one explicit state. The model-availability action (Load / Download /
  /// unavailable) stays #326's `MissingModelRecovery`; this only decides
  /// the lifecycle framing (chiefly: is the engine/model still busy?).
  private func chatStartState(for chat: Chat) -> ChatStartGate.State {
    ChatStartGate.evaluate(
      engineStatus: engineStatusStore.status,
      helperError: engineStatusStore.lastError,
      // #460: the chat's model is per-chat now (`currentModelID(for:)`); #469:
      // `ChatStartGate.evaluate` no longer takes a `load:` state — the load
      // state machine is gone (ModelLoadCenter is residency-only).
      resolvedModelID: currentModelID(for: chat),
      // The gate names the model the Load tap will BOOT — the chat's pick
      // when present, not the profile default the boot path would ignore
      // (#459 repro 1 vs #460's engine-running nil). #497: the full
      // `ModelTarget` (id + source) so the prompt frames a pin honestly.
      target: gateTarget(for: chat),
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
  private func noModelAction(for chat: Chat) -> MissingModelRecovery.PromptAction {
    Self.availabilityAction(gateModel: gateTarget(for: chat)?.modelID,
                            isModelInstalled: Self.isModelInstalled)
  }

  /// Pure availability derivation that `noModelAction` delegates to —
  /// extracted so it can be exercised across an install-state flip without
  /// a view host (and so no stored/memoized copy can hide here): it
  /// re-reads `isModelInstalled` on every call, which is what keeps the
  /// availability axis live per render. `isModelInstalled` is injected so a
  /// test can drive it; production passes `Self.isModelInstalled`. Keys on
  /// the GATE model (chat pick ?? profile default, `gateTarget`) so the
  /// install check probes the model the Load/Download will actually use.
  static func availabilityAction(gateModel slug: String?,
                                 isModelInstalled: (String) -> Bool)
    -> MissingModelRecovery.PromptAction {
    MissingModelRecovery.promptAction(
      profileDefaultModel: slug,
      isInstalled: slug.map(isModelInstalled) ?? false)
  }

  /// The model identity the send GATE describes — mirrors the boot path's
  /// precedence (`startEngineForSelectedProfile` boots
  /// `chats.first?.modelID`, falling back to the profile default), so the
  /// prompt's chip, download CTA, Load action, missing-model banner, and
  /// launch ask all name the model the tap will actually boot (#459 repro
  /// 1). #497: returns the full `ModelTarget` (id + provenance) so copy
  /// can frame a pinned selection honestly. Distinct from
  /// `currentModelID(for:)`, which deliberately nils the pick while the
  /// engine isn't `.running` (#460 send-resolution semantics) and so can't
  /// feed the gate's model-identity axis. Pure + static for SPM-free
  /// unit-testing of the precedence.
  static func gateTarget(selectedModelID: String?,
                         profileDefaultModel: String?) -> ModelTarget? {
    ModelTarget.resolve(selectedModelID: selectedModelID,
                        profileDefault: profileDefaultModel)
  }

  private func gateTarget(for chat: Chat) -> ModelTarget? {
    Self.gateTarget(selectedModelID: chat.modelID,
                    profileDefaultModel: selectedProfileDefault)
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
      // Engine up — make it serve this model. #469: a model that differs from
      // the resident one rebuilds the engine onto it (a live `/v1/models/load`
      // can't swap the boot model); the already-resident case short-circuits.
      swapCoordinator.loadDirect(modelID: model, profileID: viewModel.selectedProfileID)
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
  private func dismissPromptIfResolved(for chat: Chat) {
    if showNoModelPrompt, currentModelID(for: chat) != nil {
      showNoModelPrompt = false
    }
  }

  /// Resolve the model a send should target from the chat's SELECTION
  /// authority (#460): the explicit pin (`selectedModelID` = `Chat.modelID`),
  /// else the active profile's default, else nil. : no hidden fallback —
  /// when nothing resolves the caller blocks the send behind the no-model
  /// confirm rather than asking the engine to load something the user never
  /// chose. The test override wins for the GUI harness. Pure + static so the
  /// precedence is unit-tested without a view.
  static func requestModelID(
    selectedModelID: String?,
    profileDefaultModel: String?,
    testModelID: String? = nil
  ) -> String? {
    if let testModel = testModelID, !testModel.isEmpty {
      return testModel
    }
    if let selectedModelID, !selectedModelID.isEmpty {
      return selectedModelID
    }
    if let profileDefaultModel, !profileDefaultModel.isEmpty {
      return profileDefaultModel
    }
    return nil
  }
}
