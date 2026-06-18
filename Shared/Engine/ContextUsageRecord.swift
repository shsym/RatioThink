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

  /// The model currently resident in the engine, set at model-load (#711
  /// follow-up). Non-nil whenever a model is loaded — so the meter shows a
  /// real `0 / window` zero-state the instant a model loads, before any turn.
  @Published public private(set) var loadedModelID: String?
  /// Engine-true context window (tokens) of `loadedModelID`, seeded at
  /// model-load from the model's KV budget (`kv_pages_total × tokens_per_page`)
  /// with NO turn. `nil` when a model is loaded but its window can't be read
  /// yet (the meter then shows `0 / unknown`, visible rather than hidden).
  @Published public private(set) var loadedWindow: Int?

  private var byID: [ContextUsageID: ContextUsageRecord] = [:]
  private let now: () -> Date

  public init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  /// Seed the zero-state at model-load: a model is resident, and (when the
  /// engine-true window is known) its window. A model switch resets the
  /// window to the new model's (re-seeded once its budget is readable); a
  /// repeat seed for the SAME model only upgrades a `nil` window to a known
  /// value and never wipes a good one with a transient `nil` (#711 follow-up).
  public func seedLoadedModel(modelID: String, window: Int?) {
    if modelID != loadedModelID {
      loadedModelID = modelID
      loadedWindow = window
    } else if let window, window != loadedWindow {
      // Same model — only a CHANGED known window writes (it rides the KV poll,
      // which fires often; an unchanged value must not republish every tick).
      loadedWindow = window
    }
  }

  /// Clear the zero-state when no model is resident (engine left `.running`).
  /// The meter then hides until a model loads again.
  public func clearLoadedModel() {
    loadedModelID = nil
    loadedWindow = nil
  }

  /// Seed (or clear) the zero-state from the resident model's engine-true KV
  /// budget (#711 follow-up). The window is `kv_pages_total × tokens_per_page`
  /// — both control-only signals available at model-load (no turn): a resident
  /// model with both known seeds `0 / window`; with either missing seeds a
  /// known-loaded / unknown-window zero-state (`0 / unknown`, meter visible);
  /// no resident model clears the seed (meter hides). Pure over its inputs so
  /// the window arithmetic is unit-testable.
  public func seedFromModelLoad(modelID: String?, pagesTotal: Int?, tokensPerPage: Int?) {
    guard let modelID else { clearLoadedModel(); return }
    let window: Int?
    if let pagesTotal, let tokensPerPage, pagesTotal > 0, tokensPerPage > 0 {
      window = pagesTotal * tokensPerPage
    } else {
      window = nil
    }
    seedLoadedModel(modelID: modelID, window: window)
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
    // The standard chat path reports the engine-true window in the frame; the
    // ToT/Best-of-N paths omit it (the app holds the budget from the
    // model-load seed). Fall back to the seeded window so every record's
    // fraction renders regardless of which path produced it.
    let window = usage.windowTokens ?? loadedWindow
    record.usage = ContextUsage(usedTokens: usage.usedTokens, windowTokens: window)
    byID[id] = record
    publish()
  }

  /// What the top-bar meter shows for `chatID`: the chat's latest engine-true
  /// usage, or — before any turn — the model-load zero-state (`0 / window`)
  /// once a model is resident. `nil` only when no model is loaded (the meter
  /// hides). A resident model whose window is not yet readable shows
  /// `0 / unknown` (visible, indeterminate) rather than hiding (#711 follow-up).
  public func meterUsage(chatID: UUID) -> ContextUsage? {
    if let live = latestUsage(chatID: chatID) { return live }
    guard loadedModelID != nil else { return nil }
    return ContextUsage(usedTokens: 0, windowTokens: loadedWindow)
  }

  /// Engine-true usage of this chat's most recent request that reported a
  /// `usage` frame, or `nil` until one has. Drives the top-bar meter.
  public func latestUsage(chatID: UUID) -> ContextUsage? {
    records.first { $0.chatID == chatID && $0.usage != nil }?.usage
  }

  /// Engine-true context window (tokens) of the loaded model. Prefers the
  /// most recent turn's measured window, falling back to the model-load seed
  /// so the memory screen shows the real number the instant a model loads —
  /// without standing up a chat or waiting for a turn (#711 follow-up).
  public var latestWindow: Int? {
    records.lazy.compactMap { $0.usage?.windowTokens }.first ?? loadedWindow
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
