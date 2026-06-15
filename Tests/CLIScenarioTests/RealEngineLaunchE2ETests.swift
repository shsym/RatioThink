import XCTest
import Foundation
import Darwin
import os
@testable import RatioThinkCore

/// REAL end-to-end Helper-hosted engine launch ( follow-up).
///
/// Every other tier skips the actual engine spawn:
///   · StartEngineXPCIntegrationTests injects a synthetic launcher.
///   · The  full-e2e boots `pie` in the harness and points the GUI
///     at it via `PIE_TEST_ENGINE_BASE_URL` (bypass).
///
/// This drives the PRODUCTION path with NO mock: a real
/// `LaunchSpecResolver` reading a staged profile → `PieEngineHost()`
/// with the default launcher (`PieControlLauncher.launch`) → a real
/// `pie serve` subprocess loading a real GGUF → `EngineStatus.running`,
/// then an HTTP chat round-trip against the engine the Helper would
/// spawn. Closes the gap that hid the  model-load hang (engine
/// never started; nothing exercised the spawn).
///
/// Gated on a staged model + bundled binary so CI without them skips.
/// Driven by `Scripts/run-engine-e2e.sh`, which stages the
/// GGUF and exports:
///   · PIE_TEST_REAL_PIE_BIN          — the bundled `pie` engine binary
///   · PIE_TEST_REAL_MODEL_PATH       — a real .gguf on disk
///   · PIE_TEST_REAL_CHATAPC_WASM     — chat-apc.wasm
///   · PIE_TEST_REAL_CHATAPC_MANIFEST — chat-apc Pie.toml
///
/// Isolation: subclasses `IsolatedTestCase` (not bare `XCTestCase`) so the
/// real `pie serve` it spawns is registered via `trackSubprocess(_:)` and
/// SIGKILL-reaped by the base's post-test reap loop even if the body throws
/// or `host.stop()` (async, fire-and-forget) hasn't finished — the same
/// safety net S0/S3 rely on. A hung engine no longer leaks into the next
/// test or the developer's machine.
final class RealEngineLaunchE2ETests: IsolatedTestCase {
  /// Short `/tmp`-anchored pieHome so the engine's aux Unix socket path
  /// stays under the 104-char `sun_path` limit (see resolver wiring).
  /// Deliberately NOT the base `tempPieHome` (which lives under the deep
  /// `NSTemporaryDirectory()` /var/folders root): only the engine's
  /// PIE_HOME carries the length-bounded socket, so the models/profiles
  /// scratch stays under `tempPieHome` while the engine gets this.
  private var shortPieHome: URL!

  override func setUpWithError() throws {
    // super first: IsolatedTestCase.invokeTest already allocated
    // `tempPieHome` and bound `PieDirs.homeOverride` to it; super's setUp
    // precondition verifies that binding. Only the short engine pieHome
    // is ours to create.
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    // When driven by Scripts/run-engine-e2e.sh, anchor under the wrapper's
    // per-run id (`/tmp/pe2e-<runID>-<uuid>`) so its EXIT sweep can scope
    // its `rm` to THIS run's pieHomes and never delete a concurrent run's
    // (or a still-live bundle's) live engine home. Plain `swift test` (no
    // PE2E_RUN_ID) keeps the flat `/tmp/pe2e-<uuid>` form. The run id is
    // the wrapper's PID — digits only, so it stays sun_path-short and
    // regex-safe for the wrapper's scoped pkill.
    let runID = ProcessInfo.processInfo.environment["PE2E_RUN_ID"]
      .flatMap { $0.isEmpty ? nil : $0 }
    let leaf = runID.map { "pe2e-\($0)-\(uuid)" } ?? "pe2e-\(uuid)"
    shortPieHome = URL(fileURLWithPath: "/tmp/\(leaf)", isDirectory: true)
    try FileManager.default.createDirectory(at: shortPieHome, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    // Best-effort: races the async `host.stop()` shutdown, but POSIX
    // unlink succeeds even while the engine still holds fds, and the
    // wrapper's EXIT sweep (Scripts/run-engine-e2e.sh) is the
    // deterministic outer net for an externally-killed bundle. The
    // base's verified `cleanupTempPieHome()` (runs post-reap in
    // invokeTest) owns `tempPieHome`.
    if let shortPieHome { try? FileManager.default.removeItem(at: shortPieHome) }
    shortPieHome = nil
    try super.tearDownWithError()
  }

  func test_realEngine_startsServesAndStops() async throws {
    let env = try realEngineEnvOrSkip()
    let host = PieEngineHost()
    defer { host.stop() }
    let (port, slug) = try await launchRealEngine(env, host: host)

    // Engine is genuinely serving: HTTP chat round-trip. The served id
    // must be the profile slug (id-unification,  follow-up) — assert
    // /v1/models advertises it, then chat against that exact id.
    try await assertServedModelID(port: port, expected: slug)
    try await assertChatCompletion(port: port, modelID: slug)
  }

  /// #469 — App↔Helper active-model sync, end-to-end against a REAL engine.
  /// Proves BOTH ticket symptoms are fixed on a profile that has NO default
  /// model (so the only boot model can come from the pick / the durable
  /// marker, never a profile default):
  ///   (a) "App selects model X → the helper-started engine actually SERVES
  ///       X": an explicit pick (the `startEngine(modelOverride:)` /
  ///       switch-from-idle path) boots the engine on X, and the resolver
  ///       records X in the durable active-model marker.
  ///   (b) "engine start drops pending pick (wrong model)" is FIXED: a real
  ///       `HelperResumeAction` run (menu-bar Resume / crash auto-relaunch),
  ///       with only the marker to go on, boots the engine cleanly on X.
  func test_realEngine_servesExplicitPick_andResumeHonorsMarker() async throws {
    let e = try realEngineEnvOrSkip()
    let (store, resolver, slug) = try stageNoDefaultProfile(e)
    defer { store.stop() }

    // (a) Switch-from-idle: resolve with the explicit override (the profile
    // has no default) and launch — the engine must serve the picked model.
    let host1 = PieEngineHost()
    var spec1: PieControlLauncher.LaunchSpec
    switch resolver.asClosure("chat", slug) {
    case .success(let s): spec1 = s
    case .failure(let err):
      XCTFail("explicit pick must resolve a no-default profile: \(err.code.rawValue): \(err.message)")
      throw XCTSkip("resolver failure")
    }
    reapEngineSubprocess(in: &spec1)
    if case .failure(let err) = host1.start(spec1) {
      XCTFail("engineHost.start rejected: \(err.code.rawValue): \(err.message)")
      throw XCTSkip("host start failure")
    }
    let port1 = try await awaitRunning(host: host1, timeout: 120)
    try await assertServedModelID(port: port1, expected: slug)
    try await assertChatCompletion(port: port1, modelID: slug)
    XCTAssertEqual(store.activeModelID, slug,
                   "the launch must record the picked model in the durable active-model marker")
    host1.stop()
    await awaitStopped(host: host1, timeout: 30)

    // (b) Menu-bar Resume: the profile STILL has no default, so the only way
    // the engine can boot the pick is by honoring the marker. Drive the real
    // HelperResumeAction with a reaping resolver wrapper so the relaunched
    // engine's pid is tracked by the IsolatedTestCase reap net.
    let host2 = PieEngineHost()
    defer { host2.stop() }
    let reapingResolver: HelperExportedAPI.LaunchSpecResolver = { id, model in
      switch resolver.asClosure(id, model) {
      case .success(var spec): self.reapEngineSubprocess(in: &spec); return .success(spec)
      case .failure(let err):  return .failure(err)
      }
    }
    let outcome = HelperResumeAction.run(
      engineHost: host2, profileStore: store, resolver: reapingResolver)
    XCTAssertEqual(outcome, .started(profileID: "chat"),
                   "Resume must boot the marker model even with no profile default; got \(outcome)")
    let port2 = try await awaitRunning(host: host2, timeout: 120)
    try await assertServedModelID(port: port2, expected: slug)
    try await assertChatCompletion(port: port2, modelID: slug)
  }

  /// Real-model proof for the reasoning-channel split: a thinking model
  /// (Qwen3) must keep raw `<think>`/`</think>` delimiters OFF the
  /// visible-content channel and surface the scratchpad on
  /// `reasoning_content` instead. Gated behind
  /// `PIE_TEST_REAL_EXPECT_REASONING=1` so the model-agnostic suite
  /// (Qwen2.5 etc.) doesn't run it — a non-thinking model has no
  /// reasoning to assert on. Drive with:
  ///   PIE_TEST_REAL_EXPECT_REASONING=1 \
  ///   PIE_TEST_E2E_REPO=Qwen/Qwen3-0.6B-GGUF \
  ///   PIE_TEST_E2E_FILE=Qwen3-0.6B-Q8_0.gguf  Scripts/run-engine-e2e.sh
  func test_realEngine_keepsThinkDelimitersOffContentChannel() async throws {
    let env = try realEngineEnvOrSkip()
    guard ProcessInfo.processInfo.environment["PIE_TEST_REAL_EXPECT_REASONING"] == "1" else {
      throw XCTSkip("set PIE_TEST_REAL_EXPECT_REASONING=1 with a thinking model (e.g. Qwen3) to run")
    }
    let host = PieEngineHost()
    defer { host.stop() }
    let (port, slug) = try await launchRealEngine(env, host: host)
    try await assertReasoningSeparatedFromContent(port: port, modelID: slug)
  }

  /// One cell of the (model × profile) real-engine compatibility matrix
  /// (#473). Routing is per-REQUEST, not per-launch-profile (chat →
  /// /v1/chat/completions, tree-of-thought → /v1/inferlet, fast-think →
  /// chat-completions + a `speculation` field, ceiling → the #475
  /// token-ceiling contract over /v1/models + a boundary pair), so a single
  /// booted model proves every profile shape against it: this boots ONCE and
  /// fires each profile in `PIE_TEST_E2E_PROFILES` as a sub-assertion. The
  /// `ceiling` profile is the memory-size half of the matrix — the engine's
  /// effective `max_output_tokens` (and its clean over-ceiling 400) is
  /// memory-aware, so it is proven once per loaded model. That keeps the
  /// matrix at 9 boots / 36 cells instead of 36 cold boots — decisive for
  /// the slow ~9 GB 14B loads.
  ///
  /// Gated on `PIE_TEST_E2E_PROFILES` (a csv of `chat,tree-of-thought,
  /// fast-think`) so the default `Scripts/run-engine-e2e.sh` path — which
  /// sets only `PIE_TEST_REAL_*` — skips it; `Scripts/run-matrix-e2e.sh`
  /// sets the profile list + the per-cell model coordinate and is the sole
  /// driver. `PIE_TEST_REAL_EXPECT_REASONING=1` (set by the wrapper for the
  /// Qwen3 thinking models) adds the reasoning-channel sub-checks.
  func test_realEngine_profileMatrixCell() async throws {
    let env = try realEngineEnvOrSkip()
    let raw = ProcessInfo.processInfo.environment["PIE_TEST_E2E_PROFILES"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else {
      throw XCTSkip("set PIE_TEST_E2E_PROFILES (csv of chat,tree-of-thought,fast-think) — driven by Scripts/run-matrix-e2e.sh")
    }
    let profiles = raw.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let expectReasoning = ProcessInfo.processInfo.environment["PIE_TEST_REAL_EXPECT_REASONING"] == "1"
    // Capability gate for the weak semantic floor (#484). The wrapper sets
    // this only for the larger tier (params > 1B); the small 0.5–1B models
    // stay contract-level so a missed `pong` echo — a capability limit, not
    // an engine-compat failure — does not false-FAIL the matrix.
    let expectSemantic = ProcessInfo.processInfo.environment["PIE_TEST_REAL_EXPECT_SEMANTIC"] == "1"

    let host = PieEngineHost()
    defer { host.stop() }
    let (port, slug) = try await launchRealEngine(env, host: host)
    // The engine must serve exactly the profile slug as its model id
    // (id-unification) before any request can match it.
    try await assertServedModelID(port: port, expected: slug)

    // Run each profile independently: a throwing failure in one cell must
    // not abort the others (we want the whole row's verdict, not "stop at
    // the first red"). Each cell emits a machine-parseable
    // `MATRIX-CELL <model> <profile> PASS|FAIL` line that
    // Scripts/run-matrix-e2e.sh aggregates into the matrix table; if the
    // engine never booted, the method threw above and NO lines print for
    // this model — the wrapper reads that absence as a load failure.
    let model = env.modelPath.lastPathComponent
    var failures: [String] = []
    for profile in profiles {
      do {
        switch profile {
        case "chat":
          try await assertChatCell(port: port, modelID: slug,
                                   expectReasoning: expectReasoning,
                                   expectSemantic: expectSemantic)
        case "tree-of-thought":
          try await assertTreeOfThoughtCell(port: port, modelID: slug)
        case "fast-think":
          try await assertFastThinkCell(port: port, modelID: slug, expectReasoning: expectReasoning)
        case "ceiling":
          try await assertTokenCeilingCell(port: port, modelID: slug)
        default:
          throw MatrixCellFailure("unknown profile (expected chat|tree-of-thought|fast-think|ceiling)")
        }
        print("MATRIX-CELL\t\(model)\t\(profile)\tPASS")
      } catch {
        failures.append("\(profile): \(error)")
        // Single-line, tab-delimited so the wrapper can grep it; the
        // reason rides the 4th column with internal tabs stripped.
        let reason = "\(error)".replacingOccurrences(of: "\t", with: " ")
        print("MATRIX-CELL\t\(model)\t\(profile)\tFAIL\t\(reason)")
      }
    }
    if !failures.isEmpty {
      XCTFail("\(model): \(failures.count) profile cell(s) failed — \(failures.joined(separator: " | "))")
    }
  }

  // MARK: - memory-budget sweep (#475)

  /// Which configured budget knob a sweep cell turns.
  private enum BudgetKnob {
    /// App-side (#328/#438): inject a guardrail `Policy` whose RAM ceiling
    /// is `bytes`, so the REAL `LaunchSpecResolver` → `KVCacheBudget` derives
    /// `default_token_limit` from it — the exact production app-config path.
    /// Lower `bytes` → lower derived ceiling. Never causes a load failure on
    /// its own: it floors at `KVCacheBudget.minCeilingTokens` (512).
    case guardrailBytes(Int64)
    /// Engine-side: override `[model.driver.options].max_num_kv_pages`, the
    /// raw KV page pool (= pages × 32 tokens). Caps N directly; when set far
    /// too small for the model it makes `pie serve` fail to load — a
    /// captured, classified engine-start error, not a hang.
    case kvPages(Int)
  }

  /// One cell of the memory-budget sweep.
  private struct BudgetCell {
    let name: String
    let knob: BudgetKnob
    /// `true` when the budget is deliberately small enough that the model is
    /// not expected to boot — a structured `.failed` is then the PASS
    /// outcome, and an actual boot is the regression.
    let expectStructuredLoadFailure: Bool
  }

  /// The budget ladder, ordered large → small, exercising BOTH fault domains.
  /// Guardrail thresholds derive from the model's own weight size + the same
  /// overhead `KVCacheBudget` reserves, so the cells move N for any model.
  /// Calibrated against a measured real boot (#475 spike, Qwen2.5-0.5B):
  ///   · large           — guardrail RAM ceiling far above the model → no
  ///                       clamp; N at the engine default pool cap (32768).
  ///                       The baseline every other cell is compared against.
  ///   · near-boundary   — guardrail with a few hundred MiB of KV headroom →
  ///                       mid N (measured ≈21845). App-side knob, mid.
  ///   · harsh-guardrail — guardrail with ~0 KV headroom → N floored to 512;
  ///                       STILL BOOTS. Proves the #328/#438 guardrail caps
  ///                       the *advertised* ceiling, not the physical pool —
  ///                       it cannot, by itself, trip a load failure.
  ///   · kv-pages-low    — engine KV pool shrunk to 256 pages → N = 256×32 =
  ///                       8192 (measured). The OTHER fault domain (engine,
  ///                       not app) lowering N on a real boot.
  ///   · harsh-kv-pages  — 2-page pool: far below the model's minimum → a
  ///                       structured engine-start failure (`spawnFailed`,
  ///                       exit code + stderr tail), captured as a cell — the
  ///                       memory-bound failure the ticket demands be classified.
  private static func budgetSweepCells(weightBytes: Int64) -> [BudgetCell] {
    let overhead = max(KVCacheBudget.overheadFloorBytes,
                       Int64(Double(weightBytes) * KVCacheBudget.overheadFraction))
    // `base` = the threshold at which KV headroom is exactly zero, so
    // `base + small` floors N at 512 while `base + 256 MiB` leaves mid headroom.
    let base = weightBytes + overhead
    let mib: Int64 = 1024 * 1024
    return [
      BudgetCell(name: "large",
                 knob: .guardrailBytes(base + 64 * 1024 * mib),       // +64 GiB → no clamp
                 expectStructuredLoadFailure: false),
      BudgetCell(name: "near-boundary",
                 knob: .guardrailBytes(base + 256 * mib),             // mid headroom
                 expectStructuredLoadFailure: false),
      BudgetCell(name: "harsh-guardrail",
                 knob: .guardrailBytes(base + 1),                     // ~0 headroom → floor 512
                 expectStructuredLoadFailure: false),
      BudgetCell(name: "kv-pages-low",
                 knob: .kvPages(256),                                 // 256×32 = 8192 KV tokens
                 expectStructuredLoadFailure: false),
      BudgetCell(name: "harsh-kv-pages",
                 knob: .kvPages(2),                                   // 2×32 = 64 KV tokens → too small
                 expectStructuredLoadFailure: true),
    ]
  }

  /// REAL-engine memory-budget sweep (#475): boot the SAME model across a
  /// ladder of CONFIGURED budgets and prove the effective ceiling N actually
  /// tracks the budget — and that every memory-bound failure surfaces as a
  /// captured, classified cell (a clean 400 token-ceiling rejection, a
  /// structured engine-start error, or a 200), never an opaque engine error
  /// or a hang.
  ///
  /// This is the memory-size half of the matrix the single `ceiling` cell
  /// could not be: it varies the budget through BOTH fault domains — the
  /// App guardrail (`KVCacheBudget` → `default_token_limit`, the #328/#438
  /// app-config path) and the pie KV pool (`max_num_kv_pages`) — and asserts
  /// N moves and the harsh-low cell trips a structured failure.
  ///
  /// Multi-boot (one `pie serve` per budget), so it is gated separately from
  /// the per-request profile matrix and scoped to a small model by its
  /// driver (`make test-e2e-budget-sweep` / `PIE_TEST_E2E_BUDGET_SWEEP=1`).
  func test_realEngine_memoryBudgetSweep() async throws {
    let env = try realEngineEnvOrSkip()
    guard ProcessInfo.processInfo.environment["PIE_TEST_E2E_BUDGET_SWEEP"] == "1" else {
      throw XCTSkip("set PIE_TEST_E2E_BUDGET_SWEEP=1 — driven by `make test-e2e-budget-sweep` (small model; one boot per budget)")
    }
    let model = env.modelPath.lastPathComponent
    let weightBytes = try cellUnwrap(
      ModelMemoryGuardrail.resolvedBytes(resolvedModelURL: env.modelPath),
      "budget-sweep: could not read resolved weight size of \(env.modelPath.path)")
    let cells = Self.budgetSweepCells(weightBytes: weightBytes)

    struct Booted { let name: String; let n: Int; let isGuardrail: Bool; let kvPages: Int? }
    var booted: [Booted] = []
    var structuredFailures: [String] = []
    var hardFailures: [String] = []
    var baselineLargeN: Int?

    for (idx, cell) in cells.enumerated() {
      let host = PieEngineHost()
      let outcome = await launchForBudget(env, host: host, cell: cell, index: idx)
      let isGuardrail: Bool
      let kvPages: Int?
      switch cell.knob {
      case .guardrailBytes: isGuardrail = true;  kvPages = nil
      case let .kvPages(p):  isGuardrail = false; kvPages = p
      }
      switch outcome {
      case .running(let port, let slug):
        do {
          let n = try await readAdvertisedCeiling(port: port, modelID: slug, label: cell.name)
          // The structured token-ceiling contract must STILL hold at this
          // budget: an over-ceiling request is a clean 400, never the raw
          // engine error — at every memory budget, not just the default.
          try await assertOverCeilingRejected(port: port, modelID: slug, ceiling: n, label: cell.name)
          print("BUDGET-CELL\t\(model)\t\(cell.name)\trunning\tN=\(n)")
          if cell.name == "large" { baselineLargeN = n }
          // Exact-wire proof for the engine KV knob: a booted `max_num_kv_pages`
          // cell must report N == min(pages × 32, the default-pool/context cap).
          // This pins `LaunchSpec.maxNumKvPages → config.toml → driver →
          // runtime::max-output-tokens` end-to-end (measured 256 → 8192).
          if let p = kvPages {
            let cap = baselineLargeN ?? KVCacheBudget.defaultPoolCapacityTokens
            // pie's portable-driver default `kv_page_size` (PortableDriverOptions).
            let kvPageSizeTokens = 32
            let expected = min(p * kvPageSizeTokens, cap)
            if n != expected {
              hardFailures.append("\(cell.name): max_num_kv_pages=\(p) → expected N=\(expected) (min(\(p)×32, \(cap))), got \(n)")
            }
          }
          booted.append(Booted(name: cell.name, n: n, isGuardrail: isGuardrail, kvPages: kvPages))
          if cell.expectStructuredLoadFailure {
            hardFailures.append("\(cell.name): expected a structured load failure but the engine booted (N=\(n))")
          }
        } catch {
          hardFailures.append("\(cell.name): booted but the ceiling contract failed — \(error)")
        }
      case .failed(let code, let message):
        print("BUDGET-CELL\t\(model)\t\(cell.name)\tstructured-fail\tcode=\(code)\tmsg=\(message.prefix(160).debugDescription)")
        if cell.expectStructuredLoadFailure {
          // The PASS outcome for a deliberately-too-small budget: a captured,
          // classified ENGINE-start error. cellRequireStructured rejects an
          // empty/opaque classification AND the `harness_error` sentinel (a
          // setup failure, NOT the engine classifying the over-small pool).
          structuredFailures.append(cell.name)
          try cellRequireStructured(code: code, message: message, label: cell.name, into: &hardFailures)
        } else {
          // A cell that was supposed to BOOT regressed into a load failure —
          // the silent regression #475 must never let green. Mirror the
          // `.running`-branch guard (a supposed-to-fail cell that boots is a
          // hard failure): this is its symmetric twin, not a captured cell.
          hardFailures.append("\(cell.name): expected to boot but the engine failed to load — code=\(code) msg=\(message.prefix(160))")
        }
      case .timedOut:
        // A hang is exactly the failure mode the ticket forbids: not a
        // captured cell. Fail hard and name it.
        hardFailures.append("\(cell.name): engine neither booted nor reported a structured failure within the budget (HANG)")
      }
      host.stop()
      // Let the prior engine's aux socket / shmem fully release before the
      // next boot reuses a short /tmp pieHome.
      try await Task.sleep(nanoseconds: 750_000_000)
    }

    // 1. N must actually MOVE with the budget — the whole point of the sweep.
    //    Both fault domains must demonstrably lower N below the large-budget
    //    baseline: a guardrail (#328/#438 app config) cell AND a KV-pages
    //    (engine) cell. (The engine domain is also exercised by the harsh
    //    structured-failure cell below.)
    if let large = baselineLargeN {
      let guardrailLowered = booted.contains { $0.isGuardrail && $0.name != "large" && $0.n < large }
      let kvLowered = booted.contains { $0.kvPages != nil && $0.n < large }
      if !guardrailLowered {
        hardFailures.append("the App guardrail knob did not lower N below the baseline \(large) (booted=\(booted.map { "\($0.name):\($0.n)" }))")
      }
      if !kvLowered {
        hardFailures.append("the pie KV-pages knob did not lower N below the baseline \(large) on a boot (booted=\(booted.map { "\($0.name):\($0.n)" }))")
      }
    } else {
      hardFailures.append("the large budget did not boot — cannot establish an N baseline (booted=\(booted.map { "\($0.name):\($0.n)" }))")
    }

    // 2. The deliberately-too-small budget MUST have produced a STRUCTURED
    //    failure (captured), proving a memory-bound load failure is a
    //    classified cell rather than an opaque error or a hang. This is a HARD
    //    requirement — a boot there is already flagged above; a hang is flagged
    //    in the loop; only a captured structured failure clears it.
    let expectedFailCells = Set(cells.filter { $0.expectStructuredLoadFailure }.map { $0.name })
    let missingStructured = expectedFailCells.subtracting(structuredFailures)
    if !missingStructured.isEmpty {
      hardFailures.append("no captured structured failure for the too-small budget(s): \(missingStructured.sorted().joined(separator: ","))")
    }

    print("BUDGET-SUMMARY\t\(model)\tbooted=\(booted.map { "\($0.name):\($0.n)" }.joined(separator: ","))\tstructured_fail=\(structuredFailures.joined(separator: ","))")

    if !hardFailures.isEmpty {
      XCTFail("\(model): memory-budget sweep — \(hardFailures.count) failure(s): \(hardFailures.joined(separator: " | "))")
    }
  }

  /// A structured engine-start failure must carry a non-empty classification
  /// (a code + message), not an empty/opaque sentinel — that is what makes a
  /// memory-bound load failure a *captured* cell. Records a hard failure when
  /// the failure is unclassified.
  private func cellRequireStructured(code: String, message: String, label: String,
                                     into hardFailures: inout [String]) throws {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    // A harness setup failure (model staging, dir/profile creation) is mapped
    // to `.failed(code: "harness_error", …)` by `launchForBudget`; it is NOT
    // the engine classifying an over-small KV pool — the one thing the
    // expect-fail cell must prove. Reject it so an infrastructure bug cannot
    // satisfy the captured-structured-failure requirement.
    if code == "harness_error" {
      hardFailures.append("\(label): structured failure was a harness error, not an engine classification — \(message.prefix(200))")
      return
    }
    if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || trimmed.isEmpty {
      hardFailures.append("\(label): engine failed without a structured code/message (opaque) — code=\(code.debugDescription) msg=\(message.debugDescription)")
    }
  }

  /// The terminal state of one budget boot: a real serving port, a structured
  /// engine-start failure (classified code + message), or a hang (neither).
  private enum BootOutcome {
    case running(port: Int, slug: String)
    case failed(code: String, message: String)
    case timedOut
  }

  /// Poll the host to a terminal state, RETURNING the outcome (unlike
  /// `awaitRunning`, which `XCTFail`s on `.failed`). The sweep must classify
  /// a `.failed` as a captured cell, so it needs the failure, not an assert.
  private func awaitOutcome(host: PieEngineHost, slug: String, timeout: TimeInterval) async -> BootOutcome {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      switch host.status {
      case .running(let snap):
        return .running(port: Int(snap.port), slug: slug)
      case .failed(let code, let message):
        return .failed(code: code.rawValue, message: message)
      default:
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    return .timedOut
  }

  /// Boot one budget cell on its own short `/tmp` pieHome through the REAL
  /// production launch path (`LaunchSpecResolver` → `PieEngineHost` →
  /// `PieControlLauncher.launch` → `pie serve`), applying the cell's knob:
  ///   · `.guardrailBytes` — inject a fixed guardrail `Policy` so the real
  ///     resolver/`KVCacheBudget` derives `default_token_limit` (app path).
  ///   · `.kvPages`        — set `spec.maxNumKvPages` (engine path).
  /// Returns the classified `BootOutcome`; never `XCTFail`s, so the caller
  /// owns the verdict.
  private func launchForBudget(_ e: RealEngineEnv, host: PieEngineHost,
                               cell: BudgetCell, index: Int) async -> BootOutcome {
    let fm = FileManager.default
    do {
      // Per-cell scratch under the base temp home; a per-cell SHORT /tmp
      // pieHome keeps the engine aux socket under the sun_path limit and
      // isolates each boot's config/shmem.
      let cellRoot = tempPieHome.appendingPathComponent("budget-\(index)", isDirectory: true)
      let modelsRoot = cellRoot.appendingPathComponent("models", isDirectory: true)
      try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
      let slug = e.modelPath.lastPathComponent
      let staged = modelsRoot.appendingPathComponent(slug, isDirectory: false)
      try? fm.removeItem(at: staged)
      do { try fm.linkItem(at: e.modelPath, to: staged) }
      catch { try fm.copyItem(at: e.modelPath, to: staged) }

      let profiles = cellRoot.appendingPathComponent("profiles", isDirectory: true)
      try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
      try """
      id = "chat"
      name = "Chat"
      model = "\(slug)"
      inferlet = "chat-apc"
      """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
      let store = ProfileStore(
        directory: profiles,
        activeProfileURL: cellRoot.appendingPathComponent("active-profile", isDirectory: false))
      try store.start()
      try store.setActiveProfileID("chat")
      defer { store.stop() }

      let uuid = UUID().uuidString.prefix(8).lowercased()
      let runID = ProcessInfo.processInfo.environment["PE2E_RUN_ID"].flatMap { $0.isEmpty ? nil : $0 }
      let leaf = runID.map { "pe2e-\($0)-b\(index)-\(uuid)" } ?? "pe2e-b\(index)-\(uuid)"
      let cellPieHome = URL(fileURLWithPath: "/tmp/\(leaf)", isDirectory: true)
      try fm.createDirectory(at: cellPieHome, withIntermediateDirectories: true)

      // App-side guardrail knob → injected memoryPolicy → KVCacheBudget.
      let policyOverride: (() -> ModelMemoryGuardrail.Policy)?
      if case let .guardrailBytes(bytes) = cell.knob {
        policyOverride = { ModelMemoryGuardrail.Policy(maxResolvedModelBytes: bytes) }
      } else {
        policyOverride = nil
      }

      let resolver = LaunchSpecResolver(
        profileStore: store,
        pieBinary: { e.pieBin },
        modelsRoot: { modelsRoot },
        pieControlResources: { (wasm: e.wasm, manifest: e.manifest) },
        pieHome: { cellPieHome },
        subprocessEnvironment: { SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment) },
        memoryPolicy: policyOverride ?? { ModelMemoryGuardrail.defaultPolicy })

      var spec: PieControlLauncher.LaunchSpec
      switch resolver.asClosure("chat", nil) {
      case .success(let s): spec = s
      case .failure(let err):
        // A resolver rejection IS a structured, captured engine-start error.
        return .failed(code: err.code.rawValue, message: err.message)
      }
      // Engine-side KV-pool knob.
      if case let .kvPages(pages) = cell.knob {
        spec.maxNumKvPages = pages
      }
      reapEngineSubprocess(in: &spec)

      if case .failure(let err) = host.start(spec) {
        return .failed(code: err.code.rawValue, message: err.message)
      }
      return await awaitOutcome(host: host, slug: slug, timeout: 120)
    } catch {
      return .failed(code: "harness_error", message: "\(error)")
    }
  }

  /// A real-engine matrix cell assertion failed. Thrown (not `XCTFail`) so
  /// the per-profile loop in `test_realEngine_profileMatrixCell` can catch
  /// it, record the verdict, and continue to the next profile rather than
  /// aborting the whole row at the first red cell.
  private struct MatrixCellFailure: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
  }

  /// Throwing analogue of `XCTAssert` for matrix cells — see
  /// `MatrixCellFailure`.
  private func cellRequire(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw MatrixCellFailure(message()) }
  }

  /// Throwing analogue of `XCTUnwrap` for matrix cells.
  private func cellUnwrap<T>(_ value: T?, _ message: @autoclosure () -> String) throws -> T {
    guard let value else { throw MatrixCellFailure(message()) }
    return value
  }

  /// Poll the host until it reports `.running`, failing fast on `.failed`.
  private func awaitRunning(host: PieEngineHost, timeout: TimeInterval) async throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      switch host.status {
      case .running(let snap):
        return Int(snap.port)
      case .failed(let code, let message):
        XCTFail("engine entered .failed(\(code.rawValue)): \(message)")
        return 0
      default:
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    XCTFail("engine did not reach .running within \(timeout)s (last status=\(host.status))")
    return 0
  }

  /// Assert `/v1/models` advertises exactly the profile slug as the
  /// served id. This is the wire-level proof of the id-unification fix:
  /// the engine no longer serves a hardcoded "default", so a client that
  /// sends the profile slug (as the App does on every path) matches.
  private func assertServedModelID(port: Int, expected: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "/v1/models HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    XCTAssertEqual(ids, [expected],
                   "engine must advertise the profile slug as its served id (not \"default\"); got \(ids)")
  }

  /// Hit the engine's OpenAI-compatible chat endpoint and assert a
  /// non-empty assistant reply — proves the model is loaded and serving,
  /// not just that the port is bound. `modelID` must be the served id
  /// (the profile slug) so the request matches chat-apc's registered
  /// model and does not 404 as `model_not_found`.
  private func assertChatCompletion(port: Int, modelID: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 90
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": 16,
      "stream": false,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "chat completion HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choices = json?["choices"] as? [[String: Any]]
    let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
    XCTAssertNotNil(content, "engine reply missing choices[0].message.content: \(String(data: data, encoding: .utf8) ?? "")")
    XCTAssertFalse((content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "engine returned an empty assistant message")
  }

  /// Drive a real thinking-model completion and assert the
  /// `<think>`/`</think>` delimiters never reach `message.content`, while
  /// the scratchpad arrives on `message.reasoning_content`. Non-streaming
  /// for a single deterministic JSON to inspect. A generous `max_tokens`
  /// gives Qwen3 room to finish its reasoning chain; even if it caps
  /// before the answer, the delimiter-free + reasoning-present invariant
  /// still holds (reasoning streams first).
  private func assertReasoningSeparatedFromContent(port: Int, modelID: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 180
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "messages": [["role": "user", "content": "What is 2 + 2? Think briefly, then answer."]],
      "max_tokens": 4096,
      "stream": false,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    let bodyText = String(data: data, encoding: .utf8) ?? ""
    XCTAssertEqual(http.statusCode, 200, "chat HTTP \(http.statusCode): \(bodyText)")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
    let content = (message?["content"] as? String) ?? ""
    let reasoning = (message?["reasoning_content"] as? String) ?? ""

    // Core acceptance: no raw delimiter in the visible answer.
    XCTAssertFalse(content.contains("</think>"), "raw </think> leaked into content: \(content.debugDescription)")
    XCTAssertFalse(content.contains("<think>"), "raw <think> leaked into content: \(content.debugDescription)")
    // Separation actually engaged: the thinking model routed its
    // scratchpad to the reasoning channel, not into content.
    XCTAssertFalse(reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "expected non-empty reasoning_content for a thinking model; body=\(bodyText.prefix(400))")
    XCTAssertFalse(reasoning.contains("</think>"),
                   "reasoning_content must hold clean scratchpad text, not the delimiter")
  }

  // MARK: - profile matrix cells (#473)

  /// POST a non-streaming chat body and return the decoded JSON object,
  /// asserting HTTP 200 first. Shared by the chat and fast-think cells —
  /// both inspect the single non-streaming JSON (so `finish_reason` /
  /// `spec_metrics` are read directly rather than reassembled from SSE).
  private func postChatJSON(port: Int, body: [String: Any]) async throws -> [String: Any] {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 180
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try cellUnwrap(response as? HTTPURLResponse, "no HTTP response")
    let text = String(data: data, encoding: .utf8) ?? ""
    try cellRequire(http.statusCode == 200, "chat HTTP \(http.statusCode): \(text.prefix(400))")
    return try cellUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                          "chat response not a JSON object: \(text.prefix(400))")
  }

  /// chat cell: a plain completion returns 200 with a non-empty answer and
  /// a terminal `finish_reason` of `stop` or `length` (#434/#439 — the
  /// engine must always settle a turn, never starve). On a thinking model
  /// the visible answer stays free of raw `<think>` delimiters and the
  /// scratchpad rides `reasoning_content` (#329); a thinking model that
  /// caps mid-reasoning legitimately yields empty `content`, so "produced
  /// output" is satisfied by either channel.
  private func assertChatCell(port: Int, modelID: String,
                              expectReasoning: Bool, expectSemantic: Bool) async throws {
    let json = try await postChatJSON(port: port, body: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": expectReasoning ? 1024 : 64,
      "stream": false,
    ])
    let choice = try cellUnwrap((json["choices"] as? [[String: Any]])?.first, "chat: no choices")
    let message = try cellUnwrap(choice["message"] as? [String: Any], "chat: no message")
    let content = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let reasoning = ((message["reasoning_content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let finish = choice["finish_reason"] as? String

    // Diagnostic evidence (#484): surface the actual reply so the matrix log
    // shows the semantic floor is satisfied by real text, not vacuously. One
    // tab-delimited line per cell; truncated so a runaway reply can't flood
    // the log. Printed before the asserts so it is captured even on a FAIL.
    let reasonEvidence = reasoning.isEmpty ? "" : "\treasoning=\(reasoning.prefix(200).debugDescription)"
    print("CHAT-REPLY\t\(modelID)\tfinish=\(finish ?? "nil")\tsemantic_gated=\(expectSemantic)"
          + "\tcontent=\(content.prefix(200).debugDescription)\(reasonEvidence)")

    try cellRequire(["stop", "length"].contains(finish ?? ""),
                    "chat: finish_reason must be stop|length, got \(finish ?? "nil")")
    try cellRequire(!(content.isEmpty && reasoning.isEmpty),
                    "chat: engine produced neither content nor reasoning")
    if expectReasoning {
      try cellRequire(!(content.contains("<think>") || content.contains("</think>")),
                      "chat: raw think delimiter leaked into content: \(content.debugDescription)")
      try cellRequire(!reasoning.isEmpty,
                      "chat: thinking model must surface reasoning_content")
    }

    // The answer channel: the visible content, or the reasoning scratchpad
    // when a thinking model caps before emitting any content.
    let answer = content.isEmpty ? reasoning : content

    // Degenerate-output guard (#484): all-whitespace or pure-repetition
    // output is template/tokenizer corruption — a model that loads but emits
    // coherent-SHAPED garbage. Reject it across EVERY model (no capability
    // gate) without grading quality.
    try cellRequire(!Self.isDegenerateOutput(answer),
                    "chat: degenerate output (all-whitespace or pure repetition): \(answer.prefix(120).debugDescription)")

    // Weak semantic floor (#484): on the trivial 'pong' prompt a capable
    // model must echo the word somewhere in its reply. Capability-gated to
    // the larger tier (`expectSemantic`); checking either channel keeps a
    // thinking model that answers inside its scratchpad from false-FAILing
    // while a broken-template/tokenizer model — which never produces 'pong'
    // anywhere — still trips it.
    if expectSemantic {
      let haystack = (content + " " + reasoning).lowercased()
      try cellRequire(haystack.contains("pong"),
                      "chat: semantic floor — reply did not contain 'pong' (content=\(content.prefix(120).debugDescription))")
    }
  }

  /// Detect template/tokenizer corruption that still yields a well-FORMED
  /// response: output that is all-whitespace, a single character repeated, or
  /// the same word repeated. Deliberately conservative — it flags only
  /// egregious degeneracy so a legitimate short answer (incl. the bare
  /// `pong`) never trips it. This is a compatibility tripwire, NOT a quality
  /// grader (#484).
  static func isDegenerateOutput(_ text: String) -> Bool {
    let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.isEmpty { return true } // all-whitespace

    // A single non-whitespace character repeated (e.g. "GGGGGGGG", "的的的的的的的的").
    let nonWhitespace = collapsed.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
    }
    if nonWhitespace.count >= 8 && Set(nonWhitespace).count == 1 { return true }

    // The same word repeated (e.g. "pong pong pong pong pong pong").
    let words = collapsed.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
    if words.count >= 6 && Set(words).count == 1 { return true }

    return false
  }

  /// Engine-free guard for the #484 degenerate-output classifier. Runs in the
  /// deterministic scenario tier (no `realEngineEnvOrSkip`), so the matrix's
  /// new tripwire logic is verified without a real engine: corruption shapes
  /// must trip it, legitimate short answers (incl. a bare `pong`) must not.
  func test_isDegenerateOutput_classifier() {
    // Degenerate — must be rejected.
    XCTAssertTrue(Self.isDegenerateOutput(""))
    XCTAssertTrue(Self.isDegenerateOutput("   \n\t  "))
    XCTAssertTrue(Self.isDegenerateOutput("GGGGGGGG"))          // single char ×8
    XCTAssertTrue(Self.isDegenerateOutput("!!!!!!!!!!"))
    XCTAssertTrue(Self.isDegenerateOutput("的的的的的的的的"))      // non-ASCII single char
    XCTAssertTrue(Self.isDegenerateOutput("pong pong pong pong pong pong"))
    XCTAssertTrue(Self.isDegenerateOutput("the the the the the the the"))

    // Legitimate — must pass.
    XCTAssertFalse(Self.isDegenerateOutput("pong"))
    XCTAssertFalse(Self.isDegenerateOutput("Pong!"))
    XCTAssertFalse(Self.isDegenerateOutput("The answer is pong."))
    XCTAssertFalse(Self.isDegenerateOutput("GGG"))              // short repeat (<8) is not flagged
    XCTAssertFalse(Self.isDegenerateOutput("pong pong"))        // <6 words is not flagged
    XCTAssertFalse(Self.isDegenerateOutput("ping pong ping pong ping pong"))
  }

  /// tree-of-thought cell: dispatch the real `/v1/inferlet` ToT search
  /// through the typed client + `toTEventStream` (the exact App path) and
  /// require the stream to reach a `tree_complete` terminal with a chosen
  /// answer, having materialized at least one node at depth ≥ 2 — the
  /// depth>1 search is what spans the inter-level idle gap (#413). Default
  /// `coupled_sequential` exec, so the production prebuilt wasm serves it
  /// (the #458 phased_concurrent strategies are a separate feature build).
  private func assertTreeOfThoughtCell(port: Int, modelID: String) async throws {
    let client = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
    let input: [String: Any] = [
      "model": modelID,
      "messages": [["role": "user", "content": "What is the best way to learn a new programming language?"]],
      "breadth": 3,
      "depth": 2,
      "beam_width": 2,
      "max_tokens_per_node": 256,
      "temperature": 0.7,
      "top_p": 0.9,
    ]
    let req = InferletRequest(
      inferlet: "tree-of-thought",
      input: try JSONSerialization.data(withJSONObject: input),
      messages: nil,
      stream: true)

    var sawTreeComplete = false
    var maxDepth = 0
    var selected: String?
    var finalAnswer: String?
    for try await event in toTEventStream(from: client.dispatchInferlet(req)) {
      switch event {
      case .nodeComplete(let node):
        maxDepth = max(maxDepth, node.depth)
      case .treeComplete(let sel, let ans):
        sawTreeComplete = true
        selected = sel
        finalAnswer = ans
      default:
        break
      }
    }
    try cellRequire(sawTreeComplete, "tot: stream never reached tree_complete")
    try cellRequire(maxDepth >= 2, "tot: search did not reach depth>1 (max node depth \(maxDepth))")
    try cellRequire(selected != nil || !((finalAnswer ?? "").isEmpty),
                    "tot: tree_complete carried neither a selected node nor a final answer")
  }

  /// fast-think cell: a greedy (temperature 0) completion carrying the
  /// chat-apc `speculation` extension must actually engage speculative
  /// decoding — the response's `spec_metrics` object is omitted entirely
  /// when speculation does not run (#418), so its presence with
  /// `enabled == true` is the wire proof. Also a real answer on some
  /// channel (thinking models may cap mid-reasoning, as in the chat cell).
  private func assertFastThinkCell(port: Int, modelID: String, expectReasoning: Bool) async throws {
    let json = try await postChatJSON(port: port, body: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": expectReasoning ? 1024 : 64,
      "temperature": 0.0,
      "stream": false,
      "speculation": ["enabled": true],
    ])
    let choice = try cellUnwrap((json["choices"] as? [[String: Any]])?.first, "fast-think: no choices")
    let message = try cellUnwrap(choice["message"] as? [String: Any], "fast-think: no message")
    let content = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let reasoning = ((message["reasoning_content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try cellRequire(!(content.isEmpty && reasoning.isEmpty),
                    "fast-think: engine produced neither content nor reasoning")
    let spec = try cellUnwrap(json["spec_metrics"] as? [String: Any],
                              "fast-think: spec_metrics absent — speculation did not engage")
    try cellRequire(spec["enabled"] as? Bool == true,
                    "fast-think: spec_metrics.enabled != true (fallback_reason=\(spec["fallback_reason"] ?? "nil"))")
  }

  /// ceiling cell (#475): the real-engine token-ceiling contract, proven per
  /// loaded model so the (memory-size) matrix shows the engine's effective
  /// `max_output_tokens` — and its clean over-ceiling rejection — vary with
  /// the model that squeezed KV capacity.
  ///
  /// The original failure (#475 → #474 fix): a profile `max_tokens` above the
  /// launched engine's memory-aware ceiling tripped a raw, opaque engine
  /// error ("max ... must be in [0,512]") at generate time. #474 moved the
  /// check to the chat-apc 400 boundary; this is the REAL-engine proof of
  /// that boundary across every memory size:
  ///   1. `GET /v1/models` advertises a positive, floor-respecting ceiling N
  ///      (`max_output_tokens`, memory-aware; floor 512 = KVCacheBudget).
  ///   2. An over-ceiling request (N+1) returns a CLEAN 400
  ///      `max_tokens must be in [1, N]` blaming `param=max_tokens` — the
  ///      boundary rejection, NOT the raw generate-time engine error.
  ///   3. An at-ceiling request (N) is accepted (200) — the bound is
  ///      inclusive, guarding an off-by-one in the ceiling check / clamp.
  ///
  /// The actual N and the over-ceiling 400 body are printed (CEILING* lines)
  /// so the matrix log makes the contract auditable per memory size, not a
  /// vacuous PASS.
  private func assertTokenCeilingCell(port: Int, modelID: String) async throws {
    // 1. Read the engine's advertised ceiling for the loaded model.
    let ceiling = try await readAdvertisedCeiling(port: port, modelID: modelID, label: "ceiling")

    // 2. Over-ceiling (N+1) must be rejected at the clean 400 boundary — the
    //    exact failure #475 captures: NOT the raw generate-time engine error.
    try await assertOverCeilingRejected(port: port, modelID: modelID, ceiling: ceiling, label: "ceiling")

    // 3. At-ceiling (N) must be accepted — inclusive bound (off-by-one guard).
    //    The trivial prompt stops the model early, so a large N stays cheap.
    let (atData, atResp) = try await postChatRaw(port: port, body: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": ceiling,
      "stream": false,
    ])
    let atHTTP = try cellUnwrap(atResp as? HTTPURLResponse, "ceiling: at-ceiling no HTTP response")
    let atText = String(data: atData, encoding: .utf8) ?? ""
    try cellRequire(atHTTP.statusCode == 200,
                    "ceiling: at-ceiling (max_tokens=\(ceiling)) must be accepted (200), got "
                    + "\(atHTTP.statusCode): \(atText.prefix(300))")
  }

  /// Read the engine's advertised `max_output_tokens` for `modelID` off
  /// `GET /v1/models`, assert it is a positive, floor-respecting ceiling, and
  /// print a `CEILING` evidence line. Shared by the single-budget `ceiling`
  /// cell and the per-budget memory sweep so both audit the real N.
  /// `label` tags the evidence/errors with the caller's cell name.
  @discardableResult
  private func readAdvertisedCeiling(port: Int, modelID: String, label: String) async throws -> Int {
    let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models")!
    let (mData, mResp) = try await URLSession.shared.data(from: modelsURL)
    let mHTTP = try cellUnwrap(mResp as? HTTPURLResponse, "\(label): no /v1/models HTTP response")
    let mText = String(data: mData, encoding: .utf8) ?? ""
    try cellRequire(mHTTP.statusCode == 200,
                    "\(label): /v1/models HTTP \(mHTTP.statusCode): \(mText.prefix(300))")
    let mJSON = try cellUnwrap(try JSONSerialization.jsonObject(with: mData) as? [String: Any],
                               "\(label): /v1/models not a JSON object: \(mText.prefix(300))")
    let entry = try cellUnwrap(
      (mJSON["data"] as? [[String: Any]])?.first(where: { $0["id"] as? String == modelID }),
      "\(label): /v1/models has no entry for \(modelID): \(mText.prefix(300))")
    let ceiling = try cellUnwrap((entry["max_output_tokens"] as? NSNumber)?.intValue,
                                 "\(label): entry missing numeric max_output_tokens: \(entry)")
    print("CEILING\t\(modelID)\t\(label)\tmax_output_tokens=\(ceiling)")
    try cellRequire(ceiling >= 512,
                    "\(label): max_output_tokens \(ceiling) below the KVCacheBudget floor of 512")
    return ceiling
  }

  /// Assert an over-ceiling request (`max_tokens = ceiling + 1`) is rejected
  /// with the clean 400 `max_tokens must be in [1, ceiling]` blaming
  /// `param=max_tokens` — the structured boundary rejection, not the raw
  /// generate-time engine error. Prints a `CEILING-OVER` evidence line.
  private func assertOverCeilingRejected(port: Int, modelID: String, ceiling: Int, label: String) async throws {
    let (overData, overResp) = try await postChatRaw(port: port, body: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": ceiling + 1,
      "stream": false,
    ])
    let overHTTP = try cellUnwrap(overResp as? HTTPURLResponse, "\(label): over-ceiling no HTTP response")
    let overText = String(data: overData, encoding: .utf8) ?? ""
    print("CEILING-OVER\t\(modelID)\t\(label)\tstatus=\(overHTTP.statusCode)\tbody=\(overText.prefix(200).debugDescription)")
    try cellRequire(overHTTP.statusCode == 400,
                    "\(label): over-ceiling (max_tokens=\(ceiling + 1)) must be a clean 400, got "
                    + "\(overHTTP.statusCode): \(overText.prefix(300))")
    let overErr = (try? JSONSerialization.jsonObject(with: overData) as? [String: Any])?["error"] as? [String: Any]
    let overMsg = (overErr?["message"] as? String) ?? ""
    let overParam = (overErr?["param"] as? String) ?? ""
    try cellRequire(overMsg == "max_tokens must be in [1, \(ceiling)]",
                    "\(label): over-ceiling 400 message drifted — want "
                    + "'max_tokens must be in [1, \(ceiling)]', got \(overMsg.debugDescription)")
    try cellRequire(overParam == "max_tokens",
                    "\(label): over-ceiling 400 must blame param=max_tokens, got \(overParam.debugDescription)")
  }

  /// POST a non-streaming chat body and return the raw `(data, response)`
  /// WITHOUT asserting a status — unlike `postChatJSON`, which requires 200.
  /// The ceiling cell inspects both a 400 (over-ceiling) and a 200
  /// (at-ceiling), so it owns the status check on each call.
  private func postChatRaw(port: Int, body: [String: Any]) async throws -> (Data, URLResponse) {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 180
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await URLSession.shared.data(for: req)
  }

  // MARK: - launch helper

  private struct RealEngineEnv {
    let pieBin: URL
    let modelPath: URL
    let wasm: URL
    let manifest: URL
  }

  private func realEngineEnvOrSkip() throws -> RealEngineEnv {
    let env = ProcessInfo.processInfo.environment
    func require(_ key: String) throws -> String {
      guard let v = env[key], !v.isEmpty else {
        throw XCTSkip("\(key) not set — run Scripts/run-engine-e2e.sh (stages a GGUF + the bundled pie binary)")
      }
      return v
    }
    let e = RealEngineEnv(
      pieBin: URL(fileURLWithPath: try require("PIE_TEST_REAL_PIE_BIN")),
      modelPath: URL(fileURLWithPath: try require("PIE_TEST_REAL_MODEL_PATH")),
      wasm: URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_WASM")),
      manifest: URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_MANIFEST"))
    )
    let fm = FileManager.default
    XCTAssertTrue(fm.isExecutableFile(atPath: e.pieBin.path), "pie binary missing/!exec at \(e.pieBin.path)")
    XCTAssertTrue(fm.fileExists(atPath: e.modelPath.path), "model missing at \(e.modelPath.path)")
    return e
  }

  /// Drives the PRODUCTION launch path (real `LaunchSpecResolver` →
  /// `PieEngineHost` → real `pie serve` subprocess) and returns once the
  /// engine reports `.running`. The caller owns `host` (and its
  /// `host.stop()` defer) so the engine outlives this call. The spawned
  /// `pie serve` pid is routed into the `IsolatedTestCase` reap net via
  /// `reapEngineSubprocess(in:)` so a hung engine is SIGKILL-reaped
  /// post-test even if the body throws.
  private func launchRealEngine(
    _ e: RealEngineEnv,
    host: PieEngineHost
  ) async throws -> (port: Int, slug: String) {
    let fm = FileManager.default
    // Stage a models root containing the GGUF (the slug is the leaf
    // filename, matching the resolver's flat-slug join) + a profile
    // pointing at it. Hardlink so we don't copy ~500 MB per run.
    let modelsRoot = tempPieHome.appendingPathComponent("models", isDirectory: true)
    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    let slug = e.modelPath.lastPathComponent
    let staged = modelsRoot.appendingPathComponent(slug, isDirectory: false)
    try? fm.removeItem(at: staged)
    // The resolver requires a regular file (rejects symlinks as an
    // anti-symlink-attack guard), so hardlink when possible (same
    // volume, no copy) and fall back to a full copy across volumes.
    do {
      try fm.linkItem(at: e.modelPath, to: staged)
    } catch {
      try fm.copyItem(at: e.modelPath, to: staged)
    }

    let profiles = tempPieHome.appendingPathComponent("profiles", isDirectory: true)
    try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    id = "chat"
    name = "Chat"
    model = "\(slug)"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let store = ProfileStore(
      directory: profiles,
      activeProfileURL: tempPieHome.appendingPathComponent("active-profile", isDirectory: false)
    )
    try store.start()
    try store.setActiveProfileID("chat")

    // Real resolver → real launcher (no PieEngineHost launcher override).
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { e.pieBin },
      modelsRoot: { modelsRoot },
      pieControlResources: { (wasm: e.wasm, manifest: e.manifest) },
      // The engine binds an aux Unix-domain socket under
      // <pieHome>/standalone/<pid>/g0/aux.sock, which must fit the
      // sun_path 104-char limit. NSTemporaryDirectory() (/var/folders/…)
      // is far too deep, so anchor pieHome at a short /tmp path. (:
      // production's ~/Library/Application Support/RatioThink is short enough.)
      pieHome: { self.shortPieHome },
      subprocessEnvironment: { SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment) }
    )
    var spec: PieControlLauncher.LaunchSpec
    switch resolver.asClosure("chat", nil) {
    case .success(let s): spec = s
    case .failure(let err):
      store.stop()
      XCTFail("resolver rejected chat profile: \(err.code.rawValue): \(err.message)")
      throw XCTSkip("resolver failure")
    }
    // Register the about-to-be-spawned `pie serve` pid with the
    // IsolatedTestCase reap net so a hung engine is SIGKILL-reaped after
    // the test even if the body throws or `host.stop()` (async) hasn't
    // run. The resolver leaves `pidSink` nil; this is the sole sink.
    reapEngineSubprocess(in: &spec)
    // ProfileStore must outlive the launch; the engine has its config by
    // the time .running is reported, so stopping it after is safe.
    defer { store.stop() }

    if case .failure(let err) = host.start(spec) {
      XCTFail("engineHost.start rejected: \(err.code.rawValue): \(err.message)")
      throw XCTSkip("host start failure")
    }
    // Await .running (model load + Metal init can take ~10-30s cold).
    let port = try await awaitRunning(host: host, timeout: 120)
    XCTAssertGreaterThan(port, 0, "engine must publish a real port")
    return (port, slug)
  }

  /// Stage a real GGUF + a profile with NO `model =` default, and build the
  /// production resolver against them (#469). The absent default is the whole
  /// point: it forces the engine's boot model to come from the explicit pick
  /// or the active-model marker — the App↔Helper sync surfaces — never a
  /// profile default. Does NOT launch; the caller drives the two launches.
  private func stageNoDefaultProfile(
    _ e: RealEngineEnv
  ) throws -> (store: ProfileStore, resolver: LaunchSpecResolver, slug: String) {
    let fm = FileManager.default
    let modelsRoot = tempPieHome.appendingPathComponent("models", isDirectory: true)
    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    let slug = e.modelPath.lastPathComponent
    let staged = modelsRoot.appendingPathComponent(slug, isDirectory: false)
    try? fm.removeItem(at: staged)
    do { try fm.linkItem(at: e.modelPath, to: staged) }
    catch { try fm.copyItem(at: e.modelPath, to: staged) }

    let profiles = tempPieHome.appendingPathComponent("profiles", isDirectory: true)
    try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    id = "chat"
    name = "Chat"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let store = ProfileStore(
      directory: profiles,
      activeProfileURL: tempPieHome.appendingPathComponent("active-profile", isDirectory: false)
    )
    try store.start()
    try store.setActiveProfileID("chat")

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { e.pieBin },
      modelsRoot: { modelsRoot },
      pieControlResources: { (wasm: e.wasm, manifest: e.manifest) },
      pieHome: { self.shortPieHome },
      subprocessEnvironment: { SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment) }
    )
    return (store, resolver, slug)
  }

  /// Poll the host until `.stopped` so the next launch starts from a clean
  /// idle. Non-fatal on timeout — the IsolatedTestCase reap net SIGKILLs a
  /// lingering engine, and a brief overlap of two small engines is harmless.
  private func awaitStopped(host: PieEngineHost, timeout: TimeInterval) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .stopped = host.status { return }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    NSLog("awaitStopped: host still \(host.status) after \(timeout)s (reap net is the outer guard)")
  }

  // MARK: - pid-reap wiring

  /// Route the about-to-be-spawned `pie serve` pid into the
  /// `IsolatedTestCase` reap net. Factored out of the launch body so the
  /// wiring is verifiable engine-free
  /// (`test_reapEngineSubprocess_wires_pid_into_reap_net`); the gated
  /// real-engine test only runs on a host with a staged model + binary.
  private func reapEngineSubprocess(in spec: inout PieControlLauncher.LaunchSpec) {
    spec.pidSink = { [weak self] pid in self?.trackSubprocess(pid) }
  }

  /// Engine-free regression guard for the pid-reap wiring. Subclassing
  /// `IsolatedTestCase` only helps if the spawned pid actually reaches
  /// `trackSubprocess(_:)`, so assert the seam forwards it. A real
  /// `/bin/sleep` stands in for the engine: the base reap loop SIGKILLs +
  /// waitpids it post-test, so there is no manual cleanup and no leak —
  /// the same pattern as `IsolatedTestCaseTests`' reap check.
  func test_reapEngineSubprocess_wires_pid_into_reap_net() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["60"]
    try sleeper.run()

    var spec = try makeDummyLaunchSpec()
    XCTAssertNil(spec.pidSink, "precondition: a fresh spec has no pidSink")
    reapEngineSubprocess(in: &spec)
    XCTAssertNotNil(spec.pidSink, "reapEngineSubprocess must install a pidSink")

    let before = trackedSubprocessCountForTesting
    spec.pidSink?(sleeper.processIdentifier)
    XCTAssertEqual(trackedSubprocessCountForTesting, before + 1,
                   "the spec's pidSink must forward the spawned pid into the IsolatedTestCase reap net")
    // No teardown: the base reap loop SIGKILL + waitpids the sleeper.
  }

  /// Minimal `.dummy` LaunchSpec for the engine-free wiring test.
  /// `.dummy` skips PieControlLauncher's driver-capability probe, so the
  /// throwaway binary/resource paths need not exist on disk.
  private func makeDummyLaunchSpec() throws -> PieControlLauncher.LaunchSpec {
    try PieControlLauncher.LaunchSpec(
      pieBinary: tempPieHome.appendingPathComponent("pie"),
      wasmURL: tempPieHome.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tempPieHome.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      modelConfig: .dummy
    )
  }

  // MARK: - launch fires pidSink (engine-free production coverage)

  /// The seam test above proves `reapEngineSubprocess` installs a pidSink,
  /// but NOT that `PieControlLauncher.launch` actually FIRES it — the only
  /// tests that drive `launch()` -> pidSink (S0_TestIsolationTests,
  /// ScenarioBindings' S3) are `XCTSkipUnless`-gated on the pie binary, so
  /// every engine-free lane has zero coverage of that production call. A
  /// regression dropping the sink call would keep all default-lane tests
  /// green while the real-engine test silently leaked.
  ///
  /// Drive a real `launch()` against a tiny stub `pie` that emits the two
  /// handshake markers `awaitHandshake` waits on, with its advertised WS
  /// address pointed at a just-closed loopback port so the post-handshake
  /// control-plane install fails fast (ECONNREFUSED) — no real engine.
  /// Assert (a) the sink received the spawned pid, and (b) `launch` failed
  /// at the WS step (`.clientError`), which also pins the stub's marker
  /// strings against the launcher's `awaitHandshake` regexes: a drift
  /// would surface as `.handshakeTimeout` and fail (b).
  func test_launch_fires_pidSink_with_spawned_pid_engineFree() async throws {
    let deadPort = try Self.reserveClosedLoopbackPort()
    let stub = try writeStubPie(advertisedWSPort: deadPort, readiness: .legacy)
    let captured = OSAllocatedUnfairLock<pid_t>(initialState: 0)

    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: stub,
      wasmURL: tempPieHome.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tempPieHome.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      handshakeTimeout: 5,
      pidSink: { pid in captured.withLock { $0 = pid } },
      modelConfig: .dummy
    )

    do {
      // Unreachable in practice (the dead WS port refuses the post-handshake
      // connect) — but if a future change ever let it succeed, shut the
      // session down so the stub subprocess can't leak.
      let (_, session) = try await PieControlLauncher.launch(spec: spec)
      _ = await session.shutdown()
      XCTFail("engine-free stub cannot complete the WS install; launch must throw")
    } catch let error as PieControlLauncher.LaunchError {
      guard case .clientError = error else {
        return XCTFail("expected .clientError (handshake passed, post-handshake WS install failed); got \(error) — stub markers may have drifted from PieControlLauncher.awaitHandshake")
      }
    }

    let pid = captured.withLock { $0 }
    XCTAssertGreaterThan(pid, 0,
                         "PieControlLauncher.launch must fire pidSink with the spawned pie pid — the production fact the hand-rolled seam test does not cover")
  }

  func test_launch_accepts_new_server_ready_handshake_format_engineFree() async throws {
    let deadPort = try Self.reserveClosedLoopbackPort()
    let stub = try writeStubPie(advertisedWSPort: deadPort, readiness: .serverReady)
    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: stub,
      wasmURL: tempPieHome.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tempPieHome.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      handshakeTimeout: 5,
      modelConfig: .dummy
    )

    do {
      let (_, session) = try await PieControlLauncher.launch(spec: spec)
      await session.shutdown()
      XCTFail("engine-free stub cannot complete the WS install; launch must throw")
    } catch let error as PieControlLauncher.LaunchError {
      guard case .clientError = error else {
        return XCTFail("expected .clientError after parsing new 'Server ready at ws://...' handshake; got \(error)")
      }
    }
  }

  /// Write an executable stub mimicking `pie serve` only as far as
  /// `PieControlLauncher.awaitHandshake` reads: emit the serving-address
  /// line and the internal-token line (the exact two markers the launcher
  /// captures), then re-exec as `sleep` so the pid stays stable for the
  /// launcher's shutdown SIGINT. It runs no WS server, so the launcher's
  /// install step fails by design — after the pidSink has already fired.
  private enum StubReadiness {
    case legacy
    case serverReady
  }

  private func writeStubPie(advertisedWSPort port: UInt16,
                            readiness: StubReadiness) throws -> URL {
    let url = tempPieHome.appendingPathComponent("stub-pie-\(UUID().uuidString.prefix(8))")
    let readyLine: String
    switch readiness {
    case .legacy:
      readyLine = #"pie-server serving on 127.0.0.1:\#(port)"#
    case .serverReady:
      readyLine = #"✓ Server ready at ws://127.0.0.1:\#(port)"#
    }
    let script = """
    #!/bin/sh
    echo "\(readyLine)"
    echo "internal token: stub-token-deadbeef"
    exec sleep 30
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: url.path)
    return url
  }

  /// Bind 127.0.0.1:0, read the OS-assigned port, close the socket — so a
  /// later connect to that port fails fast with ECONNREFUSED. Mirrors the
  /// launcher's own `reserveFreePort`; gives the stub a dead WS port so
  /// `launch()`'s post-handshake connect fails without a real engine.
  /// (Same close->reuse race as the launcher; negligible on loopback for a
  /// single-shot test.)
  private static func reserveClosedLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw stubSocketError("socket", errno) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let bindRC = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindRC == 0 else { throw stubSocketError("bind", errno) }
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameRC = withUnsafeMutablePointer(to: &out) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    guard nameRC == 0 else { throw stubSocketError("getsockname", errno) }
    return UInt16(bigEndian: out.sin_port)
  }

  private static func stubSocketError(_ call: String, _ err: Int32) -> NSError {
    NSError(domain: "RealEngineLaunchE2ETests.stub", code: Int(err),
            userInfo: [NSLocalizedDescriptionKey: "\(call) failed: \(String(cString: strerror(err)))"])
  }
}
