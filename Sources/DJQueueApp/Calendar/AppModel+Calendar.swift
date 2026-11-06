import AppKit
import DJQCore
import SwiftUI

/// Calendar state, reads and moves. Data comes from `calendarData` (loaded off-main by `refresh`); nothing here
/// touches the database except the writes, which go through the same journaled actions as everywhere else.
extension AppModel {
  /// The day the view is anchored on (following today until Eric steps away from it).
  var calendarDay: String { calendarAnchor.isEmpty ? todayKey : calendarAnchor }
  var calendarVisible: CalendarRange { CalendarRange.visible(calendarMode, anchor: calendarDay, dm: dm) }
  var calendarDays: [String] { calendarVisible.days(dm: dm) }
  /// True once the data for what's on screen has landed.
  var calendarLoaded: Bool { loaded && (calendarData.range?.covers(calendarVisible) ?? false) }
  /// Where the awake strip's data starts: the view, at most two weeks back. Month has no strip.
  var calendarAwakeFrom: String? { calendarMode == .month ? nil : max(calendarVisible.first, calendarAwakeLimit) }
  /// Older days show no strip: their heartbeats aren't worth reading on every refresh.
  var calendarAwakeLimit: String { dm.addDays(todayKey, -14) }

  /// The platform filter, ignored once that platform is off.
  var calendarFilter: Platform? { calendarPlatform.flatMap { settings.activePlatforms.contains($0) ? $0 : nil } }

  /// Toolbar subtitle: "Thu 5 Nov" · "5 – 7 Nov" · "2 – 8 Nov" · "30 Nov – 2 Dec" · "November 2026".
  var calendarRangeText: String {
    switch calendarMode {
    case .day: return Fmt.day(dm.date(calendarDay), tz: tz, style: "EEE d MMM")
    case .month: return Fmt.day(dm.date(calendarDay), tz: tz, style: "MMMM yyyy")
    case .threeDay, .week:
      let r = calendarVisible
      let a = dm.date(r.first), b = dm.date(r.last)
      if Fmt.day(a, tz: tz, style: "yyyyMM") == Fmt.day(b, tz: tz, style: "yyyyMM") {
        return "\(Fmt.day(a, tz: tz, style: "d")) – \(Fmt.day(b, tz: tz, style: "d MMM"))"
      }
      return "\(Fmt.day(a, tz: tz, style: "d MMM")) – \(Fmt.day(b, tz: tz, style: "d MMM"))"
    }
  }

  /// This week's and the shown week's first day (`weekStartsOn`).
  var thisWeek: String { planner.weekStart(for: now) }
  var shownWeek: String { dm.weekStart(of: dm.date(calendarDay)) }

  /// "Week of 2 Nov".
  func weekTitle(_ ws: String) -> String { "Week of \(Fmt.day(dm.date(ws), tz: tz, style: "d MMM"))" }

  /// "This week" / "Next week" / "Last week" / "26 Oct – 1 Nov".
  func weekContext(_ ws: String) -> String {
    let tw = thisWeek
    if ws == tw { return "This week" }
    if ws == dm.addDays(tw, 7) { return "Next week" }
    if ws == dm.addDays(tw, -7) { return "Last week" }
    return "\(Fmt.day(dm.date(ws), tz: tz, style: "d MMM")) – \(Fmt.day(dm.date(dm.addDays(ws, 6)), tz: tz, style: "d MMM"))"
  }

  // MARK: Navigation

  /// A view switch by Eric: remembered across launches.
  func setCalendarMode(_ m: CalendarViewMode) {
    calendarMode = m
    if !Self.isSnapshotRun { UserDefaults.standard.set(m.rawValue, forKey: "djq.calendar.mode") }
  }

  func setCalendarPlatform(_ p: Platform?) {
    calendarPlatform = p
    if !Self.isSnapshotRun { UserDefaults.standard.set(p?.rawValue, forKey: "djq.calendar.platform") }
  }

  func stepCalendar(_ n: Int) { calendarAnchor = CalendarRange.stepped(calendarDay, mode: calendarMode, by: n, dm: dm) }
  func calendarToday() { calendarAnchor = "" }

  /// Day view on `day` for this session (a click or a deep link, so the remembered view stays what Eric chose).
  func openCalendarDay(_ day: String? = nil) {
    calendarAnchor = day == nil || day == todayKey ? "" : day!
    calendarMode = .day
    editor = nil
    screen = .calendar
  }

  /// Saved prefs (AppModel.loadPersistedPrefs): default Week, all platforms.
  func loadCalendarPrefs() {
    let d = UserDefaults.standard
    if let raw = d.string(forKey: "djq.calendar.mode"), let m = CalendarViewMode(rawValue: raw) { calendarMode = m }
    if let raw = d.string(forKey: "djq.calendar.platform"), let p = Platform(rawValue: raw) { calendarPlatform = p }
  }

  /// No dialog, sheet or in-window overlay is up (plain keys belong to whatever is on top).
  var noOverlayOpen: Bool {
    editor == nil && !showSettings && !showPalette && !showShortcuts && pendingBulk == nil && pendingConfirm == nil
      && previewVideo == nil && markPostedTarget == nil && reportTarget == nil && longformTarget == nil && scorePrompt == nil
      && pinPrompt == nil && captionDialogIds == nil && cropDialogIds == nil && !ListPrefs.shared.screenDialogOpen && BrowseUI.shared.quickLook == nil
      && BrowseUI.shared.longformTargets.isEmpty && BrowseUI.shared.scoreTargets.isEmpty && BrowseUI.shared.pendingPostBulk == nil
  }

  /// D · 3 · W · M · T · ← → on the Calendar. False = not ours: the event goes on (typing in a field, an overlay).
  func handleCalendarKey(_ e: NSEvent) -> Bool {
    guard screen == .calendar, noOverlayOpen, !ShortcutButtons.textFieldIsEditing else { return false }
    let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
    guard mods.isEmpty else { return false }
    switch e.keyCode {
    case 123: stepCalendar(-1); return true
    case 124: stepCalendar(1); return true
    default: break
    }
    switch e.charactersIgnoringModifiers?.lowercased() {
    case "d": setCalendarMode(.day)
    case "3": setCalendarMode(.threeDay)
    case "w": setCalendarMode(.week)
    case "m": setCalendarMode(.month)
    case "t": calendarToday()
    default: return false
    }
    return true
  }

  // MARK: Reads

  /// Latest attempt per platform for a plan slot.
  func slotPosts(_ slotId: String) -> [Platform: PlatformPost] {
    Dictionary((postsBySlot[slotId] ?? []).map { ($0.platform, $0) }, uniquingKeysWith: { a, b in a.attemptNo > b.attemptNo ? a : b })
  }

  /// The clips going out on `day`, in slot order, narrowed by the platform filter. Built from the posts that really go
  /// out that day: a post shifted off this day shows on its own day (`calendarExtras`), not on this card.
  func calendarClips(_ day: String) -> [CalendarClip] {
    let filter = calendarFilter
    let todays = calendarData.posts[day] ?? []
    return (calendarData.slots[day] ?? []).compactMap { s -> CalendarClip? in
      guard let v = video(s.videoId) else { return nil }
      let posts = slotPosts(s.id)
      let onDay = Dictionary(todays.filter { $0.planSlotId == s.id }.map { ($0.platform, $0) },
                             uniquingKeysWith: { a, b in a.attemptNo > b.attemptNo ? a : b })
      if !posts.isEmpty && onDay.isEmpty { return nil }
      let platforms = shownPlatforms(onDay, filter: filter)
      return platforms.isEmpty ? nil : CalendarClip(slot: s, video: v, posts: posts, dayPosts: onDay, platforms: platforms)
    }
  }

  private func shownPlatforms(_ posts: [Platform: PlatformPost], filter: Platform?) -> [Platform] {
    let withPosts = Set(posts.keys)
    let active = settings.activePlatforms
    let all = withPosts.isEmpty ? active : active.filter(withPosts.contains) + withPosts.subtracting(active).sorted()
    return filter.map { f in all.filter { $0 == f } } ?? all
  }

  /// Posts on `day` that no card there carries, in time order: retries, reposts, and posts shifted here from their
  /// clip's own day.
  func calendarExtras(_ day: String) -> [PlatformPost] {
    let filter = calendarFilter
    let here = Set((calendarData.slots[day] ?? []).map(\.id))
    return (calendarData.posts[day] ?? []).filter { p in
      guard filter == nil || p.platform == filter else { return false }
      guard let slot = p.planSlotId else { return true }
      return !here.contains(slot) && slotPosts(slot)[p.platform]?.id == p.id
    }
  }

  /// Day view: every post of the day grouped by clip, in time order. Today also takes overdue leftovers from earlier
  /// days. A slot with no posts yet still gets its group.
  func calendarDayGroups(_ day: String) -> [CalendarDayGroup] {
    let filter = calendarFilter
    let source = day == todayKey ? todayPosts : withoutRetriedFailures(calendarData.posts[day] ?? [])
    let posts = source.filter { filter == nil || $0.platform == filter }
    var order: [String] = []
    var byVideo: [String: [PlatformPost]] = [:]
    for p in posts {
      if byVideo[p.videoId] == nil { order.append(p.videoId) }
      byVideo[p.videoId, default: []].append(p)
    }
    let slots = calendarData.slots[day] ?? []
    var groups = order.map { id in
      let own = byVideo[id] ?? []
      let slot = slots.first { $0.videoId == id } ?? own.lazy.compactMap { $0.planSlotId.flatMap { self.calendarData.slotById[$0] } }.first
      return CalendarDayGroup(videoId: id, video: video(id), slot: slot, posts: own, platforms: [])
    }
    for c in calendarClips(day) where byVideo[c.slot.videoId] == nil {
      groups.append(CalendarDayGroup(videoId: c.slot.videoId, video: c.video, slot: c.slot, posts: [], platforms: c.platforms))
    }
    return groups
  }

  /// True when no day on screen has anything for the platform filter.
  var calendarFilterIsEmpty: Bool {
    guard calendarFilter != nil else { return false }
    return !calendarDays.contains { !calendarClips($0).isEmpty || !calendarExtras($0).isEmpty }
  }

  /// A clip holds this day, whatever the filter shows.
  func calendarDayIsTaken(_ day: String) -> Bool { !(calendarData.slots[day] ?? []).isEmpty }

  /// The engine can still fill this day: same rule as `Planner.isOpen`, a free position with time left before it.
  func calendarDayCanFill(_ day: String) -> Bool {
    guard day >= todayKey else { return false }
    let used = Set((calendarData.slots[day] ?? []).map(\.position))
    let limit = now.addingTimeInterval(Planner.autoScheduleLead)
    let dm = self.dm
    return (0..<max(1, settings.postsPerDay)).contains { pos in
      !used.contains(pos) && (settings.activePlatforms.map { settings.slotTime($0, date: day, position: pos, dm) }.min() ?? limit) >= limit
    }
  }

  /// When a clip's post goes out on `p`: the post's time, or the slot's time while it has no post yet.
  func calendarTime(_ c: CalendarClip, _ p: Platform) -> Date {
    c.dayPosts[p]?.scheduledAt
      ?? settings.slotTime(p, date: c.slot.date, position: c.slot.position, dm)
  }

  /// "12:30 PM – 7 PM" across the platforms shown (one time when they're all the same).
  func calendarTimeRange(_ c: CalendarClip) -> String {
    let times = c.platforms.map { calendarTime(c, $0) }
    guard let lo = times.min(), let hi = times.max() else { return "" }
    return lo == hi ? Self.shortClock(lo, tz: tz) : "\(Self.shortClock(lo, tz: tz)) – \(Self.shortClock(hi, tz: tz))"
  }

  /// "7 PM" on the hour, "12:30 PM" otherwise.
  static func shortClock(_ d: Date, tz: TimeZone) -> String {
    Fmt.day(d, tz: tz, style: Fmt.day(d, tz: tz, style: "mm") == "00" ? "h a" : "h:mm a")
  }

  func calendarStatus(_ c: CalendarClip, _ p: Platform) -> DSXPostStatus {
    c.dayPosts[p].map(postStatus) ?? .planned
  }

  /// "TikTok · 7:00 PM · Rendered" (hover on any platform, in every view).
  func calendarPlatformHelp(_ c: CalendarClip, _ p: Platform) -> String {
    let state = c.dayPosts[p].flatMap { postizRowState($0)?.text } ?? calendarStatus(c, p).text
    return "\(p.displayName) · \(Self.clockText(calendarTime(c, p), tz: tz)) · \(state)"
  }

  /// "TikTok: Retrying Fri 8:00 AM": the next try of the first post on this card that failed and has one coming.
  func calendarRetryNote(_ c: CalendarClip) -> String? {
    for p in c.platforms {
      if let s = c.dayPosts[p].flatMap({ postizRowState($0) }), s.isRetrying { return "\(p.dsxCompactName): \(s.text)" }
    }
    return nil
  }

  /// The icon state for a platform on a card. A retry coming isn't a problem, so it reads as planned.
  func calendarIconState(_ c: CalendarClip, _ p: Platform) -> DSPlatformState {
    if c.dayPosts[p].flatMap({ postizRowState($0) })?.isRetrying == true { return .planned }
    switch calendarStatus(c, p) {
    case .posted: return .posted
    case .failed, .copyright: return .failed
    case .dueNow, .late: return .due
    case .skipped, .resolved: return .skipped
    default: return .planned
    }
  }

  /// "1 failed" / "2 late", or nil when nothing shown needs Eric.
  func calendarProblem(_ c: CalendarClip) -> (text: String, tone: DSTone)? {
    let tones = c.platforms.compactMap { calendarStatus(c, $0).problemTone }
    let failed = tones.filter { $0 == .danger }.count
    if failed > 0 { return ("\(failed) failed", .danger) }
    return tones.isEmpty ? nil : ("\(tones.count) late", .warning)
  }

  /// Why this clip can't leave its day (nil = it can).
  func calendarMoveBlocker(_ slot: PlanSlot?, posts: [Platform: PlatformPost]) -> String? {
    guard let slot else { return "Only this post is on this day" }
    if slot.date < todayKey { return "Past days are fixed" }
    if let p = posts.values.filter({ $0.state == .posted }).min(by: { $0.platform < $1.platform }) {
      return "Posted on \(p.platform.displayName), so it stays on this day"
    }
    return nil
  }

  /// Clips beyond the schedule: the days are full out to the horizon and these are still waiting. Zero while paused or
  /// between ticks, when open days are about to take them.
  var calendarWaitingBeyondHorizon: Int {
    guard !settings.paused, let last = upcomingSlots.map(\.date).max(),
          last >= dm.addDays(todayKey, Planner.autoScheduleHorizonDays) else { return 0 }
    return schedulable.count
  }

  // MARK: Schedule words

  /// "Scheduled through Sat 7 Nov" · "Nothing scheduled" (the chip, the low card).
  var scheduledText: String { StageWording.scheduledThrough(runway.scheduledThrough, settings: settings) }

  /// Fewer days scheduled than the Low Queue alert, and nothing waiting to fill them.
  var queueRunningLow: Bool { runway.isLow(settings) }

  // MARK: Actions

  /// Slot → day, pinned so nothing re-lays it. A full day swaps (Planner.moveSlot) and the toast names the other clip.
  /// Past days and posted slots refuse here, in words, before anything is written. A landing on today inside the lead
  /// asks first; a swap that would put the other clip there is refused by the planner (`StageWording.todayTooSoon`).
  @discardableResult
  func calendarMove(slotId: String, to day: String, done: String = "Moved") -> Bool {
    guard day >= todayKey else { show("Past days can't be changed", error: true); return false }
    guard let s = calendarData.slotById[slotId] ?? upcomingSlots.first(where: { $0.id == slotId }), s.date != day else { return false }
    let label = Fmt.day(dm.date(day), tz: tz)
    if s.date < todayKey { show("That clip already went out", error: true); return false }
    if let p = (postsBySlot[s.id] ?? []).first(where: { $0.state == .posted }) {
      show("Posted on \(p.platform.displayName), so it stays on its day", error: true)
      return false
    }
    let here = upcomingSlots.filter { $0.date == day && $0.id != s.id }
    let perDay = max(1, settings.postsPerDay)
    var other: PlanSlot?
    if here.count >= perDay { other = here.first { $0.position == s.position } ?? here.first }
    if let o = other {
      let name = video(o.videoId).map(displayName) ?? "that clip"
      if o.pinned { show("“\(name)” is pinned to \(label). Move it first", error: true); return false }
      if (postsBySlot[o.id] ?? []).contains(where: { $0.state == .posted }) {
        show("“\(name)” already posted on \(label). Pick another day", error: true)
        return false
      }
    }
    let otherName = other.flatMap { video($0.videoId) }.map(displayName)
    let toast = "\(done) to \(label)" + (otherName.map { " · swapped with “\($0)”" } ?? "")
    let position = other?.position ?? (0..<perDay).first { p in !here.contains { $0.position == p } } ?? 0
    let videoId = s.videoId
    let soon = platformsTooSoon(videoId, day: day, position: position)
    if !soon.isEmpty {
      let swap = otherName.map { DSChangeList.Change(field: "Swaps with", value: "“\($0)”, which moves to \(Fmt.day(dm.date(s.date), tz: tz))") }
      askPostToday(videoId, platforms: soon, extra: swap, done: toast) { b, dry in try b.pinConsecutive([videoId], from: day, dryRun: dry) }
      return true
    }
    return undoable(toast, "move", ids: [videoId] + (other.map { [$0.videoId] } ?? []), plan: true) {
      try planner.pin(videoId: videoId, date: day)
    }
  }

  /// "Move to…" from a menu: the same checks and words as a drag.
  func calendarMove(videoId: String, to day: String) {
    guard let s = nextSlotByVideo[videoId] else { return }
    if s.date == day { show("Already on \(Fmt.day(dm.date(day), tz: tz))"); return }
    calendarMove(slotId: s.id, to: day)
  }

  // MARK: Going out right away

  /// Every pin from anywhere (Queue, ⌘K, a clip's menu, a drop on a Queue row): moves go through `calendarMove`, and a
  /// clip with no day asks first when it would land inside the lead.
  func pinAsking(_ videoId: String, to day: String, done: String) {
    let label = Fmt.day(dm.date(day), tz: tz)
    if let s = nextSlotByVideo[videoId], s.date != day {
      calendarMove(slotId: s.id, to: day, done: done)
      return
    }
    let soon = nextSlotByVideo[videoId] == nil ? platformsTooSoon(videoId, day: day) : []
    if soon.isEmpty {
      undoable("\(done) to \(label)", "pin", ids: [videoId], plan: true) { try planner.pin(videoId: videoId, date: day) }
      return
    }
    let here = upcomingSlots.filter { $0.date == day }
    let replaced = here.count >= max(1, settings.postsPerDay) ? here.first { !$0.pinned }.flatMap { video($0.videoId) } : nil
    let row = replaced.map { DSChangeList.Change(field: "Replaces", value: "“\(displayName($0))”, which goes back to waiting") }
    askPostToday(videoId, platforms: soon, extra: row, done: "\(done) to \(label)") { b, dry in try b.pinConsecutive([videoId], from: day, dryRun: dry) }
  }

  /// Post today, from anywhere: always asks, and names what goes out at once.
  func postTodayAsking(_ ids: [String]) {
    guard let first = ids.first else { return }
    let b = bulk
    let n = AppModel.pipelineClips(ids.count)
    let changes = [DSChangeList.Change(field: "Day", value: "Today · the rest of the Calendar moves a day later")]
      + goesOutRow(platformsTooSoon(first, day: todayKey))
    requestBulk(BulkRequest(title: ids.count == 1 ? "Post today?" : "Post \(n) today?", verb: "Post today", ids: ids, changes: changes,
                            doneMessage: ids.count == 1 ? "Posting today" : nil, alwaysConfirm: true) { dry in try b.postToday(ids, dryRun: dry) })
  }

  /// Platforms that would go out inside the lead if this clip landed on `day`: only ever today. Its own platforms when
  /// it has posts (minus the finished ones, which get no new post), else every active one.
  func platformsTooSoon(_ videoId: String, day: String, position: Int? = nil) -> [Platform] {
    guard day == todayKey else { return [] }
    let posts = nextSlotByVideo[videoId].map { slotPosts($0.id) } ?? [:]
    let live = posts.filter { !$0.value.state.isTerminal }
    let limit = now.addingTimeInterval(Planner.autoScheduleLead)
    let pos = position ?? openPosition(on: day, for: videoId)
    let dm = self.dm
    return settings.activePlatforms.filter { p in
      (posts.isEmpty || live[p] != nil) && settings.slotTime(p, date: day, position: pos, dm) < limit
    }
  }

  /// The position a clip lands on: the first free one, else the first clip that isn't pinned.
  private func openPosition(on day: String, for videoId: String) -> Int {
    let here = upcomingSlots.filter { $0.date == day && $0.videoId != videoId }
    return (0..<max(1, settings.postsPerDay)).first { p in !here.contains { $0.position == p } } ?? here.first { !$0.pinned }?.position ?? 0
  }

  /// The confirmation's "Goes out right away: Facebook, Threads" row; nothing when nothing does.
  func goesOutRow(_ platforms: [Platform]) -> [DSChangeList.Change] {
    platforms.isEmpty ? [] : [.init(field: "Goes out right away", value: platforms.map(\.displayName).joined(separator: ", "))]
  }

  /// The Post today confirmation, so Eric can still say no.
  private func askPostToday(_ videoId: String, platforms: [Platform], extra: DSChangeList.Change? = nil, done: String,
                            _ body: @escaping @Sendable (BulkActions, Bool) throws -> BulkResult) {
    let b = bulk
    requestBulk(BulkRequest(title: "Post today?", verb: "Post today", ids: [videoId],
                            changes: goesOutRow(platforms) + (extra.map { [$0] } ?? []),
                            doneMessage: done, alwaysConfirm: true) { dry in try body(b, dry) })
  }

  /// False for a post just past midnight: its time runs over from the slot's own day, and nothing moved it.
  func calendarWasMoved(_ p: PlatformPost) -> Bool {
    guard let s = p.planSlotId.flatMap({ calendarData.slotById[$0] }) else { return true }
    return dm.planDay(p.scheduledAt, position: s.position, slotDate: s.date, platform: p.platform,
                      offsetMinutes: settings.secondPostOffsetMinutes) != s.date
  }

  /// Why Unschedule isn't offered (nil = it is): past days are fixed, and only Queue and Scheduled clips have a day to
  /// give up.
  func calendarUnscheduleBlocker(_ video: Video, slot: PlanSlot?) -> String? {
    if let slot, slot.date < todayKey { return "Past days are fixed" }
    guard let stage = ClipStage.of(video), stage == .queue || stage == .scheduled else {
      return "It isn't in the Queue"
    }
    return removeFromQueueBlocker(video)
  }

  /// Unschedule: back one stage through `stageBack`, with the Calendar's own words.
  func calendarUnschedule(_ videoId: String) {
    if let why = video(videoId).flatMap({ removeFromQueueBlocker($0) }) { show(why, error: true); return }
    stageBack([videoId], unschedule: true)
  }
}
