import Foundation

/// Off-main-actor discovery of installed models for the Settings
/// surfaces. Both the profile picker and the Models tab need the
/// app-managed scan (a recursive walk) AND the HF-cache scan (a
/// recursive walk per cached repo); running both on the main actor janks
/// the UI on a large/cold cache. This hops the filesystem work onto a
/// detached task and returns a `Sendable` snapshot the caller assigns
/// back on the main actor.
///
/// The HF scan runs regardless of an app-dir failure and is always
/// returned, so a permission glitch on the app models directory never
/// hides independently-discoverable HF-cache models.
enum CachedModelScan {
  struct Result: Sendable {
    /// App models directory when it was prepared (even if the scan then
    /// failed) — the Add-Model sheet + drop import need it. `nil` only
    /// when `PieDirs.models()` itself threw.
    let modelsDirectory: URL?
    let appManaged: [InstalledModel]
    /// Non-nil when the models directory could not be prepared OR the
    /// app-managed scan failed; carries the underlying error detail. HF
    /// rows are still valid either way.
    let appError: String?
    let huggingFaceCache: [InstalledModel]
  }

  static func run() async -> Result {
    await Task.detached(priority: .userInitiated) {
      let hf = HFCacheCatalog.scan(hfHome: LaunchSpecResolver.defaultHFHome())
      let dir: URL
      do {
        // PieDirs.models() CREATES the dir and throws a rich PieDirsError
        // (failing path + OS error) on disk-full / read-only / perms.
        // Preserve that detail rather than try?-swallowing it.
        dir = try PieDirs.models()
      } catch {
        return Result(modelsDirectory: nil, appManaged: [],
                      appError: "Could not prepare the models directory: \(error)",
                      huggingFaceCache: hf)
      }
      do {
        let app = try InstalledModels.scan(dir)
        return Result(modelsDirectory: dir, appManaged: app, appError: nil,
                      huggingFaceCache: hf)
      } catch {
        return Result(modelsDirectory: dir, appManaged: [],
                      appError: "Could not read installed models: \(error)",
                      huggingFaceCache: hf)
      }
    }.value
  }
}
