import Foundation
import Combine

/// App-scoped state for the launch-time update check (#411). Holds the
/// pending "a newer, non-ignored release is available" prompt that the
/// non-modal `UpdateAvailableBanner` renders.
///
/// The pure show/suppress decision lives in `UpdateCheck.launchPrompt`; this
/// owns the async GitHub fetch, the once-per-launch guard, and the persisted
/// ignore-set integration. Kept in RatioThinkCore (no AppKit) so the launch
/// check and ignore wiring are unit-testable without the app — inject a stub
/// `ReleaseFeed` and a scratch `AppPreferences`. The AppKit side effect of
/// "Download" (opening the release page) stays in the view.
@MainActor
public final class UpdateAvailabilityModel: ObservableObject {
  /// A newer release the user has not ignored. `nil` means nothing to show:
  /// up to date, the version was ignored, the check failed, or it has not run.
  public struct Pending: Equatable, Sendable {
    /// Normalized latest version, e.g. `"0.1.1"` — also the ignore-set key.
    public let latest: String
    public let release: UpdateCheck.Release

    public init(latest: String, release: UpdateCheck.Release) {
      self.latest = latest
      self.release = release
    }
  }

  @Published public private(set) var pending: Pending?

  private let feed: ReleaseFeed
  private let currentVersion: String
  private var didRunLaunchCheck = false

  public init(feed: ReleaseFeed = GitHubReleaseFeed(),
              currentVersion: String = UpdateAvailabilityModel.bundleShortVersion()) {
    self.feed = feed
    self.currentVersion = currentVersion
  }

  /// The running app's marketing version. `nonisolated` so it is usable as a
  /// default argument (evaluated outside the main actor).
  nonisolated public static func bundleShortVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  /// Run the GitHub check once per launch and publish a `pending` prompt only
  /// for a newer, non-ignored release. Silent on any failure (network/parse →
  /// no banner). Idempotent: a second call (e.g. a SwiftUI view re-running its
  /// `.task`) is a no-op, so the network is hit at most once per launch.
  public func checkOnLaunch(preferences: AppPreferences) async {
    guard !didRunLaunchCheck else { return }
    // Burn the one-shot only on a COMPLETED attempt. If SwiftUI cancels
    // RootView's `.task` mid-fetch, refresh reports "not completed" and the
    // guard stays armed so a later launch (or re-`task`) can retry; a real
    // GitHub failure (404/HTTP/parse) is a completed attempt and burns it.
    if await refresh(ignoredVersions: preferences.ignoredUpdateVersions) {
      didRunLaunchCheck = true
    }
  }

  /// Fetch the latest release and apply the launch decision against
  /// `ignoredVersions`. Returns `true` when a real attempt completed (success
  /// or a genuine GitHub failure), and `false` only when the attempt was
  /// cancelled — so the caller keeps its once-per-launch guard armed for a
  /// retry. Stays silent (no banner) on any failure. Factored out of the
  /// once-guard so tests can drive the decision directly with different
  /// ignore-sets.
  @discardableResult
  func refresh(ignoredVersions: Set<String>) async -> Bool {
    let release: UpdateCheck.Release
    do {
      release = try await feed.latestRelease()
    } catch {
      pending = nil
      // A cancelled launch `.task` surfaces here. URLSession maps task
      // cancellation to `URLError.cancelled`, which `GitHubReleaseFeed`
      // re-wraps as `UpdateCheckError.transport` — so detect cancellation by
      // `Task.isCancelled` (production) OR the raw cancellation error types
      // (direct propagation / tests), never the wrapped error alone.
      if error is CancellationError || Task.isCancelled { return false }
      if let urlError = error as? URLError, urlError.code == .cancelled { return false }
      return true
    }
    switch UpdateCheck.launchPrompt(current: currentVersion,
                                    latest: release,
                                    ignoredVersions: ignoredVersions) {
    case let .prompt(_, latest, rel):
      pending = Pending(latest: latest, release: rel)
    case .silent:
      pending = nil
    }
    return true
  }

  /// Persist the pending version into the ignore-set and clear the banner. A
  /// strictly newer release is not in the set, so it surfaces on a later
  /// launch.
  public func ignorePending(into preferences: AppPreferences) {
    guard let pending else { return }
    preferences.ignoreUpdateVersion(pending.latest)
    self.pending = nil
  }

  /// Clear the banner after the user chose Download (the view opens the URL).
  public func dismissPending() {
    pending = nil
  }
}
