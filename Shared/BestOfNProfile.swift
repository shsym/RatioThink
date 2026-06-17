import Foundation
import TOMLKit

/// Best-of-N parameters resolved from a profile (#690).
///
/// Like `ToTProfileConfig`, the server (`bestofn/schema.rs`) is the single
/// source of bounds truth — it re-validates and rejects out-of-range values —
/// so the client passes these through as-is. Defaults mirror the engine's
/// (`n 5 / max_tokens_per_candidate 256`).
///
/// `temperature` / `top_p` are NOT here — the dispatch sources them from the
/// profile's `sampling` directly (`Profile.bestOfNRequestSampling`), so a
/// profile's configured temperature drives candidate generation rather than
/// the unseeded toolbar default. `thinking` is OFF for this profile (the
/// seed omits it; the server defaults it false, #679).
public struct BestOfNProfileConfig: Equatable, Sendable {
  public var n: Int
  public var maxTokensPerCandidate: Int

  public init(n: Int = 5, maxTokensPerCandidate: Int = 256) {
    self.n = n
    self.maxTokensPerCandidate = maxTokensPerCandidate
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
        "max_tokens_per_candidate", default: defaults.maxTokensPerCandidate)
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
