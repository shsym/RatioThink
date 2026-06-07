import Foundation

/// Imports a user-supplied GGUF file (drag-drop or *Open…* picker) into
/// the Rational models directory. Lives in `Shared/` so the same logic can
/// run from the App, from a unit test, or eventually from a CLI tool.
public enum ModelImporter {

  public enum ImportError: Error, CustomStringConvertible, Equatable {
    case notAFile(path: String)
    case wrongExtension(path: String)
    case destinationExists(path: String)
    case copyFailed(path: String, underlying: String)

    public var description: String {
      switch self {
      case .notAFile(let p):          return "ModelImporter: '\(p)' is not a regular file"
      case .wrongExtension(let p):    return "ModelImporter: '\(p)' must have a .gguf extension"
      case .destinationExists(let p): return "ModelImporter: a model already exists at \(p)"
      case let .copyFailed(p, why):   return "ModelImporter: copy to \(p) failed: \(why)"
      }
    }
  }

  /// Copy `source` into `modelsDirectory`, preserving its basename.
  ///
  /// Validation:
  ///   · file must exist and be a regular file (not a directory)
  ///   · extension must be `.gguf` (case-insensitive)
  ///   · target name must not already be present in `modelsDirectory`
  /// we do NOT silently overwrite, since that would erase a
  ///     model the user already loaded.
  ///
  /// Phase 3.8 returns the destination URL on success; the caller
  /// (`AddModelSheet`) re-scans the directory to refresh the list.
  @discardableResult
  public static func importFile(at source: URL,
                                 into modelsDirectory: URL,
                                 fileManager: FileManager = .default) throws -> URL {
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDir),
          !isDir.boolValue else {
      throw ImportError.notAFile(path: source.path)
    }
    guard source.pathExtension.lowercased() == InstalledModels.modelExtension else {
      throw ImportError.wrongExtension(path: source.path)
    }
    let destination = modelsDirectory.appendingPathComponent(source.lastPathComponent)
    if fileManager.fileExists(atPath: destination.path) {
      throw ImportError.destinationExists(path: destination.path)
    }
    // Ensure parent exists — `PieDirs.models()` would have created it
    // on a normal run, but tests inject scratch dirs that may not
    // have the path yet.
    try fileManager.createDirectory(at: modelsDirectory,
                                    withIntermediateDirectories: true)
    do {
      try fileManager.copyItem(at: source, to: destination)
    } catch {
      throw ImportError.copyFailed(path: destination.path,
                                    underlying: String(describing: error))
    }
    return destination
  }
}
