import Combine
import Foundation

public struct ContextUsageID: Codable, Equatable, Hashable, Sendable {
  public let chatID: UUID
  public let modelID: String
  public let requestID: String

  public init(chatID: UUID, modelID: String, requestID: String) {
    self.chatID = chatID
    self.modelID = modelID
    self.requestID = requestID
  }
}

public enum ContextResidency: String, Codable, Equatable, Sendable {
  case unknown
  case requestLocalActive
  case requestLocalDestroyed
  case persistentActive
  case persistentSuspended
  case persistentSnapshotBacked
  case destroyed
}

public struct ContextUsageRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: ContextUsageID
  public var chatID: UUID { id.chatID }
  public var modelID: String { id.modelID }
  public var requestID: String? { id.requestID }
  public var lastUsedAt: Date
  public var residency: ContextResidency
  /// Engine-true occupancy reported by the turn's `usage` frame
  /// (#711): `usedTokens` + the effective KV-budget `windowTokens`. `nil`
  /// until the frame arrives (it trails the stream's `.finish`); the
  /// tracker never estimates a value the engine did not report.
  public var usage: ContextUsage?

  public init(id: ContextUsageID,
              requestID: String?,
              lastUsedAt: Date,
              residency: ContextResidency,
              usage: ContextUsage?) {
    assert(requestID == nil || requestID == id.requestID, "ContextUsageRecord.requestID must match id.requestID")
    self.id = id
    self.lastUsedAt = lastUsedAt
    self.residency = residency
    self.usage = usage
  }
}

@MainActor
public final class ContextUsageTracker: ObservableObject {
  @Published public private(set) var records: [ContextUsageRecord] = []

  private var byID: [ContextUsageID: ContextUsageRecord] = [:]
  private let now: () -> Date

  public init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  public func markRequestStarted(chatID: UUID, modelID: String, requestID: String) {
    let id = ContextUsageID(chatID: chatID, modelID: modelID, requestID: requestID)
    byID[id] = ContextUsageRecord(
      id: id,
      requestID: requestID,
      lastUsedAt: now(),
      residency: .requestLocalActive,
      usage: nil
    )
    publish()
  }

  public func markRequestFinished(chatID: UUID, modelID: String, requestID: String) {
    let id = ContextUsageID(chatID: chatID, modelID: modelID, requestID: requestID)
    guard var record = byID[id] else { return }
    record.lastUsedAt = now()
    record.residency = .requestLocalDestroyed
    byID[id] = record
    publish()
  }

  /// Record the engine-true occupancy a turn's `usage` frame reported
  /// (#711). Keyed on the SAME request id `markRequestStarted` used, so a
  /// frame for a superseded request can't overwrite a newer one; an
  /// unknown id is ignored (mirrors `markRequestFinished`).
  public func markUsage(chatID: UUID, modelID: String, requestID: String, usage: ContextUsage) {
    let id = ContextUsageID(chatID: chatID, modelID: modelID, requestID: requestID)
    guard var record = byID[id] else { return }
    record.lastUsedAt = now()
    record.usage = usage
    byID[id] = record
    publish()
  }

  /// Engine-true usage of this chat's most recent request that reported a
  /// `usage` frame, or `nil` until one has. Drives the top-bar meter.
  public func latestUsage(chatID: UUID) -> ContextUsage? {
    records.first { $0.chatID == chatID && $0.usage != nil }?.usage
  }

  /// Engine-true context window (tokens) of the most recently used model.
  /// Model-global (`budget_pages × tokens_per_page`), so the memory screen
  /// reads it to show the expected max context without standing up a chat.
  public var latestWindow: Int? {
    records.lazy.compactMap { $0.usage?.windowTokens }.first
  }

  private func publish() {
    records = byID.values.sorted {
      if $0.lastUsedAt == $1.lastUsedAt {
        if $0.modelID != $1.modelID { return $0.modelID < $1.modelID }
        if $0.chatID != $1.chatID { return $0.chatID.uuidString < $1.chatID.uuidString }
        return $0.id.requestID < $1.id.requestID
      }
      return $0.lastUsedAt > $1.lastUsedAt
    }
  }
}
