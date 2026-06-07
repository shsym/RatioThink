import Foundation
import os

/// #448 full-product quit coordinator (App side). A single funnel for every
/// quit trigger — ⌘Q, the App "Quit Rational" menu item, and the menu-bar
/// Helper's `ratiothink://quit` deep link — so the whole product tears down
/// with no orphaned App / Helper / `pie` process and no relaunch loop.
///
/// Sequence:
///   1. Stop the engine-status poll loop. The Helper is an on-demand launchd
///      mach service, so a poll landing after the Helper exits would respawn
///      it; stopping the loop first closes that race.
///   2. Ask the Helper to stop + reap the engine and terminate itself
///      (`quitHelper`).
///   3. Signal the caller (the AppDelegate) whether it is safe to terminate
///      the App. Explicit stop/reap timeout blocks normal quit; transport
///      failures remain best-effort because the Helper may have exited while
///      flushing the reply.
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
  private var pendingDoneCallbacks: [@MainActor (Bool) -> Void] = []
  private nonisolated static let log = Logger(subsystem: "com.ratiothink.app", category: "quit")

  public init(
    helperClient: any AppXPCClient = HelperXPCClient(),
    isTestLaunch: Bool = HelperRegistrationReconciler.isTestLaunch(ProcessInfo.processInfo.environment)
  ) {
    self.helperClient = helperClient
    self.isTestLaunch = isTestLaunch
  }

  /// Backwards-compatible convenience for tests/callers that only care about
  /// the successful termination path.
  public func beginTeardown(done: @escaping @MainActor () -> Void) {
    beginTeardown { shouldTerminate in
      if shouldTerminate { done() }
    }
  }

  /// Begin the coordinated teardown. `done` is invoked exactly once, on the
  /// main actor, with `true` when the App may terminate and `false` when the
  /// normal quit must be cancelled because the engine was not confirmed reaped.
  /// Repeated calls while teardown is in flight join the original helper quit
  /// and are released only when that first teardown completes; calls after
  /// completion return immediately with `true`.
  public func beginTeardown(done: @escaping @MainActor (Bool) -> Void) {
    if teardownComplete {
      done(true)
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
      finishTeardown(shouldTerminate: true)
      return
    }

    Task { @MainActor in
      var shouldTerminate = true
      do {
        try await helperClient.quitHelper()
        Diag.app.event("app.quit", [("phase", "helper_quit_ok")])
      } catch {
        if Self.blocksNormalTermination(error) {
          shouldTerminate = false
          Self.log.error("quitHelper did not confirm engine reap; cancelling App quit: \(String(describing: error), privacy: .public)")
          Diag.app.event("app.quit", [("phase", "helper_quit_blocked")])
        } else {
          // Best-effort: a transport error may be the Helper exiting before
          // its clean quit reply flushes. Proceed rather than trapping the
          // user in a false-negative quit failure.
          Self.log.notice("quitHelper failed (proceeding to terminate): \(String(describing: error), privacy: .public)")
          Diag.app.event("app.quit", [("phase", "helper_quit_err")])
        }
      }
      Diag.app.event("app.quit", [("phase", "done")])
      finishTeardown(shouldTerminate: shouldTerminate)
    }
  }

  private static func blocksNormalTermination(_ error: Error) -> Bool {
    if error is EngineError {
      return true
    }
    if let clientError = error as? AppXPCClientError,
       case .replyTimeout(selector: "quitHelper", timeout: _) = clientError {
      return true
    }
    return false
  }

  private func finishTeardown(shouldTerminate: Bool) {
    if shouldTerminate {
      guard !teardownComplete else { return }
      teardownComplete = true
    } else {
      isQuitting = false
      engineStatusStore?.start()
    }
    let callbacks = pendingDoneCallbacks
    pendingDoneCallbacks.removeAll()
    callbacks.forEach { $0(shouldTerminate) }
  }
}
