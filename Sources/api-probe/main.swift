import Foundation
import RatioThinkCore

// independent HTTP-API assertion for the full-chain E2E.
//
// Drives a chat request against the SAME running engine the GUI uses,
// through the SAME client + protocol the app uses
// (`HTTPEngineClient.chatCompletion` → `POST /v1/chat/completions`,
// served by `pie serve` + the chat-apc inferlet). Asserts the engine
// itself returns a real generated reply containing the expected token —
// decoupled from the SwiftUI render. This proves the API contract, not
// just the GUI.
//
// FOUNDATION FOR UI<->API PARITY (, future work): the same
// instruction a user issues in the UI ("The capital of France is")
// should be provable over the engine's HTTP/WS API. This probe is the
// first such cross-surface check; it is a TEST assertion + a documented
// seed only — it builds NO new product API surface. A future pass can
// generalize it into a parity harness that runs the same prompt through
// the UI and the API and compares outcomes.
//
// Exit 0 = reply contained the expected token; 1 = mismatch/empty;
// 2 = bad invocation; other = transport/timeout error.

@main
enum APIProbe {
  static func main() async {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["PIE_TEST_API_BASE_URL"], !raw.isEmpty,
          let baseURL = URL(string: raw) else {
      FileHandle.standardError.write(Data("api-probe: PIE_TEST_API_BASE_URL required\n".utf8))
      exit(2)
    }
    let model = env["PIE_TEST_API_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    let prompt = env["PIE_TEST_API_PROMPT"].flatMap { $0.isEmpty ? nil : $0 } ?? "The capital of France is"
    let expect = env["PIE_TEST_API_EXPECT"].flatMap { $0.isEmpty ? nil : $0 } ?? "Paris"
    let timeout = env["PIE_TEST_API_TIMEOUT"].flatMap(Double.init) ?? 120

    print("api-probe: base=\(baseURL.absoluteString) model=\(model) prompt=\(prompt.debugDescription) expect=\(expect.debugDescription)")

    let client = HTTPEngineClient(baseURL: baseURL)
    let request = ChatRequest(
      model: model,
      messages: [ChatMessage(role: .user, content: prompt)]
    )

    do {
      let reply = try await withTimeout(seconds: timeout) {
        var text = ""
        for try await event in client.chatCompletion(request) {
          switch event {
          case let .delta(_, content):
            text += content
          case .finish:
            return text
          // Reasoning rides its own channel and is not part of the
          // visible reply this probe asserts on.
          case .reasoningDelta, .generationMetrics, .modelLoading, .modelReady, .specMetrics, .usage:
            continue
          }
        }
        return text
      }
      let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      print("api-probe: reply=\(trimmed.debugDescription)")
      guard !trimmed.isEmpty else {
        FileHandle.standardError.write(Data("api-probe: engine returned an empty reply\n".utf8))
        exit(1)
      }
      guard trimmed.localizedCaseInsensitiveContains(expect) else {
        FileHandle.standardError.write(Data("api-probe: reply did not contain \(expect.debugDescription)\n".utf8))
        exit(1)
      }
      print("api-probe: PASS — engine reply contains \(expect.debugDescription)")
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("api-probe: chatCompletion failed: \(error)\n".utf8))
      exit(3)
    }
  }

  /// Fail loud on a hung stream rather than block the E2E forever.
  static func withTimeout<T: Sendable>(seconds: TimeInterval,
                                       _ body: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw ProbeError.timeout(seconds)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw ProbeError.timeout(seconds)
      }
      return result
    }
  }
}

enum ProbeError: Error, CustomStringConvertible {
  case timeout(TimeInterval)
  var description: String {
    switch self {
    case let .timeout(s): return "chatCompletion timed out after \(s)s"
    }
  }
}
