import XCTest
@testable import RatioThink

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

  func test_model_omitted_is_explicit_no_default_state() throws {
    let profile = try Profile.parse(toml: """
    id = "x"
    name = "X"
    inferlet = "chat-apc"
    """)

    XCTAssertNil(profile.model,
                 "missing model is an explicit no-default state, not a parse failure")
    let dumped = try profile.dump()
    XCTAssertFalse(dumped.contains("model ="),
                   "round-trip must preserve no-default by omitting the model key")
  }

  func test_throws_parse_failure_on_invalid_toml() {
    XCTAssertThrowsError(try Profile.parse(toml: "this = is = not = toml")) { err in
      guard case ProfileError.parseFailure = err else {
        return XCTFail("expected .parseFailure, got \(err)")
      }
    }
  }
}
