import Foundation

/// Durable, best-effort capture of an engine's stdout/stderr failure tail
/// into `engine.log` (#447).
///
/// The production launch path (`PieControlLauncher` / `PieEngineHost`) keeps
/// only the last lines in memory and surfaces them through Unified Logging,
/// which is time-bounded and rotates — so the engine's death output is
/// durably LOST in production, and `Scripts/collect-diagnostics.sh` finds an
/// empty `engine.log`. This writer tees the bounded tail there on death so
/// the failure output survives in the diagnostics bundle.
///
/// Contract (mirrors `DiagnosticLog`): writes NEVER throw, block, or crash —
/// diagnostics must not become a failure source. Lines arrive already
/// token-redacted from `LaunchedSession.diagnosticTail()` and are pie
/// `serve --debug` tracing, never chat content (which rides HTTP/WS, not the
/// engine's stdio — see #358).
public enum EngineLogTail {
  /// Bound on how many tail lines are persisted per death.
  public static let maxLines = 32

  /// Append a bounded `[engine-terminated]`-prefixed block of the given
  /// lines to `engine.log`. The directory is resolved on the CALLING thread
  /// so `PieDirs.$homeOverride` / `$PIE_HOME` are honored (the same
  /// GCD-vs-TaskLocal caveat `DiagnosticLog` documents).
  public static func append(_ lines: [String],
                            directory: URL? = nil) {
    guard !lines.isEmpty else { return }
    let dir: URL
    if let directory {
      try? FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      dir = directory
    } else {
      guard let logs = try? PieDirs.logs() else { return }
      dir = logs
    }
    let url = dir.appendingPathComponent("engine.log")
    let bounded = lines.suffix(maxLines)
    let ts = iso8601.string(from: Date())
    var block = "[\(ts)] [engine-terminated] stderr tail (\(bounded.count) lines):\n"
    for line in bounded { block += "  \(line)\n" }
    append(block, to: url)
  }

  private static func append(_ text: String, to url: URL) {
    let data = Data(text.utf8)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
      try? data.write(to: url, options: .atomic)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  }

  private static let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    return f
  }()
}
