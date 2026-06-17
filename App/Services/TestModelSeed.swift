import Foundation

/// DEBUG-only seed seam that stages an UNVERIFIED model fixture for the #678
/// chat-dropdown mark GUI guard (`S678_UnverifiedModelMarkGUITests`).
///
/// The XCUITest runner is sandboxed and cannot write into `PIE_HOME/models`
/// (it hits `Operation not permitted`); the non-sandboxed app can, so it stages
/// the fixture here from `PIE_TEST_SEED_UNVERIFIED_MODEL=<slug>`: a few-byte
/// `.gguf` at `<modelsRoot>/<slug>` plus its `<…>.gguf.unverified` sidecar —
/// exactly what `InstalledModels.scan` reads to set `isUnverified`, so the
/// model surfaces as an unverified row in the toolbar dropdown without any
/// engine or network. No-op unless the env var is set; the `#if DEBUG` call
/// site plus the isolated `PIE_HOME` every GUI suite uses keep a shipped app
/// from ever seeding.
enum TestModelSeed {
  static let envVar = "PIE_TEST_SEED_UNVERIFIED_MODEL"

  static func seedIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard let slug = environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !slug.isEmpty else { return }
    do {
      let root = try PieDirs.models()
      var modelURL = root
      for segment in slug.split(separator: "/", omittingEmptySubsequences: true) {
        modelURL.appendPathComponent(String(segment), isDirectory: false)
      }
      try FileManager.default.createDirectory(
        at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: modelURL.path) {
        try Data("gguf-test-bytes".utf8).write(to: modelURL)
      }
      // The `.unverified` sidecar marks the placed-but-unverified download
      // (InstalledModels.unverifiedSuffix) — its presence is what makes the
      // scan flag the row.
      let sidecarPath = modelURL.path + InstalledModels.unverifiedSuffix
      if !FileManager.default.fileExists(atPath: sidecarPath) {
        try Data().write(to: URL(fileURLWithPath: sidecarPath))
      }
    } catch {
      NSLog("TestModelSeed: failed to stage unverified fixture for \(slug): \(error)")
    }
  }
}
