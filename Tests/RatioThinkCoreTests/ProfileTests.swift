import XCTest
@testable import RatioThinkCore

final class ProfileTests: XCTestCase {
  func test_parses_v1_minimal_profile() throws {
    let toml = """
    id = "chat"
    name = "Chat"
    model = "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M.gguf"
    inferlet = "chat-apc"
    system_prompt = "You are helpful."

    [sampling]
    temperature = 0.7
    top_p = 0.9
    max_tokens = 2048

    [inferlet_args]
    apc_enabled = true
    """
    let p = try Profile.parse(toml: toml)
    XCTAssertEqual(p.id, "chat")
    XCTAssertEqual(p.name, "Chat")
    XCTAssertEqual(p.model, "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M.gguf")
    XCTAssertEqual(p.inferlet, "chat-apc")
    XCTAssertEqual(p.systemPrompt, "You are helpful.")
    XCTAssertEqual(p.sampling.temperature, 0.7)
    XCTAssertEqual(p.sampling.topP, 0.9)
    XCTAssertEqual(p.sampling.maxTokens, 2048)
    XCTAssertEqual(p.inferletArgs["apc_enabled"]?.bool, true)
  }

  func test_applies_sampling_defaults_when_section_omitted() throws {
    let toml = """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "chat-apc"
    """
    let p = try Profile.parse(toml: toml)
    XCTAssertEqual(p.sampling.temperature, 0.7)
    XCTAssertEqual(p.sampling.topP, 0.9)
    XCTAssertEqual(p.sampling.maxTokens, 2048)
  }

  func test_preserves_unknown_v2_sections_round_trip() throws {
    let toml = """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "chat-apc"

    [[mcp_servers]]
    command = "uvx some-server"

    [routine]
    cron = "0 9 * * *"
    trigger = "schedule"

    [remote]
    url = "wss://remote.example.com"
    auth = "keychain:profile-x"

    [agent]
    loop = "react"
    """
    let p = try Profile.parse(toml: toml)
    let dumped = try p.dump()
    XCTAssertTrue(dumped.contains("mcp_servers"), "mcp_servers missing:\n\(dumped)")
    XCTAssertTrue(dumped.contains("uvx some-server"))
    XCTAssertTrue(dumped.contains("0 9 * * *"))
    XCTAssertTrue(dumped.contains("wss://remote.example.com"))
    XCTAssertTrue(dumped.contains("react"))
  }

  func test_throws_missing_field_when_id_omitted() {
    XCTAssertThrowsError(try Profile.parse(toml: """
    name = "no id"
    model = "m"
    inferlet = "chat-apc"
    """)) { err in
      guard case ProfileError.missingField(let f) = err else {
        return XCTFail("expected .missingField, got \(err)")
      }
      XCTAssertEqual(f, "id")
    }
  }

  func test_throws_missing_field_when_model_omitted() {
    XCTAssertThrowsError(try Profile.parse(toml: """
    id = "x"
    name = "X"
    inferlet = "chat-apc"
    """)) { err in
      guard case ProfileError.missingField(let f) = err else {
        return XCTFail("expected .missingField, got \(err)")
      }
      XCTAssertEqual(f, "model")
    }
  }

  func test_throws_parse_failure_on_invalid_toml() {
    XCTAssertThrowsError(try Profile.parse(toml: "this = is = not = toml")) { err in
      guard case ProfileError.parseFailure = err else {
        return XCTFail("expected .parseFailure, got \(err)")
      }
    }
  }

  /// Review cycle 149/150 F3: `Profile.dump()` previously aliased
  /// the stored `rawTable` (TOMLTable is a `final class`) and
  /// mutated it via subscript writes. A parse → mutate → dump
  /// sequence would dump the still-present typed sections from the
  /// original parse instead of the caller's mutation, AND a second
  /// dump would see the mutation persisted on `self` even though
  /// `Profile.dump()` is a non-mutating method.
  func test_dump_does_not_mutate_stored_rawTable_across_calls() throws {
    var profile = try Profile.parse(toml: """
    id = "code"
    name = "Code"
    model = "m"
    inferlet = "i"

    [inferlet_args]
    foo = 1
    """)
    XCTAssertEqual(profile.inferletArgs.count, 1,
                   "sanity: parsed inferlet_args.foo")

    // Caller clears the typed slice. After dump(), the emitted TOML
    // must NOT carry `foo` — and a second dump() against the same
    // unchanged value must produce identical output.
    profile.inferletArgs = [:]
    let first  = try profile.dump()
    let second = try profile.dump()
    XCTAssertFalse(first.contains("foo"),
                   "dump() must not emit cleared inferlet_args — saw: \(first)")
    XCTAssertEqual(first, second,
                   "dump() must be idempotent across calls; reference aliasing on rawTable would surface here")

    // Re-parsing the dumped output must yield a clean profile —
    // proves dump() actually wrote the cleared shape, not just
    // "decided not to print foo".
    let reparsed = try Profile.parse(toml: first)
    XCTAssertTrue(reparsed.inferletArgs.isEmpty,
                  "round-trip after clearing must produce an empty inferlet_args, got \(reparsed.inferletArgs)")
  }

  /// Review v3 F4: `Profile.dump()` only purged `inferlet_args` via
  /// the symmetric remove+rewrite. A profile parsed with `icon = "X"`
  /// and mutated to `profile.icon = nil` re-emitted with `icon = "X"`
  /// because the cloned table preserved the original key and the
  /// `if let icon` write skipped on nil. Same shape as F3.
  /// Parameterized over `icon` and `system_prompt` (and re-exercises
  /// `inferlet_args` for completeness) so a future regression on any
  /// of the optional typed slices surfaces here.
  func test_dump_drops_optional_keys_when_nil_set_after_parse() throws {
    var profile = try Profile.parse(toml: """
    id = "code"
    name = "Code"
    icon = "bubble.left"
    model = "m"
    inferlet = "i"
    system_prompt = "You are helpful."

    [inferlet_args]
    foo = 1
    """)
    XCTAssertEqual(profile.icon, "bubble.left")
    XCTAssertEqual(profile.systemPrompt, "You are helpful.")
    XCTAssertEqual(profile.inferletArgs.count, 1)

    profile.icon = nil
    profile.systemPrompt = nil
    profile.inferletArgs = [:]

    let dumped = try profile.dump()
    XCTAssertFalse(dumped.contains("icon"),
                   "nil-set icon must NOT appear in dump (regression: F4 only purged inferlet_args)\ndumped:\n\(dumped)")
    XCTAssertFalse(dumped.contains("system_prompt"),
                   "nil-set system_prompt must NOT appear in dump\ndumped:\n\(dumped)")
    XCTAssertFalse(dumped.contains("foo"),
                   "cleared inferlet_args must NOT appear in dump\ndumped:\n\(dumped)")

    // Round-trip back to verify the actual semantic shape, not just
    // string-absence (defends against the keys being smuggled
    // through under a different surface).
    let reparsed = try Profile.parse(toml: dumped)
    XCTAssertNil(reparsed.icon)
    XCTAssertNil(reparsed.systemPrompt)
    XCTAssertTrue(reparsed.inferletArgs.isEmpty)
  }

  /// Review v3 F3: prior `?? TOMLTable()` fallback would silently
  /// emit a syntactically-valid TOML with EVERY preserved v2 section
  /// (`mcp_servers`, `routine`, `remote`, `agent`) amputated when the
  /// `convert() -> TOMLTable(string:)` clone failed.
  /// `Profile.dump()` is now `throws` so a clone failure aborts the
  /// emit. The throwing branch is unreachable in practice (TOMLKit
  /// `TOMLTable(string:)` always succeeds on output of `convert()`
  /// from a valid `TOMLTable`); the contract is defense-in-depth
  /// against a future TOMLKit version drift. The wrap-into-
  /// `ProfileStoreError.dumpFailed` step is covered by
  /// `ProfileStoreTests.test_createProfile_propagates_dump_failure`
  /// via an injected throwing `dumpProvider`. Healthy-path round-trip
  /// is pinned here so a future regression on the silent-amputation
  /// pathway surfaces.
  func test_dump_preserves_v2_sections_on_round_trip() throws {
    let toml = """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "i"

    [mcp_servers.demo]
    url = "https://example.com/mcp"
    auth = "keychain:demo"

    [routine]
    cron = "*/15 * * * *"

    [remote]
    endpoint = "wss://remote.example.com"

    [agent]
    loop = "react"
    """
    let p = try Profile.parse(toml: toml)
    let dumped = try p.dump()
    XCTAssertTrue(dumped.contains("mcp_servers"),
                  "mcp_servers must survive dump round-trip — F3 silent-amputation regression\n\(dumped)")
    XCTAssertTrue(dumped.contains("https://example.com/mcp"))
    XCTAssertTrue(dumped.contains("routine"))
    XCTAssertTrue(dumped.contains("remote"))
    XCTAssertTrue(dumped.contains("agent"))
  }

  // MARK: - [speculation] (#426 Fast Think)

  func test_parses_speculation_section_enabled_only() throws {
    let toml = """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "chat-apc"

    [speculation]
    enabled = true
    """
    let p = try Profile.parse(toml: toml)
    XCTAssertEqual(p.speculation, Profile.Speculation(enabled: true))
  }

  func test_parses_speculation_section_with_knobs() throws {
    let toml = """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "chat-apc"

    [speculation]
    enabled = true
    leader_len = 2
    draft_len = 5
    """
    let p = try Profile.parse(toml: toml)
    XCTAssertEqual(p.speculation, Profile.Speculation(enabled: true, leaderLen: 2, draftLen: 5))
  }

  func test_absent_speculation_section_is_nil() throws {
    let toml = """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "chat-apc"
    """
    XCTAssertNil(try Profile.parse(toml: toml).speculation)
  }

  func test_dump_round_trips_speculation_with_knobs() throws {
    let p = Profile(id: "x", name: "X", model: "m", inferlet: "chat-apc",
                    speculation: Profile.Speculation(enabled: true, leaderLen: 2, draftLen: 5))
    let reparsed = try Profile.parse(toml: try p.dump())
    XCTAssertEqual(reparsed.speculation, Profile.Speculation(enabled: true, leaderLen: 2, draftLen: 5))
  }

  func test_dump_drops_speculation_when_cleared_to_nil() throws {
    // A profile parsed WITH speculation, then mutated to nil, must not
    // re-emit the section (mirrors the icon/system_prompt purge).
    var p = try Profile.parse(toml: """
    id = "x"
    name = "X"
    model = "m"
    inferlet = "chat-apc"

    [speculation]
    enabled = true
    """)
    p.speculation = nil
    XCTAssertNil(try Profile.parse(toml: try p.dump()).speculation)
  }
}
