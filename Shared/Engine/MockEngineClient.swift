// Review v2 F6: gate the entire mock behind `#if DEBUG` so a release
// build of the app cannot link a canned-token engine even if a future
// caller forgets to guard their use site. SPM tests + the Xcode unit
// bundle run in Debug, so the only thing this excludes is a shipping
// Release binary — exactly the target audience whose users must NEVER
// see mock output.
#if DEBUG
import Foundation

/// In-process `EngineClient` for offline UI iteration. Emits canned
/// tokens + simulated load progress on a configurable schedule.
///
/// Design constraints:
/// - **Deterministic by default.** Test seams accept an injectable
///   sleep closure so unit tests can run with zero wall-clock delay
///   while still exercising the exact event-emission sequence.
/// - **Cooperative cancellation.** Each yield is preceded by a
///   `try Task.checkCancellation()` so dropping the consumer's task
///   (or letting its parent scope end) terminates the stream
///   promptly. No `onTermination` ceremony needed because the actor
///   holds no external resources — the stream simply stops yielding.
/// - **No shared mutable state.** Configuration is `let` so two views
///   can drive the same `MockEngineClient` from different tasks
///   without protecting it; per-stream state lives inside each
///   `Task` body.
///
/// Not an actor: the streaming methods are non-isolated and produce
/// independent `Task`s per call; making it an actor would force every
/// stream consumer to hop the actor on each yield for no gain.
public final class MockEngineClient: EngineClient, @unchecked Sendable {

  // MARK: - Config

  public struct Config: Sendable {
    /// Step delay between successive load-progress frames.
    public var loadStepInterval: Duration
    /// Step delay between successive chat-delta frames.
    public var chatStepInterval: Duration
    /// Number of progress frames `loadModel`/`chatCompletion` emit
    /// before `.ready`/first delta. The frames split `totalBytes`
    /// into equal-ish slices.
    public var loadSteps: Int
    /// Total bytes reported across the simulated load. Realistic-ish
    /// 2 GiB default lets the loading-indicator math exercise the
    /// `etaSeconds` branch without hardcoding a magic number in views.
    public var totalBytes: UInt64
    /// Whether `chatCompletion` should prepend `modelLoading` /
    /// `modelReady` frames before the first delta. Default true so the
    /// SwiftUI preview shows both code paths; set false to test the
    /// "model already resident" path.
    public var simulateChatLoad: Bool
    /// Canned tokens the `chatCompletion` stream replays. Concatenated
    /// they form the assistant's reply — splitting by whitespace gives
    /// the UI a realistic mid-word streaming cadence.
    public var cannedTokens: [String]
    /// Canned health response returned by `health()`.
    public var health: EngineHealth
    /// Canned model listing returned by `models()`.
    public var models: [ModelInfo]

    public init(
      loadStepInterval: Duration = .milliseconds(120),
      chatStepInterval: Duration = .milliseconds(40),
      loadSteps: Int = 8,
      totalBytes: UInt64 = 2 * 1024 * 1024 * 1024,
      simulateChatLoad: Bool = true,
      cannedTokens: [String] = MockEngineClient.defaultCannedTokens,
      health: EngineHealth = EngineHealth(
        status: .ok,
        loadedModel: "qwen3-0.6b",
        uptimeSeconds: 12.0
      ),
      models: [ModelInfo] = MockEngineClient.defaultModels
    ) {
      self.loadStepInterval = loadStepInterval
      self.chatStepInterval = chatStepInterval
      self.loadSteps = loadSteps
      self.totalBytes = totalBytes
      self.simulateChatLoad = simulateChatLoad
      self.cannedTokens = cannedTokens
      self.health = health
      self.models = models
    }
  }

  public static let defaultCannedTokens: [String] = [
    "Sure", "—", " here's", " a", " quick", " sketch", " of", " what",
    " your", " Pie", " engine", " might", " reply", " with", ".",
  ]

  public static let defaultModels: [ModelInfo] = [
    ModelInfo(id: "qwen3-0.6b", ownedBy: "pie", created: Date(timeIntervalSince1970: 0)),
    ModelInfo(id: "qwen3-7b",   ownedBy: "pie", created: Date(timeIntervalSince1970: 0)),
  ]

  // MARK: - Stored state

  public let config: Config
  /// Sleep seam. Production path forwards to `Task.sleep(for:)`. Tests
  /// inject a no-op (or a tracker) so they don't pay wall-clock cost.
  /// Throwing because `Task.sleep` itself throws on cancellation —
  /// preserving that signature lets cancellation flow through the seam
  /// without an extra check.
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    config: Config = Config(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.config = config
    self.sleep = sleep
  }

  // MARK: - EngineClient

  public func health() async throws -> EngineHealth {
    try Task.checkCancellation()
    return config.health
  }

  public func models() async throws -> [ModelInfo] {
    try Task.checkCancellation()
    return config.models
  }

  public func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let simulateLoad = config.simulateChatLoad
    let steps = config.loadSteps
    let total = config.totalBytes
    let loadInterval = config.loadStepInterval
    let tokens = config.cannedTokens
    let chatInterval = config.chatStepInterval
    let sleeper = sleep

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          if simulateLoad {
            try await Self.streamLoadProgress(
              steps: steps,
              totalBytes: total,
              interval: loadInterval,
              sleep: sleeper,
              yield: { continuation.yield($0) }
            )
          }

          var emittedFirstDelta = false
          for token in tokens {
            try Task.checkCancellation()
            try await sleeper(chatInterval)
            let role: ChatMessage.Role? = emittedFirstDelta ? nil : .assistant
            continuation.yield(.delta(role: role, content: token))
            emittedFirstDelta = true
          }

          try Task.checkCancellation()
          continuation.yield(.finish(reason: .stop))
          continuation.finish()
        } catch is CancellationError {
          continuation.yield(.finish(reason: .cancelled))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    let sleeper = sleep
    let interval = config.chatStepInterval
    // Echo the input twice so consumers can assert on multi-frame
    // streams without hard-coding mock-specific payload bytes.
    let payload = req.input
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try Task.checkCancellation()
          try await sleeper(interval)
          continuation.yield(payload)
          try Task.checkCancellation()
          try await sleeper(interval)
          continuation.yield(payload)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Helpers

  /// Simulated chat-stream model-loading prefix: `steps` `.modelLoading`
  /// frames followed by a single `.modelReady`. `etaSeconds` is reported from
  /// the second frame onward (the first has no transfer-rate sample yet).
  /// #469: the standalone `loadModel` consumer is gone; only
  /// `chatCompletion`'s `simulateChatLoad` uses this now, so it yields
  /// `ChatEvent` directly.
  static func streamLoadProgress(
    steps: Int,
    totalBytes: UInt64,
    interval: Duration,
    sleep: @Sendable (Duration) async throws -> Void,
    yield: (ChatEvent) -> Void
  ) async throws {
    guard steps > 0 else {
      yield(.modelReady)
      return
    }
    let stepBytes = totalBytes / UInt64(steps)
    let intervalSeconds = Double(interval.components.seconds)
                       + Double(interval.components.attoseconds) / 1e18
    for step in 1...steps {
      try Task.checkCancellation()
      try await sleep(interval)
      let loaded = (step == steps) ? totalBytes : UInt64(step) * stepBytes
      let eta: Double? = (step == 1)
        ? nil
        : intervalSeconds * Double(steps - step)
      yield(.modelLoading(loadedBytes: loaded, totalBytes: totalBytes, etaSeconds: eta))
    }
    try Task.checkCancellation()
    yield(.modelReady)
  }
}

#endif
