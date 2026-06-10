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
  /// Phase 3.8 (review v2 F1): the Add Model sheet's `.queueDownload`
  /// outcome runs through this controller so the existing
  /// `ModelDownloader` is actually invoked. Lives at app scope so
  /// closing + reopening the Settings sheet does not orphan an
  /// in-flight download.
  @StateObject private var downloadController: ModelDownloadController
  /// #411: once-per-launch GitHub-Releases update check. App-scoped so the
  /// check (and its single network call) fires once per process; RootView
  /// observes `pending` to render the non-modal update banner.
  @StateObject private var updateAvailability = UpdateAvailabilityModel()
  @StateObject private var settingsNavigation = SettingsNavigation()

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
    let statusStore: EngineStatusStore
    #if DEBUG
    // DEBUG-only GUI-harness seam (S302): a pure-HTTP mock engine answers
    // `/v1/...` but has NO Helper to report status over XPC, so the
    // model-menu `/v1/models` reconcile (gated on `.running`) would
    // otherwise empty the menu. When `PIE_TEST_PIN_ENGINE_RUNNING` is set
    // alongside the base-URL bypass, pin `EngineStatus.running(port:)` —
    // the one fact the absent Helper would report, and one the harness
    // genuinely satisfies (`.running`'s downstream contract is "an inferlet
    // serves `/v1/...` on this port"). Scoped to its OWN flag, NOT every
    // `PIE_TEST_ENGINE_BASE_URL` launch: the lifecycle-recovery suite
    // (S279) drives real status transitions and must keep polling.
    // `#if DEBUG` so the flag + pin compile out of Release entirely; the
    // S302 GUI suite runs the Debug build.
    let pinnedRunningPort: EnginePort? = {
      guard ProcessInfo.processInfo.environment["PIE_TEST_PIN_ENGINE_RUNNING"] == "1",
            let rawPort = testBaseURL?.port,
            let port = EnginePort(exactly: rawPort) else { return nil }
      return port
    }()
    // #381: a SECOND helperless GUI seam, distinct from the pinned-running pin
    // above. The no-model → Load-default follow-through needs the engine to
    // start STOPPED so the send gate raises its Load affordance, then become
    // `.running` the instant the user taps Load — without a real Helper or
    // `pie serve` (the heavy, seated-session-flaky start that wedged the path).
    // The stub reports `.stopped` until `startEngine` is called, then
    // `.running(port)` — the one fact the absent Helper would report once the
    // engine is up — pointed at the same mock base URL. Its own DEBUG flag so a
    // pinned-running launch (S302/S486) is unaffected.
    let startToRunningPort: EnginePort? = {
      guard ProcessInfo.processInfo.environment["PIE_TEST_ENGINE_START_TO_RUNNING"] == "1",
            let rawPort = testBaseURL?.port,
            let port = EnginePort(exactly: rawPort) else { return nil }
      return port
    }()
    if let pinnedRunningPort {
      // Inject a stub XPC client (NOT HelperXPCClient): the helperless
      // harness has no Helper, so a real stopEngine() during Unload would
      // throw and ChatScaffoldView.unloadModel would never reach
      // markUnloaded() — the model would stay resident. The stub reports
      // the pinned running status and accepts stopEngine as a no-op so
      // the Unload confirm path completes to .idle (#359 Path2).
      statusStore = EngineStatusStore(
        client: PinnedRunningXPCClient(port: pinnedRunningPort),
        initialStatus: .running(EngineSessionSnapshot(port: pinnedRunningPort, profileID: "chat"))
      )
    } else if let startToRunningPort {
      statusStore = EngineStatusStore(
        client: StartableStubXPCClient(port: startToRunningPort),
        initialStatus: .stopped
      )
    } else {
      statusStore = EngineStatusStore(client: HelperXPCClient())
    }
    #else
    statusStore = EngineStatusStore(client: HelperXPCClient())
    #endif
    //  wire-in completed by : `HTTPEngineClient.baseURLProvider`
    // resolves `EngineStatusStore.requireBaseURL()` on each request.
    // Returns `http://127.0.0.1:<port>` when the helper reports
    // `EngineStatus.running(port:_)`, throws `engineNotReady` (with
    // the current human-readable status detail) otherwise. The
    // weak-store capture matches the rest of the GUI's lifetime model
    // — `RatioThinkApp` outlives every subsystem so the closure realistically
    // never finds `nil`, but the explicit guard keeps the failure
    // mode an `engineNotReady` rather than a force-unwrap crash if a
    // future refactor lets the store deinit early.
    let engine: EngineClient
    if let testBaseURL {
      engine = HTTPEngineClient(baseURL: testBaseURL)
    } else {
      engine = HTTPEngineClient(
        baseURLProvider: { [weak statusStore] in
          guard let store = statusStore else {
            throw HTTPEngineError.engineNotReady(
              detail: "EngineStatusStore deallocated"
            )
          }
          return try await MainActor.run { try store.requireBaseURL() }
        }
      )
    }
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
    _downloadController = StateObject(wrappedValue: Self.makeDownloadController())

    _persistenceStatus = StateObject(wrappedValue: status)
    chatContainer = RatioThinkModelContainer.openWithFallback(status: status)

    // #412: App-side helper-health restart ladder. The repair runs the
    // runtime registration reconcile; a test/automation launch gets a no-op
    // repair so a GUI run never mutates the real machine's SMAppService
    // background-item registration (same guard the launch reconcile uses).
    let helperRepair: () async -> Bool
    if HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment) {
      helperRepair = { false }
    } else {
      helperRepair = { await HelperRegistrationRepair().repairAndReportReachable() }
    }
    // #496 DEBUG GUI seam: pin the helper-health ladder to a fixed state so the
    // chat-body recovery overlay's states (starting / unreachable / hidden)
    // render deterministically without a real background helper — sibling of
    // `PIE_TEST_PIN_ENGINE_RUNNING`. Compiled out of Release.
    #if DEBUG
    let pinnedHelperHealth = Self.pinnedHelperHealthForTesting()
    #else
    let pinnedHelperHealth: HelperHealth? = nil
    #endif
    let helperHealthController = HelperHealthController(
      repair: helperRepair,
      pinnedHealth: pinnedHelperHealth
    )
    // Drive the ladder from the SAME poll the status mirror runs — no second
    // XPC surface. Set BEFORE statusStore.start() so the first ticks count.
    statusStore.onPollOutcome = { [weak helperHealthController] succeeded in
      helperHealthController?.ingestPollOutcome(succeeded: succeeded)
    }
    // #412 review F1: let the chat recovery wait bound itself by the ladder
    // outcome (give up the moment the ladder hits .unreachable) instead of a
    // fixed timeout chosen out of sync with the ladder cadence.
    statusStore.helperHealthProvider = { [weak helperHealthController] in
      helperHealthController?.health
    }
    _helperHealth = StateObject(wrappedValue: helperHealthController)

    // #448: give the full-product quit coordinator the poll loop it must stop
    // before tearing down, so no late on-demand poll respawns the Helper.
    AppQuitCoordinator.shared.engineStatusStore = statusStore

    // Kick the XPC poll loop. Idempotent + cheap — first reply lands
    // within ~one runloop tick when the helper is registered, longer
    // when launchd has not yet published the mach service.
    #if DEBUG
    // Skipped when status is pinned for the S302 harness (no Helper to poll; a
    // failed poll would reset the pinned `.running` → `.starting`), and for the
    // #496 helper-health pin (a failed/successful poll would move the pinned
    // ladder and could flip the engine off `.starting`, both of which would
    // make the overlay state nondeterministic).
    if pinnedRunningPort == nil && pinnedHelperHealth == nil {
      statusStore.start()
    }
    #else
    statusStore.start()
    #endif
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
    guard let raw = HelperConfig.testEngineBaseURLOverride() else { return nil }
    return URL(string: raw)
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
    return defaults
  }

  private static func makeDownloadController() -> ModelDownloadController {
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
        .environmentObject(engineClientStore)
        .environmentObject(persistenceStatus)
        .environmentObject(engineStatusStore)
        .environmentObject(engineLifecycle)
        .environmentObject(helperHealth)
        .environmentObject(downloadController)
        .environmentObject(updateAvailability)
        .environmentObject(settingsNavigation)
        // #420: route the menu-bar Helper's `ratiothink://settings` deep
        // link straight to the Settings scene (not just app-foreground).
        .handlesSettingsDeepLink()
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
        .environmentObject(persistenceStatus)
        .environmentObject(engineStatusStore)
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
private struct PinnedRunningXPCClient: AppXPCClient {
  let port: EnginePort
  func helperProtocolVersion() async throws -> Int { HelperProtocolCompatibility.currentVersion }
  func engineStatus() async throws -> EngineStatus { .running(EngineSessionSnapshot(port: port, profileID: "chat")) }
  func stopEngine() async throws {}
  // The pinned harness has no Helper to launch an engine; the engine is
  // already pinned `.running`, so a start is a no-op success (mirrors
  // `stopEngine`).
  func startEngine(profileID: String, modelOverride: String?) async throws {}
  func restartEngine(profileID: String, modelOverride: String?) async throws {}
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
