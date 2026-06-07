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
  /// Engine default KV-pool capacity in tokens = `kv_page_size (32) *
  /// default max_num_kv_pages (1024)`. The pool is not resized, so this
  /// is the hard upper bound; an override is only written when it would
  /// LOWER the ceiling below this.
  public static let defaultPoolCapacityTokens: Int = 32 * 1024  // 32768

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
