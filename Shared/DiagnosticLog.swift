import Foundation

/// Durable, best-effort, append-only lifecycle breadcrumb log. One file per
/// process under `PieDirs.logs()` (App → `app.log`, Helper → `helper.log`) —
/// the user-inspectable / script-collectable companion to Unified Logging,
/// which stays the rich diagnostic stream. This file is what
/// `Scripts/collect-diagnostics.sh` bundles and what survives even after the
/// system log store rotates.
///
/// Contract: writes NEVER throw, block the caller, or crash. Diagnostics must
/// not become a failure source — every I/O step is `try?`'d and dropped on
/// failure. Record only non-sensitive fields (states, codes, counts,
/// durations, versions); `redactHome` strips the home prefix from any path.
/// Never pass tokens, secrets, or chat content.
public final class DiagnosticLog {
  public enum Process: String { case app, helper }

  /// Process-wide singletons. Resolve their target via `PieDirs.logs()` so the
  /// Helper's `$PIE_HOME` is honored.
  public static let app = DiagnosticLog(.app)
  public static let helper = DiagnosticLog(.helper)

  private let proc: Process
  /// Test seam: when set, writes go to `<directory>/<proc>.log` instead of
  /// `PieDirs.logs()`. Lets unit tests isolate without depending on
  /// `PieDirs.$homeOverride` propagating across the GCD writer queue (a
  /// `DispatchQueue.async` block is not a structured child task and would not
  /// inherit the @TaskLocal).
  private let directoryOverride: URL?
  private let queue: DispatchQueue
  /// Rotate when the active file exceeds this many bytes (single `.1` backup).
  private let rotateByteCap: Int

  init(_ proc: Process, directory: URL? = nil, rotateByteCap: Int = 512 * 1024) {
    self.proc = proc
    self.directoryOverride = directory
    self.rotateByteCap = rotateByteCap
    self.queue = DispatchQueue(label: "com.ratiothink.diaglog.\(proc.rawValue)")
  }

  /// Append one breadcrumb line. `fields` render as space-joined `k=v` in the
  /// given order. The target directory is resolved on the CALLING thread (so
  /// `PieDirs.$homeOverride` / `$PIE_HOME` are honored — see `directoryOverride`);
  /// only the file I/O is deferred to the serial queue.
  public func event(_ name: String, _ fields: [(String, String)] = []) {
    let line = Self.render(proc: proc, name: name, fields: fields)
    guard let dir = resolveDirectory() else { return }
    let url = dir.appendingPathComponent("\(proc.rawValue).log")
    queue.async { [rotateByteCap] in
      Self.rotateIfNeeded(url: url, cap: rotateByteCap)
      Self.append(line, to: url)
    }
  }

  /// Collapse the user's home prefix to `~` so breadcrumb paths do not leak the
  /// account name. Pure; safe to call anywhere.
  public static func redactHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard !home.isEmpty, path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
  }

  /// Block until queued writes drain. Test seam only — production callers fire
  /// and forget.
  func flush() { queue.sync {} }

  // MARK: - internals

  private func resolveDirectory() -> URL? {
    if let directoryOverride {
      try? FileManager.default.createDirectory(
        at: directoryOverride, withIntermediateDirectories: true)
      return directoryOverride
    }
    return try? PieDirs.logs()
  }

  static func render(proc: Process, name: String, fields: [(String, String)]) -> String {
    let ts = iso8601.string(from: Date())
    guard !fields.isEmpty else { return "\(ts) \(proc.rawValue) \(name)\n" }
    let kv = fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    return "\(ts) \(proc.rawValue) \(name) \(kv)\n"
  }

  private static func rotateIfNeeded(url: URL, cap: Int) {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
          size > cap else { return }
    let backup = url.appendingPathExtension("1")
    try? fm.removeItem(at: backup)
    try? fm.moveItem(at: url, to: backup)
  }

  private static func append(_ line: String, to url: URL) {
    let data = Data(line.utf8)
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
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()
}

/// Ergonomic alias mirroring the `Log` enum next door (`Log.app` / `Diag.app`).
public enum Diag {
  public static var app: DiagnosticLog { DiagnosticLog.app }
  public static var helper: DiagnosticLog { DiagnosticLog.helper }
}
