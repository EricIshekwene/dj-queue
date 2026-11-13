import Foundation

/// Round 31 (DECISIONS-R31.md): where each version post of a clip stands, as the Queue card and the Calendar show it.
/// Read from a `UnitBook` and the clip's upcoming slots, off the main thread with every refresh.
public struct UnitLine: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// Has a day from today on (its earliest).
    case day(String)
    /// Waits for a day.
    case waiting
    /// Nothing left to do on any platform (posted, on its way, or skipped).
    case done
  }

  public var unit: PostUnit
  /// "v2 · 1 of 2".
  public var label: String
  public var state: State

  public init(unit: PostUnit, label: String, state: State) {
    self.unit = unit
    self.label = label
    self.state = state
  }
}

extension UnitBook {
  /// Every version post of clip `id`, in planning order, and where it stands. `upcoming`: the clip's slots from today on
  /// (other clips' slots are ignored). Empty for a clip the book doesn't know (long-form, not loaded).
  public func lines(_ id: String, upcoming: [PlanSlot]) -> [UnitLine] {
    guard let c = self[id] else { return [] }
    let pending = Set(c.pending(settings.activePlatforms))
    var day: [PostUnit: String] = [:]
    for s in upcoming where s.videoId == id {
      if let had = day[s.unit], had <= s.date { continue }
      day[s.unit] = s.date
    }
    return c.all.map { u in
      let state: UnitLine.State = day[u].map { .day($0) } ?? (pending.contains(u) ? .waiting : .done)
      return UnitLine(unit: u, label: label(id, u), state: state)
    }
  }
}

/// The Queue card's words for a clip's version posts (round 31): the next one rides on the date chip, the others are
/// small tags in planning order with their day, "waiting" or "done".
public enum UnitLines {
  /// The most tags a Queue card shows before "+N" (fewer when the line is narrower).
  public static let cap = 4

  /// Every line but `next` (the one on the date chip), at most `cap`, and how many are left out.
  public static func others(_ lines: [UnitLine], next: PostUnit?, cap: Int = cap) -> (shown: [UnitLine], more: Int) {
    let rest = lines.filter { $0.unit != next }
    let shown = Array(rest.prefix(max(0, cap)))
    return (shown, rest.count - shown.count)
  }

  /// "v2 · 1 of 2 · Sat 16" · "v1 · 2 of 2 · waiting" · "v1 · 1 of 2 · done". `day` formats a day key.
  public static func tagText(_ l: UnitLine, day: (String) -> String) -> String {
    switch l.state {
    case .day(let d): return "\(l.label) · \(day(d))"
    case .waiting: return "\(l.label) · waiting"
    case .done: return "\(l.label) · done"
    }
  }

  /// What a tag means on hover.
  public static func tagHelp(_ l: UnitLine, day: (String) -> String) -> String {
    let what = meaning(l.unit, label: l.label)
    switch l.state {
    case .day(let d): return "\(what) goes out \(day(d))"
    case .waiting: return "\(what) is waiting for a day: it gets one by itself, spaced from this clip's other posts"
    case .done: return "\(what) is done on every platform (posted, on its way, or skipped)"
    }
  }

  /// "Version 2, post 1 of 2" (the post count is per platform).
  public static func meaning(_ u: PostUnit, label: String) -> String {
    label.contains(" of ") ? "Version \(u.version), post \(u.post) of \(label.split(separator: " ").last ?? "1")" : "Version \(u.version)"
  }

  /// The date chip with the unit going out that day: "Thu 14 Nov · v1 · 1 of 2".
  public static func dateText(_ date: String, unit: String?) -> String {
    guard let unit, !unit.isEmpty else { return date }
    return "\(date) · \(unit)"
  }
}
