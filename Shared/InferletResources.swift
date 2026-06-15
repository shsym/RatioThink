import Foundation

/// Resolves the URLs of bundled inferlet artifacts (wasm + manifest)
/// that the `pie serve` subprocess installs at launch time. Ticket
///  item 1 bundles `chat-apc` into
/// `App.app/Contents/Resources/Inferlets/chat-apc/`; this enum is
/// the single read path used by the Swift launcher (item 2) so the
/// "where do the artifacts live" question has one answer and tests
/// can override it cleanly.
public enum InferletResources {
  /// Errors surfaced when a bundled artifact is missing. Each case
  /// names the file that was looked up so the error string is
  /// actionable (`make build-inferlets` not run? stale build?).
  public enum LookupError: Error, CustomStringConvertible, Equatable {
    case missingWasm(name: String, searched: [String])
    case missingManifest(name: String, searched: [String])

    public var description: String {
      switch self {
      case let .missingWasm(name, searched):
        return "InferletResources: wasm '\(name)' not found in bundle (searched: \(searched.joined(separator: ", ")))"
      case let .missingManifest(name, searched):
        return "InferletResources: manifest '\(name)' not found in bundle (searched: \(searched.joined(separator: ", ")))"
      }
    }
  }

  /// Path components written by the postCompileScript in project.yml.
  /// Keep in sync if the layout ever changes.
  private static let subdir = "Inferlets/chat-apc"
  private static let wasmName = "chat-apc.wasm"
  private static let manifestName = "Pie.toml"

  /// Returns the wasm + manifest URLs for the bundled `chat-apc`
  /// inferlet, resolving from:
  ///   1. `bundle` directly (the in-app case — caller is Rational.app), OR
  ///   2. the containing app bundle when `bundle` is an embedded
  ///      helper (`Rational.app/Contents/Library/LoginItems/RationalHelper.app`
  ///      walks two levels up).
  ///
  /// Step 2 lets RatioThinkHelper consume the artifacts without us
  /// double-bundling them into the helper too; the wasm is ~242 KiB
  /// and `cp`-duplicating it across two targets is gratuitous when
  /// RationalHelper already lives inside Rational.app's wrapper.
  public static func pieControl(in bundle: Bundle = .main) throws -> (wasm: URL, manifest: URL) {
    let searchBundles = candidateBundles(starting: bundle)
    let wasm = try locate(name: wasmName, in: searchBundles) { searched in
      .missingWasm(name: wasmName, searched: searched)
    }
    let manifest = try locate(name: manifestName, in: searchBundles) { searched in
      .missingManifest(name: manifestName, searched: searched)
    }
    return (wasm, manifest)
  }

  // MARK: - private

  /// Canonical embed layout is
  /// `Rational.app/Contents/Library/LoginItems/RationalHelper.app` — FOUR
  /// `deletingLastPathComponent()` hops from the helper bundle to
  /// reach the containing `Rational.app`. The prior `0..<3` bound stopped
  /// at `Rational.app/Contents` and never found the parent (review v150
  /// F6). Six gives two extra levels of headroom for a future
  /// versioned LoginItems subdir, matching `HelperAppDelegate
  /// .pieAppAncestorMaxDepth` and `LaunchSpecResolver.bundleWalkMaxDepth`.
  private static let bundleWalkMaxDepth = 6
  private static let xcodeSiblingAppName = "Rational.app"

  private static func candidateBundles(starting bundle: Bundle) -> [Bundle] {
    var out: [Bundle] = []
    var seen = Set<String>()

    func appendBundle(at url: URL) {
      let key = url.standardizedFileURL.path
      guard !seen.contains(key),
            url.pathExtension == "app",
            let candidate = Bundle(url: url) else { return }
      seen.insert(key)
      out.append(candidate)
    }

    appendBundle(at: bundle.bundleURL)
    var url = bundle.bundleURL
    for _ in 0..<bundleWalkMaxDepth {
      // Xcode UI tests can launch the RatioThinkHelper target as a
      // standalone sibling of Rational.app instead of from the production
      // embedded LoginItems path. Include that sibling so the GUI
      // harness exercises the same single-bundled app resources
      // production uses without duplicating them into RationalHelper.app.
      appendBundle(at: url.deletingLastPathComponent()
        .appendingPathComponent(xcodeSiblingAppName, isDirectory: true))
      url = url.deletingLastPathComponent()
      if url.pathExtension == "app" {
        appendBundle(at: url)
        break
      }
      if url.path == "/" { break }
    }
    return out
  }

  private static func locate(name: String,
                              in bundles: [Bundle],
                              error: ([String]) -> LookupError) throws -> URL {
    var searched: [String] = []
    let (base, ext) = splitExtension(name)
    for b in bundles {
      let candidate = b.bundleURL
        .appendingPathComponent("Contents/Resources/\(subdir)/\(name)")
      searched.append(candidate.path)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      // Fall back to Bundle.url(forResource:withExtension:subdirectory:)
      // so a future xcodegen layout change that uses the standard
      // resources subdirectory mechanism still resolves.
      if let viaAPI = b.url(forResource: base, withExtension: ext, subdirectory: subdir) {
        return viaAPI
      }
    }
    throw error(searched)
  }

  private static func splitExtension(_ name: String) -> (base: String, ext: String?) {
    guard let dot = name.lastIndex(of: ".") else { return (name, nil) }
    let base = String(name[..<dot])
    let ext = String(name[name.index(after: dot)...])
    return (base, ext)
  }
}
