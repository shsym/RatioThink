import Foundation

/// Host physical RAM — the basis for the RAM-aware model-size
/// guardrail. The default reader uses `ProcessInfo.physicalMemory`,
/// which is `hw.memsize` (the same number Activity Monitor reports as
/// "Memory"). The reader is injectable so tests can drive the
/// unknown-RAM fallback without depending on the test host's actual
/// memory.
public enum SystemMemory {
  /// Total physical memory in bytes, or `nil` when it cannot be read
  /// (reader returned nil/zero, or a value that does not fit `Int64`).
  /// Callers treat `nil` as "RAM unknown" and fall back to a
  /// conservative fixed ceiling rather than blocking every load.
  public static func physicalBytes(
    reader: () -> UInt64? = { ProcessInfo.processInfo.physicalMemory }
  ) -> Int64? {
    guard let raw = reader(), raw > 0, raw <= UInt64(Int64.max) else {
      return nil
    }
    return Int64(raw)
  }
}
