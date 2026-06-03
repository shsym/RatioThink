import Foundation
import XCTest
@testable import RatioThinkCore

/// Unit coverage for the "Check for Updates…" core (#411): the lenient
/// version parse/compare, the pure status decision, and the GitHub release
/// fetch (stubbed via the shared `MockURLProtocol` — no network leaves the
/// process). The AppKit `NSAlert` presentation in `App/Services/UpdateChecker`
/// is GUI-only; this target proves every decision feeding it.
final class UpdateCheckTests: XCTestCase {

  // MARK: - SemanticVersion parsing

  func test_semanticVersion_parsesPlainAndVPrefixed() {
    XCTAssertEqual(SemanticVersion("0.1.0")?.components, [0, 1, 0])
    XCTAssertEqual(SemanticVersion("v0.1.1")?.components, [0, 1, 1])
    XCTAssertEqual(SemanticVersion("V2.3.4")?.components, [2, 3, 4])
    XCTAssertEqual(SemanticVersion("  v1.0  ")?.components, [1, 0])
  }

  func test_semanticVersion_dropsPreReleaseAndBuildMetadata() {
    XCTAssertEqual(SemanticVersion("0.1.1-rc.1")?.displayString, "0.1.1")
    XCTAssertEqual(SemanticVersion("1.2.0+build.5")?.components, [1, 2, 0])
    XCTAssertEqual(SemanticVersion("v0.2.0-beta+exp")?.components, [0, 2, 0])
  }

  func test_semanticVersion_rejectsNonNumeric() {
    XCTAssertNil(SemanticVersion(""))
    XCTAssertNil(SemanticVersion("v"))
    XCTAssertNil(SemanticVersion("nightly"))
    XCTAssertNil(SemanticVersion("1.x.0"))
    XCTAssertNil(SemanticVersion("1..0"))   // empty middle component
  }

  func test_semanticVersion_ordersByComponents() {
    XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
    XCTAssertLessThan(SemanticVersion("0.1.9")!, SemanticVersion("0.2.0")!)
    XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
    XCTAssertGreaterThan(SemanticVersion("1.0.0")!, SemanticVersion("0.9.99")!)
  }

  func test_semanticVersion_missingTrailingComponentsCompareAsZero() {
    let short = SemanticVersion("1.2")!
    let padded = SemanticVersion("1.2.0")!
    XCTAssertFalse(short < padded)
    XCTAssertFalse(padded < short)   // i.e. equal ordering — 1.2 == 1.2.0
  }

  func test_semanticVersion_equatableAndHashableMatchZeroPaddedOrdering() {
    // `==` and `hash` must agree with the zero-padded `<` (Comparable's
    // total-order law) — the synthesized versions would not.
    XCTAssertEqual(SemanticVersion("1.2")!, SemanticVersion("1.2.0")!)
    XCTAssertEqual(SemanticVersion("0.1")!, SemanticVersion("0.1.0")!)
    XCTAssertNotEqual(SemanticVersion("1.2")!, SemanticVersion("1.2.1")!)
    // Equal values collapse in a Set (hash consistent with ==).
    XCTAssertEqual(Set([SemanticVersion("1.2")!, SemanticVersion("1.2.0")!]).count, 1)
    XCTAssertEqual(Set([SemanticVersion("1.2")!, SemanticVersion("1.2.1")!]).count, 2)
  }

  // MARK: - UpdateCheck.status decision

  private func release(_ tag: String) -> UpdateCheck.Release {
    UpdateCheck.Release(
      tagName: tag,
      htmlURL: URL(string: "https://github.com/shsym/RatioThink/releases/tag/\(tag)")!
    )
  }

  func test_status_updateAvailable_whenReleaseIsNewer() {
    let status = UpdateCheck.status(current: "0.1.0", latest: release("v0.1.1"))
    guard case let .updateAvailable(current, latest, rel) = status else {
      return XCTFail("expected .updateAvailable, got \(status)")
    }
    XCTAssertEqual(current, "0.1.0")
    XCTAssertEqual(latest, "0.1.1")              // normalized, no leading v
    XCTAssertEqual(rel.tagName, "v0.1.1")        // raw tag preserved for the link
  }

  func test_status_upToDate_whenEqual() {
    XCTAssertEqual(
      UpdateCheck.status(current: "v0.1.1", latest: release("0.1.1")),
      .upToDate(current: "0.1.1")
    )
  }

  func test_status_upToDate_whenRunningAheadOfRelease() {
    // A local dev build can be ahead of the latest published release; that
    // must read as up-to-date, never as a spurious "update available".
    XCTAssertEqual(
      UpdateCheck.status(current: "0.2.0", latest: release("v0.1.1")),
      .upToDate(current: "0.2.0")
    )
  }

  func test_status_indeterminate_whenEitherVersionUnparseable() {
    if case .indeterminate = UpdateCheck.status(current: "dev", latest: release("v0.1.1")) {} else {
      XCTFail("unparseable current must be .indeterminate")
    }
    if case .indeterminate = UpdateCheck.status(current: "0.1.0", latest: release("nightly")) {} else {
      XCTFail("unparseable latest must be .indeterminate")
    }
  }

  // MARK: - launchPrompt (ignore-set layered over status)

  func test_launchPrompt_promptsForNewerNonIgnoredRelease() {
    let prompt = UpdateCheck.launchPrompt(current: "0.1.0",
                                          latest: release("v0.1.1"),
                                          ignoredVersions: [])
    XCTAssertEqual(prompt, .prompt(current: "0.1.0", latest: "0.1.1", release: release("v0.1.1")))
  }

  func test_launchPrompt_silentWhenLatestIsIgnored() {
    // Ignore-set stores normalized displayStrings ("0.1.1"), not the raw tag.
    XCTAssertEqual(
      UpdateCheck.launchPrompt(current: "0.1.0", latest: release("v0.1.1"), ignoredVersions: ["0.1.1"]),
      .silent
    )
  }

  func test_launchPrompt_newerVersionResurfacesAfterAnIgnore() {
    // 0.1.1 was dismissed; a strictly newer 0.1.2 is NOT in the set, so it
    // prompts again — the "never re-surface until a newer one ships" contract.
    let ignored: Set<String> = ["0.1.1"]
    XCTAssertEqual(
      UpdateCheck.launchPrompt(current: "0.1.0", latest: release("v0.1.1"), ignoredVersions: ignored),
      .silent
    )
    XCTAssertEqual(
      UpdateCheck.launchPrompt(current: "0.1.0", latest: release("v0.1.2"), ignoredVersions: ignored),
      .prompt(current: "0.1.0", latest: "0.1.2", release: release("v0.1.2"))
    )
  }

  func test_launchPrompt_silentWhenUpToDateOrIndeterminate() {
    XCTAssertEqual(
      UpdateCheck.launchPrompt(current: "0.1.1", latest: release("v0.1.1"), ignoredVersions: []),
      .silent
    )
    XCTAssertEqual(
      UpdateCheck.launchPrompt(current: "0.1.0", latest: release("nightly"), ignoredVersions: []),
      .silent
    )
  }

  // MARK: - Slug / URL guards (drift tripwire)

  func test_feedURLs_pointAtPublicRepo() {
    XCTAssertEqual(UpdateCheck.repositorySlug, "shsym/RatioThink")
    XCTAssertEqual(UpdateCheck.releasesPageURL.absoluteString,
                   "https://github.com/shsym/RatioThink/releases")
    XCTAssertEqual(UpdateCheck.latestReleaseAPIURL.absoluteString,
                   "https://api.github.com/repos/shsym/RatioThink/releases/latest")
  }

  // MARK: - GitHubReleaseFeed (stubbed transport)

  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  private func stubbedFeed() -> GitHubReleaseFeed {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    cfg.timeoutIntervalForRequest = 5
    return GitHubReleaseFeed(session: URLSession(configuration: cfg))
  }

  private func httpResponse(_ url: URL, _ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
  }

  func test_feed_decodesLatestRelease() async throws {
    let body = """
    {"tag_name": "v0.1.1",
     "html_url": "https://github.com/shsym/RatioThink/releases/tag/v0.1.1",
     "name": "RatioThink 0.1.1"}
    """
    MockURLProtocol.handler = { request in
      // Confirm the feed hits the documented public endpoint with a UA
      // (GitHub 403s a missing User-Agent).
      XCTAssertEqual(request.url, UpdateCheck.latestReleaseAPIURL)
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "RatioThink")
      return (self.httpResponse(request.url!, 200), Data(body.utf8))
    }

    let rel = try await stubbedFeed().latestRelease()
    XCTAssertEqual(rel.tagName, "v0.1.1")
    XCTAssertEqual(rel.htmlURL.absoluteString,
                   "https://github.com/shsym/RatioThink/releases/tag/v0.1.1")
  }

  func test_feed_throwsNoPublishedRelease_on404() async {
    MockURLProtocol.handler = { request in
      (self.httpResponse(request.url!, 404), Data("{}".utf8))
    }
    await assertFeedThrows(.noPublishedRelease)
  }

  func test_feed_throwsHTTPStatus_onServerError() async {
    MockURLProtocol.handler = { request in
      (self.httpResponse(request.url!, 503), Data())
    }
    await assertFeedThrows(.httpStatus(503))
  }

  func test_feed_throwsMalformedPayload_onGarbageBody() async {
    MockURLProtocol.handler = { request in
      (self.httpResponse(request.url!, 200), Data("not json".utf8))
    }
    await assertFeedThrows(.malformedPayload)
  }

  func test_feed_throwsMalformedPayload_onEmptyTag() async {
    let body = #"{"tag_name": "", "html_url": "https://example.com"}"#
    MockURLProtocol.handler = { request in
      (self.httpResponse(request.url!, 200), Data(body.utf8))
    }
    await assertFeedThrows(.malformedPayload)
  }

  /// End-to-end of the surface's non-AppKit half: a stubbed feed flows into
  /// the pure decision exactly as `UpdateChecker.checkForUpdates` wires it.
  func test_feedThenStatus_yieldsUpdateAvailable() async throws {
    let body = #"{"tag_name": "v0.1.1", "html_url": "https://github.com/shsym/RatioThink/releases/tag/v0.1.1"}"#
    MockURLProtocol.handler = { request in
      (self.httpResponse(request.url!, 200), Data(body.utf8))
    }
    let rel = try await stubbedFeed().latestRelease()
    XCTAssertEqual(UpdateCheck.status(current: "0.1.0", latest: rel),
                   .updateAvailable(current: "0.1.0", latest: "0.1.1", release: rel))
  }

  private func assertFeedThrows(_ expected: UpdateCheckError,
                               file: StaticString = #filePath,
                               line: UInt = #line) async {
    do {
      _ = try await stubbedFeed().latestRelease()
      XCTFail("expected \(expected) to be thrown", file: file, line: line)
    } catch let error as UpdateCheckError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("expected UpdateCheckError.\(expected), got \(error)", file: file, line: line)
    }
  }
}
