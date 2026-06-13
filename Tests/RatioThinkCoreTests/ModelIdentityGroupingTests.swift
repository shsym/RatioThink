import XCTest
@testable import RatioThinkCore

/// Dedup + group by structured identity (#580). Same key as
/// `ModelNameParts.identity` / `.groupKey`, exercised on a plain
/// slug-carrying struct so the generic helper is covered without a view.
final class ModelIdentityGroupingTests: XCTestCase {
  private struct Row: Equatable { let slug: String; let tag: String }

  func test_deduped_collapses_app_and_hf_copies_keeping_first() {
    let rows = [
      Row(slug: "Qwen3-0.6B-Q8_0.gguf", tag: "app"),
      Row(slug: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf", tag: "hf"),
    ]
    let out = ModelIdentityGrouping.deduped(rows, slug: \.slug)
    XCTAssertEqual(out, [Row(slug: "Qwen3-0.6B-Q8_0.gguf", tag: "app")],
                   "true dupe collapses to the first (app-managed) row")
  }

  func test_deduped_keeps_distinct_quants() {
    let rows = [
      Row(slug: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", tag: "q4"),
      Row(slug: "Llama-3.2-1B-Instruct-Q8_0.gguf", tag: "q8"),
    ]
    XCTAssertEqual(ModelIdentityGrouping.deduped(rows, slug: \.slug).count, 2)
  }

  func test_grouped_clusters_quants_under_base_preserving_order() {
    let rows = [
      Row(slug: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", tag: "a"),
      Row(slug: "Qwen3-0.6B-Q8_0.gguf", tag: "b"),
      Row(slug: "Llama-3.2-1B-Instruct-Q8_0.gguf", tag: "c"),
    ]
    let groups = ModelIdentityGrouping.grouped(rows, slug: \.slug)
    XCTAssertEqual(groups.map(\.base), ["Llama 3.2 1B Instruct", "Qwen3 0.6B"],
                   "bases appear in first-seen order; the Llama family clusters")
    XCTAssertEqual(groups[0].items.map(\.tag), ["a", "c"])
    XCTAssertEqual(groups[1].items.map(\.tag), ["b"])
  }

  func test_grouped_does_not_dedup() {
    let rows = [Row(slug: "m.gguf", tag: "1"), Row(slug: "m.gguf", tag: "2")]
    let groups = ModelIdentityGrouping.grouped(rows, slug: \.slug)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].items.count, 2, "grouping clusters but never drops")
  }
}
