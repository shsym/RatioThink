import Foundation
import XCTest
@testable import RatioThinkCore

/// Coverage for the launch-time update check (#411): the `UpdateAvailabilityModel`
/// fetch → decision → publish flow, the once-per-launch guard, and the
/// `AppPreferences` ignore-set round-trip that makes a dismissed version stay
/// silent until a newer one ships. AppKit (the banner, opening the release
/// page) is not exercised here — the model is pure RatioThinkCore.
@MainActor
final class UpdateAvailabilityModelTests: XCTestCase {

  // MARK: - Test doubles / helpers

  /// In-process `ReleaseFeed` stub with a call counter so tests can assert the
  /// network is hit exactly once per launch.
  private final class StubReleaseFeed: ReleaseFeed, @unchecked Sendable {
    enum Outcome {
      case release(UpdateCheck.Release)
      case failure(Error)
    }
    var outcome: Outcome
    private(set) var callCount = 0
    init(_ outcome: Outcome) { self.outcome = outcome }
    func latestRelease() async throws -> UpdateCheck.Release {
      callCount += 1
      switch outcome {
      case let .release(release): return release
      case let .failure(error): throw error
      }
    }
  }

  private func release(_ tag: String) -> UpdateCheck.Release {
    UpdateCheck.Release(
      tagName: tag,
      htmlURL: URL(string: "https://github.com/shsym/RatioThink/releases/tag/\(tag)")!
    )
  }

  /// A scratch `AppPreferences` over an isolated UserDefaults suite, cleaned up
  /// after the test. Returns the suite name so a sibling instance can be built
  /// for the cross-instance round-trip.
  private func makePreferences() -> (AppPreferences, String) {
    let suite = "com.ratiothink.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return (AppPreferences(defaults: defaults), suite)
  }

  // MARK: - checkOnLaunch

  func test_checkOnLaunch_publishesPendingForNewerNonIgnoredRelease() async {
    let feed = StubReleaseFeed(.release(release("v0.1.1")))
    let model = UpdateAvailabilityModel(feed: feed, currentVersion: "0.1.0")
    let (prefs, _) = makePreferences()

    await model.checkOnLaunch(preferences: prefs)

    XCTAssertEqual(model.pending?.latest, "0.1.1")
    XCTAssertEqual(model.pending?.release.tagName, "v0.1.1")
    XCTAssertEqual(feed.callCount, 1, "launch check must hit the feed exactly once")
  }

  func test_checkOnLaunch_silentWhenVersionAlreadyIgnored() async {
    let feed = StubReleaseFeed(.release(release("v0.1.1")))
    let model = UpdateAvailabilityModel(feed: feed, currentVersion: "0.1.0")
    let (prefs, _) = makePreferences()
    prefs.ignoreUpdateVersion("0.1.1")

    await model.checkOnLaunch(preferences: prefs)

    XCTAssertNil(model.pending, "an ignored newer version must not surface on launch")
  }

  func test_checkOnLaunch_silentOnFeedFailure() async {
    let feed = StubReleaseFeed(.failure(UpdateCheckError.noPublishedRelease))
    let model = UpdateAvailabilityModel(feed: feed, currentVersion: "0.1.0")
    let (prefs, _) = makePreferences()

    await model.checkOnLaunch(preferences: prefs)

    XCTAssertNil(model.pending, "a fetch failure must stay silent (no banner)")
    XCTAssertEqual(feed.callCount, 1)
  }

  func test_checkOnLaunch_runsAtMostOncePerLaunch() async {
    let feed = StubReleaseFeed(.release(release("v0.1.1")))
    let model = UpdateAvailabilityModel(feed: feed, currentVersion: "0.1.0")
    let (prefs, _) = makePreferences()

    await model.checkOnLaunch(preferences: prefs)
    await model.checkOnLaunch(preferences: prefs)

    XCTAssertEqual(feed.callCount, 1, "the launch check is one-shot — no second network call")
  }

  func test_checkOnLaunch_reArmsAfterCancellation() async {
    // A cancelled launch `.task` must NOT burn the one-shot — otherwise the
    // banner could never surface again this process despite no completed check.
    let feed = StubReleaseFeed(.failure(CancellationError()))
    let model = UpdateAvailabilityModel(feed: feed, currentVersion: "0.1.0")
    let (prefs, _) = makePreferences()

    await model.checkOnLaunch(preferences: prefs)
    XCTAssertNil(model.pending)
    XCTAssertEqual(feed.callCount, 1)

    // Re-armed: a later launch (or re-`task`) retries.
    await model.checkOnLaunch(preferences: prefs)
    XCTAssertEqual(feed.callCount, 2,
                   "a cancelled launch check must re-arm so it can retry")
  }

  // MARK: - ignore + persistence

  func test_ignorePending_persistsVersionAndClearsBanner() async {
    let feed = StubReleaseFeed(.release(release("v0.1.1")))
    let model = UpdateAvailabilityModel(feed: feed, currentVersion: "0.1.0")
    let (prefs, _) = makePreferences()

    await model.checkOnLaunch(preferences: prefs)
    XCTAssertNotNil(model.pending)

    model.ignorePending(into: prefs)

    XCTAssertNil(model.pending, "ignoring must clear the banner")
    XCTAssertTrue(prefs.ignoredUpdateVersions.contains("0.1.1"),
                  "ignoring must persist the version")
  }

  func test_appPreferences_ignoreRoundTripsAcrossInstances() {
    let suite = "com.ratiothink.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

    let first = AppPreferences(defaults: defaults)
    first.ignoreUpdateVersion("0.1.1")
    XCTAssertEqual(first.ignoredUpdateVersions, ["0.1.1"])

    // A fresh instance over the same suite must read the persisted set —
    // proving the dismissal survives an app relaunch.
    let second = AppPreferences(defaults: defaults)
    XCTAssertTrue(second.ignoredUpdateVersions.contains("0.1.1"))
  }

  func test_resurfaces_whenNewerReleaseShipsAfterIgnore() async {
    let (prefs, _) = makePreferences()

    // Launch 1: ignore 0.1.1.
    let firstFeed = StubReleaseFeed(.release(release("v0.1.1")))
    let firstModel = UpdateAvailabilityModel(feed: firstFeed, currentVersion: "0.1.0")
    await firstModel.checkOnLaunch(preferences: prefs)
    firstModel.ignorePending(into: prefs)
    XCTAssertNil(firstModel.pending)

    // Launch 2 (same persisted prefs): 0.1.1 still latest → silent.
    let stillFeed = StubReleaseFeed(.release(release("v0.1.1")))
    let stillModel = UpdateAvailabilityModel(feed: stillFeed, currentVersion: "0.1.0")
    await stillModel.checkOnLaunch(preferences: prefs)
    XCTAssertNil(stillModel.pending, "the ignored version must stay silent")

    // Launch 3: a newer 0.1.2 ships → surfaces despite the earlier ignore.
    let newerFeed = StubReleaseFeed(.release(release("v0.1.2")))
    let newerModel = UpdateAvailabilityModel(feed: newerFeed, currentVersion: "0.1.0")
    await newerModel.checkOnLaunch(preferences: prefs)
    XCTAssertEqual(newerModel.pending?.latest, "0.1.2",
                   "a strictly newer release must re-surface after an earlier ignore")
  }
}
