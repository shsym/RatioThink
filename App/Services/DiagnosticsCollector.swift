import AppKit

/// Runs the bundled `collect-diagnostics.sh` from inside the app (Help →
/// Collect Diagnostics…) and returns the produced `.zip`. The script is the
/// single source of truth — the same file a user can run standalone from the
/// bundle when the app won't launch. The app is non-sandboxed (see
/// App/RatioThink.entitlements), so spawning `/bin/bash` + `log show`/`spctl`
/// is permitted.
enum DiagnosticsCollector {
  static let runningMessage = "Collecting diagnostics…"

  static func successMessage(_ zip: URL) -> String {
    "Diagnostics bundle created: \(zip.lastPathComponent)"
  }

  #if DEBUG
  private static func debugDelayNanoseconds(environmentKey: String, defaultMilliseconds: UInt64) -> UInt64 {
    let raw = ProcessInfo.processInfo.environment[environmentKey]
    let milliseconds = raw.flatMap(UInt64.init) ?? defaultMilliseconds
    return milliseconds * 1_000_000
  }
  #endif

  enum CollectError: LocalizedError {
    case scriptMissing
    case launchFailed(String)
    case scriptFailed(code: Int32, tail: String)
    case noBundlePath

    var errorDescription: String? {
      switch self {
      case .scriptMissing:
        return "The diagnostics script is missing from the app bundle."
      case let .launchFailed(detail):
        return "Couldn't start the diagnostics script: \(detail)"
      case let .scriptFailed(code, tail):
        return "The diagnostics script exited with code \(code).\n\(tail)"
      case .noBundlePath:
        return "The diagnostics script finished but did not report a bundle path."
      }
    }
  }

  /// Spawn the bundled script and parse its `Bundle: <path>` line. Runs the
  /// blocking `Process` work off the main actor; call from a `Task`.
  static func collect() async throws -> URL {
    #if DEBUG
    if let fakeZip = ProcessInfo.processInfo.environment["PIE_TEST_DIAGNOSTICS_FAKE_ZIP"],
       !fakeZip.isEmpty {
      let url = URL(fileURLWithPath: fakeZip)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: url.path) {
        try Data().write(to: url)
      }
      try? await Task.sleep(nanoseconds: debugDelayNanoseconds(
        environmentKey: "PIE_TEST_DIAGNOSTICS_DELAY_MS",
        defaultMilliseconds: 150
      ))
      return url
    }
    #endif

    guard let script = Bundle.main.url(forResource: "collect-diagnostics",
                                       withExtension: "sh") else {
      throw CollectError.scriptMissing
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      throw CollectError.launchFailed(String(describing: error))
    }
    // Drain before waitUntilExit so a large `log show` payload cannot deadlock
    // on a full pipe buffer.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)

    guard process.terminationStatus == 0 else {
      let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
      throw CollectError.scriptFailed(code: process.terminationStatus, tail: tail)
    }

    guard let line = output.split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.hasPrefix("Bundle: ") }) else {
      throw CollectError.noBundlePath
    }
    let path = line.dropFirst("Bundle: ".count).trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { throw CollectError.noBundlePath }
    return URL(fileURLWithPath: path)
  }

  /// Collect, then reveal the `.zip` in Finder. Callers own failure feedback so
  /// the user sees one surface (banner/overlay), not a modal plus inline error.
  @MainActor
  @discardableResult
  static func collectAndReveal() async -> URL? {
    do {
      let zip = try await collect()
      NSWorkspace.shared.activateFileViewerSelecting([zip])
      return zip
    } catch {
      NSLog("Couldn't collect diagnostics: \(error.localizedDescription)")
      return nil
    }
  }
}
