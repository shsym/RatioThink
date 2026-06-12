import Foundation
import ServiceManagement

enum LoginItemRegistrationStatus: Equatable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
  case unavailable(String)

  var userVisibleText: String {
    switch self {
    case .notRegistered:
      return "Rational Helper is not registered yet"
    case .enabled:
      return "Rational Helper is registered"
    case .requiresApproval:
      return "Rational Helper needs approval in System Settings"
    case .notFound:
      return "Rational Helper was not found in the app bundle"
    case .unavailable(let reason):
      return "Rational Helper registration unavailable: \(reason)"
    }
  }

  var canContinue: Bool {
    switch self {
    case .enabled:
      return true
    case .notRegistered, .requiresApproval, .notFound, .unavailable:
      return false
    }
  }

  /// One-line description, for *Settings → General → Startup*, of whether
  /// Rational keeps its menu-bar icon / background helper after the main
  /// app quits. The menu-bar presence is owned by the launchd-managed
  /// Rational Helper agent (registered via `SMAppService`), so this
  /// registration state — not the app process — decides whether the icon
  /// and the engine survive a quit. Phrased honestly: the app cannot tear
  /// down a running helper, so we surface the persistence the user has
  /// (or hasn't) opted into rather than offer a switch that can't deliver.
  var menuBarPersistenceSummary: String {
    switch self {
    case .enabled:
      return "Rational stays in your menu bar after you quit, so the engine resumes instantly."
    case .notRegistered:
      return "Rational won't stay in your menu bar after you quit until Rational Helper is registered."
    case .requiresApproval:
      return "Approve Rational Helper in System Settings to keep it in your menu bar after you quit."
    case .notFound:
      return "Rational Helper is missing from the app bundle, so Rational can't stay in your menu bar after you quit."
    case .unavailable(let reason):
      return "Menu-bar persistence is unavailable: \(reason)."
    }
  }
}

protocol LoginItemRegistering: AnyObject {
  var status: LoginItemRegistrationStatus { get }
  func register() throws -> LoginItemRegistrationStatus
  /// Remove the SMAppService registration. Needed to force launchd to
  /// reload a STALE job after a bundle replacement: while the status is
  /// already `.enabled`, `register()` is a no-op and will not republish
  /// `com.ratiothink.helper`, so the reconciler does `unregister()` then
  /// `register()` ( robustness). Throwing when the item is already
  /// absent is benign — callers ignore it.
  func unregister() throws
}

extension LoginItemRegistrationStatus {
  /// Project onto the RatioThinkCore `HelperRegistrationState` the reconciler
  /// reasons over.
  var reconcilerState: HelperRegistrationState {
    switch self {
    case .enabled:          return .enabled
    case .notRegistered:    return .notRegistered
    case .requiresApproval: return .requiresApproval
    case .notFound, .unavailable:
      return .other
    }
  }
}

final class SMAppServiceLoginItemRegistrar: LoginItemRegistering {
  /// Name of the launchd plist staged at
  /// `Rational.app/Contents/Library/LaunchAgents/<plistName>`. Registered as
  /// an agent (not a login item) so the plist's `MachServices` entry
  /// makes `com.ratiothink.helper` an on-demand launchd service: launchd
  /// (re)launches the Helper when the App connects, even after the
  /// Helper dies. `SMAppService.loginItem` registered only an
  /// at-login app launch and stripped `MachServices`, so a dead Helper
  /// never republished `com.ratiothink.helper` and the App saw 4099 until
  /// logout/login.
  /// Filename of the launchd agent plist staged into
  /// `Rational.app/Contents/Library/LaunchAgents/`. Single source of truth
  /// shared with the plist-contract test so the registrar and the
  /// bundled plist cannot drift.
  static let defaultPlistName = "com.ratiothink.app.helper.plist"

  private let plistName: String

  init(plistName: String = SMAppServiceLoginItemRegistrar.defaultPlistName) {
    self.plistName = plistName
  }

  var status: LoginItemRegistrationStatus {
    map(SMAppService.agent(plistName: plistName).status)
  }

  func register() throws -> LoginItemRegistrationStatus {
    let service = SMAppService.agent(plistName: plistName)
    try service.register()
    return map(service.status)
  }

  func unregister() throws {
    try SMAppService.agent(plistName: plistName).unregister()
  }

  private func map(_ status: SMAppService.Status) -> LoginItemRegistrationStatus {
    switch status {
    case .notRegistered:
      return .notRegistered
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      return .notFound
    @unknown default:
      return .unavailable("unknown SMAppService status")
    }
  }
}

final class EnvironmentLoginItemRegistrar: LoginItemRegistering {
  static let envKey = "PIE_TEST_LOGIN_ITEM_STATUS"

  private var current: LoginItemRegistrationStatus

  init(initial: LoginItemRegistrationStatus) {
    self.current = initial
  }

  var status: LoginItemRegistrationStatus { current }

  func register() throws -> LoginItemRegistrationStatus {
    current = .enabled
    return current
  }

  func unregister() throws {
    current = .notRegistered
  }

  static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LoginItemRegistering? {
    guard let raw = env[envKey], !raw.isEmpty else { return nil }
    return EnvironmentLoginItemRegistrar(initial: parse(raw))
  }

  private static func parse(_ raw: String) -> LoginItemRegistrationStatus {
    switch raw {
    case "notRegistered": return .notRegistered
    case "enabled": return .enabled
    case "requiresApproval": return .requiresApproval
    case "notFound": return .notFound
    default: return .unavailable(raw)
    }
  }
}

enum LoginItemRegistrarFactory {
  static func make() -> LoginItemRegistering {
    EnvironmentLoginItemRegistrar.fromEnvironment()
      ?? SMAppServiceLoginItemRegistrar()
  }
}
