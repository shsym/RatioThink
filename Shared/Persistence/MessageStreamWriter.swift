import Foundation
import SwiftData

/// Batched writer for streamed assistant turns. Streaming delta
/// callbacks fire at ~30–100 Hz; persisting every delta would
/// thrash SwiftData's change-tracker and the SwiftUI `@Query`
/// observers downstream. `MessageStreamWriter` buffers the delta
/// string in memory and saves to disk on either:
///
/// 1. Wall-clock timer (`flushInterval`, default 250 ms).
/// 2. An explicit `flush()` call from `model_ready` / `finish`
///    events (or any other "boundary" the caller wants to land
///    durably).
///
/// Durability contract: every `flush()` (and therefore every timer
/// tick that has buffered deltas) calls `context.save()`. SwiftData
/// auto-save semantics shifted between OS versions and the writer
/// owns the durability boundary — autosave is not relied on. Save
/// failures are routed through `errorReporter` so the GUI can show
/// a toast and the engine pipeline can decide whether to keep
/// streaming.
///
/// The writer owns no lifetime contracts beyond the message row it
/// was constructed with — callers should call `finish(...)` or
/// `cancel()` to stop the timer explicitly. As a safety net `deinit`
/// invalidates the timer so a dropped writer (view disappears
/// mid-stream, engine cancellation forgets) does not leak a
/// repeating timer that retains its closure; `deinit` deliberately
/// does **not** flush — a dropped buffer is a dropped buffer, never
/// a silent late commit.
///
/// `@MainActor` because `ModelContext` is main-actor isolated by
/// default in SwiftData; streaming consumers cross actor boundaries
/// to hand the writer a delta string.
@available(macOS 14, *)
@MainActor
public final class MessageStreamWriter {
  /// Default flush cadence per the design doc Phase 4 spec.
  ///
  /// Nonisolated so it can appear as a default argument on the
  /// `@MainActor`-isolated `init` — main-actor isolation on a
  /// `static let` constant is meaningless and trips a Swift 6
  /// concurrency error.
  public nonisolated static let defaultFlushInterval: TimeInterval = 0.250

  /// Callback type for non-fatal persistence failures. Receives the
  /// thrown error + a short context tag (`"flush"`, `"finish"`,
  /// `"cancel"`) so the reporter can route the message to a status
  /// banner or telemetry sink.
  public typealias ErrorReporter = (Error, String) -> Void

  private let context: ModelContext
  private let message: Message
  private let flushInterval: TimeInterval
  private let errorReporter: ErrorReporter?
  private var pending: String = ""
  /// Buffered reasoning (`reasoning_content`) deltas, flushed into
  /// `message.reasoning` on the same durability boundary as `content`
  /// so the thinking section and the answer stay consistent on disk
  ///.
  private var pendingReasoning: String = ""
  private var timer: Timer?
  private var didFinish = false

  public init(
    context: ModelContext,
    message: Message,
    flushInterval: TimeInterval = defaultFlushInterval,
    errorReporter: ErrorReporter? = nil
  ) {
    self.context = context
    self.message = message
    self.flushInterval = flushInterval
    self.errorReporter = errorReporter
  }

  /// Safety net: invalidate the repeating timer when the writer is
  /// dropped without `finish()` / `cancel()`. `Timer.invalidate()`
  /// is thread-safe (callable from any isolation), so `deinit`
  /// stays nonisolated as required by Swift concurrency. Does not
  /// flush — a dropped reference is a dropped buffer.
  deinit {
    timer?.invalidate()
  }

  /// Number of buffered characters not yet committed to the row.
  /// Exposed for tests / diagnostics.
  public var pendingCount: Int { pending.count }

  /// Appends a streaming delta. Starts the flush timer on first
  /// delta and re-arms it implicitly via `Timer.scheduledTimer`'s
  /// repeating cadence — no per-call timer churn.
  public func appendDelta(_ text: String) {
    guard !didFinish else { return }
    pending.append(text)
    armTimer()
  }

  /// Appends a streaming reasoning (`reasoning_content`) delta. Buffered
  /// separately from `content` and committed to `message.reasoning` on
  /// the same flush boundary.
  public func appendReasoningDelta(_ text: String) {
    guard !didFinish else { return }
    pendingReasoning.append(text)
    armTimer()
  }

  /// Forces a durability boundary. Safe to call when the buffer is
  /// empty. Bumps `chat.updatedAt` so the sidebar's recency sort
  /// promotes a chat whose assistant turn is still streaming —
  /// otherwise pin / profile toggles would float ahead of the most
  /// recent activity ( F2).
  public func flush() {
    guard !pending.isEmpty || !pendingReasoning.isEmpty else { return }
    let previousContent = message.content
    let previousReasoning = message.reasoning
    let owningChat = message.chat
    let previousUpdatedAt = owningChat?.updatedAt
    message.content.append(pending)
    message.reasoning.append(pendingReasoning)
    let flushed = pending
    let flushedReasoning = pendingReasoning
    pending.removeAll(keepingCapacity: true)
    pendingReasoning.removeAll(keepingCapacity: true)
    owningChat?.updatedAt = Date()
    do {
      try context.save()
    } catch {
      // Mirror the rollback shape used elsewhere on the durability
      // boundary ( F21): un-bump `chat.updatedAt` and re-buffer
      // both flushed slices so the in-memory view doesn't overstate
      // persistence relative to disk. A subsequent successful
      // flush will re-attempt the same write.
      message.content = previousContent
      message.reasoning = previousReasoning
      if let owningChat, let previousUpdatedAt {
        owningChat.updatedAt = previousUpdatedAt
      }
      pending.insert(contentsOf: flushed, at: pending.startIndex)
      pendingReasoning.insert(contentsOf: flushedReasoning, at: pendingReasoning.startIndex)
      errorReporter?(error, "MessageStreamWriter.flush")
    }
  }

  /// Marks the turn complete: flushes any buffered tail, sets token
  /// count + finish-reason metadata, then stops the timer. After
  /// this call further `appendDelta` are no-ops so a late-arriving
  /// delta (engine sent extra frames after `finish_reason`) doesn't
  /// silently extend the row.
  public func finish(tokens: Int? = nil, meta: Data? = nil) {
    guard !didFinish else { return }
    flush()
    if let tokens { message.tokens = tokens }
    if let meta { message.meta = meta }
    if let owningChat = message.chat {
      owningChat.updatedAt = Date()
    }
    stopTimer()
    didFinish = true
    do {
      try context.save()
    } catch {
      errorReporter?(error, "MessageStreamWriter.finish")
    }
  }

  /// Aborts streaming without committing buffered deltas. Used when
  /// the consumer cancels mid-stream — the partial content already
  /// flushed by the timer stays (the user typed-then-cancelled
  /// transcript is a coherent state); the buffer in flight is
  /// dropped. Idempotent.
  public func cancel() {
    guard !didFinish else { return }
    pending.removeAll(keepingCapacity: false)
    pendingReasoning.removeAll(keepingCapacity: false)
    stopTimer()
    didFinish = true
    do {
      try context.save()
    } catch {
      errorReporter?(error, "MessageStreamWriter.cancel")
    }
  }

  // MARK: - timer

  private func armTimer() {
    guard timer == nil else { return }
    let t = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.flush() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
}
