import Foundation

enum LocalAPIAutoStartResult: Equatable {
  case skipped
  case started
  case failed(message: String)
}

enum LocalAPIAutoStartLauncher {
  @MainActor
  static func run(
    enabled: Bool,
    status: EngineStatus,
    activeProfileID: String?,
    startEngine: (String) async throws -> Void,
    errorMessage: (Error) -> String
  ) async -> LocalAPIAutoStartResult {
    guard LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: enabled,
      status: status,
      activeProfileID: activeProfileID
    ), let profileID = activeProfileID else {
      return .skipped
    }

    do {
      try await startEngine(profileID)
      return .started
    } catch {
      return .failed(message: errorMessage(error))
    }
  }
}
