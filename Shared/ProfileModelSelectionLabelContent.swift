import Foundation

public struct ProfileModelSelectionLabelContent: Equatable, Sendable {
  public enum NameTruncationMode: Equatable, Sendable {
    case middle
  }

  public static let maxNameWidth: Double = 240
  public static let maxSelectionWidth: Double = 360
  public static let nameLineLimit = 1
  public static let nameTruncationMode: NameTruncationMode = .middle

  public let displayName: String
  public let warningText: String?

  public init(
    fallbackModel: String?,
    selectedOption: ProfileModelOptions.Option?,
    memoryPolicy: ModelMemoryGuardrail.Policy?
  ) {
    displayName = selectedOption?.displayName ?? Self.displayText(for: fallbackModel)
    warningText = Self.warningText(for: selectedOption, memoryPolicy: memoryPolicy)
  }

  public static func displayText(for modelID: String?) -> String {
    modelID.map(ModelDisplayName.leaf) ?? "No default model"
  }

  public var accessibilityLabel: String {
    if let warningText {
      return "Default model: \(displayName). Warning: \(warningText)"
    }
    return "Default model: \(displayName)"
  }

  private static func warningText(
    for option: ProfileModelOptions.Option?,
    memoryPolicy: ModelMemoryGuardrail.Policy?
  ) -> String? {
    guard let option else { return nil }
    if option.isOverLimit, let memoryPolicy {
      return "exceeds \(InstalledModels.formattedSize(memoryPolicy.maxResolvedModelBytes)) limit"
    }
    if let unsupportedReason = option.unsupportedReason {
      return unsupportedReason
    }
    return option.supportWarning
  }
}
