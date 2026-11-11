import Foundation

/// Round 21 (DECISIONS-R21.md, D12–D14): "Post at a set time". Eric picks an exact day and time for an item and every
/// platform it posts to goes out at that minute.
///
/// The model is a `PlanSlot` with `exactAt` set:
/// - always pinned, `date` = the local day of `exactAt`, `position` = the first free one from `PlanSlot.exactBase` up, so
///   it never takes one of the day's regular positions (`0..<postsPerDay`) and two set-time items can share a day;
/// - its week is marked approved the way `autoSchedule` does, and it holds one regular `PlatformPost` per usable
///   platform at `exactAt`: always the slot's own clip, never another clip pulled by a per-platform sort. YouTube inside
///   the quiet window goes through `YouTubeWindow.clear` like every other YouTube time;
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
    }

    public struct Skipped: Codable, Sendable, Equatable {
      public enum Reason: String, Codable, Sendable {
        /// Turned off for this item in the editor (a photo post's YouTube is always off).
        case off
        /// Marked as already posted there.
        case posted
        /// It already has a post there (one that failed or was skipped, or a retry on its way).
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
    /// What Eric should read first: "YouTube moves to 2:30 AM (07:30 UTC)".
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
    return dm.at(day, minutes: n[3] * 60 + n[4])
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
  /// it the next open day. Refused once something posted.
  public func clearExact(videoId: String) throws {
    try store.db.transaction {
      let slots = try store.planSlots(where: "video_id=? AND exact_at IS NOT NULL", [videoId])
      guard !slots.isEmpty else { throw EngineError(StageWording.noSetTime) }
      for s in slots {
        try ensureNothingPosted(s)
        try ensureNothingFinal(s)
      }
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
        let posts = try store.slotPosts(r.slot.id).filter { $0.kind == .regular && !$0.state.isTerminal }
        out.platforms = posts.sorted { $0.platform < $1.platform }.map { ExactPreview.Line(platform: $0.platform, at: $0.scheduledAt, moved: $0.scheduledAt != at) }
        let going = Set(posts.map(\.platform))
        let edit = try store.edit(videoId: videoId)
        for p in settings.activePlatforms.sorted() where !going.contains(p) {
          let reason: ExactPreview.Skipped.Reason = v.alreadyPostedOn.contains(p) ? .posted
            : edit.isSkipped(p, defaults: settings.defaults) ? .off : .history
          out.skipped.append(.init(platform: p, reason: reason, why: Self.words(reason, p)))
        }
        out.notes = out.platforms.filter { $0.moved && $0.platform == .youtube }
          .map { StageWording.youtubeMoves(to: $0.at, setFor: at, settings: settings) }
        throw PreviewRollback()
      }
    } catch is PreviewRollback {
    } catch let e as EngineError {
      out.blocker = e.message
    }
    return out
  }

  static func words(_ r: ExactPreview.Skipped.Reason, _ p: Platform) -> String {
    switch r {
    case .off: "\(p.displayName) is off for it"
    case .posted: "Already posted on \(p.displayName)"
    case .history: "It already has a post on \(p.displayName)"
    }
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
    for s in old { try ensureNothingFinal(s) }
    for s in old { try dropSlot(s) }
    guard try settings.activePlatforms.contains(where: { try usable(videoId, on: $0) }) else {
      throw EngineError("\(v.tag) has nowhere left to post: every platform is done or off for it")
    }
    let day = dm.key(at)
    let week = dm.weekStart(of: dm.date(day))
    try approve(week: week, at: store.clock.now)
    let slot = PlanSlot(id: old.first?.id ?? newId(), date: day, position: try freeExactPosition(on: day), videoId: videoId,
                        pinned: true, weekStart: week, exactAt: at)
    try store.save(slot)
    try createExactPosts(slot, settings: settings)
    try store.refreshState(videoId: videoId)
    return (slot, old, true)
  }

  /// `remove(slotId:)` without its checks: automatic retries dropped, un-posted posts deleted, history detached.
  func dropSlot(_ s: PlanSlot) throws {
    try store.dropAutoRetries(slot: s)
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
  func createExactPosts(_ s: PlanSlot, settings: Settings, note: String = "set time", notBefore: Date? = nil) throws {
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
        note: at == exact ? note : "\(note) (YouTube's quiet window: 07:30 UTC)")
    }
    try store.refreshState(videoId: s.videoId)
  }

  /// A set-time slot moved to another day keeps its clock time there. It never swaps with or displaces another slot.
  func moveExactSlot(_ s: inout PlanSlot, to date: String, settings: Settings, dm: DayMath) throws {
    guard let exact = s.exactAt, date != s.date else { return }
    let c = dm.calendar.dateComponents([.hour, .minute], from: exact)
    let to = dm.at(date, minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    if let why = exactTimeProblem(to) { throw EngineError(why) }
    try clearSlot(s)
    let week = dm.weekStart(of: dm.date(date))
    try approve(week: week, at: store.clock.now)
    s.date = date
    s.position = try freeExactPosition(on: date, excluding: s.id)
    s.weekStart = week
    s.exactAt = to
    s.pinned = true
    try store.save(s)
    try createExactPosts(s, settings: settings)
    try store.logEvent("plan", StageWording.setFor(to, settings: settings), videoId: s.videoId)
  }
}
