import XCTest
@testable import RatioThinkCore

/// #438 Phase 2 — memory-aware sizing of the engine KV pool. These pin
/// the RAM → `max_num_kv_pages` heuristic so a regression (or a default
/// constant drift) is caught at the unit layer rather than as a
/// surprising launch-time KV allocation. The driver's launch-time backoff
/// is the real safety net; this just verifies the *request* shape.
final class KVCacheBudgetTests: XCTestCase {

  private func policy(
    ramGiB: Double,
    fraction: Double = ModelMemoryGuardrail.Policy.defaultRAMFraction
  ) -> ModelMemoryGuardrail.Policy {
    ModelMemoryGuardrail.Policy.recommended(
      physicalMemoryBytes: Int64(ramGiB * 1024 * 1024 * 1024),
      fraction: fraction
    )
  }

  func test_unknown_ram_returns_nil() {
    // An injected fixed policy carries no RAM context → omit the override
    // so the engine keeps its own default (and the size-guardrail test
    // fixtures don't accidentally drive KV sizing).
    let fixed = ModelMemoryGuardrail.Policy(maxResolvedModelBytes: 8 << 30)
    XCTAssertNil(KVCacheBudget.recommendedMaxPages(for: fixed))
  }

  func test_small_host_returns_nil_keeping_engine_default() {
    // A ~16 GB Mac maps to the engine default (no headroom to raise) and
    // anything smaller stays there too — never regressing below today's
    // behavior; the driver backoff handles a host where even the default
    // does not fit.
    XCTAssertNil(KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 16)))
    XCTAssertNil(KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 8)))
  }

  func test_roomy_host_raises_pool_above_default() {
    let pages = KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 32))
    XCTAssertNotNil(pages)
    XCTAssertGreaterThan(pages!, KVCacheBudget.defaultPages)
    XCTAssertLessThanOrEqual(pages!, KVCacheBudget.maxPages)
  }

  func test_large_host_clamps_to_cap() {
    XCTAssertEqual(KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 128)),
                   KVCacheBudget.maxPages)
    XCTAssertEqual(KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 256)),
                   KVCacheBudget.maxPages)
  }

  func test_operator_fraction_scales_request() {
    // At a RAM tier below the cap, a more aggressive fraction must request
    // strictly more pages than a conservative one (the operator dial
    // scales KV sizing the same way it scales the size guardrail).
    let conservative = KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 32, fraction: 0.55))
    let aggressive = KVCacheBudget.recommendedMaxPages(for: policy(ramGiB: 32, fraction: 0.95))
    XCTAssertNotNil(conservative)
    XCTAssertNotNil(aggressive)
    XCTAssertGreaterThan(aggressive!, conservative!)
    XCTAssertLessThanOrEqual(aggressive!, KVCacheBudget.maxPages)
  }
}
