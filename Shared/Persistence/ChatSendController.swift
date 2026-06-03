import Combine
import Foundation
import SwiftData

/// Transient per-chat send pipeline. The controller bridges the
/// SwiftUI composer to the engine stream and owns the lifetime rules
/// that cross those layers:
///
/// - build a `ChatRequest` from persisted turn history plus toolbar
///   overrides,
/// - insert the assistant row before the first delta so the transcript
///   shows a streaming bubble immediately,
/// - feed deltas through `MessageStreamWriter`, and
/// - cancel stale streams before a newer turn can be clobbered.
@available(macOS 14, *)
@MainActor
public final class ChatSendController: ObservableObject {
  @Published public private(set) var isInFlight = false

  private var generation: UInt64 = 0
  private var task: Task<Void, Never>?
  private var activeWriter: MessageStreamWriter?
  private var activeAssistant: Message?
  private var activeContext: ModelContext?
  private var activePersistenceStatus: PersistenceStatus?

  public init() {}

  public func send(
    chat: Chat,
    context: ModelContext,
    engine: EngineClient,
    modelLoadCenter: ModelLoadCenter,
    persistenceStatus: PersistenceStatus,
    options: ChatSendRequestOptions,
    recoveryGate: ChatRecoveryGate? = nil,
    recoveryPolicy: ChatRecoveryPolicy = .default
  ) {
    cancel()
    generation &+= 1
    let myGeneration = generation
    let request = Self.makeRequest(chat: chat, options: options)
    isInFlight = true
    Diag.app.event("chat.send", [("model", options.modelID)])

    task = Task { @MainActor [weak self] in
      guard let self else { return }
      var writer: MessageStreamWriter?
      defer {
        if self.generation == myGeneration {
          self.activeWriter = nil
          self.activeAssistant = nil
          self.activeContext = nil
          self.activePersistenceStatus = nil
          self.task = nil
          self.isInFlight = false
        }
      }

      guard self.generation == myGeneration, !Task.isCancelled else { return }

      let assistant = Message(
        role: ChatMessage.Role.assistant.rawValue,
        content: "",
        ts: Date()
      )
      context.insert(assistant)
      chat.messages.append(assistant)
      chat.updatedAt = assistant.ts
      do {
        try context.save()
      } catch {
        chat.messages.removeAll { $0.id == assistant.id }
        context.delete(assistant)
        persistenceStatus.report(error, context: "ChatSendController.insertAssistant")
        return
      }

      writer = MessageStreamWriter(
        context: context,
        message: assistant,
        errorReporter: { error, context in
          persistenceStatus.report(error, context: context)
        }
      )
      self.activeWriter = writer
      self.activeAssistant = assistant
      self.activeContext = context
      self.activePersistenceStatus = persistenceStatus

      // Bounded retry ladder. First pass runs the normal stream. On a
      // fault that classifies as engine-gone via `recoveryGate`, wait
      // for the helper's auto-relaunch to bring the engine back to
      // `.running`, then re-issue the SAME `ChatRequest` against a fresh
      // writer so the user does not have to re-click Send. Surfaces the
      // error only after the retry also fails (or no gate was wired).
      var attemptsRemaining = max(1, recoveryPolicy.maxAttempts)
      // Set once the stream delivers its terminal `.finish` chunk. A
      // transport throw AFTER `.finish` but before the `[DONE]` sentinel
      // (engine dies in that window) must NOT be treated as a retryable
      // engine-gone fault — the answer is already persisted; retrying would
      // discard a correct, finished turn.
      var didFinish = false
      streamLoop: while attemptsRemaining > 0 {
        attemptsRemaining -= 1
        do {
          for try await event in engine.chatCompletion(request) {
            guard self.generation == myGeneration, !Task.isCancelled else {
              writer?.cancel()
              return
            }
            switch event {
            case let .modelLoading(loaded, total, eta):
              modelLoadCenter.applyChatMetaEvent(
                .loading(loadedBytes: loaded, totalBytes: total, etaSeconds: eta),
                modelID: options.modelID
              )
              writer?.flush()
            case .modelReady:
              modelLoadCenter.applyChatMetaEvent(.ready, modelID: options.modelID)
              writer?.flush()
            case let .delta(_, content):
              writer?.appendDelta(content)
            case let .reasoningDelta(text):
              writer?.appendReasoningDelta(text)
            case let .finish(reason):
              writer?.finish(meta: Self.finishMeta(for: reason))
              didFinish = true
              let reasonValue = Self.finishReasonValue(for: reason)
              Diag.app.event(reasonValue == "length" ? "chat.truncated" : "chat.stream_end",
                             [("reason", reasonValue)])
              self.activeWriter = nil
              self.activeAssistant = nil
              self.activeContext = nil
              self.activePersistenceStatus = nil
            }
          }
          // Stream completed cleanly — no retry.
          break streamLoop
        } catch is CancellationError {
          writer?.cancel()
          return
        } catch {
          // A throw AFTER the terminal `.finish` chunk (engine died between
          // `.finish` and the `[DONE]` sentinel) is not a lost turn — the
          // answer is already persisted and the active* fields nilled. Treat
          // as terminal: do not retry/reset (would discard a correct answer)
          // and do not markAssistant (would overwrite it with the engine-gone
          // warning). The writer already finished, so no cleanup is needed.
          if didFinish { return }
          guard self.generation == myGeneration, !Task.isCancelled else {
            writer?.cancel()
            return
          }

          let isRecoverableFault = await Self.classifyRecoverable(
            error: error,
            gate: recoveryGate
          )
          guard attemptsRemaining > 0,
                isRecoverableFault,
                let gate = recoveryGate else {
            writer?.cancel()
            // Re-check generation after the `await classifyEngineGone`
            // suspension. A cancel()/supersede during it bumps `generation`
            // and `recordCancelledAssistant` may have already DELETED this
            // (empty) assistant row; markAssistant would then write + save
            // onto a deleted Message and crash SwiftData. Mirror the
            // recovered-path guard below.
            guard self.generation == myGeneration, !Task.isCancelled else { return }
            Self.markAssistant(assistant, failedWith: error, context: context, persistenceStatus: persistenceStatus)
            return
          }

          // Wait for recovery to bring the engine back. The budget is sized
          // to the fault's recovery path (review F1): a HELPER death recovers
          // via the App-side restart ladder (first repair ~17s+), so it gets
          // the larger `helperUnreachableWaitTimeout`; an ENGINE death recovers
          // via PieEngineHost's faster relaunch ladder, so it keeps the tight
          // `waitForReadyTimeout`. Either wait early-exits the moment the
          // helper ladder gives up. If recovery doesn't land in budget, surface
          // the original error so the bubble shows what actually happened.
          let waitBudget = gate.isHelperUnreachable
            ? recoveryPolicy.helperUnreachableWaitTimeout
            : recoveryPolicy.waitForReadyTimeout
          let recovered = await gate.waitUntilRunning(timeout: waitBudget)
          guard recovered else {
            writer?.cancel()
            // Re-check generation after the `await waitUntilRunning`
            // suspension. `waitUntilRunning` returns false on cancellation,
            // so a turn superseded during the recovery wait lands here; the
            // same write-after-delete crash applies. Without this guard the
            // stale task writes onto a row `recordCancelledAssistant` already
            // deleted.
            guard self.generation == myGeneration, !Task.isCancelled else { return }
            Self.markAssistant(assistant, failedWith: error, context: context, persistenceStatus: persistenceStatus)
            return
          }
          guard self.generation == myGeneration, !Task.isCancelled else {
            writer?.cancel()
            return
          }

          // Reset the assistant bubble + writer for the retry pass. Any
          // partial delta or reasoning from the first attempt is
          // discarded: chat-apc does not surface a resume cursor, so a
          // clean re-issue is the only correct behavior.
          assistant.content = ""
          assistant.reasoning = ""
          assistant.meta = nil
          do {
            try context.save()
          } catch {
            persistenceStatus.report(error, context: "ChatSendController.resetAssistantForRetry")
          }
          writer = MessageStreamWriter(
            context: context,
            message: assistant,
            errorReporter: { error, context in
              persistenceStatus.report(error, context: context)
            }
          )
          self.activeWriter = writer
          continue streamLoop
        }
      }
    }
  }

  public func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    activeWriter?.cancel()
    if let assistant = activeAssistant,
       let context = activeContext,
       let status = activePersistenceStatus {
      Self.recordCancelledAssistant(
        assistant,
        context: context,
        persistenceStatus: status
      )
    }
    activeWriter = nil
    activeAssistant = nil
    activeContext = nil
    activePersistenceStatus = nil
    isInFlight = false
  }

  /// True when `error` should be ridden through recovery (wait for the engine
  /// to come back, then retry the turn) rather than surfaced immediately.
  /// Channels:
  ///  · `HTTPEngineError.engineGone` thrown synchronously by
  ///    `baseURLProvider` when the cached status is already
  ///    `.failed(.engineGone)` — the post-poll engine-death case.
  ///  · A streaming throw (URLError, `.http`, `.stream`, …) that races ahead
  ///    of the 1Hz poll: force a fresh helper poll and re-check. The retried
  ///    classification covers BOTH (a) the engine died with a live helper
  ///    (`isEngineGone`), and (b) the HELPER itself died mid-stream
  ///    (`isHelperUnreachable`) — the App's helper-restart ladder will bring
  ///    it back, so the turn waits for `.running` and retries instead of
  ///    surfacing a raw transport error (#393/#412). A non-death fault leaves
  ///    a reachable helper reporting a non-gone state, so neither flag trips
  ///    and the error surfaces normally.
  private static func classifyRecoverable(
    error: Error,
    gate: ChatRecoveryGate?
  ) async -> Bool {
    if case HTTPEngineError.engineGone = error { return true }
    guard let gate else { return false }
    await gate.refreshStatus()
    return gate.isEngineGone || gate.isHelperUnreachable
  }

  private static func makeRequest(chat: Chat, options: ChatSendRequestOptions) -> ChatRequest {
    var turns: [ChatMessage] = []
    if let prompt = options.systemPromptOverride, !prompt.isEmpty {
      turns.append(ChatMessage(role: .system, content: prompt))
    }
    turns.append(contentsOf: chat.messages
      .sorted { lhs, rhs in
        if lhs.ts == rhs.ts { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.ts < rhs.ts
      }
      .compactMap { message in
        guard let role = ChatMessage.Role(rawValue: message.role) else { return nil }
        guard !Self.excludesFromRequestHistory(message, role: role) else { return nil }
        return ChatMessage(role: role, content: message.content)
      })
    return ChatRequest(
      model: options.modelID,
      messages: turns,
      sampling: options.sampling,
      stream: true
    )
  }

  /// Canonical wire string for a finish reason. Shared by `finishMeta`
  /// (persisted JSON) and the `chat.stream_end`/`chat.truncated` breadcrumb so
  /// the two never drift.
  static func finishReasonValue(for reason: ChatEvent.FinishReason) -> String {
    switch reason {
    case .stop:           return "stop"
    case .length:         return "length"
    case .cancelled:      return "cancelled"
    case .other(let raw): return raw
    }
  }

  private static func finishMeta(for reason: ChatEvent.FinishReason) -> Data? {
    struct FinishMeta: Encodable { let finishReason: String }
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try? encoder.encode(FinishMeta(finishReason: finishReasonValue(for: reason)))
  }

  private static func markAssistant(
    _ assistant: Message,
    failedWith error: Error,
    context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) {
    assistant.content = "⚠️ \(PersistenceStatus.formatError(error))"
    // Breadcrumb the error TYPE only — never the prompt/response content.
    Diag.app.event("chat.fail", [("error", String(describing: type(of: error)))])
    do {
      try context.save()
    } catch {
      persistenceStatus.report(error, context: "ChatSendController.markAssistantFailed")
    }
  }

  private static func recordCancelledAssistant(
    _ assistant: Message,
    context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) {
    if assistant.content.isEmpty {
      assistant.chat?.messages.removeAll { $0.id == assistant.id }
      context.delete(assistant)
    } else {
      assistant.meta = finishMeta(for: .cancelled)
    }
    do {
      try context.save()
    } catch {
      persistenceStatus.report(error, context: "ChatSendController.cancelAssistant")
    }
  }

  private static func excludesFromRequestHistory(
    _ message: Message,
    role: ChatMessage.Role
  ) -> Bool {
    guard role == .assistant else { return false }
    if message.content.isEmpty { return true }
    return finishReason(in: message.meta) == "cancelled"
  }

  private static func finishReason(in meta: Data?) -> String? {
    guard let meta,
          let object = try? JSONSerialization.jsonObject(with: meta) as? [String: Any] else {
      return nil
    }
    return object["finish_reason"] as? String
  }
}

public struct ChatSendRequestOptions: Equatable, Sendable {
  public let modelID: String
  public let sampling: ChatSampling
  public let systemPromptOverride: String?

  public init(
    modelID: String,
    sampling: ChatSampling = ChatSampling(),
    systemPromptOverride: String? = nil
  ) {
    self.modelID = modelID
    self.sampling = sampling
    self.systemPromptOverride = systemPromptOverride
  }
}

/// Knobs for the engine-gone retry ladder in `ChatSendController.send`.
/// Defaults match the helper's `PieEngineHost.RelaunchPolicy` so an
/// in-flight chat turn outlasts one full auto-relaunch cycle (backoff +
/// handshake).
public struct ChatRecoveryPolicy: Equatable, Sendable {
  /// Total stream attempts including the first. `1` disables retry
  /// entirely (no second pass); `2` (the default) is "initial + one
  /// retry".
  public var maxAttempts: Int
  /// How long to wait for `.running` again after classifying ENGINE-gone
  /// (helper alive). Sized for `PieEngineHost`'s engine-relaunch ladder
  /// (2 × 1–2s backoff + handshake) — a few seconds.
  public var waitForReadyTimeout: TimeInterval

  /// How long to wait when the fault is a HELPER death (`isHelperUnreachable`).
  /// Larger than `waitForReadyTimeout` because the App-side helper-restart
  /// ladder only restores reachability after several poll cycles plus reconcile
  /// probes (well past the engine-relaunch budget — review F1). NOT a
  /// hand-picked literal: the default is DERIVED from `HelperHealthPolicy` +
  /// the reconcile probe budget via `helperUnreachableCeiling(for:probeBudget:)`,
  /// so a ladder-policy retune cannot silently push recovery past a stale
  /// ceiling and re-introduce F1 (re-F1, TD2 pt4). The wait ALSO early-exits the
  /// instant the ladder gives up (`helperRecoveryGaveUp`), so this is an upper
  /// backstop, not a delay the user always pays.
  public var helperUnreachableWaitTimeout: TimeInterval

  public init(maxAttempts: Int = 2,
              waitForReadyTimeout: TimeInterval = 15,
              helperUnreachableWaitTimeout: TimeInterval =
                ChatRecoveryPolicy.helperUnreachableCeiling(
                  for: HelperHealthPolicy(),
                  probeBudget: HelperReconcileProbeBudget.seconds)) {
    self.maxAttempts = maxAttempts
    self.waitForReadyTimeout = waitForReadyTimeout
    self.helperUnreachableWaitTimeout = helperUnreachableWaitTimeout
  }

  /// Upper bound on how long to wait for the App-side helper-restart ladder to
  /// either recover the engine or escalate to `.unreachable` — DERIVED from the
  /// ladder policy so it tracks any retune instead of drifting (#412 re-F1,
  /// TD2 pt4). At the 1 Hz poll cadence `transientThreshold`/`repairGap` are
  /// seconds; each repair attempt runs the reconcile, which probes reachability
  /// ~twice (pre-unregister + post-register), so an attempt costs
  /// `repairGap + 2 × probeBudget`. `margin` covers scheduling slack.
  /// Overestimates safely: a too-large backstop only delays a give-up the
  /// `.unreachable` early-exit already short-circuits.
  public static func helperUnreachableCeiling(
    for policy: HelperHealthPolicy,
    probeBudget: TimeInterval,
    margin: TimeInterval = 8
  ) -> TimeInterval {
    let pollSecond: TimeInterval = 1   // the HelperHealthController ladder is poll-clocked at 1 Hz
    let transient = TimeInterval(policy.transientThreshold) * pollSecond
    let perAttempt = TimeInterval(policy.repairGap) * pollSecond + 2 * probeBudget
    return transient + TimeInterval(policy.maxRepairAttempts) * perAttempt + margin
  }

  public static let `default` = ChatRecoveryPolicy()
}
