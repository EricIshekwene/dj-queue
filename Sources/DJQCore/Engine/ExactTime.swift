import Foundation

/// Round 21 (DECISIONS-R21.md, D12–D14): "Post at a set time". Eric picks an exact day and time for an item and every
/// platform it posts to goes out at that minute.
///
/// The model is a `PlanSlot` with `exactAt` set:
/// - always pinned, `date` = the local day of `exactAt`, `position` = the first free one from `PlanSlot.exactBase` up, so
///   it never takes one of the day's regular positions (`0..<postsPerDay`) and two set-time items can share a day
///   (on the same minute Postiz sends one of them a minute later on a channel, and the preview says so);
/// - its week is marked approved the way `autoSchedule` does, and it holds one regular `PlatformPost` per usable
///   platform at `exactAt`: always the slot's own clip, never another clip pulled by a per-platform sort. YouTube inside
///   the quiet window goes through `YouTubeWindow.clear` like every other YouTube time. A platform that failed and has a
///   retry on its way goes out at the set time as that retry (`carryRetries`), so the lineage never forks;
/// - it sits outside the cadence: `openPositions`, `fill`, the relay, `push`, `reflow`, the `Placer` and the runway leave
///   it out, so no other clip moves because of it and nothing but `postAt`, `clearExact`, a move to another day, Back to
///   Edit and `remove` ever changes it.
extension Planner {
  /// A set time must be at least this far ahead.
  public static let exactLead: TimeInterval = 600

  /// What `postAt` would do, for the UI and `djq post-at --dry-run` to show before Eric confirms.
  public struct ExactPreview: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
      public var platform: Platform
      /// When it goes out there.
      public var at: Date
      /// YouTube's quiet window moved it off the set time.
      public var moved: Bool
      /// It goes out as the retry of a post that failed, moved to the set time.
      public var retry = false
    }

    public struct Skipped: Codable, Sendable, Equatable {
      public enum Reason: String, Codable, Sendable {
        /// Turned off for this item in the editor (a photo post's YouTube is always off).
        case off
        /// Marked as already posted there.
        case posted
        /// Its post there failed and retries by itself: the retry is made for the set time on the engine's next pass.
        case retrying
        /// Its post there failed and waits for Eric (Fixed, or a copyright choice) in Posts.
        case failed
        /// Its post there was skipped.
        case skipped
        /// Anything else already on record there (taken down, blocked).
        case history
      }
      public var platform: Platform
      public var reason: Reason
      /// The reason in words: "Off for this clip".
      public var why: String
    }

    public var videoId: String
    /// The set time, on the whole minute.
    public var at: Date
    /// "Set for Sat 14 Nov 3:15 PM".
    public var summary: String
    /// One line per platform it goes out on, in platform order. Empty when `blocker` is set.
    public var platforms: [Line] = []
    /// Platforms that are on in Settings and get no post.
    public var skipped: [Skipped] = []
    /// The slots it takes the item off (its regular day, or the set time it had).
    public var replaces: [PlanSlot] = []
    /// What Eric should read first: "YouTube moves to 2:30 AM (07:30 UTC)", "TikTok goes out at 7:01 PM: another post
    /// has 7:00 PM" (Postiz never sends two posts on one channel in the same minute).
    public var notes: [String] = []
    /// It already has exactly this time: confirming changes nothing.
    public var unchanged = false
    /// Why it can't be set (nil = it can): the time has passed, something is left to fix, it already posted, …
    public var blocker: String?
  }

  /// `at` on its whole minute: every platform goes out at the same minute.
  public static func exactMinute(_ at: Date) -> Date {
    Date(timeIntervalSince1970: (at.timeIntervalSince1970 / 60).rounded(.down) * 60)
  }

  /// "2026-11-14 15:15" (or with a `T`) in the Settings time zone, on a real day. The words of the error are for the CLI.
  public static func parseExact(_ raw: String, settings: Settings) throws -> Date {
    let bad = EngineError("\(raw) isn't a day and time — use \"YYYY-MM-DD HH:MM\", e.g. \"2026-11-14 15:15\"")
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else { throw bad }
    let n = text.split(whereSeparator: { "-T: ".contains($0) }).compactMap { Int($0) }
    guard n.count == 5, (1...12).contains(n[1]), (1...31).contains(n[2]), n[3] < 24, n[4] < 60 else { throw bad }
    let dm = DayMath(settings: settings)
    let day = String(format: "%04d-%02d-%02d", n[0], n[1], n[2])
    guard dm.key(dm.date(day)) == day else { throw bad }  // 31 November rolls over
    return try exactDate(day: day, minutes: n[3] * 60 + n[4], settings: settings)
  }

  /// `minutes` after midnight on `day` in the Settings time zone. Refused when that time doesn't exist there: the night
  /// the clocks go forward has no 2:30 AM, and the calendar would quietly hand back 3:30.
  public static func exactDate(day: String, minutes: Int, settings: Settings) throws -> Date {
    let dm = DayMath(settings: settings)
    let d = dm.at(day, minutes: minutes)
    let c = dm.calendar.dateComponents([.hour, .minute], from: d)
    guard dm.key(d) == day, (c.hour ?? 0) * 60 + (c.minute ?? 0) == minutes else {
      throw EngineError(StageWording.noSuchTime(minutes: minutes, day: day, settings: settings))
    }
    return d
  }

  /// Why `at` can't be a set time (nil = it can): it has passed, or it's inside the lead.
  public func exactTimeProblem(_ at: Date) -> String? {
    let now = store.clock.now
    if at <= now { return StageWording.setTimePassed }
    return at < now.addingTimeInterval(Self.exactLead) ? StageWording.setTimeTooSoon : nil
  }

  /// The item's set-time slot (nil = it follows the regular schedule).
  public func exactSlot(videoId: String) throws -> PlanSlot? {
    try store.planSlots(where: "video_id=? AND exact_at IS NOT NULL", [videoId]).max { ($0.exactAt ?? .distantPast) < ($1.exactAt ?? .distantPast) }
  }

  /// Posts the item at `at` on every platform it goes to, outside the cadence (see the type comment). It must be in the
  /// Queue or already scheduled, with nothing posted. A slot it has (its regular day, or another set time) is cleared
  /// and replaced; a regular position it leaves is open again and the next `autoSchedule` fills it from the Queue.
  /// Nothing else moves. Throws a readable `EngineError` when the time isn't `exactLead` ahead.
  @discardableResult
  public func postAt(videoId: String, at: Date) throws -> PlanSlot {
    try setExact(videoId: videoId, at: at).slot
  }

  /// `postAt`, and whether anything changed (false: it already had exactly this time).
  func setExact(videoId: String, at: Date) throws -> (slot: PlanSlot, changed: Bool) {
    try store.db.transaction {
      let settings = try store.settings()
      let r = try replaceWithExact(videoId: videoId, at: at, settings: settings)
      if r.changed {
        try store.logEvent("plan", StageWording.setFor(r.slot.exactAt ?? at, settings: settings), videoId: videoId)
      }
      return (r.slot, r.changed)
    }
  }

  /// "Use the regular schedule": takes the set time off. The item is back in the Queue and the next `autoSchedule` gives
  /// it the next open day. Refused once something posted, or while Postiz holds a copy about to go out.
  public func clearExact(videoId: String) throws {
    try store.db.transaction {
      let slots = try store.planSlots(where: "video_id=? AND exact_at IS NOT NULL", [videoId])
      guard !slots.isEmpty else { throw EngineError(StageWording.noSetTime) }
      for s in slots {
        try ensureNothingPosted(s)
        try ensureNothingFinal(s)
      }
      try refuseTooLate(videoId: videoId)
      // A retry on its way stays as it is, at its own time (`clearSlot` only takes it off the card): dropping it would
      // leave its failure marked retried with nothing coming.
      for s in slots { try dropSlot(s) }
      try store.refreshState(videoId: videoId)
      try store.logEvent("plan", StageWording.regularSchedule, videoId: videoId)
    }
  }

  /// Read-only: what `postAt(videoId:at:)` would do. It runs the real thing and rolls it back, so the two can't disagree.
  /// For an item still in Edit use `BulkActions.postAtPreview`, which goes through Send to Queue first as `postAt` there does.
  public func postAtPreview(videoId: String, at: Date) throws -> ExactPreview {
    try postAtPreview(videoId: videoId, at: at, first: nil)
  }

  private struct PreviewRollback: Error {}

  /// `first` runs inside the rolled-back transaction before the time is set (the Send to Queue door).
  func postAtPreview(videoId: String, at raw: Date, first: ((Video, Settings) throws -> Void)?) throws -> ExactPreview {
    let shown = try store.settings()
    let at = Self.exactMinute(raw)
    var out = ExactPreview(videoId: videoId, at: at, summary: StageWording.setFor(at, settings: shown))
    do {
      try store.db.transaction {
        let settings = try store.settings()
        guard let v = try store.video(id: videoId) else { throw EngineError("No video \(videoId)") }
        try first?(v, settings)
        let r = try replaceWithExact(videoId: videoId, at: at, settings: settings)
        out.unchanged = !r.changed
        out.replaces = r.replaced
        let posts = try store.slotPosts(r.slot.id).filter { $0.kind != .repost && !$0.state.isTerminal }
        out.platforms = posts.sorted { $0.platform < $1.platform }.map {
          ExactPreview.Line(platform: $0.platform, at: $0.scheduledAt, moved: $0.scheduledAt != at, retry: $0.kind == .retry)
        }
        let going = Set(posts.map(\.platform))
        let edit = try store.edit(videoId: videoId)
        for p in settings.activePlatforms.sorted() where !going.contains(p) {
          let reason = try skipReason(v, p, edit: edit, settings: settings)
          out.skipped.append(.init(platform: p, reason: reason, why: StageWording.noSetTimePost(reason, p)))
        }
        out.notes = out.platforms.filter { $0.moved && $0.platform == .youtube }
          .map { StageWording.youtubeMoves(to: $0.at, setFor: at, settings: settings) }
        out.notes += try sameMinuteNotes(out.platforms, videoId: videoId, settings: settings)
        throw PreviewRollback()
      }
    } catch is PreviewRollback {
    } catch let e as EngineError {
      out.blocker = e.message
    }
    return out
  }

  /// Why an active platform gets no set-time post, from what's on record for the item there.
  private func skipReason(_ v: Video, _ p: Platform, edit: Edit, settings: Settings) throws -> ExactPreview.Skipped.Reason {
    if v.alreadyPostedOn.contains(p) { return .posted }
    if edit.isSkipped(p, defaults: settings.defaults) { return .off }
    guard let last = try store.platformHistory(videoId: v.id, platform: p).max(by: { $0.attemptNo < $1.attemptNo }) else { return .history }
    switch last.state {
    case .failed: return try store.retryIsComing(last) ? .retrying : .failed
    case .skipped: return .skipped
    default: return .history
    }
  }

  /// Postiz never holds two posts on one channel in the same minute: the later create goes a minute on
  /// (`PostizService.remoteDate`). When another post already sits in Postiz on that minute, this one is the later create
  /// and the note gives its real time; when neither is there yet, it says one of the two moves.
  private func sameMinuteNotes(_ lines: [ExactPreview.Line], videoId: String, settings: Settings) throws -> [String] {
    func minute(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 60) }
    var notes: [String] = []
    let jobs = try store.openPostizJobs().filter { $0.videoId != videoId }
    for l in lines where settings.publishing.publisher(for: l.platform) == .postiz {
      let held = Set(jobs.filter { $0.platform == l.platform }.map { minute($0.remoteDate) })
      if held.contains(minute(l.at)) {
        var d = l.at
        while held.contains(minute(d)) { d = YouTubeWindow.clear(d.addingTimeInterval(60), l.platform) }
        notes.append(StageWording.sameMinute(l.platform, goesAt: d, taken: l.at, settings: settings))
      } else if try store.posts(where: "platform=? AND video_id<>? AND scheduled_at>=? AND scheduled_at<?",
                                [l.platform.rawValue, videoId, l.at, l.at.addingTimeInterval(60)]).contains(where: { !$0.state.isTerminal }) {
        notes.append(StageWording.sameMinute(l.platform, goesAt: nil, taken: l.at, settings: settings))
      }
    }
    return notes
  }

  // MARK: Internals

  /// The core of `postAt`, inside the caller's transaction. No event: the preview runs it too.
  private func replaceWithExact(videoId: String, at raw: Date, settings: Settings) throws -> (slot: PlanSlot, replaced: [PlanSlot], changed: Bool) {
    let dm = DayMath(settings: settings)
    let at = Self.exactMinute(raw)
    let old = try unplanTargets(videoId: videoId, dm: dm).slots.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
    if old.count == 1, old[0].exactAt == at, try !store.slotPosts(old[0].id).isEmpty { return (old[0], [], false) }
    if let why = exactTimeProblem(at) { throw EngineError(why) }
    if let p = try store.posts(where: "video_id=? AND kind IN ('regular','retry') AND state='posted'", [videoId], order: "posted_at").first {
      throw EngineError("Already posted on \(p.platform.displayName) — it can't take a set time")
    }
    let v = try readyVideo(videoId, scheduled: !old.isEmpty)
    try refuseSharedCard(videoId: videoId, leaving: old)
    try refuseTooLate(videoId: videoId)
    // A new id forgets a final Postiz job, so a post Eric removed there stays put.
    for p in try inFlight(videoId) where try store.finalPostizJob(postId: p.id) != nil {
      throw EngineError("\(v.displayName) has a post you removed from Postiz")
    }
    for s in old { try dropSlot(s) }
    let day = dm.key(at)
    let week = dm.weekStart(of: dm.date(day))
    try approve(week: week, at: store.clock.now)
    let slot = PlanSlot(id: old.first?.id ?? newId(), date: day, position: try freeExactPosition(on: day), videoId: videoId,
                        pinned: true, weekStart: week, exactAt: at)
    try store.save(slot)
    let waiting = try carryRetries(to: slot)
    try createExactPosts(slot, settings: settings)
    guard try waiting > 0 || store.slotPosts(slot.id).contains(where: { !$0.state.isTerminal }) else {
      throw EngineError("\(v.tag) has nowhere left to post: every platform is done or off for it")
    }
    try store.refreshState(videoId: videoId)
    return (slot, old, true)
  }

  /// When a platform has its own order, a day's card can carry another clip's post and the item's own post can sit on
  /// another clip's card. Taking the item off its regular day would then delete or strand a post of another clip, or
  /// leave that platform of the item on its regular day. Nothing is detached, deleted or guessed: it is refused, and
  /// Back to Edit (which takes the whole day off, as it always did) is the way out. An item still in the Queue has no
  /// card, and a set-time slot only ever holds its own clip's posts, so neither can be in this state.
  private func refuseSharedCard(videoId: String, leaving old: [PlanSlot]) throws {
    for s in old where !s.isExact {
      if let p = try store.slotPosts(s.id).first(where: { $0.videoId != videoId && !$0.state.isTerminal }) {
        throw EngineError(StageWording.sharedCard(p.platform))
      }
    }
    for p in try inFlight(videoId) where p.kind == .regular {
      if let s = try p.planSlotId.flatMap({ try store.planSlot(id: $0) }), s.videoId != videoId {
        throw EngineError(StageWording.sharedCard(p.platform))
      }
    }
  }

  /// The item's regular posts and retries that haven't gone out or ended.
  private func inFlight(_ videoId: String) throws -> [PlatformPost] {
    try store.posts(where: "video_id=? AND kind IN ('regular','retry')", [videoId]).filter { !$0.state.isTerminal }
  }

  /// Changing or clearing a time deletes the post Postiz holds, and from `PostizService.safety` before its time Postiz
  /// keeps its copy whatever the plan says (`decide`: "re-planned close to its slot"): it would go out at the old time
  /// while every screen showed the new one. So a copy that goes out within `exactLead` refuses the change, the way the
  /// relay, `setSlot` and a swap leave a post that is about to go out. A post Postiz doesn't hold can always change.
  func refuseTooLate(videoId: String) throws {
    for p in try inFlight(videoId) {
      if let why = try tooLate(p, to: "change") { throw EngineError(why) }
    }
  }

  /// The one test `refuseTooLate` and the undo of a set-time batch share: Postiz holds a copy of `p` that goes out
  /// within `exactLead`. nil = it can still be taken back.
  func tooLate(_ p: PlatformPost, to verb: String) throws -> String? {
    guard !p.state.isTerminal, let job = try store.livePostizJob(postId: p.id) else { return nil }
    let now = store.clock.now
    let goes = min(p.scheduledAt, job.remoteDate)
    return goes <= now.addingTimeInterval(Self.exactLead)
      ? StageWording.tooLateToChange(p.platform, seconds: goes.timeIntervalSince(now), to: verb) : nil
  }

  /// What still goes out by itself after "Use the regular schedule": a retry on its way keeps its own time, and so does
  /// one still to be made. For the note: "TikTok's retry still goes out Fri 6 Nov 10:00 AM".
  func retriesLeft(videoId: String) throws -> [(platform: Platform, at: Date)] {
    var out = try inFlight(videoId).filter { $0.kind == .retry }.map { (platform: $0.platform, at: $0.scheduledAt) }
    for f in try store.posts(where: "video_id=? AND state='failed' AND resolution IS NULL", [videoId]) where try store.retryIsComing(f) {
      if let at = try store.autoRetries(f).nextRetryAt { out.append((f.platform, at)) }
    }
    return out.sorted { $0.platform < $1.platform }
  }

  /// A platform that failed keeps one lineage: a retry on its way (the engine's own, or Eric's Fixed) moves to the set
  /// time as the same post, so nothing is created beside it, and a failure whose retry is still to be made has it made
  /// for the set time on the engine's next pass. A failure is never left marked retried with no attempt. Returns how
  /// many failures still wait for their attempt.
  @discardableResult
  func carryRetries(to slot: PlanSlot) throws -> Int {
    guard let exact = slot.exactAt else { return 0 }
    let settings = try store.settings()
    for var a in try inFlight(slot.videoId) where a.kind == .retry {
      let at = YouTubeWindow.clear(exact, a.platform)
      var r = try store.autoRetries(a)
      if r.lastPostId == a.id, r.nextRetryAt != at {
        r.nextRetryAt = at  // or a day later it would count as stuck
        try store.setKV(PostizService.autoRetryKey(a), r)
      }
      guard a.scheduledAt != at || a.planSlotId != slot.id else { continue }
      a.scheduledAt = at
      a.planSlotId = slot.id
      if a.state == .due || a.state == .overdue { a.state = a.renderId == nil ? .planned : .rendered }
      try store.save(a, note: "retry moved to the set time → \(Sched.shortTime(at, settings))")
    }
    var waiting = 0
    for var f in try store.posts(where: "video_id=? AND state='failed' AND resolution IS NULL", [slot.videoId]) where try store.retryIsComing(f) {
      var r = try store.autoRetries(f)
      r.nextRetryAt = YouTubeWindow.clear(exact, f.platform)
      try store.setKV(PostizService.autoRetryKey(f), r)
      if f.planSlotId != slot.id {
        f.planSlotId = slot.id  // the attempt takes its failure's card
        try store.save(f, note: "its retry goes at the set time")
      }
      waiting += 1
    }
    return waiting
  }

  /// Un-posted posts deleted, history and retries taken off the card, the slot gone.
  func dropSlot(_ s: PlanSlot) throws {
    try clearSlot(s)
    try store.deletePlanSlot(s.id)
  }

  /// The first free position from `exactBase` up on `date` (UNIQUE(date, position)).
  func freeExactPosition(on date: String, excluding id: String? = nil) throws -> Int {
    let used = Set(try store.planSlots(where: "date=?", [date]).filter { $0.id != id }.map(\.position))
    var p = PlanSlot.exactBase
    while used.contains(p) { p += 1 }
    return p
  }

  /// One regular post of the slot's own clip per active platform it's usable on and has no post for yet, at the slot's
  /// set time (YouTube out of the quiet window). No `Placer`, no `PlatformPicker`: a set-time post takes no
  /// (platform, day, position) and never pulls another clip. `notBefore`: a platform whose time comes earlier gets none.
  func createExactPosts(_ s: PlanSlot, settings: Settings, notBefore: Date? = nil) throws {
    guard let exact = s.exactAt else { return }
    let existing = Set(try store.slotPosts(s.id).filter { $0.kind == .regular }.map(\.platform))
    let now = store.clock.now
    for p in settings.activePlatforms where !existing.contains(p) {
      guard try usable(s.videoId, on: p) else { continue }
      let at = YouTubeWindow.clear(exact, p)
      if let notBefore, at < notBefore { continue }
      try store.save(PlatformPost(
        id: newId(), videoId: s.videoId, platform: p, versionNo: 1, attemptNo: try store.nextAttemptNo(videoId: s.videoId, platform: p),
        kind: .regular, planSlotId: s.id, scheduledAt: at,
        renderId: nil, state: .planned, publisher: "manual", externalId: nil, url: nil, postedAt: nil, errorType: nil,
        errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now),
        note: at == exact ? "set time" : "set time (YouTube's quiet window: 07:30 UTC)")
    }
    try store.refreshState(videoId: s.videoId)
  }

  /// A set-time slot moved to another day keeps its clock time there. It never swaps with or displaces another slot.
  /// Refused when that clock time doesn't exist on the new day (the clocks go forward), rather than drift an hour for good.
  func moveExactSlot(_ s: inout PlanSlot, to date: String, settings: Settings, dm: DayMath) throws {
    guard let exact = s.exactAt, date != s.date else { return }
    let c = dm.calendar.dateComponents([.hour, .minute], from: exact)
    let to = try Self.exactDate(day: date, minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0), settings: settings)
    if let why = exactTimeProblem(to) { throw EngineError(why) }
    try refuseTooLate(videoId: s.videoId)
    try clearSlot(s)
    let week = dm.weekStart(of: dm.date(date))
    try approve(week: week, at: store.clock.now)
    s.date = date
    s.position = try freeExactPosition(on: date, excluding: s.id)
    s.weekStart = week
    s.exactAt = to
    s.pinned = true
    try store.save(s)
    try carryRetries(to: s)
    try createExactPosts(s, settings: settings)
    try store.logEvent("plan", StageWording.setFor(to, settings: settings), videoId: s.videoId)
  }
}

extension Store {
  /// The post sits on a set-time slot.
  func hasSetTime(_ p: PlatformPost) throws -> Bool {
    try p.planSlotId.flatMap { try planSlot(id: $0) }?.isExact == true
  }
}
