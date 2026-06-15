import Foundation
import os

/// Persisted per-profile speculative-decode telemetry (#621). Each chat
/// turn on a "Repeat Boost" profile ends with a terminal `spec_metrics` SSE
/// frame (chat-apc #418); `ChatSendController` hands the decoded
/// `SpecMetrics` here so the ProfileEditor can surface a read-only "last
/// run" badge without re-running inference.
///
/// This is RUNTIME TELEMETRY, deliberately kept OUT of the profile TOML
/// (which `ProfileStore` owns as config). It lives in its own small JSON
/// file in the support root — the same persistence shape as
/// `GuardrailSettings` — and is only ever read/written App-side (the chat
/// send loop and the editor both run in the App process), so there is no
/// App↔Helper boundary to cross.
public struct SpecMetricsAggregate: Codable, Equatable, Sendable {
  /// Total reported runs for this profile (drafted or not).
  public var runCount: Int
  /// Runs where drafting actually engaged (`proposed > 0`) — the only
  /// runs that contribute an accept ratio to the average.
  public var draftedRunCount: Int
  /// Whether drafting engaged on the most recent run.
  public var lastEnabled: Bool
  /// Why the most recent run did not draft despite being requested
  /// (`disabled`, `non_greedy_sampling`, `tool_choice_forced`), or `nil`
  /// when it did engage.
  public var lastFallbackReason: String?
  /// Accept ratio of the most recent run (`0…1`), or `nil` when that run
  /// proposed no drafts (drafting requested but inactive).
  public var lastAcceptRatio: Double?
  /// Average tokens committed per decode step on the most recent run.
  public var lastAvgTokensPerStep: Double
  /// Decode throughput (tok/s) of the most recent run.
  public var lastDecodeTokensPerSec: Double
  /// Running mean accept ratio over drafted runs, or `nil` when none has
  /// drafted yet.
  public var avgAcceptRatio: Double?
  /// Running mean tokens-per-step over drafted runs.
  public var avgTokensPerStep: Double

  static let empty = SpecMetricsAggregate(
    runCount: 0,
    draftedRunCount: 0,
    lastEnabled: false,
    lastFallbackReason: nil,
    lastAcceptRatio: nil,
    lastAvgTokensPerStep: 0,
    lastDecodeTokensPerSec: 0,
    avgAcceptRatio: nil,
    avgTokensPerStep: 0
  )

  /// Fold one run's metrics into the aggregate. Pure so the averaging math
  /// is unit-tested without any file IO. The accept-ratio / tok-per-step
  /// means are taken over DRAFTED runs only — a requested-but-inactive run
  /// still bumps `runCount` and overwrites the `last*` fields (so the badge
  /// can explain *why* it didn't draft) without polluting the averages with
  /// a `0` that never reflected real drafting.
  func folding(_ metrics: SpecMetrics) -> SpecMetricsAggregate {
    var next = self
    next.runCount += 1
    next.lastEnabled = metrics.enabled
    next.lastFallbackReason = metrics.fallbackReason
    next.lastAcceptRatio = metrics.acceptRatio
    next.lastAvgTokensPerStep = metrics.avgTokensPerStep
    next.lastDecodeTokensPerSec = metrics.decodeTokensPerSec
    if let ratio = metrics.acceptRatio {
      let n = Double(draftedRunCount)
      next.avgAcceptRatio = ((avgAcceptRatio ?? 0) * n + ratio) / (n + 1)
      next.avgTokensPerStep = (avgTokensPerStep * n + metrics.avgTokensPerStep) / (n + 1)
      next.draftedRunCount += 1
    }
    return next
  }

  // MARK: - display

  /// Most-recent-run badge copy: "accept 78%, 2.4 tok/step" for a drafted
  /// run, or "didn’t speculate (<why>)" when the last run was requested but
  /// inactive. Kept here (not in the SwiftUI view) so the formatting is
  /// unit-tested in the fast tier.
  public var lastRunSummary: String {
    if let ratio = lastAcceptRatio {
      return "accept \(Self.percent(ratio)), \(Self.tokPerStep(lastAvgTokensPerStep)) tok/step"
    }
    return "didn’t speculate (\(Self.fallbackCopy(lastFallbackReason)))"
  }

  /// Average-over-drafted-runs badge copy, or `nil` until at least two
  /// drafted runs exist (a single run's "average" duplicates "last run").
  public var averageSummary: String? {
    guard let avg = avgAcceptRatio, draftedRunCount >= 2 else { return nil }
    return "accept \(Self.percent(avg)), \(Self.tokPerStep(avgTokensPerStep)) tok/step over \(draftedRunCount) runs"
  }

  static func percent(_ ratio: Double) -> String {
    guard ratio.isFinite else { return "—" }
    return "\(Int((ratio * 100).rounded()))%"
  }

  static func tokPerStep(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.1f", value)
  }

  /// Human copy for a `fallback_reason` wire tag. `nil` means drafting was
  /// requested but proposed no drafts (e.g. the answer was a single token).
  static func fallbackCopy(_ reason: String?) -> String {
    switch reason {
    case "non_greedy_sampling": return "non-greedy sampling"
    case "tool_choice_forced": return "tool call forced"
    case "disabled": return "disabled"
    case .some(let other): return other
    case nil: return "no drafts proposed"
    }
  }
}

/// Observable store of per-profile `SpecMetricsAggregate`s, backed by a
/// JSON file. `@MainActor` because the ProfileEditor observes it and the
/// chat send loop records into it, both on the main actor; the writes are
/// once-per-turn against a tiny file, so synchronous IO is fine (mirrors
/// `GuardrailSettings`).
@MainActor
public final class SpecMetricsStore: ObservableObject {
  /// Keyed by profile id. `@Published` so the editor badge refreshes the
  /// instant a turn reports.
  @Published private var byProfile: [String: SpecMetricsAggregate]

  /// What a non-clean load did with a present-but-bad file. `nil` on a clean
  /// load (file absent or valid).
  public enum LoadDiagnostic: Equatable, Sendable {
    /// The corrupt file was moved aside to `quarantine`; the store started
    /// empty and persistence resumes against the now-free canonical path,
    /// so the preserved bytes can't be silently overwritten.
    case quarantined(corrupt: URL, quarantine: URL)
    /// The corrupt file could not be moved aside, so persistence is DISABLED
    /// for this instance rather than overwriting it — the bytes stay intact
    /// for manual recovery.
    case corruptPersistenceDisabled(URL)
    /// The file was present but could not be *read* (a transient IO or
    /// permission failure), so its bytes are NOT proven corrupt. It is left
    /// untouched — never quarantined — and persistence is DISABLED so the
    /// next `record()` can't overwrite possibly-valid telemetry (#633).
    case unreadablePersistenceDisabled(URL)
  }

  /// Signal raised when the backing file was present but could not be loaded
  /// — either undecodable (#625) or unreadable (#633) — so a future Settings
  /// surface can tell the operator their telemetry was reset and where the
  /// preserved bytes live. The load no longer silently swallows a bad file
  /// into an empty map.
  @Published public private(set) var loadDiagnostic: LoadDiagnostic?

  /// `nil` disables persistence (preview / unit tests that don't want a
  /// file). Reads/writes are best-effort: a corrupt or unwritable file
  /// degrades to in-memory only rather than bricking chat.
  private let fileURL: URL?
  private let fileManager: FileManager

  /// Set when a corrupt file could not be quarantined: `persist()` then
  /// refuses to write so the unreadable bytes survive (no silent wipe).
  private var persistenceDisabled: Bool

  /// Production store rooted at the support dir. A `PieDirs` failure (very
  /// rare — unwritable home) yields an in-memory-only store rather than
  /// throwing into app launch.
  public convenience init() {
    let url = try? PieDirs.applicationSupport()
      .appendingPathComponent("spec-metrics.json", isDirectory: false)
    self.init(fileURL: url)
  }

  /// Test/preview seam: inject the file URL (or `nil` for in-memory).
  public init(fileURL: URL?, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    let outcome = Self.load(from: fileURL, fileManager: fileManager)
    self.byProfile = outcome.aggregates
    self.loadDiagnostic = outcome.diagnostic
    self.persistenceDisabled = outcome.persistenceDisabled
  }

  /// The aggregate for a profile, or `nil` when it has never reported.
  public func aggregate(forProfileID id: String) -> SpecMetricsAggregate? {
    byProfile[id]
  }

  /// Fold one turn's metrics into the profile's aggregate and persist.
  public func record(_ metrics: SpecMetrics, forProfileID id: String) {
    let folded = (byProfile[id] ?? .empty).folding(metrics)
    byProfile[id] = folded
    persist()
  }

  // MARK: - persistence

  /// Sibling path a corrupt file is moved to (`spec-metrics.json.corrupt`).
  static func quarantineURL(for url: URL) -> URL {
    url.appendingPathExtension("corrupt")
  }

  private struct LoadOutcome {
    var aggregates: [String: SpecMetricsAggregate]
    var diagnostic: LoadDiagnostic?
    var persistenceDisabled: Bool

    static let clean = LoadOutcome(aggregates: [:], diagnostic: nil, persistenceDisabled: false)
  }

  /// Four outcomes, never collapsed into one empty map (the #625 bug): an
  /// *absent* file is the legitimate unset state → empty + clean; a *valid*
  /// file decodes; a present-but-*unreadable* file is left untouched with
  /// persistence disabled (a read failure does NOT prove the bytes corrupt,
  /// so moving them would risk destroying valid telemetry — #633); only a
  /// read-OK-but-*undecodable* file is quarantined so the next `record()`
  /// can't silently destroy it, then the store starts empty.
  private static func load(from url: URL?,
                           fileManager: FileManager) -> LoadOutcome {
    guard let url, fileManager.fileExists(atPath: url.path) else { return .clean }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      // Present but unreadable — unproven corrupt. Don't quarantine; just
      // disable persistence so a possibly-valid file is never overwritten.
      Log.store.error("spec-metrics.json present but unreadable; persistence disabled to preserve it")
      return LoadOutcome(aggregates: [:],
                         diagnostic: .unreadablePersistenceDisabled(url),
                         persistenceDisabled: true)
    }
    guard let decoded = try? JSONDecoder()
      .decode([String: SpecMetricsAggregate].self, from: data) else {
      return quarantine(url, fileManager: fileManager)   // read OK, bytes bad
    }
    return LoadOutcome(aggregates: decoded, diagnostic: nil, persistenceDisabled: false)
  }

  /// Move a corrupt file aside, preserving its bytes. On success the store
  /// resumes persistence against the now-free canonical path; if the move
  /// fails, persistence is disabled so the bytes are never overwritten.
  private static func quarantine(_ url: URL,
                                 fileManager: FileManager) -> LoadOutcome {
    let dest = quarantineURL(for: url)
    do {
      try? fileManager.removeItem(at: dest)   // latest corruption wins the slot
      try fileManager.moveItem(at: url, to: dest)
      Log.store.error("spec-metrics.json corrupt; quarantined to \(dest.lastPathComponent, privacy: .public)")
      return LoadOutcome(aggregates: [:],
                         diagnostic: .quarantined(corrupt: url, quarantine: dest),
                         persistenceDisabled: false)
    } catch {
      Log.store.error("spec-metrics.json corrupt and unmovable; persistence disabled to preserve it")
      return LoadOutcome(aggregates: [:],
                         diagnostic: .corruptPersistenceDisabled(url),
                         persistenceDisabled: true)
    }
  }

  private func persist() {
    guard let fileURL, !persistenceDisabled else { return }
    guard let data = try? JSONEncoder().encode(byProfile) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
