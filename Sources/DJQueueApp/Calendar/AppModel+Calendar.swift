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
      && pinPrompt == nil && !ListPrefs.shared.screenDialogOpen && BrowseUI.shared.quickLook == nil
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

  /// The clips going out on `day`, in slot order, narrowed by the platform filter.
  func calendarClips(_ day: String) -> [CalendarClip] {
    let filter = calendarFilter
    return (calendarData.slots[day] ?? []).compactMap { s -> CalendarClip? in
      guard let v = video(s.videoId) else { return nil }
      let posts = slotPosts(s.id)
      let platforms = shownPlatforms(posts, filter: filter)
      return platforms.isEmpty ? nil : CalendarClip(slot: s, video: v, posts: posts, platforms: platforms)
    }
  }

  private func shownPlatforms(_ posts: [Platform: PlatformPost], filter: Platform?) -> [Platform] {
    let withPosts = Set(posts.keys)
    let active = settings.activePlatforms
    let all = withPosts.isEmpty ? active : active.filter(withPosts.contains) + withPosts.subtracting(active).sorted()
    return filter.map { f in all.filter { $0 == f } } ?? all
  }

  /// Retries and reposts on `day` (no plan slot), in time order.
  func calendarExtras(_ day: String) -> [PlatformPost] {
    let filter = calendarFilter
    return (calendarData.posts[day] ?? []).filter { $0.planSlotId == nil && (filter == nil || $0.platform == filter) }
  }

  /// Day view: every post of the day grouped by clip, in time order. Today also takes overdue leftovers from earlier
  /// days. A slot with no posts yet still gets its group.
  func calendarDayGroups(_ day: String) -> [CalendarDayGroup] {
    let filter = calendarFilter
    let source = day == todayKey ? todayPosts : (calendarData.posts[day] ?? [])
    let posts = source.filter { filter == nil || $0.platform == filter }
    var order: [String] = []
    var byVideo: [String: [PlatformPost]] = [:]
    for p in posts {
      if byVideo[p.videoId] == nil { order.append(p.videoId) }
      byVideo[p.videoId, default: []].append(p)
    }
    let slots = calendarData.slots[day] ?? []
    var groups = order.map { id in
      CalendarDayGroup(videoId: id, video: video(id), slot: slots.first { $0.videoId == id }, posts: byVideo[id] ?? [], platforms: [])
    }
    for c in calendarClips(day) where byVideo[c.slot.videoId] == nil {
      groups.append(CalendarDayGroup(videoId: c.slot.videoId, video: c.video, slot: c.slot, posts: [], platforms: c.platforms))
    }
    return groups
  }

  /// True when no day on screen has anything for the platform filter.
  var calendarFilterIsEmpty: Bool {
    guard let f = calendarFilter else { return false }
    return !calendarDays.contains { d in
      !calendarClips(d).isEmpty || (calendarData.posts[d] ?? []).contains { $0.platform == f && $0.planSlotId == nil }
    }
  }

  /// When a clip's post goes out on `p`: the post's time, or the slot's time while it has no post yet.
  func calendarTime(_ c: CalendarClip, _ p: Platform) -> Date {
    c.posts[p]?.scheduledAt
      ?? dm.at(c.slot.date, minutes: settings.slot(for: p) + c.slot.position * settings.secondPostOffsetMinutes)
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
    c.posts[p].map(postStatus) ?? .planned
  }

  /// "TikTok · 7:00 PM · Rendered" (hover on any platform, in every view).
  func calendarPlatformHelp(_ c: CalendarClip, _ p: Platform) -> String {
    let post = c.posts[p]
    let state = post.flatMap { $0.resolution == nil ? postizState($0)?.text : nil } ?? calendarStatus(c, p).text
    return "\(p.displayName) · \(Self.clockText(calendarTime(c, p), tz: tz)) · \(state)"
  }

  /// The icon state for a platform on a card or a month chip.
  func calendarIconState(_ s: DSXPostStatus) -> DSPlatformState {
    switch s {
    case .posted: .posted
    case .failed, .copyright: .failed
    case .dueNow, .late: .due
    case .skipped, .resolved: .skipped
    default: .planned
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
    guard let slot else { return "A retry or repost has no day to move" }
    if slot.date < todayKey { return "Past days are fixed" }
    if let p = posts.values.filter({ $0.state == .posted }).min(by: { $0.platform < $1.platform }) {
      return "Posted on \(p.platform.displayName), so it stays on this day"
    }
    return nil
  }

  /// Queue clips still waiting for a day, in Queue order.
  var calendarBacklog: [Video] {
    let planned = Set(upcomingSlots.map(\.videoId))
    return ordered.filter { !planned.contains($0.id) }
  }

  // MARK: Schedule words

  /// "Scheduled through Sat 7 Nov" · "Nothing scheduled" (the chip, the low card).
  var scheduledText: String { StageWording.scheduledThrough(runway.scheduledThrough, settings: settings) }

  /// Fewer days scheduled than the Low Queue alert, and nothing waiting to fill them.
  var queueRunningLow: Bool { runway.isLow(settings) }

  // MARK: Actions

  /// Slot → day, pinned so nothing re-lays it. A full day swaps (Planner.moveSlot) and the toast names the other clip.
  /// Past days and posted slots refuse here, in words, before anything is written.
  @discardableResult
  func calendarMove(slotId: String, to day: String) -> Bool {
    guard day >= todayKey else { show("Past days can't be changed", error: true); return false }
    let all = calendarData.slots.values.joined()
    guard let s = all.first(where: { $0.id == slotId }) ?? upcomingSlots.first(where: { $0.id == slotId }), s.date != day else { return false }
    let label = Fmt.day(dm.date(day), tz: tz)
    if s.date < todayKey { show("That clip already went out", error: true); return false }
    if let p = (postsBySlot[s.id] ?? []).first(where: { $0.state == .posted }) {
      show("Posted on \(p.platform.displayName), so it stays on its day", error: true)
      return false
    }
    let here = (calendarData.slots[day] ?? []).filter { $0.id != s.id }
    var other: PlanSlot?
    if here.count >= max(1, settings.postsPerDay) { other = here.first { $0.position == s.position } ?? here.first }
    if let o = other {
      let name = video(o.videoId).map(displayName) ?? "that clip"
      if o.pinned { show("“\(name)” is pinned to \(label). Move it first", error: true); return false }
      if (postsBySlot[o.id] ?? []).contains(where: { $0.state == .posted }) {
        show("“\(name)” already posted on \(label). Pick another day", error: true)
        return false
      }
    }
    let swapped = other.flatMap { video($0.videoId) }.map { "Moved to \(label) · swapped with “\(displayName($0))”" }
    return undoable(swapped ?? "Moved to \(label)", "move", ids: [s.videoId] + (other.map { [$0.videoId] } ?? []), plan: true) {
      try planner.pin(videoId: s.videoId, date: day)
    }
  }

  /// "Post today" for one clip from a card or a menu (same path as Queue).
  func calendarPostToday(_ videoId: String) {
    pipelineBulk("Post today?", verb: "Post today", ids: [videoId], done: "Posting today") { b, dry in try b.postToday([videoId], dryRun: dry) }
  }

  /// Unschedule: back one stage through `stageBack`, with the Calendar's own words.
  func calendarUnschedule(_ videoId: String) {
    if let why = removeFromQueueBlocker([videoId]) { show(why, error: true); return }
    stageBack([videoId], unschedule: true)
  }
}
