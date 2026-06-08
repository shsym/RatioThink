import Foundation
import RatioThinkCore

/// S6 — XPC payload round-trip.
///
/// Each Codable value that crosses the helper↔GUI boundary survives a
/// full encode→decode cycle. Locks the JSON wire format before Phase 2
/// stands up `NSXPCConnection`; the same scenario is reusable later by
/// a runner that drives a real listener.
public enum S6_XPCRoundtrip {
  public static let title = "XPC Codable payloads round-trip losslessly"

  public static func run<R: ScenarioRunner>(_ r: R) async throws {
    try await r.step("EngineStatus.stopped round-trips") {
      let out = try await r.xpcRoundTripEngineStatus(.stopped)
      try r.require(out == .stopped, "got \(out)")
    }

    try await r.step("EngineStatus.running carries port + profileID") {
      let original = EngineStatus.running(port: 51234, profileID: "chat")
      let out = try await r.xpcRoundTripEngineStatus(original)
      try r.require(out == original, "got \(out)")
    }

    try await r.step("EngineStatus.failed preserves discriminator + message") {
      let original = EngineStatus.failed(code: .spawnFailed, message: "ENOENT")
      let out = try await r.xpcRoundTripEngineStatus(original)
      try r.require(out == original, "got \(out)")
    }

    try await r.step("DownloadHandle survives round-trip with stable UUID") {
      let original = DownloadHandle(repo: "bartowski/Llama-3.2-3B-Instruct-GGUF",
                                    file: "Q4_K_M.gguf")
      let out = try await r.xpcRoundTripDownloadHandle(original)
      try r.require(out == original,
                    "round-trip mutated handle: \(original) → \(out)")
    }

    try await r.step("EngineError round-trips for every code") {
      for code in [EngineErrorCode.spawnFailed,
                   .handshakeTimeout, .modelMissing, .profileMissing,
                   .portUnavailable, .alreadyRunning, .cancelled,
                   .wireContractViolation, .degraded,
                   .integrityFailed, .networkFailed, .diskWriteFailed,
                   .invalidInput, .killRejected, .memoryRisk, .unknown] {
        let original = EngineError(code: code, message: "msg-\(code.rawValue)")
        let out = try await r.xpcRoundTripEngineError(original)
        try r.require(out == original, "code \(code) lost in round-trip: got \(out)")
      }
    }

    try await r.step("startEngine success reply round-trips as Result.success(port)") {
      let result: Result<EnginePort, EngineError> = .success(7777)
      let out = try await r.xpcStartEngineReplyRoundTrip(result)
      switch out {
      case .success(let port): try r.require(port == 7777, "wrong port: \(port)")
      case .failure(let e):    try r.require(false, "expected .success, got .failure(\(e))")
      }
    }

    try await r.step("startEngine failure reply round-trips as Result.failure(error)") {
      let err = EngineError(code: .portUnavailable, message: "EADDRINUSE")
      let result: Result<EnginePort, EngineError> = .failure(err)
      let out = try await r.xpcStartEngineReplyRoundTrip(result)
      switch out {
      case .success(let p): try r.require(false, "expected .failure, got .success(\(p))")
      case .failure(let e): try r.require(e == err, "error mutated: \(e) vs \(err)")
      }
    }
  }
}
