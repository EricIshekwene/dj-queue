import Foundation

/// Weekly plan (spec §5): propose → edit → approve. Only approved slots get PlatformPosts, and only posts ever post.
///
/// A slot counts as approved when its week is approved or it already has posts (e.g. it was pushed into a
/// draft week, or created by Post today). Any edit to an approved slot regenerates its un-posted posts.
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
      for s in upcoming { try createPosts(s, settings: settings, dm: dm, picker: &picker) }
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
        let posts = try store.slotPosts(s.id)
        if posts.contains(where: { $0.state == .posted }) { continue }
        for p in posts where !p.state.isTerminal { try store.deletePost(p.id) }
        try store.deletePlanSlot(s.id)
        try store.refreshState(videoId: s.videoId)
        for p in posts { try store.refreshState(videoId: p.videoId) }
      }
      try store.save(Week(weekStart: week, state: .draft, approvedAt: nil))
    }
    try proposeWeek(week)
    try store.logEvent("plan", "Rebuilt week of \(week)")
  }

  /// Moves every slot on/after `date` (and their un-posted posts, plus retries/reposts on those days) by `days`.
  public func pushPlan(from date: String, days: Int) throws {
    guard days != 0 else { return }
    let dm = try store.dayMath()
    try store.db.transaction {
      var slots = try store.planSlots(where: "date>=?", [date])
      slots.sort { days > 0 ? ($0.date, $0.position) > ($1.date, $1.position) : ($0.date, $0.position) < ($1.date, $1.position) }
      for var s in slots {
        let to = dm.addDays(s.date, days)
        if days < 0, let clash = try store.planSlots(where: "date=? AND position=?", [to, s.position]).first,
           !slots.contains(where: { $0.id == clash.id }) {
          throw EngineError("Can't pull the plan back: \(to) already has a post")
        }
        s.date = to
        s.weekStart = dm.weekStart(of: dm.date(to))
        try store.save(s)
        for var p in try store.slotPosts(s.id) where !p.state.isTerminal {
          p.scheduledAt = Sched.shift(p.scheduledAt, days: days, dm)
          try store.save(p, note: "plan pushed \(days > 0 ? "+" : "")\(days) d")
        }
      }
      for var p in try store.posts(where: "plan_slot_id IS NULL AND scheduled_at>=?", [dm.date(date)]) where !p.state.isTerminal {
        p.scheduledAt = Sched.shift(p.scheduledAt, days: days, dm)
        try store.save(p, note: "plan pushed \(days > 0 ? "+" : "")\(days) d")
      }
    }
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
        if try store.week(week)?.state == .approved { try regenerate(s, settings: settings, dm: dm) }
      } else if var s = here.first(where: { !$0.pinned }) {
        try ensureNothingPosted(s)
        let old = s.videoId
        s.videoId = v.id
        s.pinned = true
        try store.save(s)
        try regenerateIfApproved(s, wasApproved: try isApproved(s), settings: settings, dm: dm)
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
      let posts = try store.slotPosts(s.id)
      for p in posts where !p.state.isTerminal { try store.deletePost(p.id) }
      try store.deletePlanSlot(s.id)
      try store.refreshState(videoId: s.videoId)
      for p in posts { try store.refreshState(videoId: p.videoId) }
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

  /// Puts a video on today (pinned) and pushes the rest of the plan back a day.
  public func postToday(videoId: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    let existing = try store.planSlots(where: "video_id=? AND date>=?", [videoId, today]).first
    if let e = existing { try ensureNothingPosted(e) } else { _ = try readyVideo(videoId) }
    try store.db.transaction {
      var s: PlanSlot
      if var e = existing {
        // Park it, close its gap by pushing the days between today and its old date.
        let oldDate = e.date
        e.date = "0000-00-00"
        e.position = -1
        try store.save(e)
        let between = try store.planSlots(where: "date>=? AND date<?", [today, oldDate])
          .sorted { ($0.date, $0.position) > ($1.date, $1.position) }
        for var b in between {
          b.date = dm.addDays(b.date, 1)
          b.weekStart = dm.weekStart(of: dm.date(b.date))
          try store.save(b)
          for var p in try store.slotPosts(b.id) where !p.state.isTerminal {
            p.scheduledAt = Sched.shift(p.scheduledAt, days: 1, dm)
            try store.save(p, note: "post today: pushed +1 d")
          }
        }
        s = e
      } else {
        try pushPlan(from: today, days: 1)
        s = PlanSlot(id: newId(), date: today, position: 0, videoId: videoId, pinned: true, weekStart: "")
      }
      s.date = today
      s.position = 0
      s.pinned = true
      s.weekStart = dm.weekStart(of: dm.date(today))
      try store.save(s)
      try regenerate(s, settings: settings, dm: dm)
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

  /// One post per active platform that doesn't have one for this slot yet.
  func createPosts(_ s: PlanSlot, settings: Settings, dm: DayMath, picker: inout PlatformPicker) throws {
    let existing = Set(try store.slotPosts(s.id).map(\.platform))
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
      try store.save(PlatformPost(
        id: newId(), videoId: vid, platform: p, versionNo: 1, attemptNo: try store.nextAttemptNo(videoId: vid, platform: p),
        kind: .regular, planSlotId: s.id, scheduledAt: Sched.slotTime(settings, dm, date: s.date, position: s.position, platform: p),
        renderId: nil, state: .planned, publisher: "manual", externalId: nil, url: nil, postedAt: nil, errorType: nil,
        errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now), note: "approved")
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

  func regenerate(_ s: PlanSlot, settings: Settings, dm: DayMath) throws {
    try regenerateMany([(s, true)], settings: settings, dm: dm)
  }

  func regenerateIfApproved(_ s: PlanSlot, wasApproved: Bool, settings: Settings, dm: DayMath) throws {
    try regenerateMany([(s, wasApproved)], settings: settings, dm: dm)
  }

  /// Deletes the un-posted posts of every approved slot first, then recreates them, so videos that just traded
  /// places don't look "already planned" on a platform.
  func regenerateMany(_ list: [(PlanSlot, Bool)], settings: Settings, dm: DayMath) throws {
    var todo: [PlanSlot] = []
    var touched = Set(list.map(\.0.videoId))
    for (s, was) in list {
      let weekApproved = try store.week(s.weekStart)?.state == .approved
      guard was || weekApproved else { continue }
      for p in try store.slotPosts(s.id) where !p.state.isTerminal {
        try store.deletePost(p.id)
        touched.insert(p.videoId)
      }
      todo.append(s)
    }
    var picker = PlatformPicker(queue: queue, settings: settings)
    for s in todo { try createPosts(s, settings: settings, dm: dm, picker: &picker) }
    for v in touched { try store.refreshState(videoId: v) }
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
      try regenerateIfApproved(s, wasApproved: wasApproved, settings: settings, dm: dm)
    } else {
      var other = used.first { $0.position == s.position } ?? used[0]
      try ensureNothingPosted(other)
      let otherApproved = try isApproved(other)
      let (d, p, w) = (s.date, s.position, s.weekStart)
      s.date = "0000-00-00"; s.position = -1
      try store.save(s)
      other.date = d; other.position = p; other.weekStart = w
      try store.save(other)
      s.date = date; s.position = used.first { $0.id == other.id }!.position
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
