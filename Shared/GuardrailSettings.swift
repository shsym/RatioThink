import Foundation

/// User-tunable memory-guardrail settings, persisted as a small JSON
/// file in the support root (`PieDirs.applicationSupport`) so it
/// crosses the App↔Helper boundary the same way `ProfileStore` does —
/// `UserDefaults` is container-private without an app group and the
/// guardrail runs in the Helper.
///
/// Only `ramFraction` is user-exposed in v1; the reserve term stays a
/// `ModelMemoryGuardrail.Policy` constant. Reads distinguish three cases
/// instead of flattening them: an *absent* file is the legitimate unset
/// state and yields `defaultFraction`; a *present-but-unreadable or
/// corrupt* file throws `LoadError` so the operator's lost ceiling
/// surfaces instead of silently reverting (symmetric with `saveFraction`,
/// which throws by design); a *present, decodable but out-of-range* value
/// is recoverable and clamps. Callers that must not brick (the Helper
/// launch gate) catch the throw, log it, and fall back to the default.
public enum GuardrailSettings {
  /// Why a load can fail loudly instead of silently reverting to
  /// `defaultFraction`: a present-but-bad file means the operator's
  /// persisted ceiling is being lost, and collapsing that into the
  /// default is indistinguishable from "unset" — callers must be able to
  /// tell them apart to surface (Settings) or log (launch gate) the loss.
  public enum LoadError: Error, CustomStringConvertible {
    /// File exists but couldn't be read (I/O, permissions).
    case unreadable(URL, underlying: Error)
    /// File exists and was read but isn't valid guardrail JSON, or holds a
    /// non-finite fraction that no clamp can recover.
    case corrupt(URL, underlying: Error?)

    public var description: String {
      switch self {
      case let .unreadable(url, underlying):
        return "guardrail.json unreadable at \(url.path): \(underlying)"
      case let .corrupt(url, underlying):
        return "guardrail.json corrupt at \(url.path)" + (underlying.map { ": \($0)" } ?? "")
      }
    }
  }

  /// Default fraction when unset — the guardrail's own default (0.65).
  public static var defaultFraction: Double { ModelMemoryGuardrail.Policy.defaultRAMFraction }
  public static let minFraction: Double = 0.50
  public static let maxFraction: Double = 0.95
  /// Stepper granularity for the Settings dial.
  public static let step: Double = 0.05

  /// Segmented dial presets. An on-disk value not equal to one of these
  /// reads as "Custom" in the UI.
  public static let presets: [(label: String, value: Double)] = [
    ("Conservative", 0.55),
    ("Balanced", 0.65),
    ("Aggressive", 0.80),
  ]

  /// Clamp any fraction into the supported range.
  public static func clamp(_ fraction: Double) -> Double {
    guard fraction.isFinite else { return defaultFraction }
    return min(maxFraction, max(minFraction, fraction))
  }

  /// Human-readable percent rendering of a fraction for the Settings dial
  /// readout (e.g. `0.65` → `"65%"`). The dial snaps to a 0.05 (5%) grid,
  /// so a whole-percent label is exact and reads far clearer than the raw
  /// `"0.65"`. A non-finite value falls back to the default's label rather
  /// than rendering `"naN%"`.
  public static func percentLabel(_ fraction: Double) -> String {
    let value = fraction.isFinite ? fraction : defaultFraction
    return "\(Int((value * 100).rounded()))%"
  }

  /// `true` when `fraction` matches a preset (within half a step), so
  /// the dial can highlight that preset vs. show "Custom".
  public static func matchingPreset(_ fraction: Double) -> Double? {
    presets.first { abs($0.value - fraction) < step / 2 }?.value
  }

  static func fileURL(root: URL) -> URL {
    root.appendingPathComponent("guardrail.json", isDirectory: false)
  }

  /// Persisted RAM fraction, clamped into range.
  ///
  /// Returns `defaultFraction` only when the file is *absent* (the unset
  /// state). A present-but-unreadable or corrupt file throws `LoadError`
  /// so a lost operator ceiling surfaces rather than silently reverting to
  /// the default. A decodable, finite-but-out-of-range value is a
  /// recoverable stale write and clamps — not an error.
  public static func loadFraction(root: URL, fileManager: FileManager = .default) throws -> Double {
    let url = fileURL(root: root)
    guard fileManager.fileExists(atPath: url.path) else { return defaultFraction }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw LoadError.unreadable(url, underlying: error)
    }
    let stored: Stored
    do {
      stored = try JSONDecoder().decode(Stored.self, from: data)
    } catch {
      throw LoadError.corrupt(url, underlying: error)
    }
    guard stored.ramFraction.isFinite else {
      throw LoadError.corrupt(url, underlying: nil)
    }
    return clamp(stored.ramFraction)
  }

  /// Persist `fraction` (clamped) atomically. Throws on write failure so
  /// the UI can surface it rather than silently keeping a value that
  /// won't reach the Helper.
  public static func saveFraction(_ fraction: Double,
                                  root: URL,
                                  fileManager: FileManager = .default) throws {
    let data = try JSONEncoder().encode(Stored(ramFraction: clamp(fraction)))
    try data.write(to: fileURL(root: root), options: .atomic)
  }

  private struct Stored: Codable {
    var ramFraction: Double
  }
}
