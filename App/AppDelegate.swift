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
///   then terminate the App. If the engine cannot be confirmed reaped, normal
///   quit is cancelled and the App stays alive to keep ownership visible.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var quitBlockedAlertVisible = false

  /// Window close = background, never quit (#448 Q2).
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Route every real quit through the coordinator. Returning
  /// `.terminateLater` holds the App alive until the Helper has stopped +
  /// reaped the engine, so a quit never orphans `pie`.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppQuitCoordinator.shared.beginTeardown { shouldTerminate in
      NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
      if !shouldTerminate {
        self.presentQuitBlockedAlert()
      }
    }
    return .terminateLater
  }

  private func presentQuitBlockedAlert() {
    guard !quitBlockedAlertVisible else { return }
    quitBlockedAlertVisible = true
    let alert = NSAlert()
    alert.messageText = "RatioThink is still stopping Pie"
    alert.informativeText = """
    RatioThink will stay open until the engine process has fully stopped. Try \
    Quit again after Pie finishes stopping.
    """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
    quitBlockedAlertVisible = false
  }
}
