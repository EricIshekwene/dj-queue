import Foundation
import Testing
@testable import DJQCore

/// Round 17: Postiz's YouTube quota resets at 07:00 UTC and is often gone hours before, so nothing on YouTube is scheduled
/// from 02:00 to 07:00 UTC, quota retries go at 07:30 UTC, and `djq slot` moves a platform's posts to a new time.
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

  // MARK: The helper

  @Test(arguments: [(1, 59, 59, false), (2, 0, 0, true), (2, 0, 1, true), (4, 30, 0, true), (6, 59, 59, true), (7, 0, 0, false),
                    (7, 30, 0, false), (15, 0, 0, false), (23, 59, 59, false), (0, 0, 0, false)])
  func theWindowsEdges(_ h: Int, _ m: Int, _ s: Int, _ quiet: Bool) {
    let d = utc("2026-11-04", h, m, s)
    #expect(YouTubeWindow.clear(d, .youtube) == (quiet ? utc("2026-11-04", 7, 30) : d))
  }

  @Test(arguments: Platform.allCases.filter { $0 != .youtube })
  func otherPlatformsNeverMove(_ p: Platform) {
    #expect(YouTubeWindow.clear(utc("2026-11-04", 4), p) == utc("2026-11-04", 4))
  }

  /// 9:30 pm New York is outside the window in summer and inside it in winter: the window doesn't move with the clocks.
  @Test func theWindowIsUTCAcrossBothDSTChanges() {
    #expect(YouTubeWindow.clear(ny("2026-10-31", 21, 30), .youtube) == ny("2026-10-31", 21, 30))  // EDT: 01:30 UTC
    #expect(YouTubeWindow.clear(ny("2026-11-01", 21, 30), .youtube) == utc("2026-11-02", 7, 30))  // EST: 02:30 UTC
    #expect(YouTubeWindow.clear(ny("2027-03-13", 21, 30), .youtube) == utc("2027-03-14", 7, 30))  // EST: 02:30 UTC
    #expect(YouTubeWindow.clear(ny("2027-03-14", 21, 30), .youtube) == ny("2027-03-14", 21, 30))  // EDT: 01:30 UTC
  }

  @Test func theQuotaRetryIsTheNext0730UTCAfterTheFailure() {
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-04", 20)).retry == utc("2026-11-05", 7, 30))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-04", 20)).reset == utc("2026-11-05", 7))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-04", 6)).retry == utc("2026-11-04", 7, 30))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-04", 7, 29)).retry == utc("2026-11-04", 7, 30))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-04", 7, 30)).retry == utc("2026-11-05", 7, 30))
    // Both DST nights: midnight Pacific would drift an hour against this.
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2026-11-01", 3)).retry == utc("2026-11-01", 7, 30))
    #expect(PostizRetrySchedule.youTubeQuota(after: utc("2027-03-14", 3)).retry == utc("2027-03-14", 7, 30))
    #expect(PostizRetrySchedule.next(after: utc("2026-11-04", 20), retry: 4, platform: .youtube, settings: Settings()) == utc("2026-11-05", 7, 30))
  }

  // MARK: Slot times

  /// One clip a day from Monday on YouTube alone, its slot late in the evening.
  func nightRig(_ n: Int = 3, slot: Int = 23 * 60) throws -> Rig {
    try Rig(n, platforms: [.youtube]) { s in
      s.enabledPlatforms = [.youtube]
      s.slotMinutes[.youtube] = slot
    }
  }

  @Test func aSlotInTheWindowGoesAt0730AndOtherPlatformsStay() throws {
    var s = Settings()
    s.slotMinutes[.youtube] = 22 * 60
    s.slotMinutes[.x] = 22 * 60
    let dm = DayMath(settings: s)
    #expect(s.slotTime(.youtube, date: "2026-11-04", position: 0, dm) == utc("2026-11-05", 7, 30))
    #expect(s.slotTime(.x, date: "2026-11-04", position: 0, dm) == utc("2026-11-05", 3))
    #expect(s.slotTime(.youtube, date: "2026-07-01", position: 0, dm) == utc("2026-07-02", 7, 30))
    s.slotMinutes[.youtube] = 8 * 60
    #expect(s.slotTime(.youtube, date: "2026-11-04", position: 0, dm) == utc("2026-11-04", 13))
    #expect(s.slotTime(.youtube, date: "2026-07-01", position: 0, dm) == utc("2026-07-01", 12))
  }

  /// A 23:00 slot posts at 2:30 am the next morning and still belongs to the day it was placed on, or `Placer` would see
  /// that day free and put a second clip on the same time.
  @Test func aNightSlotKeepsItsPlanDay() throws {
    let rig = try nightRig()
    let posts = try rig.store.posts(where: "platform='youtube' AND kind='regular'").sorted { $0.scheduledAt < $1.scheduledAt }
    #expect(posts.map(\.scheduledAt) == [utc("2026-11-03", 7, 30), utc("2026-11-04", 7, 30), utc("2026-11-05", 7, 30)])
    let dm = try rig.store.dayMath()
    #expect(try posts.map { try rig.store.planDay(of: $0, dm: dm) } == ["2026-11-02", "2026-11-03", "2026-11-04"])
    let placer = try Placer(store: rig.store, dm: dm)
    #expect(placer.isTaken(.youtube, day: "2026-11-02", position: 0))
    #expect(!placer.isTaken(.youtube, day: "2026-11-05", position: 0))
  }

  @Test func aReflowAcrossTheSpringChangeStaysOutOfTheWindow() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    var p = try #require(try rig.store.posts(where: "platform='youtube'").first)
    p.scheduledAt = utc("2027-03-13", 7, 30)  // 2:30 am EST; two days on, that clock time is 06:30 UTC
    try rig.store.save(p, note: "test")
    try rig.store.reflow([p], days: 2, dm: try rig.store.dayMath(), note: "test")
    #expect(try rig.store.post(id: p.id)?.scheduledAt == utc("2027-03-15", 7, 30))
  }

  /// 19:00 + 3 h is 03:00 UTC in winter, so the extra post looks the other way.
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
    #expect(try slot(utc("2026-11-20", 3)) == utc("2026-11-20", 7, 30))
    try extra(rig, yt, at: utc("2026-11-20", 7, 30))
    #expect(try slot(utc("2026-11-20", 3)) == utc("2026-11-20", 10, 30))  // the gap, after the move
    #expect(try slot(utc("2026-11-20", 7, 30), earliest: utc("2026-11-20", 7)) == utc("2026-11-20", 10, 30))  // 04:30 is no room
    // Pushed later into the window, it comes out at 07:30.
    try extra(rig, yt, at: utc("2026-11-25", 23, 30))
    #expect(try slot(utc("2026-11-25", 23, 30)) == utc("2026-11-26", 7, 30))
    // Other platforms keep their time.
    #expect(try Sched.retrySlot(store: rig.store, platform: .x, target: utc("2026-11-20", 3), settings: s) == utc("2026-11-20", 3))
  }

  /// The Mac sleeps past the retry's time and wakes inside the window: now + 3 min isn't allowed, 07:30 is.
  @Test func aLateRetryThatWouldGoInTheWindowWaitsFor0730() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    rig.settle()
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    let j = try #require(try rig.job(yt))
    rig.fake.fail(j.postizId!, error: Self.quota)
    rig.f.clock.set(utc("2026-11-04", 4))
    rig.tick()
    let a = try #require(try r8.attempts(rig, yt).last)
    #expect(a.id != yt.id && a.scheduledAt == utc("2026-11-04", 7, 30))
    rig.tick(2)
    #expect(try rig.job(a)?.remoteDate == utc("2026-11-04", 7, 30))
  }

  /// Every create comes through `remoteDate`: a late slot or Post now inside the window waits too, other platforms don't.
  @Test func nothingReachesPostizInTheWindow() throws {
    let rig = try Rig(1, platforms: [.youtube, .x])
    rig.f.clock.set(utc("2026-11-04", 4))
    let past = utc("2026-11-04", 3)
    #expect(try rig.service.remoteDate(for: past, platform: .youtube, integrationId: "ch-youtube") == utc("2026-11-04", 7, 30))
    #expect(try rig.service.remoteDate(for: past, platform: .x, integrationId: "ch-x") == utc("2026-11-04", 4, 3))
  }

  /// Two jobs never share a minute: the +1 min that dodges a taken 01:59 doesn't get to land on 02:00.
  @Test func theMinuteAfterATakenOneStaysOutOfTheWindowToo() throws {
    let rig = try Rig(1, platforms: [.youtube]) { $0.enabledPlatforms = [.youtube] }
    rig.settle()
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    var j = try #require(try rig.job(yt))
    j.remoteDate = utc("2026-11-04", 1, 59)
    try rig.store.save(j)
    rig.f.clock.set(utc("2026-11-04", 1, 40))
    #expect(try rig.service.remoteDate(for: utc("2026-11-04", 1, 59), platform: .youtube, integrationId: "ch-youtube") == utc("2026-11-04", 7, 30))
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
    rig.f.setTime(day(1), "14:52")  // 8 minutes: past the crop's 10, not yet Postiz's 5
    let c = try actions.setSlot(.youtube, minutes: 16 * 60)
    #expect(Dictionary(uniqueKeysWithValues: c.kept.map { ($0.post.id, $0.why) }) == [monday.id: "it goes out within 10 minutes", wed.id: "pinned"])
    #expect(c.moved.count == 1)
    for p in [monday, posted, wed] { #expect(try rig.store.post(id: p.id) == p) }
  }

  /// A time that has passed today can't take a post: it stays, and Eric reads why. Tomorrow's moves.
  @Test func aNewTimeThatHasPassedLeavesThePostWhereItIs() throws {
    let rig = try slotRig()
    let monday = try #require(try rig.f.post(.youtube, day: day(1)))
    rig.f.setTime(day(1), "10:00")
    let c = try PostActions(store: rig.store).setSlot(.youtube, minutes: 8 * 60)
    #expect(c.kept.map(\.post.id) == [monday.id] && c.kept[0].why == "the new time has already passed")
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
    #expect(retry.scheduledAt == utc("2026-11-03", 7, 30))
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
    #expect(c.batchId == nil && c.moved.map(\.to).sorted() == (1...4).map { utc("2026-11-0\($0 + 2)", 7, 30) })
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
