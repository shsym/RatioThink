import Foundation

/// Narrow classifier for model-load failures that should be shown as
/// unsupported/not-loadable. It deliberately uses engine/helper signals
/// (structured error codes first, then a small stderr signature allowlist)
/// and never consults app-side catalog curation, because being outside the
/// curated list is only advisory.
public enum EngineLoadFailureClassifier {
  public enum Kind: Equatable, Sendable {
    case unsupportedModel
  }

  public struct Classification: Equatable, Sendable {
    public let kind: Kind
    public let underlyingReason: String
  }

  public static func classify(_ error: Error) -> Classification? {
    if let http = error as? HTTPEngineError {
      return classify(http)
    }
    if let launch = error as? PieControlLauncher.LaunchError {
      return classify(launch)
    }
    return classify(text: String(describing: error))
  }

  public static func userFacingLoadFailureMessage(modelID: String, error: Error) -> String {
    guard let classification = classify(error) else {
      let detail = String(describing: error)
      return detail.isEmpty ? "Couldn’t load \(modelID)." : "Couldn’t load \(modelID): \(detail)"
    }
    switch classification.kind {
    case .unsupportedModel:
      return "Couldn’t load \(modelID): the selected model is unsupported or not loadable. "
        + "To recover, choose a curated model, remove or fix the cached repo, or install a supported artifact. "
        + "Engine reason: \(classification.underlyingReason)"
    }
  }

  private static func classify(_ error: HTTPEngineError) -> Classification? {
    switch error {
    case let .api(_, code, message), let .stream(code, message):
      if isStructuredUnsupportedCode(code) {
        return Classification(kind: .unsupportedModel,
                              underlyingReason: cleaned(message, fallback: code))
      }
      return classify(text: message)
    case let .http(_, body, _):
      // Plain FaultClass tags like handler-panic/instantiate-failed are
      // intentionally not in the allowlist below, so generic crashes and
      // helper faults stay generic.
      return classify(text: String(decoding: body, as: UTF8.self))
    case .nonHTTPResponse, .engineNotReady, .engineGone:
      return nil
    }
  }

  private static func classify(_ error: PieControlLauncher.LaunchError) -> Classification? {
    switch error {
    case let .engineExitedEarly(_, _, stderrTail, _):
      return classify(text: stderrTail)
    case .driverUnsupported:
      // Structured helper-side driver support is a real unsupported-engine
      // signal, but it is about the bundled pie binary rather than the cached
      // model itself. Keep it generic for this ticket's model-load surface.
      return nil
    default:
      return nil
    }
  }

  private static func isStructuredUnsupportedCode(_ code: String) -> Bool {
    let normalized = code.lowercased()
    return [
      "unsupported_model",
      "model_unsupported",
      "unsupported_model_format",
      "unsupported_format",
      "model_load_unsupported",
    ].contains(normalized)
  }

  private static func classify(text raw: String) -> Classification? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let lower = text.lowercased()
    let signatures = [
      "unsupported model architecture",
      "unsupported architecture",
      "unsupported gguf",
      "unsupported model format",
      "unsupported tensor type",
      "unknown model architecture",
      "not a gguf file",
      "invalid gguf magic",
    ]
    guard signatures.contains(where: lower.contains) else { return nil }
    return Classification(kind: .unsupportedModel,
                          underlyingReason: cleaned(text, fallback: "unsupported model"))
  }

  private static func cleaned(_ text: String, fallback: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
