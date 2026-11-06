import Foundation

/// The plan (round 13): a clip in the Queue is approved, and `autoSchedule` (AutoSchedule.swift) keeps every Queue clip on
/// the calendar. Only slots of an approved week get PlatformPosts, and only posts ever post; "approved" is an internal
/// word here (`autoSchedule` marks the week itself, so Eric never sees it).
///
/// A slot counts as approved when its week is approved or it already has posts (e.g. it was pushed into a
/// draft week, or created by Post today). Any edit to an approved slot regenerates its un-posted posts.
///
/// Never double-post: every regular post is placed with `Placer` on the first day ≥ its intended date that has
/// no other live regular post for that platform and position, so per-platform shifts (missed days) survive
/// scheduling, swaps, moves and pushes. Retries/reposts are extras staggered ≥ 3 h from that day's post.
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

  /// Internal seam (test setup, the draft week `autoSchedule` adopts); nothing aimed at Eric calls it. Fills every open
  /// (date, position) of the week from today onward with the queue order. Pinned/kept slots stay.
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

  /// Internal seam (test setup); the engine uses `autoSchedule`. Creates a PlatformPost per slot (today on) × active
  /// platform; marks the week approved. One transaction: the state check, the draft-day refill and the approval all
  /// land or none do.
  public func approveWeek(_ week: String) throws {
    try store.db.transaction { try approveWeekInTransaction(week) }
  }

  private func approveWeekInTransaction(_ week: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    // Round 6 (F5): days of this week that already passed as a draft never get posts — drop them first, so their
    // clips go back to the Queue instead of reading "Scheduled" in an approved week.
    if try store.week(week)?.state != .approved { try store.dropStalePastDraftSlots(today: today, week: week) }
    if try slots(week: week).filter({ $0.date >= today }).isEmpty, try store.week(week)?.state != .approved {
      try proposeWeek(week)
    }
    // Round 4 (S1): the Queue only holds ready clips — a draft day whose clip has since gone to Edit (unpinned, no
    // posts) is refilled from the queue before approval, so approving never schedules a clip that isn't ready.
    // Pinned days stay (pinned clips never move); the engine then reports them ("<clip> can't post").
    try dropNotReadyDraftSlots(week: week)
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

  /// Round 4 (S1): unpinned draft-week slots (today on, no posts) whose clip is no longer in the Queue (its state, freshly
  /// computed, isn't `ready`) are removed and each freed day/position is refilled from the queue order, like a
  /// proposal. `week` limits it to one week (nil = every draft week). Pinned slots and approved weeks are never
  /// touched. Returns the removed slots.
  /// `revalidate` first re-derives every Edit/Queue clip's state (states only), so neither the drop nor the refill
  /// trusts a stale stored `ready` (e.g. right after a settings save, before the next tick).
  @discardableResult
  public func dropNotReadyDraftSlots(week: String? = nil, revalidate: Bool = true) throws -> [PlanSlot] {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    var dropped: [PlanSlot] = []
    try store.db.transaction {
      if revalidate { try Revalidation(store: store).run(adjustPlan: false) }
      var clause = "date>=? AND pinned=0 AND week_start NOT IN (SELECT week_start FROM weeks WHERE state='approved')"
      var binds: [SQLBindable?] = [today]
      if let week { clause += " AND week_start=?"; binds.append(week) }
      for s in try store.planSlots(where: clause, binds) {
        guard try store.slotPosts(s.id).isEmpty, let v = try store.video(id: s.videoId) else { continue }
        _ = try store.refreshState(v, context: nil)
        guard let fresh = try store.video(id: s.videoId), [.needsEdit, .missingFile, .excluded].contains(fresh.state) else { continue }
        try store.deletePlanSlot(s.id)
        dropped.append(s)
      }
      guard !dropped.isEmpty else { return }
      var backlog = try queue.ordered()
      for s in dropped.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
        try store.logEvent("plan", "Taken off \(s.date): not in the Queue any more", videoId: s.videoId)
        guard let i = try pickIndex(backlog, for: s.date, settings: settings, dm: dm) else { continue }
        let v = backlog.remove(at: i)
        try store.save(PlanSlot(id: newId(), date: s.date, position: s.position, videoId: v.id, pinned: false, weekStart: s.weekStart))
        try store.refreshState(videoId: v.id)
        try store.logEvent("plan", "Took \(s.date) (a day freed by a clip that went back to Edit)", videoId: v.id)
      }
    }
    return dropped
  }

  /// Internal seam (test setup). Drops unpinned slots (today on) that have nothing posted, deletes their un-posted
  /// posts, re-proposes; week → draft.
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
        try ensureNothingFinal(s)
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
    try ensureNothingFinal(s)
    try store.db.transaction {
      try store.dropAutoRetries(slot: s)
      try clearSlot(s)
      try store.deletePlanSlot(s.id)
      try store.refreshState(videoId: s.videoId)
    }
  }

  /// What "Remove from queue" takes out for one video, per day: its in-flight posts (planned, rendering, rendered,
  /// due, overdue) grouped by their local day, plus its removable slots that have no posts yet.
  public struct UnplanItem: Codable, Sendable, Hashable {
    public var videoId: String
    /// YYYY-MM-DD (the post's day — a platform shifted by a missed day keeps its own day).
    public var date: String
    /// Platforms whose post is removed that day (empty: a slot that never got posts).
    public var platforms: [Platform]
    /// The slot that day was pinned (its pin goes too).
    public var pinned: Bool
  }

  /// Read-only preview of `unplan(videoId:)`, in date order.
  public func unplanPreview(videoId: String) throws -> [UnplanItem] {
    let dm = try store.dayMath()
    let (slots, live) = try unplanTargets(videoId: videoId, dm: dm)
    var byDay: [String: UnplanItem] = [:]
    for p in live {
      let d = dm.key(p.scheduledAt)
      var i = byDay[d] ?? UnplanItem(videoId: videoId, date: d, platforms: [], pinned: false)
      if !i.platforms.contains(p.platform) { i.platforms.append(p.platform) }
      byDay[d] = i
    }
    for s in slots {
      var i = byDay[s.date] ?? UnplanItem(videoId: videoId, date: s.date, platforms: [], pinned: false)
      i.pinned = i.pinned || s.pinned
      byDay[s.date] = i
    }
    return byDay.values.map { i in
      var i = i
      i.platforms.sort { (Platform.allCases.firstIndex(of: $0) ?? 0) < (Platform.allCases.firstIndex(of: $1) ?? 0) }
      return i
    }.sorted { $0.date < $1.date }
  }

  /// Takes a video out of the plan ("Remove from queue", sends it back to Edit). Every slot of it from today on with
  /// nothing posted is removed exactly like `remove(slotId:)` (un-posted regular posts deleted, failed/skipped
  /// history and pending extras detached; a pinned slot goes with its pin), and so is a past slot that only held
  /// in-flight posts. Then every post of the video still in flight — planned, rendering, rendered, due, overdue,
  /// in any slot, retries and reposts too — is deleted, so nothing of it posts while it's held. Posted and other
  /// terminal posts, slots with a posted post and post history stay. The other clips keep their days: nothing is
  /// reshuffled, and the gap is filled from the Queue's waiting clips only (`autoSchedule`).
  @discardableResult
  public func unplan(videoId: String) throws -> [UnplanItem] {
    let dm = try store.dayMath()
    let preview = try unplanPreview(videoId: videoId)
    try store.db.transaction {
      let (slots, _) = try unplanTargets(videoId: videoId, dm: dm)
      var touched: Set<String> = [videoId]
      for s in slots {
        touched.formUnion(try store.slotPosts(s.id).map(\.videoId))
        try clearSlot(s)
        try store.deletePlanSlot(s.id)
      }
      for p in try store.posts(where: "video_id=?", [videoId]) where !p.state.isTerminal {
        try store.deletePost(p.id)
      }
      for v in touched { try store.refreshState(videoId: v) }
    }
    if !preview.isEmpty {
      try store.logEvent("plan", "Removed from the plan: " + preview.map { i in
        "\(i.date)" + (i.platforms.isEmpty ? " (no posts yet)" : " · \(i.platforms.count) platform\(i.platforms.count == 1 ? "" : "s")")
      }.joined(separator: ", "), videoId: videoId)
    }
    return preview
  }

  /// Slots `unplan` removes (nothing posted; today on, or past with only in-flight posts) and the video's own
  /// in-flight posts it deletes.
  func unplanTargets(videoId: String, dm: DayMath) throws -> (slots: [PlanSlot], live: [PlatformPost]) {
    let today = store.today(dm)
    var slots: [PlanSlot] = []
    for s in try store.planSlots(where: "video_id=?", [videoId]) {
      let posts = try store.slotPosts(s.id)
      if posts.contains(where: { $0.state == .posted }) { continue }
      if s.date >= today || !posts.contains(where: { $0.state.isTerminal }) { slots.append(s) }
    }
    let live = try store.posts(where: "video_id=?", [videoId]).filter { !$0.state.isTerminal }
    return (slots, live)
  }

  /// Swaps the videos of two slots.
  public func swap(_ a: String, _ b: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    guard var sa = try store.planSlot(id: a), var sb = try store.planSlot(id: b) else { throw EngineError("No such plan slot") }
    try ensureNothingPosted(sa)
    try ensureNothingPosted(sb)
    try ensureNothingFinal(sa)
    try ensureNothingFinal(sb)
    try refuseTooSoon(sa, settings: settings, dm: dm)
    try refuseTooSoon(sb, settings: settings, dm: dm)
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
    if let e = existing {
      try ensureNothingPosted(e)
      try ensureNothingFinal(e)
    } else {
      _ = try readyVideo(videoId)
    }
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
  /// ≥ the slot date for that platform and position. `note` opens the post's history. `notBefore`: a platform whose time
  /// comes earlier gets no post. `pullForHistory: false`: a platform the clip already has history on gets no post,
  /// instead of another clip's (`autoSchedule`, DECISIONS-R13.md).
  func createPosts(_ s: PlanSlot, settings: Settings, dm: DayMath, picker: inout PlatformPicker, placer: inout Placer,
                   note: String = "scheduled", notBefore: Date? = nil, pullForHistory: Bool = true) throws {
    let existing = Set(try store.slotPosts(s.id).filter { $0.kind == .regular }.map(\.platform))
    let now = store.clock.now
    var touched: Set<String> = [s.videoId]
    for p in settings.activePlatforms where !existing.contains(p) {
      var videoId: String? = s.videoId
      if try store.edit(videoId: s.videoId).isSkipped(p, defaults: settings.defaults), !picker.hasOverride(p) { continue }
      if picker.hasOverride(p) {
        videoId = try picker.next(p)?.id ?? (try usable(s.videoId, on: p) ? s.videoId : nil)
      } else if try !usable(s.videoId, on: p) {
        guard pullForHistory else { continue }
        videoId = try picker.next(p)?.id
      }
      guard let vid = videoId else { continue }
      let day = placer.place(p, position: s.position, from: s.date)
      let at = Sched.slotTime(settings, dm, date: day, position: s.position, platform: p)
      if let notBefore, at < notBefore { continue }
      picker.used[p, default: []].insert(vid)
      touched.insert(vid)
      try store.save(PlatformPost(
        id: newId(), videoId: vid, platform: p, versionNo: 1, attemptNo: try store.nextAttemptNo(videoId: vid, platform: p),
        kind: .regular, planSlotId: s.id, scheduledAt: at,
        renderId: nil, state: .planned, publisher: "manual", externalId: nil, url: nil, postedAt: nil, errorType: nil,
        errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now),
        note: day == s.date ? note : "\(note) (platform plan shifted to \(day))")
    }
    for v in touched { try store.refreshState(videoId: v) }
  }

  /// Not skipped in the editor for p, and never planned/posted on p.
  func usable(_ videoId: String, on p: Platform) throws -> Bool {
    guard let v = try store.video(id: videoId) else { return false }
    if v.alreadyPostedOn.contains(p) { return false }
    if try store.edit(videoId: videoId).isSkipped(p, defaults: try store.settings().defaults) { return false }
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
    // A move never pulls another clip onto this slot: a platform the clip has history on gets no post (re-review N3).
    for s in todo.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
      try createPosts(s, settings: settings, dm: dm, picker: &picker, placer: &placer, pullForHistory: false)
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
    let oldDates = Dictionary(uniqueKeysWithValues: movable.map { ($0.id, $0.date) })
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
      let planned = dm.planDay(p.scheduledAt, position: pos, slotDate: oldDates[p.planSlotId ?? ""], platform: p.platform,
                               offsetMinutes: settings.secondPostOffsetMinutes)
      let day = placer.place(p.platform, position: pos, from: dm.addDays(planned, delta))
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
    try ensureNothingFinal(s)
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
      try ensureNothingFinal(other)
      try refuseTooSoon(s, settings: settings, dm: dm)  // `other` takes this slot's day and position
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

  /// A swap would put a clip Eric didn't touch on `s`'s day and position. Inside the lead that clip would post within
  /// minutes (a past slot goes out 3 minutes after upload), so the swap is refused.
  func refuseTooSoon(_ s: PlanSlot, settings: Settings, dm: DayMath) throws {
    let now = store.clock.now
    guard isOpen(day: s.date, position: s.position, today: dm.key(now), now: now, settings: settings, dm: dm) else {
      throw EngineError(StageWording.todayTooSoon)
    }
  }

  /// Regenerating a slot gives its posts new ids, and a new id forgets a final Postiz job: a post Eric deleted in Postiz would
  /// go back. So a slot with one stays put. Back to Edit and Send to Queue is the explicit way to send it again.
  func ensureNothingFinal(_ s: PlanSlot) throws {
    for p in try store.slotPosts(s.id) where !p.state.isTerminal {
      guard try store.finalPostizJob(postId: p.id) != nil else { continue }
      throw EngineError("\(try store.video(id: p.videoId)?.displayName ?? p.videoId) has a post you removed from Postiz")
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
    if let i = issues.first { throw EngineError("\(v.tag) is in Edit, not the Queue (\(i.message))") }
    if !v.sentToQueue { throw EngineError("\(v.tag) is in Edit, not the Queue (send it to the Queue first)") }
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
