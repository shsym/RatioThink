import Foundation

/// One sample of the running engine's resident memory, taken Helper-side
/// via `proc_pid_rusage` on the pie process the Helper spawned.
///
/// Optional on the wire: a `nil` `EngineMemorySample?` reply means the
/// engine is not running, or the sample could not be taken. The GUI
/// reads this on-demand while the status popover is open (never as a
/// globally-published field — a per-second RSS publish would re-render
/// the toolbar that hosts the popover and dismiss it).
///
/// `residentBytes` measures the parent pie process only. If pie spawns
/// worker children this undercounts; summing the process group is a
/// deliberate follow-up, not a v1 requirement.
public struct EngineMemorySample: Codable, Equatable, Sendable {
  public let residentBytes: UInt64
  public let sampledAt: Date

  public init(residentBytes: UInt64, sampledAt: Date = Date()) {
    self.residentBytes = residentBytes
    self.sampledAt = sampledAt
  }

  /// Build a sample from a raw resident-bytes reading, or `nil` when the
  /// reading is not a valid live measurement. 0 is NEVER valid: a live
  /// engine is never 0-resident, so 0 only appears on the dead/reaped
  /// path (the `PieControlLauncher` sampler already gates it). Collapsing
  /// 0 → nil at this construction boundary keeps the wire-type's "sample
  /// failure ⇒ nil" contract true regardless of the producer, so a
  /// "0 MB" row can never render.
  public static func from(residentBytes: UInt64, sampledAt: Date = Date()) -> EngineMemorySample? {
    guard residentBytes > 0 else { return nil }
    return EngineMemorySample(residentBytes: residentBytes, sampledAt: sampledAt)
  }

  /// Quiet readout string for the popover row. Mirrors the MB/GB
  /// convention `ModelLoadPopover.formatMB` already uses so the popover
  /// reads consistently: GB (2 dp) at/above 1024 MB, else whole MB.
  public var formattedResident: String {
    let mb = Double(residentBytes) / (1024.0 * 1024.0)
    if mb >= 1024 {
      return String(format: "%.2f GB", mb / 1024.0)
    }
    return String(format: "%.0f MB", mb)
  }
}
