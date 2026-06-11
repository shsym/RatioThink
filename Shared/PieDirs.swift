import Foundation

/// Typed errors thrown by PieDirs when the configured root or one of
/// its subdirectories cannot be created/configured. Callers that own a
/// UI surface (Helper status bar, App settings pane) catch these and
/// offer recovery; the legacy `*.fatalError` convenience accessors
/// `try!` on the throwing variants for code paths that genuinely
/// cannot proceed without storage.
public enum PieDirsError: Error, CustomStringConvertible, Equatable {
  case rootMkdirFailed(path: String, underlying: String)
  case subdirMkdirFailed(name: String, path: String, underlying: String)
  case excludeFromBackupFailed(path: String, underlying: String)
  /// Catch-all for non-PieDirsError failures that surfaced through a
  /// throwing PieDirs call path. Used by Helper's `eagerProbePieDirs`
  /// so the alert can show the real message without inventing a fake
  /// `<unknown>` filesystem path that would mislead `existingAncestor`
  /// + the Reveal-in-Finder affordance (review v5 F8).
  case unknown(underlying: String)

  public var description: String {
    switch self {
    case let .rootMkdirFailed(path, underlying):
      return "PieDirs root mkdir failed at \(path): \(underlying)"
    case let .subdirMkdirFailed(name, path, underlying):
      return "PieDirs subdir '\(name)' mkdir failed at \(path): \(underlying)"
    case let .excludeFromBackupFailed(path, underlying):
      return "PieDirs setResourceValues(.isExcludedFromBackup) failed at \(path): \(underlying)"
    case let .unknown(underlying):
      return "PieDirs unexpected error: \(underlying)"
    }
  }
}

/// Resolves Rational's on-disk locations. Default root is
/// `~/Library/Application Support/RatioThink/`. Tests and other isolated runs
/// override it via either the in-process `homeOverride` injection seam
/// (a `@TaskLocal` so concurrent test methods cannot alias each other)
/// or the `PIE_HOME` environment variable (used by Helper, pie
/// subprocess, and any out-of-process consumer that inherits env from
/// the test harness).
///
/// Resolution order: `homeOverride` → `$PIE_HOME` → system default.
///
/// All FS failures are surfaced as `PieDirsError`. Callers with a UI
/// surface (Helper status bar, App settings) recover gracefully; the
/// non-throwing `*OrTrap` convenience accessors `try!` for paths that
/// genuinely cannot proceed without storage (most tests, eager helper
/// boot probe). See .
public enum PieDirs {
  /// Env var consulted before the system default. Used by Helper and
  /// any subprocess that inherits env (pie engine, etc).
  public static let homeEnvVar = "PIE_HOME"

  /// Per-task injection seam for tests. `@TaskLocal` so concurrent
  /// setUp/test/tearDown invocations on separate tasks never alias —
  /// each `withValue { … }` scope sees its own value, eliminating the
  /// process-global race the prior `static var` version had.
  ///
  /// Tests wrap the test body via XCTest's `invokeTest` override:
  ///
  ///     override func invokeTest() {
  ///       PieDirs.$homeOverride.withValue(temp) { super.invokeTest() }
  ///     }
  @TaskLocal public static var homeOverride: URL?

  // MARK: - throwing primitive API

  public static func applicationSupport() throws -> URL {
    let url = resolveRoot()
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw PieDirsError.rootMkdirFailed(path: url.path,
                                         underlying: String(describing: error))
    }
    return url
  }

  public static func profiles()  throws -> URL { try ensureDir("profiles") }
  public static func models()    throws -> URL { try ensureDir("models", markNoBackup: true) }
  public static func inferlets() throws -> URL { try ensureDir("inferlets") }
  public static func logs()      throws -> URL { try ensureDir("logs") }

  public static func chatsSQLite() throws -> URL {
    try applicationSupport().appendingPathComponent("chats.sqlite")
  }
  public static func configTOML() throws -> URL {
    try applicationSupport().appendingPathComponent("config.toml")
  }
  public static func helperUDS() throws -> URL {
    try applicationSupport().appendingPathComponent("helper.sock")
  }

  // MARK: - non-throwing convenience (traps on failure)
  //
  // Use ONLY when there is no meaningful recovery — most test bodies,
  // the eager helper-boot probe. Code that owns a UI surface must call
  // the throwing variants and present an error.

  public static var applicationSupportOrTrap: URL { try! applicationSupport() }
  public static var profilesOrTrap:           URL { try! profiles() }
  public static var modelsOrTrap:             URL { try! models() }
  public static var inferletsOrTrap:          URL { try! inferlets() }
  public static var logsOrTrap:               URL { try! logs() }

  /// Canonical profiles directory URL **without** creating it (
  /// review F3). App startup constructs a long-lived `ProfileStore`
  /// before any UI error surface exists; pointing it at the real
  /// location (and letting `ProfileStore.start()` create the dir and
  /// surface any failure to `PersistenceStatus`) is correct, whereas a
  /// throwing pre-resolve forces a silent temp-dir fallback that hides
  /// the user's real profiles. Pure path composition — no side effects.
  public static func profilesURL() -> URL {
    resolveRoot().appendingPathComponent("profiles", isDirectory: true)
  }

  /// Canonical models directory URL **without** creating it or mutating
  /// attributes — for read-only callers (a model-present existence check
  /// on a SwiftUI render path). Pure path composition, no side effects.
  /// Use the throwing `models()` when you intend to WRITE into the dir: it
  /// ensures the dir exists and excludes it from backup, which are
  /// filesystem mutations that must not run on every render.
  public static func modelsURL() -> URL {
    resolveRoot().appendingPathComponent("models", isDirectory: true)
  }

  // MARK: - internals

  private static func resolveRoot() -> URL {
    if let override = homeOverride {
      return override
    }
    if let env = ProcessInfo.processInfo.environment[homeEnvVar], !env.isEmpty {
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("RatioThink", isDirectory: true)
  }

  private static func ensureDir(_ name: String, markNoBackup: Bool = false) throws -> URL {
    let dir = try applicationSupport().appendingPathComponent(name, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw PieDirsError.subdirMkdirFailed(name: name,
                                           path: dir.path,
                                           underlying: String(describing: error))
    }
    if markNoBackup {
      var dir = dir
      var vals = URLResourceValues()
      vals.isExcludedFromBackup = true
      do {
        try dir.setResourceValues(vals)
      } catch {
        throw PieDirsError.excludeFromBackupFailed(path: dir.path,
                                                   underlying: String(describing: error))
      }
    }
    return dir
  }
}
