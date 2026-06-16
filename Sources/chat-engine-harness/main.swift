import Darwin
import Foundation
import RatioThinkCore

@main
enum EngineHarness {
  static func main() async throws {
    let env = ProcessInfo.processInfo.environment
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    // The model the engine serves is the SAME id the app pins as the chat's
    // selection (`PIE_TEST_CHAT_MODEL_PIN` → `Chat.modelID`), so the request the
    // app sends and the model this harness advertises always match (#504).
    let model = env["PIE_TEST_CHAT_MODEL_PIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "Qwen/Qwen3-0.6B"
    let pieBinary = URL(fileURLWithPath: env["PIE_BIN"] ?? cwd.appendingPathComponent("Vendor/pie/target/aarch64-apple-darwin/release/pie").path)
    let urlFile = URL(fileURLWithPath: env["PIE_TEST_ENGINE_URL_FILE"] ?? "/tmp/pie-chat-engine.url")
    let pieHome: URL
    if let configuredHome = env["PIE_TEST_ENGINE_HOME"], !configuredHome.isEmpty {
      pieHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
    } else {
      pieHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("p258e-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
    let wasm = cwd.appendingPathComponent("Inferlets/chat-apc/prebuilt/chat-apc.wasm", isDirectory: false)
    let manifest = cwd.appendingPathComponent("Inferlets/chat-apc/Pie.toml", isDirectory: false)

    try FileManager.default.createDirectory(at: pieHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: urlFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Keep the harness' non-content DiagnosticLog breadcrumbs isolated with the
    // engine home under test. Without this, helper-style lifecycle events from
    // the CLI harness land in the user's real RatioThink helper.log, making
    // bounded reproductions harder to correlate and potentially polluting
    // operator diagnostics.
    setenv(PieDirs.homeEnvVar, pieHome.path, 1)

    //  full-chain mode: serve a portable app-staged GGUF (the path
    // the Settings downloader wrote into a shared PIE_HOME/models)
    // instead of resolving an HF-cached model. Slug is `<repo>/<file>`.
    // `.portable` registers the model under the SLUG as its served id
    // (`PieControlLauncher.renderPortableModel` writes `name = modelSlug`),
    // matching production's `.portableResolved(servedModelID: profile.model)`
    // — so both the `/v1/models` id and the load target are the slug, NOT
    // "default" (loading "default" fails `model_not_found`). The App then
    // renders the menu label as `ModelDisplayName.leaf(slug)`. Both env vars
    // unset keeps the original `.metal` behavior (this harness is shared).
    let modelConfig: PieControlLauncher.ModelConfig
    let loadTarget: String
    if let slug = env["PIE_TEST_HARNESS_MODEL_SLUG"], !slug.isEmpty,
       let rootPath = env["PIE_TEST_HARNESS_MODELS_ROOT"], !rootPath.isEmpty {
      modelConfig = .portable(
        modelSlug: slug,
        modelsRoot: URL(fileURLWithPath: rootPath, isDirectory: true))
      loadTarget = slug
      print("chat-engine-harness: portable app-staged model slug=\(slug) modelsRoot=\(rootPath)")
    } else {
      modelConfig = .metal(modelID: model)
      loadTarget = model
    }

    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: pieBinary,
      wasmURL: wasm,
      manifestURL: manifest,
      subprocessEnvironment: SpawnEnvSanitizer.sanitize(env),
      pieHome: pieHome,
      shmemName: "/pie258_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))",
      handshakeTimeout: 30,
      profileID: "chat",
      modelConfig: modelConfig
    )

    if let lifecycleMode = env["PIE_TEST_LIFECYCLE_SOAK"], !lifecycleMode.isEmpty {
      let ok = try await runLifecycleSoak(mode: lifecycleMode, spec: spec, loadTarget: loadTarget, env: env)
      exit(ok ? 0 : 1)
    }

    print("chat-engine-harness: launching \(pieBinary.path) with model \(loadTarget)")
    let (port, session) = try await PieControlLauncher.launch(spec: spec)
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    print("chat-engine-harness: engine running at \(baseURL.absoluteString)")

    do {
      try await loadModel(loadTarget, baseURL: baseURL)
      // ToT app-path E2E mode (#413 stall repro / regression): when
      // PIE_TEST_TOT_QUESTION is set, drive a real tree-of-thought search
      // through the SAME Swift path the app uses — HTTPEngineClient
      // .dispatchInferlet -> toTEventStream -> ToTTree — and assert it
      // reaches a `tree_complete` terminal. This is the coverage the wire
      // probe (Python, bypasses Swift) and the TCC-blocked GUI tests both
      // missed. Exits non-zero if the stream stalls / ends without a
      // terminal.
      if let question = env["PIE_TEST_TOT_QUESTION"], !question.isEmpty {
        // Depth-parametric coverage (#649 follow-up): prove the "every level
        // reasons under thinking:true" invariant at more than one depth on a
        // single engine boot. `PIE_TEST_TOT_DEPTHS` is a comma list (e.g.
        // "2,3"); each depth drives its own ToT search on the same engine, so
        // the deeper case exercises a true intermediate depth>1 level (level 2
        // is no longer the final level). Falls back to the single
        // `PIE_TEST_TOT_DEPTH` run when unset (back-compat).
        let depths = parsedDepths(env: env)
        var allOk = true
        for d in depths {
          if depths.count > 1 { print("chat-engine-harness: ── ToT depth case depth=\(d) ──") }
          let ok = try await runTreeOfThought(
            question: question, baseURL: baseURL, env: env, depthOverride: d)
          allOk = allOk && ok
        }
        _ = await session.shutdown(reason: "harness.tot_complete")
        exit(allOk ? 0 : 1)
      }
      try baseURL.absoluteString.write(to: urlFile, atomically: true, encoding: .utf8)
      print("chat-engine-harness: wrote \(urlFile.path)")
      await waitForSIGTERM()
      print("chat-engine-harness: shutting down")
      _ = await session.shutdown(reason: "harness.sigterm")
    } catch {
      _ = await session.shutdown(reason: "harness.error")
      throw error
    }
  }

  /// Production-lifecycle soak harness: drives the real `PieEngineHost`
  /// liveness monitor + optional auto-relaunch instead of launching
  /// `PieControlLauncher` directly. Emits only non-content lifecycle data.
  private static func runLifecycleSoak(
    mode: String,
    spec originalSpec: PieControlLauncher.LaunchSpec,
    loadTarget: String,
    env: [String: String]
  ) async throws -> Bool {
    let duration = doubleEnv("PIE_TEST_LIFECYCLE_DURATION", 150, env: env)
    let interval = doubleEnv("PIE_TEST_LIFECYCLE_LIVENESS_INTERVAL", 5, env: env)
    let threshold = intEnv("PIE_TEST_LIFECYCLE_LIVENESS_THRESHOLD", 2, env: env)
    let pids = Locked<[pid_t]>([])
    var spec = originalSpec
    spec.pidSink = { pid in pids.withLock { $0.append(pid) } }

    final class HostBox: @unchecked Sendable { weak var host: PieEngineHost? }
    let box = HostBox()
    let relauncher: PieEngineHost.Relauncher = { [box, spec] in
      print("chat-engine-harness: lifecycle relauncher invoked")
      _ = box.host?.start(spec)
    }
    let host = PieEngineHost(
      livenessInterval: interval,
      livenessFailureThreshold: threshold,
      relaunchPolicy: PieEngineHost.RelaunchPolicy(maxAttempts: 2, window: 60, backoffSchedule: [1.0, 2.0]),
      relauncher: relauncher
    )
    box.host = host

    let transitions = Locked<[String]>([])
    let token = host.observe { status, _ in
      let rendered = String(describing: status)
      transitions.withLock { $0.append(rendered) }
      print("chat-engine-harness: lifecycle status=\(rendered)")
    }
    defer { token.cancel() }

    print("chat-engine-harness: lifecycle mode=\(mode) duration=\(duration)s interval=\(interval)s threshold=\(threshold)")
    try host.start(spec).get()
    let port = try await waitForRunningPort(host: host, timeout: 120)
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    print("chat-engine-harness: lifecycle engine running port=\(port) pids=\(pids.withLock { $0.map(String.init).joined(separator: ",") })")
    try await loadModel(loadTarget, baseURL: baseURL)

    switch mode {
    case "idle":
      print("chat-engine-harness: lifecycle idle soak begin (no chat/ToT content)")
      try await sleepSeconds(duration)
      let final = host.status
      print("chat-engine-harness: lifecycle idle soak end status=\(final) pids=\(pids.withLock { $0.map(String.init).joined(separator: ",") }) transitions=\(transitions.withLock { $0.count })")
      await stopLifecycleHost(host)
      if case .running = final { return true }
      return false
    case "tot":
      let question = env["PIE_TEST_TOT_QUESTION"].flatMap { $0.isEmpty ? nil : $0 } ?? "Diagnose a software lifecycle issue."
      print("chat-engine-harness: lifecycle active ToT soak begin (question_chars=\(question.count))")
      let ok = try await runTreeOfThought(question: question, baseURL: baseURL, env: env)
      let final = host.status
      print("chat-engine-harness: lifecycle active ToT soak end status=\(final) terminal=\(ok) pids=\(pids.withLock { $0.map(String.init).joined(separator: ",") }) transitions=\(transitions.withLock { $0.count })")
      await stopLifecycleHost(host)
      return ok
    default:
      print("chat-engine-harness: unknown PIE_TEST_LIFECYCLE_SOAK=\(mode); expected idle|tot")
      await stopLifecycleHost(host)
      return false
    }
  }

  /// Drive a real ToT search through the App's Swift path and report
  /// per-event timing + the terminal. Returns true iff a `tree_complete`
  /// arrived (the live tree would reach a final answer in the UI).
  private static func runTreeOfThought(
    question: String, baseURL: URL, env: [String: String], depthOverride: Int? = nil
  ) async throws -> Bool {
    let breadth = intEnv("PIE_TEST_TOT_BREADTH", 3, env: env)
    let depth = depthOverride ?? intEnv("PIE_TEST_TOT_DEPTH", 2, env: env)
    let beam = intEnv("PIE_TEST_TOT_BEAM", 2, env: env)
    let maxTok = intEnv("PIE_TEST_TOT_MAXTOK", 256, env: env)
    let input: [String: Any] = [
      "messages": [["role": "user", "content": question]],
      "breadth": breadth, "depth": depth, "beam_width": beam,
      "max_tokens_per_node": maxTok, "temperature": 0.7, "top_p": 0.9,
    ]
    let inputData = try JSONSerialization.data(withJSONObject: input)
    let req = InferletRequest(inferlet: "tree-of-thought", input: inputData, messages: nil, stream: true)
    let client = HTTPEngineClient(baseURL: baseURL)

    print("chat-engine-harness: ToT drive b\(breadth)/d\(depth)/beam\(beam)/max\(maxTok) question_chars=\(question.count)")
    var tree = ToTTree()
    let t0 = Date()
    var sawTerminal = false
    var nodeStarts = 0
    var reasoningDeltas = 0
    var answerDeltas = 0
    for try await event in toTEventStream(from: client.dispatchInferlet(req)) {
      tree.apply(event)
      let dt = Date().timeIntervalSince(t0)
      switch event {
      case let .treeStart(id, model, b, d, w):
        print(String(format: "  +%6.1fs tree_start id=\(id) model=\(model) b\(b)/d\(d)/beam\(w)", dt))
      case let .nodeStart(id, _, depth, _):
        nodeStarts += 1
        print(String(format: "  +%6.1fs node_start \(id) depth=\(depth)", dt))
      case let .nodeDelta(_, channel, _):
        // Token-level chunks (#413 phase B) — count, don't spam per-chunk.
        switch channel {
        case .reasoning: reasoningDeltas += 1
        case .answer: answerDeltas += 1
        }
      case .finalDelta:
        // #523 Part A: synthesized final-answer chunks — folded into the
        // tree's finalAnswer by `tree.apply`; nothing extra to print here.
        break
      case let .nodeComplete(node):
        print(String(format: "  +%6.1fs node_complete depth=\(node.depth) status=\(node.status) score=\(node.score.map(String.init) ?? "nil") answer_len=\(node.content.count) reasoning_len=\(node.reasoning.count)", dt))
      case let .levelPruned(level, kept):
        print(String(format: "  +%6.1fs level_pruned level=\(level) kept=\(kept)", dt))
      case let .treeComplete(sel, ans):
        sawTerminal = true
        print(String(format: "  +%6.1fs tree_complete selected=\(sel ?? "nil") answer_len=\(ans?.count ?? 0)", dt))
      case let .generationMetrics(metrics):
        print(String(format: "  +%6.1fs generation_metrics total_tokens=%d tok_s=%.1f",
                     dt, metrics.outputTokens, metrics.tokensPerSecond))
      }
    }
    let total = Date().timeIntervalSince(t0)
    print("chat-engine-harness: token stream — node_starts=\(nodeStarts) reasoningDeltas=\(reasoningDeltas) answerDeltas=\(answerDeltas)")

    // Per-node reasoning-aware accounting (#413/#434/#437).
    func answered(_ n: ToTTree.Node) -> Bool {
      !n.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let okNodes = tree.nodes.filter { $0.status == .ok }
    let incompleteNodes = tree.nodes.filter { $0.status == .incomplete }
    let withReasoning = tree.nodes.filter { !$0.reasoning.isEmpty }
    let bothReasoningAndAnswer = okNodes.filter { !$0.reasoning.isEmpty && answered($0) }
    // The demux contract: a node's ANSWER (content) must never carry the raw
    // <think> delimiters — those belong to the reasoning channel (#437).
    let tagSoup = tree.nodes.filter {
      $0.content.contains("<think>") || $0.content.contains("</think>")
    }
    let expectReasoning = (env["PIE_TEST_TOT_EXPECT_REASONING"] ?? "1") == "1"

    print(String(format: "chat-engine-harness: ToT stream ended after %.1fs; status=\(tree.status); nodes=\(tree.nodes.count) (ok=\(okNodes.count) incomplete=\(incompleteNodes.count)); withReasoning=\(withReasoning.count); terminal=\(sawTerminal)", total))
    if let sel = tree.selectedNode {
      print("chat-engine-harness: selected=\(sel.id) score=\(sel.score.map(String.init) ?? "nil") reasoningChars=\(sel.reasoning.count) answerChars=\(sel.content.count)")
    }

    // Failure modes must be handled honestly, not as a hang or tag-soup.
    var failures: [String] = []
    if !(tree.status == .complete && sawTerminal && tree.selectedNode != nil) {
      failures.append("no tree_complete / no selected answer (status=\(tree.status))")
    }
    if !tagSoup.isEmpty {
      failures.append("\(tagSoup.count) node(s) leak <think> tags into the ANSWER channel (demux broken)")
    }
    if let sel = tree.selectedNode, !answered(sel) {
      failures.append("selected node has no usable answer")
    }
    // #413 phase B: text must stream INCREMENTALLY, not only at node_complete.
    if nodeStarts == 0 {
      failures.append("no node_start frames — token streaming not emitting")
    }
    if answerDeltas == 0 {
      failures.append("no answer node_delta chunks — answers not streaming incrementally")
    }
    if expectReasoning {
      if reasoningDeltas == 0 {
        failures.append("no reasoning node_delta chunks — reasoning not streaming incrementally")
      }
      // Thinking is on: the demux must yield nodes that carry BOTH a
      // reasoning trace AND a clean answer — that is the whole point.
      if bothReasoningAndAnswer.isEmpty {
        failures.append("no ok node carried BOTH reasoning AND an answer (reasoning demux not working)")
      }
      if let sel = tree.selectedNode, sel.reasoning.isEmpty {
        failures.append("selected node carries no reasoning (expected thinking on)")
      }
      // #649 follow-up: prove the invariant DEPTH-PARAMETRICALLY — every
      // depth>1 level (the intermediate depth>1 levels AND the final level)
      // must carry reasoning, not only the selected final node. The depth=2
      // run pins the final level; the deeper run additionally pins a true
      // intermediate depth>1 level (e.g. level 2 when depth=3). A level with
      // ok nodes but no reasoning on any of them means that level fell back to
      // the old final-depth /no_think behavior.
      if depth >= 2 {
        for level in 2...depth {
          let okAtLevel = okNodes.filter { $0.depth == level }
          if !okAtLevel.isEmpty, !okAtLevel.contains(where: { !$0.reasoning.isEmpty }) {
            failures.append(
              "no ok node at depth \(level) carries reasoning — that level is not reasoning under thinking:true")
          }
        }
      }
    }

    if failures.isEmpty {
      print("chat-engine-harness: ToT PASS — tree_complete; each node demuxed into reasoning + a clean answer; \(incompleteNodes.count) incomplete node(s) surfaced honestly")
      return true
    }
    for f in failures { print("chat-engine-harness: ToT FAIL — \(f)") }
    return false
  }

  private static func loadModel(_ model: String, baseURL: URL) async throws {
    // #469: v1 pie binds the served model at `pie serve` boot, so there is no
    // `/v1/models/load` to drive — confirm the engine advertises the boot
    // model on `GET /v1/models` (the only id its chat endpoint accepts).
    let client = HTTPEngineClient(baseURL: baseURL, unaryTimeout: 15)
    try await withTimeout(seconds: 120, label: "models(\(model))") {
      let served = try await client.models().map(\.id)
      if !served.contains(model) {
        throw HarnessError.modelLoadEndedWithoutReady(model)
      }
    }
    print("chat-engine-harness: serving \(model)")
  }

  private static func waitForSIGTERM() async {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    await withCheckedContinuation { continuation in
      source.setEventHandler {
        source.cancel()
        continuation.resume()
      }
      source.resume()
    }
  }

  private static func withTimeout(
    seconds: TimeInterval,
    label: String,
    body: @Sendable @escaping () async throws -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw HarnessError.timeout(label)
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private static func waitForRunningPort(host: PieEngineHost, timeout: TimeInterval) async throws -> UInt16 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      switch host.status {
      case .running(let snap):
        return UInt16(snap.port)
      case .failed(let code, let message):
        throw HarnessError.engineFailed("\(code.rawValue): \(message)")
      default:
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    throw HarnessError.timeout("waitForRunningPort(\(timeout)s), last=\(host.status)")
  }

  private static func sleepSeconds(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  private static func stopLifecycleHost(_ host: PieEngineHost) async {
    host.stop(reason: "harness.lifecycle.complete")
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if case .stopped = host.status { break }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private static func intEnv(_ key: String, _ fallback: Int, env: [String: String]) -> Int {
    env[key].flatMap { Int($0) } ?? fallback
  }

  /// The depths to drive (#649 follow-up). `PIE_TEST_TOT_DEPTHS` is a comma
  /// list of positive ints; invalid/empty entries are dropped. Falls back to
  /// the single `PIE_TEST_TOT_DEPTH` run so existing callers are unchanged.
  private static func parsedDepths(env: [String: String]) -> [Int] {
    if let raw = env["PIE_TEST_TOT_DEPTHS"], !raw.isEmpty {
      let parsed = raw.split(separator: ",").compactMap {
        Int($0.trimmingCharacters(in: .whitespaces))
      }.filter { $0 >= 1 }
      if !parsed.isEmpty { return parsed }
    }
    return [intEnv("PIE_TEST_TOT_DEPTH", 2, env: env)]
  }

  private static func doubleEnv(_ key: String, _ fallback: TimeInterval, env: [String: String]) -> TimeInterval {
    env[key].flatMap { TimeInterval($0) } ?? fallback
  }
}

private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withLock<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

private enum HarnessError: Error, CustomStringConvertible {
  case timeout(String)
  case modelLoadEndedWithoutReady(String)
  case engineFailed(String)

  var description: String {
    switch self {
    case .timeout(let label):
      return "\(label) timed out"
    case .modelLoadEndedWithoutReady(let model):
      return "loadModel(\(model)) ended without .ready"
    case .engineFailed(let message):
      return "engine failed: \(message)"
    }
  }
}
