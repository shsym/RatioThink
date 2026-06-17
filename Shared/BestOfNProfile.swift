import Foundation
import TOMLKit

/// Best-of-N parameters resolved from a profile (#690).
///
/// Like `ToTProfileConfig`, the server (`bestofn/schema.rs`) is the single
/// source of bounds truth — it re-validates and rejects out-of-range values —
/// so the client passes these through as-is. The client default `n` is 3
/// (#708); `max_tokens_per_candidate` defaults to 256 (matching the engine).
///
/// `temperature` / `top_p` are NOT here — the dispatch sources them from the
/// profile's `sampling` directly (`Profile.bestOfNRequestSampling`), so a
/// profile's configured temperature drives candidate generation rather than
/// the unseeded toolbar default.
///
/// `thinking` is ON by default (#708): each candidate emits a tagged `<think>`
/// block that `generate_demuxed` routes onto the reasoning channel, so the row
/// renders a real `ReasoningDisclosure` (brain icon + folded "Thinking") and
/// the answer stays clean. With it OFF the model honors `/no_think` only
/// loosely and leaks chain-of-thought prose — untagged, so undemuxable — into
/// the answer text. Enabling it rides the thinking-ON path that carried the
/// #679 forward-pass starvation crash; that is gated by the SDK collect_* break
/// + KV RAII drop-frees present in the pinned engine (verified before enabling).
///
/// Default `n` is 3 (#708): three candidates read clearly side-by-side without
/// crowding the transcript, while the engine still caps N at 5 (`MAX_N`). The
/// app always sends a resolved `n` on the wire, so the engine's own `DEFAULT_N`
/// (5) is only a fallback for callers that omit it and is never hit here.
public struct BestOfNProfileConfig: Equatable, Sendable {
  public var n: Int
  public var maxTokensPerCandidate: Int
  public var thinking: Bool

  public init(n: Int = 3, maxTokensPerCandidate: Int = 256, thinking: Bool = true) {
    self.n = n
    self.maxTokensPerCandidate = maxTokensPerCandidate
    self.thinking = thinking
  }
}

public extension Profile {
  /// `inferlet_args.mode` value that turns a profile into a Best-of-N
  /// interactive profile. Shares `dispatchModeArgKey` ("mode") with
  /// tree-of-thought; the launched `inferlet` stays `chat-apc` — Best-of-N is
  /// a dispatch mode selected per request over `/v1/inferlet`, not a separate
  /// wasm — so switching to it needs no new component and (model permitting)
  /// no engine relaunch.
  static let bestOfNModeValue = "best-of-n"

  /// The Best-of-N config when this profile dispatches as best-of-n, else
  /// `nil`. A profile is a Best-of-N profile iff its `inferlet_args` declare
  /// `mode = "best-of-n"`.
  var bestOfN: BestOfNProfileConfig? {
    guard inferletArgs[Profile.dispatchModeArgKey]?.tomlValue.string == Profile.bestOfNModeValue
    else {
      return nil
    }
    func intArg(_ key: String, default fallback: Int) -> Int {
      inferletArgs[key]?.tomlValue.int ?? fallback
    }
    let defaults = BestOfNProfileConfig()
    return BestOfNProfileConfig(
      n: intArg("n", default: defaults.n),
      maxTokensPerCandidate: intArg(
        "max_tokens_per_candidate", default: defaults.maxTokensPerCandidate),
      thinking: inferletArgs["thinking"]?.tomlValue.bool ?? defaults.thinking
    )
  }

  /// The sampling a Best-of-N dispatch should send: sourced from the profile's
  /// own `sampling` so its configured temperature is the candidate-generation
  /// temperature on the wire (mirrors `toTRequestSampling`).
  var bestOfNRequestSampling: ChatSampling {
    ChatSampling(
      temperature: sampling.temperature,
      topP: sampling.topP,
      maxTokens: sampling.maxTokens
    )
  }
}
