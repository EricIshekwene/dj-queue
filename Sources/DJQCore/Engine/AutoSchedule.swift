import Foundation

/// Round 13: a clip in the Queue is approved, and the engine keeps every Queue clip on the calendar. `autoSchedule` runs in
/// the plan step of each tick; it fills open (day, position) slots in Queue order and creates the real posts at once, so
/// there are no drafts. `weeks` stays as the internal record: the week of every slot it touches is marked approved here,
/// which is why `isApproved`, `regenerateMany`, the runway and undo snapshots work unchanged.
///
/// Guards it adds to the planner's own:
/// - a position is open only when its earliest platform time is at least `autoScheduleLead` away, so Eric can always
///   cancel, and no post is ever created in the past or inside the lead;
/// - the plan re-lays only when posts/day or the Queue sort changed (`plan.layoutSig`), never otherwise: a gap is filled
///   from the waiting clips and the other clips keep their days;
/// - a clip with history on a platform skips that platform on its day instead of pulling another clip onto its card
///   (DECISIONS-R13.md), and a clip with nowhere left to post takes no day.
extension Planner {
  /// How far ahead the calendar is filled (days after today, no setting).
  public static let autoScheduleHorizonDays = 30
  /// A position is open only when its earliest platform time is at least this far away.
  public static let autoScheduleLead: TimeInterval = 30 * 60
  /// A relay leaves a slot alone when one of its live posts goes out sooner than this.
  public static let relayLead: TimeInterval = 60 * 60
  /// kv key of the layout the plan was last laid out for.
  static let layoutKey = "plan.layoutSig"

  /// What the plan is laid out for. The sort is one canonical string, because a Swift dictionary encodes in hash order.
  struct LayoutSig: Codable, Equatable {
    var postsPerDay: Int
    var sort: String

    init(_ s: Settings) {
      postsPerDay = max(1, s.postsPerDay)
      sort = ([s.sort.rawValue] + s.sortOverrides.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted()).joined(separator: ";")
    }
  }

  public struct ScheduledClip: Codable, Sendable, Equatable {
    public var videoId: String
    public var date: String
    public var position: Int
  }

  public struct AutoScheduleReport: Codable, Sendable, Equatable {
    /// Clips that got a day they didn't have (new from the Queue, or a draft slot that got its posts).
    public var scheduled = 0
    /// Clips the relay took off the calendar and laid again.
    public var relaid = 0
    /// Why nothing was scheduled ("paused", "no platforms on", "Queue empty", "no open day", or clips with nowhere left to
    /// post); nil when something was.
    public var reason: String?
    /// Clips still waiting for a day afterwards.
    public var waiting = 0
    /// Clips in the Queue that will never get a day: every platform is done or skipped for them.
    public var nowhereToPost = 0
    /// Where each clip landed, in calendar order.
    public var clips: [ScheduledClip] = []
    public var dryRun = false

    public var summary: String {
      var parts: [String] = []
      if scheduled > 0 { parts.append("scheduled \(scheduled)") }
      if relaid > 0 { parts.append("re-laid \(relaid)") }
      if parts.isEmpty { parts.append(reason ?? "nothing to do") }
      return parts.joined(separator: " · ")
    }
  }

  private struct Rollback: Error { var report: AutoScheduleReport }

  /// One pass in one transaction: adopt draft slots, relay when due, fill open positions, refresh states. Safe to call at
  /// any time: with nothing open it writes nothing, and two callers can't double-slot (the transaction is `BEGIN IMMEDIATE`
  /// and reads everything inside it). `dryRun` rolls the whole pass back and reports what it would do.
  /// `revalidate` re-derives Edit/Queue states first (the engine's stages step already did).
  @discardableResult
  public func autoSchedule(now: Date? = nil, dryRun: Bool = false, revalidate: Bool = false) throws -> AutoScheduleReport {
    do {
      return try store.db.transaction {
        var r = try pass(now: now ?? store.clock.now, revalidate: revalidate)
        r.dryRun = dryRun
        if dryRun { throw Rollback(report: r) }
        return r
      }
    } catch let d as Rollback {
      return d.report
    }
  }

  private func pass(now: Date, revalidate: Bool) throws -> AutoScheduleReport {
    var r = AutoScheduleReport()
    let settings = try store.settings()
    guard !settings.paused else { r.reason = "paused"; return r }
    guard !settings.activePlatforms.isEmpty else { r.reason = "no platforms on"; return r }
    if revalidate { try Revalidation(store: store).run(adjustPlan: false) }
    let dm = DayMath(settings: settings)
    let today = dm.key(now)
    try store.dropStalePastDraftSlots(today: today)
    var ctx = Pass(now: now, today: today, settings: settings, dm: dm, picker: PlatformPicker(queue: queue, settings: settings))
    try adoptDraftSlots(&ctx, &r)
    let first = try relayIfDue(&ctx, &r)
    try fill(&ctx, first: first, &r)
    r.clips.sort { ($0.date, $0.position) < ($1.date, $1.position) }
    let queued = try queue.ordered().count
    r.waiting = try schedulable(settings).count
    r.nowhereToPost = queued - r.waiting
    if r.scheduled == 0, r.relaid == 0 {
      r.reason = r.waiting > 0 ? "no open day"
        : r.nowhereToPost > 0 ? "\(r.nowhereToPost) clip\(r.nowhereToPost == 1 ? "" : "s") in the Queue with nowhere left to post"
        : "Queue empty"
    }
    return r
  }

  /// One pass's shared state. The placer is built on first use: a tick with nothing to do reads no posts.
  private struct Pass {
    var now: Date
    var today: String
    var settings: Settings
    var dm: DayMath
    var picker: PlatformPicker
    var placer: Placer?
    /// Clip → the day it had before the relay took it off.
    var previousDay: [String: String] = [:]
  }

  /// The position still has every platform at least the lead away: today's, and tomorrow's just after midnight.
  func isOpen(day: String, position pos: Int, today: String, now: Date, settings: Settings, dm: DayMath) -> Bool {
    guard day >= today else { return false }
    let times = settings.activePlatforms.map { Sched.slotTime(settings, dm, date: day, position: pos, platform: $0) }
    guard let earliest = times.min() else { return false }
    return earliest >= now.addingTimeInterval(Self.autoScheduleLead)
  }

  /// Every open (day, position) from today to the horizon, in calendar order. A day never goes past posts/day, even when
  /// a pinned slot sits above it after posts/day was lowered. Set-time slots (round 21) don't count: the day keeps all
  /// its regular positions.
  func openPositions(now: Date, settings: Settings, dm: DayMath) throws -> [(date: String, position: Int)] {
    let today = dm.key(now)
    let last = dm.addDays(today, Self.autoScheduleHorizonDays)
    let perDay = max(1, settings.postsPerDay)
    let byDay = Dictionary(grouping: try store.planSlots(where: "date>=? AND date<=?", [today, last]), by: \.date)
    var out: [(date: String, position: Int)] = []
    for offset in 0...Self.autoScheduleHorizonDays {
      let day = dm.addDays(today, offset)
      // Set-time slots are outside the cadence: they take none of the day's room.
      let used = Set((byDay[day] ?? []).filter { !$0.isExact }.map(\.position))
      let room = perDay - used.count
      guard room > 0 else { continue }
      let free = (0..<perDay).filter { !used.contains($0) }
        .filter { isOpen(day: day, position: $0, today: today, now: now, settings: settings, dm: dm) }
      out += free.prefix(room).map { (day, $0) }
    }
    return out
  }

  /// The Queue in posting order, without clips that have nowhere left to post: they would take a day and post nothing.
  public func schedulable(_ settings: Settings) throws -> [Video] {
    try queue.ordered().filter { v in try settings.activePlatforms.contains { try usable(v.id, on: $0) } }
  }

  /// Draft-week slots from today on become real, the same way approving a week did (not-ready clips drop first; pinned
  /// ones stay). A slot on today that's already inside the lead can't post whole: unpinned it goes back to the Queue, and
  /// pinned it keeps the platforms still ahead, or goes back to the Queue when none are.
  private func adoptDraftSlots(_ c: inout Pass, _ r: inout AutoScheduleReport) throws {
    let clause = "date>=? AND week_start NOT IN (SELECT week_start FROM weeks WHERE state='approved')"
    guard try !store.planSlots(where: clause, [c.today]).isEmpty else { return }
    try dropNotReadyDraftSlots(revalidate: false)
    let slots = try store.planSlots(where: clause, [c.today]).sorted { ($0.date, $0.position) < ($1.date, $1.position) }
    var placer = try Placer(store: store, dm: c.dm)
    // A set-time slot is real from the moment it's made (`postAt` creates its posts): only its week is marked.
    for s in slots where !s.isExact {
      let late = !isOpen(day: s.date, position: s.position, today: c.today, now: c.now, settings: c.settings, dm: c.dm)
      let hadPosts = try !store.slotPosts(s.id).isEmpty
      if !late || s.pinned || hadPosts {
        try createPosts(s, settings: c.settings, dm: c.dm, picker: &c.picker, placer: &placer, note: "auto-scheduled",
                        notBefore: c.now.addingTimeInterval(Self.autoScheduleLead), pullForHistory: false)
      }
      guard try !store.slotPosts(s.id).isEmpty || (s.pinned && !late) else {
        try store.deletePlanSlot(s.id)
        try store.refreshState(videoId: s.videoId)
        try store.logEvent("plan", "\(late ? "Too late to post" : "Nothing left to post") on \(s.date)\(s.pinned ? ", pin removed" : "") — back in the Queue", videoId: s.videoId)
        continue
      }
      r.scheduled += 1
      r.clips.append(ScheduledClip(videoId: s.videoId, date: s.date, position: s.position))
      try logScheduled(s.videoId, s.date, c)
    }
    for w in Set(slots.map(\.weekStart)) { try approve(week: w, at: c.now) }
    c.placer = placer
  }

  /// Marks the week as the internal record wants it for a slot that posts. Shared with `postAt`.
  func approve(week: String, at now: Date) throws {
    if try store.week(week)?.state != .approved { try store.save(Week(weekStart: week, state: .approved, approvedAt: now)) }
  }

  private func logScheduled(_ videoId: String, _ day: String, _ c: Pass) throws {
    try store.logEvent("plan", StageWording.scheduledFor(BulkActions.day(day, c.dm, c.settings)), videoId: videoId)
  }

  /// Runs once when posts/day or the Queue sort changed, and the first run only records the layout (installing never
  /// reshuffles what's there). Returns the order to fill in: the cleared clips in their old order after a posts/day
  /// change, nil (plain Queue order) after a sort change.
  private func relayIfDue(_ c: inout Pass, _ r: inout AutoScheduleReport) throws -> [String]? {
    let sig = LayoutSig(c.settings)
    let stored: LayoutSig? = try store.kv(Self.layoutKey)
    guard stored != sig else { return nil }
    try store.setKV(Self.layoutKey, sig)
    guard let stored else { return nil }
    let cleared = try movableSlots(c)
    for s in cleared {
      try clearSlot(s)
      try store.deletePlanSlot(s.id)
      try store.refreshState(videoId: s.videoId)
      c.previousDay[s.videoId] = s.date
    }
    c.placer = nil  // the posts it counted are gone
    r.relaid = cleared.count
    r.scheduled -= r.clips.filter { c.previousDay[$0.videoId] != nil }.count  // adopted a moment ago: counted by the relay
    r.clips.removeAll { c.previousDay[$0.videoId] != nil }
    if !cleared.isEmpty { try store.logEvent("plan", "Re-laid \(cleared.count) clip\(cleared.count == 1 ? "" : "s"): posts per day or the Queue order changed") }
    return stored.sort == sig.sort ? cleared.map(\.videoId) : nil
  }

  /// What a relay may take off: unpinned slots from today on with nothing posted, each live post at least `relayLead`
  /// away and untouched. A set-time slot is always pinned, and left out by name as well.
  /// Postiz keeps its guards: a slot with a live job moves (the publish step cancels the job, and the
  /// lineage blocks a new create until that's confirmed); one whose job isn't settled or ended Postiz delivery for good,
  /// or that went to Eric by hand, stays.
  private func movableSlots(_ c: Pass) throws -> [PlanSlot] {
    let cutoff = c.now.addingTimeInterval(Self.relayLead)
    let untouched: Set<PostState> = [.planned, .rendering, .rendered]
    func movable(_ p: PlatformPost) throws -> Bool {
      guard !p.state.isTerminal else { return true }  // failed/skipped history is detached and kept
      guard untouched.contains(p.state), p.scheduledAt >= cutoff, try !PostizService.handedToToday(p, store: store) else { return false }
      // Deleted in Postiz, refused, or released by Eric: final for this post, and a new post id would forget it.
      if try store.finalPostizJob(postId: p.id) != nil { return false }
      if try store.publishedPostizJob(lineage: PostizJob.lineage(p)) != nil { return false }
      guard let job = try store.livePostizJob(postId: p.id) else { return true }
      return job.phase == .live && job.remoteDate >= cutoff
    }
    return try store.planSlots(where: "date>=? AND pinned=0 AND exact_at IS NULL", [c.today]).sorted { ($0.date, $0.position) < ($1.date, $1.position) }
      .filter { s in
        let posts = try store.slotPosts(s.id)
        return try !posts.contains { $0.state == .posted } && posts.allSatisfy(movable)
      }
  }

  /// Open positions in calendar order take the next clip, keeping the overlap rule. `first` puts those clips ahead of the
  /// rest of the Queue, in that order.
  private func fill(_ c: inout Pass, first: [String]?, _ r: inout AutoScheduleReport) throws {
    let open = try openPositions(now: c.now, settings: c.settings, dm: c.dm)
    guard !open.isEmpty else { return }
    var backlog = try schedulable(c.settings)
    guard !backlog.isEmpty else { return }
    if let first {
      let rank = Dictionary(first.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
      backlog = backlog.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! } + backlog.filter { rank[$0.id] == nil }
    }
    var placer = try c.placer ?? Placer(store: store, dm: c.dm)
    for (day, pos) in open {
      guard !backlog.isEmpty else { break }
      guard let i = try pickIndex(backlog, for: day, settings: c.settings, dm: c.dm) else { continue }
      let v = backlog.remove(at: i)
      let week = c.dm.weekStart(of: c.dm.date(day))
      try approve(week: week, at: c.now)
      let s = PlanSlot(id: newId(), date: day, position: pos, videoId: v.id, pinned: false, weekStart: week)
      try store.save(s)
      try createPosts(s, settings: c.settings, dm: c.dm, picker: &c.picker, placer: &placer, note: "auto-scheduled",
                      notBefore: c.now.addingTimeInterval(Self.autoScheduleLead), pullForHistory: false)
      guard try !store.slotPosts(s.id).isEmpty else {  // a slot with no posts would hold its clip on Scheduled for good
        try store.deletePlanSlot(s.id)
        try store.refreshState(videoId: v.id)
        backlog.insert(v, at: i)
        continue
      }
      r.clips.append(ScheduledClip(videoId: v.id, date: day, position: pos))
      if c.previousDay[v.id] == nil { r.scheduled += 1 }
      if c.previousDay[v.id] != day { try logScheduled(v.id, day, c) }
    }
    c.placer = placer
  }
}
