import Foundation
import CoreFoundation

public struct KVUsageSnapshot: Codable, Equatable, Sendable {
  public let modelID: String
  public let pagesUsed: UInt64
  public let pagesTotal: UInt64
  public let observedAt: Date
  public let generation: UInt64
  public let source: KVUsageSource

  public init(modelID: String,
              pagesUsed: UInt64,
              pagesTotal: UInt64,
              observedAt: Date,
              generation: UInt64,
              source: KVUsageSource) {
    self.modelID = modelID
    self.pagesUsed = pagesUsed
    self.pagesTotal = pagesTotal
    self.observedAt = observedAt
    self.generation = generation
    self.source = source
  }
}

public enum KVUsageSource: String, Codable, Equatable, Sendable {
  case pieModelStatus
}

public enum KVUsageModelStatusParser {
  public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case notJSONObject
    case invalidCounter(key: String)
    case missingCounter(modelID: String, key: String)

    public var description: String {
      switch self {
      case .notJSONObject:
        return "model_status result was not a JSON object"
      case .invalidCounter(let key):
        return "model_status counter '\(key)' was not a non-negative integer"
      case .missingCounter(let modelID, let key):
        return "model_status KV row for model '\(modelID)' was missing counter '\(key)'"
      }
    }
  }

  private struct PartialRow {
    var used: UInt64?
    var total: UInt64?
  }

  public static func parse(_ json: String,
                           observedAt: Date,
                           generation: UInt64) throws -> [KVUsageSnapshot] {
    let data = Data(json.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let map = object as? [String: Any] else {
      throw ParseError.notJSONObject
    }

    var rows: [String: PartialRow] = [:]
    for (key, value) in map {
      if key.hasSuffix(".kv_pages_used") {
        let model = String(key.dropLast(".kv_pages_used".count))
        var row = rows[model, default: PartialRow()]
        row.used = try uint64(value, key: key)
        rows[model] = row
      } else if key.hasSuffix(".kv_pages_total") {
        let model = String(key.dropLast(".kv_pages_total".count))
        var row = rows[model, default: PartialRow()]
        row.total = try uint64(value, key: key)
        rows[model] = row
      }
    }

    return try rows.map { modelID, row in
      guard let used = row.used else {
        throw ParseError.missingCounter(modelID: modelID, key: "kv_pages_used")
      }
      guard let total = row.total else {
        throw ParseError.missingCounter(modelID: modelID, key: "kv_pages_total")
      }
      return KVUsageSnapshot(
        modelID: modelID,
        pagesUsed: used,
        pagesTotal: total,
        observedAt: observedAt,
        generation: generation,
        source: .pieModelStatus
      )
    }
    .sorted { $0.modelID < $1.modelID }
  }

  private static func uint64(_ value: Any, key: String) throws -> UInt64 {
    guard CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID(),
          let number = value as? NSNumber,
          !CFNumberIsFloatType(number) else {
      throw ParseError.invalidCounter(key: key)
    }

    let double = number.doubleValue
    guard double >= 0,
          double.rounded(.towardZero) == double,
          double <= Double(UInt64.max) else {
      throw ParseError.invalidCounter(key: key)
    }
    return number.uint64Value
  }
}

public enum KVUsageRefreshError: Error, Equatable, Sendable, CustomStringConvertible {
  case modelStatusUnavailable(reason: String)

  public var description: String {
    switch self {
    case .modelStatusUnavailable(let reason):
      return "KV usage model_status unavailable: \(reason)"
    }
  }
}
