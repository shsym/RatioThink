import Foundation
import os

/// #448 full-product quit coordinator (App side). A single funnel for every
/// quit trigger — ⌘Q, the App "Quit RatioThink" menu item, and the menu-bar
/// Helper's `ratiothink://quit` deep link — so the whole product tears down
/// with no orphaned App / Helper / `pie` process and no relaunch loop.
///
/// Sequence:
///   1. Stop the engine-status poll loop. The Helper is an on-demand launchd
///      mach service, so a poll landing after the Helper exits would respawn
///      it; stopping the loop first closes that race.
///   2. Ask the Helper to stop + reap the engine and terminate itself
///      (`quitHelper`). Best-effort and bounded by the client's own reply
///      timeout — a wedged or absent Helper never blocks quit.
///   3. Signal the caller (the AppDelegate) that it is safe to terminate the
///      App.
///
/// Lives in RatioThinkCore (no AppKit) so the sequencing is unit-testable; the
/// AppDelegate supplies the `done` closure that calls
/// `NSApp.reply(toApplicationShouldTerminate:)`.
@MainActor
public final class AppQuitCoordinator {
  public static let shared = AppQuitCoordinator()

  /// The poll loop to stop before quitting. Weak — the App owns it.
  public weak var engineStatusStore: EngineStatusStore?

  private let helperClient: any AppXPCClient
  private let isTestLaunch: Bool
  public private(set) var isQuitting = false
  private var teardownComplete = false
  private var pendingDoneCallbacks: [@MainActor () -> Void] = []
  private nonisolated static let log = Logger(subsystem: "com.ratiothink.app", category: "quit")

  public init(
    helperClient: any AppXPCClient = HelperXPCClient(),
    isTestLaunch: Bool = HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment)
  ) {
    self.helperClient = helperClient
    self.isTestLaunch = isTestLaunch
  }

  /// Begin the coordinated teardown. `done` is invoked exactly once, on the
  /// main actor, when the App may terminate. Repeated calls while teardown is
  /// in flight join the original helper quit and are released only when that
  /// first teardown completes; calls after completion return immediately.
  public func beginTeardown(done: @escaping @MainActor () -> Void) {
    if teardownComplete {
      done()
      return
    }
    pendingDoneCallbacks.append(done)
    if isQuitting {
      return
    }
    isQuitting = true
    Diag.app.event("app.quit", [("phase", "begin")])
    // Stop polling FIRST so no on-demand mach-service connect respawns the
    // Helper we are about to quit.
    engineStatusStore?.stop()

    // A test / automation launch must not mutate the real machine or block
    // GUI teardown on a (possibly absent) helper — stop polling and return.
    if isTestLaunch {
      Diag.app.event("app.quit", [("phase", "test_skip_helper")])
      finishTeardown()
      return
    }

    Task { @MainActor in
      do {
        try await helperClient.quitHelper()
        Diag.app.event("app.quit", [("phase", "helper_quit_ok")])
      } catch {
        // Best-effort: a refusal, a transport error, or the helper exiting
        // before its reply flushes all mean the same thing — proceed to
        // terminate the App.
        Self.log.notice("quitHelper failed (proceeding to terminate): \(String(describing: error), privacy: .public)")
        Diag.app.event("app.quit", [("phase", "helper_quit_err")])
      }
      Diag.app.event("app.quit", [("phase", "done")])
      finishTeardown()
    }
  }

  private func finishTeardown() {
    guard !teardownComplete else { return }
    teardownComplete = true
    let callbacks = pendingDoneCallbacks
    pendingDoneCallbacks.removeAll()
    callbacks.forEach { $0() }
  }
}
