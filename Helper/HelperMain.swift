import AppKit
import QuartzCore
import os

/// Engine-death (D2) — the auto-relaunch closure handed to
/// `PieEngineHost` needs the HelperAppDelegate's profileStore +
/// resolver but must NOT keep the delegate alive past XPC
/// teardown. The holder is a weak indirection: the closure
/// captures it, dereferences `helper` (which is itself weak), and
/// no-ops if the helper has been released.
///
/// `@unchecked Sendable`: the closure that captures this is
/// `@Sendable` (invoked off `PieEngineHost.stateQueue`), but every
/// access to `helper` is confined to the main queue — `helper` is
/// assigned once on the main thread during `startXPCListener` boot
/// and read only inside the relauncher's `DispatchQueue.main.async`
/// block. The compiler cannot prove that confinement, so the promise
/// is annotated rather than checked.
private final class HelperResumeHolder: @unchecked Sendable {
  weak var helper: HelperAppDelegate?
}

@main
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem?

  /// Status-bar menu items mutated by `applyStatusItemModel` as the
  /// supervisor publishes state transitions. Built once in
  /// `setupStatusItem`; kept here so the observer's main-thread hop
  /// can rewrite titles + enabled state without rebuilding the menu.
  private var engineLabelMenuItem: NSMenuItem?
  private var pauseResumeMenuItem: NSMenuItem?

  /// Observation handle for `PieEngineHost.observe`. Dropping it
  /// removes the observer (ObservationToken.deinit cancels). Lives
  /// for the helper's lifetime by default; cleared in
  /// `applicationWillTerminate` so the observer does not fire into
  /// a tearing-down AppKit graph.
  private var engineHostObservation: PieEngineHost.ObservationToken?

  /// Retains the XPC listener once `startXPCListener` has run. Stored
  /// here because dropping the owner tears the listener down.
  private var xpcListener: HelperXPCListener?

  /// Production engine manager ( — replaces the stale
  /// `PieSupervisor` argv path with `PieControlLauncher`).
  /// Constructed once per healthy helper boot and threaded into
  /// `HelperExportedAPI` so `engineStatus` / `startEngine` /
  /// `stopEngine` plumb through the live subprocess. Nil under
  /// degraded mode — `DegradedHelperAPI` does not spawn engines.
  private var engineHost: PieEngineHost?

  /// Phase 2.4 profile store. Owns the on-disk profiles directory
  /// watcher (Phase 2.4 ) and the persisted active-profile id.
  /// Nil under degraded mode. Held here so the FS watcher's
  /// `DispatchSource` stays armed for the helper's lifetime.
  private var profileStore: ProfileStore?

  /// Cached LaunchSpec resolver used by the in-process menu-bar
  /// `Resume` action. Mirrors the closure handed to
  /// `HelperExportedAPI` so the helper itself can resolve the
  /// active profile without re-opening an XPC client. Nil under
  /// degraded mode or when neither production nor smoke wiring
  /// produced a resolver.
  private var launchSpecResolver: HelperExportedAPI.LaunchSpecResolver?

  /// Set by `eagerProbePieDirs` when the configured PIE_HOME cannot be
  /// created. Once true, the helper publishes an *error* status item
  /// instead of the normal one, skips login-item registration, and
  /// presents an alert when the user clicks. Replaces the silent
  /// "continue with a beep" failure mode (review v4 F4).
  private var degradedReason: PieDirsError?

  /// Test seam over the `NSWorkspace` app-launch `openPieApp` performs.
  /// Production leaves it `nil` and the real `NSWorkspace.shared`
  /// launches/foregrounds the resolved parent bundle (delivering any
  /// deep-link URLs). A unit test sets it to capture `(urls, appURL)` and
  /// assert that the menu-bar "Settings…" item delivers exactly
  /// `[SettingsDeepLink.settingsURL]` to `resolvedPieAppURL()` — the wiring
  /// that otherwise silently degrades to a plain app-foreground on a refactor
  /// (#440). A settable property rather than a constructor-injected closure
  /// (the idiom for `PieSupervisor.killProcessOverride`) because
  /// `HelperAppDelegate` is `@main`-constructed with no init seam; `nil` in
  /// production keeps the real launch path untouched.
  var workspaceOpenOverride: ((_ urls: [URL], _ appURL: URL) -> Void)?

  static func main() {
    let app = NSApplication.shared
    let delegate = HelperAppDelegate()
    app.delegate = delegate
    app.run()
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    // When this helper hosts the #440 RatioThinkHelperTests unit bundle its
    // code is loaded in-process, and the real boot would otherwise run: status
    // item, login-item registration, and the XPC-listener bind whose
    // `verifyStartupInvariants` hard-traps under the ad-hoc-signed test host
    // (no Team Identifier). XCTest's own `XCTestConfigurationFilePath` marker is
    // injected only AFTER launch, too late for this boot path, so the test
    // scheme sets this env var instead — scheme env is present from launch. It
    // is never set in production or by the App-spawned helper subprocess, so
    // this skips boot ONLY under the unit-test scheme.
    if ProcessInfo.processInfo.environment["PIE_TEST_HELPER_NO_BOOT"] == "1" {
      Log.helper.info("PIE_TEST_HELPER_NO_BOOT=1; skipping helper boot (unit-test host)")
      return
    }
    HelperConfig.assertStartupContract()
    Log.helper.info("RatioThinkHelper launched (xpc=\(HelperConfig.xpcServiceName, privacy: .public) testMode=\(HelperConfig.isTestMode, privacy: .public))")
    let info = Bundle.main.infoDictionary
    Diag.helper.event("helper.launch", [
      ("version", info?["CFBundleShortVersionString"] as? String ?? "?"),
      ("build", info?["CFBundleVersion"] as? String ?? "?"),
      ("pid", String(ProcessInfo.processInfo.processIdentifier)),
      ("bundle", DiagnosticLog.redactHome(Bundle.main.bundleURL.path)),
      ("executable", DiagnosticLog.redactHome(Bundle.main.executableURL?.path ?? "?")),
    ])
    eagerProbePieDirs()
    setupStatusItemIfNeeded()
    registerLoginItemIfNeeded()
    startXPCListener()

    // Auto-present the startup error so a non-technical user notices
    // immediately instead of having to discover and click the
    // exclamation-triangle status item (review v5 F6). Status item
    // remains as the ongoing reminder. Dispatched async so the runloop
    // is up before we beginSheetModalForWindow.
    if let reason = degradedReason {
      Diag.helper.event("helper.degraded", [("reason", "\(reason)")])
      DispatchQueue.main.async { [weak self] in
        self?.presentPieDirsAlert(title: "Rational cannot start", error: reason)
      }
    }
  }

  /// `NSApplicationDelegate` lifecycle hook for graceful termination
  /// paths only. Fires on `NSApp.terminate` and the SIGTERM
  /// AppKit-installs-a-handler-for via the main runloop. Tears the
  /// XPC listener down so the mach service is unpublished cleanly —
  /// peers racing the teardown see `NSXPCConnectionInvalid` instead
  /// of a half-published stale registration (review v4 F2).
  ///
  /// What this hook does NOT cover (review v5 F3):
  ///  · SIGKILL (including the SIGKILL `launchctl bootout` sends ~5s
  ///    after its SIGTERM; if the helper is mid-init the SIGKILL
  ///    fires before the runloop can drain the SIGTERM)
  ///  · SIGABRT / SIGSEGV / SIGBUS / `os_unfair_lock` aborts
  ///  · Swift runtime traps (`fatalError`, `preconditionFailure`)
  ///  · `exit(_:)` direct calls — including
  ///    `transitionToDegradedOrTerminate`'s `exit(EXIT_FAILURE)`,
  ///    which therefore calls `xpcListener.invalidate()` inline
  ///    instead of relying on this hook.
  func applicationWillTerminate(_ note: Notification) {
    Diag.helper.event("helper.quit", [
      ("reason", "applicationWillTerminate"),
      ("pid", String(ProcessInfo.processInfo.processIdentifier)),
    ])
    // Order matters here (review v1 F1):
    //   1. Cancel the supervisor observer FIRST and nil out the
    //      status item so the `guard` in `applyStatusItemModel`
    //      short-circuits any blocks the observer already enqueued
    //      on main via `DispatchQueue.main.async`. `ObservationToken.cancel()`
    //      alone only unregisters from the observers dict — it
    //      cannot invalidate work already sitting on main's queue.
    //   2. Then stop the supervisor (SIGTERM the child).
    //   3. Then invalidate the XPC listener.
    //
    // The pre-F1 ordering (stop → cancel observer → invalidate)
    // let a late `.stopping → .stopped` transition hop onto main
    // and touch menu items mid-teardown.
    engineHostObservation?.cancel()
    engineHostObservation = nil
    // Drop the status item BEFORE engineHost.stop() so any block
    // already queued on main hits the nil-guard in
    // applyStatusItemModel and no-ops cleanly. Order vs cancel()
    // is "either is fine" — both protect the same invariant.
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
    engineLabelMenuItem = nil
    pauseResumeMenuItem = nil
    // Caveats from the listener doc-comment about which termination
    // paths reach this hook still apply — SIGKILL/SIGABRT/exit(_:)
    // skip the helper teardown entirely, in which case launchd
    // reaps the child via process-group cleanup.
    // A graceful helper teardown takes the engine with it; preserve both the
    // durable shutdown reason and the initiator so diagnostics distinguish this
    // from an operator Pause.
    engineHost?.stop(reason: "helper.applicationWillTerminate", initiator: .helper)
    profileStore?.stop()
    profileStore = nil
    if let xpcListener {
      xpcListener.invalidate()
    }
    xpcListener = nil
  }

  /// Force-creates the Rational root + logs subdir. On failure, records the
  /// error in `degradedReason` so downstream setup branches degrade
  /// gracefully instead of registering a broken helper for relaunch
  /// or publishing a no-op status item (review v4 F4).
  private func eagerProbePieDirs() {
    do {
      _ = try PieDirs.applicationSupport()
      _ = try PieDirs.logs()
    } catch let error as PieDirsError {
      Log.helper.error("eagerProbePieDirs failed: \(String(describing: error), privacy: .public)")
      degradedReason = error
    } catch {
      // Don't invent a fake `<unknown>` path — that misleads the
      // Reveal-in-Finder affordance + the alert body (review v5 F8).
      // Surface the raw error message via the explicit .unknown case.
      Log.helper.error("eagerProbePieDirs unexpected error: \(String(describing: error), privacy: .public)")
      degradedReason = .unknown(underlying: String(describing: error))
    }
  }

  /// Status bar publishes a menu-bar UI item — system-visible side  // lint:allow-side-effect: doc-comment, no call here
  /// effect that a parallel test helper must not take. Routed through
  /// the choke point so the lint script and the runtime gate agree.
  private func setupStatusItemIfNeeded() {
    if HelperConfig.isTestMode {
      Log.helper.info("PIE_TEST_MODE=1; skipping NSStatusBar status item")
      return
    }
    HelperConfig.assertSystemSideEffectAllowed("NSStatusBar.statusItem")
    if degradedReason != nil {
      setupDegradedStatusItem()
    } else {
      setupStatusItem()
    }
  }

  /// Starts the XPC listener that publishes `HelperConfig.xpcServiceName`
  /// (canonical `com.ratiothink.helper`, or a test-unique name when the
  /// `PIE_XPC_SERVICE` override is in effect).
  ///
  /// Degraded mode (review v1 F12): when `degradedReason` is set, the
  /// listener still publishes — but vends a `DegradedHelperAPI` that
  /// returns `EngineError(.degraded, message: <PieDirsError>)` on
  /// every selector. A GUI that connects sees a *structured cause*
  /// instead of a mach-service-not-found, so the UI can render the
  /// real reason even if the parallel "Rational cannot start" alert path
  /// fails.
  ///
  /// Pre-bind: `HelperXPCListener.verifyStartupInvariants()` opens a
  /// same-process probe to confirm the KVC `auditToken` extraction
  /// still produces a properly-sized token and our own Team ID is
  /// readable (review v1 F5 + F11). Test-mode helpers skip this
  /// probe — they have no signed identity.
  ///
  /// Post-bind: `verifyMachServiceReachable` opens an in-process
  /// `NSXPCConnection(machServiceName:)` and pings `engineStatus`
  /// within a launch deadline (review v1 F13). If launchd never
  /// published the service the ping fails and the helper transitions
  /// to degraded mode so the GUI's later connect attempt at least
  /// gets a structured `EngineError(.degraded)`.
  private func startXPCListener() {
    // Validate KVC + self-identity invariants before touching the
    // listener. Fails loudly here instead of silently rejecting every
    // production connection later.
    HelperXPCListener.verifyStartupInvariants()

    let exported: PieHelperXPC
    if let reason = degradedReason {
      Log.helper.error("publishing degraded XPC listener (reason=\(String(describing: reason), privacy: .public))")
      exported = DegradedHelperAPI(reasonMessage: String(describing: reason),
                                   onQuitRequested: Self.terminateSelf)
    } else {
      // : PieEngineHost replaces PieSupervisor on the
      // production helper boot path. Lazily constructed (not in
      // init) so degraded helpers never spawn the host they cannot
      // use.
      //
      // Engine-death recovery (D2): the host's bounded auto-relaunch
      // ladder fires on `.failed(.engineGone)`, but the host itself
      // is profile-agnostic — the closure below routes the relaunch
      // back through the same `HelperResumeAction` policy a
      // user-clicked Pause/Resume would take, so the auto path and
      // the manual path always reach the engine via one funnel.
      // `HelperResumeHolder` carries a `weak var helper` that the
      // closure dereferences to reach the live HelperAppDelegate.
      // The closure captures `holder` STRONGLY so the holder outlives
      // this function — the local `let` at the line below is the only
      // other strong owner and goes out of scope at function return.
      // Cycle safety: HelperMain -> engineHost -> RelaunchPolicy
      // closure -> holder -[weak]-> HelperMain. The weak edge inside
      // the holder breaks the cycle; capturing the holder weakly
      // here would deallocate it at function return and silently
      // disable every later relaunch (review v1 F1).
      let holder = HelperResumeHolder()
      let host = PieEngineHost(
        relauncher: { [holder] in
          // Off-stateQueue. Hop onto the main queue so the read of
          // `helper.profileStore` / `helper.launchSpecResolver` is
          // serialized against the boot-time writers and the
          // togglePauseResume click path. HelperResumeAction.run is
          // synchronous and quick (no I/O); it queues a fresh
          // PieEngineHost launch task and returns.
          DispatchQueue.main.async {
            guard let helper = holder.helper else { return }
            guard let engineHost = helper.engineHost else { return }
            // #395 + review v3 N3: the veto→run composition is now the
            // SPM-reachable `HelperResumeAction.composeAutoRelaunch`, so
            // deleting the veto fails a unit test (it was the exact
            // untestable boundary that hid the #299 v1 F1 blocker). This
            // closure keeps ONLY the AppKit-bound bits: the main-queue hop,
            // the `HelperResumeHolder` deref, and the log lines. Veto
            // semantics are unchanged — `.failed` commits, anything else
            // (Pause won, user Resume already ran, in-flight start) vetoes.
            // See `Shared/HelperResumeAction.swift` for the full table.
            let decision = HelperResumeAction.composeAutoRelaunch(status: engineHost.status) {
              HelperResumeAction.run(
                engineHost: engineHost,
                profileStore: helper.profileStore,
                resolver: helper.launchSpecResolver
              )
            }
            switch decision {
            case .vetoed(let status):
              Log.helper.notice("auto-relaunch skipped: engineHost.status=\(String(describing: status), privacy: .public) at main-queue commit (user Pause or concurrent start landed during the deferred hop)")
            case .ran(let outcome):
              Log.helper.notice("auto-relaunch outcome: \(String(describing: outcome), privacy: .public)")
            }
          }
        },
        // #447: durable, chat-free engine death diagnostics. The sinks write
        // the `engine.terminated` breadcrumb (helper.log) + the bounded
        // redacted stderr tail (engine.log); the guardrail feeds the
        // likely-OOM heuristic (SIGKILL-not-by-us + last-RSS >= ceiling).
        terminationSink: PieEngineHost.productionTerminationSink,
        tailWriter: PieEngineHost.productionTailWriter,
        guardrailBytes: ModelMemoryGuardrail.defaultPolicy.maxResolvedModelBytes
      )
      holder.helper = self
      self.engineHost = host
      // Phase 2.4: stand up the profile-backed LaunchSpec
      // resolver. ProfileStore.start failures fall back to the
      // DEBUG smoke seam (or nil) so the helper still publishes its
      // XPC listener — `startEngine` reports `.profileMissing` /
      // `.spawnFailed` with a real cause instead of silently
      // refusing every selector.
      let resolver = buildLaunchSpecResolver()
      exported = HelperExportedAPI(engineHost: host,
                                   launchSpecResolver: resolver,
                                   onQuitRequested: Self.terminateSelf)
      // Phase 2.3: wire engine-host state into the menu-bar dot
      // once a healthy host exists. Degraded boots skip this — the
      // degraded status item is already published and must not be
      // overwritten by a misleading "Engine: stopped" render.
      subscribeToEngineHost(host)
      // Boot model-load is intentionally disabled: helper startup publishes
      // XPC/menu state and leaves the engine `.stopped`. Status delivery is
      // still poll-based via `engineStatus`, but the app can issue explicit
      // lifecycle requests through `EngineStatusStore.startEngine` for the
      // launch prompt/user confirmation, Restart, Local API, and post-download
      // recovery paths. Engine-crash auto-relaunch remains separate and is
      // wired through `HelperResumeAction` via `PieEngineHost`'s relauncher.
      autoResumeEngineOnBoot()
      #if DEBUG
      scheduleSmokeAutoDriveIfRequested(engineHost: host)
      #endif
    }
    xpcListener = HelperXPCListener.startMachService(exportedObject: exported)

    if degradedReason == nil && shouldRunPostResumeProbe() {
      verifyMachServicePublished()
    }
  }

  /// Skip the post-resume probe whenever the identity gate would
  /// reject the helper's own self-connection (review v2 F2). Two
  /// cases:
  ///  · `bypassReason() != nil` — listener captured a bypass, so any
  ///    peer including ourselves is accepted; the probe is redundant.
  ///  · `selfTeamIDResult() == .failure(.teamIDAbsent)` — ad-hoc-signed
  ///    build with no Team ID; the gate would reject self with
  ///    `.teamIDMismatch` AND we have no bypass. The probe would
  ///    then false-degrade every boot. Log the skip so an operator
  ///    can tell why no probe ran. `.securityFrameworkFailure` etc.
  ///    are still worth probing — verifyStartupInvariants already
  ///    trapped those, so reaching here means the framework is
  ///    healthy.
  private func shouldRunPostResumeProbe() -> Bool {
    if let bypass = CallerIdentity.bypassReason() {
      Log.helper.info("post-resume probe: skipped (bypass=\(bypass, privacy: .public))")
      return false
    }
    if case .failure(.teamIDAbsent) = CallerIdentity.selfTeamIDResult() {
      Log.helper.info("post-resume probe: skipped (selfTeamID absent — ad-hoc-signed build)")
      return false
    }
    return true
  }

  /// Post-resume reachability probe (review v1 F13). Opens a
  /// same-process `NSXPCConnection(machServiceName:)` and waits for an
  /// `engineStatus` reply within `launchDeadlineSeconds`. On failure
  /// the helper transitions to degraded mode so future connections
  /// receive a structured `EngineError(.degraded)` instead of a
  /// silent mach-service-not-found.
  ///
  /// Outcome state is `pending` until the FIRST callback transitions
  /// it (review v2 F4 — NSXPC routinely fires `errorHandler` AFTER a
  /// successful reply when the peer tears down, and the prior
  /// unconditional write let a trailing
  /// `NSXPCConnectionInterrupted` overwrite a healthy `.ok` and
  /// force a spurious degraded transition).
  private func verifyMachServicePublished() {
    let serviceName = HelperConfig.xpcServiceName
    let connection = NSXPCConnection(machServiceName: serviceName)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    let sem = DispatchSemaphore(value: 0)
    let outcome = OSAllocatedUnfairLock<MachReachability>(initialState: .pending)
    func setOnce(_ value: MachReachability) {
      let transitioned = outcome.withLock { (state: inout MachReachability) -> Bool in
        guard case .pending = state else { return false }
        state = value
        return true
      }
      if transitioned { sem.signal() }
    }
    let proxy = connection.remoteObjectProxyWithErrorHandler { err in
      setOnce(.error(String(describing: err)))
    }
    if let api = proxy as? PieHelperXPC {
      api.engineStatus { _ in setOnce(.ok) }
    } else {
      setOnce(.error("proxy does not conform to PieHelperXPC"))
    }

    let waited = sem.wait(timeout: .now() + launchDeadlineSeconds)
    let final = outcome.withLock { $0 }
    switch (waited, final) {
    case (.success, .ok):
      Log.helper.info("post-resume self-test: mach service \(serviceName, privacy: .public) reachable")
    case (.timedOut, _):
      Log.helper.fault("post-resume self-test: mach service \(serviceName, privacy: .public) ping timed out after \(self.launchDeadlineSeconds, privacy: .public)s — transitioning to degraded mode (launchd publication likely failed)")
      transitionToDegradedOrTerminate(reason: "XPC listener resumed but mach service ping timed out after \(launchDeadlineSeconds)s")
    case (_, .error(let message)):
      Log.helper.fault("post-resume self-test: mach service \(serviceName, privacy: .public) ping failed — \(message, privacy: .public)")
      transitionToDegradedOrTerminate(reason: "XPC listener resumed but mach service ping failed: \(message)")
    case (_, .pending):
      Log.helper.fault("post-resume self-test: outcome lock pending after wait — proxy never fired")
      transitionToDegradedOrTerminate(reason: "XPC listener resumed but post-resume probe never returned")
    }
  }

  /// Transition the live listener into degraded mode by swapping its
  /// exported object atomically (review v3 F1). The mach service
  /// registration stays in place — only the per-connection
  /// `exportedObject` future peers will be assigned changes.
  /// Eliminates the v2-era rebind path, which depended on
  /// `NSXPCListener.invalidate()` racing launchd's publish/unpublish
  /// step without any synchronization.
  ///
  /// Returns `true` when the swap took effect, `false` when there is
  /// no live listener to mutate (review v4 F1). Callers that
  /// promised "post-resume failure → helper serves .degraded" MUST
  /// treat `false` as a process-exit condition — silently returning
  /// here while logging would leave the helper serving nothing,
  /// breaking the documented invariant.
  @discardableResult
  private func transitionToDegraded(reason: String) -> Bool {
    guard let xpcListener else { return false }
    let degraded = DegradedHelperAPI(reasonMessage: reason,
                                     onQuitRequested: Self.terminateSelf)
    xpcListener.setExportedObject(degraded)
    return true
  }

  /// Caller-side wrapper that escalates a failed degraded transition
  /// into immediate process exit (review v4 F1). The previous code
  /// only logged when `xpcListener` was nil, silently violating the
  /// "post-resume failure → helper serves .degraded" contract.
  ///
  /// `exit(_:)` skips `applicationWillTerminate`, so we invalidate
  /// the listener (if any) inline (review v5 F1) — launchd needs the
  /// unpublish signal on the one path where publication is already
  /// known broken.
  ///
  /// PR12 review v1 F8: after a successful XPC-side degraded swap,
  /// also drive the local UI affordances (status-bar icon swap,
  /// startup alert, `degradedReason` ivar) so an operator inspecting
  /// the helper sees the failure without needing to attach an XPC
  /// peer. Dispatched on main because NSStatusBar / NSAlert are
  /// AppKit-main-thread-only.
  private func transitionToDegradedOrTerminate(reason: String) {
    guard transitionToDegraded(reason: reason) else {
      Log.helper.fault("transitionToDegraded had no listener to mutate (reason=\(reason, privacy: .public)) — terminating: a live listener serving .degraded is the only acceptable post-resume failure mode")
      Diag.helper.event("helper.quit", [
        ("reason", "degraded_transition_failed"),
        ("pid", String(ProcessInfo.processInfo.processIdentifier)),
      ])
      xpcListener?.invalidate()
      xpcListener = nil
      exit(EXIT_FAILURE)
    }
    DispatchQueue.main.async { [weak self] in
      self?.surfaceRuntimeDegraded(reason: reason)
    }
  }

  /// Idempotently swap the status item + present the alert once the
  /// XPC side has gone degraded at runtime. Repeated calls are
  /// no-ops because `degradedReason` is sticky and the reentry
  /// guard in `presentAlert` drops the second sheet.
  ///
  /// Delegated to `HelperDegradedSurface` (review v2 F32) so the
  /// state-mutation half is unit-testable in RatioThinkCoreTests without
  /// instantiating an `NSStatusBar`. Closures bridge back into the
  /// HelperAppDelegate's mutable AppKit state on the main actor.
  private func surfaceRuntimeDegraded(reason: String) {
    if degradedReason != nil { return }
    let surface = HelperDegradedSurface(
      setReason: { [weak self] err in self?.degradedReason = err },
      clearHealthyStatusItem: { [weak self] in
        guard let self else { return }
        if let item = self.statusItem {
          NSStatusBar.system.removeStatusItem(item)
          self.statusItem = nil
        }
      },
      presentDegradedStatusItem: { [weak self] in self?.setupDegradedStatusItem() },
      presentAlert: { [weak self] err in
        self?.presentPieDirsAlert(title: "Pie engine subsystem degraded", error: err)
      },
      isTestMode: { HelperConfig.isTestMode }
    )
    surface.apply(reason: reason)
  }

  private let launchDeadlineSeconds: TimeInterval = 5

  private enum MachReachability {
    case pending
    case ok
    case error(String)
  }

  /// SMAppService.loginItem is a process-wide, system-singleton side
  /// effect. Skipped in test mode AND when we're already degraded —
  /// re-registering a broken helper just makes the user reboot into
  /// the same broken state (review v4 F4).
  private func registerLoginItemIfNeeded() {
    if HelperConfig.isTestMode {
      Log.helper.info("PIE_TEST_MODE=1; skipping SMAppService.loginItem registration")
      return
    }
    if degradedReason != nil {
      Log.helper.error("degraded mode; skipping SMAppService.loginItem registration to avoid relaunch loop")
      return
    }
    HelperConfig.assertSystemSideEffectAllowed("SMAppService.loginItem")
    // TODO(phase-2): SMAppService.loginItem(identifier:).register() here.
  }

  private func setupStatusItem() {
    // Defense in depth — `setupStatusItemIfNeeded` should be the only
    // caller, but the gate lives here too so the lint script's
    // grep-and-window heuristic always finds an adjacent assertion.
    HelperConfig.assertSystemSideEffectAllowed("NSStatusBar.statusItem")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Show Rational",
                            action: #selector(showPie),
                            keyEquivalent: "0"))
    menu.addItem(.separator())

    // "Engine: …" — disabled status label that doubles as the
    // Phase 2.3 "current model/profile/port" slot. The S4 GUI test
    // pins the `Engine: stopped` string when the supervisor is in
    // `.stopped`; running state morphs it to
    // `Engine: running — <profile> @ port <port>`.
    let stateLabel = NSMenuItem(title: "Engine: stopped",
                                action: nil,
                                keyEquivalent: "")
    stateLabel.isEnabled = false
    menu.addItem(stateLabel)
    self.engineLabelMenuItem = stateLabel

    // Pause/Resume toggle. Title + enabled state are driven by
    // `applyStatusItemModel` from the live supervisor status.
    // `representedObject` carries the model's action discriminator
    // so the selector can branch without rebuilding the model.
    //
    // Review v1 F6: leave `target` unset (and thus the selector
    // unreachable) at construction. `applyStatusItemModel` re-sets
    // target=self ONLY when the model says `enabled=true`, so AX
    // scripting cannot reach the `.resume` no-op while the helper
    // is in a state that should be unclickable.
    let pauseResume = NSMenuItem(title: "Resume Engine",
                                 action: #selector(togglePauseResume(_:)),
                                 keyEquivalent: "")
    pauseResume.target = nil
    pauseResume.isEnabled = false
    menu.addItem(pauseResume)
    self.pauseResumeMenuItem = pauseResume

    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Settings…",
                            action: #selector(openSettings),
                            keyEquivalent: ","))
    menu.addItem(NSMenuItem(title: "Open Logs…",
                            action: #selector(openLogs),
                            keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Rational",
                            action: #selector(quitPie),
                            keyEquivalent: "q"))
    item.menu = menu
    self.statusItem = item
    Diag.helper.event("statusitem.create", [("kind", "normal")])

    // Review v1 F3: no synthetic `.stopped` initial render here.
    // `subscribeToSupervisor` registers an observer whose
    // initial-status dispatch fires synchronously onto `stateQueue`
    // (see `PieSupervisor.observe`), so the first paint reaches main
    // within one runloop turn — using the SUPERVISOR's actual state
    // rather than a guessed `.stopped`. A watchdog timer pins this
    // contract and logs a fault if no observer hop arrives within
    // `initialRenderDeadline`. Menu item titles default to "Engine:
    // stopped" / "Resume Engine" via the NSMenuItem inits above, so
    // the menu is readable in the gap.
    armInitialRenderWatchdog()
  }

  /// Maximum wait between `subscribeToSupervisor` and the observer's
  /// first main-thread paint. Beyond this, the supervisor-wiring
  /// contract has regressed; log a fault so the operator sees the
  /// gray-dot stuckness in `helper.log`.
  private static let initialRenderDeadlineSeconds: TimeInterval = 0.5

  /// Size of the bounded ring used by `subscribeToSupervisor`'s
  /// post-subscribe degraded-drop throttle (review v3 F24). Each
  /// distinct `EngineErrorCode` rawValue gets ONE fault-level log
  /// line while it remains in the ring; once evicted, the same code
  /// re-logs at fault on its next appearance. 8 is comfortably
  /// larger than the current `EngineErrorCode` discriminator count
  /// — the ring exists to defend against a future code explosion,
  /// not the present finite set.
  private static let failureCodeRingSize = 8

  /// Flips to true on the first `applyStatusItemModel` call from the
  /// supervisor observer; the watchdog timer reads this and stays
  /// silent if the contract held.
  private var receivedInitialStatusItemRender = false

  /// Set by the watchdog when it logs the missed-deadline fault.
  /// `applyStatusItemModel` reads this on the first paint and emits
  /// a paired `.info` recovery line so the operator does not see a
  /// dangling fault with no resolution (review v2 F13).
  private var initialRenderWatchdogFaulted = false

  private func armInitialRenderWatchdog() {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialRenderDeadlineSeconds) { [weak self] in
      guard let self else { return }
      if self.receivedInitialStatusItemRender { return }
      if self.degradedReason != nil {
        // Review v2 F14: a silent return made "contract held" and
        // "contract bypassed by degraded mode" indistinguishable in
        // helper.log. Log the skip at info so absence-of-fault is
        // itself documented.
        Log.helper.info("statusItem watchdog: skipped — degraded mode active at \(Self.initialRenderDeadlineSeconds, privacy: .public)s deadline")
        return
      }
      self.initialRenderWatchdogFaulted = true
      Log.helper.fault("statusItem: no observer paint within \(Self.initialRenderDeadlineSeconds, privacy: .public)s — supervisor wiring may have regressed; menu-bar dot remains image-less")
    }
  }

  /// Render a `HelperStatusItemModel` onto the live status item.
  /// Main-thread only — caller's responsibility (the supervisor
  /// observer hops via `DispatchQueue.main.async`). Delegates the
  /// per-field assignment to `HelperStatusItemBinding` so the
  /// ordering contract is locked by RatioThinkCoreTests without an
  /// `NSStatusBar` instance.
  private func applyStatusItemModel(_ model: HelperStatusItemModel) {
    guard statusItem != nil else {
      // Review v1 F2: a dropped render is now a load-bearing signal
      // — the only "impossible" path to here is an observer that
      // fires AFTER `applicationWillTerminate` nil'd the item, which
      // is benign teardown. Anything else (early-boot race, degraded
      // fallback never re-running setupStatusItem) means the
      // operator is staring at a stale dot with no idea why.
      Log.helper.error("statusItem dropped (no statusItem): dot=\(model.dot.rawValue, privacy: .public) label=\(model.engineLabel, privacy: .public)")
      return
    }
    let firstPaint = !receivedInitialStatusItemRender
    receivedInitialStatusItemRender = true
    // Review v2 F13: pair the watchdog fault with a recovery line
    // so the operator can tell a slow-but-correct boot from a stuck
    // helper.
    if firstPaint && initialRenderWatchdogFaulted {
      Log.helper.info("statusItem: initial observer paint arrived AFTER the \(Self.initialRenderDeadlineSeconds, privacy: .public)s watchdog deadline — supervisor wiring intact, just slow")
    }
    Log.helper.info("statusItem: dot=\(model.dot.rawValue, privacy: .public) label=\(model.engineLabel, privacy: .public) pr.title=\(model.pauseResume.title, privacy: .public) pr.enabled=\(model.pauseResume.enabled, privacy: .public)")
    Diag.helper.event("statusitem.update", [("dot", model.dot.rawValue), ("label", model.engineLabel)])
    statusItemBinding().apply(model)
  }

  /// Construct the AppKit-side binding closures. Re-built on each
  /// apply (cheap — closures capture `self` weakly via `@MainActor`
  /// callers + retained ivars) so a status-item teardown / rebuild
  /// cannot leave stale references behind.
  private func statusItemBinding() -> HelperStatusItemBinding {
    HelperStatusItemBinding(
      setDot: { [weak self] dot in
        guard let self, let button = self.statusItem?.button else { return }
        // #424: render the Rational brand mark (a rounded
        // down-pointing triangle) as a native menu-bar template image,
        // not a colored LED/status-light. Fill + the error badge carry
        // status WITHOUT color (#396), while macOS owns light/dark menu-bar
        // foreground treatment.
        let img = MenuBarBrandIcon.image(filled: dot.isFilled,
                                         errorBadge: dot.showsErrorBadge)
        img.accessibilityDescription = "Rational engine \(dot.accessibilityWord)"
        button.image = img
        // #396: a transitional dot (engine starting/stopping) is an
        // in-flight async op, so it must show MOTION — never a static
        // colored dot. Steady states remove the pulse so the menu bar
        // is quiet when the engine is settled.
        Self.applyDotPulse(animated: dot.isAnimated, to: button)
      },
      setEngineLabel: { [weak self] title in
        self?.engineLabelMenuItem?.title = title
      },
      setPauseResumeTitle: { [weak self] title in
        self?.pauseResumeMenuItem?.title = title
      },
      setPauseResumeEnabled: { [weak self] enabled in
        guard let self else { return }
        // Review v1 F6: AppKit's responder chain would deliver the
        // selector to the next responder if `target` were left set
        // while the item is supposedly disabled. Clear target on
        // disable so AX scripting (which can fire selectors even on
        // visually-disabled items) cannot reach `togglePauseResume`.
        self.pauseResumeMenuItem?.target = enabled ? self : nil
        self.pauseResumeMenuItem?.isEnabled = enabled
      },
      setPauseResumeAction: { [weak self] action in
        self?.pauseResumeMenuItem?.representedObject = action
      }
    )
  }

  /// Layer-animation key for the transitional-dot pulse. A constant so
  /// the add/remove pair can never drift.
  private static let dotPulseAnimationKey = "com.ratiothink.helper.dotPulse"

  /// Drive (or stop) a gentle opacity pulse on the menu-bar dot so an
  /// in-progress engine transition reads as *active work*, not a stuck
  /// static dot (#396 invariant 1). Layer-backed opacity animation
  /// rather than a `Timer` so the cadence is owned by Core Animation and
  /// stops cleanly on removal — no timer to invalidate on teardown. The
  /// pulse survives the per-apply `button.image` reassignment because it
  /// targets `layer.opacity`, not the image.
  private static func applyDotPulse(animated: Bool, to button: NSStatusBarButton) {
    button.wantsLayer = true
    guard let layer = button.layer else { return }
    if animated {
      // Idempotent: re-applying the same state (e.g. starting → stopping,
      // both `.loading`) must not restart the animation mid-cycle.
      guard layer.animation(forKey: dotPulseAnimationKey) == nil else { return }
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 1.0
      pulse.toValue = 0.3
      pulse.duration = 0.7
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(pulse, forKey: dotPulseAnimationKey)
    } else {
      layer.removeAnimation(forKey: dotPulseAnimationKey)
    }
  }

  /// Durable engine-lifecycle breadcrumb for each healthy-mode transition. The
  /// `.failed` message is intentionally omitted — its code is the routable
  /// signal and the full text already rides Unified Logging + engine.log;
  /// `.stopping` is a transient and is skipped.
  private static func recordEngineBreadcrumb(for status: EngineStatus) {
    switch status {
    case .starting:
      Diag.helper.event("engine.start")
    case let .running(snapshot):
      Diag.helper.event("engine.ready", [
        ("port", String(snapshot.port)),
        ("profile", snapshot.profileID),
        ("model", snapshot.servedModelID),
        ("maxOutputTokens", String(snapshot.maxOutputTokens)),
        ("generation", String(snapshot.generation)),
      ])
    case let .failed(code, _):
      Diag.helper.event("engine.fail", [("code", code.rawValue)])
    case .stopped:
      Diag.helper.event("engine.stop")
    case .stopping:
      break
    }
  }

  /// Subscribe the menu bar to supervisor state transitions. The
  /// observer fires on `PieSupervisor`'s stateQueue (an arbitrary
  /// background queue); each transition hops onto main before
  /// touching AppKit. Degraded mode wins over the supervisor's
  /// state — the degraded status item is already on screen and must
  /// not be overwritten by a misleading "Engine: stopped" render
  /// (preservation contract from ).
  ///
  /// MUST be called on main (review v1 F11): `degradedReason` is
  /// the AppKit-main-owned source of truth, and the subscribe-time
  /// read here is the only one that escapes the observer's main-hop.
  /// The `dispatchPrecondition` traps a future caller that tries to
  /// subscribe from a non-main queue rather than racing the
  /// degraded transition.
  private func subscribeToEngineHost(_ engineHost: PieEngineHost) {
    dispatchPrecondition(condition: .onQueue(.main))
    if HelperConfig.isTestMode { return }
    if degradedReason != nil {
      // Review v1 F4 (subscribe-time leg): logged so a future
      // refactor that calls subscribeToEngineHost on a degraded
      // boot path doesn't silently skip without trace.
      Log.helper.info("subscribeToEngineHost: skipped — degraded mode active")
      return
    }
    // Review v1 F4 + review v2 F17 + review v3 F24: under post-
    // subscribe degraded mode we drop transitions silently from the
    // UI but keep `helper.log` honest. Three-tier policy:
    //   · Non-failed transitions: log the FIRST drop at fault,
    //     then stay quiet.
    //   · Failed-CODE transitions: log at fault when the failure
    //     CODE first appears (or reappears after eviction). Bounded
    //     ring of the last `failureCodeRingSize` codes guards
    //     against an engine alternating between a small set of
    //     codes (each "new code" log fires once per ring eviction,
    //     not per transition).
    //   · Failed-MESSAGE-DIFF transitions (same code, different
    //     message): log at INFO, not fault — the discriminator is
    //     stable, the message is per-attempt noise (pid, timestamp,
    //     retry counter) that the previous unbounded fault-log
    //     would spam to helper.log without upper bound.
    let droppedNonFailedLogged = OSAllocatedUnfairLock<Bool>(initialState: false)
    let recentFailureCodes = OSAllocatedUnfairLock<[String]>(initialState: [])
    // Review v4 F32: per-code last-message map. The v3 single-slot
    // implementation aliased across codes — code A then code B
    // then code A again with A's original message would falsely
    // log "message diff" because the slot still held B's key.
    // Keying by code.rawValue eliminates that false-positive.
    let lastFailureMessagePerCode = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    let token = engineHost.observe { [weak self] status, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.degradedReason != nil {
          if case .failed(let code, let message) = status {
            let codeKey = code.rawValue
            // Review v5 F38: capture ring-evicted keys here so the
            // per-code message map gets pruned in lockstep with
            // the ring. Otherwise the map would silently grow
            // unbounded if `EngineErrorCode` is ever broadened to
            // supervisor-provided raw strings (closed enum today,
            // but the F32 fix should not depend on enum closure).
            let (codeIsNovel, evicted) = recentFailureCodes.withLock { (ring: inout [String]) -> (Bool, [String]) in
              if ring.contains(codeKey) { return (false, []) }
              ring.append(codeKey)
              var dropped: [String] = []
              if ring.count > Self.failureCodeRingSize {
                let overflow = ring.count - Self.failureCodeRingSize
                dropped = Array(ring.prefix(overflow))
                ring.removeFirst(overflow)
              }
              return (true, dropped)
            }
            if !evicted.isEmpty {
              lastFailureMessagePerCode.withLock { map in
                for k in evicted { map.removeValue(forKey: k) }
              }
            }
            if codeIsNovel {
              lastFailureMessagePerCode.withLock { $0[codeKey] = message }
              Log.helper.fault("statusItem: dropping engine-host failure under degraded mode (NEW code) — \(String(describing: status), privacy: .public)")
            } else {
              let messageChanged = lastFailureMessagePerCode.withLock { (map: inout [String: String]) -> Bool in
                if map[codeKey] == message { return false }
                map[codeKey] = message
                return true
              }
              if messageChanged {
                Log.helper.info("statusItem: dropping engine-host failure under degraded mode (code repeats, message diff) — \(String(describing: status), privacy: .public)")
              }
            }
          } else {
            let already = droppedNonFailedLogged.withLock { (logged: inout Bool) -> Bool in
              defer { logged = true }
              return logged
            }
            if !already {
              Log.helper.fault("statusItem: dropping engine-host transitions — entered degraded mode post-subscribe (first dropped status=\(String(describing: status), privacy: .public))")
            }
          }
          return
        }
        // Review v1 F7: the menu-label projection truncates `.failed`
        // messages to 120 chars; log the full status here so the
        // untruncated cause survives engine.log rotation.
        if case .failed = status {
          Log.helper.error("engine-host transition: \(String(describing: status), privacy: .public)")
        }
        Self.recordEngineBreadcrumb(for: status)
        self.applyStatusItemModel(HelperStatusItemModel.make(from: status))
      }
    }
    engineHostObservation = token
  }

  /// Phase 2.4: build the production `LaunchSpecResolver` by
  /// wiring `ProfileStore` against `~/Library/Application Support/RatioThink/
  /// profiles/`. Returns nil under any of:
  ///   · `ProfileStore.start()` threw (profiles dir unreadable —
  ///     surfaced via `eagerProbePieDirs` for degraded boot, but a
  ///     selective error here keeps the listener up with
  ///     `.profileMissing` replies).
  ///   · `PIE_TEST_MODE=1` — the test harness wires its own resolver
  ///     directly into `HelperExportedAPI` (no PieDirs filesystem
  ///     side effects).
  ///
  /// Under DEBUG, falls through to `smokeLaunchSpecResolver()` when
  /// the production resolver cannot stand up, so the smoke harness
  /// still exercises the menu-bar dot without a configured profile.
  private func buildLaunchSpecResolver() -> HelperExportedAPI.LaunchSpecResolver? {
    #if DEBUG
    let smokeFallback = Self.smokeLaunchSpecResolver()
    #else
    let smokeFallback: HelperExportedAPI.LaunchSpecResolver? = nil
    #endif

    if HelperConfig.isTestMode {
      Log.helper.info("PIE_TEST_MODE=1; skipping ProfileStore-backed resolver wire-up")
      self.launchSpecResolver = smokeFallback
      return smokeFallback
    }
    let profilesDir: URL
    do {
      profilesDir = try PieDirs.profiles()
    } catch {
      Log.helper.error("buildLaunchSpecResolver: profiles dir unavailable: \(String(describing: error), privacy: .public)")
      self.launchSpecResolver = smokeFallback
      return smokeFallback
    }
    let store = ProfileStore(directory: profilesDir)
    do {
      try store.start()
    } catch {
      Log.helper.error("buildLaunchSpecResolver: ProfileStore.start failed: \(String(describing: error), privacy: .public)")
      self.launchSpecResolver = smokeFallback
      return smokeFallback
    }
    self.profileStore = store
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { try LaunchSpecResolver.bundledPieBinary() },
      // Engine RUNTIME home is decoupled from the user store. The spawned
      // engine binds an aux Unix socket at
      // <pieHome>/standalone/<pid>/g0/aux.sock, which must fit the
      // `sun_path` 104-char limit. The store PIE_HOME can be arbitrarily
      // deep (e.g. a sandboxed XCUITest runner's ~150-char container dir),
      // which overflows it. The engine home is self-contained ephemeral
      // runtime — config.toml is written fresh per launch, http.port is
      // launcher-owned, and the model path is an absolute modelsRoot join —
      // so a short /tmp anchor needs nothing from the store and leaves
      // profiles/models/chats untouched. The Helper is app-sandbox=false,
      // so it can create /tmp even when the test runner cannot.
      pieHome: { try Self.engineRuntimeHome() },
      // Honor the operator's RAM-guardrail fraction (persisted by the
      // Settings → Models dial as guardrail.json) at the launch-time size
      // guard, instead of the hardcoded default. Re-evaluated per resolve
      // so a dial change takes effect on the next launch with no Helper
      // restart; falls back to the default fraction when unset/unreadable.
      memoryPolicy: {
        let fraction = (try? PieDirs.applicationSupport())
          .map { GuardrailSettings.loadFraction(root: $0) } ?? GuardrailSettings.defaultFraction
        return ModelMemoryGuardrail.Policy.recommended(
          physicalMemoryBytes: SystemMemory.physicalBytes(),
          fraction: fraction
        )
      }
    )
    let closure = resolver.asClosure
    self.launchSpecResolver = closure
    Log.helper.info("buildLaunchSpecResolver: ProfileStore-backed resolver wired (profiles=\(profilesDir.path, privacy: .public))")
    return closure
  }

  /// Short, `/tmp`-anchored RUNTIME home for the spawned engine — see the
  /// `pieHome:` note in `buildLaunchSpecResolver`. Per-UID so distinct users
  /// never collide; within a user a single Helper owns the engine and the
  /// launcher rewrites `config.toml`/`http.port` per launch while pie scopes
  /// its socket by pid, so the directory is safely reused. ~26 chars keeps
  /// `<home>/standalone/<pid>/g0/aux.sock` well under the `sun_path` limit.
  private static func engineRuntimeHome() throws -> URL {
    let home = URL(fileURLWithPath: "/tmp/ratiothink-engine-\(getuid())", isDirectory: true)
    let fm = FileManager.default
    // Owner-private (0700): the engine's aux IPC socket lives here, and on
    // multi-user macOS /tmp is world-traversable — restrict it the way the
    // prior ~/Library/Application Support location was implicitly private.
    try fm.createDirectory(at: home, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    // createDirectory does not reset perms on a dir that already existed
    // from a prior launch, so enforce it (also fails loud if the path is
    // owned by another account rather than silently reusing it).
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    return home
  }

  #if DEBUG
  /// Smoke seam: production helpers point the LaunchSpec at the
  /// bundled `pie` binary, but the smoke harness substitutes a fake
  /// shell script that prints the `PieControlLauncher`-shaped
  /// handshake (`pie-server serving on …` + `internal token: …`).
  ///  moved this to the `PieControlLauncher.LaunchSpec`
  /// shape; the smoke script must therefore also speak the new
  /// handshake. If it does not, `PieEngineHost.start` will surface
  /// `.failed(.spawnFailed)` with the parsed-stderr-tail in the
  /// message field.
  private static func smokeLaunchSpecResolver() -> HelperExportedAPI.LaunchSpecResolver? {
    guard let fakeBin = ProcessInfo.processInfo.environment["PIE_SMOKE_FAKE_ENGINE_BIN"],
          FileManager.default.isExecutableFile(atPath: fakeBin) else {
      return nil
    }
    Log.helper.info("smoke seam: PIE_SMOKE_FAKE_ENGINE_BIN=\(fakeBin, privacy: .public)")
    // Smoke resolver ignores the explicit model override — it only swaps
    // the engine binary for the fake smoke engine.
    return { profileID, _ in
      // Use the same path-resolution closures as the production
      // resolver for the wasm/manifest/pieHome bits; the smoke
      // contract only swaps the engine binary.
      let resources: (wasm: URL, manifest: URL)
      let home: URL
      do {
        resources = try InferletResources.pieControl(in: .main)
        home = try PieDirs.applicationSupport()
      } catch {
        return .failure(EngineError(
          code: .spawnFailed,
          message: "smoke resolver: \(String(describing: error))"
        ))
      }
      let env = SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment)
      do {
        return .success(try PieControlLauncher.LaunchSpec(
          pieBinary: URL(fileURLWithPath: fakeBin),
          wasmURL: resources.wasm,
          manifestURL: resources.manifest,
          subprocessEnvironment: env,
          pieHome: home,
          shmemName: LaunchSpecResolver.uniqueShmemName(),
          profileID: profileID,
          modelConfig: .dummy
        ))
      } catch {
        return .failure(EngineError(
          code: .spawnFailed,
          message: "smoke resolver spec construction failed: \(String(describing: error))"
        ))
      }
    }
  }

  /// Auto-drive host.start → wait → stop when the env opts in. Lets
  /// a seated-console operator see the dot flip live. 1.5s lead so
  /// the gray dot is visible before the first flip.
  private func scheduleSmokeAutoDriveIfRequested(engineHost: PieEngineHost) {
    guard let raw = ProcessInfo.processInfo.environment["PIE_SMOKE_AUTO_GREEN_HOLD_SECONDS"],
          let greenHold = TimeInterval(raw),
          greenHold > 0 else {
      return
    }
    guard let fakeBin = ProcessInfo.processInfo.environment["PIE_SMOKE_FAKE_ENGINE_BIN"],
          FileManager.default.isExecutableFile(atPath: fakeBin) else {
      Log.helper.error("smoke auto-drive: PIE_SMOKE_AUTO_GREEN_HOLD_SECONDS set without PIE_SMOKE_FAKE_ENGINE_BIN")
      return
    }
    Log.helper.info("smoke auto-drive: armed (greenHold=\(greenHold, privacy: .public)s)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak engineHost] in
      guard let engineHost else { return }
      let resources: (wasm: URL, manifest: URL)
      let home: URL
      do {
        resources = try InferletResources.pieControl(in: .main)
        home = try PieDirs.applicationSupport()
      } catch {
        Log.helper.error("smoke auto-drive: resource resolve failed: \(String(describing: error), privacy: .public)")
        return
      }
      let spec: PieControlLauncher.LaunchSpec
      do {
        spec = try PieControlLauncher.LaunchSpec(
          pieBinary: URL(fileURLWithPath: fakeBin),
          wasmURL: resources.wasm,
          manifestURL: resources.manifest,
          subprocessEnvironment: SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment),
          pieHome: home,
          shmemName: LaunchSpecResolver.uniqueShmemName(),
          profileID: "smoke",
          modelConfig: .dummy
        )
      } catch {
        Log.helper.error("smoke auto-drive: spec construction failed: \(String(describing: error), privacy: .public)")
        return
      }
      Log.helper.info("smoke auto-drive: start")
      if case .failure(let err) = engineHost.start(spec) {
        Log.helper.error("smoke auto-drive: start failed \(err.code.rawValue, privacy: .public) — \(err.message, privacy: .public)")
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + greenHold) { [weak engineHost] in
        Log.helper.info("smoke auto-drive: stop")
        engineHost?.stop()
      }
    }
  }
  #endif

  /// Boot-time model-load hook. This is now a disabled/no-op hook: helper
  /// boot publishes XPC/menu state and leaves the engine stopped while the app
  /// polls status separately. Starts happen through explicit lifecycle requests
  /// (`startEngine(profileID:)`) from the launch prompt/user confirmation,
  /// Restart, Local API, or post-download recovery paths. Skipped in test mode
  /// because tests own engine lifecycle.
  private func autoResumeEngineOnBoot() {
    // #4: the engine is NO LONGER auto-started on boot. Pre-#4 this
    // resumed the active profile automatically, which (a) loaded a
    // multi-GB model the user may not want this session and (b) made a
    // model-load failure on launch read as an unprompted error. The App
    // now starts via explicit lifecycle requests: the launch prompt/user
    // confirmation, Restart, Local API, or post-download recovery paths call
    // the `startEngine` XPC selector.
    //
    // Scope: this disables the BOOT model-load only. The engine-CRASH
    // auto-relaunch ladder is a separate mechanism (the `relauncher`
    // closure wired into `PieEngineHost` in `startXPCListener`, fired by
    // the liveness monitor on `.failed(.engineGone)` per
    // `RelaunchPolicy`) and is deliberately UNCHANGED — a crashed engine
    // still recovers automatically without a prompt.
    Log.helper.info("autoResumeEngineOnBoot: boot auto-start disabled (#4) — engine stays stopped until an explicit app/user start request")
  }

  @objc func togglePauseResume(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? HelperStatusItemModel.PauseResume.Action else {
      Log.helper.error("togglePauseResume: missing action on menu item")
      return
    }
    switch action {
    case .pause:
      // Phase 2.3 reuses `engineHost.stop()` for Pause — there is
      // no distinct pause primitive yet. A running engine SIGINTs
      // and transitions to `.stopped`; a starting engine cancels
      // the launch task.
      //
      // Review v1 F12: guard the host BEFORE logging so a
      // degraded-mode helper (no engineHost) cannot emit a
      // misleading "pause requested" line with no follow-up.
      guard let engineHost else {
        Log.helper.error("togglePauseResume: pause requested but engineHost unavailable (degraded boot)")
        return
      }
      Log.helper.info("togglePauseResume: pause requested")
      engineHost.stop(reason: "menu.pause")
    case .resume:
      // In-process Resume ( follow-up): no XPC round-trip — the
      // menu-bar action runs inside the helper, so we hand the
      // resolved LaunchSpec straight to `PieEngineHost.start`.
      // Policy lives in `HelperResumeAction.run`; this block is the
      // AppKit-side log surface.
      let outcome = HelperResumeAction.run(
        engineHost: engineHost,
        profileStore: profileStore,
        resolver: launchSpecResolver
      )
      switch outcome {
      case .started(let id):
        Log.helper.info("togglePauseResume: resume → engineHost.start queued (profileID=\(id, privacy: .public))")
      case .supervisorMissing:
        Log.helper.error("togglePauseResume: resume requested but engineHost unavailable")
      case .profileStoreMissing:
        Log.helper.error("togglePauseResume: resume requested but ProfileStore not wired")
      case .resolverMissing:
        Log.helper.error("togglePauseResume: resume requested but LaunchSpec resolver not wired")
      case .noActiveProfile(let afterRetry):
        // Review v6 F3: distinct log line for retry-healed-to-absent
        // (operator deleted the marker between Resume click and the
        // F3 retry call) vs first-look-no-selection.
        if afterRetry {
          Log.helper.error("togglePauseResume: resume → reloadActiveProfile() healed the marker error but produced no id (marker was removed externally)")
        } else {
          Log.helper.error("togglePauseResume: resume requested but no active profile in ProfileStore")
        }
      case .activeProfileUnreadable(let storeErr):
        // Review v3 F1: separate log line so operator reading
        // helper.log can tell "user never picked one" from
        // "marker on disk is broken (perms / dir-at-path / decode
        // failure)" — both used to collapse into the
        // `.noActiveProfile` line above.
        Log.helper.error("togglePauseResume: resume requested but active-profile marker is unreadable: \(String(describing: storeErr), privacy: .public)")
      case .activeProfileUnreadableAfterRetry(let storeErr):
        // Review v5 F2: distinguishes "marker was clean, resume
        // failed for some other reason" from "marker was broken, we
        // retried, it's STILL broken". The retry-attempt + retry-
        // failure lines are also logged inside HelperResumeAction so
        // helper.log carries the full timeline.
        Log.helper.error("togglePauseResume: resume → retry of reloadActiveProfile() still failed: \(String(describing: storeErr), privacy: .public)")
      case .resolverFailed(let err):
        Log.helper.error("togglePauseResume: resume → resolver rejected (\(err.code.rawValue, privacy: .public): \(err.message, privacy: .public))")
      case .startRejected(let err):
        Log.helper.error("togglePauseResume: resume → engineHost.start rejected (\(err.code.rawValue, privacy: .public): \(err.message, privacy: .public))")
      }
    case .none:
      return
    }
  }

  /// Error-state menu bar item: red exclamation icon, single action
  /// that opens an NSAlert explaining the failure. Distinct from the
  /// normal status item so the user can tell at a glance something's
  /// wrong (review v4 F4).
  private func setupDegradedStatusItem() {
    HelperConfig.assertSystemSideEffectAllowed("NSStatusBar.statusItem")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                        accessibilityDescription: "Rational startup error")
      img?.isTemplate = false
      button.image = img
    }
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Rational cannot start — click for details",
                            action: #selector(showStartupError),
                            keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Rational", action: #selector(quitPie), keyEquivalent: "q"))
    item.menu = menu
    self.statusItem = item
    Diag.helper.event("statusitem.create", [("kind", "degraded")])
  }

  @objc func showPie() {
    openPieApp()
  }

  @objc func openSettings() {
    // Rational.app now ships a Settings scene and the `ratiothink://` URL
    // scheme, so deliver `ratiothink://settings` to route straight to
    // Settings instead of just foregrounding the app and leaving the user
    // to press ⌘,. Delivering the URL *to the resolved parent bundle*
    // (rather than a bare `NSWorkspace.open(url)`, which LaunchServices
    // could route to any registered Rational.app) preserves the existing
    // "launch MY install" guarantee and reuses the same launch-failure
    // alert path.
    openPieApp(delivering: [SettingsDeepLink.settingsURL])
  }

  /// Resolve the parent `Rational.app` bundle that ships this helper.
  /// The helper bundle lives at
  ///   `<Rational.app>/Contents/Library/LoginItems/RationalHelper.app`
  /// so the parent is four `deletingLastPathComponent()`s up from
  /// the helper bundle URL. Falls back to `/Applications/Rational.app`
  /// when the structure does not match (e.g. helper launched
  /// standalone from a build artifact path that has been moved).
  /// Maximum ancestor levels `resolvedPieAppURL` walks looking for
  /// a `.app` parent before declaring the helper standalone
  /// (review v4 F33). Today's canonical structure is four
  /// (`<Rational>.app/Contents/Library/LoginItems/RationalHelper.app`); the
  /// bound covers two extra levels for a future embed layout
  /// change (e.g. versioned LoginItems subdir) so a structural
  /// drift surfaces as a moved-app `.error`, not a silent cross-
  /// launch.
  private static let pieAppAncestorMaxDepth = 6

  // `internal` (not `private`) so the #440 delivery unit test can assert the
  // deep link is delivered to exactly this resolved bundle. Still file-scoped
  // to the helper module; exposed only under `@testable import`.
  func resolvedPieAppURL() -> URL {
    let helperBundle = Bundle.main.bundleURL
    // Review v4 F33: walk ancestors up to a bounded depth looking
    // for ANY `*.app`. The v3 fixed 4-up walk landed in the wrong
    // directory under any future embed-layout change and silently
    // cross-launched /Applications/Rational.app. The walk now finds the
    // first `.app` ancestor regardless of depth, and only declares
    // "true standalone" when none of the first
    // `pieAppAncestorMaxDepth` ancestors is a `.app`.
    var candidate = helperBundle
    var firstAppAncestor: URL? = nil
    for _ in 0..<Self.pieAppAncestorMaxDepth {
      candidate = candidate.deletingLastPathComponent()
      if candidate.pathExtension == "app" {
        firstAppAncestor = candidate
        break
      }
      if candidate.path == "/" { break }
    }

    let fallback = URL(fileURLWithPath: "/Applications/Rational.app")
    let fallbackExists = FileManager.default.fileExists(atPath: fallback.path)

    if let ancestor = firstAppAncestor {
      let ancestorExists = FileManager.default.fileExists(atPath: ancestor.path)
      if ancestorExists {
        return ancestor
      }
      // Helper IS inside a .app bundle but the bundle is gone from
      // disk (moved-app / deleted-while-running). Surface at
      // `.error` — the fallback is a different installation,
      // IPC-version-mismatch likely.
      if !fallbackExists {
        Log.helper.fault("resolvedPieAppURL: parent .app gone AND /Applications/Rational.app absent — click will fail (ancestor=\(ancestor.path, privacy: .public))")
      } else {
        Log.helper.error("resolvedPieAppURL: parent .app moved or deleted (ancestor=\(ancestor.path, privacy: .public)); falling back to /Applications/Rational.app (possible IPC schema mismatch)")
      }
      return fallback
    }

    // No `.app` ancestor within the bounded depth — genuine
    // standalone case (helper launched from a build artifact path
    // outside a .app, test bench, etc.). The fallback is the only
    // sane guess.
    if !fallbackExists {
      Log.helper.fault("resolvedPieAppURL: helper not inside an .app ancestor (within \(Self.pieAppAncestorMaxDepth, privacy: .public) levels) AND /Applications/Rational.app absent — click will fail (helperBundle=\(helperBundle.path, privacy: .public))")
    } else {
      Log.helper.info("resolvedPieAppURL: helper not inside an .app ancestor (within \(Self.pieAppAncestorMaxDepth, privacy: .public) levels); falling back to /Applications/Rational.app (helperBundle=\(helperBundle.path, privacy: .public))")
    }
    return fallback
  }

  /// Launch / foreground the resolved parent Rational.app. When `urls` is
  /// non-empty they are delivered to that specific bundle (e.g.
  /// `ratiothink://settings`), so the app routes the deep link AND the
  /// launch still targets MY install rather than whichever Rational.app
  /// LaunchServices would pick for a bare scheme open. Both paths share the
  /// same launch-failure alert (review v2 F16 / v3 F25).
  private func openPieApp(delivering urls: [URL] = []) {
    let url = resolvedPieAppURL()
    Log.helper.info("openPieApp: \(url.path, privacy: .public) urls=\(urls.map(\.absoluteString).joined(separator: ","), privacy: .public)")
    // Test seam: capture the delivered URLs + resolved bundle instead of
    // actually launching an app (#440). Nil in production.
    if let workspaceOpenOverride {
      workspaceOpenOverride(urls, url)
      return
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    let completion: (NSRunningApplication?, Error?) -> Void = { [weak self] app, err in
      if let err {
        Log.helper.error("openPieApp failed: \(String(describing: err), privacy: .public)")
        // Review v2 F16: a logged-only failure left the menu click
        // visually silent — clicking "Show Rational" / "Settings…" did
        // nothing, no beep, no banner, no dock activity. The helper
        // is the user's only surface when Rational.app cannot launch, so
        // surface the failure via NSAlert + NSSound.beep so the
        // click registers as something the user can act on.
        DispatchQueue.main.async {
          NSSound.beep()
          // Review v3 F25: route through the high-priority queue so
          // an unrelated in-flight sheet (Reveal-in-Finder, degraded
          // surface alert) cannot silently swallow the user-feedback
          // contract — the launch-failure alert is deferred until
          // that sheet completes instead of dropped.
          self?.presentHighPriorityAlert(
            title: "Couldn't launch Rational.app",
            informativeText: "Tried to launch Rational at \(url.path)\n\(err.localizedDescription)\n\nReinstall Rational from the DMG or check that Rational.app is in /Applications.",
            revealRoot: FileManager.default.fileExists(atPath: url.path) ? url : nil
          )
        }
      } else if let app {
        Log.helper.info("openPieApp launched pid=\(app.processIdentifier, privacy: .public)")
      }
    }
    if urls.isEmpty {
      NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: completion)
    } else {
      NSWorkspace.shared.open(urls, withApplicationAt: url, configuration: cfg, completionHandler: completion)
    }
  }

  @objc func openLogs() {
    do {
      NSWorkspace.shared.open(try PieDirs.logs())
    } catch let error as PieDirsError {
      Log.helper.error("openLogs: \(String(describing: error), privacy: .public)")
      presentPieDirsAlert(title: "Cannot open Rational logs",
                          error: error)
    } catch {
      Log.helper.error("openLogs: \(String(describing: error), privacy: .public)")
      presentAlert(title: "Cannot open Rational logs",
                   informativeText: String(describing: error),
                   revealRoot: nil)
    }
  }

  @objc func showStartupError() {
    guard let reason = degradedReason else { return }
    presentPieDirsAlert(title: "Rational cannot start",
                        error: reason)
  }

  /// #448: self-terminate hook handed to the exported XPC object. The
  /// `quitHelper` selector fires this AFTER the engine is reaped, so the
  /// Helper exits cleanly (exit 0) and launchd's
  /// `KeepAlive { SuccessfulExit: false }` does NOT relaunch it. Hops to main
  /// because `NSApp.terminate` is main-thread-only; the selector runs on an
  /// arbitrary XPC / engine-host queue.
  private static let terminateSelf: @Sendable () -> Void = {
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }

  /// True when an instance of the main RatioThink.app is running. The
  /// menu-bar "Quit Rational" then delegates the coordinated full-product
  /// teardown to the App (the single quit coordinator) so the Helper isn't
  /// quit-then-respawned on-demand.
  private static var isAppRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ratiothink.app").isEmpty
  }

  /// "Quit Rational" (#448): tears down the WHOLE product, not just the
  /// Helper. The old `NSApp.terminate(nil)` quit only the Helper — the
  /// still-running App then respawned it on-demand within ~1s and the engine
  /// could orphan. Now: if the App is running it owns the quit, so hand it
  /// `ratiothink://quit` and let `AppQuitCoordinator` drive the teardown
  /// (stop polling → `quitHelper` → terminate App + Helper). If the App is
  /// absent there is nothing to coordinate, so the Helper reaps its own
  /// engine and exits.
  @objc func quitPie() {
    if Self.isAppRunning {
      Log.helper.info("quitPie: App running — delivering ratiothink://quit for coordinated full quit")
      openPieApp(delivering: [SettingsDeepLink.quitURL])
    } else {
      Log.helper.info("quitPie: App not running — local teardown (reap engine, then terminate helper)")
      quitHelperLocally()
    }
  }

  /// App-absent fallback for "Quit Rational": reap the engine before
  /// exiting so the Helper never orphans `pie`. `stopAndWait` fires only
  /// after the terminal status that `LaunchedSession.shutdown` publishes once
  /// `pie` is gone. If that deadline expires, the Helper stays alive so it can
  /// continue owning the session for retry or an explicit force-quit path.
  private func quitHelperLocally() {
    guard let engineHost else {
      NSApp.terminate(nil)
      return
    }
    HelperQuitTeardown.stopThenTerminate(
      engineHost: engineHost,
      initialTimeout: HelperExportedAPI.stopReplyDeadline,
      onTerminalFailure: { result in
        Log.helper.error("quitHelperLocally: stop/reap failed with status \(String(describing: result.lastStatus), privacy: .public); keeping helper alive for retry or explicit force quit")
      },
      onTimeout: { result in
        Log.helper.error("quitHelperLocally: stop/reap timed out with status \(String(describing: result.lastStatus), privacy: .public); keeping helper alive for retry or explicit force quit")
      },
      terminate: { DispatchQueue.main.async { NSApp.terminate(nil) } }
    )
  }

  // MARK: - alert

  /// Surface a PieDirsError to the user with a "Reveal in Finder"
  /// button that opens whichever portion of the path *does* exist.
  /// Replaces the prior `NSSound.beep()` which was indistinguishable
  /// from any other beep (review v4 F5).
  private func presentPieDirsAlert(title: String, error: PieDirsError) {
    let revealCandidate: URL? = {
      switch error {
      case let .rootMkdirFailed(path, _):
        return existingAncestor(of: URL(fileURLWithPath: path))
      case let .subdirMkdirFailed(_, path, _):
        return existingAncestor(of: URL(fileURLWithPath: path))
      case let .excludeFromBackupFailed(path, _):
        // The dir exists by definition (setResourceValues only fails
        // *after* createDirectory succeeded), but route through
        // existingAncestor anyway so a deleted-mid-flight path still
        // produces a valid Reveal target (review v5 F7).
        return existingAncestor(of: URL(fileURLWithPath: path))
      case .unknown:
        // No path to reveal — surface the message only (review v5 F8).
        return nil
      }
    }()
    presentAlert(title: title,
                 informativeText: String(describing: error),
                 revealRoot: revealCandidate)
  }

  /// Single-slot deferred-alert queue for high-priority alerts that
  /// arrive while another sheet is in flight (review v3 F25).
  /// Latest-wins eviction — if two launch-failures stack up while a
  /// Reveal-in-Finder sheet is open, only the most recent one
  /// surfaces. Drained from `beginSheetModal`'s completion handler.
  private struct DeferredAlert {
    let title: String
    let informativeText: String
    let revealRoot: URL?
  }
  private var deferredHighPriorityAlert: DeferredAlert?

  /// Strong reference to the in-flight host panel. `beginSheetModal`
  /// captures the panel in its completion closure, so the closure
  /// alone is what keeps the panel alive across the runloop turn;
  /// this ivar exists so the reentry guard can detect a sheet is
  /// already up. Reentry while non-nil = drop the second alert
  /// (review v1 F4). Cleared in the completion handler.
  private var sheetHostPanel: NSPanel?

  private func presentAlert(title: String, informativeText: String, revealRoot: URL?) {
    // Under test mode, the sheet would never receive a user click
    // and the panel would leak. Log the would-be alert content and
    // return — the test harness can verify intent via the log
    // (review v5 F9). Production helpers never hit this branch
    // because PIE_TEST_MODE=1 short-circuits earlier setup paths;
    // belt-and-braces here protects programmatic callers in future
    // smoke tests.
    if HelperConfig.isTestMode {
      Log.helper.error("alert (suppressed under PIE_TEST_MODE=1) title=\(title, privacy: .public) text=\(informativeText, privacy: .public) revealRoot=\(revealRoot?.path ?? "<nil>", privacy: .public)")
      return
    }

    // Review v1 F4: refuse reentry while a sheet is already up.
    // Previously `sheetHostPanel = panel` overwrote the in-flight
    // reference; the first completion's `self?.sheetHostPanel = nil`
    // then nilled the SECOND panel's host ivar mid-sheet, and the
    // first sheet's Reveal-in-Finder silently dropped (no telemetry
    // hint — the test-mode log branch is the only one that fires).
    // Drop the new alert and log the title so the second event is
    // visible to ops.
    if sheetHostPanel != nil {
      Log.helper.error("presentAlert reentered while a sheet is in flight; dropping new alert title=\(title, privacy: .public) text=\(informativeText, privacy: .public) revealRoot=\(revealRoot?.path ?? "<nil>", privacy: .public)")
      return
    }

    // Helper Info.plist sets `LSUIElement=YES` → status-bar agent
    // that does not own a Dock icon. The earlier implementation
    // briefly bumped `NSApp.activationPolicy` to `.regular` so the
    // agent could host an `NSAlert.runModal()`; on macOS that flash
    // causes a Dock icon to appear-and-disappear ( F5).
    //
    // Fix: host the alert as a sheet on an invisible utility
    // `NSPanel` instead. `.accessory` agents are allowed to own
    // panels and present sheets; no policy bump, no Dock entry.
    // The panel is sized 1×1, centered on the main screen with
    // `alphaValue = 0`, so the sheet visibly descends from screen
    // center without exposing the host chrome.
    //
    // Review v1 F5: `NSApp.activate()` on an LSUIElement=YES agent
    // does not reliably pull the sheet above the frontmost foreign
    // app on macOS 14/15 (the exact failure mode the previous
    // `.regular` policy bump worked around). Compensate without the
    // Dock flash by raising the panel's window level above the
    // active-app band (`.floating` is enough to clear the regular
    // app layer; `.modalPanel` keeps it above other helper windows)
    // and calling `orderFrontRegardless` so the panel front-orders
    // even when the agent is not the active app. NSApp.activate()
    // is retained as a best-effort to make the sheet *key* (so
    // keyboard Return/Esc routes to the alert) — the visibility
    // contract is carried by orderFrontRegardless + window level.
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let panel = NSPanel(
      contentRect: NSRect(x: screen.midX, y: screen.midY, width: 1, height: 1),
      styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.alphaValue = 0
    panel.hidesOnDeactivate = false
    panel.level = .modalPanel
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.orderFrontRegardless()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate()
    sheetHostPanel = panel

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = informativeText
    alert.alertStyle = .warning
    if revealRoot != nil {
      alert.addButton(withTitle: "Reveal in Finder")
    }
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: panel) { [weak self] response in
      panel.orderOut(nil)
      self?.sheetHostPanel = nil
      if let revealRoot, response == .alertFirstButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting([revealRoot])
      }
      self?.drainDeferredHighPriorityAlert()
    }
  }

  /// Drain the single-slot deferred high-priority alert queue
  /// (review v3 F25 + review v4 F29 + review v5 F37). Hoisted out
  /// of the `beginSheetModal` completion closure so the ordering
  /// invariant — `sheetHostPanel` cleared BEFORE we re-enter the
  /// gate — is checked by `dispatchPrecondition` + `assert`
  /// instead of living only in a comment. A future refactor that
  /// re-enters the gate while `sheetHostPanel` is still non-nil
  /// traps loudly here instead of silently re-enqueueing into a
  /// slot the same closure already nil'd.
  private func drainDeferredHighPriorityAlert() {
    dispatchPrecondition(condition: .onQueue(.main))
    // Review v6 F41: `precondition` (not `assert`) — `assert` is
    // stripped at `-O` and would let a future refactor that drains
    // before clearing `sheetHostPanel` silently re-enqueue the
    // payload against the already-fired completion handler. The
    // helper does not ship with `-Ounchecked`, so `precondition`
    // survives every shipping build config.
    precondition(sheetHostPanel == nil,
                 "drainDeferredHighPriorityAlert must run AFTER sheetHostPanel is cleared (review v5 F37 / v6 F41)")
    guard let pending = deferredHighPriorityAlert else { return }
    deferredHighPriorityAlert = nil
    presentHighPriorityAlert(title: pending.title,
                             informativeText: pending.informativeText,
                             revealRoot: pending.revealRoot)
  }

  /// Variant of `presentAlert` for alerts whose user-feedback
  /// contract cannot tolerate a silent drop (review v3 F25). If a
  /// sheet is already in flight, the alert is queued (latest-wins)
  /// and presented from the in-flight sheet's completion handler.
  /// Used by the "Couldn't launch Rational.app" path so the user is
  /// guaranteed to see *some* sheet for their click, not just an
  /// ambiguous beep.
  ///
  /// Decision is delegated to `HighPriorityAlertGate.decide(...)`
  /// (review v4 F31) so the queue / defer / test-mode branch logic
  /// is unit-testable in RatioThinkCoreTests without an NSPanel.
  private func presentHighPriorityAlert(title: String, informativeText: String, revealRoot: URL?) {
    switch HighPriorityAlertGate.decide(
      sheetInFlight: sheetHostPanel != nil,
      isTestMode: HelperConfig.isTestMode
    ) {
    case .testModeSuppressed:
      Log.helper.error("highPriorityAlert (suppressed under PIE_TEST_MODE=1) title=\(title, privacy: .public) text=\(informativeText, privacy: .public)")
    case .enqueued:
      // Review v4 F30: log latest-wins eviction so the lost prior
      // payload is not invisible in helper.log. Single-slot
      // semantics are intentional (the user only needs to see the
      // most recent failure surface); making the eviction
      // observable is the audit guarantee.
      if let evicted = deferredHighPriorityAlert {
        Log.helper.error("presentHighPriorityAlert evicted prior deferred alert title=\(evicted.title, privacy: .public) text=\(evicted.informativeText, privacy: .public) for newTitle=\(title, privacy: .public)")
      }
      Log.helper.fault("presentHighPriorityAlert deferred while a sheet is in flight; will present on completion title=\(title, privacy: .public)")
      deferredHighPriorityAlert = DeferredAlert(
        title: title, informativeText: informativeText, revealRoot: revealRoot
      )
    case .presented:
      presentAlert(title: title, informativeText: informativeText, revealRoot: revealRoot)
    }
  }

  /// Walks up the path, returning the deepest existing ancestor.
  /// Includes `/` as a final fallback so a fully-nonexistent
  /// `/nonexistent/sub/dir` still returns a valid Reveal target
  /// (review v5 F7).
  private func existingAncestor(of url: URL) -> URL? {
    var u = url
    while u.path != "/" && !u.path.isEmpty {
      if FileManager.default.fileExists(atPath: u.path) {
        return u
      }
      u = u.deletingLastPathComponent()
    }
    // Final fallback: `/` itself. Excluded by the loop predicate so
    // the loop terminates; check here so total fall-through to nil
    // only happens for genuinely degenerate inputs.
    let root = URL(fileURLWithPath: "/")
    if FileManager.default.fileExists(atPath: root.path) {
      return root
    }
    return nil
  }
}
