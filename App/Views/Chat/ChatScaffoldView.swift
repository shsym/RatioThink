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
  /// #507: send pipelines are app-scoped (one controller per chat, owned by
  /// the coordinator) so an in-flight stream survives this view's teardown
  /// when the user switches chats. This view only borrows its chat's
  /// controller; it never cancels on disappear.
  @EnvironmentObject private var sendCoordinator: ChatSendCoordinator
  private let chatID: UUID
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
  @EnvironmentObject private var appPreferences: AppPreferences
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
  // #580 #5: the unverified shield in the chat menu flows through
  // `toolbarDiscoveredModels` → `ToolbarModelOptions.build` (which carries
  // each model's `isUnverified`), so no separate unverified-slug plumbing is
  // needed here.
  @State private var toolbarDiscoveredModels: [InstalledModel] = []
  @State private var didScanToolbarModels = false
  /// PR#15 F2/F3: a thrown engine start/stop error (transport failure, a
  /// stop that left the engine running) that the status poll won't
  /// reflect. Surfaced via the in-chat engine-failure banner — NOT the
  /// persistence "Couldn't save" banner. Cleared when the engine status
  /// changes to a non-failed state.
  @State private var engineActionError: String?
  /// #496: an engine action (Load / start / Unload) refused because the
  /// background Helper isn't healthy. Surfaced as an inline, helper-framed
  /// `HelperUnavailableNotice` — never the engine-failure banner, which would
  /// re-attribute a Helper state to the engine.
  @State private var helperBlock: HelperUnavailable?
  /// #516: the send the gate is holding plus its fire signal. Armed when a
  /// send is blocked (with the blocked draft + the gate's load target),
  /// settled on every model-resolution edge (fired exactly once through the
  /// composer's normal submit path), and disarmed on cancel, manual send,
  /// profile switch, navigation away, or a stale resolution. The
  /// transitions live in `PendingSendState` so they are unit-tested.
  @State private var pendingSend = PendingSendState()
  /// A blocked send may need to restart the single engine onto a different
  /// model, but doing that while another chat is streaming would interrupt
  /// that stream. Defer the automatic sync until the app-wide stream set is
  /// idle; explicit user actions (Stop / Load) remain separate choices.
  @State private var deferredEngineSyncTask: Task<Void, Never>?
  @State private var deferredEngineMutation: DeferredEngineMutation?
  @State private var deferredEngineMutationGeneration: Int = 0

  /// #527: when an explicit per-chat model pin differs from the engine's
  /// known resident model, a send would deterministically fail with
  /// model_not_found. Block before persisting the user message and ask which
  /// model identity should win.
  @State private var pinnedModelMismatch: PinnedModelMismatch?

  struct PinnedModelMismatch: Equatable, Identifiable {
    let pinnedModelID: String
    let residentModelID: String

    var id: String { pinnedModelID + "\u{1f}" + residentModelID }
  }

  enum SendGateDecision: Equatable {
    case ready(modelID: String)
    case noResolvableModel
    case pinnedModelMismatch(pinnedModelID: String, residentModelID: String)

    var allowsSend: Bool {
      if case .ready = self { return true }
      return false
    }
  }
  /// #513: the assistant message id awaiting the destructive-retry
  /// confirmation. Non-nil presents the alert; Cancel clears it without
  /// touching history.
  @State private var pendingRetryMessageID: UUID?
  /// #513 review v2 F1: the stale-retry notice, on its OWN channel — it
  /// must NOT ride `engineActionError`, whose banner hides action errors
  /// behind `statusDetail` while the engine is `.failed` and whose value
  /// is cleared on the next engine-status flip. This is a transcript
  /// condition; its visibility and lifetime are independent of engine
  /// state (explicit Dismiss, or the auto-clear on the rendered row).
  ///
  /// Identity-bearing (review v3 F1): the message is a single static
  /// string, so a bare `String?` state makes every re-raise a same-value
  /// write — `.task(id:)` would never restart and a second stale click
  /// near the end of the window would get almost no banner time. Each
  /// raise mints a fresh `id`, so the auto-clear timer restarts per raise
  /// by construction.
  struct RetryNoticeState: Equatable {
    let id: UUID
    let message: String

    init(message: String) {
      self.id = UUID()
      self.message = message
    }
  }

  @State private var staleRetryNotice: RetryNoticeState?

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
    self.chatID = id
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
        helperBlock = nil
        try await engineStatusStore.stopEngine()
        modelLoadCenter.markUnloaded()
      } catch let block as HelperUnavailable {
        // #496: the Helper transport itself isn't healthy — surface a helper-
        // framed inline refusal, never the engine-failure banner.
        helperBlock = block
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
    if appPreferences.localAPIAutoStartEnabled { return }
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
        helperBlock = nil
        try await engineStatusStore.startEngine(profileID: profileID, modelOverride: modelOverride)
      } catch let block as HelperUnavailable {
        helperBlock = block
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
    // #562: the bind-mode rollback failure is a curated `LocalizedError` whose
    // message is a deliberate, user-facing security warning (the external-access
    // preference may still be set). Surface its localized copy rather than the
    // generic line; all other opaque errors stay generic (no raw struct dump).
    if error is LocalAPIBindModeRollbackError {
      return "Couldn't \(verb) the engine: \(error.localizedDescription)"
    }
    return "Couldn't \(verb) the engine."
  }

  /// Message for the chat-local engine-action banner, or nil when it
  /// should stay hidden. Live `.failed` status is owned by RootView's
  /// unified status banner (and modelMissing-with-download is owned by
  /// `ModelMissingBanner` below), so the local banner is reserved for a
  /// thrown start/stop action error while status itself is not `.failed`.
  private var engineActionFailureMessage: String? {
    MissingModelRecovery.engineActionFailureBannerMessage(
      engineStatus: engineStatusStore.status,
      actionError: engineActionError)
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
        // from `Chat.modelID` (the #460 authority). #580 grouping + quant tag
        // + unverified shield render inside `ContentToolbar` from these
        // options (each carries its parsed `ModelNameParts` + `isUnverified`).
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
        followProfileDefaultModel: appPreferences.followProfileDefaultModel,
        swapCoordinator: swapCoordinator,
        modelLoadCenter: modelLoadCenter,
        engineStatus: engineStatusStore,
        helperHealth: helperHealth,
        engineLifecycle: engineLifecycle,
        profileSampling: { selectedProfileSamplingDefault },
        onUnload: unloadModel,
        onStartEngine: startEngineForSelectedProfile
      )
      Divider().opacity(0.0001) // structural breather; no visible line per §5
      // #496: while the background Helper is the live fault, the window-level
      // `UnifiedStatusBanner` already attributes it correctly (the helper axis
      // outranks the engine axis). Suppress the in-chat ENGINE banners so a dead
      // Helper is never ALSO re-framed here as an engine fault (the ~30-poll
      // synthesized `.failed(.engineGone)`) — the mis-attribution the deleted
      // full-bleed overlay used to prevent, now carried by the banner/
      // attribution path (`StatusBannerReducer.helperOwnsBanner`).
      if !helperOwnsStatusBanner {
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
          // #477/#497: keyed on the GATE target's model (pick ?? default) like
          // the suppression axis below and the boot path — the banner must
          // never offer a download for a default the Load tap wouldn't boot.
          profileDefaultModel: gateTarget(for: chat)?.modelID,
          sendGatePresented: showNoModelPrompt && noModelAction(for: chat).isDownload
        ) {
          ModelMissingBanner(
            target: bannerTarget,
            onDownloaded: { startEngineForSelectedProfile() },
            engineStatus: engineStatusStore.status
          )
        } else if let message = engineActionFailureMessage {
          // Surface distinct thrown start/stop action errors in-chat — they
          // may not appear in the live status poll and must not be hidden
          // under "Couldn't save". Live `.failed` status is rendered once by
          // the app-level unified status banner so it does not duplicate
          // inside the chat surface.
          EngineFailureBanner(
            message: message,
            onDismiss: MissingModelRecovery.engineFailureDismissable(
              engineStatus: engineStatusStore.status) ? { engineActionError = nil } : nil)
        }
      }

      // #496: an engine action refused because the Helper isn't healthy — an
      // inline, helper-framed acknowledgment near the action. The authoritative
      // helper status lives in the window-level `UnifiedStatusBanner` above.
      if let helperBlock {
        HelperUnavailableNotice(reason: helperBlock, onDismiss: { self.helperBlock = nil })
      }
      // #513 review v2 F1: stale-retry notice on its own channel and
      // surface — engine-status changes can neither shadow nor clear it.
      // `.task(id:)` keyed on the per-raise `id` gives it a bounded
      // lifetime: every raise (including re-raising the same message)
      // restarts the auto-clear, and Dismiss clears it immediately.
      if let notice = staleRetryNotice {
        StaleRetryNotice(message: notice.message, onDismiss: { staleRetryNotice = nil })
          .task(id: notice.id) {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            // The sleep's cancellation error is swallowed by `try?`, so
            // re-check before clearing: a cancelled timer (row replaced or
            // removed) must not wipe a newer notice.
            guard !Task.isCancelled else { return }
            if staleRetryNotice?.id == notice.id { staleRetryNotice = nil }
          }
      }
      // #496: the chat body is the transcript + composer. It is NEVER covered by
      // a full-bleed helper overlay — that earlier overlay's `maxHeight:.infinity`
      // exploded the window layout and made the WHOLE window non-interactive. A
      // dead/starting Helper now reads on the bounded window banner (+ the inline
      // notice above for a refused action), keeping the sidebar/history/Settings
      // live.
      VStack(spacing: 0) {
        TranscriptView(
          chat: chat,
          // #513: retry waits for the active stream — while this chat is
          // in flight the controls are hidden entirely (nil), so a retry
          // can never race the stream writer or cancel an unrelated
          // chat's stream.
          onRetryTurn: sendCoordinator.isInFlight(chatID)
            ? nil
            : { messageID in requestRetry(for: chat, messageID: messageID) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        ComposerView(
          chat: chat,
          viewModel: viewModel,
          isSending: sendCoordinator.isInFlight(chatID),
          shouldAllowSend: { sendGateDecision(for: chat).allowsSend },
          onSendBlocked: { draft in
            handleBlockedSend(draft: draft, for: chat)
          },
          onUserMessageSaved: { _ in
            // A send committed (manual or fired auto-send) — any armed
            // pending send is now satisfied or superseded. #516.
            pendingSend.disarm()
            cancelDeferredEngineSync()
            sendAssistantTurn(for: chat)
          },
          // #507: the composer's stop button — the user-reachable cancel
          // for this chat's in-flight turn (review v1 F1).
          onStop: { sendCoordinator.cancel(chatID: chatID) },
          autoSubmit: pendingSend.autoSubmit
        )
      }
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
          // The common load path defers while any chat is streaming so this
          // prompt button can't restart the single engine out from under a
          // sibling chat.
          loadDefaultModel(model, for: chat)
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
        onCancel: {
          // #516: a dismissed gate drops the pending send — the draft stays
          // in the composer, but nothing auto-fires later.
          pendingSend.disarm()
          cancelDeferredEngineSync()
          showNoModelPrompt = false
        },
        engineStatus: engineStatusStore.status,
        // #516: only promise "…to send your message" when a blocked send is
        // actually armed to fire (the launch-time prompt raises this same
        // sheet with an empty composer — there, the copy must not lie).
        willAutoSend: pendingSend.pending != nil
      )
    }
    .sheet(item: $pinnedModelMismatch) { mismatch in
      PinnedModelMismatchPrompt(
        mismatch: mismatch,
        onRelaunchPinned: {
          relaunchPinnedMismatch(mismatch, for: chat)
        },
        onUseResident: {
          if persistChatModel(mismatch.residentModelID, on: chat) {
            pinnedModelMismatch = nil
          }
        },
        onCancel: {
          pinnedModelMismatch = nil
        }
      )
    }
    // #513: destructive-retry confirmation. Required whenever the plan
    // erases more than the stale assistant itself: later conversation, or
    // adjacent assistant rows that must be removed so the retained prefix
    // ends at a user turn. Canceling leaves history untouched — nothing is
    // mutated until Retry.
    .alert(
      "Retry from here?",
      isPresented: Binding(
        get: { pendingRetryMessageID != nil },
        set: { if !$0 { pendingRetryMessageID = nil } }
      )
    ) {
      Button("Retry", role: .destructive) {
        if let messageID = pendingRetryMessageID {
          executeRetry(for: chat, messageID: messageID)
        }
        pendingRetryMessageID = nil
      }
      Button("Cancel", role: .cancel) { pendingRetryMessageID = nil }
    } message: {
      Text("This will erase the affected responses back to the previous user message, plus any later conversation, and generate a new response.")
    }
    .onChange(of: engineStatusStore.status) { _, new in
      // PR#15 F3: a thrown start/stop error is transient — once the poll
      // observes the engine in any non-failed state, drop it so a stale
      // action error can't outlive the condition it described.
      if case .failed = new {} else { engineActionError = nil }
      // #4: the engine no longer auto-starts on boot — once status settles
      // (.starting → .stopped), proactively ask to start the model.
      maybePromptEngineStartOnLaunch()
      // #516 review F1: `currentModelID` gates on THIS status being
      // `.running`, but the residency feed (`EngineLifecycle` →
      // `ModelLoadCenter`) observes the engine independently and can land
      // FIRST — its `residentModelID` edge then evaluates to `.hold` and
      // the change-guarded setters emit no later edge. The status flip is
      // that missing edge; `resolutionEdge` is idempotent, so the extra
      // call is safe in every other ordering.
      // Review F6: at the `.running` flip the selection authority is still
      // pre-reconcile (the `.task` reconcile runs after) — require
      // reconciled residency so this edge can't fire a stale pin into an
      // engine serving a different model.
      resolutionEdge(for: chat, requiresResidency: true)
    }
    // #496: auto-dismiss the inline helper-refusal once the Helper recovers to
    // a state where the op would be allowed again, so a stale "helper is
    // starting" notice can't outlive the condition it described.
    .onChange(of: helperHealth.health) { _, h in
      if HelperOpGate.evaluate(h) == nil { helperBlock = nil }
    }
    // #397: auto-dismiss the gate once a model resolves (engine came up
    // and reconciled, or a load completed) so the user lands back at the
    // composer with their draft intact — no stale "starting…" sheet.
    // These two are the post-reconcile edges — residency (or the re-seeded
    // selection) IS the new fact being observed, so no residency pre-check.
    .onChange(of: modelLoadCenter.residentModelID) { _, _ in resolutionEdge(for: chat, requiresResidency: false) }
    .onChange(of: chat.modelID) { _, _ in resolutionEdge(for: chat, requiresResidency: false) }
    // #413's helper-health generation gate is wired at app scope from
    // `ChatSendCoordinator.onAnyInFlightChange` (#507) — streams outlive this
    // view now, so a per-view forward would release the gate on navigate-away
    // while the stream is still saturating the MainActor. THIS chat's
    // in-flight edge is still observed here for #516:
    .onChange(of: sendCoordinator.isInFlight(chatID)) { _, inFlight in
      // #516 review F2: a fire delivered while a send is in flight would be
      // swallowed by `submit()`'s `!isSending` guard — so `verdict` holds
      // while in flight, and THIS edge (in-flight clearing) re-evaluates
      // and delivers the deferred fire.
      // Residency-checked (F6): a deferred fire must not consume the
      // pending against a relaunched-but-unreconciled engine either; if
      // residency is still nil this holds and the residency edge delivers.
      if !inFlight { resolutionEdge(for: chat, requiresResidency: true) }
    }
    .onAppear {
      // Seed the toolbar from the persisted profile so the menu
      // label matches what the chat was created with.
      viewModel.selectedProfileID = chat.profileID
      clearTransientOverridesForSelectedProfile()
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
      // #516: a profile switch makes the gate's promised load target stale —
      // drop the pending send rather than auto-firing under a new profile.
      pendingSend.disarm()
      cancelDeferredEngineSync()
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
        clearTransientOverridesForSelectedProfile()
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
    // #507: NO `.onDisappear` stream cancel — switching chats must not kill
    // the stream. Cancellation is explicit only: the composer's stop button
    // (`cancel(chatID:)`) or chat deletion (`forget`); a new send in the
    // same chat still supersedes inside `ChatSendController.send`.
    .onDisappear {
      // #516: navigating away abandons the pending flow — no stale
      // auto-send when the user later returns or switches chats.
      pendingSend.disarm()
      cancelDeferredEngineSync()
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
  private func reconcileEngineResidentModel(for chat: Chat,
                                            isRetryPass: Bool = false) async {
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
      // #516 review F8: residency-required edges hold the pending send
      // until THIS reconcile lands — and equal `.running` polls never
      // re-run the `.task`, so a bounded failure here would strand the
      // promise forever. Settle instead: one backed-off retry round, and
      // on the final failure fall back to the residency-free edge (the
      // bounded pre-F6 behavior beats an infinite hold). The `.task`
      // cancels this on a status flip (the sleep throws), so a real
      // engine transition supersedes the fallback.
      switch Self.reconcileFailureStep(hasPendingAutoSend: pendingSend.pending != nil,
                                       isRetryPass: isRetryPass) {
      case .none:
        break
      case .retry:
        guard (try? await Task.sleep(nanoseconds: 2_000_000_000)) != nil else { break }
        await reconcileEngineResidentModel(for: chat, isRetryPass: true)
      case .fallbackEdge:
        terminatePendingSendAfterReconcileFailure(for: chat)
      }
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

  /// #513 entry point from a transcript row's Retry control. Routes
  /// through the destructive confirmation only when the plan says more
  /// than the stale assistant itself would be erased; a simple latest-turn
  /// retry executes directly.
  /// The model gate runs FIRST so a blocked retry raises the no-model or
  /// pinned/resident mismatch prompt without having mutated any history.
  private func requestRetry(for chat: Chat, messageID: UUID) {
    guard !sendCoordinator.isInFlight(chatID) else { return }
    switch sendGateDecision(for: chat) {
    case .ready:
      break
    case .pinnedModelMismatch(let pinned, let resident):
      pendingSend.disarm()
      pinnedModelMismatch = PinnedModelMismatch(pinnedModelID: pinned,
                                                residentModelID: resident)
      return
    case .noResolvableModel:
      presentNoModelPrompt()
      return
    }
    guard let plan = ChatRetryPlan.plan(messages: chat.messages, retryPointID: messageID) else {
      // Review v1 F1 (lower-stakes sibling): the rendered control was
      // stale — say so instead of a dead click.
      staleRetryNotice = RetryNoticeState(message: Self.staleRetryNoticeCopy)
      return
    }
    if plan.requiresConfirmation {
      pendingRetryMessageID = messageID
    } else {
      executeRetry(for: chat, messageID: messageID)
    }
  }

  /// Review v1 F1: a user who consented to a destructive retry (or clicked
  /// a rendered Retry control) must never get a silent no-op when the
  /// transcript changed underneath. Review v2 F1: rendered by the
  /// dedicated `StaleRetryNotice` row off `staleRetryNotice` state —
  /// never the engine-failure banner, whose `.failed`-status shadowing
  /// and status-flip clearing could drop this unread.
  static let staleRetryNoticeCopy =
    "Retry no longer applies — the conversation changed or a response is in progress."

  /// #513: truncate back to the last user before the retry point, then
  /// resend from the retained prefix via the normal send path (same
  /// model/profile resolution, same
  /// ToT dispatch, same per-chat controller — so an unrelated chat's
  /// stream is never touched). `ChatRetryPlan.apply` re-validates against
  /// the live transcript and truncates atomically; review v1 F1: every
  /// blocked branch surfaces — `.noLongerApplies` raises the stale-retry
  /// notice, `.saveFailed` was already reported via the persistence
  /// banner (and must not resend — the engine never sees a prefix the
  /// store does not hold).
  private func executeRetry(for chat: Chat, messageID: UUID) {
    switch ChatRetryPlan.apply(
      retryPointID: messageID,
      chat: chat,
      isInFlight: sendCoordinator.isInFlight(chatID),
      context: modelContext,
      persistenceStatus: persistenceStatus
    ) {
    case .send:
      sendAssistantTurn(for: chat)
    case .noLongerApplies:
      staleRetryNotice = RetryNoticeState(message: Self.staleRetryNoticeCopy)
    case .saveFailed:
      break
    }
  }

  private func sendAssistantTurn(for chat: Chat) {
    // Defensive: ComposerView only invokes this after `shouldAllowSend`
    // passed, but never ask the engine to load a model the user did not
    // choose, and never send a pinned model into a known different resident
    // engine (#527).
    let modelID: String
    switch sendGateDecision(for: chat) {
    case .ready(let readyModelID):
      modelID = readyModelID
    case .pinnedModelMismatch(let pinned, let resident):
      pinnedModelMismatch = PinnedModelMismatch(pinnedModelID: pinned,
                                                residentModelID: resident)
      return
    case .noResolvableModel:
      presentNoModelPrompt()
      return
    }
    let options = ChatSendRequestOptions(
      modelID: modelID,
      sampling: Self.resolvedSampling(
        profileDefault: profileStore.sampling(forProfileID: viewModel.selectedProfileID),
        transientOverride: viewModel.samplingOverride),
      systemPromptOverride: Self.resolvedSystemPrompt(
        profileDefault: profileStore.systemPrompt(forProfileID: viewModel.selectedProfileID),
        transientOverride: viewModel.systemPromptOverride),
      profileID: viewModel.selectedProfileID,
      // #426: thread the selected profile's Fast Think (speculative-decoding)
      // settings into the request — a Fast Think profile attaches speculation
      // + forces greedy; a normal or tree-of-thought profile carries none.
      // Built once here so both the ToT dispatch and the normal send get it.
      speculation: profileStore.speculation(forProfileID: viewModel.selectedProfileID),
      // #474: the launched engine's effective max_tokens ceiling, learned
      // from GET /v1/models during resident-model reconcile. `makeRequest`
      // clamps the profile's max_tokens down to this so a memory-squeezed
      // launch never trips the engine's clean 400.
      maxOutputTokensCeiling: modelLoadCenter.residentMaxOutputTokens,
      // #524: seed chat-apc's APC snapshot-retention policy from the latest
      // authoritative pie `model_status` KV counters. Nil/unknown means the
      // inferlet must retain rather than guess.
      kvUsageSnapshot: engineStatusStore.kvUsageSnapshot(for: modelID),
      // #572: thread the selected profile's output-constraint mode. A "JSON
      // Think" profile attaches `response_format: json_object` so chat-apc runs
      // JSON-grammar-constrained decoding; other profiles carry none. Built
      // here so both the ToT dispatch and the normal send get it. Ordered last
      // to match the `ChatSendRequestOptions` init parameter order.
      responseFormat: profileStore.responseFormat(forProfileID: viewModel.selectedProfileID)
    )

    // #413: when the active profile declares `mode = "tree-of-thought"`,
    // route the turn to the ToT dispatch (streamed tree search rendered
    // inline) instead of a chat completion. The launched inferlet is
    // still chat-apc — ToT is a per-request dispatch mode.
    // #507: the chat's app-scoped controller — the send outlives this view.
    let sendController = sendCoordinator.controller(for: chatID)

    // #523 Part B binds the whole profile so the ToT dispatch can source its
    // candidate-generation temperature from it (`toTRequestSampling` below).
    if let totProfile = profileStore.profile(forProfileID: viewModel.selectedProfileID),
       let totConfig = totProfile.treeOfThought {
      sendController.sendTreeOfThought(
        chat: chat,
        context: modelContext,
        engine: engineStore.client,
        config: totConfig,
        persistenceStatus: persistenceStatus,
        // #523 Part B: source the ToT candidate-generation temperature from
        // the profile, not the toolbar default.
        options: options.withSampling(totProfile.toTRequestSampling)
      )
      return
    }

    sendController.send(
      chat: chat,
      context: modelContext,
      engine: engineStore.client,
      modelLoadCenter: modelLoadCenter,
      persistenceStatus: persistenceStatus,
      // Reuses the `options` built above (now carrying #426 speculation +
      // #572 response_format and the selected profile id for Cacheback
      // sidecar scoping), so the normal send and the ToT dispatch share one
      // options value.
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
  /// clears residency on the leave-`.running` edge; this preflight then
  /// requires the helper-observed resident model to match the app's target
  /// before returning a request model id. A mismatch blocks the send and
  /// synchronizes the engine instead of leaking `model_not_found`.
  private func currentModelID(for chat: Chat) -> String? {
    let engineRunning: Bool = {
      if case .running = engineStatusStore.status { return true }
      return false
    }()
    return Self.requestModelID(
      selectedModelID: engineRunning ? chat.modelID : nil,
      profileDefaultModel: engineRunning ? selectedProfileDefault : nil,
      residentModelID: modelLoadCenter.residentModelID
    )
  }

  private func sendGateDecision(for chat: Chat) -> SendGateDecision {
    Self.sendGateDecision(
      engineStatus: engineStatusStore.status,
      selectedModelID: chat.modelID,
      profileDefaultModel: selectedProfileDefault,
      residentModelID: modelLoadCenter.residentModelID)
  }

  private func handleBlockedSend(draft: String, for chat: Chat) {
    switch sendGateDecision(for: chat) {
    case .ready:
      return
    case .pinnedModelMismatch(let pinned, let resident):
      pendingSend.disarm()
      cancelDeferredEngineSync()
      pinnedModelMismatch = PinnedModelMismatch(pinnedModelID: pinned,
                                                residentModelID: resident)
    case .noResolvableModel:
      // #516: capture the blocked send so it can auto-submit once the gate's
      // load target resolves — the promise the no-model sheet's copy makes
      // ("…to send your message"). The #527 mismatch prompt deliberately does
      // not arm auto-send: choosing relaunch or resident is an explicit model
      // identity decision, not permission to send the draft afterwards.
      pendingSend.arm(chatID: chat.id,
                      targetModelID: gateTarget(for: chat)?.modelID,
                      messageText: draft)
      synchronizeEngineForPendingSend(chat)
      presentNoModelPrompt()
    }
  }

  private func relaunchPinnedMismatch(_ mismatch: PinnedModelMismatch, for chat: Chat) {
    pinnedModelMismatch = nil
    // The mismatch prompt is a blocked-send surface, not a permission to
    // interrupt unrelated chats. Route its Relaunch action through the same
    // stream-aware, target-bound engine-mutation path as the no-model prompt's
    // explicit Load button, so a running chat elsewhere defers the restart and
    // a stale prompt target is dropped before it can mutate the shared engine.
    guard gateTarget(for: chat)?.modelID == mismatch.pinnedModelID else { return }
    switch Self.pinnedMismatchRelaunchDecision(inFlightChatIDs: sendCoordinator.inFlightChatIDs) {
    case .runNow:
      loadDefaultModel(mismatch.pinnedModelID, for: chat)
    case .deferUntilIdle:
      deferEngineLoadUntilStreamsIdle(mismatch.pinnedModelID, for: chat)
    }
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
      cancelStaleDeferredEngineMutation(afterTargetChangeFor: chat, newTargetModelID: modelID)
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
  ///
  /// NOT routed through `ModelTarget.resolve`: this is a seed *guard*
  /// (unpinned AND served == this chat's default), not a pin-over-default
  /// pick. `ModelTarget.resolve` models pick → default → nil; folding this
  /// in would change behavior (it would adopt the pin or a non-default
  /// served id, the exact F1 defect this guard exists to prevent).
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

  private var selectedProfileSamplingDefault: ChatSampling {
    Self.chatSampling(from: profileStore.sampling(forProfileID: viewModel.selectedProfileID))
  }

  private func clearTransientOverridesForSelectedProfile() {
    Self.clearTransientOverridesForProfileSwitch(to: viewModel)
  }

  /// Profile switches reset per-chat toolbar overrides. Profile defaults are
  /// not copied into cached view-model state; `sendAssistantTurn` resolves them
  /// from `ProfileStore` at send time so Settings saves affect open chats.
  static func clearTransientOverridesForProfileSwitch(to viewModel: ChatTranscriptViewModel) {
    viewModel.samplingOverride = nil
    viewModel.systemPromptOverride = nil
  }

  static func resolvedSampling(profileDefault: Sampling?,
                               transientOverride: ChatSampling?) -> ChatSampling {
    transientOverride ?? chatSampling(from: profileDefault)
  }

  static func chatSampling(from sampling: Sampling?) -> ChatSampling {
    let defaults = sampling ?? Sampling()
    return ChatSampling(
      temperature: defaults.temperature,
      topP: defaults.topP,
      maxTokens: defaults.maxTokens)
  }

  static func resolvedSystemPrompt(profileDefault: String?,
                                   transientOverride: String?) -> String? {
    let override = transientOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty { return override }
    let profile = profileDefault?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (profile?.isEmpty == false) ? profile : nil
  }

  /// #496: whether the background-Helper transport axis OWNS the window-level
  /// status banner right now (it is being repaired or is unreachable, so
  /// `StatusBannerReducer` surfaces a HELPER banner that outranks the engine
  /// axis). While it does, the chat body suppresses its in-chat ENGINE banners
  /// so a dead Helper is attributed to the Helper (one window banner) and never
  /// re-framed as an engine fault here. Single source of truth with the banner
  /// itself, so the two surfaces can never disagree.
  private var helperOwnsStatusBanner: Bool {
    StatusBannerReducer.helperOwnsBanner(helperHealth.health)
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
      residentModelID: modelLoadCenter.residentModelID,
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
  /// auto-dismisses via `resolutionEdge` (probe-gated — review v3 F9).
  private func loadDefaultModel(_ model: String, for chat: Chat? = nil) {
    switch Self.engineMutationDecision(inFlightChatIDs: sendCoordinator.inFlightChatIDs) {
    case .runNow:
      break
    case .deferUntilIdle:
      if let chat {
        deferEngineLoadUntilStreamsIdle(model, for: chat)
      }
      return
    }
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

  /// #528 send preflight: if a user presses Send while the app's target and
  /// helper resident model disagree, immediately converge the engine onto the
  /// intended target instead of letting the request reach chat completions and
  /// fail as `model_not_found`. `PendingAutoSend` still owns the actual submit
  /// and fires only after residency confirms this target.
  private func synchronizeEngineForPendingSend(_ chat: Chat) {
    guard let target = gateTarget(for: chat) else { return }
    guard pendingSend.pending?.chatID == chat.id else { return }
    guard currentModelID(for: chat) == nil else { return }
    guard case .load = Self.availabilityAction(gateModel: target.modelID,
                                               isModelInstalled: Self.isModelInstalled) else {
      return
    }
    guard Self.engineMutationDecision(inFlightChatIDs: sendCoordinator.inFlightChatIDs) == .runNow else {
      deferEngineSyncUntilStreamsIdle(for: chat)
      return
    }
    if case .running = engineStatusStore.status,
       modelLoadCenter.residentModelID == nil {
      Task { @MainActor in
        await reconcileEngineResidentModel(for: chat)
        if currentModelID(for: chat) == nil {
          loadDefaultModel(target.modelID, for: chat)
        }
      }
      return
    }
    loadDefaultModel(target.modelID, for: chat)
  }

  static func shouldDeferEngineSyncForStreams(_ inFlightChatIDs: Set<UUID>) -> Bool {
    !inFlightChatIDs.isEmpty
  }

  enum EngineMutationDecision: Equatable {
    case runNow
    case deferUntilIdle
  }

  static func engineMutationDecision(inFlightChatIDs: Set<UUID>) -> EngineMutationDecision {
    shouldDeferEngineSyncForStreams(inFlightChatIDs) ? .deferUntilIdle : .runNow
  }

  static func pinnedMismatchRelaunchDecision(inFlightChatIDs: Set<UUID>) -> EngineMutationDecision {
    engineMutationDecision(inFlightChatIDs: inFlightChatIDs)
  }

  private func deferEngineSyncUntilStreamsIdle(for chat: Chat) {
    guard deferredEngineSyncTask == nil else { return }
    deferredEngineSyncTask = Task { @MainActor in
      defer { deferredEngineSyncTask = nil }
      while Self.engineMutationDecision(inFlightChatIDs: sendCoordinator.inFlightChatIDs) == .deferUntilIdle {
        do {
          try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
          return
        }
      }
      synchronizeEngineForPendingSend(chat)
    }
  }

  struct DeferredEngineMutation: Equatable {
    let chatID: UUID
    let targetModelID: String
    let generation: Int

    static func explicitLoad(chatID: UUID,
                             targetModelID: String,
                             generation: Int) -> DeferredEngineMutation {
      DeferredEngineMutation(chatID: chatID, targetModelID: targetModelID, generation: generation)
    }
  }

  enum DeferredEngineMutationResolution: Equatable {
    case drop
    case run(modelID: String)
  }

  static func deferredEngineMutationResolution(
    queued: DeferredEngineMutation,
    currentChatID: UUID,
    currentTargetModelID: String?
  ) -> DeferredEngineMutationResolution {
    guard queued.chatID == currentChatID else { return .drop }
    guard let currentTargetModelID, !currentTargetModelID.isEmpty else { return .drop }
    guard currentTargetModelID == queued.targetModelID else { return .drop }
    return .run(modelID: queued.targetModelID)
  }

  static func replacingDeferredEngineMutation(
    current: DeferredEngineMutation?,
    replacement: DeferredEngineMutation
  ) -> DeferredEngineMutation {
    replacement
  }

  private func deferEngineLoadUntilStreamsIdle(_ model: String, for chat: Chat) {
    deferredEngineMutationGeneration += 1
    let queued = DeferredEngineMutation.explicitLoad(
      chatID: chat.id,
      targetModelID: model,
      generation: deferredEngineMutationGeneration)
    deferredEngineMutation = Self.replacingDeferredEngineMutation(
      current: deferredEngineMutation,
      replacement: queued)
    deferredEngineSyncTask?.cancel()
    deferredEngineSyncTask = Task { @MainActor in
      defer { deferredEngineSyncTask = nil }
      while Self.engineMutationDecision(inFlightChatIDs: sendCoordinator.inFlightChatIDs) == .deferUntilIdle {
        do {
          try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
          return
        }
      }
      guard deferredEngineMutation == queued else { return }
      deferredEngineMutation = nil
      switch Self.deferredEngineMutationResolution(
        queued: queued,
        currentChatID: chat.id,
        currentTargetModelID: gateTarget(for: chat)?.modelID
      ) {
      case .drop:
        break
      case .run(let modelID):
        loadDefaultModel(modelID, for: chat)
      }
    }
  }

  private func cancelDeferredEngineSync() {
    deferredEngineSyncTask?.cancel()
    deferredEngineSyncTask = nil
    deferredEngineMutation = nil
  }

  private func cancelStaleDeferredEngineMutation(afterTargetChangeFor chat: Chat,
                                                 newTargetModelID: String?) {
    guard let queued = deferredEngineMutation, queued.chatID == chat.id else { return }
    let currentTarget = Self.gateTarget(selectedModelID: newTargetModelID,
                                        profileDefaultModel: selectedProfileDefault)?.modelID
    guard currentTarget != queued.targetModelID else { return }
    cancelDeferredEngineSync()
  }

  /// #397 F1: re-poll the helper after an unreachable-transport failure.
  /// The 1 Hz loop would catch up anyway; this makes Retry immediate.
  private func refreshEngineStatus() {
    Task { @MainActor in
      _ = try? await engineStatusStore.refresh()
    }
  }


  /// #516 review F8: the bounded reconcile-failure policy. Without a
  /// pending send there is nothing to settle (the pre-existing NSLog
  /// behavior stands — surfacing the failure in the gate UI is the
  /// deferred FC1). With one armed: first pass earns a backed-off retry;
  /// the final failure explicitly terminates the pending flow instead of
  /// holding forever on equal `.running` polls that will not re-run reconcile.
  enum ReconcileFailureStep: Equatable {
    case none, retry, fallbackEdge
  }

  static func reconcileFailureStep(hasPendingAutoSend: Bool,
                                   isRetryPass: Bool) -> ReconcileFailureStep {
    guard hasPendingAutoSend else { return .none }
    return isRetryPass ? .fallbackEdge : .retry
  }

  /// #516 review F6: what a resolution edge may treat as resolved. On the
  /// STATUS edge (`requiresResidency: true`) the selection authority is
  /// still pre-reconcile — `chat.modelID`/profile default can name model A
  /// while the engine just came up serving model B (helper auto-relaunch
  /// boots the active-profile marker's model) — so until
  /// `residentModelID` is reconciled nothing counts as resolved; the
  /// post-reconcile residency/`chat.modelID` edges then deliver the real
  /// fire-or-disarm. Pure + static so the ordering matrix is unit-tested.
  static func resolutionProbe(resolvedModelID: String?,
                              residentModelID: String?,
                              requiresResidency: Bool) -> String? {
    guard let resolvedModelID, !resolvedModelID.isEmpty else { return nil }
    if let residentModelID {
      guard residentModelID == resolvedModelID else { return nil }
    } else if requiresResidency {
      return nil
    }
    return resolvedModelID
  }

  enum PendingSettlementResolution: Equatable {
    case hold
    case disarm
    case model(String)
  }

  static func pendingSettlementResolution(currentTargetModelID: String?,
                                          pendingTargetModelID: String?,
                                          residentModelID: String?) -> PendingSettlementResolution {
    guard let pendingTargetModelID, !pendingTargetModelID.isEmpty else { return .hold }
    guard let currentTargetModelID, !currentTargetModelID.isEmpty else { return .disarm }
    guard currentTargetModelID == pendingTargetModelID else { return .disarm }
    guard let residentModelID, !residentModelID.isEmpty else { return .hold }
    return .model(residentModelID)
  }

  private func terminatePendingSendAfterReconcileFailure(for chat: Chat) {
    pendingSend.terminate(chatID: chat.id)
  }

  /// #516: a model-resolution edge (residency reconciled, or the chat's
  /// selection re-seeded to the served model). Closes the gate (#397) and
  /// settles any armed pending send: fire it through the composer when the
  /// INTENDED model resolved, drop it when a different one did (the user
  /// switched model/profile mid-load), keep holding otherwise.
  ///
  /// `requiresResidency` — true ONLY for the engine-status edge, which can
  /// arrive before `reconcileEngineResidentModel` re-seeds the selection
  /// authority (review F6, see `resolutionProbe`). No default: every new
  /// edge must decide explicitly.
  private func resolutionEdge(for chat: Chat, requiresResidency: Bool) {
    let resolved = Self.resolutionProbe(
      resolvedModelID: currentModelID(for: chat),
      residentModelID: modelLoadCenter.residentModelID,
      requiresResidency: requiresResidency)
    let pendingResolution = Self.pendingSettlementResolution(
      currentTargetModelID: gateTarget(for: chat)?.modelID,
      pendingTargetModelID: pendingSend.pending?.targetModelID,
      residentModelID: modelLoadCenter.residentModelID)
    // #397: close the gate once a model resolves so the user lands back at
    // the composer with their draft intact. Review v3 F9: dismissal stays
    // keyed on the send-safe probe — on a residency-required edge the sheet
    // must not flash the dismiss-success signal while pending settlement is
    // still waiting for resident evidence.
    if showNoModelPrompt, resolved != nil {
      showNoModelPrompt = false
    }
    // Settle the pending: fire-once (cleared before the signal so
    // re-entrant edges can never double-send), disarm on stale, else hold.
    // The transition bookkeeping lives in `PendingSendState` (tested).
    switch pendingResolution {
    case .hold:
      pendingSend.settle(chatID: chat.id,
                         resolvedModelID: nil,
                         isSending: sendCoordinator.isInFlight(chatID))
    case .disarm:
      pendingSend.disarm()
    case .model(let modelID):
      pendingSend.settle(chatID: chat.id,
                         resolvedModelID: modelID,
                         isSending: sendCoordinator.isInFlight(chatID))
    }
  }

  /// Resolve the model a send may target only when the chat's SELECTION
  /// authority (#460) and the helper-observed resident engine state agree.
  /// The app target is still the explicit pin (`selectedModelID` =
  /// `Chat.modelID`) else the active profile's default; residency is the
  /// separate engine fact that proves the running helper can serve it. Nil
  /// means the caller blocks the send and synchronizes the engine first.
  ///
  /// Pin-over-default precedence routes through the one derivation
  /// (`ModelTarget.resolve`) so the send path can never disagree with the
  /// gate/launch path about which model the chat means. GUI tests reach this
  /// path the same way a user does — a pinned `Chat.modelID` and a running
  /// engine — never a parallel send-model override (#504 retired the
  /// `PIE_TEST_CHAT_MODEL` bypass).
  static func requestModelID(
    selectedModelID: String?,
    profileDefaultModel: String?,
    residentModelID: String?
  ) -> String? {
    EngineRequestSync(
      target: ModelTarget.resolve(selectedModelID: selectedModelID,
                                  profileDefault: profileDefaultModel),
      resident: EngineResidentState(modelID: residentModelID)
    ).resolvedModelID
  }

  /// #527: final send gate for model identity. The selection authority remains
  /// `Chat.modelID` (or profile default when unpinned), but a known resident
  /// engine model is an execution precondition: an explicit per-chat pin that
  /// differs from `residentModelID` is guaranteed to be rejected by the engine,
  /// so block and ask instead of surfacing a bare model_not_found after send.
  ///
  /// Explicit pins get the user-facing mismatch prompt. Unpinned
  /// profile-default-vs-resident gaps fall through to `.noResolvableModel`,
  /// where the request/resident sync path can converge the engine before send.
  static func sendGateDecision(
    engineStatus: EngineStatus,
    selectedModelID: String?,
    profileDefaultModel: String?,
    residentModelID: String?
  ) -> SendGateDecision {
    guard case .running = engineStatus else { return .noResolvableModel }
    guard ModelTarget.resolve(selectedModelID: selectedModelID,
                              profileDefault: profileDefaultModel) != nil else {
      return .noResolvableModel
    }

    let selected = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resident = residentModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let selected, !selected.isEmpty,
       let resident, !resident.isEmpty,
       selected != resident {
      return .pinnedModelMismatch(pinnedModelID: selected,
                                  residentModelID: resident)
    }
    guard let resolved = requestModelID(selectedModelID: selectedModelID,
                                        profileDefaultModel: profileDefaultModel,
                                        residentModelID: residentModelID) else {
      return .noResolvableModel
    }
    return .ready(modelID: resolved)
  }
}

struct PinnedModelMismatchPrompt: View {
  let mismatch: ChatScaffoldView.PinnedModelMismatch
  let onRelaunchPinned: () -> Void
  let onUseResident: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text("Switch model before sending?")
          .font(.headline)
      }
      Text("This chat is pinned to a different model than the engine is currently serving. Choose which model should be used before sending.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      modelRow(label: "Pinned chat model", modelID: mismatch.pinnedModelID)
      modelRow(label: "Resident engine model", modelID: mismatch.residentModelID)
      HStack {
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Use \(Self.leaf(mismatch.residentModelID)) for this chat") {
          onUseResident()
        }
        .accessibilityIdentifier("pinnedModelMismatch.useResident")
        Button("Relaunch engine with \(Self.leaf(mismatch.pinnedModelID))") {
          onRelaunchPinned()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("pinnedModelMismatch.relaunchPinned")
      }
    }
    .padding(18)
    .frame(width: 420)
    .accessibilityIdentifier("pinnedModelMismatch.prompt")
  }

  private func modelRow(label: String, modelID: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(modelID)
        .font(.body.weight(.medium))
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }

  private static func leaf(_ modelID: String) -> String {
    ModelDisplayName.leaf(modelID)
  }
}
