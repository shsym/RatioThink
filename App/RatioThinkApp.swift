import SwiftUI
import SwiftData
import ServiceManagement

@main
struct RatioThinkApp: App {
  /// #448: window-close = background, ⌘Q / "Quit" / `ratiothink://quit` =
  /// coordinated full quit. The delegate owns `applicationShouldTerminate`
  /// (which SwiftUI's `App` does not expose) and
  /// `applicationShouldTerminateAfterLastWindowClosed`.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// One-shot guard so the launch-time Helper registration reconcile
  /// runs once even if a second window opens.
  @MainActor private static var didReconcileHelperRegistration = false
  @StateObject private var windowState = WindowState()
  /// Phase 4: observable durability state for the chat
  /// store. Surfaces on-disk vs in-memory fallback and per-mutation
  /// save failures to a banner inside `RootView` so the user is
  /// never silently writing to a tier that dies on relaunch.
  @StateObject private var persistenceStatus: PersistenceStatus
  /// Phase 4: single app-wide `ModelContainer` for the
  /// SwiftData `chats.sqlite` store. Falls back to an in-memory
  /// container if the on-disk store can't be opened; the fallback
  /// is observable via `persistenceStatus.storage`.
  private let chatContainer: ModelContainer
  // Phase 3.5/3.6: app-wide model-load + preferences + swap policy.
  // Phase 6.1 swapped `MockEngineClient` for `HTTPEngineClient`;
  //  wires the app-side `EngineStatusStore` that resolves
  // its `baseURLProvider`. Constructing the coordinator inside an
  // `@StateObject` closure (rather than another `@StateObject`) lets
  // the four sibling observables share lifetimes without main-actor
  // isolation gymnastics — `RatioThinkApp` is on `@MainActor` by virtue of
  // `App`.
  @StateObject private var modelLoadCenter: ModelLoadCenter
  @StateObject private var appPreferences: AppPreferences
  /// : live profile store shared with the chat toolbar, profile
  /// editor, and the swap coordinator's `modelForProfile` lookup.
  /// `start()` only scans/seeds TOML — it never loads a model, so the
  /// no-eager-load-at-launch invariant holds.
  @StateObject private var profileStore: ProfileStore
  @StateObject private var swapCoordinator: ProfileSwapCoordinator
  /// #616: app-scoped engine-action primitives (start/unload/refresh) + the
  /// once-per-launch start-prompt latch the chat scaffold binds to.
  @StateObject private var engineCoordinator: ChatEngineCoordinator
  @StateObject private var engineStatusStore: EngineStatusStore
  /// The reconciled engine-lifecycle source of truth: folds engine status +
  /// model load into one published `EngineIndicatorState` every surface
  /// derives from, and invalidates app-side residency when the engine leaves
  /// `.running` so no surface can claim a resident model on a dead engine.
  @StateObject private var engineLifecycle: EngineLifecycle
  /// #412: App-side background-helper health + restart ladder. Driven by the
  /// same `engineStatus()` poll as `engineStatusStore` (via `onPollOutcome`)
  /// and surfaced as the toolbar helper-ring + the escalation banner.
  @StateObject private var helperHealth: HelperHealthController
  @StateObject private var engineClientStore: EngineClientStore
  /// #507: app-scoped per-chat send pipelines, so an in-flight stream
  /// survives chat switches and multiple chats can stream concurrently.
  /// Also feeds the #413 generation gate (any chat in flight → hold
  /// failed helper polls).
  @StateObject private var sendCoordinator: ChatSendCoordinator
  /// Phase 3.8 (review v2 F1): the Add Model sheet's `.queueDownload`
  /// outcome runs through this controller so the existing
  /// `ModelDownloader` is actually invoked. Lives at app scope so
  /// closing + reopening the Settings sheet does not orphan an
  /// in-flight download.
  @StateObject private var downloadController: ModelDownloadController
  /// #514: the one live source of truth for local model availability
  /// (scan results + in-flight downloads + completion reconciliation).
  /// App-scoped beside the download controller it observes.
  @StateObject private var modelLibrary: ModelLibraryStore
  /// #411: once-per-launch GitHub-Releases update check. App-scoped so the
  /// check (and its single network call) fires once per process; RootView
  /// observes `pending` to render the non-modal update banner.
  @StateObject private var updateAvailability = UpdateAvailabilityModel()
  @StateObject private var settingsNavigation = SettingsNavigation()
  // Cross-tab tick so the Profiles-tab ProfileEditor recomputes its
  // picker over-limit badges when the Models-tab guardrail dial writes (#334).
  @StateObject private var guardrailRevision = GuardrailRevision()
  /// #621: per-profile speculative-decode telemetry. The chat send loop
  /// records each turn's terminal `spec_metrics` here; the ProfileEditor
  /// reads it for the read-only "last run" badge.
  @StateObject private var specMetricsStore = SpecMetricsStore()

  /// #587 resume trigger: re-arm the (possibly paused) engine-status poll
  /// loop when the app returns to the foreground, so the user always sees a
  /// fresh status the moment they look at the window. A no-op when the loop
  /// is already running; one extra poll then re-pause when no session is
  /// expected.
  @Environment(\.scenePhase) private var scenePhase

  @MainActor
  init() {
    Self.writeArtifactPathProbeIfRequested()
    Self.recordLaunchBreadcrumb()

    // Build the four dependencies value-side so the coordinator can
    // borrow them at construction. The `@StateObject` wrappers aren't
    // installed on `self` at `init` time, so a re-instantiation here
    // is the only place identity can be threaded.
    let center = ModelLoadCenter()
    let prefs = AppPreferences(defaults: Self.appPreferencesDefaults())
    let testBaseURL = Self.chatTestEngineBaseURL()
    // #504/#616: one construction point for the status store (incl. the DEBUG
    // PIE_TEST_PIN_ENGINE_RUNNING / PIE_TEST_ENGINE_START_TO_RUNNING harness
    // seams). `enginePinned` gates the poll loop below; `residentSeed` is the
    // pinned-running GUI seam's resident-model seed, applied to `center` here
    // (kept out of the factory so the factory never reaches into ModelLoadCenter).
    let (statusStore, enginePinned, residentSeed) =
      Self.makeEngineStatusStore(testBaseURL: testBaseURL, preferences: prefs)
    if let residentSeed {
      center.reconcileEngineResident(residentSeed)
    }
    let engine = Self.makeEngineClient(testBaseURL: testBaseURL, statusStore: statusStore)
    // Build the persistence-status surface first so the profile store's
    // start() failure has a visible channel (review F3).
    let status = PersistenceStatus()

    // : app-side profile store. Honors PIE_HOME (test isolation).
    // Point it at the REAL profiles location (review F3 — no silent
    // /tmp fallback that would hide the user's actual profiles); its
    // start() creates the dir + scans/seeds (no model load), and any
    // failure (unwritable PIE_HOME, etc.) is reported to
    // `PersistenceStatus` rather than swallowed.
    let store = ProfileStore(directory: PieDirs.profilesURL())
    do {
      try store.start()
    } catch {
      status.report(error, context: "RatioThinkApp.ProfileStore.start")
    }

    _modelLoadCenter = StateObject(wrappedValue: center)
    _appPreferences = StateObject(wrappedValue: prefs)
    _profileStore = StateObject(wrappedValue: store)
    _engineStatusStore = StateObject(wrappedValue: statusStore)
    // #616: borrow the value-side `statusStore`/`center` so the chat scaffold
    // shares one engine-action coordinator (and one launch latch surviving
    // chat-row remounts).
    _engineCoordinator = StateObject(wrappedValue: ChatEngineCoordinator(
      engineStatus: statusStore,
      modelLoad: center,
      engineClient: engine
    ))
    // The reconciled engine-lifecycle fold + residency invalidation. Borrows
    // the value-side `statusStore`/`center` built above; observes both and
    // republishes the single `EngineIndicatorState`.
    _engineLifecycle = StateObject(wrappedValue: EngineLifecycle(
      engineStatus: statusStore,
      modelLoad: center
    ))
    _engineClientStore = StateObject(wrappedValue: EngineClientStore(client: engine))
    // #469: the production status-aware executor a model PICK routes through.
    // v1 pie binds the served model at `pie serve` boot, so changing the
    // served model is an engine lifecycle event — start a stopped engine
    // bound to the pick, rebuild a running one onto a different pick, or
    // no-op when it is already resident — NOT a `/v1/models/load` (which a
    // stopped engine ignores and a running one only acks for its boot model).
    // The override is threaded through the start/restart XPC so the Helper
    // boots the chosen model; the resolver records it in the durable
    // active-model marker so a later menu-bar Resume honors the pick.
    // #488: the executor also QUEUES a pick made while the engine is
    // mid-transition (policy `.deferBusy`) and re-serves it when the engine
    // settles, instead of silently dropping it.
    let serveExecutor = ActiveModelServeExecutor(engineStatus: statusStore, modelLoad: center)
    let coordinator = ProfileSwapCoordinator(
      center: center,
      profileStore: store,
      serveModel: { try await serveExecutor.serve(modelID: $0, profileID: $1) }
    )
    // A deferred re-serve has no awaiting `startLoad` Task to throw to —
    // route its failure into the same toolbar `serveModelError` surface a
    // direct pick's failure uses (#488).
    serveExecutor.onDeferredServeFailure = { [weak coordinator] modelID, error in
      coordinator?.reportServeFailure(modelID: modelID, error: error)
    }
    _swapCoordinator = StateObject(wrappedValue: coordinator)
    let downloadController = Self.makeDownloadController()
    _downloadController = StateObject(wrappedValue: downloadController)
    _modelLibrary = StateObject(wrappedValue: ModelLibraryStore(downloads: downloadController))

    _persistenceStatus = StateObject(wrappedValue: status)
    chatContainer = RatioThinkModelContainer.openWithFallback(status: status)

    // #412: App-side helper-health restart ladder, built + wired to the SAME
    // status poll (no second XPC surface). `helperPinned` is the #496 DEBUG GUI
    // seam pin; it joins `enginePinned` to gate the poll loop below.
    let (helperHealthController, helperPinned) =
      Self.makeHelperHealthController(statusStore: statusStore)
    _helperHealth = StateObject(wrappedValue: helperHealthController)

    // #507: chat sends are app-scoped (per-chat controllers) so streams
    // outlive the detail view. The #413 generation gate moves here with
    // them: hold failed helper polls while ANY chat is streaming.
    let chatSendCoordinator = ChatSendCoordinator()
    chatSendCoordinator.onAnyInFlightChange = { [weak helperHealthController] active in
      helperHealthController?.setGenerating(active)
    }
    _sendCoordinator = StateObject(wrappedValue: chatSendCoordinator)

    // #448: give the full-product quit coordinator the poll loop it must stop
    // before tearing down, so no late on-demand poll respawns the Helper.
    AppQuitCoordinator.shared.engineStatusStore = statusStore

    // Kick the XPC poll loop. Idempotent + cheap — first reply lands within
    // ~one runloop tick when the helper is registered, longer when launchd has
    // not yet published the mach service. Skipped when the engine status is
    // pinned for the S302 harness (no Helper to poll; a failed poll would reset
    // the pinned `.running` → `.starting`) or the #496 helper-health is pinned
    // (a poll would move the pinned ladder and could flip the engine off
    // `.starting`), both of which would make the GUI seam nondeterministic.
    if !enginePinned && !helperPinned {
      statusStore.start()
    }
  }

  /// #504/#616: the single construction point for the app's `EngineStatusStore`,
  /// including the DEBUG-only GUI-harness seams.
  ///
  /// `PIE_TEST_PIN_ENGINE_RUNNING` (S302): a pure-HTTP mock engine answers
  /// `/v1/...` but has NO Helper to report status over XPC, so the model-menu
  /// `/v1/models` reconcile (gated on `.running`) would otherwise empty the
  /// menu. Pin `EngineStatus.running` — the one fact the absent Helper would
  /// report. `PIE_TEST_ENGINE_START_TO_RUNNING` (#381): a second seam that
  /// starts `.stopped` then flips to `.running` when `startEngine` is called,
  /// for the no-model → Load-default follow-through without a real `pie serve`.
  /// `#if DEBUG` so the flags + pins compile out of Release entirely.
  ///
  /// Returns the store, whether the engine status is pinned (the caller must
  /// then NOT poll, or a failed poll would reset the pin), and the optional
  /// `PIE_TEST_CHAT_MODEL_PIN` resident-model seed the caller applies to
  /// `ModelLoadCenter` (kept out of this factory so it stays engine-store-only).
  @MainActor
  private static func makeEngineStatusStore(
    testBaseURL: URL?,
    preferences prefs: AppPreferences
  ) -> (store: EngineStatusStore, enginePinned: Bool, residentSeed: String?) {
    #if DEBUG
    let pinnedRunningPort: EnginePort? = {
      guard ProcessInfo.processInfo.environment["PIE_TEST_PIN_ENGINE_RUNNING"] == "1",
            let rawPort = testBaseURL?.port,
            let port = EnginePort(exactly: rawPort) else { return nil }
      return port
    }()
    let startToRunningPort: EnginePort? = {
      guard ProcessInfo.processInfo.environment["PIE_TEST_ENGINE_START_TO_RUNNING"] == "1",
            let rawPort = testBaseURL?.port,
            let port = EnginePort(exactly: rawPort) else { return nil }
      return port
    }()
    if let pinnedRunningPort {
      let servedModelID = ProcessInfo.processInfo.environment["PIE_TEST_ENGINE_SERVED_MODEL"] ?? ""
      // Inject a stub XPC client (NOT HelperXPCClient): the helperless harness
      // has no Helper, so a real stopEngine() during Unload would throw and the
      // coordinator would never reach markUnloaded() — the model would stay
      // resident. The stub reports the pinned running status and accepts
      // stopEngine as a no-op so the Unload confirm path completes (#359 Path2).
      let store = EngineStatusStore(
        client: PinnedRunningXPCClient(port: pinnedRunningPort,
                                       servedModelID: servedModelID),
        initialStatus: .running(EngineSessionSnapshot(port: pinnedRunningPort,
                                                      profileID: "chat",
                                                      servedModelID: servedModelID,
                                                      daemonBindHost: prefs.localAPIBindMode)),
        initialDaemonBindMode: prefs.localAPIBindMode,
        daemonBindModeProvider: { prefs.localAPIBindMode }
      )
      let seed = ProcessInfo.processInfo.environment["PIE_TEST_CHAT_MODEL_PIN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let residentSeed = (seed?.isEmpty == false) ? seed : nil
      return (store, enginePinned: true, residentSeed: residentSeed)
    }
    if let startToRunningPort {
      let store = EngineStatusStore(
        client: StartableStubXPCClient(port: startToRunningPort),
        initialStatus: .stopped
      )
      // Not status-pinned: this seam drives real `.stopped`→`.running`
      // transitions and must keep polling.
      return (store, enginePinned: false, residentSeed: nil)
    }
    #endif
    let store = EngineStatusStore(
      client: HelperXPCClient(),
      initialDaemonBindMode: prefs.localAPIBindMode,
      daemonBindModeProvider: { prefs.localAPIBindMode }
    )
    return (store, enginePinned: false, residentSeed: nil)
  }

  /// Build the chat engine client. `HTTPEngineClient.baseURLProvider` resolves
  /// `EngineStatusStore.requireBaseURL()` on each request: `http://127.0.0.1:<port>`
  /// when the helper reports `.running`, else throws `engineNotReady`. A
  /// `testBaseURL` (DEBUG/test harness only) points the client straight at an
  /// externally-launched engine. The weak-store capture matches the GUI's
  /// lifetime model — `RatioThinkApp` outlives every subsystem so the closure
  /// realistically never finds `nil`, but the explicit guard keeps the failure
  /// mode an `engineNotReady` rather than a crash if a future refactor lets the
  /// store deinit early.
  @MainActor
  private static func makeEngineClient(
    testBaseURL: URL?,
    statusStore: EngineStatusStore
  ) -> EngineClient {
    if let testBaseURL {
      return HTTPEngineClient(baseURL: testBaseURL)
    }
    return HTTPEngineClient(
      baseURLProvider: { [weak statusStore] in
        guard let store = statusStore else {
          throw HTTPEngineError.engineNotReady(detail: "EngineStatusStore deallocated")
        }
        return try await MainActor.run { try store.requireBaseURL() }
      }
    )
  }

  /// #412: build the App-side helper-health restart ladder and wire it to the
  /// status poll. The repair runs the runtime registration reconcile; a
  /// test/automation launch gets a no-op repair so a GUI run never mutates the
  /// real machine's SMAppService background-item registration (the same guard
  /// the launch reconcile uses). #496 DEBUG GUI seam: the ladder can be pinned
  /// to a fixed `HelperHealth` so the chat-body recovery states render
  /// deterministically without a real background helper. Driven by the SAME
  /// `engineStatus()` poll as the status mirror (via `onPollOutcome`) — no
  /// second XPC surface — and the chat recovery wait bounds itself by the
  /// ladder outcome (review F1). Returns whether the ladder is pinned (joins
  /// `enginePinned` to gate the poll loop).
  @MainActor
  private static func makeHelperHealthController(
    statusStore: EngineStatusStore
  ) -> (controller: HelperHealthController, helperPinned: Bool) {
    let helperRepair: () async -> Bool
    if HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment) {
      helperRepair = { false }
    } else {
      helperRepair = { await HelperRegistrationRepair().repairAndReportReachable() }
    }
    #if DEBUG
    let pinnedHelperHealth = Self.pinnedHelperHealthForTesting()
    #else
    let pinnedHelperHealth: HelperHealth? = nil
    #endif
    let controller = HelperHealthController(
      repair: helperRepair,
      pinnedHealth: pinnedHelperHealth
    )
    // Set BEFORE statusStore.start() so the first ticks count.
    statusStore.onPollOutcome = { [weak controller] succeeded in
      controller?.ingestPollOutcome(succeeded: succeeded)
    }
    statusStore.helperHealthProvider = { [weak controller] in
      controller?.health
    }
    return (controller, helperPinned: pinnedHelperHealth != nil)
  }

  #if DEBUG
  /// #496 GUI seam: map `PIE_TEST_PIN_HELPER_HEALTH` to a pinned `HelperHealth`
  /// so the chat-body recovery overlay's states can be driven without a real
  /// background helper. `starting` maps to an active-recovery ladder state
  /// (`.repairing`) so the gate resolves to `.startingHelper`; `unreachable`
  /// and `healthy` map directly. Unset / unrecognized ⇒ no pin (normal ladder).
  private static func pinnedHelperHealthForTesting() -> HelperHealth? {
    switch ProcessInfo.processInfo.environment["PIE_TEST_PIN_HELPER_HEALTH"] {
    case "starting":    return .repairing(attempt: 1)
    case "unreachable": return .unreachable
    case "healthy":     return .healthy
    default:            return nil
    }
  }
  #endif

  /// Test-only engine base-URL override. `PIE_TEST_ENGINE_BASE_URL`
  /// points the chat client straight at an externally-launched engine,
  /// bypassing the entire production launch boundary (Helper XPC,
  /// `EngineStatusStore`, `LaunchSpecResolver`, `PieControlLauncher`,
  /// `pie serve`). It is honored ONLY in a test harness
  /// (`PIE_TEST_MODE=1`) or a DEBUG build — a shipped Release
  /// `Rational.app` MUST use the real Helper→engine path. Refusing it
  /// in Release closes the parity gap two ways: a shipped app can't be
  /// redirected at a foreign URL, and a "real binary" (Release/packaged)
  /// scenario cannot silently pass on a fake base URL — if the override
  /// is set it is ignored and the app exercises the real path (failing
  /// loudly when no real engine is present). Mirrors
  /// `HelperXPCListener.isAnonymousModeAllowed` for the
  /// `PIE_ALLOW_UNSIGNED_CALLERS` bypass.
  private static func chatTestEngineBaseURL() -> URL? {
    // Gated through HelperConfig so a Release build ignores the override
    // entirely — the engine-client redirection and the DEBUG status pin both
    // key off this result, so a non-debug app falls back to the real
    // Helper-driven engine path (`HelperXPCClient()`) and never honors the
    // `PIE_TEST_ENGINE_BASE_URL` seam.
    switch HelperConfig.resolveTestEngineBaseURL() {
    case .notSet:
      return nil
    case .valid(let url):
      #if DEBUG
      return url
      #else
      // Defense in depth (#340): the `HelperConfig` gate already returns
      // `.notSet` in a Release build, so a resolved override here means the
      // build gate was somehow wrong. Refuse rather than silently redirect a
      // shipped app at an attacker-supplied URL — mirrors the call-site
      // `preconditionFailure` that `HelperXPCListener.startAnonymous` raises
      // when its own gate is violated.
      preconditionFailure("PIE_TEST_ENGINE_BASE_URL resolved in a Release build — refuse to redirect the engine endpoint away from the real Helper-driven path")
      #endif
    case .malformed(let raw):
      #if DEBUG
      // The override was set and honored (DEBUG/test build) but is not a
      // parseable URL (bad scheme, embedded whitespace, unbalanced bracket).
      // Never silently fall back to the real engine — that would run a test
      // author's typo'd override against the production path and fail far
      // downstream from the cause (#339). Log it, and under an explicit
      // harness (`PIE_TEST_MODE=1`) trap so the misconfiguration surfaces at
      // launch instead of masquerading as a "no model" failure.
      NSLog("PIE_TEST_ENGINE_BASE_URL is set but not a valid URL — refusing to silently fall back to the real engine: \(raw)")
      if ProcessInfo.processInfo.environment[HelperConfig.testModeEnvVar] == "1" {
        preconditionFailure("PIE_TEST_ENGINE_BASE_URL is not a valid URL: \(raw)")
      }
      return nil
      #else
      // Defense in depth (#340): same as `.valid` — the gate returns `.notSet`
      // in Release, so any resolved override here means the gate was wrong.
      preconditionFailure("PIE_TEST_ENGINE_BASE_URL resolved in a Release build — refuse to redirect the engine endpoint away from the real Helper-driven path")
      #endif
    }
  }

  private static func appPreferencesDefaults() -> UserDefaults {
    let env = ProcessInfo.processInfo.environment
    let defaults: UserDefaults
    if let suite = env["PIE_APP_PREFERENCES_SUITE"], !suite.isEmpty {
      defaults = UserDefaults(suiteName: suite) ?? .standard
    } else {
      defaults = .standard
    }
    if env["PIE_TEST_FIRST_LAUNCH_COMPLETED"] == "1" {
      defaults.set(true, forKey: AppPreferences.firstLaunchWizardCompletedKey)
    }
    if env["PIE_TEST_FOLLOW_PROFILE_DEFAULT_MODEL"] == "1" {
      defaults.set(true, forKey: AppPreferences.followProfileDefaultModelKey)
    }
    return defaults
  }

  private static func makeDownloadController() -> ModelDownloadController {
    // DEBUG-only GUI/e2e seams: a faked or fixture-backed downloader so a test
    // exercises the download UI without hitting the network. `#if DEBUG` so the
    // env reads (and the test downloaders) compile out of Release entirely —
    // a shipped app can never be redirected onto a fake download path.
    #if DEBUG
    if ProcessInfo.processInfo.environment["PIE_TEST_FAKE_DOWNLOADS"] == "1" {
      return ModelDownloadController(
        downloader: EnvironmentFakeModelDownloader(),
        terminalRowLingerSeconds: 60
      )
    }
    if ProcessInfo.processInfo.environment["PIE_TEST_FIXTURE_DOWNLOADS"] == "1" {
      return ModelDownloadController(
        downloader: EnvironmentFixtureModelDownloader(),
        terminalRowLingerSeconds: 60
      )
    }
    #endif
    return ModelDownloadController()
  }

  /// Self-heal the Helper's launchd registration on launch (
  /// robustness). After an app update replaces the bundle, BTM keeps
  /// reporting `.enabled` while launchd never reloads the `com.ratiothink.helper`
  /// job against the new bundle — so the App's XPC connect fails forever
  /// and the engine never auto-starts. The reconciler probes the Helper
  /// and, ONLY if it is unreachable, forces a reload (`unregister()` then
  /// `register()`); a healthy Helper is left untouched.
  @MainActor
  private static func reconcileHelperRegistrationIfNeeded() async {
    guard !didReconcileHelperRegistration else { return }
    didReconcileHelperRegistration = true
    await performHelperRegistrationReconcile()
  }

  /// The reconcile body, callable on demand. The launch path guards it
  /// with `didReconcileHelperRegistration` (run once); the runtime
  /// "Restart Engine" command (#5b) calls it UNGUARDED to repair a Helper
  /// that went down / unreachable mid-session. Probes the Helper and,
  /// only if it is unreachable, forces a launchd reload (`unregister()`
  /// then `register()`) — which resets a wedged or throttled on-demand
  /// job, the step that previously required a full app restart.
  @MainActor
  private static func performHelperRegistrationReconcile() async {
    // A test/automation launch must NOT construct the real registrar or
    // run SMAppService.unregister()/register() — that mutates the real
    // machine's background-item registration. GUI helpers set only
    // PIE_TEST_FIRST_LAUNCH_COMPLETED / PIE_APP_PREFERENCES_SUITE, so the
    // skip set must cover those launch seams too (F1).
    guard !HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment) else {
      return
    }

    // #412: the reconcile is now the shared `HelperRegistrationRepair`
    // primitive so the launch-time self-heal, the runtime
    // `HelperHealthController` restart ladder, and the user's "Restart
    // helper" action all go through one wiring.
    let outcome = await HelperRegistrationRepair().reconcile()
    NSLog("RatioThinkHelper registration reconcile: \(outcome)")
    Diag.app.event("helper.reconcile", [("outcome", "\(outcome)")])
    if outcome.requiresUserApproval {
      // Hard macOS consent gate — route the user to the toggle.
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  /// User-triggered runtime recovery behind the "Restart Engine" menu
  /// command: reload a wedged or throttled Helper registration via the
  /// shared `performHelperRegistrationReconcile` (the same
  /// `HelperRegistrationRepair` primitive the launch-time self-heal and
  /// the autonomous restart ladder use), then re-start the engine on the
  /// active profile — without quitting the app. A slow-start
  /// `replyTimeout` is swallowed by `EngineStatusStore.startEngine`; the
  /// status poll surfaces the real outcome.
  @MainActor
  private func restartEngine() {
    Task {
      await Self.performHelperRegistrationReconcile()
      guard let profileID = profileStore.activeProfileID,
            !profileID.isEmpty else {
        NSLog("Restart Engine: no active profile to start")
        return
      }
      do {
        try await engineStatusStore.startEngine(profileID: profileID)
      } catch {
        NSLog("Restart Engine: startEngine(\(profileID)) failed: \(error)")
      }
    }
  }

  /// Durable launch breadcrumb: proves the app process started, and records the
  /// version/build, the (home-redacted) bundle path, and whether Gatekeeper's
  /// quarantine xattr is still on the bundle — the first thing triage needs when
  /// "the app does nothing". Best-effort; never blocks launch.
  private static func recordLaunchBreadcrumb() {
    let info = Bundle.main.infoDictionary
    let bundlePath = Bundle.main.bundleURL.path
    let quarantined = getxattr(bundlePath, "com.apple.quarantine", nil, 0, 0, 0) > 0
    Diag.app.event("app.launch", [
      ("version", info?["CFBundleShortVersionString"] as? String ?? "?"),
      ("build", info?["CFBundleVersion"] as? String ?? "?"),
      ("pid", String(ProcessInfo.processInfo.processIdentifier)),
      ("bundle", DiagnosticLog.redactHome(bundlePath)),
      ("executable", DiagnosticLog.redactHome(Bundle.main.executableURL?.path ?? "?")),
      ("quarantine", quarantined ? "present" : "absent"),
    ])
  }

  private static func writeArtifactPathProbeIfRequested() {
    let env = ProcessInfo.processInfo.environment
    guard let probePath = env["PIE_TEST_ARTIFACT_PATH_PROBE_FILE"],
          !probePath.isEmpty else { return }

    let probeURL = URL(fileURLWithPath: probePath)
    do {
      try FileManager.default.createDirectory(
        at: probeURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let bundlePath = Bundle.main.bundleURL
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
      try (bundlePath + "\n").write(to: probeURL, atomically: true, encoding: .utf8)
    } catch {
      NSLog("PIE_TEST_ARTIFACT_PATH_PROBE_FILE write failed: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup("Rational") {
      Group {
        if appPreferences.firstLaunchWizardCompleted {
          RootView()
            // Self-heal a stale Helper registration left by an app
            // update before the engine poll gives up silently.
            .task { await Self.reconcileHelperRegistrationIfNeeded() }
        } else {
          FirstLaunchWizardView()
        }
      }
        .environmentObject(windowState)
        .environmentObject(modelLoadCenter)
        .environmentObject(appPreferences)
        .environmentObject(profileStore)
        .environmentObject(swapCoordinator)
        .environmentObject(engineCoordinator)
        .environmentObject(engineClientStore)
        .environmentObject(persistenceStatus)
        .environmentObject(engineStatusStore)
        .environmentObject(engineLifecycle)
        .environmentObject(helperHealth)
        .environmentObject(sendCoordinator)
        .environmentObject(downloadController)
        .environmentObject(modelLibrary)
        .environmentObject(updateAvailability)
        .environmentObject(settingsNavigation)
        .environmentObject(specMetricsStore)
        // #420: route the menu-bar Helper's `ratiothink://settings` deep
        // link straight to the Settings scene (not just app-foreground).
        .handlesSettingsDeepLink(settingsNavigation: settingsNavigation)
        // #587: re-arm the adaptive poll loop on foreground. `start()` is
        // idempotent, so this is free when the loop is already running and
        // wakes it from a paused (stopped/idle) state to refresh status.
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { engineStatusStore.start() }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
    .modelContainer(chatContainer)
    .defaultSize(width: 1200, height: 800)
    .commands {
      // #411: the MANUAL "Check for Updates…" entry, in the standard macOS
      // spot (App menu, directly under "About Rational"). It always checks
      // and bypasses the ignore-set, complementing the once-per-launch auto
      // check that surfaces the non-modal UpdateAvailableBanner (RootView /
      // UpdateAvailabilityModel). Both compare the running version to the
      // latest GitHub release and, at most, open the release page — neither
      // downloads or installs (in-app auto-INSTALL via Sparkle is future #178).
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          Task { await UpdateChecker.checkForUpdates() }
        }
      }
      // #411: remove the two orphaned no-op "New Chat" menu commands
      // (⌘N / "New Chat (Always)" ⌘T) that had replaced the default
      // File ▸ New. Both were empty closures — they did nothing, while the
      // live new-chat affordances drive `ChatCreation.create` directly
      // (chat-list "+" + col-3 zero-state CTA), never a global menu command.
      // Replacing `.newItem` with an empty group drops both items and their
      // ⌘N/⌘T shortcuts, and keeps the default "New Window" suppressed — the
      // app shares one app-scoped `WindowState`, so a second window is a
      // half-baked surface.
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .sidebar) {
        Button(windowState.columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar") {
          windowState.toggleSidebar()
        }
        .keyboardShortcut("s", modifiers: [.command, .option])

        Button(windowState.isItemListHidden ? "Show List" : "Hide List") {
          windowState.toggleItemList()
        }
        .keyboardShortcut("l", modifiers: [.command, .option])
      }
      // #5b: runtime recovery for a Helper/engine that went down or
      // unreachable mid-session — reloads the launchd registration and
      // re-starts the engine without a full app restart. Always reachable
      // from the menu even when the in-window UI is wedged.
      CommandGroup(after: .help) {
        Button("Restart Engine") { restartEngine() }
        // #358: user-reachable diagnostics. Runs the bundled
        // collect-diagnostics.sh and reveals the redacted .zip in Finder.
        Button("Collect Diagnostics…") {
          Task { await DiagnosticsCollector.collectAndReveal() }
        }
      }
      #if DEBUG
      CommandMenu("Debug") {
        Button("Reset Onboarding State") {
          appPreferences.resetFirstLaunchWizard()
        }
        .keyboardShortcut("r", modifiers: [.command, .control, .option])

        // S511 GUI seam: a deterministic in-process window resize. XCUITest
        // cannot resize reliably from the outside — Window ▸ Zoom no-ops when
        // the window is maximized, a synthesized corner-drag misses the resize
        // border, and the public Accessibility set-size API is APIDisabled for
        // the test runner. Shrinking the key window's width here (floored at
        // the 900pt minimum) drives the split-view relayout the geometry guard
        // needs, and a menu click is the one resize trigger XCUITest fires
        // reliably.
        Button("Shrink Window (Test)") {
          guard let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }
          var frame = window.frame
          frame.size.width = max(900, frame.size.width - 200)
          window.setFrame(frame, display: true, animate: false)
        }
      }
      #endif
    }

    Settings {
      SettingsRoot()
        .environmentObject(settingsNavigation)
        .environmentObject(modelLoadCenter)
        .environmentObject(appPreferences)
        .environmentObject(profileStore)
        .environmentObject(swapCoordinator)
        .environmentObject(engineClientStore)
        .environmentObject(downloadController)
        .environmentObject(modelLibrary)
        .environmentObject(persistenceStatus)
        .environmentObject(engineStatusStore)
        .environmentObject(guardrailRevision)
        .environmentObject(specMetricsStore)
    }
  }
}

#if DEBUG
/// Minimal `AppXPCClient` for the helperless S302 GUI harness
/// (`PIE_TEST_PIN_ENGINE_RUNNING`). The harness has no Helper to answer
/// XPC, so a real `stopEngine()` during Unload would throw and
/// `ChatScaffoldView.unloadModel` would never run `markUnloaded()`. This
/// reports the pinned `.running` status and treats `stopEngine()` as a
/// no-op success, so the Unload confirm path completes to `.idle`. DEBUG
/// only — compiled out of Release alongside the pin itself.
private final class PinnedRunningXPCClient: AppXPCClient, @unchecked Sendable {
  private let port: EnginePort
  private let lock = NSLock()
  private var servedModelID: String

  init(port: EnginePort, servedModelID: String) {
    self.port = port
    self.servedModelID = servedModelID
  }

  func helperProtocolVersion() async throws -> Int { HelperProtocolCompatibility.currentVersion }
  func engineStatus() async throws -> EngineStatus {
    lock.lock()
    let model = servedModelID
    lock.unlock()
    return .running(EngineSessionSnapshot(port: port,
                                          profileID: "chat",
                                          servedModelID: model))
  }

  func stopEngine() async throws {}
  // The pinned harness has no Helper to launch an engine; the engine is
  // already pinned `.running`, so a start is a no-op success (mirrors
  // `stopEngine`).
  func startEngine(profileID: String, modelOverride: String?) async throws {
    updateServedModel(modelOverride)
  }

  func restartEngine(profileID: String, modelOverride: String?) async throws {
    updateServedModel(modelOverride)
  }

  private func updateServedModel(_ modelOverride: String?) {
    guard let modelOverride, !modelOverride.isEmpty else { return }
    lock.lock()
    servedModelID = modelOverride
    lock.unlock()
  }
}

/// #381: helperless `AppXPCClient` whose engine starts `.stopped` and flips to
/// `.running(port)` the first time the App calls `startEngine` — the GUI seam
/// for the no-model → Load-default follow-through. It models the single fact
/// the absent Helper would report across a `pie serve` start (stopped →
/// running) so the send gate's Load button drives a deterministic engine start
/// with NO real Helper or engine. `stopEngine` flips it back so the path is
/// repeatable within a launch. DEBUG only — compiled out of Release alongside
/// its `PIE_TEST_ENGINE_START_TO_RUNNING` flag.
private final class StartableStubXPCClient: AppXPCClient, @unchecked Sendable {
  private let port: EnginePort
  private let lock = NSLock()
  private var started = false

  init(port: EnginePort) { self.port = port }

  func helperProtocolVersion() async throws -> Int { HelperProtocolCompatibility.currentVersion }

  func engineStatus() async throws -> EngineStatus {
    lock.lock(); defer { lock.unlock() }
    return started ? .running(EngineSessionSnapshot(port: port, profileID: "chat")) : .stopped
  }

  func startEngine(profileID: String, modelOverride: String?) async throws {
    lock.lock(); started = true; lock.unlock()
  }

  func restartEngine(profileID: String, modelOverride: String?) async throws {
    lock.lock(); started = true; lock.unlock()
  }

  func stopEngine() async throws {
    lock.lock(); started = false; lock.unlock()
  }
}
#endif
