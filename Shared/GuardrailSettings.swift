import Foundation

/// User-tunable memory-guardrail settings, persisted as a small JSON
/// file in the support root (`PieDirs.applicationSupport`) so it
/// crosses the App↔Helper boundary the same way `ProfileStore` does —
/// `UserDefaults` is container-private without an app group and the
/// guardrail runs in the Helper.
///
/// Only `ramFraction` is user-exposed in v1; the reserve term stays a
/// `ModelMemoryGuardrail.Policy` constant. Reads are defensive: a
/// missing/corrupt/out-of-range file yields the default fraction so a
/// bad write never bricks launches.
public enum GuardrailSettings {
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

  /// Persisted RAM fraction, clamped, or `defaultFraction` when unset /
  /// unreadable / out of range.
  public static func loadFraction(root: URL, fileManager: FileManager = .default) -> Double {
    guard let data = try? Data(contentsOf: fileURL(root: root)),
          let stored = try? JSONDecoder().decode(Stored.self, from: data),
          stored.ramFraction.isFinite else {
      return defaultFraction
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
