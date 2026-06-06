import AppKit

/// #448: the App's quit + window-lifecycle policy. App and Shared compile
/// into one module, so `AppQuitCoordinator` (RatioThinkCore) is reachable
/// directly.
///
/// - Window close (red button / ⌘W) does NOT quit. The product keeps running
///   in the menu bar with the engine still serving; reopen via the menu-bar
///   "Show RatioThink" (#448 Q2). The idle-death fix (#448) is what makes this
///   honest — a backgrounded engine actually stays alive.
/// - ⌘Q, the "Quit RatioThink" menu items, and the Helper's
///   `ratiothink://quit` deep link all route through `NSApp.terminate`, which
///   lands here and performs a coordinated FULL quit via `AppQuitCoordinator`:
///   stop polling, ask the Helper to stop + reap the engine and exit cleanly,
///   then terminate the App. Nothing is left running, and the clean Helper
///   exit means launchd's `KeepAlive { SuccessfulExit: false }` does not
///   relaunch it.
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Window close = background, never quit (#448 Q2).
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Route every real quit through the coordinator. Returning
  /// `.terminateLater` holds the App alive until the Helper has stopped +
  /// reaped the engine, so a quit never orphans `pie`; the coordinator is
  /// bounded so a wedged/absent Helper can't hang the quit.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppQuitCoordinator.shared.beginTeardown {
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
