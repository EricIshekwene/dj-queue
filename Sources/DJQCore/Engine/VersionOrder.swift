import Foundation

/// Round 35 (DECISIONS-R35.md): the order a clip's versions post in. By default the planner posts v1, v2, v3, … (every
/// version's first post before any repeat, `PostUnit` order); Eric can put any version first, per clip ("v2, then v1,
/// then v3"). The order only says which version goes out next: spacing, counts and days are unchanged.
///
/// Stored in kv `plan.versionOrder` as `[videoId: [version numbers]]`, only for clips whose order isn't the plain one.
/// It's planning data, not part of how a version looks, so setting it never touches a version or the clip's edit (no
/// preview or render changes). A version missing from the stored list (a newer one) posts after the listed ones, in
/// number order; a deleted version's number is simply skipped.
public enum VersionOrder {
  public static let key = "plan.versionOrder"

  /// `order` cleaned against the versions the clip has: each listed number once, unknown ones dropped, the rest
  /// after them in number order.
  public static func normalized(_ order: [Int], versions: [Int]) -> [Int] {
    let have = Set(versions)
    var seen = Set<Int>()
    let listed = order.filter { have.contains($0) && seen.insert($0).inserted }
    return listed + versions.sorted().filter { !seen.contains($0) }
  }

  /// Where version `n` posts in `order` (unlisted versions after every listed one, by number).
  public static func rank(_ n: Int, in order: [Int]) -> Int { order.firstIndex(of: n) ?? (order.count + n) }

  /// Planning order of two units of one clip: first posts before repeats (as always), then the clip's version order.
  public static func precedes(_ a: PostUnit, _ b: PostUnit, order: [Int]) -> Bool {
    if a.post != b.post { return a.post < b.post }
    return (rank(a.version, in: order), a.version) < (rank(b.version, in: order), b.version)
  }

  /// "v2, then v1, then v3".
  public static func text(_ order: [Int]) -> String { order.map { "v\($0)" }.joined(separator: ", then ") }

  /// "1st", "2nd", "3rd", "4th", …
  public static func ordinal(_ n: Int) -> String {
    let tens = (n / 10) % 10, ones = n % 10
    let suffix = tens == 1 ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th"
    return "\(n)\(suffix)"
  }
}

extension Store {
  /// Every stored order (clips with the plain order aren't listed).
  public func versionOrders() throws -> [String: [Int]] { (try? kv(VersionOrder.key, as: [String: [Int]].self)) ?? [:] }

  /// The clip's version numbers in posting order (v1 alone for a clip with no version rows).
  public func versionOrder(videoId: String) throws -> [Int] {
    let numbers = Set(try versions(videoId: videoId).map(\.number)).union([1])
    return VersionOrder.normalized(try versionOrders()[videoId] ?? [], versions: Array(numbers))
  }

  /// True when Eric chose an order for this clip (it isn't the plain v1, v2, v3, …).
  public func hasOwnVersionOrder(videoId: String) throws -> Bool {
    let order = try versionOrder(videoId: videoId)
    return order != order.sorted()
  }

  /// Sets the clip's posting order (nil or the plain order = back to number order). Versions already on the calendar
  /// swap which version they carry so the next days follow the new order (`Planner.applyVersionOrder`); a day whose
  /// posts are already in Postiz, posted or going out within the hour keeps its version. Returns false when nothing
  /// changed.
  @discardableResult
  public func setVersionOrder(videoId: String, _ order: [Int]?) throws -> Bool {
    guard let v = try video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form: long-form has one version") }
    let numbers = Array(Set(try versions(videoId: videoId).map(\.number)).union([1]))
    if let order {
      if let bad = order.first(where: { !numbers.contains($0) }) { throw EngineError("\(v.tag) has no v\(bad)") }
      if Set(order).count != order.count { throw EngineError("Each version once, e.g. 2,1,3") }
    }
    let new = VersionOrder.normalized(order ?? [], versions: numbers)
    let old = try versionOrder(videoId: videoId)
    guard new != old else { return false }
    try db.transaction {
      var all = try versionOrders()
      all[videoId] = new == new.sorted() ? nil : new
      try setKV(VersionOrder.key, all)
      try logEvent("version", "Posting order: \(VersionOrder.text(new))", videoId: videoId)
      try Planner(store: self).applyVersionOrder(videoId: videoId)
      try refreshState(videoId: videoId)
    }
    return true
  }
}

extension Planner {
  /// Round 35: after a clip's version order changed, its days on the calendar carry the units the new order puts first.
  /// Only days that can still change move: from today on, no set time, nothing posted, every post untouched (planned or
  /// rendered), not in Postiz and an hour or more away. Those days keep their date and position (pinned ones stay pinned);
  /// only which version post they carry changes, and their posts are made again for it. A day that would put one version
  /// closer than `sameVersionGapDays` to another post of it comes off the calendar instead, and the next pass gives that
  /// version post a day that fits. Returns the slots that changed.
  @discardableResult
  public func applyVersionOrder(videoId: String) throws -> Int {
    let now = store.clock.now
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    guard let v = try store.video(id: videoId), v.type == .short else { return 0 }
    let book = try UnitBook(store: store, settings: settings, videos: [v])
    guard let clip = book[videoId] else { return 0 }
    let today = dm.key(now)
    let slots = try store.planSlots(where: "video_id=?", [videoId]).sorted { ($0.date, $0.position) < ($1.date, $1.position) }
    // A day that can still change: after today, no set time, every post only of this clip, and movable by the relay's
    // own rule (`isMovable`: nothing posted, every live post untouched, an hour or more away and not final in Postiz).
    // A day another clip shares (a platform's own sort order put it there) stays as it is.
    func free(_ s: PlanSlot) throws -> Bool {
      guard s.date > today, !s.isExact else { return false }
      guard try store.slotPosts(s.id).allSatisfy({ $0.videoId == videoId }) else { return false }
      return try isMovable(s, now: now)
    }
    var movable: [PlanSlot] = []
    var fixed: [PlanSlot] = []
    for s in slots { if try free(s) { movable.append(s) } else { fixed.append(s) } }
    guard !movable.isEmpty else { return 0 }
    let movableIds = Set(movable.map(\.id))
    // Units that stay where they are: the fixed days'. A unit with a post somewhere else (a repost with no day, say) can
    // still take a movable day; `createPosts` skips the platforms that already have it.
    let held = Set(fixed.map(\.unit))
    var days: [(version: Int, day: String)] = fixed.map { ($0.versionNo, $0.date) }
    for p in try store.posts(where: "video_id=?", [videoId]) where !movableIds.contains(p.planSlotId ?? "") && p.planSlotId == nil {
      if p.state == .posted || !p.state.isTerminal { days.append((p.versionNo, dm.key(p.postedAt ?? p.scheduledAt))) }
    }
    // The units the movable days carry now are exactly the ones to share out again, plus any the clip still needs.
    let onMovable = Set(movable.map(\.unit))
    let wanted = clip.all.filter { !held.contains($0) && (onMovable.contains($0) || clip.needsPost($0, on: settings.activePlatforms)) }
    let gap = max(1, settings.sameVersionGapDays)
    var changed = 0
    var remaining = wanted
    var toRegenerate: [PlanSlot] = []
    for var s in movable {
      // The first unit in the new order that keeps its version far enough from its other posts.
      let fits = remaining.firstIndex { u in !days.contains { $0.version == u.version && abs(dm.days(from: $0.day, to: s.date)) < gap } }
      // A day Eric pinned keeps its place: it takes the next unit even when that's a little close to its other post, and
      // keeps what it has when nothing is left to give it.
      if s.pinned && remaining.isEmpty {
        days.append((s.versionNo, s.date))
        continue
      }
      guard let i = fits ?? (s.pinned ? 0 : nil) else {
        // Nothing fits this day: it comes off, and the next pass gives the unit it carried a day that fits.
        try clearSlot(s)
        try store.deletePlanSlot(s.id)
        try store.logEvent("plan", "\(BulkActions.day(s.date, dm, settings)): \(book.label(videoId, s.unit)) taken off to keep the posting order", videoId: videoId)
        changed += 1
        continue
      }
      let unit = remaining.remove(at: i)
      days.append((unit.version, s.date))
      guard unit != s.unit else { continue }
      let was = s.unit
      let hadPosts = try !store.slotPosts(s.id).isEmpty
      try clearSlot(s)
      s.unit = unit
      try store.save(s)
      if hadPosts { toRegenerate.append(s) }
      try store.logEvent("plan", "\(BulkActions.day(s.date, dm, settings)): \(book.label(videoId, unit)) instead of \(book.label(videoId, was)) (posting order)", videoId: videoId)
      changed += 1
    }
    if !toRegenerate.isEmpty {
      var picker = PlatformPicker(queue: queue, settings: settings)
      var placer = try Placer(store: store, dm: dm)
      for s in toRegenerate {
        try createPosts(s, settings: settings, dm: dm, picker: &picker, placer: &placer, note: "posting order",
                        notBefore: now.addingTimeInterval(Self.autoScheduleLead), pullForHistory: false)
        // Like the fill: a day that ended up with no post (every platform already has that version post) comes off, or
        // it would hold the clip on Scheduled for good. The next pass gives its unit a day if one still needs it.
        if !s.pinned, try store.slotPosts(s.id).isEmpty {
          try store.deletePlanSlot(s.id)
          try store.logEvent("plan", "\(BulkActions.day(s.date, dm, settings)): \(book.label(videoId, s.unit)) has nothing left to post there, taken off", videoId: videoId)
        }
      }
    }
    try store.refreshState(videoId: videoId)
    return changed
  }
}

/// Round 35: what the editor's version list says about when a version posts. One line, no platform list (Eric:
/// "you can just say planned to post"): the version's next post time, or why it has none.
public enum VersionPlanLine {
  /// The line for version `number`. `posts`/`slots` are the clip's, `pending` its version posts still waiting for a day,
  /// `count` how many times the version posts, `inQueue` whether the clip is in the Queue (only Queue clips get days).
  public static func text(number: Int, posts: [PlatformPost], slots: [PlanSlot], pending: [PostUnit], count: Int,
                          inQueue: Bool, now: Date, settings: Settings) -> String {
    let dm = DayMath(settings: settings)
    let today = dm.key(now)
    // When each still-to-come post of this version goes out: its earliest live platform post, else its slot's day.
    var times: [PostUnit: Date] = [:]
    for p in posts where p.versionNo == number && !p.state.isTerminal {
      times[p.unit] = min(times[p.unit] ?? p.scheduledAt, p.scheduledAt)
    }
    var dayOnly: Set<PostUnit> = []
    for s in slots where s.versionNo == number && s.date >= today && times[s.unit] == nil {
      times[s.unit] = s.exactAt ?? dm.date(s.date)
      if s.exactAt == nil { dayOnly.insert(s.unit) }
    }
    let upcoming = times.sorted { $0.value < $1.value }
    if let first = upcoming.first {
      let when = dayOnly.contains(first.key) ? day(first.value, settings) : Sched.shortTime(first.value, settings)
      var line = "Planned to post \(when)"
      if upcoming.count > 1 { line += " · again \(day(upcoming[1].value, settings))" }
      return line
    }
    if count == 0 { return "Doesn't post (Posts: Never)" }
    if pending.contains(where: { $0.version == number }) {
      return inQueue ? "Waiting for a day in the Queue" : "Not planned yet: plans once the clip is in the Queue"
    }
    let posted = posts.contains { $0.versionNo == number && $0.state == .posted }
    return posted ? "Every post of it went out" : "Not planned yet"
  }

  /// "Thu 26 Nov".
  static func day(_ d: Date, _ s: Settings) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = s.tz
    f.dateFormat = "EEE d MMM"
    return f.string(from: d)
  }
}
