import AppKit

/// Drives the App-menu "Check for Updates…" command (#411). Reads the
/// running version, fetches the latest GitHub release through a
/// `ReleaseFeed`, and presents an honest `NSAlert`. RatioThink has no
/// in-app auto-update (Sparkle is the future follow-up #178), so this
/// never downloads or installs — at most it opens the release page in the
/// browser. The decision + fetch live in `RatioThinkCore.UpdateCheck`; this
/// type owns only AppKit presentation, mirroring `DiagnosticsCollector`.
@MainActor
enum UpdateChecker {
  /// Menu entry point. `feed` and `currentVersion` are injectable so the
  /// status→alert mapping can be exercised without the network or the real
  /// bundle version.
  static func checkForUpdates(
    feed: ReleaseFeed = GitHubReleaseFeed(),
    currentVersion: String = UpdateChecker.bundleShortVersion()
  ) async {
    let status: UpdateCheck.Status
    do {
      let release = try await feed.latestRelease()
      status = UpdateCheck.status(current: currentVersion, latest: release)
    } catch {
      // Any fetch failure → honest "couldn't check", never a false verdict.
      status = .indeterminate(reason: error.localizedDescription)
    }
    present(status)
  }

  /// The running app's marketing version (`CFBundleShortVersionString`),
  /// e.g. `0.1.0`. Same key `GeneralSettingsTab` reads. `nonisolated` so it
  /// can be a default argument (evaluated outside the main actor); reading
  /// `Bundle.main.infoDictionary` needs no actor isolation.
  nonisolated static func bundleShortVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  /// Present the outcome. Split out (and returning the user's choice) so
  /// the three honest branches are obvious; the side effect is only ever
  /// "open a URL", never an install.
  private static func present(_ status: UpdateCheck.Status) {
    let alert = NSAlert()
    switch status {
    case let .upToDate(current):
      alert.messageText = "You’re up to date"
      alert.informativeText = "RatioThink \(current) is the latest version."
      alert.alertStyle = .informational
      alert.addButton(withTitle: "OK")
      alert.runModal()

    case let .updateAvailable(current, latest, release):
      alert.messageText = "Update available"
      alert.informativeText = """
      RatioThink \(latest) is available — you have \(current). \
      Open the release page on GitHub to download it.
      """
      alert.alertStyle = .informational
      alert.addButton(withTitle: "View Release")
      alert.addButton(withTitle: "Later")
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(release.htmlURL)
      }

    case let .indeterminate(reason):
      alert.messageText = "Couldn’t check for updates"
      alert.informativeText = "\(reason)\n\nYou can check the releases page on GitHub manually."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Open Releases Page")
      alert.addButton(withTitle: "OK")
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(UpdateCheck.releasesPageURL)
      }
    }
  }
}
