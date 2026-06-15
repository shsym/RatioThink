import XCTest
@testable import RatioThinkCore

/// Dedup + group by structured identity (#580). Same key as
/// `ModelNameParts.identity` / `.groupKey`, exercised on a plain
/// slug-carrying struct so the generic helper is covered without a view.
final class ModelIdentityGroupingTests: XCTestCase {
  private struct Row: Equatable { let slug: String; let tag: String }

  func test_deduped_collapses_exact_duplicate_slugs_keeping_first() {
    // The dedup key is the full resolvable slug (review v2 F2): an
    // app-managed download and an HF-cache copy of the SAME `<repo>/<file>`
    // slug collapse to the first (app-managed) row.
    let slug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    let rows = [Row(slug: slug, tag: "app"), Row(slug: slug, tag: "hf")]
    let out = ModelIdentityGrouping.deduped(rows, slug: \.slug)
    XCTAssertEqual(out, [Row(slug: slug, tag: "app")],
                   "same resolvable slug collapses to the first (app-managed) row")
  }

  // F2 regression: distinct files that merely share a leaf must NOT collapse —
  // main deduped by full filename and kept them all visible.
  func test_deduped_keeps_same_leaf_across_repos_and_bare_distinct() {
    let rows = [
      Row(slug: "RepoA/Model-GGUF/Model-Q4_K_M.gguf", tag: "a"),
      Row(slug: "RepoB/Model-GGUF/Model-Q4_K_M.gguf", tag: "b"),
      Row(slug: "Model-Q4_K_M.gguf", tag: "bare"),
    ]
    XCTAssertEqual(ModelIdentityGrouping.deduped(rows, slug: \.slug).count, 3,
                   "same leaf across two repos plus a bare copy are three distinct files")
  }

  func test_deduped_does_not_over_normalize_underscore_vs_hyphen() {
    let rows = [Row(slug: "Model_A-Q4_K_M.gguf", tag: "u"),
                Row(slug: "Model-A-Q4_K_M.gguf", tag: "h")]
    XCTAssertEqual(ModelIdentityGrouping.deduped(rows, slug: \.slug).count, 2,
                   "underscore vs hyphen are distinct files, not one over-normalized row")
  }

  // F1 (PR #174 review v1): when an app-download and an HF-cache copy of the
  // SAME resolvable slug collapse, the chat menu must keep the CURRENT one so
  // the surviving row's slug matches the persisted selection (checkmark + the
  // tap writes the right slug). `prefer` breaks the identity tie.
  func test_deduped_prefer_upgrades_to_current_on_identity_tie() {
    let slug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    let rows = [Row(slug: slug, tag: "served"), Row(slug: slug, tag: "current")]
    let out = ModelIdentityGrouping.deduped(rows, slug: \.slug,
                                            prefer: { $0.tag == "current" })
    XCTAssertEqual(out, [Row(slug: slug, tag: "current")],
                   "the preferred (current) row wins the tie and holds the first slot")
  }

  func test_deduped_prefer_is_noop_without_a_match() {
    // No element satisfies `prefer` → first-wins, unchanged from the default.
    let slug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    let rows = [Row(slug: slug, tag: "served"), Row(slug: slug, tag: "app")]
    let out = ModelIdentityGrouping.deduped(rows, slug: \.slug, prefer: { _ in false })
    XCTAssertEqual(out.map(\.tag), ["served"], "no preferred element → first-wins holds")
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

  // #580 long-list: the dedup→group pipeline that feeds the (scrollable) model
  // menus must never truncate a long installed-model list — every distinct
  // model survives into exactly one group. The on-screen scrolling of the long
  // result is the native SwiftUI `Menu`/NSMenu's job (a `ScrollView` cannot be
  // embedded in a `Menu`); this guards the data path that the menu renders.
  func test_long_multi_family_list_is_never_truncated() {
    // 40 families × 2 distinct quants = 80 distinct models.
    let rows: [Row] = (1...40).flatMap { i -> [Row] in
      let fam = String(format: "Fam%02d/Fam%02d-GGUF", i, i)
      return [
        Row(slug: "\(fam)/Fam\(i)-Q4_K_M.gguf", tag: "q4-\(i)"),
        Row(slug: "\(fam)/Fam\(i)-Q8_0.gguf", tag: "q8-\(i)"),
      ]
    }
    let deduped = ModelIdentityGrouping.deduped(rows, slug: \.slug)
    XCTAssertEqual(deduped.count, 80, "distinct quants must not collapse")
    let groups = ModelIdentityGrouping.grouped(deduped, slug: \.slug)
    XCTAssertEqual(groups.count, 40, "one base-name group per family")
    XCTAssertEqual(groups.reduce(0) { $0 + $1.items.count }, 80,
                   "every model survives into exactly one group — the long list is never clipped")
    XCTAssertTrue(groups.allSatisfy { $0.items.count == 2 },
                  "each family clusters its two quants")
  }
}
