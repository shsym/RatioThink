import Foundation
import XCTest
@testable import RatioThinkCore

/// LIVE integration test against the real GitHub Releases API — the one path
/// the hermetic `MockURLProtocol` tests can't exercise. OFF by default so CI
/// stays network-free; opt in with `PIE_TEST_REAL_GITHUB=1` (mirrors the
/// project's real-e2e env gating, e.g. the real-engine suites). Makes exactly
/// one request to `api.github.com/repos/shsym/RatioThink/releases/latest` and
/// asserts the production `GitHubReleaseFeed` decode + `UpdateCheck` compare
/// work against real data.
final class UpdateCheckLiveGitHubTests: XCTestCase {
  /// MARKETING_VERSION / CFBundleShortVersionString shipped by the app
  /// (project.yml). Used only for the informational "what would the app show"
  /// line — the assertions don't depend on it so they survive a version bump.
  private static let shippingAppVersion = "0.1.0"

  func test_liveLatestRelease_decodesAndComparesAgainstRealReleases() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PIE_TEST_REAL_GITHUB"] == "1",
      "Live GitHub Releases test is opt-in (one real network call). " +
      "Set PIE_TEST_REAL_GITHUB=1 to run."
    )

    let feed = GitHubReleaseFeed()
    let release: UpdateCheck.Release
    do {
      release = try await feed.latestRelease()
    } catch UpdateCheckError.noPublishedRelease {
      // The documented 404 path: no published (non-draft, non-prerelease)
      // release yet. The feature stays silent / shows "couldn't check" — not a
      // failure, just nothing to assert about a release that doesn't exist.
      throw XCTSkip("shsym/RatioThink has no published release (/latest → 404).")
    }

    // 1. Decode shape: a usable tag and a github.com release page.
    XCTAssertFalse(release.tagName.isEmpty, "real tag_name must be non-empty")
    XCTAssertEqual(release.htmlURL.host, "github.com",
                   "release html_url host drifted: \(release.htmlURL)")

    // 2. The real tag must parse — proves SemanticVersion handles the actual
    //    tag scheme in use (e.g. the leading-v "v0.1.0").
    let latest = try XCTUnwrap(
      SemanticVersion(release.tagName),
      "real tag '\(release.tagName)' did not parse as a version"
    )

    // 3. Compare works against live data, both directions:
    //    a very old running version sees an update; the release's own version
    //    is up to date.
    guard case .updateAvailable = UpdateCheck.status(current: "0.0.0", latest: release) else {
      return XCTFail("0.0.0 vs real \(release.tagName) should be .updateAvailable")
    }
    XCTAssertEqual(
      UpdateCheck.status(current: latest.displayString, latest: release),
      .upToDate(current: latest.displayString)
    )

    // 4. Report exactly what the SHIPPING app would show right now.
    let appWouldShow = UpdateCheck.status(current: Self.shippingAppVersion, latest: release)
    print("LIVE-GITHUB: latest=\(release.tagName) host=\(release.htmlURL.host ?? "?") "
          + "app(\(Self.shippingAppVersion))WouldShow=\(appWouldShow)")
  }
}
