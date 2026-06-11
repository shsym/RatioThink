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

public struct ContextPageUsage: Codable, Equatable, Sendable {
  public let tokensPerPage: UInt32
  public let committedPages: UInt32
  public let workingPages: UInt32
  public let workingTokens: UInt32
  public let checkpoint: String
  public let observedAt: Date

  public init(tokensPerPage: UInt32,
              committedPages: UInt32,
              workingPages: UInt32,
              workingTokens: UInt32,
              checkpoint: String,
              observedAt: Date) {
    self.tokensPerPage = tokensPerPage
    self.committedPages = committedPages
    self.workingPages = workingPages
    self.workingTokens = workingTokens
    self.checkpoint = checkpoint
    self.observedAt = observedAt
  }
}

public struct ContextUsageRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: ContextUsageID
  public var chatID: UUID { id.chatID }
  public var modelID: String { id.modelID }
  public var requestID: String? { id.requestID }
  public var lastUsedAt: Date
  public var residency: ContextResidency
  public var usage: ContextPageUsage?

  public init(id: ContextUsageID,
              requestID: String?,
              lastUsedAt: Date,
              residency: ContextResidency,
              usage: ContextPageUsage?) {
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
