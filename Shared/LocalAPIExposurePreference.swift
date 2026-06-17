import Foundation

/// File-backed Local API exposure preference shared by the App and Helper.
///
/// `UserDefaults.standard` is process-domain scoped for this app/helper pair
/// (`com.ratiothink.app` vs `com.ratiothink.app.helper`), so security-critical
/// launch posture must live in the shared PieDirs root, like guardrail.json and
/// ProfileStore. Reads are defensive: missing/corrupt files fall back to the
/// safe loopback posture.
public enum LocalAPIExposurePreference {
  public static let fileName = "local-api.json"

  public struct Store {
    public var loadEnabled: () -> Bool?
    public var saveEnabled: (Bool) throws -> Void

    public init(loadEnabled: @escaping () -> Bool?,
                saveEnabled: @escaping (Bool) throws -> Void) {
      self.loadEnabled = loadEnabled
      self.saveEnabled = saveEnabled
    }

    public static func live(root: URL) -> Store {
      Store(
        loadEnabled: { LocalAPIExposurePreference.loadEnabled(root: root) },
        saveEnabled: { try LocalAPIExposurePreference.saveEnabled($0, root: root) }
      )
    }

    public static func live() -> Store {
      Store(
        loadEnabled: {
          guard let root = try? PieDirs.applicationSupport() else { return nil }
          return LocalAPIExposurePreference.loadEnabled(root: root)
        },
        saveEnabled: {
          let root = try PieDirs.applicationSupport()
          try LocalAPIExposurePreference.saveEnabled($0, root: root)
        }
      )
    }
  }

  public static func fileURL(root: URL) -> URL {
    root.appendingPathComponent(fileName, isDirectory: false)
  }

  public static func loadEnabled(root: URL, fileManager: FileManager = .default) -> Bool? {
    let url = fileURL(root: root)
    guard fileManager.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      return nil
    }
    return stored.externalAccessEnabled
  }

  public static func loadBindMode(root: URL, fileManager: FileManager = .default) -> EngineHTTPBindMode {
    loadEnabled(root: root, fileManager: fileManager) == true ? .external : .loopback
  }

  public static func saveEnabled(_ enabled: Bool,
                                 root: URL,
                                 fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(Stored(externalAccessEnabled: enabled))
    try data.write(to: fileURL(root: root), options: .atomic)
  }

  private struct Stored: Codable {
    var externalAccessEnabled: Bool
  }
}
