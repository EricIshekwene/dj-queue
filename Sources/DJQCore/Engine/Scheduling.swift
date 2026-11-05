import Foundation

/// A readable error for anything the engine refuses to do (shown as-is in the UI and the CLI).
public struct EngineError: LocalizedError, CustomStringConvertible, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Post-time arithmetic shared by the planner, post actions and the engine.
enum Sched {
  /// Regular slot time: platform slot + position × second-post offset, on a local day.
  static func slotTime(_ settings: Settings, _ dm: DayMath, date: String, position: Int, platform: Platform) -> Date {
    dm.at(date, minutes: settings.slot(for: platform) + position * settings.secondPostOffsetMinutes)
  }

  /// Same local clock time `days` calendar days later (DST-safe).
  static func shift(_ d: Date, days: Int, _ dm: DayMath) -> Date {
    dm.calendar.date(byAdding: .day, value: days, to: d) ?? d.addingTimeInterval(Double(days) * 86400)
  }

  /// A time on `day` for an extra post (retry / repost) on `platform`: that day's regular slot time
  /// staggered by ≥ `retryStaggerHours` from every other post on that platform that day.
  /// Tries +3 h first; if that crosses midnight, −3 h; then +6 h, −6 h, …
  static func staggered(store: Store, platform p: Platform, day: String, settings: Settings, dm: DayMath,
                        excluding: Set<String> = []) throws -> Date {
    let base = dm.at(day, minutes: settings.slot(for: p))
    let gap = max(1, settings.retryStaggerHours) * 3600
    let start = dm.date(day), end = dm.date(dm.addDays(day, 1))
    let others = try store.posts(where: "platform=? AND scheduled_at>=? AND scheduled_at<? AND state<>'skipped'",
                                 [p.rawValue, start, end])
      .filter { !excluding.contains($0.id) }.map(\.scheduledAt)
    let taken = others + [base]
    for k in [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7] {
      let t = base.addingTimeInterval(Double(k) * gap)
      guard t >= start, t < end else { continue }
      if taken.allSatisfy({ abs($0.timeIntervalSince(t)) >= gap - 1 }) { return t }
    }
    let up = base.addingTimeInterval(gap)
    return up < end ? up : base.addingTimeInterval(-gap)
  }

  /// "2 h late" / "40 min late".
  static func lateText(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m < 60 ? "\(max(1, m)) min late" : "\(m / 60) h late"
  }

  static func shortTime(_ d: Date, _ settings: Settings) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = settings.tz
    f.dateFormat = "EEE d MMM h:mm a"
    return f.string(from: d)
  }

  static func clock(_ d: Date, _ settings: Settings) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = settings.tz
    f.dateFormat = "HH:mm"
    return f.string(from: d)
  }
}

extension Store {
  func dayMath(_ s: Settings? = nil) throws -> DayMath { DayMath(settings: try s ?? settings()) }

  func today(_ dm: DayMath) -> String { dm.key(clock.now) }

  func planSlot(id: String) throws -> PlanSlot? { try planSlots(where: "id=?", [id]).first }

  func slotPosts(_ slotId: String) throws -> [PlatformPost] { try posts(where: "plan_slot_id=?", [slotId]) }

  /// Regular/retry posts (not reposts) of a video on a platform — "has it been planned or posted there?".
  func platformHistory(videoId: String, platform: Platform) throws -> [PlatformPost] {
    try posts(where: "video_id=? AND platform=? AND kind IN ('regular','retry')", [videoId, platform.rawValue])
  }

  func nextAttemptNo(videoId: String, platform: Platform) throws -> Int {
    (try db.one("SELECT MAX(attempt_no) AS m FROM platform_posts WHERE video_id=? AND platform=?",
                [videoId, platform.rawValue])?.int("m") ?? 0) + 1
  }

  func sessionName(for v: Video) throws -> String { try session(id: v.sessionId)?.name ?? "" }

  /// Round 6 (F5): slots on a day before `today` in a draft week that never got a post (pinned or not). They can't
  /// post any more; left in place they would keep their clip out of the queue for good.
  public func stalePastDraftSlots(today: String) throws -> [PlanSlot] {
    try planSlots(where: "date<? AND week_start NOT IN (SELECT week_start FROM weeks WHERE state='approved') "
                    + "AND id NOT IN (SELECT plan_slot_id FROM platform_posts WHERE plan_slot_id IS NOT NULL)", [today])
  }

  /// Deletes `stalePastDraftSlots` (only `week`'s when given), each with a "Past day … dropped" event.
  @discardableResult
  public func dropStalePastDraftSlots(today: String, week: String? = nil) throws -> [PlanSlot] {
    try db.transaction {
      let list = try stalePastDraftSlots(today: today).filter { week == nil || $0.weekStart == week }
      for s in list {
        try deletePlanSlot(s.id)
        try refreshState(videoId: s.videoId)
        try logEvent("plan", "Past day \(s.date) dropped (it never got posts)\(s.pinned ? ", pin removed" : "") — back in the Queue",
                     videoId: s.videoId)
      }
      return list
    }
  }
}


/// Occupancy of live regular posts per (platform, local day, position) — the "never double-post" invariant.
/// Live = not terminal, or posted. Retries/reposts are staggered extras and don't occupy a position.
struct Placer {
  let dm: DayMath
  private(set) var taken: Set<String> = []

  init(store: Store, dm: DayMath, excluding: Set<String> = []) throws {
    self.dm = dm
    let positions = Dictionary(uniqueKeysWithValues: try store.planSlots().map { ($0.id, $0.position) })
    for p in try store.posts(where: "kind='regular'") where !excluding.contains(p.id) && Self.isLive(p) {
      taken.insert(Self.key(p.platform, dm.key(p.scheduledAt), positions[p.planSlotId ?? ""] ?? 0))
    }
  }

  static func isLive(_ p: PlatformPost) -> Bool { p.state == .posted || !p.state.isTerminal }
  static func key(_ p: Platform, _ day: String, _ pos: Int) -> String { "\(p.rawValue)#\(day)#\(pos)" }

  func isTaken(_ p: Platform, day: String, position: Int) -> Bool { taken.contains(Self.key(p, day, position)) }

  /// Reserves and returns the first day ≥ `day` that is free for the platform at that position.
  mutating func place(_ p: Platform, position: Int, from day: String) -> String {
    var d = day
    while taken.contains(Self.key(p, d, position)) { d = dm.addDays(d, 1) }
    taken.insert(Self.key(p, d, position))
    return d
  }
}

extension Store {
  /// The plan position of a post (its slot's position; 0 when it has no slot).
  func position(of p: PlatformPost) throws -> Int {
    try p.planSlotId.flatMap { try planSlot(id: $0)?.position } ?? 0
  }
}

extension Store {
  /// Regular posts of a platform at a plan position that a plan shift may move: un-posted, not overdue, and not
  /// belonging to a pinned slot (a pinned video never moves — Eric's decision).
  func movablePosts(platform: Platform, position: Int, after: Date, inclusive: Bool = false, excluding id: String) throws -> [PlatformPost] {
    let pinned = Set(try planSlots(where: "pinned=1").map(\.id))
    return try posts(where: "platform=? AND kind='regular' AND id<>? AND scheduled_at\(inclusive ? ">=" : ">")?",
                     [platform.rawValue, id, after])
      .filter { !$0.state.isTerminal && $0.state != .overdue && !pinned.contains($0.planSlotId ?? "") }
      .filter { (try? self.position(of: $0)) == position }
  }

  /// Moves `posts` (one platform, one position) by `days`, earliest first, each to the first day ≥ its target that
  /// has no other live regular post there — so they flow around pinned and posted days, never onto them.
  /// `reserve` days are kept free (e.g. today for a post being shifted in). Returns how many moved.
  @discardableResult
  func reflow(_ posts: [PlatformPost], days: Int, reserve: [String] = [], dm: DayMath, note: String) throws -> Int {
    guard let first = posts.first else { return 0 }
    var placer = try Placer(store: self, dm: dm, excluding: Set(posts.map(\.id)))
    let pos = try position(of: first)
    for d in reserve { _ = placer.place(first.platform, position: pos, from: d) }
    var moved = 0
    for var o in posts.sorted(by: { $0.scheduledAt < $1.scheduledAt }) {
      let from = dm.key(o.scheduledAt)
      let to = placer.place(o.platform, position: pos, from: dm.addDays(from, days))
      let delta = dm.days(from: from, to: to)
      guard delta != 0 else { continue }
      o.scheduledAt = Sched.shift(o.scheduledAt, days: delta, dm)
      if o.state == .due { o.state = o.renderId == nil ? .planned : .rendered }
      try save(o, note: "\(note) → \(to)")
      moved += 1
    }
    return moved
  }
}
