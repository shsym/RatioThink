import Foundation

public struct ProfileModelSelectionLabelContent: Equatable, Sendable {
  public enum NameTruncationMode: Equatable, Sendable {
    case middle
  }

  public static let maxNameWidth: Double = 240
  public static let maxSelectionWidth: Double = 292
  public static let nameLineLimit = 1
  public static let nameTruncationMode: NameTruncationMode = .middle

  public let displayName: String
  public let warningText: String?

  public init(
    fallbackModel: String,
    selectedOption: ProfileModelOptions.Option?,
    memoryPolicy: ModelMemoryGuardrail.Policy?
  ) {
    displayName = selectedOption?.displayName ?? ModelDisplayName.leaf(fallbackModel)
    warningText = Self.warningText(for: selectedOption, memoryPolicy: memoryPolicy)
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
    return option.unsupportedReason
  }
}
