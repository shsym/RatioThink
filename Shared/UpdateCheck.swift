import Foundation

/// Pure, AppKit-free core of the "Check for Updates…" surface (#411).
///
/// RatioThink ships via GitHub Releases (a notarized arm64 DMG); there is
/// no in-app auto-update yet (Sparkle is the future follow-up #178). So
/// this is a *manual* check: read the running version, fetch the latest
/// published release, and decide whether the user is behind. The decision
/// and the network fetch live here (Foundation only) so they are unit-
/// testable in the fast `RatioThinkCoreTests` SPM target; the AppKit
/// `NSAlert` presentation lives in `App/Services/UpdateChecker`. This
/// mirrors the existing `HighPriorityAlertGate` (rules in RatioThinkCore) vs
/// `HelperMain` (AppKit) split.
public enum UpdateCheck {
  /// The public GitHub repository the release feed is read from.
  /// Public repo ⇒ the REST call needs no token (avoids the ticket's
  /// credential-overclaim trap).
  public static let repositorySlug = "shsym/RatioThink"

  /// The human-facing releases listing. Used as the honest fallback
  /// target whenever the check can't produce a definite answer.
  public static var releasesPageURL: URL {
    // Force-unwrap: the slug is a compile-time constant with no
    // percent-encoding hazards, so this URL is always well-formed.
    URL(string: "https://github.com/\(repositorySlug)/releases")!
  }

  /// Unauthenticated "latest published release" endpoint. GitHub returns
  /// the most recent non-draft, non-prerelease release, or 404 when none
  /// exists yet — both handled honestly by the caller.
  static var latestReleaseAPIURL: URL {
    URL(string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!
  }

  /// One published GitHub release, decoded from the REST payload.
  public struct Release: Equatable, Sendable {
    /// The git tag, e.g. `v0.1.1`. Parsed leniently by `SemanticVersion`.
    public let tagName: String
    /// The release's web page — what "View Release" opens.
    public let htmlURL: URL

    public init(tagName: String, htmlURL: URL) {
      self.tagName = tagName
      self.htmlURL = htmlURL
    }
  }

  /// Outcome of comparing the running app version to the latest release.
  public enum Status: Equatable, Sendable {
    /// Running version ≥ latest published release.
    case upToDate(current: String)
    /// A newer release exists; carries the release so the UI can link it.
    case updateAvailable(current: String, latest: String, release: Release)
    /// Versions couldn't be compared (malformed tag/version, no release,
    /// or a fetch error). Honest fallback: point the user at the page
    /// rather than claim either "up to date" or "update available".
    case indeterminate(reason: String)
  }

  /// Pure decision: compare a running version string against a fetched
  /// release. A version that fails to parse yields `.indeterminate` —
  /// never a false "up to date" — so the surface stays honest.
  public static func status(current: String, latest: Release) -> Status {
    guard let currentVersion = SemanticVersion(current) else {
      return .indeterminate(
        reason: "Couldn't read this app's version (\"\(current)\")."
      )
    }
    guard let latestVersion = SemanticVersion(latest.tagName) else {
      return .indeterminate(
        reason: "Couldn't read the latest release version (\"\(latest.tagName)\")."
      )
    }
    if latestVersion > currentVersion {
      return .updateAvailable(
        current: currentVersion.displayString,
        latest: latestVersion.displayString,
        release: latest
      )
    }
    return .upToDate(current: currentVersion.displayString)
  }

  /// Launch-time decision: whether to interrupt the user with the non-modal
  /// "update available" banner. Layers the persisted ignore-set on top of
  /// `status` so only a newer release the user has NOT dismissed surfaces on
  /// launch. Pure (no AppKit, no network) — the show/suppress logic is
  /// unit-testable on its own.
  ///
  /// `ignoredVersions` holds normalized version strings (the `displayString`
  /// form, e.g. `"0.1.1"`). Membership is exact, so a dismissed version stays
  /// silent until a strictly newer one ships (a newer tag is not in the set
  /// and therefore prompts). The manual "Check for Updates…" menu command does
  /// NOT call this — it always reports via `status`, bypassing the ignore-set.
  public static func launchPrompt(current: String,
                                  latest: Release,
                                  ignoredVersions: Set<String>) -> LaunchPrompt {
    switch status(current: current, latest: latest) {
    case let .updateAvailable(currentDisplay, latestDisplay, release):
      if ignoredVersions.contains(latestDisplay) {
        return .silent
      }
      return .prompt(current: currentDisplay, latest: latestDisplay, release: release)
    case .upToDate, .indeterminate:
      return .silent
    }
  }

  /// Outcome of the launch-time check after the ignore-set is applied.
  public enum LaunchPrompt: Equatable, Sendable {
    /// Surface the banner for a newer, non-ignored release.
    case prompt(current: String, latest: String, release: Release)
    /// Stay silent: up to date, the newer version is ignored, or the check
    /// was indeterminate (incl. any network/parse failure upstream).
    case silent
  }
}

/// A lenient dotted-integer version (`major.minor.patch…`) parsed from a
/// GitHub tag or a bundle version. Tolerates a leading `v`/`V` and ignores
/// any SemVer pre-release/build metadata (`0.1.1-rc.1+build` → `0.1.1`),
/// which is enough to order RatioThink's `vX.Y.Z` release tags. Returns
/// `nil` on anything non-numeric so the caller falls back to honest
/// "couldn't determine" rather than guessing.
public struct SemanticVersion: Comparable, Hashable, Sendable {
  /// The numeric release components in order, e.g. `[0, 1, 1]`.
  public let components: [Int]
  /// Canonical `joined(".")` form for display, e.g. `0.1.1`.
  public let displayString: String

  public init?(_ raw: String) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = text.first, first == "v" || first == "V" {
      text.removeFirst()
    }
    // Drop pre-release / build metadata: keep only the dotted release core.
    if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
      text = String(text[..<cut])
    }
    guard !text.isEmpty else { return nil }

    var parsed: [Int] = []
    for part in text.split(separator: ".", omittingEmptySubsequences: false) {
      guard let value = Int(part), value >= 0 else { return nil }
      parsed.append(value)
    }
    guard !parsed.isEmpty else { return nil }

    self.components = parsed
    self.displayString = parsed.map(String.init).joined(separator: ".")
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    let width = max(lhs.components.count, rhs.components.count)
    for index in 0..<width {
      // Missing trailing components compare as 0 (1.2 == 1.2.0).
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  /// Equatable consistent with the zero-padded ordering: `1.2 == 1.2.0`
  /// (matches `<`'s missing-trailing-component-as-zero rule). The synthesized
  /// `==` would compare `components`/`displayString` and call them unequal,
  /// breaking the Comparable total-order law (exactly one of `<`, `==`, `>`
  /// must hold) for an otherwise order-equal pair.
  public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }

  /// Hash the canonical (trailing-zero-stripped) form so equal versions hash
  /// equal — `1.2` and `1.2.0` collapse in a `Set`/dictionary, keeping
  /// `Hashable` consistent with the custom `==`.
  public func hash(into hasher: inout Hasher) {
    var canonical = components
    while canonical.count > 1, canonical.last == 0 { canonical.removeLast() }
    hasher.combine(canonical)
  }
}

/// Source of the latest release. Abstracted so the AppKit caller and the
/// unit tests can inject a stub instead of hitting the network.
public protocol ReleaseFeed: Sendable {
  func latestRelease() async throws -> UpdateCheck.Release
}

/// Failure modes of the GitHub release fetch, each with a user-facing
/// `errorDescription` that flows into the "couldn't check" alert.
public enum UpdateCheckError: Error, LocalizedError, Equatable {
  /// No release published yet (`/releases/latest` 404).
  case noPublishedRelease
  /// A non-200, non-404 HTTP status.
  case httpStatus(Int)
  /// 200 OK but the JSON was missing/!decodable into a release.
  case malformedPayload
  /// Transport failure (offline, DNS, TLS, timeout).
  case transport(String)

  public var errorDescription: String? {
    switch self {
    case .noPublishedRelease:
      return "No published release was found on GitHub yet."
    case let .httpStatus(code):
      return "GitHub returned an unexpected response (HTTP \(code))."
    case .malformedPayload:
      return "GitHub's response could not be read."
    case let .transport(detail):
      return "Couldn't reach GitHub: \(detail)"
    }
  }
}

/// Reads the latest release from GitHub's public REST API over `URLSession`.
public struct GitHubReleaseFeed: ReleaseFeed {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func latestRelease() async throws -> UpdateCheck.Release {
    var request = URLRequest(url: UpdateCheck.latestReleaseAPIURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // GitHub rejects API requests with no User-Agent (HTTP 403).
    request.setValue("RatioThink", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw UpdateCheckError.transport(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw UpdateCheckError.transport("No HTTP response")
    }
    if http.statusCode == 404 {
      throw UpdateCheckError.noPublishedRelease
    }
    guard http.statusCode == 200 else {
      throw UpdateCheckError.httpStatus(http.statusCode)
    }

    let payload: Payload
    do {
      payload = try JSONDecoder().decode(Payload.self, from: data)
    } catch {
      throw UpdateCheckError.malformedPayload
    }
    guard let htmlURL = URL(string: payload.htmlURL), !payload.tagName.isEmpty else {
      throw UpdateCheckError.malformedPayload
    }
    return UpdateCheck.Release(tagName: payload.tagName, htmlURL: htmlURL)
  }

  /// The subset of the GitHub release JSON the surface needs.
  private struct Payload: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
    }
  }
}
