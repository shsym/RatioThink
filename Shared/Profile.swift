import Foundation
import TOMLKit

public enum ProfileError: Error, Equatable, CustomStringConvertible {
  case missingField(String)
  case invalidValue(field: String, reason: String)
  case parseFailure(String)

  public var description: String {
    switch self {
    case .missingField(let f):          return "Profile missing required field: \(f)"
    case .invalidValue(let f, let why): return "Profile field '\(f)' invalid: \(why)"
    case .parseFailure(let why):        return "Profile TOML parse failure: \(why)"
    }
  }
}

public struct Sampling: Equatable {
  public var temperature: Double = 0.7
  public var topP: Double = 0.9
  public var maxTokens: Int = 2048

  public init(temperature: Double = 0.7, topP: Double = 0.9, maxTokens: Int = 2048) {
    self.temperature = temperature
    self.topP = topP
    self.maxTokens = maxTokens
  }
}

public struct Profile {
  /// Per-profile speculative-decoding ("Fast Think") settings — the
  /// domain mirror of the wire `ChatSpeculation` (#426). `nil` knobs fall
  /// back to the chat-apc inferlet's #418 defaults (leader 1 / draft 3).
  /// Drafting only engages when `enabled` AND the request is greedy
  /// (temperature 0); the send path (`ChatSendController.makeRequest`)
  /// enforces that coupling, so an enabled-speculation profile is always
  /// a greedy "Fast Think" profile.
  public struct Speculation: Equatable, Sendable {
    public var enabled: Bool
    public var leaderLen: Int?
    public var draftLen: Int?

    public init(enabled: Bool = false, leaderLen: Int? = nil, draftLen: Int? = nil) {
      self.enabled = enabled
      self.leaderLen = leaderLen
      self.draftLen = draftLen
    }
  }

  public var id: String
  public var name: String
  public var icon: String?
  /// Default model slug for this profile. `nil` is an explicit
  /// no-default state: the UI should prompt the operator to choose or
  /// download a model instead of inventing a fallback.
  public var model: String?
  public var inferlet: String
  public var systemPrompt: String?
  public var sampling: Sampling
  public var inferletArgs: [String: TOMLValueConvertible]
  /// Speculative-decoding settings from the `[speculation]` section;
  /// `nil` when the profile has no such section.
  public var speculation: Speculation?

  // Preserve unknown v2 sections (mcp_servers, routine, remote, agent) verbatim.
  private var rawTable: TOMLTable

  public init(
    id: String,
    name: String,
    icon: String? = nil,
    model: String?,
    inferlet: String,
    systemPrompt: String? = nil,
    sampling: Sampling = Sampling(),
    inferletArgs: [String: TOMLValueConvertible] = [:],
    speculation: Speculation? = nil,
    rawTable: TOMLTable = TOMLTable()
  ) {
    self.id = id
    self.name = name
    self.icon = icon
    self.model = model
    self.inferlet = inferlet
    self.systemPrompt = systemPrompt
    self.sampling = sampling
    self.inferletArgs = inferletArgs
    self.speculation = speculation
    self.rawTable = rawTable
  }

  public static func parse(toml source: String) throws -> Profile {
    let table: TOMLTable
    do {
      table = try TOMLTable(string: source)
    } catch {
      throw ProfileError.parseFailure(String(describing: error))
    }

    func requireString(_ key: String) throws -> String {
      guard let v = table[key]?.string else {
        throw ProfileError.missingField(key)
      }
      return v
    }

    let id       = try requireString("id")
    let name     = try requireString("name")
    let rawModel = table["model"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    let model    = rawModel?.isEmpty == false ? rawModel : nil
    let inferlet = try requireString("inferlet")

    let icon = table["icon"]?.string
    let systemPrompt = table["system_prompt"]?.string

    var sampling = Sampling()
    if let s = table["sampling"]?.table {
      if let t = s["temperature"]?.double { sampling.temperature = t }
      if let p = s["top_p"]?.double       { sampling.topP        = p }
      if let m = s["max_tokens"]?.int     { sampling.maxTokens   = m }
    }

    var args: [String: TOMLValueConvertible] = [:]
    if let ia = table["inferlet_args"]?.table {
      for k in ia.keys {
        if let v = ia[k] { args[k] = v }
      }
    }

    var speculation: Speculation? = nil
    if let s = table["speculation"]?.table {
      speculation = Speculation(
        enabled: s["enabled"]?.bool ?? false,
        leaderLen: s["leader_len"]?.int,
        draftLen: s["draft_len"]?.int
      )
    }

    return Profile(
      id: id, name: name, icon: icon,
      model: model, inferlet: inferlet,
      systemPrompt: systemPrompt,
      sampling: sampling,
      inferletArgs: args,
      speculation: speculation,
      rawTable: table
    )
  }

  /// Lossless round-trip — unknown v2 tables (`mcp_servers`, `routine`, `remote`, `agent`)
  /// are preserved in `rawTable` and emitted on dump. Required fields
  /// are mirrored from `self` into `rawTable` before emit so a
  /// `Profile` constructed via the public initializer (no parse step)
  /// still round-trips through TOML — `ProfileStore.createProfile`
  /// relies on this for first-class profile creation.
  ///
  /// Throws `ProfileError.parseFailure` when the `rawTable` cannot
  /// be cloned via the `convert() → TOMLTable(string:)` round-trip
  /// (review v3 F3). The prior `?? TOMLTable()` fallback was a
  /// silent-failure anti-pattern: it would emit a syntactically
  /// valid TOML with required fields but every preserved v2
  /// section (`mcp_servers`, `routine`, etc.) silently amputated.
  /// Surfacing the error here lets `ProfileStore.createProfile`
  /// abort the write before stale data hits disk.
  public func dump() throws -> String {
    // `TOMLTable` is a reference type, so `let table = rawTable`
    // would alias the struct's stored table — subsequent subscript
    // writes would mutate `self.rawTable` through the alias.
    // Round-trip through `.convert()` -> `TOMLTable(string:)` to
    // get an independent clone before mirroring the typed fields
    // back in.
    let table: TOMLTable
    do {
      table = try TOMLTable(string: rawTable.convert())
    } catch {
      throw ProfileError.parseFailure(
        "Profile.dump: rawTable convert/reparse round-trip failed (\(String(describing: error))) — refusing to emit a truncated profile that would silently drop preserved v2 sections"
      )
    }
    // Drop stale typed sections the caller may have cleared on
    // `self` since parse — without this, a profile loaded with
    // `icon = "X"` (or `system_prompt = "..."` / `inferlet_args.foo
    // = 1`) and then mutated to `.icon = nil` (etc.) would still
    // dump with the original value because the clone preserved the
    // key. `table[key] = nil` is a no-op in TOMLKit (the subscript
    // setter only fires for non-nil values); `remove(at:)` is the
    // actual deletion path. Mirror-back below re-inserts the typed
    // keys only when the Swift side still has a value (review v3
    // F4 — prior code only purged inferlet_args).
    table.remove(at: "icon")
    table.remove(at: "system_prompt")
    table.remove(at: "inferlet_args")
    table.remove(at: "speculation")
    table.remove(at: "model")
    table["id"]       = TOMLValue(stringLiteral: id)
    table["name"]     = TOMLValue(stringLiteral: name)
    table["inferlet"] = TOMLValue(stringLiteral: inferlet)
    if let model, !model.isEmpty { table["model"] = TOMLValue(stringLiteral: model) }
    if let icon { table["icon"] = TOMLValue(stringLiteral: icon) }
    if let systemPrompt { table["system_prompt"] = TOMLValue(stringLiteral: systemPrompt) }
    let samplingTable = TOMLTable([
      "temperature": TOMLValue(floatLiteral: sampling.temperature),
      "top_p":       TOMLValue(floatLiteral: sampling.topP),
      "max_tokens":  TOMLValue(integerLiteral: sampling.maxTokens),
    ])
    table["sampling"] = TOMLValue(samplingTable)
    if !inferletArgs.isEmpty {
      let args = TOMLTable()
      for (k, v) in inferletArgs { args[k] = v.tomlValue }
      table["inferlet_args"] = TOMLValue(args)
    }
    if let speculation {
      let specTable = TOMLTable(["enabled": TOMLValue(booleanLiteral: speculation.enabled)])
      if let l = speculation.leaderLen { specTable["leader_len"] = TOMLValue(integerLiteral: l) }
      if let d = speculation.draftLen  { specTable["draft_len"]  = TOMLValue(integerLiteral: d) }
      table["speculation"] = TOMLValue(specTable)
    }
    return table.convert()
  }

  /// Forward-compat v2 section names. Presence is optional; when
  /// present, ProfileStore surfaces type-shape mismatches as warnings
  /// rather than rejecting the whole profile (per plan §2.4: "loaded
  /// as warnings").
  public static let v2SectionNames: [String] = ["mcp_servers", "routine", "remote", "agent"]

  /// Validate the shape of forward-compat v2 sections without
  /// promoting failures into hard errors. Returns one warning per
  /// section that is present but has the wrong TOML type. Empty
  /// result == clean profile.
  ///
  /// Validation rules (loose on purpose — v2 schemas not yet frozen):
  ///   · `mcp_servers` must be a table (typically a table-of-tables).
  ///   · `routine`, `remote`, `agent` each must be a table.
  /// Anything else (e.g. a scalar, array, or string under those keys)
  /// produces a `ProfileSectionWarning`.
  public func sectionWarnings() -> [ProfileSectionWarning] {
    var warnings: [ProfileSectionWarning] = []
    for name in Profile.v2SectionNames {
      guard let value = rawTable[name] else { continue }
      if value.table == nil {
        warnings.append(ProfileSectionWarning(
          section: name,
          message: "expected a TOML table, got \(value.type)"
        ))
      }
    }
    return warnings
  }
}

/// One per malformed forward-compat v2 section. Surfaced by
/// `Profile.sectionWarnings()` and aggregated by `ProfileStore`.
public struct ProfileSectionWarning: Equatable, Sendable, CustomStringConvertible {
  public let section: String
  public let message: String

  public init(section: String, message: String) {
    self.section = section
    self.message = message
  }

  public var description: String {
    "[\(section)] \(message)"
  }
}
