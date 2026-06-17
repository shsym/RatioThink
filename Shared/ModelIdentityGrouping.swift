import Foundation

/// Dedup + group a model list by structured identity (#580). One pure,
/// generic helper reused by every surface that lists models — the chat
/// dropdown, the Settings installed table, and the profile picker — so the
/// three can never disagree on what counts as "the same model" or how a
/// family clusters.
///
/// Keyed off `ModelNameParts`: `identity` (the full resolvable slug, review
/// v2 F2) for dedup, `groupKey` (the prettified leaf base) for grouping.
/// Callers supply a `slug` accessor so the helper stays element-type agnostic.
public enum ModelIdentityGrouping {
  /// Dedup by `ModelNameParts.identity`, keeping the FIRST occurrence.
  /// Callers order app-managed entries before Hugging-Face-cache copies, so
  /// the app-managed row wins a true duplicate — matching the resolver's
  /// app-staged-first precedence (#580 Q1). Relative order is otherwise
  /// preserved.
  ///
  /// `prefer` breaks an identity tie: when a later duplicate satisfies it and
  /// the already-held element does not, the held element is upgraded IN PLACE
  /// (its slot, hence group order, is preserved). The chat menu passes
  /// `isCurrent` so that when an app-managed download and an HF-cache copy of
  /// the SAME resolvable slug collapse, the survivor is the current one — its
  /// slug matches the persisted selection, so the checkmark renders and a tap
  /// writes the persisted slug rather than the other copy's.
  public static func deduped<Item>(_ items: [Item],
                                   slug: (Item) -> String,
                                   prefer: ((Item) -> Bool)? = nil) -> [Item] {
    var slotByIdentity: [String: Int] = [:]
    var out: [Item] = []
    for item in items {
      let identity = ModelNameParts.parse(slug(item)).identity
      if let slot = slotByIdentity[identity] {
        if let prefer, prefer(item), !prefer(out[slot]) { out[slot] = item }
      } else {
        slotByIdentity[identity] = out.count
        out.append(item)
      }
    }
    return out
  }

  /// One base-name section: every quant of a family clustered under a
  /// single header (#580 #4).
  public struct Group<Item>: Identifiable {
    public let base: String
    public let items: [Item]
    public var id: String { base }

    public init(base: String, items: [Item]) {
      self.base = base
      self.items = items
    }
  }

  /// Group items by `ModelNameParts.groupKey` (the base name), preserving
  /// the first-seen order of both bases and the items within each base — so
  /// an upstream mtime/slug sort still decides ordering, grouping only
  /// clusters. Does NOT dedup; pass a `deduped(_:slug:)` result when both
  /// are wanted.
  public static func grouped<Item>(_ items: [Item],
                                   slug: (Item) -> String) -> [Group<Item>] {
    var order: [String] = []
    var buckets: [String: [Item]] = [:]
    for item in items {
      let base = ModelNameParts.parse(slug(item)).groupKey
      if buckets[base] == nil { order.append(base) }
      buckets[base, default: []].append(item)
    }
    return order.map { Group(base: $0, items: buckets[$0]!) }
  }
}
