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
  private var activeUsageIdentity: (tracker: ContextUsageTracker, chatID: UUID, modelID: String, requestID: String)?

  public init() {}

  public func send(
    chat: Chat,
    context: ModelContext,
    engine: EngineClient,
    modelLoadCenter: ModelLoadCenter,
    persistenceStatus: PersistenceStatus,
    options: ChatSendRequestOptions,
    recoveryGate: ChatRecoveryGate? = nil,
    recoveryPolicy: ChatRecoveryPolicy = .default,
    contextUsageTracker: ContextUsageTracker? = nil,
    onSpecMetrics: (@MainActor (SpecMetrics) -> Void)? = nil
  ) {
    cancel()
    generation &+= 1
    let myGeneration = generation
    let request = Self.makeRequest(chat: chat, options: options)
    let usageRequestID = UUID().uuidString
    contextUsageTracker?.markRequestStarted(
      chatID: chat.id,
      modelID: options.modelID,
      requestID: usageRequestID
    )
    self.activeUsageIdentity = contextUsageTracker.map {
      (tracker: $0, chatID: chat.id, modelID: options.modelID, requestID: usageRequestID)
    }
    isInFlight = true
    Diag.app.event("chat.send", [("model", options.modelID)])

    task = Task { @MainActor [weak self] in
      guard let self else { return }
      var writer: MessageStreamWriter?
      defer {
        if self.generation == myGeneration,
           let usage = self.activeUsageIdentity,
           usage.requestID == usageRequestID {
          usage.tracker.markRequestFinished(
            chatID: usage.chatID,
            modelID: usage.modelID,
            requestID: usage.requestID
          )
          self.activeUsageIdentity = nil
        }
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
      var generationMetrics: GenerationMetrics?
      streamLoop: while attemptsRemaining > 0 {
        attemptsRemaining -= 1
        do {
          for try await event in engine.chatCompletion(request) {
            guard self.generation == myGeneration, !Task.isCancelled else {
              writer?.cancel()
              return
            }
            switch event {
            case .modelLoading:
              // #469: pie binds the served model at `pie serve` boot, so a
              // chat-stream `model_loading` meta-frame carries no actionable
              // load progress (the dead `/v1/models/load` UI is gone). Ignore.
              break
            case .modelReady:
              // The engine confirmed it is serving this model for the turn —
              // record residency so the composer's send gate unblocks. (This
              // is the residency half of the former ModelLoadCenter; the
              // load-progress half was removed with `/v1/models/load`.)
              modelLoadCenter.reconcileEngineResident(options.modelID)
              writer?.flush()
            case let .delta(_, content):
              writer?.appendDelta(content)
            case let .reasoningDelta(text):
              writer?.appendReasoningDelta(text)
            case let .generationMetrics(metrics):
              generationMetrics = metrics
              if didFinish {
                Self.persistGenerationMetrics(
                  metrics,
                  on: assistant,
                  finishReason: assistant.finishReason,
                  context: context,
                  persistenceStatus: persistenceStatus
                )
              }
            case let .specMetrics(metrics):
              // Terminal speculation report (#621). Arrives after `.finish`;
              // hand it to the recorder (which persists the per-profile
              // aggregate) without touching the transcript writer.
              onSpecMetrics?(metrics)
            case let .finish(reason):
              writer?.finish(meta: Self.finishMeta(for: reason, generationMetrics: generationMetrics))
              didFinish = true
              let reasonValue = Self.finishReasonValue(for: reason)
              Diag.app.event(reasonValue == "length" ? "chat.truncated" : "chat.stream_end",
                             [("reason", reasonValue)])
              self.activeWriter = nil
              self.activeAssistant = nil
              self.activeContext = nil
              self.activePersistenceStatus = nil
            case let .usage(used, window):
              // #711: the usage frame trails `.finish`. It carries the
              // conversation's engine-true occupancy (committed + working +
              // buffered tokens), NOT this turn's token count — so it lands
              // on the ContextUsageTracker (the single source for the meter +
              // memory estimate) and is NOT written to `Message.tokens`, whose
              // per-message meaning the writer owns. Keyed on this request's
              // identity, so a frame from a superseded turn can't clobber a
              // newer one.
              if let usage = self.activeUsageIdentity, usage.requestID == usageRequestID {
                usage.tracker.markUsage(
                  chatID: usage.chatID,
                  modelID: usage.modelID,
                  requestID: usage.requestID,
                  usage: ContextUsage(usedTokens: used, windowTokens: window)
                )
              }
            }
          }
          // Stream completed cleanly — no retry.
          break streamLoop
        } catch is CancellationError {
          writer?.cancel()
          return
        } catch {
          // A transport closure AFTER the terminal `.finish` chunk (engine
          // died between `.finish` and the `[DONE]` sentinel) is not a lost
          // turn — the answer is already persisted. Protocol/decode errors
          // after `.finish`, however, are still contract violations (for
          // example malformed terminal `generation_metrics`) and must leave a
          // diagnostic instead of looking identical to historical no-metric
          // rows.
          if didFinish {
            if !Self.isBenignPostFinishTransportClosure(error) {
              persistenceStatus.report(error, context: "ChatSendController.postFinishStreamError")
            }
            return
          }
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
            Self.markAssistant(assistant, failedWith: error, requestedModelID: options.modelID, context: context, persistenceStatus: persistenceStatus)
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
            Self.markAssistant(assistant, failedWith: error, requestedModelID: options.modelID, context: context, persistenceStatus: persistenceStatus)
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
          generationMetrics = nil
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

  /// Send the current turn as a **tree-of-thought** search (#413). Shares
  /// the controller's generation/cancel/`isInFlight` scaffolding with
  /// `send` but consumes the `/v1/inferlet` SSE tree stream instead of a
  /// chat completion: each event folds into a `ToTTree`, snapshotted onto
  /// the assistant row's `tot` for the live tree-search view, and the
  /// `tree_complete` final answer becomes the row's `content`.
  ///
  /// Deliberately NOT wired to the engine-gone retry ladder `send` uses:
  /// a ToT search is long and non-idempotent (a re-issue re-runs the whole
  /// tree), so v1 surfaces a fault rather than silently re-spending it.
  public func sendTreeOfThought(
    chat: Chat,
    context: ModelContext,
    engine: EngineClient,
    config: ToTProfileConfig,
    persistenceStatus: PersistenceStatus,
    options: ChatSendRequestOptions
  ) {
    cancel()
    generation &+= 1
    let myGeneration = generation
    guard let request = Self.makeToTRequest(chat: chat, config: config, options: options) else {
      persistenceStatus.report(
        ToTSendError.requestEncodingFailed,
        context: "ChatSendController.makeToTRequest"
      )
      return
    }
    isInFlight = true
    Diag.app.event("chat.send.tot", [("model", options.modelID)])

    task = Task { @MainActor [weak self] in
      guard let self else { return }
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

      let assistant = Message(role: ChatMessage.Role.assistant.rawValue, content: "", ts: Date())
      context.insert(assistant)
      chat.messages.append(assistant)
      chat.updatedAt = assistant.ts
      do {
        try context.save()
      } catch {
        chat.messages.removeAll { $0.id == assistant.id }
        context.delete(assistant)
        persistenceStatus.report(error, context: "ChatSendController.insertAssistant(tot)")
        return
      }
      self.activeAssistant = assistant
      self.activeContext = context
      self.activePersistenceStatus = persistenceStatus

      var tree = ToTTree()
      // Whether a terminal frame (tree_complete) arrived. A ToT stream that
      // ends WITHOUT one — the engine closed the connection mid-search, e.g.
      // a slow search hit the engine's per-request timeout — must surface as
      // a failure, not a silent partial tree the UI shows forever (the
      // "hangs after the beam selection, no completion, no error" report).
      var reachedTerminal = false
      var generationMetrics: GenerationMetrics?
      let encoder = JSONEncoder()
      // Coalesce the live-view encode (#413 phase B). Each `assistant.tot`
      // set republishes the @Model and rebuilds the whole recursive tree
      // view; the token-delta flood (thousands per search) would do that
      // thousands of times and saturate the MainActor — which starved the
      // helper-health monitor into restarting the engine mid-search, closing
      // the SSE with no terminal. So re-encode at most ~15 Hz for delta
      // frames; structural frames (a node starting/finishing, a level
      // pruning, the terminal) always flush so the view never lags a whole
      // node behind and the persisted snapshot is never stale.
      var lastLiveEncode = Date.distantPast
      // #413 diag: time + progress at the SSE close, so the operator's run can
      // line a `no_terminal` close up against an `engine.relaunch` (helper.log)
      // or `engine.poll fail` (app.log) at the same instant — pinning whether a
      // mid-search engine/helper restart closed the stream.
      let totStart = Date()
      do {
        for try await event in toTEventStream(from: engine.dispatchInferlet(request)) {
          guard self.generation == myGeneration, !Task.isCancelled else { return }
          tree.apply(event)
          let isDelta: Bool = {
            switch event {
            case .nodeDelta, .finalDelta: return true
            default: return false
            }
          }()
          let now = Date()
          if !isDelta || now.timeIntervalSince(lastLiveEncode) >= Self.totLiveEncodeInterval {
            lastLiveEncode = now
            assistant.tot = try? encoder.encode(tree)
          }
          switch event {
          case let .treeComplete(selectedNodeID, finalAnswer):
            reachedTerminal = true
            if selectedNodeID == nil {
              // F1: a null selection is a TOTAL failure — the beam selects
              // the best ok leaf whenever one exists, so no selection means
              // every branch failed to generate. The server now emits the
              // terminal `error` frame for this (handled by the `catch`),
              // but treat a null `treeComplete` as failure defensively so a
              // total failure never persists as a blank SUCCESSFUL turn.
              tree.fail(Self.totNoAnswerMessage)
              assistant.tot = try? encoder.encode(tree)
              assistant.content = "⚠️ \(Self.totNoAnswerMessage)"
              Diag.app.event("chat.fail.tot", [("reason", "no_answer")])
            } else if finalAnswer == nil {
              // Review v4 F1 (client defensive): selectedNodeID is an
              // inspection pointer, not proof that a final answer exists.
              // The server now emits `error` for this shape, but if an
              // older/buggy engine sends it, do not persist a blank
              // successful assistant message.
              tree.fail(Self.totFinalAnswerUnavailableMessage)
              assistant.tot = try? encoder.encode(tree)
              assistant.content = "⚠️ \(Self.totFinalAnswerUnavailableMessage)"
              Diag.app.event("chat.fail.tot", [("reason", "final_answer_unavailable")])
            } else {
              if let generationMetrics {
                assistant.content = finalAnswer ?? ""
                Self.persistGenerationMetrics(
                  generationMetrics,
                  on: assistant,
                  finishReason: Self.finishReasonValue(for: .stop),
                  context: context,
                  persistenceStatus: persistenceStatus
                )
              } else {
                tree.fail(Self.totMissingMetricsMessage)
                assistant.tot = try? encoder.encode(tree)
                assistant.content = "⚠️ \(Self.totMissingMetricsMessage)"
                Diag.app.event("chat.fail.tot", [("reason", "missing_generation_metrics")])
              }
            }
            Self.persistTree(context, status: persistenceStatus)
            // Terminal: nil the active row so a later cancel() can't delete
            // an already-finished turn (mirrors `send`).
            self.activeAssistant = nil
            self.activeContext = nil
            self.activePersistenceStatus = nil
          case let .generationMetrics(metrics):
            generationMetrics = metrics
          case let .finalDelta(text):
            // #523 Part A: stream the synthesized final answer into the row
            // live (the row's content is otherwise empty until the terminal);
            // `treeComplete` then sets the authoritative full text.
            assistant.content += text
          case .levelPruned:
            Self.persistTree(context, status: persistenceStatus)
          case .treeStart, .nodeStart, .nodeDelta, .nodeScoring, .nodeComplete:
            // In-memory tot re-encode above already drives the live tree
            // (incl. per-token node_delta fill, #413 phase B, and the
            // `nodeScoring` live-phase flip); disk persistence stays throttled
            // to level boundaries + the terminal.
            break
          case .awaitingSelection:
            // Best-of-N terminal (#690) — never emitted on the tree-of-thought
            // path; handled by `sendBestOfN`.
            break
          }
        }
        // Stream ended cleanly. If no terminal frame arrived, the engine
        // closed the connection mid-search (a slow search hit the engine's
        // per-request timeout, or the daemon dropped it) — surface it as a
        // failure with the partial tree preserved, instead of leaving a
        // half-built tree that looks like a permanent hang (no completion,
        // no error). A real terminal already set `.complete`/`.failed`.
        if self.generation == myGeneration, !Task.isCancelled {
          if !reachedTerminal {
            tree.fail(Self.totIncompleteMessage)
            assistant.tot = try? encoder.encode(tree)
            assistant.content = "⚠️ \(Self.totIncompleteMessage)"
            Diag.app.event("chat.fail.tot", [
              ("reason", "no_terminal"),
              ("elapsed", String(format: "%.1f", Date().timeIntervalSince(totStart))),
              ("nodes", String(tree.nodes.count)),
            ])
          }
          Self.persistTree(context, status: persistenceStatus)
        }
      } catch is CancellationError {
        return  // cancel() owns the row (recordCancelledAssistant)
      } catch {
        guard self.generation == myGeneration, !Task.isCancelled else { return }
        // #477: the bubble gets the normalized taxonomy line; the tree
        // disclosure (a technical surface) keeps the raw diagnostic.
        let problem = EngineProblem(requestError: error, requestedModelID: options.modelID)
        tree.fail(problem.technicalDetail ?? problem.message)
        assistant.tot = try? encoder.encode(tree)
        assistant.content = "⚠️ \(problem.message)"
        if let detail = problem.technicalDetail {
          Log.engine.error("ChatSendController: ToT send failed: \(detail, privacy: .public)")
        }
        Diag.app.event("chat.fail.tot", [("error", String(describing: type(of: error)))])
        Self.persistTree(context, status: persistenceStatus)
      }
    }
  }

  /// Min interval between live-tree re-encodes for token-delta frames
  /// (#413 phase B) — ~15 Hz. Smooth enough for live token-fill, sparse
  /// enough that a search's thousands of deltas no longer rebuild the tree
  /// view thousands of times on the MainActor. Structural frames bypass it.
  static let totLiveEncodeInterval: TimeInterval = 1.0 / 15.0

  /// User-facing copy for a no-ok-leaf tree-of-thought total failure (F1).
  /// Kept close to the engine's `no_answer` message without coupling to its
  /// exact wording.
  static let totNoAnswerMessage = "Tree-of-thought search produced no answer (every branch failed)."

  /// User-facing copy when the ToT stream ends without a terminal frame —
  /// the engine closed the connection mid-search (commonly its per-request
  /// timeout on a slow search). The partial tree is preserved (F-stall).
  static let totIncompleteMessage = "Tree-of-thought search did not finish — the engine closed the connection (it may have timed out). Try a lighter profile (smaller breadth/depth) or a simpler question."

  /// User-facing copy when a selected ToT success arrives without the
  /// required terminal total-throughput metrics (#542 review F1).
  static let totMissingMetricsMessage = "Tree-of-thought search finished without generation metrics."

  /// User-facing copy when the engine selected an inspection node but did
  /// not produce the required direct final answer (review v4 F1).
  static let totFinalAnswerUnavailableMessage = "Tree-of-thought search did not produce a final answer."

  private static func persistTree(_ context: ModelContext, status: PersistenceStatus) {
    do {
      try context.save()
    } catch {
      status.report(error, context: "ChatSendController.persistTree")
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
    if let usage = activeUsageIdentity {
      usage.tracker.markRequestFinished(
        chatID: usage.chatID,
        modelID: usage.modelID,
        requestID: usage.requestID
      )
    }
    activeUsageIdentity = nil
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
  ///  · An engine-ANSWERED fault (`HTTPEngineError.api` / `.stream`) surfaces
  ///    immediately via `engineAnswered` BEFORE the poll: the engine emitted a
  ///    deliberate `{code,message}` envelope or error meta-frame, so it was not
  ///    gone at request time and must never be reclassified as engine-gone by a
  ///    coincident, independent death the refresh happens to observe (#335).
  ///  · A transport-shaped throw (URLError, `.http`, `.nonHTTPResponse`, raw
  ///    exceptions from the SSE reader, …) that races ahead of the 1Hz poll:
  ///    force a fresh helper poll and re-check. The retried classification
  ///    covers BOTH (a) the engine died with a live helper (`isEngineGone`),
  ///    and (b) the HELPER itself died mid-stream (`isHelperUnreachable`) — the
  ///    App's helper-restart ladder will bring it back, so the turn waits for
  ///    `.running` and retries instead of surfacing a raw transport error
  ///    (#393/#412). A non-death fault leaves a reachable helper reporting a
  ///    non-gone state, so neither flag trips and the error surfaces normally.
  private static func classifyRecoverable(
    error: Error,
    gate: ChatRecoveryGate?
  ) async -> Bool {
    if case HTTPEngineError.engineGone = error { return true }
    // A semantic error the engine deliberately emitted — an `.api`
    // `{code,message}` envelope (pre-stream HTTP) or a `.stream` error
    // meta-frame (mid-stream) — proves the engine ANSWERED, so it was not
    // gone at request time. Key the classification on the error SHAPE, not on
    // the engine's state now: without this guard, an independent engine death
    // that races the forced gate refresh (so it reports `isEngineGone`) would
    // reclassify a deterministic semantic fault as engine-gone — wasting a
    // relaunch/retry cycle and delaying the real error by one round-trip
    // (#335). Only transport-shaped faults (URLError, `.http`,
    // `.nonHTTPResponse`, raw stream throws) — where the engine may NOT have
    // answered — fall through to the gate refresh.
    if Self.engineAnswered(error) { return false }
    guard let gate else { return false }
    await gate.refreshStatus()
    return gate.isEngineGone || gate.isHelperUnreachable
  }

  /// True for the two `HTTPEngineError` shapes the engine emits only when it
  /// answered the request: the pre-stream `.api` envelope and the mid-stream
  /// `.stream` meta-frame. Both carry an engine-authored `code`/`message`, so
  /// the engine was demonstrably alive at request time — these are never
  /// engine-death faults regardless of the engine's state now (#335).
  private static func engineAnswered(_ error: Error) -> Bool {
    switch error {
    case HTTPEngineError.api, HTTPEngineError.stream: return true
    default: return false
    }
  }

  /// Clamp a profile `max_tokens` DOWN to the launched engine's effective
  /// ceiling (#474). Pure so the full matrix is unit-tested without an
  /// engine. `nil` or a non-positive ceiling means "unknown / no clamp" —
  /// the engine reports 0 when no model is registered, and clamping a
  /// request to 0 would be a worse failure than the value we are guarding
  /// against — so the profile value passes through untouched. Down-only:
  /// a profile value at or below the ceiling is returned verbatim, so a
  /// user's intentionally-lower cap is never raised.
  nonisolated static func clampMaxTokens(_ requested: Int, toCeiling ceiling: Int?) -> Int {
    guard let ceiling, ceiling > 0 else { return requested }
    return min(requested, ceiling)
  }

  private static func makeRequest(chat: Chat, options: ChatSendRequestOptions) -> ChatRequest {
    let turns = transcriptTurns(chat: chat, options: options)
    // Authoritative speculation coupling (#426). An enabled-speculation
    // profile is a greedy "Repeat Boost" profile: the chat-apc drafter only
    // engages when the request is greedy (temperature 0, #418), so force it
    // here regardless of the toolbar's sampling. A profile with no
    // `[speculation]` section, or one explicitly disabled, attaches no field
    // and leaves sampling untouched — the request stays byte-identical to a
    // normal chat (no `spec_metrics` overhead).
    let spec = options.speculation
    let wireSpec: ChatSpeculation? = (spec?.enabled == true)
      ? ChatSpeculation(
        enabled: true,
        leaderLen: spec?.leaderLen,
        draftLen: spec?.draftLen,
        threadID: chat.id.uuidString,
        profileID: options.profileID)
      : nil
    // #474: clamp the profile's max_tokens DOWN to the launched engine's
    // effective ceiling before send. On a memory-squeezed launch the engine
    // accepts far fewer output tokens than the profile default; sending the
    // blind value trips chat-apc's clean 400 ("max_tokens must be in
    // [1, N]") and the whole turn fails. Clamping makes the turn succeed
    // (shorter reply) instead. Down-only, so an intentionally-lower profile
    // value is preserved.
    let effectiveMaxTokens = clampMaxTokens(
      options.sampling.maxTokens, toCeiling: options.maxOutputTokensCeiling
    )
    let sampling = wireSpec == nil
      ? ChatSampling(
          temperature: options.sampling.temperature,
          topP: options.sampling.topP,
          maxTokens: effectiveMaxTokens)
      : ChatSampling(temperature: 0, topP: options.sampling.topP, maxTokens: effectiveMaxTokens)
    // #522: per-chat prefix-cache directive. The chat id is the thread
    // key; `turn` is the message count at send time (diagnostics — the
    // inferlet content-addresses snapshots, so identity comes from the
    // tokens, not this counter). Sampling/speculation changes do not
    // affect the snapshot key, so a same-model profile switch still reuses
    // the prefix; a changed model or system prompt shows up as different
    // tokens and misses. Reuse is correctness-safe by construction
    // (see chat-apc `prefix_cache`), so it is on for every chat.
    let cache = ChatCacheDirective(
      key: chat.id.uuidString,
      turn: turns.count,
      retention: retentionDirective(from: options.kvUsageSnapshot, modelID: options.modelID)
    )
    // #572: attach `response_format` for a JSON Think profile. Unlike
    // speculation it does NOT force greedy decoding — the grammar masks the
    // sampler regardless of temperature. A profile with no `[constraint]`
    // attaches nothing, leaving the request byte-identical to a normal chat.
    let wireResponseFormat: ChatResponseFormat? = options.responseFormat == .jsonObject
      ? .jsonObject
      : nil
    return ChatRequest(
      model: options.modelID,
      messages: turns,
      sampling: sampling,
      stream: true,
      speculation: wireSpec,
      cache: cache,
      responseFormat: wireResponseFormat
    )
  }

  /// The request-history turns: an optional system-prompt override
  /// followed by the persisted transcript in `(ts, id)` order, dropping
  /// turns that don't belong in history (empty / cancelled assistants).
  /// Shared by the chat (`makeRequest`) and tree-of-thought
  /// (`makeToTRequest`) request builders so the two can't drift.
  private static func transcriptTurns(chat: Chat, options: ChatSendRequestOptions) -> [ChatMessage] {
    var turns: [ChatMessage] = []
    if let prompt = options.systemPromptOverride, !prompt.isEmpty {
      turns.append(ChatMessage(role: .system, content: prompt))
    }
    turns.append(contentsOf: chat.messages
      .sorted(by: Message.transcriptPrecedes)
      .compactMap { message in
        guard let role = ChatMessage.Role(rawValue: message.role) else { return nil }
        guard !Self.excludesFromRequestHistory(message, role: role) else { return nil }
        return ChatMessage(role: role, content: message.content)
      })
    return turns
  }

  private static func retentionDirective(from snapshot: KVUsageSnapshot?,
                                         modelID: String) -> ChatCacheRetentionDirective? {
    guard let snapshot,
          snapshot.modelID == modelID,
          let used = Int(exactly: snapshot.pagesUsed),
          let total = Int(exactly: snapshot.pagesTotal) else {
      return nil
    }
    return ChatCacheRetentionDirective(kvPagesUsed: used, kvPagesTotal: total)
  }

  /// Build the `/v1/inferlet` dispatch body for a tree-of-thought turn.
  /// The ToT `input` carries the transcript + the bounded search params
  /// (server re-validates them); `temperature`/`top_p` come from the same
  /// sampling the chat path uses. Returns nil only if the body can't be
  /// JSON-encoded (a programmer error — the input is plain owned data).
  private static func makeToTRequest(
    chat: Chat,
    config: ToTProfileConfig,
    options: ChatSendRequestOptions
  ) -> InferletRequest? {
    let input = ToTRequestInput(
      model: options.modelID,
      messages: transcriptTurns(chat: chat, options: options),
      breadth: config.breadth,
      depth: config.depth,
      beamWidth: config.beamWidth,
      maxTokensPerNode: config.maxTokensPerNode,
      temperature: options.sampling.temperature,
      topP: options.sampling.topP
    )
    guard let data = try? JSONEncoder().encode(input) else { return nil }
    return InferletRequest(inferlet: "tree-of-thought", input: data, messages: nil, stream: true)
  }

  /// Resume payload for a Best-of-N think-more round (#690): the picked
  /// candidate's snapshot + text, the unpicked siblings to drop, and the new
  /// level the round generates at.
  public struct BestOfNResume: Equatable, Sendable {
    public let pickedName: String
    public let pickedText: String
    public let unpicked: [String]
    public let level: Int
    public init(pickedName: String, pickedText: String, unpicked: [String], level: Int) {
      self.pickedName = pickedName
      self.pickedText = pickedText
      self.unpicked = unpicked
      self.level = level
    }
  }

  /// Stream one Best-of-N round (#690): generate N candidates, render them in
  /// the reused tree view, and persist the `awaiting_selection` terminal as the
  /// round's pick set — WITHOUT auto-selecting an answer (the user picks). The
  /// candidates fold into the same `ToTTree` (`assistant.tot`) the tree-of-
  /// thought path uses; the pickable set + level land on `assistant.bestOfN`.
  /// `resume` is nil for round 1, set for a think-more round.
  public func sendBestOfN(
    chat: Chat,
    context: ModelContext,
    engine: EngineClient,
    config: BestOfNProfileConfig,
    persistenceStatus: PersistenceStatus,
    options: ChatSendRequestOptions,
    resume: BestOfNResume? = nil
  ) {
    cancel()
    generation &+= 1
    let myGeneration = generation
    guard let request = Self.makeBestOfNRequest(
      chat: chat, config: config, options: options, resume: resume)
    else {
      persistenceStatus.report(
        ToTSendError.requestEncodingFailed, context: "ChatSendController.makeBestOfNRequest")
      return
    }
    isInFlight = true
    Diag.app.event("chat.send.bestofn", [("model", options.modelID)])

    task = Task { @MainActor [weak self] in
      guard let self else { return }
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

      let assistant = Message(role: ChatMessage.Role.assistant.rawValue, content: "", ts: Date())
      context.insert(assistant)
      chat.messages.append(assistant)
      chat.updatedAt = assistant.ts
      do {
        try context.save()
      } catch {
        chat.messages.removeAll { $0.id == assistant.id }
        context.delete(assistant)
        persistenceStatus.report(error, context: "ChatSendController.insertAssistant(bestofn)")
        return
      }
      self.activeAssistant = assistant
      self.activeContext = context
      self.activePersistenceStatus = persistenceStatus

      var tree = ToTTree()
      var reachedTerminal = false
      let encoder = JSONEncoder()
      var lastLiveEncode = Date.distantPast
      do {
        for try await event in toTEventStream(from: engine.dispatchInferlet(request)) {
          guard self.generation == myGeneration, !Task.isCancelled else { return }
          tree.apply(event)
          let isDelta: Bool = { if case .nodeDelta = event { return true } else { return false } }()
          let now = Date()
          if !isDelta || now.timeIntervalSince(lastLiveEncode) >= Self.totLiveEncodeInterval {
            lastLiveEncode = now
            assistant.tot = try? encoder.encode(tree)
          }
          switch event {
          case let .awaitingSelection(level, candidates):
            reachedTerminal = true
            assistant.tot = try? encoder.encode(tree)
            // The round's pick set — no choice yet; the user selects in the UI.
            let round = BestOfNRound(level: level, candidates: candidates, chosenID: nil)
            assistant.bestOfN = try? encoder.encode(round)
            Self.persistTree(context, status: persistenceStatus)
            self.activeAssistant = nil
            self.activeContext = nil
            self.activePersistenceStatus = nil
          case .levelPruned:
            Self.persistTree(context, status: persistenceStatus)
          case .treeStart, .nodeStart, .nodeDelta, .nodeScoring, .nodeComplete,
               .treeComplete, .finalDelta, .generationMetrics:
            // Best-of-N never auto-selects (no treeComplete/finalDelta) and
            // emits no metrics; the live re-encode above drives the tree
            // (incl. the `nodeScoring` live-phase flip).
            break
          }
        }
        if self.generation == myGeneration, !Task.isCancelled {
          if !reachedTerminal {
            tree.fail(Self.totIncompleteMessage)
            assistant.tot = try? encoder.encode(tree)
            assistant.content = "⚠️ \(Self.totIncompleteMessage)"
            Diag.app.event("chat.fail.bestofn", [("reason", "no_terminal")])
          }
          Self.persistTree(context, status: persistenceStatus)
        }
      } catch is CancellationError {
        return
      } catch {
        guard self.generation == myGeneration, !Task.isCancelled else { return }
        let problem = EngineProblem(requestError: error, requestedModelID: options.modelID)
        tree.fail(problem.technicalDetail ?? problem.message)
        assistant.tot = try? encoder.encode(tree)
        assistant.content = "⚠️ \(problem.message)"
        if let detail = problem.technicalDetail {
          Log.engine.error("ChatSendController: best-of-n send failed: \(detail, privacy: .public)")
        }
        Diag.app.event("chat.fail.bestofn", [("error", String(describing: type(of: error)))])
        Self.persistTree(context, status: persistenceStatus)
      }
    }
  }

  /// Build the `/v1/inferlet` dispatch body for a Best-of-N round (#690). For a
  /// think-more round `resume` carries the picked snapshot + text, the unpicked
  /// siblings to drop, and the new level; its fields are omitted (round 1) when
  /// nil.
  private static func makeBestOfNRequest(
    chat: Chat,
    config: BestOfNProfileConfig,
    options: ChatSendRequestOptions,
    resume: BestOfNResume?
  ) -> InferletRequest? {
    let input = BestOfNRequestInput(
      model: options.modelID,
      messages: transcriptTurns(chat: chat, options: options),
      n: config.n,
      maxTokensPerCandidate: config.maxTokensPerCandidate,
      temperature: options.sampling.temperature,
      topP: options.sampling.topP,
      resumeFrom: resume?.pickedName,
      pickedText: resume?.pickedText,
      unpicked: resume?.unpicked,
      level: resume?.level
    )
    guard let data = try? JSONEncoder().encode(input) else { return nil }
    return InferletRequest(inferlet: "best-of-n", input: data, messages: nil, stream: true)
  }

  /// Release (delete) a Best-of-N round's candidate KV snapshots — terminal
  /// cleanup (#690). Fired on stop/commit (the chosen reply's text is now
  /// persisted, so its snapshot is dead weight) and on abandon (a round the
  /// user left without picking). Best-effort and fire-and-forget: the request
  /// runs no generation, just frees the round's KV pages, and a failure only
  /// wastes pages until engine teardown — never block the UI on it. Think-more
  /// frees its prior round through the resume path instead, so this is for the
  /// no-next-round terminals only.
  /// `modelID` is the engine's served model; pass `nil` (e.g. from the chat-list
  /// delete path, which has no gate) to let the engine resolve its first
  /// registered model — it serves exactly one, so that is the same model.
  public func releaseBestOfNSnapshots(
    engine: EngineClient,
    modelID: String?,
    snapshotNames: [String]
  ) {
    guard !snapshotNames.isEmpty,
          let request = Self.makeBestOfNReleaseRequest(modelID: modelID, names: snapshotNames)
    else { return }
    Task { @MainActor in
      do {
        // Drain the unary release ack and check the accounting (#703 F4). The
        // request sets `stream: false`, so `dispatchInferlet` takes the unary
        // control transport and yields the server's `application/json`
        // ReleaseReport as a single frame (the old SSE path stripped it). HTTP
        // failures throw here (`assertOK`) and are logged below; a short
        // release — fewer freed than requested — is surfaced so a release that
        // freed nothing no longer reports silent success.
        var frames: [Data] = []
        for try await frame in engine.dispatchInferlet(request) { frames.append(frame) }
        // Decode with `try` (review F1): a 2xx body that is NOT a decodable
        // ReleaseReport (proxy mangling, a 200-wrapped error envelope,
        // truncation, schema drift) must NOT read as a silent clean release —
        // the `DecodingError` propagates to the `catch` below and is logged.
        if let ack = try Self.decodeReleaseAck(frames: frames),
           let message = Self.shortReleaseLog(ack) {
          Log.engine.notice("ChatSendController: \(message, privacy: .public)")
        }
      } catch {
        let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        Log.engine.error(
          "ChatSendController: best-of-n snapshot release failed: \(detail, privacy: .public)")
      }
    }
  }

  /// Build the `/v1/inferlet` body for a Best-of-N snapshot-release request
  /// (#690): a `release` list, no messages, no generation. `modelID` is omitted
  /// when nil so the engine resolves its served model.
  private static func makeBestOfNReleaseRequest(modelID: String?, names: [String]) -> InferletRequest? {
    guard let data = try? JSONEncoder().encode(BestOfNReleaseInput(model: modelID, release: names))
    else { return nil }
    return InferletRequest(inferlet: "best-of-n", input: data, messages: nil, stream: false)
  }

  /// Decode the unary release ack from the dispatched frames (#703 F4/F1).
  /// Returns nil ONLY when no frame arrived; a frame whose body is not a
  /// decodable `ReleaseReport` THROWS the `DecodingError` rather than collapsing
  /// to a silent success — `releaseBestOfNSnapshots` lets it reach the logging
  /// `catch`. `nonisolated` + pure so the decode-failure contract is
  /// unit-tested without a live engine.
  nonisolated static func decodeReleaseAck(frames: [Data]) throws -> BestOfNReleaseAck? {
    var ack: BestOfNReleaseAck?
    for frame in frames {
      ack = try JSONDecoder().decode(BestOfNReleaseAck.self, from: frame)
    }
    return ack
  }

  /// #703 F4: the human-readable short-release line, or nil when the engine
  /// freed every requested snapshot. A short release (`released < requested`)
  /// is benign for a re-release (some names already evicted), but a FULL miss
  /// (`released == 0`) signals the release reached the wrong engine or the
  /// round's snapshots were already gone. Pure so the accounting decision is
  /// unit-tested without a live engine. `nonisolated` — pure over its argument,
  /// touches no actor state.
  nonisolated static func shortReleaseLog(_ ack: BestOfNReleaseAck) -> String? {
    guard ack.released < ack.requested else { return nil }
    return "best-of-n release freed \(ack.released)/\(ack.requested) snapshots "
      + "(\(ack.absent) already absent)"
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
    finishMeta(for: reason, generationMetrics: nil)
  }

  private static func finishMeta(
    for reason: ChatEvent.FinishReason,
    generationMetrics: GenerationMetrics?
  ) -> Data? {
    let validMetrics = finishReasonValue(for: reason) == finishReasonValue(for: .cancelled)
      ? nil
      : validGenerationMetrics(generationMetrics)
    let meta = MessageMeta(
      finishReason: finishReasonValue(for: reason),
      generationPerformance: validMetrics
    )
    return try? JSONEncoder().encode(meta)
  }

  private static func validGenerationMetrics(_ metrics: GenerationMetrics?) -> GenerationMetrics? {
    guard let metrics,
          metrics.outputTokens > 0,
          metrics.elapsedSeconds > 0,
          metrics.elapsedSeconds.isFinite,
          metrics.tokensPerSecond > 0,
          metrics.tokensPerSecond.isFinite else { return nil }
    return metrics
  }

  private static func persistGenerationMetrics(
    _ metrics: GenerationMetrics,
    on assistant: Message,
    finishReason: String?,
    context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) {
    guard finishReason != finishReasonValue(for: .cancelled),
          let valid = validGenerationMetrics(metrics) else { return }
    assistant.tokens = valid.outputTokens
    assistant.meta = try? JSONEncoder().encode(MessageMeta(
      finishReason: finishReason,
      generationPerformance: valid
    ))
    do {
      try context.save()
    } catch {
      persistenceStatus.report(error, context: "ChatSendController.persistGenerationMetrics")
    }
  }

  private static func isBenignPostFinishTransportClosure(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cancelled,
           .networkConnectionLost,
           .cannotConnectToHost,
           .cannotFindHost,
           .notConnectedToInternet,
           .timedOut:
        return true
      default:
        return false
      }
    }
    if let engineError = error as? HTTPEngineError,
       case .engineGone = engineError {
      return true
    }
    return false
  }

  private static func markAssistant(
    _ assistant: Message,
    failedWith error: Error,
    requestedModelID: String?,
    context: ModelContext,
    persistenceStatus: PersistenceStatus
  ) {
    let problem = EngineProblem(requestError: error, requestedModelID: requestedModelID)
    assistant.content = "⚠️ \(problem.message)"
    // The raw diagnostic never reaches the bubble (#477) — log it here so
    // the failure stays traceable.
    if let detail = problem.technicalDetail {
      Log.engine.error("ChatSendController: send failed: \(detail, privacy: .public)")
    }
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
    return message.finishReason == "cancelled"
  }
}

/// JSON body for the tree-of-thought `/v1/inferlet` dispatch `input`.
/// snake_case keys mirror the engine's `TotInput` schema; `temperature` /
/// `top_p` come from the shared sampling, the rest from the ToT profile.
private struct ToTRequestInput: Encodable {
  let model: String
  let messages: [ChatMessage]
  let breadth: Int
  let depth: Int
  let beamWidth: Int
  let maxTokensPerNode: Int
  let temperature: Double
  let topP: Double

  private enum CodingKeys: String, CodingKey {
    case model, messages, breadth, depth, temperature
    case beamWidth = "beam_width"
    case maxTokensPerNode = "max_tokens_per_node"
    case topP = "top_p"
  }
}

/// `/v1/inferlet` dispatch body for a Best-of-N round (#690). Round-1 leaves
/// the resume fields nil → the synthesized `Encodable` omits them
/// (`encodeIfPresent`), so the server reads it as a fresh round.
private struct BestOfNRequestInput: Encodable {
  let model: String
  let messages: [ChatMessage]
  let n: Int
  let maxTokensPerCandidate: Int
  let temperature: Double
  let topP: Double
  let resumeFrom: String?
  let pickedText: String?
  let unpicked: [String]?
  let level: Int?

  private enum CodingKeys: String, CodingKey {
    case model, messages, n, temperature, level, unpicked
    case maxTokensPerCandidate = "max_tokens_per_candidate"
    case topP = "top_p"
    case resumeFrom = "resume_from"
    case pickedText = "picked_text"
  }
}

/// `/v1/inferlet` body for a Best-of-N snapshot-release request (#690): names
/// to drop, no messages — the server runs no generation and acks the freed
/// count.
private struct BestOfNReleaseInput: Encodable {
  /// Omitted when nil (`encodeIfPresent`) so the engine resolves its served
  /// model — the delete path has no gate to supply a model id.
  let model: String?
  let release: [String]

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(model, forKey: .model)
    try c.encode(release, forKey: .release)
  }

  private enum CodingKeys: String, CodingKey { case model, release }
}

/// The unary `application/json` ack `bestofn::release::dispatch_release` returns
/// (#703): the snapshot-release accounting. `released + absent == requested`
/// always; `released < requested` means some names were already gone (a
/// re-release or an earlier eviction). Decoded from the single frame the unary
/// control transport yields so a release that freed nothing no longer reports
/// silent success.
struct BestOfNReleaseAck: Decodable, Equatable {
  let requested: Int
  let released: Int
  let absent: Int
}

/// Failure constructing a tree-of-thought send.
public enum ToTSendError: Error, Equatable, Sendable {
  /// The `/v1/inferlet` dispatch body could not be JSON-encoded.
  case requestEncodingFailed
}

public struct ChatSendRequestOptions: Equatable, Sendable {
  public let modelID: String
  public let sampling: ChatSampling
  public let systemPromptOverride: String?
  /// Selected `Profile.id` for this send. Sent with enabled
  /// speculation so chat-apc can fork Cacheback sidecars on profile
  /// changes even when model/system prompt stay the same.
  public let profileID: String?
  /// Speculative-decoding settings of the chat's selected profile, or
  /// `nil` when the profile has none. `makeRequest` injects this into the
  /// request (and forces greedy temperature) when `enabled` — see #426.
  public let speculation: Profile.Speculation?
  /// The launched engine's effective `max_tokens` ceiling for the resident
  /// model (#474), from `ModelLoadCenter.residentMaxOutputTokens` (which
  /// mirrors `GET /v1/models`' `max_output_tokens`). `makeRequest` clamps
  /// the profile's `max_tokens` DOWN to this so a memory-squeezed launch
  /// never trips the engine's clean 400. `nil` = ceiling unknown
  /// (pre-#474 engine / not yet reconciled) → no clamp, send the profile
  /// value verbatim. The profile default stays distinct from this
  /// per-launch effective limit.
  public let maxOutputTokensCeiling: Int?
  /// Latest #517 runtime/inferlet-backed KV usage snapshot for `modelID`.
  /// When present and model-matched, `makeRequest` passes it to chat-apc's
  /// cache-retention directive so eviction uses pie `model_status`
  /// accounting rather than app-side token estimates.
  public let kvUsageSnapshot: KVUsageSnapshot?
  /// Output-constraint mode of the chat's selected profile, or `nil` when
  /// the profile has no `[constraint]`. `makeRequest` attaches the OpenAI
  /// `response_format` wire field when `.jsonObject` — see #572.
  public let responseFormat: ResponseFormat?

  public init(
    modelID: String,
    sampling: ChatSampling = ChatSampling(),
    systemPromptOverride: String? = nil,
    profileID: String? = nil,
    speculation: Profile.Speculation? = nil,
    maxOutputTokensCeiling: Int? = nil,
    kvUsageSnapshot: KVUsageSnapshot? = nil,
    responseFormat: ResponseFormat? = nil
  ) {
    self.modelID = modelID
    self.sampling = sampling
    self.systemPromptOverride = systemPromptOverride
    self.profileID = profileID
    self.speculation = speculation
    self.maxOutputTokensCeiling = maxOutputTokensCeiling
    self.kvUsageSnapshot = kvUsageSnapshot
    self.responseFormat = responseFormat
  }

  /// A copy with `sampling` replaced. Used by the tree-of-thought dispatch
  /// to source its temperature from the active profile (#523 Part B) rather
  /// than the toolbar default, leaving every other option intact.
  public func withSampling(_ sampling: ChatSampling) -> ChatSendRequestOptions {
    ChatSendRequestOptions(
      modelID: modelID,
      sampling: sampling,
      systemPromptOverride: systemPromptOverride,
      profileID: profileID,
      speculation: speculation,
      maxOutputTokensCeiling: maxOutputTokensCeiling,
      kvUsageSnapshot: kvUsageSnapshot,
      responseFormat: responseFormat
    )
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
