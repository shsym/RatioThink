import XCTest
@testable import RatioThinkCore

/// `Profile.treeOfThought` convention tests (#413): a profile dispatches
/// as tree-of-thought iff `inferlet_args.mode == "tree-of-thought"`, with
/// the bounded search params read from `inferlet_args` (engine defaults
/// otherwise). Driven through the real `Profile.parse` so it exercises the
/// TOML `inferlet_args` reading path.
final class ToTProfileTests: XCTestCase {

  private func parse(_ toml: String) throws -> Profile { try Profile.parse(toml: toml) }

  func test_non_tot_profile_is_nil() throws {
    let p = try parse("""
    id = "chat"
    name = "Chat"
    model = "qwen"
    inferlet = "chat-apc"
    """)
    XCTAssertNil(p.treeOfThought)
  }

  func test_other_mode_value_is_nil() throws {
    let p = try parse("""
    id = "x"
    name = "X"
    model = "qwen"
    inferlet = "chat-apc"
    [inferlet_args]
    mode = "something-else"
    """)
    XCTAssertNil(p.treeOfThought)
  }

  func test_tot_profile_reads_all_params() throws {
    let p = try parse("""
    id = "tot"
    name = "Tree of Thought"
    model = "qwen"
    inferlet = "chat-apc"
    [inferlet_args]
    mode = "tree-of-thought"
    breadth = 4
    depth = 3
    beam_width = 2
    max_tokens_per_node = 128
    """)
    XCTAssertEqual(
      p.treeOfThought,
      ToTProfileConfig(breadth: 4, depth: 3, beamWidth: 2, maxTokensPerNode: 128)
    )
    // The launched inferlet stays chat-apc — ToT is a dispatch mode.
    XCTAssertEqual(p.inferlet, "chat-apc")
  }

  func test_tot_profile_falls_back_to_engine_defaults() throws {
    let p = try parse("""
    id = "tot"
    name = "Tree of Thought"
    model = "qwen"
    inferlet = "chat-apc"
    [inferlet_args]
    mode = "tree-of-thought"
    """)
    XCTAssertEqual(p.treeOfThought, ToTProfileConfig())  // 3 / 2 / 2 / 256
  }

  func test_tot_profile_round_trips_through_dump() throws {
    let p = try parse("""
    id = "tot"
    name = "Tree of Thought"
    model = "qwen"
    inferlet = "chat-apc"
    [inferlet_args]
    mode = "tree-of-thought"
    breadth = 5
    """)
    let reparsed = try Profile.parse(toml: try p.dump())
    XCTAssertEqual(reparsed.treeOfThought, ToTProfileConfig(breadth: 5, depth: 2, beamWidth: 2, maxTokensPerNode: 256))
  }
}
