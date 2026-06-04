import AppKit

/// Runs the bundled `collect-diagnostics.sh` from inside the app (Help →
/// Collect Diagnostics…) and returns the produced `.zip`. The script is the
/// single source of truth — the same file a user can run standalone from the
/// bundle when the app won't launch. The app is non-sandboxed (see
/// App/RatioThink.entitlements), so spawning `/bin/bash` + `log show`/`spctl`
/// is permitted.
enum DiagnosticsCollector {
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

  /// Collect, then reveal the `.zip` in Finder (or present an alert on failure).
  /// Main-actor entry point for the menu command.
  @MainActor
  static func collectAndReveal() async {
    do {
      let zip = try await collect()
      NSWorkspace.shared.activateFileViewerSelecting([zip])
    } catch {
      let alert = NSAlert()
      alert.messageText = "Couldn't collect diagnostics"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .warning
      alert.runModal()
    }
  }
}
