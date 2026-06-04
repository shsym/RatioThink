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
    reader: () -> UInt64? = {
      #if DEBUG
      // DEBUG-only seam: honor a `PIE_TEST_PHYSICAL_MEMORY_BYTES` env override
      // so the RAM-aware guardrail can be exercised deterministically across
      // hosts — e.g. the S4 oversized-model GUI test, which must trip
      // `memoryRisk` regardless of the runner's real RAM. Faking the value
      // smaller only ever makes the guardrail STRICTER (it can never green a
      // load that real RAM would block), and the override is compiled out of
      // Release builds, so a shipped app always reports true hardware memory.
      if let raw = ProcessInfo.processInfo.environment["PIE_TEST_PHYSICAL_MEMORY_BYTES"],
         let value = UInt64(raw), value > 0 {
        return value
      }
      #endif
      return ProcessInfo.processInfo.physicalMemory
    }
  ) -> Int64? {
    guard let raw = reader(), raw > 0, raw <= UInt64(Int64.max) else {
      return nil
    }
    return Int64(raw)
  }
}
