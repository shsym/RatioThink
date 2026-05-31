import SwiftUI
import SwiftData
import ServiceManagement

@main
struct RatioThinkApp: App {
  /// One-shot guard so the launch-time Helper registration reconcile
  /// runs once even if a second window opens.
  @MainActor private static var didReconcileHelperRegistration = false
  @StateObject private var windowState = WindowState()
  @StateObject private var endpointStore = EndpointStore()
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
  @StateObject private var engineClientStore: EngineClientStore
  /// Phase 3.8 (review v2 F1): the Add Model sheet's `.queueDownload`
  /// outcome runs through this controller so the existing
  /// `ModelDownloader` is actually invoked. Lives at app scope so
  /// closing + reopening the Settings sheet does not orphan an
  /// in-flight download.
  @StateObject private var downloadController: ModelDownloadController

  @MainActor
  init() {
    Self.writeArtifactPathProbeIfRequested()

    // Build the four dependencies value-side so the coordinator can
    // borrow them at construction. The `@StateObject` wrappers aren't
    // installed on `self` at `init` time, so a re-instantiation here
    // is the only place identity can be threaded.
    let center = ModelLoadCenter()
    let prefs = AppPreferences(defaults: Self.appPreferencesDefaults())
    let testBaseURL = Self.chatTestEngineBaseURL()
    let statusStore: EngineStatusStore
    if let testBaseURL {
      // Probe the wrapper-booted engine for status (not the absent Helper) so
      // the chat model-menu reconcile, gated on `.running`, fetches /v1/models.
      statusStore = EngineStatusStore(client: TestEngineStatusXPCClient(baseURL: testBaseURL))
    } else {
      statusStore = EngineStatusStore(client: HelperXPCClient())
    }
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
    _engineClientStore = StateObject(wrappedValue: EngineClientStore(client: engine))
    _swapCoordinator = StateObject(wrappedValue: ProfileSwapCoordinator(
      center: center,
      engine: engine,
      profileStore: store
    ))
    _downloadController = StateObject(wrappedValue: Self.makeDownloadController())

    _persistenceStatus = StateObject(wrappedValue: status)
    chatContainer = RatioThinkModelContainer.openWithFallback(status: status)

    // Kick the XPC poll loop. Idempotent + cheap — first reply lands
    // within ~one runloop tick when the helper is registered, longer
    // when launchd has not yet published the mach service.
    statusStore.start()
  }

  private static func chatTestEngineBaseURL() -> URL? {
    // Gated through HelperConfig so a Release build ignores the override
    // entirely — both this read and the `TestEngineStatusXPCClient` status
    // branch key off the result, so a non-debug app falls back to the real
    // Helper-driven engine path (`HelperXPCClient()`) and never honors the
    // `PIE_TEST_ENGINE_BASE_URL` seam.
    guard let raw = HelperConfig.testEngineBaseURLOverride() else { return nil }
    return URL(string: raw)
  }

  /// `AppXPCClient` that derives engine status by probing a fixed base URL
  /// (`PIE_TEST_ENGINE_BASE_URL`) instead of the Helper XPC. The e2e wrapper
  /// boots the engine and exports its URL; no Helper runs on this path, so
  /// polling the Helper would pin status at `.starting` and the chat
  /// model-menu reconcile (gated on `.running`) would never fetch
  /// `/v1/models`. A reachable engine maps to `.running(port:)` — which the
  /// reconcile needs to surface the served model; a stale/unreachable URL
  /// (S279) makes the probe throw → status is NOT `.running`, preserving the
  /// recoverable-error path. Lifecycle is owned by the wrapper, so
  /// `stopEngine()` is a no-op.
  private struct TestEngineStatusXPCClient: AppXPCClient {
    let baseURL: URL

    func engineStatus() async throws -> EngineStatus {
      var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
      request.timeoutInterval = 2
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let port = baseURL.port, let enginePort = EnginePort(exactly: port) else {
        throw AppXPCClientError.replyTimeout(
          selector: "engineStatus(probe \(baseURL.absoluteString))", timeout: 2)
      }
      return .running(port: enginePort, profileID: "chat")
    }

    func stopEngine() async throws {}
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

    // A test/automation launch must NOT construct the real registrar or
    // run SMAppService.unregister()/register() — that mutates the real
    // machine's background-item registration. GUI helpers set only
    // PIE_TEST_FIRST_LAUNCH_COMPLETED / PIE_APP_PREFERENCES_SUITE, so the
    // skip set must cover those launch seams too (F1).
    guard !HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment) else {
      return
    }

    let registrar = SMAppServiceLoginItemRegistrar()
    let reconciler = HelperRegistrationReconciler(
      probeReachable: { await Self.helperReachable() },
      currentState: { registrar.status.reconcilerState },
      register: { try registrar.register().reconcilerState },
      unregister: { try registrar.unregister() }
    )
    let outcome = await reconciler.reconcile()
    NSLog("RatioThinkHelper registration reconcile: \(outcome)")
    if case .needsApproval = outcome {
      // Hard macOS consent gate — route the user to the toggle.
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  /// Returns true as soon as the Helper answers an `engineStatus()` XPC
  /// call, retrying over a bounded window so a just-launched (or
  /// just-reloaded) on-demand Helper has time to publish its mach
  /// service. ~5s worst case.
  private static func helperReachable(attempts: Int = 8,
                                      delayMilliseconds: UInt64 = 600) async -> Bool {
    let client = HelperXPCClient()
    for attempt in 0..<attempts {
      if (try? await client.engineStatus()) != nil { return true }
      if attempt < attempts - 1 {
        try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
      }
    }
    return false
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
    WindowGroup("RatioThink") {
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
        .environmentObject(endpointStore)
        .environmentObject(modelLoadCenter)
        .environmentObject(appPreferences)
        .environmentObject(profileStore)
        .environmentObject(swapCoordinator)
        .environmentObject(engineClientStore)
        .environmentObject(persistenceStatus)
        .environmentObject(engineStatusStore)
        .environmentObject(downloadController)
        .frame(minWidth: 900, minHeight: 600)
    }
    .modelContainer(chatContainer)
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Chat") {}.keyboardShortcut("n")
        Button("New Chat (Always)") {}.keyboardShortcut("t")
      }
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
    }

    Settings {
      SettingsRoot()
        .environmentObject(endpointStore)
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
