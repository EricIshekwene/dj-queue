import Foundation
import Testing
@testable import DJQCore

/// Round 33 (Eric, 2026-11-15): "Post today" may only be held back when Postiz itself won't take the post, and then the
/// app says why and what happens. The live case: Saturday evening, every regular slot of the day had posted, so Post
/// today found no position, refused, and the sheet hid the reason. Now it goes out now on its own, nothing else moves,
/// and the result says per platform when it goes out (YouTube's shared quota window is the one wait).
/// The clock starts Monday 2026-11-02 09:00 New York, one post a day.
@Suite struct R33PostTodayTests {
  func layout(_ f: Fixture) throws -> [String] {
    try f.store.planSlots().sorted { ($0.date, $0.position) < ($1.date, $1.position) }.map { "\($0.date)#\($0.position) \($0.videoId)" }
  }

  /// Today's slot (clip-0) has gone out everywhere; the clock is `hhmm` that evening.
  func fullDay(_ n: Int = 6, at hhmm: String = "21:00") throws -> (Fixture, Planner) {
    let f = try Fixture.engine(n)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    try f.postAll(on: "2026-11-02")
    f.setTime("2026-11-02", hhmm)
    return (f, planner)
  }

  @Test func aFullEveningGoesOutNowOnItsOwnAndNothingElseMoves() throws {
    let (f, planner) = try fullDay()
    let before = try layout(f).filter { !$0.contains("clip-4") }
    let r = try BulkActions(store: f.store).postToday(["clip-4"])
    #expect(r.changed == ["clip-4"] && r.skipped.isEmpty)
    #expect(r.onItsOwn == ["clip-4"])
    // Every other clip keeps its day; clip-4 left its own day and holds a set time at the next minute.
    #expect(try layout(f).filter { !$0.contains("clip-4") } == before.filter { !$0.contains("clip-4") })
    let s = try #require(try f.store.planSlots(where: "video_id='clip-4'").first)
    #expect(s.isExact && s.date == "2026-11-02" && s.exactAt == f.at("2026-11-02", "21:01"))
    let posts = try f.store.slotPosts(s.id).filter { !$0.state.isTerminal }
    #expect(posts.count == 6 && posts.allSatisfy { $0.scheduledAt == f.at("2026-11-02", "21:01") })
    let goes = try #require(r.goesOut?["clip-4"])
    #expect(goes.count == 6 && goes.allSatisfy { $0.now && $0.wait == nil })
    #expect(try f.doublePosts().isEmpty)
    _ = planner
  }

  @Test func theDryRunSaysWhatTheRealOneDoes() throws {
    let (f, _) = try fullDay()
    let b = BulkActions(store: f.store)
    let plan = try layout(f)
    let dry = try b.postToday(["clip-4"], dryRun: true)
    #expect(try layout(f) == plan)  // nothing changed
    let real = try b.postToday(["clip-4"])
    #expect(dry.changed == real.changed && dry.onItsOwn == real.onItsOwn && dry.goesOut == real.goesOut)
  }

  @Test func inYouTubesQuietWindowOnlyYouTubeWaitsAndSaysWhy() throws {
    let (f, _) = try fullDay(at: "22:30")  // 19:30 Pacific: Postiz's shared YouTube quota is gone for the day
    let r = try BulkActions(store: f.store).postToday(["clip-4"])
    let goes = try #require(r.goesOut?["clip-4"])
    let yt = try #require(goes.first { $0.platform == .youtube })
    #expect(!yt.now && yt.at == f.at("2026-11-03", "03:30"))  // 00:30 Pacific
    #expect(yt.wait?.contains("midnight Pacific") == true)
    #expect(goes.filter { $0.platform != .youtube }.allSatisfy { $0.now && $0.wait == nil })
  }

  @Test func aMorningPostTodayStillTakesTodaysSlotAndPushes() throws {
    let f = try Fixture.engine(6)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    let r = try BulkActions(store: f.store).postToday(["clip-4"])
    #expect(r.onItsOwn == [])
    #expect(try f.store.planSlots(where: "date='2026-11-02'").map(\.videoId) == ["clip-4"])
    #expect(try f.store.planSlots(where: "date='2026-11-03'").first?.videoId == "clip-0")  // the rest moved a day
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func aPinnedTodayAlsoGoesOutNowOnItsOwn() throws {
    let f = try Fixture.engine(6)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    try planner.pin(videoId: "clip-0", date: "2026-11-02")
    f.setTime("2026-11-02", "15:00")
    try planner.postToday(videoId: "clip-3")
    let s = try #require(try f.store.planSlots(where: "video_id='clip-3'").first)
    #expect(s.isExact && s.exactAt == f.at("2026-11-02", "15:01"))
    #expect(try f.store.planSlots(where: "video_id='clip-0'").first?.date == "2026-11-02")
  }

  @Test func aMoveOrPinOntoAFullTodayGoesOutNow() throws {
    let (f, planner) = try fullDay()
    let three = try #require(try f.store.planSlots(where: "video_id='clip-3'").first)
    try planner.move(slotId: three.id, to: "2026-11-02")
    #expect(try f.store.planSlots(where: "video_id='clip-3'").first?.isExact == true)
    try planner.pin(videoId: "clip-5", date: "2026-11-02")
    #expect(try f.store.planSlots(where: "video_id='clip-5'").first?.isExact == true)
    let r = try BulkActions(store: f.store).pinConsecutive(["clip-2"], from: "2026-11-02")
    #expect(r.onItsOwn == ["clip-2"] && r.goesOut?["clip-2"]?.isEmpty == false)
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func aSetTimeItemPostedTodayGoesOutNow() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try planner.postAt(videoId: "clip-1", at: f.at("2026-11-05", "10:00"))
    f.setTime("2026-11-02", "12:00")
    try planner.postToday(videoId: "clip-1")
    let s = try #require(try f.store.planSlots(where: "video_id='clip-1'").first)
    #expect(s.isExact && s.exactAt == f.at("2026-11-02", "12:01"))
  }

  @Test func aClipThatPostedBeforeTakesAnExtraPositionToday() throws {
    let f = try Fixture.engine(6)
    try f.updateSettings { $0.postsPerDay = 1 }
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    try f.postAll(on: "2026-11-02")
    f.setTime("2026-11-02", "21:00")
    // clip-3 has posted once already (an earlier post, off the plan): it can't take a set time.
    var old = try #require(try f.store.posts(where: "video_id='clip-3' AND platform='tiktok'").first)
    old.id = "clip-3-earlier"
    old.planSlotId = nil
    old.state = .posted
    old.scheduledAt = f.at("2026-10-20", "19:00")
    old.postedAt = old.scheduledAt
    try f.store.save(old)
    let others = try layout(f).filter { !$0.contains("clip-3") }
    let r = try BulkActions(store: f.store).postToday(["clip-3"])
    #expect(r.changed == ["clip-3"] && r.skipped.isEmpty)
    let s = try #require(try f.store.planSlots(where: "video_id='clip-3' AND date='2026-11-02'").first)
    #expect(!s.isExact && s.position >= 1 && s.position < PlanSlot.exactBase)
    #expect(r.onItsOwn == ["clip-3"])
    #expect(try layout(f).filter { !$0.contains("clip-3") } == others)  // nothing else moved
    #expect(r.goesOut?["clip-3"]?.isEmpty == false)
  }

  /// Review H1/H2: a set time keeps its minute when moved or pinned onto a full today; only Post today sends it now.
  @Test func aSetTimeMovedOrPinnedOntoAFullTodayKeepsItsMinute() throws {
    let (f, planner) = try fullDay(at: "18:00")
    try planner.postAt(videoId: "clip-3", at: f.at("2026-11-04", "23:00"))
    let three = try #require(try planner.exactSlot(videoId: "clip-3"))
    try planner.move(slotId: three.id, to: "2026-11-02")
    #expect(try planner.exactSlot(videoId: "clip-3")?.exactAt == f.at("2026-11-02", "23:00"))
    try planner.pin(videoId: "clip-3", date: "2026-11-02")
    #expect(try planner.exactSlot(videoId: "clip-3")?.exactAt == f.at("2026-11-02", "23:00"))
  }

  /// Review M1: an extra position today goes out now on every platform, not at position 3's slot times tomorrow.
  @Test func anExtraPositionGoesOutNowEverywhere() throws {
    let f = try Fixture.engine(6)
    try f.updateSettings { $0.postsPerDay = 3 }
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    for s in try f.store.planSlots(where: "date='2026-11-02'") { try planner.pin(videoId: s.videoId, date: "2026-11-02") }
    f.setTime("2026-11-02", "10:00")
    var old = try #require(try f.store.posts(where: "video_id='clip-5' AND platform='tiktok'").first)
    old.id = "clip-5-earlier"; old.planSlotId = nil; old.state = .posted
    old.scheduledAt = f.at("2026-10-20", "19:00"); old.postedAt = old.scheduledAt
    try f.store.save(old)
    let r = try BulkActions(store: f.store).postToday(["clip-5"])
    #expect(r.changed == ["clip-5"] && r.onItsOwn == ["clip-5"])
    let goes = try #require(r.goesOut?["clip-5"])
    #expect(!goes.isEmpty && goes.allSatisfy { $0.now && $0.at == f.at("2026-11-02", "10:01") })
  }

  /// A late Post today on a regular slot: past slot times go now, except YouTube inside its quiet window, which waits.
  @Test func aLateRegularPostTodaySaysYouTubeWaits() throws {
    let f = try Fixture.engine(6)
    try Planner(store: f.store).approveWeek(f.week)
    f.setTime("2026-11-02", "22:30")
    let r = try BulkActions(store: f.store).postToday(["clip-4"])
    #expect(r.onItsOwn == [])
    let goes = try #require(r.goesOut?["clip-4"])
    let yt = try #require(goes.first { $0.platform == .youtube })
    #expect(!yt.now && yt.at == f.at("2026-11-03", "03:30") && yt.wait != nil)
    #expect(goes.filter { $0.at < f.at("2026-11-02", "22:30") }.isEmpty)  // nothing reads as a time that has passed
  }

  @Test func theSheetWordsSayWhenAndWhy() throws {
    let s = Settings()
    let now = Fixture.engine0Now
    #expect(StageWording.goesOutWhen(GoesOut(platform: .tiktok, at: now, now: true), now: now, settings: s) == "Right away")
    #expect(StageWording.youtubeQuotaWait(now, settings: s).contains("goes by itself"))
  }
}

extension Fixture {
  /// Monday 2026-11-02 09:00 New York, where `Fixture.engine` starts.
  static var engine0Now: Date { DayMath(settings: Settings()).at("2026-11-02", minutes: 9 * 60) }
}
