import Foundation

/// Memory-aware, conservative per-request output-token ceiling for the
/// engine launch config (#438).
///
/// chat-apc's per-request `max_tokens` ceiling follows the engine via
/// `runtime::max-output-tokens`, which returns the scheduler's
/// `default_token_limit` when set. We compute that limit pre-launch from
/// what the host can actually hold: how many tokens of F16 KV cache fit
/// in the RAM budget after the model weights and a conservative overhead,
/// clamped to the model's context window and the engine's default KV-pool
/// capacity.
///
/// This is **down-only**: it never raises the ceiling above the engine's
/// default pool capacity (we do not resize the pool). It only *lowers*
/// the ceiling — and surfaces an honest clean-400 — when a large model on
/// limited RAM, or a short context window, can't sustain the default.
/// `default_token_limit` caps TOTAL forwarded tokens (prompt + output),
/// which matches a KV-capacity number since KV holds the whole context;
/// bounding the output `max_tokens` by it is conservative (output ≤ total
/// is always safe).
public enum KVCacheBudget {
  /// KV page size in tokens — pie's `kv_page_size` default
  /// (`server/src/config.rs` `default_kv_page_size() = 32`). One pool page
  /// holds this many tokens of KV.
  public static let kvPageSizeTokens: Int = 32

  /// Engine default KV-pool page count — pie's portable-driver
  /// `max_num_kv_pages` default (`server/src/config.rs` `= 1024`). Used as
  /// the divisor-free fallback when a `LaunchSpec` leaves `maxNumKvPages`
  /// `nil` (the production case — the launcher does not override it).
  public static let defaultMaxNumKvPages: Int = 1024

  /// Engine default KV-pool capacity in tokens = `kvPageSizeTokens *
  /// defaultMaxNumKvPages` (32 × 1024 = 32768). The pool is not resized, so
  /// this is the hard upper bound; an override is only written when it would
  /// LOWER the ceiling below this.
  public static let defaultPoolCapacityTokens: Int = kvPageSizeTokens * defaultMaxNumKvPages

  /// The effective per-request output-token ceiling the engine ENFORCES for a
  /// launched session, derived from the two `LaunchSpec` knobs the helper owns.
  /// Mirrors pie `runtime::max_output_tokens` exactly
  /// (`Vendor/pie/runtime/src/model.rs` `output_token_ceiling_for_model`):
  ///
  ///   `effective = default_token_limit.unwrap_or(kvCap).min(kvCap)`
  ///   `kvCap     = (max_num_kv_pages ?? defaultMaxNumKvPages) * kvPageSizeTokens`
  ///
  /// There is deliberately **no** `minCeilingTokens` floor here: that 512 floor
  /// lives only in `outputTokenCeiling` (the pre-launch EMIT path, which floors
  /// `default_token_limit` before it is written). pie's runtime applies no floor,
  /// so this OBSERVE-path value matches what `GET /v1/models` reports as
  /// `max_output_tokens`. Because the helper sets both knobs, it can publish this
  /// in the session snapshot without an engine round-trip (insight 184: pie
  /// always allocates the full default pool in production — no RAM backoff — so
  /// the `nil`-knobs production case equals the engine's `kvCap`).
  public static func effectiveOutputCeiling(defaultTokenLimit: Int?,
                                            maxNumKvPages: Int?) -> Int {
    let kvCap = (maxNumKvPages ?? defaultMaxNumKvPages) * kvPageSizeTokens
    return min(defaultTokenLimit ?? kvCap, kvCap)
  }

  /// Conservative overhead reserved on top of the weights before KV:
  /// `max(floor, fraction * weights)` (activations, compute/graph
  /// buffers, framework + fragmentation). Biased high → ceiling biased
  /// low → never OOM.
  public static let overheadFloorBytes: Int64 = 1 * 1024 * 1024 * 1024  // 1 GiB
  public static let overheadFraction: Double = 0.15

  /// Usability floor after RAM fitting. Below this the model nearly fills
  /// RAM and KV is squeezed, but `default_token_limit` must be > 0 and a
  /// tiny positive cap keeps chat minimally usable. The model's context
  /// window remains the hard cap, even when it is below this floor.
  public static let minCeilingTokens: Int = 512

  /// Returns the value to write as `[model.scheduler].default_token_limit`,
  /// or `nil` to omit it (engine keeps its default pool cap — no clamp).
  ///
  /// `ceiling = min( floor((threshold − weights − overhead) / kv_per_token),
  ///                 defaultPoolCapacityTokens, contextLength )`, raised
  /// to `minCeilingTokens` only when doing so does not exceed
  /// `contextLength`. `nil` when the RAM-fit ceiling is at or above the
  /// pool capacity AND the context window is too (i.e. nothing to clamp).
  /// `threshold` is the size guardrail's RAM-derived ceiling, so the
  /// operator's RAM-fraction dial scales this too.
  public static func outputTokenCeiling(
    policy: ModelMemoryGuardrail.Policy,
    weightBytes: Int64,
    metadata: ModelArchMetadata
  ) -> Int? {
    let kvPerToken = metadata.kvBytesPerToken
    guard kvPerToken > 0, weightBytes >= 0 else { return nil }

    let threshold = policy.maxResolvedModelBytes
    let overhead = max(overheadFloorBytes, Int64(Double(weightBytes) * overheadFraction))
    let kvBudget = threshold - weightBytes - overhead
    let ramFit = kvBudget > 0 ? Int(kvBudget / kvPerToken) : 0

    let ceiling = min(ramFit, defaultPoolCapacityTokens, metadata.contextLength)
    // Only emit when it actually lowers the ceiling below the engine
    // default; otherwise the default pool cap already binds.
    guard ceiling < defaultPoolCapacityTokens else { return nil }
    return min(metadata.contextLength, max(minCeilingTokens, ceiling))
  }
}
