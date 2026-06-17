import Foundation
import Combine
import os

/// User preferences that persist across app launches but are NOT part
/// of the engine config (`<PIE_HOME>/config.toml` is owned by the
/// engine launcher — see `PieControlLauncher`). Lives in
/// `UserDefaults` so macOS handles atomic writes, multi-process
/// coalescing, and `defaults read` debugging for free.
///
/// `final` + `@MainActor` so SwiftUI views can observe `@Published`
/// mutations without main-actor warnings. Tests inject a scratch
/// `UserDefaults(suiteName:)` via init to keep the process defaults
/// clean.
///
///  removed the per-model "don't ask again" swap skip-set: every
/// model load now always shows the confirm, so there is no silent-load
/// path to remember. The only surviving entry is the first-launch
/// completion flag.
@MainActor
public final class AppPreferences: ObservableObject {
  /// Storage key flipped after the first-launch wizard completes.
  public static let firstLaunchWizardCompletedKey = "firstLaunchWizardCompleted"

  /// Storage key for the set of update versions the user chose to ignore via
  /// the launch-time "update available" banner (#411). Persisted as a string
  /// array of normalized version strings (e.g. `["0.1.1"]`).
  public static let ignoredUpdateVersionsKey = "ignoredUpdateVersions"

  /// Storage key for allowing other devices to reach the Local API by
  /// binding its daemon listener to `0.0.0.0` instead of loopback.
  public static let localAPIExternalAccessEnabledKey =
    EngineHTTPBindMode.localAPIExternalAccessEnabledPreferenceKey

  /// Storage key for the Local API launch policy. Defaults off so the app
  /// never loads a model or opens the local HTTP endpoint at startup unless
  /// the user explicitly opts in from the Local API page.
  public static let localAPIAutoStartEnabledKey = "localAPIAutoStartEnabled"

  /// Compatibility toggle for users who want profile changes to keep offering
  /// the destination profile's default model after a concrete model row was
  /// selected. Default OFF: explicit model picks stay pinned across profile
  /// changes for the current app flow.
  public static let followProfileDefaultModelKey = "followProfileDefaultModel"

  private let defaults: UserDefaults
  private let localAPIExposurePreference: LocalAPIExposurePreference.Store

  @Published public private(set) var firstLaunchWizardCompleted: Bool

  @Published public private(set) var followProfileDefaultModel: Bool

  /// Versions dismissed from the launch update banner. A dismissed version
  /// never re-surfaces; a strictly newer release is not in this set, so it
  /// prompts again. The manual "Check for Updates…" command ignores this set.
  @Published public private(set) var ignoredUpdateVersions: Set<String>

  /// Whether the Local API daemon should bind all interfaces. Defaults false
  /// because the endpoint is unauthenticated.
  @Published public private(set) var localAPIExternalAccessEnabled: Bool

  public var localAPIBindMode: EngineHTTPBindMode {
    localAPIExternalAccessEnabled ? .external : .loopback
  }

  /// Whether RatioThink should start the shared engine (and therefore the
  /// Local API) automatically on app launch. User-controlled; default false.
  @Published public private(set) var localAPIAutoStartEnabled: Bool

  public init(defaults: UserDefaults = .standard,
              localAPIExposurePreference: LocalAPIExposurePreference.Store = .live()) {
    self.defaults = defaults
    self.localAPIExposurePreference = localAPIExposurePreference
    self.firstLaunchWizardCompleted = defaults.bool(forKey: Self.firstLaunchWizardCompletedKey)
    self.followProfileDefaultModel = defaults.bool(forKey: Self.followProfileDefaultModelKey)
    self.ignoredUpdateVersions = Set(defaults.stringArray(forKey: Self.ignoredUpdateVersionsKey) ?? [])
    self.localAPIAutoStartEnabled = defaults.bool(forKey: Self.localAPIAutoStartEnabledKey)
    let fileBacked = localAPIExposurePreference.loadEnabled()
    let defaultsBacked = defaults.bool(forKey: Self.localAPIExternalAccessEnabledKey)
    let effectiveExternalAccess = fileBacked ?? defaultsBacked
    self.localAPIExternalAccessEnabled = effectiveExternalAccess
    if fileBacked == nil, defaultsBacked {
      do {
        try localAPIExposurePreference.saveEnabled(defaultsBacked)
      } catch {
        self.localAPIExternalAccessEnabled = false
        defaults.set(false, forKey: Self.localAPIExternalAccessEnabledKey)
        defaults.synchronize()
      }
    }
    if fileBacked != nil, defaultsBacked != effectiveExternalAccess {
      defaults.set(effectiveExternalAccess, forKey: Self.localAPIExternalAccessEnabledKey)
      defaults.synchronize()
    }
  }

  public func setFollowProfileDefaultModel(_ enabled: Bool) {
    guard followProfileDefaultModel != enabled else { return }
    followProfileDefaultModel = enabled
    defaults.set(enabled, forKey: Self.followProfileDefaultModelKey)
    defaults.synchronize()
  }

  /// Persist a version as ignored. Flushed to disk now (like the first-launch
  /// flag) so a quit right after dismissing the banner doesn't lose it and the
  /// version wrongly re-surfaces next launch. Empty input is a no-op.
  public func ignoreUpdateVersion(_ version: String) {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !ignoredUpdateVersions.contains(trimmed) else { return }
    ignoredUpdateVersions.insert(trimmed)
    // Store sorted for a stable, debuggable `defaults read`.
    defaults.set(ignoredUpdateVersions.sorted(), forKey: Self.ignoredUpdateVersionsKey)
    defaults.synchronize()
  }

  public func setLocalAPIExternalAccessEnabled(_ enabled: Bool) throws {
    guard localAPIExternalAccessEnabled != enabled else { return }
    try localAPIExposurePreference.saveEnabled(enabled)
    localAPIExternalAccessEnabled = enabled
    defaults.set(enabled, forKey: Self.localAPIExternalAccessEnabledKey)
    defaults.synchronize()
  }

  /// Mark the first-launch wizard complete.  reduced the
  /// wizard to required helper/menu-bar setup + orientation; model
  /// choice moved to Settings → Models, so completion is a single flag
  /// and never claims a default model.
  public func completeFirstLaunch() {
    firstLaunchWizardCompleted = true
    defaults.set(true, forKey: Self.firstLaunchWizardCompletedKey)
    // Force the one-shot completion flag to disk now. The user can quit
    // immediately after finishing the wizard; without an explicit flush
    // the suite write can be lost on an abrupt termination and the
    // wizard would wrongly reappear on the next launch.
    defaults.synchronize()
  }

  /// Test/developer reset hook used by GUI scenarios and future
  /// Settings affordances. Clears the completion flag so the next app
  /// launch behaves like a fresh install.
  public func resetFirstLaunchWizard() {
    firstLaunchWizardCompleted = false
    defaults.removeObject(forKey: Self.firstLaunchWizardCompletedKey)
  }

  /// Persist the Local API launch policy. Flushed immediately so a user can
  /// toggle it and quit before the next automatic UserDefaults sync without
  /// losing the startup intent.
  public func setLocalAPIAutoStartEnabled(_ enabled: Bool) {
    guard localAPIAutoStartEnabled != enabled else { return }
    localAPIAutoStartEnabled = enabled
    defaults.set(enabled, forKey: Self.localAPIAutoStartEnabledKey)
    defaults.synchronize()
  }
}
