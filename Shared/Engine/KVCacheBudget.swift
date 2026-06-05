import Foundation

/// Memory-aware sizing for the engine's KV-cache pool (`max_num_kv_pages`).
///
/// The portable driver allocates `max_num_kv_pages * kv_page_size` tokens
/// of KV cache up front at launch, and that pool is the real per-request
/// output ceiling the engine can serve — chat-apc reads it back via
/// `runtime::max-output-tokens` (#438 Phase 1). The driver's fixed default
/// (1024 pages = 32768 tokens) ignores how much RAM the host has, so a
/// roomy Mac is capped no higher than a small one.
///
/// This sizes the *request* from host RAM. It deliberately does NOT try to
/// compute the exact KV byte cost (which needs per-model n_layers /
/// n_kv_heads / head_dim / dtype the App cannot cheaply read for GGUF).
/// Instead it scales the page COUNT by available RAM and leans on the
/// portable driver's launch-time backoff as the safety net: on an
/// allocation OOM the driver halves `max_num_kv_pages` (down to 64) and
/// reports the actual count it settled on (`driver/portable/src/entry.cpp`).
/// So an over-request is clamped to what physically fits — including room
/// already taken by the loaded weights, since KV is allocated after the
/// model loads — and chat-apc then follows the *actual* post-backoff
/// capacity. The request is only emitted when it *raises* the pool above
/// the engine default (a small host keeps today's behavior, never
/// regressing), and is capped so a large host does not reserve KV slots
/// far beyond any model's usable context window.
///
/// Precise per-model sizing (a driver-side budget→pages computation where
/// the exact dims live) is the planned refinement; this is the lean, safe
/// first cut that the driver backoff keeps honest.
public enum KVCacheBudget {
  /// KV page size the request assumes and writes — matches the portable
  /// driver default, so capacity-in-tokens = pages * this.
  public static let pageSize: UInt32 = 32

  /// Engine default `max_num_kv_pages` (portable driver). Sizing at or
  /// below this returns `nil` so the launcher omits the override and the
  /// engine keeps its own default — a low-RAM host never regresses, and
  /// the driver backoff still handles the rare case where even the
  /// default does not fit.
  public static let defaultPages: UInt32 = 1024

  /// Upper bound on the requested pool. 4096 pages * 32 = 131072 tokens —
  /// generous headroom over the 32768 default, comfortably covering
  /// common local-model context windows (32k–128k) without reserving KV
  /// slots no model could address.
  public static let maxPages: UInt32 = 4096

  /// Usable RAM (physical − reserve) at which the default pool is kept
  /// (scale factor 1.0). Picked so a ~16 GB Mac (≈10 GiB usable after the
  /// 6 GiB reserve) maps to the default and larger hosts scale up
  /// proportionally.
  public static let referenceUsableBytes: Int64 = 10 * 1024 * 1024 * 1024

  /// Recommended `max_num_kv_pages` for the host, or `nil` when RAM is
  /// unknown or the host is not roomy enough to exceed the engine default
  /// (caller omits the override → engine keeps its own default). Derived
  /// from the same `ModelMemoryGuardrail.Policy` the size guardrail uses,
  /// so the operator's RAM-fraction dial scales both.
  public static func recommendedMaxPages(
    for policy: ModelMemoryGuardrail.Policy
  ) -> UInt32? {
    guard let physical = policy.physicalMemoryBytes, physical > 0 else {
      return nil
    }
    let reserve = policy.reserveBytes ?? ModelMemoryGuardrail.Policy.defaultReserveBytes
    let fraction = policy.ramFraction ?? ModelMemoryGuardrail.Policy.defaultRAMFraction
    let usable = max(0, physical - reserve)

    // Scale the page count by how much usable RAM the host has relative
    // to the reference, then by the operator's aggressiveness dial
    // (fraction / default). Over-requests are safe — the driver clamps.
    let ramScale = Double(usable) / Double(referenceUsableBytes)
    let fractionScale = fraction / ModelMemoryGuardrail.Policy.defaultRAMFraction
    let scaled = Double(defaultPages) * ramScale * fractionScale
    guard scaled.isFinite, scaled > 0 else { return nil }

    let rounded = Int64(scaled.rounded())
    // Only emit the override when it actually raises the pool above the
    // engine default; clamp to the cap.
    guard rounded > Int64(defaultPages) else { return nil }
    return UInt32(min(Int64(maxPages), rounded))
  }
}
