import Foundation
import os
import SwiftUI

private let persistenceLog = Logger(subsystem: "com.ratiothink.app", category: "persistence")

/// Surfaces the durability state of the chat store to the GUI so a
/// disk-open failure ( F3) and any per-mutation save failure
/// ( F4 / F6 / F7 / F8 / F9 / F10) don't disappear into a log
/// the user never reads.
///
/// Single source of truth for two things:
///
/// 1. **Storage tier** — whether the live `ModelContainer` is the
///    on-disk SQLite store or the in-memory fallback. The fallback
///    means chats vanish on relaunch; the GUI renders a banner.
/// 2. **Last error** — most recent persistence error with the
///    operation context. Views can present a toast / inline alert
///    without needing per-error subscriptions.
///
/// `@MainActor` because SwiftData mutations and SwiftUI updates
/// both live on the main actor — keeping the observable here means
/// every reporter call sits on the same isolation domain.
@MainActor
public final class PersistenceStatus: ObservableObject {
  public enum Storage: Equatable, Sendable {
    case onDisk
    /// Reason carries the localized message that pushed the app off
    /// the on-disk store — surfaced in the banner so the user can
    /// file a bug with concrete text.
    case inMemoryFallback(reason: String)

    public var isOnDisk: Bool {
      if case .onDisk = self { return true }
      return false
    }
  }

  public struct ReportedError: Equatable, Sendable {
    public let context: String
    public let message: String
    public let timestamp: Date

    public init(context: String, message: String, timestamp: Date) {
      self.context = context
      self.message = message
      self.timestamp = timestamp
    }
  }

  @Published public private(set) var storage: Storage = .onDisk
  @Published public private(set) var lastError: ReportedError?

  public init() {}

  /// Records that the app fell back to the in-memory container.
  /// Idempotent — repeated calls with the same reason are a no-op.
  public func markInMemoryFallback(reason: String) {
    let next = Storage.inMemoryFallback(reason: reason)
    guard storage != next else { return }
    storage = next
  }

  /// Reports a non-fatal persistence error (save failure, delete
  /// failure, stream-flush failure). Logs unconditionally with full
  /// `NSError` detail and updates `lastError`. Views observe
  /// `lastError` to surface a toast / banner.
  public func report(_ error: Error, context: String) {
    let formatted = Self.formatError(error)
    persistenceLog.error("[\(context, privacy: .public)] \(formatted, privacy: .public)")
    lastError = ReportedError(context: context, message: formatted, timestamp: Date())
  }

  /// Clears the last-error breadcrumb after the user dismisses the
  /// banner. State stays stuck on `.inMemoryFallback` until relaunch
  /// because the container itself doesn't get re-opened mid-session.
  public func acknowledgeLastError() {
    lastError = nil
  }

  /// Formats an arbitrary `Error` while preserving `NSError.userInfo`
  /// — SwiftData wraps SQLite / CoreData errors as `NSError` with
  /// file path + result code in `userInfo`, and bare
  /// `localizedDescription` drops it. Used by both this type and
  /// `MessageStreamWriter`'s reporter callback.
  public nonisolated static func formatError(_ error: Error) -> String {
    let nsError = error as NSError
    let base = error.localizedDescription
    if nsError.userInfo.isEmpty {
      return base
    }
    return "\(base) (domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo))"
  }
}
