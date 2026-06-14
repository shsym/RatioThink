import Foundation
import TOMLKit

/// Tree-of-thought search parameters resolved from a profile (#413).
///
/// The server (`tot/schema.rs`) is the single source of bounds truth — it
/// re-validates and rejects out-of-range values — so the client passes
/// these through as-is rather than duplicating the clamp logic. Defaults
/// mirror the engine's (`breadth 3 / depth 2 / beam_width 2 /
/// max_tokens_per_node 256`) so an under-specified ToT profile behaves the
/// same whether or not the keys are present.
///
/// `temperature` / `top_p` are NOT here — the dispatch sources them from the
/// profile's `sampling` directly (`Profile.toTRequestSampling`, #523 Part B),
/// so a ToT profile's configured temperature drives candidate generation
/// rather than the unseeded toolbar default.
public struct ToTProfileConfig: Equatable, Sendable {
  public var breadth: Int
  public var depth: Int
  public var beamWidth: Int
  public var maxTokensPerNode: Int

  public init(breadth: Int = 3, depth: Int = 2, beamWidth: Int = 2, maxTokensPerNode: Int = 256) {
    self.breadth = breadth
    self.depth = depth
    self.beamWidth = beamWidth
    self.maxTokensPerNode = maxTokensPerNode
  }
}

public extension Profile {
  /// Reserved `inferlet_args` key flagging the dispatch mode.
  static let dispatchModeArgKey = "mode"
  /// `inferlet_args.mode` value that turns a profile into a
  /// tree-of-thought profile.
  static let treeOfThoughtModeValue = "tree-of-thought"

  /// The tree-of-thought search config when this profile dispatches as
  /// tree-of-thought, else `nil`.
  ///
  /// A profile is a ToT profile iff its `inferlet_args` declare
  /// `mode = "tree-of-thought"`. The launched `inferlet` stays `chat-apc`
  /// (the wasm `LaunchSpecResolver` validates against the installed
  /// component); tree-of-thought is a **dispatch mode** selected per
  /// request over `/v1/inferlet`, not a separate wasm — so the signal
  /// rides in `inferlet_args`, not the `inferlet` field. Switching to a
  /// ToT profile therefore needs no new wasm and (model permitting) no
  /// engine relaunch; only the chat send path routes differently.
  var treeOfThought: ToTProfileConfig? {
    guard inferletArgs[Profile.dispatchModeArgKey]?.tomlValue.string == Profile.treeOfThoughtModeValue
    else {
      return nil
    }
    func intArg(_ key: String, default fallback: Int) -> Int {
      inferletArgs[key]?.tomlValue.int ?? fallback
    }
    let defaults = ToTProfileConfig()
    return ToTProfileConfig(
      breadth: intArg("breadth", default: defaults.breadth),
      depth: intArg("depth", default: defaults.depth),
      beamWidth: intArg("beam_width", default: defaults.beamWidth),
      maxTokensPerNode: intArg("max_tokens_per_node", default: defaults.maxTokensPerNode)
    )
  }

  /// The sampling a tree-of-thought dispatch should send (#523 Part B).
  ///
  /// Sourced from the profile's own `sampling` so a ToT profile's configured
  /// temperature is the candidate-**generation** temperature on the wire —
  /// not the toolbar default (`viewModel.sampling`, which is never seeded
  /// from the profile). `max_tokens` is irrelevant to ToT (the per-node
  /// budget comes from the search config), so only `temperature`/`top_p` are
  /// load-bearing; all three are carried for fidelity. The engine keeps the
  /// scorer greedy and the final synthesis low regardless of this value, so
  /// raising it buys branch diversity without destabilizing pruning or the
  /// answer. Pure → unit-tested.
  var toTRequestSampling: ChatSampling {
    ChatSampling(
      temperature: sampling.temperature,
      topP: sampling.topP,
      maxTokens: sampling.maxTokens
    )
  }
}
