import XCTest
@testable import RatioThinkCore

/// #438 — conservative, down-only memory-aware output-token ceiling.
/// Injects a fixed-threshold `Policy` + explicit weights + metadata so
/// every case is deterministic (no host-RAM dependency).
final class KVCacheBudgetTests: XCTestCase {

  private func gib(_ n: Double) -> Int64 { Int64(n * 1024 * 1024 * 1024) }
  private func policy(thresholdGiB: Double) -> ModelMemoryGuardrail.Policy {
    ModelMemoryGuardrail.Policy(maxResolvedModelBytes: gib(thresholdGiB))
  }
  // Qwen3-0.6B-shaped: 28 layers, 8 KV heads, 128 head_dim → 112 KiB/token.
  private func meta(ctx: Int = 40960) -> ModelArchMetadata {
    ModelArchMetadata(numLayers: 28, numKVHeads: 8, headDim: 128, contextLength: ctx)
  }

  func test_kvBytesPerToken_matches_pie_formula() {
    // 4 * 28 * 8 * 128 = 114688 (= 2(K+V) * L * kvH * dim * 2(F16)).
    XCTAssertEqual(meta().kvBytesPerToken, 114_688)
  }

  func test_ram_constrained_lowers_ceiling_below_default() {
    // threshold 8 GiB, weights 4 GiB, overhead = max(1 GiB, 0.6 GiB) = 1 GiB.
    // kvBudget = 3 GiB; ramFit = floor(3 GiB / 114688) = 28086.
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 8), weightBytes: gib(4), metadata: meta())
    XCTAssertEqual(c, 28_086)
  }

  func test_context_window_clamps_even_with_roomy_ram() {
    // Roomy RAM but a 4096-context model → ceiling clamps to the window.
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 32), weightBytes: gib(1), metadata: meta(ctx: 4096))
    XCTAssertEqual(c, 4096)
  }

  func test_context_window_clamp_remains_authoritative_below_minimum_floor() {
    // The minimum usability floor must not raise an override above the
    // model's hard context-window limit.
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 32), weightBytes: gib(1), metadata: meta(ctx: 256))
    XCTAssertEqual(c, 256)
  }

  func test_omits_when_host_sustains_default_pool() {
    // Roomy RAM + context window ≥ default pool → nothing to clamp → nil.
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 64), weightBytes: gib(1), metadata: meta(ctx: 40960))
    XCTAssertNil(c)
  }

  func test_never_exceeds_default_pool_capacity() {
    // Even with a 128k context window and huge RAM, the ceiling is never
    // written above the 32768 default (down-only; pool is not resized).
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 256), weightBytes: gib(1), metadata: meta(ctx: 131072))
    XCTAssertNil(c, "ceiling at/above the pool default must be omitted, not written")
  }

  func test_tight_fit_floors_to_minimum() {
    // weights nearly fill the threshold → negative KV budget → floored to
    // the minimum positive cap (default_token_limit must be > 0).
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 5), weightBytes: gib(4.8), metadata: meta())
    XCTAssertEqual(c, KVCacheBudget.minCeilingTokens)
  }

  func test_overhead_fraction_dominates_for_large_weights() {
    // 40 GiB weights → overhead = max(1 GiB, 0.15*40 = 6 GiB) = 6 GiB.
    // threshold 64 GiB → kvBudget = 64-40-6 = 18 GiB; ramFit = floor(18 GiB/114688).
    let expected = Int(gib(18) / 114_688)  // 168550
    let c = KVCacheBudget.outputTokenCeiling(
      policy: policy(thresholdGiB: 64), weightBytes: gib(40), metadata: meta(ctx: 200000))
    // ramFit (168550) > pool default → clamped to default → omitted.
    XCTAssertNil(c)
    XCTAssertGreaterThan(expected, KVCacheBudget.defaultPoolCapacityTokens)
  }

  // MARK: - effectiveOutputCeiling (#476 OBSERVE path)

  func test_effectiveCeiling_both_nil_is_default_pool() {
    // Production case: launcher overrides neither knob → kvCap = 1024*32 = 32768
    // and there is no scheduler cap → effective = 32768.
    XCTAssertEqual(
      KVCacheBudget.effectiveOutputCeiling(defaultTokenLimit: nil, maxNumKvPages: nil),
      32_768)
  }

  func test_effectiveCeiling_matches_pie_unit_test() {
    // pie's own model.rs test: output_token_ceiling_for_model(Some(4096), 1024) == 1024.
    // kvCap = 32 pages * 32 = 1024; default_token_limit 4096 is clamped DOWN to kvCap.
    XCTAssertEqual(
      KVCacheBudget.effectiveOutputCeiling(defaultTokenLimit: 4096, maxNumKvPages: 32),
      1024)
  }

  func test_effectiveCeiling_scheduler_cap_binds_when_below_kvCap() {
    // default pool (32768), scheduler cap 8000 → min = 8000.
    XCTAssertEqual(
      KVCacheBudget.effectiveOutputCeiling(defaultTokenLimit: 8000, maxNumKvPages: nil),
      8000)
  }

  func test_effectiveCeiling_kvCap_binds_when_pages_override_lowers_it() {
    // maxNumKvPages 256 → kvCap = 256*32 = 8192; no scheduler cap → effective = 8192.
    XCTAssertEqual(
      KVCacheBudget.effectiveOutputCeiling(defaultTokenLimit: nil, maxNumKvPages: 256),
      8192)
  }

  func test_effectiveCeiling_no_512_floor_on_observe_path() {
    // The 512 floor is EMIT-path only; the observe path mirrors pie's runtime
    // which applies no floor. 8 pages * 32 = 256 → effective = 256, not 512.
    XCTAssertEqual(
      KVCacheBudget.effectiveOutputCeiling(defaultTokenLimit: nil, maxNumKvPages: 8),
      256)
  }

  func test_effectiveCeiling_scheduler_cap_above_pool_is_clamped_to_pool() {
    // A scheduler cap above the pool can never raise the ceiling above kvCap.
    XCTAssertEqual(
      KVCacheBudget.effectiveOutputCeiling(defaultTokenLimit: 40_000, maxNumKvPages: nil),
      32_768)
  }
}
