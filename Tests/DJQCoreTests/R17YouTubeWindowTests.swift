import Foundation
import Testing
@testable import DJQCore

/// Round 17, rule changed in round 22: Postiz's YouTube quota resets at midnight Pacific (07:00 UTC in summer, 08:00 UTC
/// in winter) and is often gone hours before, so nothing on YouTube is scheduled from 19:00 to midnight Pacific, it goes
/// at 00:30 Pacific instead, quota retries go to the next YouTube slot after the reset, and `djq slot` moves a platform's
/// posts to a new time.
@Suite struct R17YouTubeWindowTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  static let quota = R8PostizRetryTests.quota
  let r8 = R8PostizRetryTests()

  func utc(_ day: String, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    let p = day.split(separator: "-").compactMap { Int($0) }
    return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour, minute: minute, second: second))!
  }

  /// A New York wall clock time, the summer or winter offset from the calendar.
  func ny(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
    DayMath(tz: TimeZone(identifier: "America/New_York")!).at(day, minutes: hour * 60 + minute)
  }

  /// A Los Angeles wall clock time.
  func pt(_ day: String, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    DayMath(tz: TimeZone(identifier: "America/Los_Angeles")!).at(day, minutes: hour * 60 + minute).addingTimeInterval(Double(second))
  }

  // MARK: The helper

  @Test(arguments: [(18, 59, 59, false), (19, 0, 0, true), (19, 0, 1, true), (21, 30, 0, true), (23, 59, 59, true), (0, 0, 0, false),
                    (0, 30, 0, false), (7, 0, 0, false), (15, 0, 0, false)])
  func theWindowsEdges(_ h: Int, _ m: Int, _ s: Int, _ quiet: Bool) {
    let d = pt("2026-11-04", h, m, s)
    #expect(YouTubeWindow.clear(d, .youtube) == (quiet ? pt("2026-11-05", 0, 30) : d))
  }

  @Test(arguments: Platform.allCases.filter { $0 != .youtube })
  func otherPlatformsNeverMove(_ p: Platform) {
    #expect(YouTubeWindow.clear(pt("2026-11-04", 20), p) == pt("2026-11-04", 20))
  }

  /// The window follows the Pacific clock, so in UTC it moves an hour with the clocks: 02:00–07:00 UTC in summer,
  /// 03:00–08:00 UTC in winter. 10:30 pm New York is 7:30 pm Pacific all year: always moved, to 00:30 Pacific (3:30 am
  /// New York, or 2:30 / 4:30 am on the two nights New York changes its clocks three hours before Los Angeles).
  @Test func theWindowIsPacificAcrossBothDSTChanges() {
    for day in ["2026-10-31", "2026-11-01", "2027-03-13", "2027-03-14"] {
      let next = DayMath(tz: TimeZone(identifier: "America/New_York")!).addDays(day, 1)
      #expect(YouTubeWindow.clear(ny(day, 22, 30), .youtube) == pt(next, 0, 30), "\(day)")
      #expect(YouTubeWindow.clear(ny(day, 21, 30), .youtube) == ny(day, 21, 30), "\(day)")
    }
    #expect(pt("2026-11-01", 0, 30) == ny("2026-11-01", 2, 30) && pt("2027-03-14", 0, 30) == ny("2027-03-14", 4, 30))
    // In UTC: 02:30 UTC is quiet in summer (7:30 pm PDT) and not in winter (6:30 pm PST); 07:30 UTC the other way round.
    #expect(YouTubeWindow.clear(utc("2026-10-20", 2, 30), .youtube) == utc("2026-10-20", 7, 30))
    #expect(YouTubeWindow.clear(utc("2026-11-20", 2, 30), .youtube) == utc("2026-11-20", 2, 30))
    #expect(YouTubeWindow.clear(utc("2026-10-20", 7, 30), .youtube) == utc("2026-10-20", 7, 30))
    #expect(YouTubeWindow.clear(utc("2026-11-20", 7, 30), .youtube) == utc("2026-11-20", 8, 30))
    // The change days themselves: the reset is the Pacific midnight, whatever its UTC offset that night.
    #expect(YouTubeWindow.nextReset(after: utc("2026-11-01", 6)) == utc("2026-11-01", 7))  // PDT midnight
    #expect(YouTubeWindow.nextReset(after: utc("2026-11-01", 7, 30)) == utc("2026-11-02", 8))  // the next is PST
    #expect(YouTubeWindow.nextReset(after: utc("2027-03-14", 7, 30)) == utc("2027-03-14", 8))  // PST midnight
    #expect(YouTubeWindow.nextReset(after: utc("2027-03-14", 9)) == utc("2027-03-15", 7))  // the next is PDT
    #expect(YouTubeWindow.isMoved(pt("2026-11-01", 0, 30)) && YouTubeWindow.isMoved(pt("2027-03-14", 0, 30)))
    #expect(!YouTubeWindow.isMoved(utc("2026-11-20", 7, 30)))
  }

  /// The note in Settings and `djq slot youtube`, in Eric's own clock.
  @Test func theSettingsNoteSaysItInPlainWords() {
    #expect(YouTubeWindow.settingsNote(TimeZone(identifier: "America/New_York")!, on: utc("2026-11-11", 12))
            == "10 pm–3 am moves to 3:30 am: Postiz's YouTube quota resets at midnight Pacific.")
    #expect(YouTubeWindow.settingsNote(TimeZone(identifier: "America/Los_Angeles")!, on: utc("2026-07-01", 12))
            == "7 pm–12 am moves to 12:30 am: Postiz's YouTube quota resets at midnight Pacific.")
    #expect(YouTubeWindow.settingsNote(TimeZone(identifier: "Europe/London")!, on: utc("2026-11-11", 12))
            == "3 am–8 am moves to 8:30 am: Postiz's YouTube quota resets at midnight Pacific.")
  }

  func settings(slot: Int = 8 * 60) -> Settings {
    var s = Settings()
    s.slotMinutes[.youtube] = slot
    return s
  }

  /// R2: the next YouTube slot from Settings, 30 min or more after the next Pacific reset and an hour after the failure.
  @Test func theQuotaRetryIsTheNextSlotAfterThePacificReset() {
    let s = settings()
    // The live case: failed Wed 11 Nov 07:30 UTC (11:30 pm Tuesday Pacific), slot 8:00 am New York.
    let live = PostizRetrySchedule.youTubeQuota(after: utc("2026-11-11", 7, 30), settings: s)
    #expect(live.reset == utc("2026-11-11", 8) && live.retry == utc("2026-11-11", 13))
    // PDT: midnight Pacific is 07:00 UTC.
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-10-20", 7, 30), settings: s).reset == utc("2026-10-21", 7))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-10-20", 7, 30), settings: s).retry == utc("2026-10-21", 12))
    #expect(PostizRetrySchedule.youTubeQuota(after: ny("2026-10-20", 23), settings: s).retry == ny("2026-10-21", 8))
    // November change day: 11:30 pm PDT on the 31st resets at 07:00 UTC; half past midnight PDT on the 1st waits for PST's.
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-01", 6, 30), settings: s).reset == utc("2026-11-01", 7))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-01", 6, 30), settings: s).retry == ny("2026-11-01", 8))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-01", 7, 30), settings: s).reset == utc("2026-11-02", 8))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-01", 7, 30), settings: s).retry == ny("2026-11-02", 8))
    // March change day.
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2027-03-14", 7, 30), settings: s).reset == utc("2027-03-14", 8))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2027-03-14", 7, 30), settings: s).retry == ny("2027-03-14", 8))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2027-03-14", 8, 30), settings: s).reset == utc("2027-03-15", 7))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2027-03-14", 8, 30), settings: s).retry == ny("2027-03-15", 8))
    // A slot inside the quiet window counts at its moved time, 00:30 Pacific: never before the reset + 30 min.
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-11", 7, 30), settings: settings(slot: 23 * 60)).retry == utc("2026-11-11", 8, 30))
    // A failure just after the reset still waits an hour, so the slot that day is taken only when it's far enough.
    #expect(PostizRetrySchedule.youTubeQuota(after: ny("2026-11-11", 7, 30), settings: s).retry == ny("2026-11-12", 8))
    // Every try waits for the quota; a YouTube failure over its media backs off like the others.
    #expect(PostizRetrySchedule.next(after: utc("2026-11-11", 7, 30), retry: 4, platform: .youtube, settings: s) == utc("2026-11-11", 13))
    #expect(PostizRetrySchedule.next(after: utc("2026-11-11", 7, 30), retry: 1, platform: .youtube, settings: s, quota: false)
            == utc("2026-11-11", 8, 30))
  }

  /// The failure's quiet-window time no longer decides anything: the summer and winter failure at the same Pacific time
  /// retry at the same New York slot.
  @Test func aFailureInPSTAndInPDTRetryOnTheSameLocalSlot() {
    let s = settings()
    #expect(PostizRetrySchedule.youTubeQuota(after: pt("2026-07-15", 23, 30), settings: s).retry == ny("2026-07-16", 8))
    #expect(PostizRetrySchedule.youTubeQuota(after: pt("2026-12-15", 23, 30), settings: s).retry == ny("2026-12-16", 8))
  }

  /// Stored under the old 07:00 UTC rule, a YouTube post at 07:30 UTC in winter is 11:30 pm Pacific: the engine moves
  /// it to 00:30 Pacific by itself, Postiz's copy follows, and posts out of the window and other platforms stay.
  @Test func storedPostsInTheWindowMoveOutByThemselves() throws {
    let rig = try Rig(3, platforms: [.youtube, .x]) { $0.enabledPlatforms = [.youtube, .x] }
    rig.settle()
    rig.f.setTime("2026-11-02", "06:00")
    let yts = try rig.f.posts(.youtube).sorted { $0.scheduledAt < $1.scheduledAt }
    var old = yts[1]
    old.scheduledAt = utc("2026-11-04", 7, 30)  // the old rule's moved time
    try rig.store.save(old, note: "test")
    var pinned = yts[2]
    pinned.scheduledAt = utc("2026-11-05", 7, 30)
    try rig.store.save(pinned, note: "test")
    var slot = try #require(try rig.store.planSlot(id: pinned.planSlotId!))
    slot.pinned = true
    try rig.store.save(slot)
    let x = try rig.f.posts(.x)
    rig.tick(2)
    #expect(try rig.store.post(id: old.id)?.scheduledAt == utc("2026-11-04", 8, 30))
    #expect(try rig.store.post(id: pinned.id)?.scheduledAt == utc("2026-11-05", 8, 30))  // the window applies to pins, as `clear` always did
    #expect(try rig.store.post(id: yts[0].id)?.scheduledAt == yts[0].scheduledAt)
    #expect(try rig.f.posts(.x).map(\.scheduledAt) == x.map(\.scheduledAt))
    #expect(try rig.job(rig.store.post(id: old.id)!)?.remoteDate == utc("2026-11-04", 8, 30))
    #expect(try Placer(store: rig.store, dm: rig.f.dm).isTaken(.youtube, day: "2026-11-03", position: 0))
    #expect(try rig.invariants().isEmpty)
    #expect(try rig.store.moveOutOfYouTubeWindow() == 0)  // nothing left to move
  }

  // MARK: Slot times

  /// One clip a day from Monday on YouTube alone, its slot late in the evening.
  func nightRig(_ n: Int = 3, slot: Int = 23 * 60) throws -> Rig {
    try Rig(n, platforms: [.youtube]) { s in
      s.enabledPlatforms = [.youtube]
      s.slotMinutes[.youtube] = slot
    }
  }

  @Test func aSlotInTheWindowGoesAt0030PacificAndOtherPlatformsStay() throws {
    var s = Settings()
    s.slotMinutes[.youtube] = 22 * 60
    s.slotMinutes[.x] = 22 * 60
    let dm = DayMath(settings: s)
    #expect(s.slotTime(.youtube, date: "2026-11-04", position: 0, dm) == utc("2026-11-05", 8, 30))  // 00:30 PST
    #expect(s.slotTime(.x, date: "2026-11-04", position: 0, dm) == utc("2026-11-05", 3))
    #expect(s.slotTime(.youtube, date: "2026-07-01", position: 0, dm) == utc("2026-07-02", 7, 30))  // 00:30 PDT
    s.slotMinutes[.youtube] = 8 * 60
    #expect(s.slotTime(.youtube, date: "2026-11-04", position: 0, dm) == utc("2026-11-04", 13))
    #expect(s.slotTime(.youtube, date: "2026-07-01", position: 0, dm) == utc("2026-07-01", 12))
  }

  /// A 23:00 slot posts at 3:30 am the next morning (00:30 Pacific) and still belongs to the day it was placed on, or
  /// `Placer` would see that day free and put a second clip on the same time.
  @Test func aNightSlotKeepsItsPlanDay() throws {
    let rig = try nightRig()
    let posts = try rig.store.posts(where: "platform='youtube' AND kind='regular'").sorted { $0.scheduledAt < $1.scheduledAt }
    #expect(posts.map(\.scheduledAt) == [utc("2026-11-03", 8, 30), utc("2026-11-04", 8, 30), utc("2026-11-05", 8, 30)])
    let dm = try rig.store.dayMath()
    #expect(try posts.map { try rig.store.planDay(of: $0, dm: dm) } == ["2026-11-02", "2026-11-03", "2026-11-04"])
    let placer = try Placer(store: rig.store, dm: dm)
    #expect(placer.isTaken(.youtube, day: "2026-11-02", position: 0))
    #expect(!placer.isTaken(.youtube, day: "2026-11-05", position: 0))
  }

  @Test func aReflowAcrossTheSpringChangeStaysOutOfTheWindow() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    var p = try #require(try rig.store.posts(where: "platform='youtube'").first)
    p.scheduledAt = utc("2027-03-13", 8, 30)  // 00:30 PST; two days on, 00:30 PDT is 07:30 UTC
    try rig.store.save(p, note: "test")
    try rig.store.reflow([p], days: 2, dm: try rig.store.dayMath(), note: "test")
    #expect(try rig.store.post(id: p.id)?.scheduledAt == utc("2027-03-15", 7, 30))
  }

  /// 19:00 + 3 h is 10 pm New York, 7 pm Pacific: in the window, so the extra post looks the other way.
  @Test func anExtraPostSkipsTheWindow() throws {
    let rig = try Rig(1, platforms: [.youtube]) { s in
      s.enabledPlatforms = [.youtube]
      s.slotMinutes[.youtube] = 19 * 60
    }
    let s = try rig.store.settings()
    #expect(try Sched.staggered(store: rig.store, platform: .youtube, day: "2026-11-10", settings: s, dm: rig.f.dm) == ny("2026-11-10", 16))
    #expect(try Sched.staggered(store: rig.store, platform: .x, day: "2026-11-10", settings: s, dm: rig.f.dm) != ny("2026-11-10", 16))
  }

  // MARK: Retries

  func extra(_ rig: Rig, _ x: PlatformPost, at time: Date) throws {
    var o = x
    o.id = newId()
    o.scheduledAt = time
    o.state = .rendered
    o.planSlotId = nil
    o.kind = .repost
    o.versionNo = 9
    o.renderId = nil
    try rig.store.save(o, note: "test")
  }

  @Test func aRetryNeverLandsInTheWindowAndKeepsTheStagger() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    let yt = try #require(try rig.store.posts(where: "platform='youtube'").first)
    let s = try rig.store.settings()
    func slot(_ t: Date, earliest: Date? = nil) throws -> Date {
      try Sched.retrySlot(store: rig.store, platform: .youtube, target: t, earliest: earliest, settings: s, excluding: [yt.id])
    }
    #expect(try slot(pt("2026-11-20", 20)) == pt("2026-11-21", 0, 30))
    try extra(rig, yt, at: pt("2026-11-21", 0, 30))
    #expect(try slot(pt("2026-11-20", 20)) == pt("2026-11-21", 3, 30))  // the gap, after the move
    #expect(try slot(pt("2026-11-21", 0, 30), earliest: pt("2026-11-21", 0)) == pt("2026-11-21", 3, 30))  // 9:30 pm is no room
    // Pushed later into the window, it comes out at 00:30 Pacific.
    try extra(rig, yt, at: pt("2026-11-25", 16, 30))
    #expect(try slot(pt("2026-11-25", 16, 30)) == pt("2026-11-26", 0, 30))
    // Other platforms keep their time.
    #expect(try Sched.retrySlot(store: rig.store, platform: .x, target: pt("2026-11-20", 20), settings: s) == pt("2026-11-20", 20))
  }

  /// The Mac sleeps past the retry's time and wakes inside the window: now + 3 min isn't allowed, 00:30 Pacific is.
  @Test func aLateRetryThatWouldGoInTheWindowWaitsFor0030Pacific() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    rig.settle()
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    let j = try #require(try rig.job(yt))
    rig.fake.fail(j.postizId!, error: Self.quota)
    rig.f.clock.set(utc("2026-11-04", 4))  // 8 pm Pacific
    rig.tick()
    let a = try #require(try r8.attempts(rig, yt).last)
    #expect(a.id != yt.id && a.scheduledAt == utc("2026-11-04", 8, 30))
    rig.tick(2)
    #expect(try rig.job(a)?.remoteDate == utc("2026-11-04", 8, 30))
  }

  /// Every create comes through `remoteDate`: a late slot or Post now inside the window waits too, other platforms don't.
  @Test func nothingReachesPostizInTheWindow() throws {
    let rig = try Rig(1, platforms: [.youtube, .x])
    rig.f.clock.set(utc("2026-11-04", 4))
    let past = utc("2026-11-04", 3)
    #expect(try rig.service.remoteDate(for: past, platform: .youtube, integrationId: "ch-youtube") == utc("2026-11-04", 8, 30))
    #expect(try rig.service.remoteDate(for: past, platform: .x, integrationId: "ch-x") == utc("2026-11-04", 4, 3))
  }

  /// Two jobs never share a minute: the +1 min that dodges a taken 6:59 pm Pacific doesn't get to land on 7:00 pm.
  @Test func theMinuteAfterATakenOneStaysOutOfTheWindowToo() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    rig.settle()
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    var j = try #require(try rig.job(yt))
    j.remoteDate = pt("2026-11-03", 18, 59)
    try rig.store.save(j)
    rig.f.clock.set(pt("2026-11-03", 18, 40))
    #expect(try rig.service.remoteDate(for: pt("2026-11-03", 18, 59), platform: .youtube, integrationId: "ch-youtube") == pt("2026-11-04", 0, 30))
  }

  // MARK: djq slot

  /// Four YouTube + X posts, Monday to Thursday, in Postiz, with the clock at 6:00 on Monday.
  func slotRig() throws -> Rig {
    let rig = try Rig(4, platforms: [.youtube, .x]) { $0.enabledPlatforms = [.youtube, .x] }
    rig.settle()
    rig.f.setTime("2026-11-02", "06:00")
    return rig
  }

  func day(_ n: Int) -> String { "2026-11-0\(n + 1)" }

  @Test func itRetimesThePlatformsFuturePostsAndOnlyThose() throws {
    let rig = try slotRig()
    let dm = rig.f.dm
    let x = try rig.f.posts(.x)
    let yt = try #require(try rig.f.post(.youtube, day: day(1)))
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(c.before == 15 * 60 && c.batchId != nil && c.moved.count == 4 && c.kept.isEmpty)
    #expect(try rig.store.settings().slot(for: .youtube) == 8 * 60)
    #expect(try rig.f.posts(.youtube).map(\.scheduledAt).sorted() == (1...4).map { dm.at(day($0), minutes: 8 * 60) })
    #expect(try rig.f.posts(.x) == x)
    #expect(try rig.store.post(id: yt.id)?.state == yt.state)
  }

  @Test func postedNearSlotPinnedAndPassedPostsStay() throws {
    let rig = try slotRig()
    let actions = PostActions(store: rig.store)
    var early = try #require(try rig.f.post(.youtube, day: day(2)))
    early.state = .posted  // by hand, ahead of its time
    try rig.store.save(early, note: "test")
    let posted = try #require(try rig.store.post(id: early.id))
    let wed = try #require(try rig.f.post(.youtube, day: day(3)))
    var slot = try #require(try rig.store.planSlot(id: wed.planSlotId!))
    slot.pinned = true
    try rig.store.save(slot)
    let monday = try #require(try rig.f.post(.youtube, day: day(1)))
    rig.f.setTime(day(1), "14:40")
    let c = try actions.setSlot(.youtube, minutes: 16 * 60)
    #expect(Dictionary(uniqueKeysWithValues: c.kept.map { ($0.post.id, $0.why) }) == [monday.id: "it goes out within 30 minutes", wed.id: "pinned"])
    #expect(c.moved.count == 1)
    for p in [monday, posted, wed] { #expect(try rig.store.post(id: p.id) == p) }
  }

  /// A time that has passed today can't take a post: it stays, and Eric reads why. Tomorrow's moves.
  @Test func aNewTimeThatHasPassedLeavesThePostWhereItIs() throws {
    let rig = try slotRig()
    let monday = try #require(try rig.f.post(.youtube, day: day(1)))
    rig.f.setTime(day(1), "10:00")
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(c.kept.map(\.post.id) == [monday.id] && c.kept[0].why == "the new time has passed or is under 30 minutes away")
    #expect(try rig.store.post(id: monday.id)?.scheduledAt == monday.scheduledAt)
    #expect(try rig.f.post(.youtube, day: day(2))?.scheduledAt == rig.f.at(day(2), "08:00"))
    #expect(c.moved.count == 3)
  }

  @Test func aRepostFollowsTheSlotAndAnAutomaticRetryKeepsItsTime() throws {
    let rig = try slotRig()
    let yt = try #require(try rig.f.post(.youtube, day: day(1)))
    let tuesday = try #require(try rig.f.post(.youtube, day: day(2)))
    try extra(rig, tuesday, at: rig.f.at("2026-11-10", "18:00"))
    let repost = try #require(try rig.f.post(.youtube, day: "2026-11-10"))
    let j = try #require(try rig.job(yt))
    rig.fake.fail(j.postizId!, error: Self.quota)
    rig.f.setTime(day(1), "23:30")
    rig.tick()
    let retry = try #require(try r8.attempts(rig, yt).first { $0.kind == .retry })
    // Tuesday's slot (15:00) after the reset, but Tuesday's own post is there: 3 h earlier, still after the reset.
    #expect(retry.scheduledAt == rig.f.at(day(2), "12:00"))
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(try rig.store.post(id: repost.id)?.scheduledAt == rig.f.at("2026-11-10", "11:00"))  // the slot + 3 h
    #expect(try rig.store.post(id: retry.id)?.scheduledAt == retry.scheduledAt)
    #expect(c.kept.contains { $0.post.id == retry.id })
  }

  /// Regular posts move first: a repost mustn't keep its distance from where Wednesday's post used to be.
  @Test func aRepostStaggersAroundTheNewTimesNotTheOldOnes() throws {
    let rig = try slotRig()
    let tuesday = try #require(try rig.f.post(.youtube, day: day(2)))
    try extra(rig, tuesday, at: rig.f.at(day(3), "18:00"))
    let repost = try #require(try rig.store.posts(where: "platform='youtube' AND kind='repost'").first)
    _ = try PostActions(store: rig.store).setSlot(.youtube, minutes: 12 * 60)
    #expect(try rig.store.post(id: repost.id)?.scheduledAt == rig.f.at(day(3), "15:00"))
  }

  @Test func aSlotInTheWindowUsesTheHelperAndTheDryRunChangesNothing() throws {
    let rig = try slotRig()
    let before = try rig.f.posts(.youtube)
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 23 * 60, dryRun: true)
    #expect(c.batchId == nil && c.moved.map(\.to).sorted() == (1...4).map { utc("2026-11-0\($0 + 2)", 8, 30) })
    #expect(try rig.f.posts(.youtube) == before)
    #expect(try rig.store.settings().slot(for: .youtube) == 15 * 60)
    #expect(try BulkActions(store: rig.store).batches().isEmpty)
    // Set for real, a second run finds nothing to do: the plan days came back through the window.
    _ = try PostActions(store: rig.store).setSlot(.youtube, minutes: 23 * 60)
    let again = try PostActions(store: rig.store).setSlot(.youtube, minutes: 23 * 60)
    #expect(again.batchId == nil && again.moved.isEmpty)
  }

  /// Slot set in Settings first (which leaves posts alone): the command at the same time still moves them.
  @Test func theSameTimeStillBringsStragglersOntoTheSlot() throws {
    let rig = try slotRig()
    try rig.f.updateSettings { $0.slotMinutes[.youtube] = 8 * 60 }
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(c.moved.count == 4 && c.batchId != nil)
  }

  /// Postiz gets the new time through the engine's move: one copy per post at every step, and undo goes the same way.
  @Test func postizFollowsAndUndoRestoresEverything() throws {
    let rig = try slotRig()
    let live = try rig.f.posts(.youtube)
    let dates = { Set(rig.fake.livePosts.filter { $0.integrationId == "ch-youtube" && $0.state == "QUEUE" }.map(\.date)) }
    #expect(dates() == Set(live.map(\.scheduledAt)))
    let settings = try rig.store.settings()
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    rig.tick(2)
    #expect(dates() == Set(c.moved.map(\.to)))
    #expect(try rig.invariants().isEmpty)
    try BulkActions(store: rig.store).undo(try #require(c.batchId))
    #expect(try rig.store.settings() == settings)
    #expect(try rig.f.posts(.youtube).map(\.scheduledAt).sorted() == live.map(\.scheduledAt).sorted())
    rig.tick(2)
    #expect(dates() == Set(live.map(\.scheduledAt)))
    #expect(try rig.invariants().isEmpty)
  }

  /// A post 31 minutes out can move, and the undo the command prints works.
  @Test func whatMovesCanBeUndoneStraightAway() throws {
    let rig = try slotRig()
    let monday = try #require(try rig.f.post(.youtube, day: day(1)))
    rig.f.setTime(day(1), "14:29")
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 16 * 60)
    #expect(c.moved.contains { $0.post.id == monday.id })
    try BulkActions(store: rig.store).undo(try #require(c.batchId))
    #expect(try rig.store.post(id: monday.id)?.scheduledAt == monday.scheduledAt)
  }

  /// `djq` commits while the engine is inside a render: the render's save must not put the old time back.
  @Test func aRenderInProgressKeepsTheNewTime() throws {
    let rig = try Rig(3, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    rig.f.setTime("2026-11-02", "06:00")
    let actions = PostActions(store: rig.store)
    rig.renderer.duringRender = { _ = try actions.setSlot(.youtube, minutes: 8 * 60) }
    rig.settle()
    #expect(rig.renderer.duringRender == nil)
    #expect(try rig.f.posts(.youtube).map(\.scheduledAt).sorted() == (1...3).map { rig.f.at(day($0), "08:00") })
    #expect(try rig.f.posts(.youtube).allSatisfy { $0.renderId != nil && $0.state == .rendered })
  }

  /// The step's list is read before the render: the clip's next post attaches that render from a stale copy.
  @Test func theNextPostInTheRenderStepKeepsItsNewTimeToo() throws {
    let rig = try Rig(1, platforms: [.youtube, .x]) { $0.enabledPlatforms = [.youtube, .x] }
    rig.f.setTime("2026-11-02", "06:00")
    let actions = PostActions(store: rig.store)
    rig.renderer.duringRender = { _ = try actions.setSlot(.x, minutes: 18 * 60) }
    rig.tick()
    #expect(try rig.f.post(.x, day: day(1))?.scheduledAt == rig.f.at(day(1), "18:00"))
  }

  /// 00:30 Pacific can be a night slot moved past midnight or a post that belongs to that morning. Its slot says which.
  @Test func thePlanSlotSettlesWhichDayA0030PacificPostIs() {
    let dm = DayMath(settings: Settings()), at = utc("2026-11-04", 8, 30)  // 3:30 am New York on the 4th
    func day(_ slot: String?, _ p: Platform = .youtube, position: Int = 0) -> String {
      dm.planDay(at, position: position, slotDate: slot, platform: p, offsetMinutes: 180)
    }
    #expect(day("2026-11-03") == "2026-11-03")
    #expect(day("2026-11-04") == "2026-11-04")
    #expect(day("2026-11-01") == "2026-11-03")  // shifted past a busy day: still the night before
    #expect(day("2026-11-03", position: 1) == "2026-11-03")
    #expect(day("2026-11-03", .x) == "2026-11-04")
    #expect(dm.planDay(at.addingTimeInterval(60), position: 0, slotDate: "2026-11-03", platform: .youtube, offsetMinutes: 180) == "2026-11-04")
  }

  /// A plan push of night posts counts from their own day, read before the slots moved.
  @Test func pushingNightPostsMovesThemOneDay() throws {
    let rig = try nightRig()
    rig.f.setTime(day(1), "06:00")
    try Planner(store: rig.store).pushPlan(from: day(1), days: 1)
    #expect(try rig.f.posts(.youtube).map(\.scheduledAt).sorted() == [utc("2026-11-04", 8, 30), utc("2026-11-05", 8, 30), utc("2026-11-06", 8, 30)])
    #expect(try rig.f.posts(.youtube).map { try rig.store.planDay(of: $0, dm: rig.f.dm) }.sorted() == [day(2), day(3), day(4)])
  }

  /// Removed during its render, a post stays gone.
  @Test func aRenderDoesntBringBackAPostThatWentAway() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    let yt = try #require(try rig.f.post(.youtube, day: day(1)))
    rig.renderer.duringRender = { try rig.store.deletePost(yt.id) }
    rig.tick()
    #expect(try rig.store.post(id: yt.id) == nil)
  }

  /// Slot 23:00, then 08:00 at 10:00 on Monday: Monday's post can't go back, so it stays, and it's still Monday's.
  /// Running the command again must not put it on Tuesday's time.
  @Test func aKeptNightPostKeepsItsDayAndNothingStacks() throws {
    let rig = try nightRig()
    rig.f.setTime(day(1), "10:00")
    let actions = PostActions(store: rig.store)
    let first = try actions.setSlot(.youtube, minutes: 8 * 60)
    #expect(first.kept.count == 1 && first.moved.count == 2)
    let kept = try #require(first.kept.first).post
    #expect(try rig.store.planDay(of: kept, dm: rig.f.dm) == day(1))
    let again = try actions.setSlot(.youtube, minutes: 8 * 60)
    #expect(again.moved.isEmpty && again.kept.map(\.post.id) == [kept.id])
    #expect(Set(try rig.f.posts(.youtube).map(\.scheduledAt)).count == 3)
    #expect(try Placer(store: rig.store, dm: rig.f.dm).isTaken(.youtube, day: day(1), position: 0))
  }

  /// The slot changed in Settings first: the posts still land on their own days.
  @Test func aSettingsChangeFirstDoesntShiftNightPostsADay() throws {
    let rig = try nightRig()
    rig.f.setTime(day(1), "06:00")
    try rig.f.updateSettings { $0.slotMinutes[.youtube] = 8 * 60 }
    let dm = rig.f.dm
    let days = try rig.f.posts(.youtube).map { try rig.store.planDay(of: $0, dm: dm) }.sorted()
    #expect(days == (1...3).map(day))  // and so does the Placer, with the setting already changed
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(c.moved.count == 3)
    #expect(try rig.f.posts(.youtube).map(\.scheduledAt).sorted() == (1...3).map { rig.f.at(day($0), "08:00") })
  }

  /// A night post moved to 00:30 Pacific stays on 00:30 Pacific across both changes (a fixed 24 h would land at 23:30
  /// or 01:30 Pacific, in the window or off the moved time).
  @Test(arguments: [("2026-10-30", 3), ("2027-03-15", -3)])
  func aShiftAcrossAClockChangeStaysOn0030Pacific(_ from: String, _ days: Int) throws {
    let rig = try nightRig(1)
    let dm = rig.f.dm
    var p = try #require(try rig.store.posts(where: "platform='youtube'").first)
    p.scheduledAt = YouTubeWindow.nextSafe(after: dm.at(from, minutes: 22 * 60))
    try rig.store.save(p, note: "test")
    try rig.store.reflow([p], days: days, dm: dm, note: "test")
    let moved = try #require(try rig.store.post(id: p.id))
    let la = DayMath(tz: YouTubeWindow.pacific)
    #expect(moved.scheduledAt == pt(la.addDays(la.key(p.scheduledAt), days), 0, 30))
    #expect(YouTubeWindow.isMoved(moved.scheduledAt))
    #expect(try rig.store.planDay(of: moved, dm: dm) == dm.addDays(from, days))
  }

  /// A retry queued for 8:00 by the old code, and the slot goes to 8:00: it makes room, earlier, as a quota retry does.
  @Test func aPostLandingOnAnAutomaticRetryMovesTheRetry() throws {
    let rig = try slotRig()
    let yt = try #require(try rig.f.post(.youtube, day: day(1)))
    let j = try #require(try rig.job(yt))
    rig.fake.fail(j.postizId!, error: Self.quota)
    rig.f.setTime(day(1), "23:30")
    rig.tick()
    var retry = try #require(try r8.attempts(rig, yt).first { $0.kind == .retry })
    retry.scheduledAt = rig.f.at(day(3), "08:00")
    try rig.store.save(retry, note: "test")
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(try rig.store.post(id: retry.id)?.scheduledAt == rig.f.at(day(3), "05:00"))
    #expect(c.moved.contains { $0.post.id == retry.id })
  }

  @Test func theCommandCountsPostizCalls() throws {
    let rig = try slotRig()
    try rig.f.updateSettings { $0.publishing.hourlyBudget = 5 }
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 16 * 60, dryRun: true)
    #expect(c.postizCalls == 8 && c.postizCallsLeft <= 5)
  }

  /// The built `djq`: show, dry run, set, undo.
  @Test func theCommand() throws {
    let env = try R6PostizCLITests.Env()
    #expect(try env.djq("schedule").status == 0)
    let posts = { try env.store.posts(where: "platform='youtube' AND kind='regular'").sorted { $0.scheduledAt < $1.scheduledAt } }
    let before = try posts(), others = try env.store.posts(where: "platform<>'youtube'")
    try #require(!before.isEmpty)
    let shown = try env.djq("slot", "youtube")
    #expect(shown.out.contains("YouTube Shorts slot 15:00"), "\(shown.out)\(shown.err)")
    #expect(try env.djq("slot", "youtube", "16:00", "--dry-run").out.contains("[dry run] YouTube Shorts slot 15:00 → 16:00 · would re-time"))
    #expect(try posts() == before && env.store.settings().slot(for: .youtube) == 15 * 60)
    let r = try env.djq("slot", "youtube", "16:00")
    #expect(r.status == 0 && r.out.contains("undo: djq bulk undo"), "\(r.out)\(r.err)")
    #expect(try posts().map(\.scheduledAt) == before.map { $0.scheduledAt.addingTimeInterval(3600) })
    #expect(try env.store.posts(where: "platform<>'youtube'") == others)
    #expect(try env.store.settings().slot(for: .youtube) == 16 * 60)
    let line = try #require(r.out.split(separator: "\n").first)
    let batch = try #require(line.split(separator: " ").last.map(String.init))
    #expect(try env.djq("bulk", "undo", batch).status == 0)
    #expect(try posts().map(\.scheduledAt) == before.map(\.scheduledAt) && env.store.settings().slot(for: .youtube) == 15 * 60)
    #expect(try env.djq("slot", "youtube", "25:00").status != 0)
    #expect(try env.djq("slot", "nope", "08:00").status != 0)
    #expect(try env.djq("slot").status != 0)
    #expect(try env.djq("help").out.contains("slot <platform> [HH:MM] [--dry-run]"))
  }
}
