import Foundation

/// A readable error for anything the engine refuses to do (shown as-is in the UI and the CLI).
public struct EngineError: LocalizedError, CustomStringConvertible, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Postiz's shared YouTube upload quota (docs/postiz.md): Google resets it at midnight Pacific time (00:00
/// America/Los_Angeles, so 07:00 UTC in summer and 08:00 UTC in winter), and it is often gone hours before. Nothing on
/// YouTube is scheduled in the quiet window, 19:00 up to midnight Pacific; it goes at 00:30 Pacific instead. Every rule
/// here reads the Pacific wall clock, so it holds across both DST changes (round 22: the old fixed 07:00 UTC landed every
/// winter retry at 23:30 Pacific, on the day whose quota was gone).
public enum YouTubeWindow {
  public static let pacific = TimeZone(identifier: "America/Los_Angeles")!

  /// Pacific clock: the window starts here (minutes after midnight) and runs to midnight, the reset.
  static let quietStartMinutes = 19 * 60
  /// Pacific clock: where the window sends a time, 30 minutes after the reset.
  static let movedMinutes = 30

  static var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = pacific
    return c
  }

  /// The Pacific wall clock in minutes (seconds kept as a fraction): 19:00 is 19:00 on a 23- or 25-hour day too.
  private static func pacificMinutes(_ d: Date) -> Double {
    let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
    return Double(c.hour! * 60 + c.minute!) + (Double(c.second!) + Double(c.nanosecond!) / 1e9) / 60
  }

  static func isQuiet(_ d: Date) -> Bool { pacificMinutes(d) >= Double(quietStartMinutes) }

  /// `d` is 00:30 Pacific, where the window sends a time.
  public static func isMoved(_ d: Date) -> Bool { abs(pacificMinutes(d) - Double(movedMinutes)) < 1.0 / 120 }

  /// The Pacific midnight that starts `d`'s quota day.
  static func dayStart(_ d: Date) -> Date { calendar.startOfDay(for: d) }

  /// The first Pacific midnight after `d`: when the quota comes back. (Midnight is never inside a US clock change.)
  public static func nextReset(after d: Date) -> Date {
    let c = calendar
    return c.date(byAdding: .day, value: 1, to: c.startOfDay(for: d)) ?? dayStart(d).addingTimeInterval(86400)
  }

  /// The first 00:30 Pacific after `d`.
  public static func nextSafe(after d: Date) -> Date {
    let today = dayStart(d).addingTimeInterval(Double(movedMinutes) * 60)
    return today > d ? today : nextReset(after: d).addingTimeInterval(Double(movedMinutes) * 60)
  }

  /// The one rule, for slot times and retries alike: `d`, unless that's a YouTube time inside the quiet window.
  public static func clear(_ d: Date, _ p: Platform) -> Date {
    p == .youtube && isQuiet(d) ? nextSafe(after: d) : d
  }

  /// The same 00:30 Pacific `days` Pacific days later: a moved post stays moved across a DST change.
  static func shiftMoved(_ d: Date, days: Int) -> Date {
    calendar.date(byAdding: .day, value: days, to: d) ?? d.addingTimeInterval(Double(days) * 86400)
  }

  /// Settings → Slot times and `djq slot youtube`, in Eric's own clock: "10 pm–3 am moves to 3:30 am: Postiz's YouTube
  /// quota resets at midnight Pacific." `on` picks the day (the offset to Pacific changes for a few weeks a year).
  public static func settingsNote(_ tz: TimeZone, on day: Date = Date()) -> String {
    let start = dayStart(day)
    let from = start.addingTimeInterval(Double(quietStartMinutes) * 60)
    let to = nextReset(after: day)
    let moved = to.addingTimeInterval(Double(movedMinutes) * 60)
    func t(_ d: Date) -> String {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = tz
      f.amSymbol = "am"
      f.pmSymbol = "pm"
      f.dateFormat = Calendar(identifier: .gregorian).dateComponents(in: tz, from: d).minute == 0 ? "h a" : "h:mm a"
      return f.string(from: d)
    }
    return "\(t(from))–\(t(to)) moves to \(t(moved)): Postiz's YouTube quota resets at midnight Pacific."
  }
}

extension DayMath {
  /// The plan day of a regular post at `at`: the day its slot time counts from. It isn't always the local day: with 3 posts
  /// a day and a 180-minute offset, position 2 of Thursday's slot posts at 00:00 Friday on Instagram. A night slot the quiet
  /// window moved past midnight counts for the day before, unless its plan slot says otherwise. That comes from the post's
  /// own slot and never the current setting: the setting can change while the post stays.
  public func planDay(_ at: Date, position: Int, slotDate: String?, platform: Platform, offsetMinutes: Int) -> String {
    let day = key(at.addingTimeInterval(-Double(position * offsetMinutes) * 60))
    guard platform == .youtube, YouTubeWindow.isMoved(at), let slotDate else { return day }
    let local = key(at)
    return slotDate == local ? day : addDays(local, -1)
  }
}

extension Settings {
  /// When a regular post goes out: platform slot + position × second-post offset, on a local day, out of YouTube's quiet window.
  public func slotTime(_ p: Platform, date: String, position: Int, _ dm: DayMath) -> Date {
    YouTubeWindow.clear(dm.at(date, minutes: slot(for: p) + position * secondPostOffsetMinutes), p)
  }
}

/// Post-time arithmetic shared by the planner, post actions and the engine.
enum Sched {
  /// Regular slot time.
  static func slotTime(_ settings: Settings, _ dm: DayMath, date: String, position: Int, platform: Platform) -> Date {
    settings.slotTime(platform, date: date, position: position, dm)
  }

  /// Same local clock time `days` calendar days later (DST-safe).
  static func shift(_ d: Date, days: Int, _ dm: DayMath) -> Date {
    dm.calendar.date(byAdding: .day, value: days, to: d) ?? d.addingTimeInterval(Double(days) * 86400)
  }

  /// `shift` for a platform's post: the local clock, out of the quiet window. 00:30 Pacific stays 00:30 Pacific, because
  /// a local clock would walk off it across a DST change that isn't Pacific's (or on the few days the two differ).
  static func shift(_ d: Date, days: Int, platform p: Platform, _ dm: DayMath) -> Date {
    p == .youtube && YouTubeWindow.isMoved(d) ? YouTubeWindow.shiftMoved(d, days: days) : YouTubeWindow.clear(shift(d, days: days, dm), p)
  }

  /// A time on `day` for an extra post (retry / repost) on `platform`: that day's regular slot time
  /// staggered by ≥ `retryStaggerHours` from every other post on that platform that day.
  /// Tries +3 h first; if that crosses midnight, −3 h; then +6 h, −6 h, … A time in YouTube's quiet window is no candidate.
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
      guard t >= start, t < end, YouTubeWindow.clear(t, p) == t else { continue }
      if taken.allSatisfy({ abs($0.timeIntervalSince(t)) >= gap - 1 }) { return t }
    }
    let up = base.addingTimeInterval(gap)
    return YouTubeWindow.clear(up < end ? up : base.addingTimeInterval(-gap), p)
  }

  /// When an automatic retry due at `target` goes out: `target`, or the nearest time at least `retryStaggerHours` from
  /// every other post on the platform that went out or still will (a failed or skipped post went nowhere, and a retry
  /// must not keep its distance from its own failure). With `earliest` it looks earlier first, down to that time, then
  /// later. It never lands in YouTube's quiet window.
  static func retrySlot(store: Store, platform p: Platform, target: Date, earliest: Date? = nil, settings: Settings,
                        excluding: Set<String> = []) throws -> Date {
    let gap = max(1, settings.retryStaggerHours) * 3600
    let others = try store.posts(where: "platform=? AND state NOT IN ('skipped','failed','copyright_blocked','copyright_muted','removed')",
                                 [p.rawValue])
      .filter { !excluding.contains($0.id) }.map { $0.postedAt ?? $0.scheduledAt }.sorted()
    func clash(_ t: Date) -> Date? { others.first { abs($0.timeIntervalSince(t)) < gap - 1 } }
    let target = YouTubeWindow.clear(target, p)
    guard clash(target) != nil else { return target }
    if let earliest {
      var t = target
      while let c = clash(t) {
        t = c.addingTimeInterval(-gap)
        if t < earliest { break }
      }
      if t >= earliest, clash(t) == nil, YouTubeWindow.clear(t, p) == t { return t }
    }
    var t = target
    while let c = clash(t) { t = YouTubeWindow.clear(c.addingTimeInterval(gap), p) }
    return t
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

  /// "Thu 8:00 am".
  static func retryDay(_ d: Date, _ settings: Settings) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = settings.tz
    f.amSymbol = "am"
    f.pmSymbol = "pm"
    f.dateFormat = "EEE h:mm a"
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


/// Occupancy of live regular posts per (platform, plan day, position) — the "never double-post" invariant. Keyed by plan
/// day (`DayMath.planDay`), never the local posting day: `place` reserves plan days, and a post past midnight must count
/// for the day it was placed on, or a later Placer sees the wrong day free.
/// Live = not terminal, or posted. Retries/reposts are staggered extras and don't occupy a position, and neither does a
/// set-time post (round 21): it sits outside the cadence, so it never blocks or shifts a regular post.
struct Placer {
  let dm: DayMath
  private(set) var taken: Set<String> = []

  init(store: Store, dm: DayMath, excluding: Set<String> = []) throws {
    self.dm = dm
    let slots = Dictionary(uniqueKeysWithValues: try store.planSlots().map { ($0.id, $0) })
    let offset = try store.settings().secondPostOffsetMinutes
    let postedNow = try store.postNowIds()
    for p in try store.posts(where: "kind='regular'") where !excluding.contains(p.id) && Self.isLive(p) {
      let slot = slots[p.planSlotId ?? ""]
      if slot?.isExact == true { continue }
      let pos = slot?.position ?? 0
      let day = postedNow.contains(p.id) ? dm.key(p.scheduledAt)
        : dm.planDay(p.scheduledAt, position: pos, slotDate: slot?.date, platform: p.platform, offsetMinutes: offset)
      taken.insert(Self.key(p.platform, day, pos))
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
  /// Round 22: YouTube posts still to go whose time sits in the quiet window move out of it, to 00:30 Pacific. Posts
  /// stored under the old fixed 07:00 UTC rule land there (07:30 UTC is 23:30 Pacific in winter). Pinned and set-time
  /// posts too: the window has always applied to every YouTube time (`clear`), pins included. An automatic retry or a
  /// repost keeps the stagger gap from the platform's other posts. The publish step then moves Postiz's copy. Returns
  /// how many moved.
  @discardableResult
  public func moveOutOfYouTubeWindow() throws -> Int {
    let now = clock.now
    let candidates = try posts(where: "platform='youtube' AND state IN ('planned','rendering','rendered') AND scheduled_at>?", [now])
      .filter { YouTubeWindow.clear($0.scheduledAt, .youtube) != $0.scheduledAt }
      .sorted { ($0.kind == .regular ? 0 : 1, $0.scheduledAt) < ($1.kind == .regular ? 0 : 1, $1.scheduledAt) }
    guard !candidates.isEmpty else { return 0 }
    let s = try settings()
    var n = 0
    for c in candidates {
      try db.transaction {
        guard var p = try post(id: c.id), ["planned", "rendering", "rendered"].contains(p.state.rawValue), p.scheduledAt > now,
              YouTubeWindow.clear(p.scheduledAt, .youtube) != p.scheduledAt else { return }
        let out = YouTubeWindow.clear(p.scheduledAt, .youtube)
        p.scheduledAt = p.kind == .regular ? out
          : try Sched.retrySlot(store: self, platform: .youtube, target: out, settings: s, excluding: [p.id])
        try save(p, note: "out of YouTube's quiet window → \(Sched.shortTime(p.scheduledAt, s))")
        n += 1
      }
    }
    if n > 0 {
      try logEvent("plan", "\(n) YouTube post\(n == 1 ? "" : "s") moved out of the quiet window: Postiz's YouTube quota resets at midnight Pacific")
    }
    return n
  }

  /// The plan position of a post (its slot's position; 0 when it has no slot).
  func position(of p: PlatformPost) throws -> Int {
    try p.planSlotId.flatMap { try planSlot(id: $0)?.position } ?? 0
  }

  /// The plan day of a regular post (`DayMath.planDay`). Post now holds its local day: its time is the moment Eric pressed
  /// it, not a slot time, so it says nothing about a plan day. A set-time post's plan day is its slot's date: its time
  /// isn't a slot time either, and its position (100 and up) times the offset would land days away.
  func planDay(of p: PlatformPost, dm: DayMath) throws -> String {
    if try postNowIds().contains(p.id) { return dm.key(p.scheduledAt) }
    let slot = try p.planSlotId.flatMap { try planSlot(id: $0) }
    if let slot, slot.isExact { return slot.date }
    return dm.planDay(p.scheduledAt, position: slot?.position ?? 0, slotDate: slot?.date, platform: p.platform,
                      offsetMinutes: try settings().secondPostOffsetMinutes)
  }

  /// Regular posts still at the time Post now gave them (a shift or a reset puts a post back on a slot time).
  func postNowIds() throws -> Set<String> {
    Set(try db.query("""
      SELECT DISTINCT h.post_id AS id FROM post_history h JOIN platform_posts p ON p.id=h.post_id
      WHERE h.note='post now' AND p.kind='regular' AND p.state IN ('due','overdue','posted')
      """).compactMap { $0.string("id") })
  }
}

extension Store {
  /// Regular posts of a platform at a plan position that a plan shift may move: un-posted, not overdue, and not
  /// belonging to a pinned slot (a pinned video never moves — Eric's decision) or a set-time one (always pinned).
  func movablePosts(platform: Platform, position: Int, after: Date, inclusive: Bool = false, excluding id: String) throws -> [PlatformPost] {
    let pinned = Set(try planSlots(where: "pinned=1 OR exact_at IS NOT NULL").map(\.id))
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
      let from = try planDay(of: o, dm: dm)
      let to = placer.place(o.platform, position: pos, from: dm.addDays(from, days))
      let delta = dm.days(from: from, to: to)
      guard delta != 0 else { continue }
      o.scheduledAt = Sched.shift(o.scheduledAt, days: delta, platform: o.platform, dm)
      if o.state == .due { o.state = o.renderId == nil ? .planned : .rendered }
      try save(o, note: "\(note) → \(to)")
      moved += 1
    }
    return moved
  }
}
