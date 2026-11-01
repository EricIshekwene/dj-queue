import Foundation

/// Weekly plan (spec §5): propose → edit → approve. Only approved slots get PlatformPosts, and only posts ever post.
///
/// A slot counts as approved when its week is approved or it already has posts (e.g. it was pushed into a
/// draft week, or created by Post today). Any edit to an approved slot regenerates its un-posted posts.
///
/// Never double-post: every regular post is placed with `Placer` on the first day ≥ its intended date that has
/// no other live regular post for that platform and position, so per-platform shifts (missed days) survive
/// approvals, swaps, moves and pushes. Retries/reposts are extras staggered ≥ 3 h from that day's post.
public final class Planner: @unchecked Sendable {
  let store: Store
  lazy var queue = Queue(store: store)

  public init(store: Store) { self.store = store }

  public func weekStart(for date: Date) -> String {
    (try? store.dayMath())?.weekStart(of: date) ?? DayMath(settings: Settings()).weekStart(of: date)
  }

  public func slots(week: String) throws -> [PlanSlot] { try store.planSlots(where: "week_start=?", [week]) }

  public func week(_ weekStart: String) throws -> Week {
    try store.week(weekStart) ?? Week(weekStart: weekStart, state: .draft, approvedAt: nil)
  }

  /// True when the slot posts (its week is approved, or it has posts).
  public func isApproved(_ slot: PlanSlot) throws -> Bool {
    if try store.week(slot.weekStart)?.state == .approved { return true }
    return try !store.slotPosts(slot.id).isEmpty
  }

  /// Fills every open (date, position) from today onward with the queue order. Pinned/kept slots stay.
  @discardableResult
  public func proposeWeek(_ week: String) throws -> [PlanSlot] {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    if try store.week(week)?.state == .approved {
      throw EngineError("Week of \(week) is approved — use Rebuild week to re-plan it")
    }
    try store.db.transaction {
      if try store.week(week) == nil { try store.save(Week(weekStart: week, state: .draft, approvedAt: nil)) }
      var backlog = try queue.ordered()
      let today = store.today(dm)
      for day in dm.weekDays(week) where day >= today {
        let used = Set(try store.planSlots(where: "date=?", [day]).map(\.position))
        for pos in 0..<max(1, settings.postsPerDay) where !used.contains(pos) {
          guard let i = try pickIndex(backlog, for: day, settings: settings, dm: dm) else { break }
          let v = backlog.remove(at: i)
          try store.save(PlanSlot(id: newId(), date: day, position: pos, videoId: v.id, pinned: false, weekStart: week))
          try store.refreshState(videoId: v.id)
        }
      }
    }
    return try slots(week: week)
  }

  /// Creates a PlatformPost per slot (today on) × active platform; marks the week approved.
  public func approveWeek(_ week: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    if try slots(week: week).filter({ $0.date >= today }).isEmpty, try store.week(week)?.state != .approved {
      try proposeWeek(week)
    }
    let upcoming = try slots(week: week).filter { $0.date >= today }
    guard !upcoming.isEmpty else { throw EngineError("Nothing left to approve in the week of \(week)") }
    try store.db.transaction {
      var picker = PlatformPicker(queue: queue, settings: settings)
      var placer = try Placer(store: store, dm: dm)
      for s in upcoming { try createPosts(s, settings: settings, dm: dm, picker: &picker, placer: &placer) }
      try store.save(Week(weekStart: week, state: .approved, approvedAt: store.clock.now))
    }
    try store.logEvent("plan", "Approved week of \(week) (\(upcoming.count) slots)")
  }

  /// Drops unpinned slots (today on) that have nothing posted, deletes their un-posted posts, re-proposes; week → draft.
  public func rebuildWeek(_ week: String) throws {
    let dm = try store.dayMath()
    let today = store.today(dm)
    try store.db.transaction {
      for s in try slots(week: week) where s.date >= today && !s.pinned {
        if try store.slotPosts(s.id).contains(where: { $0.state == .posted }) { continue }
        try clearSlot(s)
        try store.deletePlanSlot(s.id)
        try store.refreshState(videoId: s.videoId)
      }
      try store.save(Week(weekStart: week, state: .draft, approvedAt: nil))
    }
    try proposeWeek(week)
    try store.logEvent("plan", "Rebuilt week of \(week)")
  }

  /// Moves every unpinned, un-posted slot on/after `date` later by `days` (skipping over pinned/posted slots),
  /// with its un-posted posts (each platform keeps its own shift) and the retries/reposts on those days.
  public func pushPlan(from date: String, days: Int) throws {
    guard days > 0 else { throw EngineError("Push moves the plan later — use a positive number of days") }
    try store.db.transaction { try push(from: date, days: days, until: nil) }
    try store.logEvent("plan", "Pushed plan from \(date) by \(days) day(s)")
  }

  /// Puts a video on a date and pins it there.
  public func pin(videoId: String, date: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    guard date >= store.today(dm) else { throw EngineError("\(date) is in the past") }
    try store.db.transaction {
      if var s = try store.planSlots(where: "video_id=? AND date>=?", [videoId, store.today(dm)]).first {
        if s.date != date { try moveSlot(&s, to: date, settings: settings, dm: dm) }
        s.pinned = true
        try store.save(s)
        return
      }
      let v = try readyVideo(videoId)
      let week = dm.weekStart(of: dm.date(date))
      if try store.week(week) == nil { try store.save(Week(weekStart: week, state: .draft, approvedAt: nil)) }
      let here = try store.planSlots(where: "date=?", [date])
      let used = Set(here.map(\.position))
      if let pos = (0..<max(1, settings.postsPerDay)).first(where: { !used.contains($0) }) {
        let s = PlanSlot(id: newId(), date: date, position: pos, videoId: v.id, pinned: true, weekStart: week)
        try store.save(s)
        try regenerateMany([(s, false)], settings: settings, dm: dm)
      } else if var s = here.first(where: { !$0.pinned }) {
        try ensureNothingPosted(s)
        let was = try isApproved(s)
        let old = s.videoId
        s.videoId = v.id
        s.pinned = true
        try store.save(s)
        try regenerateMany([(s, was)], settings: settings, dm: dm)
        try store.refreshState(videoId: old)
      } else {
        throw EngineError("Every slot on \(date) is pinned — unpin one first")
      }
      try store.refreshState(videoId: v.id)
    }
  }

  public func remove(slotId: String) throws {
    guard let s = try store.planSlot(id: slotId) else { throw EngineError("No plan slot \(slotId)") }
    try ensureNothingPosted(s)
    try store.db.transaction {
      try clearSlot(s)
      try store.deletePlanSlot(s.id)
      try store.refreshState(videoId: s.videoId)
    }
  }

  /// Swaps the videos of two slots.
  public func swap(_ a: String, _ b: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    guard var sa = try store.planSlot(id: a), var sb = try store.planSlot(id: b) else { throw EngineError("No such plan slot") }
    try ensureNothingPosted(sa)
    try ensureNothingPosted(sb)
    try store.db.transaction {
      let aa = try isApproved(sa), ba = try isApproved(sb)
      (sa.videoId, sb.videoId) = (sb.videoId, sa.videoId)
      try store.save(sa)
      try store.save(sb)
      try regenerateMany([(sa, aa), (sb, ba)], settings: settings, dm: dm)
    }
  }

  /// Moves a slot to another date (first free position; otherwise swaps places with that date's slot).
  public func move(slotId: String, to date: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    guard var s = try store.planSlot(id: slotId) else { throw EngineError("No plan slot \(slotId)") }
    guard date >= store.today(dm) else { throw EngineError("\(date) is in the past") }
    try store.db.transaction { try moveSlot(&s, to: date, settings: settings, dm: dm) }
  }

  /// Puts a video on today (pinned) and pushes the rest of the plan a day later. Pinned slots never move.
  public func postToday(videoId: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    let perDay = max(1, settings.postsPerDay)
    let existing = try store.planSlots(where: "video_id=? AND date>=?", [videoId, today]).first
    if let e = existing { try ensureNothingPosted(e) } else { _ = try readyVideo(videoId) }
    try store.db.transaction {
      var until: String?
      if let e = existing {
        // Take it out of its old day; only the days between today and that day move.
        try clearSlot(e)
        try store.deletePlanSlot(e.id)
        until = e.date
      }
      func freePosition() throws -> Int? {
        let used = Set(try store.planSlots(where: "date=?", [today]).map(\.position))
        return (0..<perDay).first { !used.contains($0) }
      }
      var pos = try freePosition()
      if pos == nil || existing != nil {
        try push(from: today, days: 1, until: until)
        pos = try freePosition()
      }
      guard let position = pos else {
        throw EngineError("Today's slots are pinned or already posted — unpin one first")
      }
      let s = PlanSlot(id: existing?.id ?? newId(), date: today, position: position, videoId: videoId, pinned: true,
                       weekStart: dm.weekStart(of: dm.date(today)))
      try store.save(s)
      try regenerateMany([(s, true)], settings: settings, dm: dm)
      try store.refreshState(videoId: videoId)
    }
    try store.logEvent("plan", "Post today", videoId: videoId)
  }

  /// Planned: swaps with the next slot (it posts one slot later). Backlog: moves one place later in the queue.
  public func skipNext(videoId: String) throws {
    let dm = try store.dayMath()
    let today = store.today(dm)
    guard let s = try store.planSlots(where: "video_id=? AND date>=?", [videoId, today]).first else {
      try queue.skipOnce(videoId)
      return
    }
    let later = try store.planSlots(where: "date>=?", [today])
      .filter { ($0.date, $0.position) > (s.date, s.position) && !$0.pinned }
    for n in later where try !store.slotPosts(n.id).contains(where: { $0.state == .posted }) {
      try swap(s.id, n.id)
      return
    }
    try remove(slotId: s.id)
    try queue.skipOnce(videoId)
  }

  // MARK: Internals

  struct PlatformPicker {
    let queue: Queue
    let settings: Settings
    var cache: [Platform: [Video]] = [:]
    var used: [Platform: Set<String>] = [:]

    init(queue: Queue, settings: Settings) { self.queue = queue; self.settings = settings }

    /// Next video from the platform's own ordering that isn't planned/posted there yet.
    mutating func next(_ p: Platform) throws -> Video? {
      if cache[p] == nil { cache[p] = try queue.ordered(platform: p) }
      let v = cache[p]!.first { !(used[p]?.contains($0.id) ?? false) }
      if let v { used[p, default: []].insert(v.id) }
      return v
    }

    func hasOverride(_ p: Platform) -> Bool {
      if let o = settings.sortOverrides[p] { return o != settings.sort }
      return false
    }
  }

  /// One regular post per active platform that doesn't have one for this slot yet, each on the first free day
  /// ≥ the slot date for that platform and position.
  func createPosts(_ s: PlanSlot, settings: Settings, dm: DayMath, picker: inout PlatformPicker, placer: inout Placer) throws {
    let existing = Set(try store.slotPosts(s.id).filter { $0.kind == .regular }.map(\.platform))
    let now = store.clock.now
    var touched: Set<String> = [s.videoId]
    for p in settings.activePlatforms where !existing.contains(p) {
      var videoId: String? = s.videoId
      if try store.edit(videoId: s.videoId).skippedPlatforms.contains(p), !picker.hasOverride(p) { continue }
      if picker.hasOverride(p) {
        videoId = try picker.next(p)?.id ?? (try usable(s.videoId, on: p) ? s.videoId : nil)
      } else if try !usable(s.videoId, on: p) {
        videoId = try picker.next(p)?.id
      }
      guard let vid = videoId else { continue }
      picker.used[p, default: []].insert(vid)
      touched.insert(vid)
      let day = placer.place(p, position: s.position, from: s.date)
      try store.save(PlatformPost(
        id: newId(), videoId: vid, platform: p, versionNo: 1, attemptNo: try store.nextAttemptNo(videoId: vid, platform: p),
        kind: .regular, planSlotId: s.id, scheduledAt: Sched.slotTime(settings, dm, date: day, position: s.position, platform: p),
        renderId: nil, state: .planned, publisher: "manual", externalId: nil, url: nil, postedAt: nil, errorType: nil,
        errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now),
        note: day == s.date ? "approved" : "approved (platform plan shifted to \(day))")
    }
    for v in touched { try store.refreshState(videoId: v) }
  }

  /// Not skipped in the editor for p, and never planned/posted on p.
  func usable(_ videoId: String, on p: Platform) throws -> Bool {
    guard let v = try store.video(id: videoId) else { return false }
    if v.alreadyPostedOn.contains(p) { return false }
    if try store.edit(videoId: videoId).skippedPlatforms.contains(p) { return false }
    return try store.platformHistory(videoId: videoId, platform: p).isEmpty
  }

  /// Un-posted regular posts of the slot are deleted; everything else (failed/skipped history, pending retries and
  /// reposts, which belong to their video) is detached from the slot and kept.
  func clearSlot(_ s: PlanSlot) throws {
    for var p in try store.slotPosts(s.id) where p.state != .posted {
      if p.kind == .regular && !p.state.isTerminal {
        try store.deletePost(p.id)
      } else {
        p.planSlotId = nil
        try store.save(p, note: "detached from slot \(s.date)")
      }
      try store.refreshState(videoId: p.videoId)
    }
  }

  /// Clears every approved slot first, then recreates their posts in date order (so videos that just traded places
  /// don't look "already planned", and each platform keeps its shift).
  func regenerateMany(_ list: [(PlanSlot, Bool)], settings: Settings, dm: DayMath) throws {
    var todo: [PlanSlot] = []
    for (s, was) in list {
      let weekApproved = try store.week(s.weekStart)?.state == .approved
      guard was || weekApproved else { continue }
      try clearSlot(s)
      todo.append(s)
    }
    var picker = PlatformPicker(queue: queue, settings: settings)
    var placer = try Placer(store: store, dm: dm)
    for s in todo.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
      try createPosts(s, settings: settings, dm: dm, picker: &picker, placer: &placer)
    }
    for (s, _) in list { try store.refreshState(videoId: s.videoId) }
  }

  /// Core of pushPlan/postToday. Slots that are pinned or have a posted post stay; the others move `days` later,
  /// skipping occupied (date, position)s. Slots on/after `until` are treated as fixed.
  func push(from date: String, days: Int, until: String?) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    var all = try store.planSlots(where: "date>=?", [date])
    var movable: [PlanSlot] = []
    for s in all where !s.pinned && (until == nil || s.date < until!) {
      if try !store.slotPosts(s.id).contains(where: { $0.state == .posted }) { movable.append(s) }
    }
    let movingIds = Set(movable.map(\.id))
    all.removeAll { movingIds.contains($0.id) }
    var occupied = Set(all.map { "\($0.date)#\($0.position)" })
    // Park the moving slots so the UNIQUE(date, position) index never trips mid-way.
    for (i, var s) in movable.enumerated() {
      s.date = "0000-00-00"
      s.position = -(i + 1)
      try store.save(s)
    }
    // Posts that move: un-posted regular posts of moving slots, plus un-slotted extras (retries/reposts) on/after date.
    var regular: [(PlatformPost, Int)] = []  // (post, slot delta days)
    var placerExclude = Set<String>()
    var newSlots: [PlanSlot] = []
    for original in movable.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
      var s = original
      var target = dm.addDays(s.date, days)
      while occupied.contains("\(target)#\(s.position)") { target = dm.addDays(target, 1) }
      occupied.insert("\(target)#\(s.position)")
      let delta = dm.days(from: s.date, to: target)
      s.date = target
      s.weekStart = dm.weekStart(of: dm.date(target))
      newSlots.append(s)
      for p in try store.slotPosts(s.id) where !p.state.isTerminal && p.kind == .regular {
        regular.append((p, delta))
        placerExclude.insert(p.id)
      }
    }
    for s in newSlots { try store.save(s) }
    var placer = try Placer(store: store, dm: dm, excluding: placerExclude)
    let positions = Dictionary(uniqueKeysWithValues: newSlots.map { ($0.id, $0.position) })
    for (var p, delta) in regular.sorted(by: { $0.0.scheduledAt < $1.0.scheduledAt }) {
      let pos = positions[p.planSlotId ?? ""] ?? 0
      let day = placer.place(p.platform, position: pos, from: dm.addDays(dm.key(p.scheduledAt), delta))
      p.scheduledAt = Sched.slotTime(settings, dm, date: day, position: pos, platform: p.platform)
      if p.state == .due || p.state == .overdue { p.state = p.renderId == nil ? .planned : .rendered }
      try store.save(p, note: "plan pushed → \(day)")
    }
    let extras = try store.posts(where: "kind<>'regular' AND scheduled_at>=?", [dm.date(date)])
      .filter { !$0.state.isTerminal && (until == nil || dm.key($0.scheduledAt) < until!) }
    for var p in extras {
      let day = dm.addDays(dm.key(p.scheduledAt), days)
      p.scheduledAt = try Sched.staggered(store: store, platform: p.platform, day: day, settings: settings, dm: dm, excluding: [p.id])
      if p.state == .due { p.state = p.renderId == nil ? .planned : .rendered }
      try store.save(p, note: "plan pushed → \(day)")
    }
  }

  func moveSlot(_ s: inout PlanSlot, to date: String, settings: Settings, dm: DayMath) throws {
    try ensureNothingPosted(s)
    let wasApproved = try isApproved(s)
    let used = try store.planSlots(where: "date=? AND id<>?", [date, s.id])
    if let pos = (0..<max(1, settings.postsPerDay)).first(where: { p in !used.contains { $0.position == p } }) {
      s.date = date
      s.position = pos
      s.weekStart = dm.weekStart(of: dm.date(date))
      try store.save(s)
      try regenerateMany([(s, wasApproved)], settings: settings, dm: dm)
    } else {
      var other = used.first { $0.position == s.position } ?? used[0]
      if other.pinned { throw EngineError("\(date) is pinned — unpin it first") }
      try ensureNothingPosted(other)
      let otherApproved = try isApproved(other)
      let (d, p, w) = (s.date, s.position, s.weekStart)
      let otherPos = other.position
      s.date = "0000-00-00"; s.position = -1
      try store.save(s)
      other.date = d; other.position = p; other.weekStart = w
      try store.save(other)
      s.date = date; s.position = otherPos
      s.weekStart = dm.weekStart(of: dm.date(date))
      try store.save(s)
      try regenerateMany([(s, wasApproved), (other, otherApproved)], settings: settings, dm: dm)
    }
  }

  func ensureNothingPosted(_ s: PlanSlot) throws {
    if let p = try store.slotPosts(s.id).first(where: { $0.state == .posted }) {
      throw EngineError("Already posted on \(p.platform.displayName) — this slot can't change")
    }
  }

  func readyVideo(_ id: String) throws -> Video {
    guard let v = try store.video(id: id) else { throw EngineError("No video \(id)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form — it's uploaded by hand, not planned") }
    if v.missing { throw EngineError("\(v.tag): file missing") }
    if v.excluded { throw EngineError("\(v.tag) is excluded") }
    let issues = try Validation.issues(video: v, store: store).filter { $0.kind != .tooLong }
    if let i = issues.first { throw EngineError("\(v.tag) isn't ready (\(i.message))") }
    return v
  }

  /// First backlog index usable on `day` (optional overlap rule).
  func pickIndex(_ backlog: [Video], for day: String, settings: Settings, dm: DayMath) throws -> Int? {
    guard !backlog.isEmpty else { return nil }
    guard settings.avoidOverlap else { return 0 }
    let n = settings.avoidOverlapDays
    let near = try store.planSlots(where: "date>=? AND date<=?", [dm.addDays(day, -n), dm.addDays(day, n)])
    let nearVideos = try near.compactMap { try store.video(id: $0.videoId) }
    let since = dm.date(dm.addDays(day, -n))
    let posted = try store.posts(where: "state='posted' AND posted_at>=?", [since]).compactMap { try store.video(id: $0.videoId) }
    let others = nearVideos + posted
    return backlog.firstIndex { v in !others.contains { Queue.overlaps($0, v) } }
  }
}
