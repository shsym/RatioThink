import AppKit
import XCTest

/// Skip when no seated GUI session present (e.g. SSH without Screen Sharing).
///
/// The XCTRunner template ships with `com.apple.security.app-sandbox=true`, so
/// `Process` cannot exec `/usr/bin/pgrep`. Query the workspace instead — the
/// Dock's bundle identifier is stable and `runningApplications` is
/// sandbox-safe.
func guardSeatedGUI() throws {
  let dockRunning = NSWorkspace.shared.runningApplications.contains { app in
    app.bundleIdentifier == "com.apple.dock"
  }
  try XCTSkipUnless(dockRunning,
                    "No seated GUI session detected (Dock not running). " +
                    "Connect via Screen Sharing / sit at the console to run GUI tests.")
}

func configureCompletedFirstLaunch(
  _ app: XCUIApplication,
  suiteName: String = "com.ratiothink.app.gui." + UUID().uuidString
) {
  app.launchEnvironment["PIE_APP_PREFERENCES_SUITE"] = suiteName
  app.launchEnvironment["PIE_TEST_FIRST_LAUNCH_COMPLETED"] = "1"
}

func stablePreferenceSuiteName(_ seed: String) -> String {
  let safe = seed.map { char -> Character in
    char.isLetter || char.isNumber ? char : "."
  }
  return "com.ratiothink.app.gui." + String(safe).prefix(180)
}

// MARK: - Seeded model fixture

/// Presence check for the `Qwen3-0.6B-Q8_0.gguf` weight the seeded "chat"
/// profile resolves to, so a GUI test can drive the helper past
/// `modelMissing` into `Engine: stopped`.
///
/// Source resolution: `$PIE_TEST_MODEL` override, else repo-root
/// `test-models/Qwen3-0.6B-Q8_0.gguf` (provisioned by
/// `Scripts/stage-test-model.sh`, which symlinks it from the HF cache).
/// When neither resolves, `require` throws `XCTSkip` with the exact staging
/// instruction so the suite reports honestly instead of hard-failing on a
/// fresh checkout. `stage` copies it into a test's `PIE_HOME/models` so the
/// helper resolves the seeded "chat" profile via the app-staged path — the
/// only path that resolves a GGUF-only default model (see `stage`).
enum SeededModelFixture {
  static let file = "Qwen3-0.6B-Q8_0.gguf"

  /// Walk up from `path` to the directory containing `Package.swift`.
  static func repoRoot(file path: StaticString = #filePath) throws -> URL {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: "\(path)", isDirectory: false).deletingLastPathComponent()
    while !fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
      let parent = dir.deletingLastPathComponent()
      if parent == dir {
        throw NSError(domain: "GUITestHelpers", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "repo root (Package.swift) not found above \(path)"
        ])
      }
      dir = parent
    }
    return dir
  }

  /// Resolved fixture URL, or `XCTSkip` with the exact staging instruction.
  static func require(file path: StaticString = #filePath) throws -> URL {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["PIE_TEST_MODEL"], !override.isEmpty {
      let url = URL(fileURLWithPath: override)
      try XCTSkipUnless(fm.fileExists(atPath: url.path),
                        "PIE_TEST_MODEL=\(override) but no file there — stage \(file) or unset PIE_TEST_MODEL")
      return url
    }
    let url = try repoRoot(file: path)
      .appendingPathComponent("test-models/\(file)", isDirectory: false)
    try XCTSkipUnless(
      fm.fileExists(atPath: url.path),
      "model fixture missing at \(url.path) — run `Scripts/stage-test-model.sh` "
        + "(symlinks it from the HF cache, or prints the huggingface-cli download command) "
        + "or set PIE_TEST_MODEL")
    return url
  }

  /// Place the fixture at `<modelsDir>/Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`
  /// as a REGULAR file. This is the resolution path the default GGUF model
  /// actually uses: `LaunchSpecResolver.hfIdentity` maps the seeded slug to
  /// `(repo, file: nil)`, and the HF-cache fallback then demands a COMPLETE
  /// snapshot (config.json + tokenizer + weights) — which a GGUF-only repo
  /// like `Qwen/Qwen3-0.6B-GGUF` never has — so only the app-staged path
  /// resolves. The staged file must be REGULAR: `validateAppStagedModel`
  /// rejects a symlink (`attributesOfItem` → `.typeSymbolicLink`). Resolve
  /// the fixture's real path (it is itself a symlink into the HF cache) and
  /// hard-link it (copy across volumes) — both yield a regular file.
  @discardableResult
  static func stage(_ source: URL, intoModels modelsDir: URL) throws -> URL {
    let fm = FileManager.default
    let dest = modelsDir
      .appendingPathComponent("Qwen", isDirectory: true)
      .appendingPathComponent("Qwen3-0.6B-GGUF", isDirectory: true)
      .appendingPathComponent(file, isDirectory: false)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    let realSource = source.resolvingSymlinksInPath()
    do {
      try fm.linkItem(at: realSource, to: dest)
    } catch {
      try fm.copyItem(at: realSource, to: dest)
    }
    return dest
  }
}
