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
    options: ChatSendRequestOptions
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
            let reasonValue = Self.finishReasonValue(for: reason)
            Diag.app.event(reasonValue == "length" ? "chat.truncated" : "chat.stream_end",
                           [("reason", reasonValue)])
            self.activeWriter = nil
            self.activeAssistant = nil
            self.activeContext = nil
            self.activePersistenceStatus = nil
          }
        }
      } catch is CancellationError {
        writer?.cancel()
      } catch {
        guard self.generation == myGeneration, !Task.isCancelled else {
          writer?.cancel()
          return
        }
        writer?.cancel()
        Self.markAssistant(assistant, failedWith: error, context: context, persistenceStatus: persistenceStatus)
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
