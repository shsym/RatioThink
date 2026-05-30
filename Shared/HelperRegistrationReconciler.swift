import Foundation

/// SMAppService registration state, projected into RatioThinkCore so the
/// reconciler decision logic is unit-testable without linking
/// ServiceManagement. The App maps `SMAppService.Status` /
/// `LoginItemRegistrationStatus` onto this.
public enum HelperRegistrationState: Equatable, Sendable {
  case enabled
  case notRegistered
  case requiresApproval
  /// `.notFound` / `.unavailable` — treated like "needs a fresh register".
  case other
}

/// Reconciles the Helper's launchd registration on app launch.
///
/// **Why this exists ( robustness):** `SMAppService` registers an
/// on-demand launch-agent job for `com.ratiothink.helper`. After an app update
/// REPLACES the bundle, BTM keeps reporting `.enabled` but launchd does
/// NOT reload the job against the new bundle — so `launchctl print
/// gui/<uid>/com.ratiothink.app.helper` returns "could not find service", the
/// mach service is never published, and the App's XPC connect fails
/// (NSCocoaError 4099) forever. A plain `register()` is a no-op while
/// the status is already `.enabled`, so it does NOT repair the stale
/// job. The only reliable reload is `unregister()` THEN `register()`.
///
/// Before  this was masked: a clean first install registered against
/// the right bundle, so it "just worked" — until the bundle was swapped
/// underneath the live registration, which silently broke it. The app
/// previously only registered inside the first-launch wizard, so it
/// could never self-heal after an update.
///
/// **Policy:** probe the Helper first; if it is REACHABLE, do nothing —
/// never disturb a healthy background service. Only when it is
/// unreachable do we repair, choosing the minimal action for the
/// observed `HelperRegistrationState`. `.requiresApproval` is a hard
/// macOS consent gate that code cannot bypass — we re-assert the
/// registration and report `needsApproval` so the App can route the
/// user to System Settings.
public struct HelperRegistrationReconciler: Sendable {
  public enum Outcome: Equatable, Sendable {
    /// Helper answered the probe — registration is healthy, nothing done.
    case healthy
    /// Was unreachable while `.enabled` (stale job) — `unregister()` +
    /// `register()` reloaded launchd and the Helper now answers.
    case repaired
    /// Was not registered — `register()` created the job and the Helper
    /// now answers.
    case registered
    /// `register()` reports the item needs user approval in System
    /// Settings → Login Items. Cannot be resolved programmatically.
    case needsApproval
    /// Repair ran but the Helper is still unreachable. Carries a short
    /// reason for the App log.
    case repairFailed(String)
  }

  /// Returns true iff the Helper answered (one bounded probe; the caller
  /// supplies its own retry/timeout policy so this type stays pure).
  let probeReachable: @Sendable () async -> Bool
  let currentState: @Sendable () -> HelperRegistrationState
  /// Calls `SMAppService.agent(...).register()` and returns the resulting
  /// state. Throws if registration itself errors.
  let register: @Sendable () throws -> HelperRegistrationState
  /// Calls `SMAppService.agent(...).unregister()`. May throw if the item
  /// was already absent — callers treat that as benign.
  let unregister: @Sendable () throws -> Void

  public init(
    probeReachable: @escaping @Sendable () async -> Bool,
    currentState: @escaping @Sendable () -> HelperRegistrationState,
    register: @escaping @Sendable () throws -> HelperRegistrationState,
    unregister: @escaping @Sendable () throws -> Void
  ) {
    self.probeReachable = probeReachable
    self.currentState = currentState
    self.register = register
    self.unregister = unregister
  }

  /// Whether the launch-time reconcile must be skipped because the
  /// process is a test/automation launch — running real
  /// `SMAppService.unregister()/register()` there would mutate the
  /// developer/CI machine's actual background-item registration (F1).
  ///
  /// Most markers are test-only env knobs a shipped app never carries,
  /// so their mere presence means "test launch, no system side effects":
  /// the registration stub (`PIE_TEST_LOGIN_ITEM_STATUS`), the
  /// isolated-prefs suite (`PIE_APP_PREFERENCES_SUITE`, set by every GUI
  /// test), fake downloads (`PIE_TEST_FAKE_DOWNLOADS`), the
  /// completed-first-launch seam (`PIE_TEST_FIRST_LAUNCH_COMPLETED`) and
  /// an explicit opt-out (`PIE_TEST_SKIP_HELPER_RECONCILE`).
  ///
  /// The in-harness engine bypass (`PIE_TEST_ENGINE_BASE_URL`) is the
  /// exception: it counts only where it can actually take effect — gated
  /// through `HelperConfig.isTestOverrideAllowed` exactly like
  /// `RatioThinkApp.isEngineBaseURLOverrideAllowed`, the other consumer of
  /// that var. So a shipped Release app launched with a stray
  /// `PIE_TEST_ENGINE_BASE_URL` still runs the real launchd self-heal
  /// reconcile rather than silently skipping it. `isDebugBuild` is
  /// injected so the Release branch is unit-testable.
  public static func isTestLaunch(
    _ env: [String: String],
    isDebugBuild: Bool = HelperConfig.isDebugBuild
  ) -> Bool {
    if (env["PIE_TEST_ENGINE_BASE_URL"] ?? "").isEmpty == false,
       HelperConfig.isTestOverrideAllowed(environment: env, isDebugBuild: isDebugBuild) {
      return true
    }
    let present = ["PIE_TEST_LOGIN_ITEM_STATUS",
                   "PIE_APP_PREFERENCES_SUITE"]
    if present.contains(where: { (env[$0] ?? "").isEmpty == false }) { return true }
    let flags = ["PIE_TEST_FAKE_DOWNLOADS",
                 "PIE_TEST_FIRST_LAUNCH_COMPLETED",
                 "PIE_TEST_SKIP_HELPER_RECONCILE"]
    return flags.contains(where: { env[$0] == "1" })
  }

  public func reconcile() async -> Outcome {
    // Never disturb a working Helper.
    if await probeReachable() { return .healthy }

    switch currentState() {
    case .enabled:
      // BTM says enabled but the Helper is unreachable → stale launchd
      // job (typically after a bundle replacement). register() alone is
      // a no-op here, so force a reload: unregister THEN register.
      // unregister() is the root operation that forces the reload, so
      // capture its error (F3): if repair ultimately fails, surface it
      // rather than masking it behind "unreachable after register". A
      // throw is still non-fatal here — register() runs regardless, and
      // a successful recovery means the unregister error didn't matter.
      var unregisterError: Error?
      do { try unregister() } catch { unregisterError = error }
      return await registerAndConfirm(freshRegistration: false, unregisterError: unregisterError)
    case .notRegistered, .other:
      return await registerAndConfirm(freshRegistration: true)
    case .requiresApproval:
      // Re-assert (harmless) and surface the consent requirement; only
      // the user can clear it in System Settings.
      _ = try? register()
      return .needsApproval
    }
  }

  private func registerAndConfirm(freshRegistration: Bool,
                                  unregisterError: Error? = nil) async -> Outcome {
    let newState: HelperRegistrationState
    do {
      newState = try register()
    } catch {
      var msg = "register() threw: \(error)"
      if let unregisterError {
        msg += "; prior unregister() also failed: \(unregisterError)"
      }
      return .repairFailed(msg)
    }
    if newState == .requiresApproval { return .needsApproval }
    // Give launchd a beat to load the RunAtLoad job — the probe closure
    // owns the retry/backoff window.
    if await probeReachable() {
      return freshRegistration ? .registered : .repaired
    }
    // Repair did not recover. If the root unregister() failed, surface it
    // — it is the most likely real cause (signing/plist/SMAppService), not
    // just "still unreachable" (F3).
    var msg = "helper unreachable after register (state=\(newState))"
    if let unregisterError {
      msg += "; unregister() had failed: \(unregisterError)"
    }
    return .repairFailed(msg)
  }
}
