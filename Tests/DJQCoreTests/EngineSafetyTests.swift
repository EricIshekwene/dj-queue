import Foundation
import Testing
@testable import DJQCore

/// Review fixes: never double-post across every planner path, retry/reset/render-cleanup rules, read-only Doctor.
@Suite struct EngineSafetyTests {
  func engine(_ f: Fixture, renderer: RenderService? = nil) -> (Engine, LogNotifier) {
    let n = LogNotifier()
    return (Engine(store: f.store, renderer: renderer, publisher: nil, notifier: n), n)
  }

  /// Reviewer probe A: Mac off over Saturday shifts Sunday's posts into Monday; approving next week must not
  /// put a second post on that Monday.
  @Test func macOffSaturdayThenApproveNextWeek() throws {
    let f = try Fixture.engine(14)
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    for day in f.dm.weekDays(f.week).prefix(5) { try f.postAll(on: day) }
    f.setTime("2026-11-08", "10:00")
    let (e, _) = engine(f)
    let r = e.tick(reason: "wake")
    #expect(r.errors.isEmpty, "\(r.errors)")
    #expect(try f.post(.facebook, day: "2026-11-07")?.state == .overdue)
    #expect(try f.post(.facebook, day: "2026-11-09")?.videoId == "clip-6")  // Sunday's post moved to Monday
    #expect(try f.doublePosts().isEmpty)
    try p.approveWeek("2026-11-09")
    #expect(try f.doublePosts().isEmpty)
    let mondaySlot = try #require(try f.store.planSlots(where: "date=?", ["2026-11-09"]).first)
    #expect(try f.post(.facebook, day: "2026-11-10", video: mondaySlot.videoId) != nil)  // FB keeps its 1-day shift
    #expect(try f.post(.tiktok, day: "2026-11-10", video: mondaySlot.videoId) != nil)
  }

  /// Reviewer probe B: Monday missed (plans shifted a day), then swapping Wed/Thu must keep the shift.
  @Test func mondayMissedThenSwapWedThu() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    let (e, _) = engine(f)
    e.tick(reason: "t")
    f.setTime("2026-11-03", "10:00")
    e.tick(reason: "wake")
    #expect(try f.post(.facebook, day: "2026-11-04")?.videoId == "clip-1")
    let slots = try p.slots(week: f.week)
    try p.swap(slots[2].id, slots[3].id)  // Wed ↔ Thu
    #expect(try f.doublePosts().isEmpty)
    #expect(try f.post(.facebook, day: "2026-11-04")?.videoId == "clip-1")
    #expect(try f.post(.facebook, day: "2026-11-05")?.videoId == "clip-3")
    #expect(try f.post(.facebook, day: "2026-11-06")?.videoId == "clip-2")
    try p.move(slotId: slots[5].id, to: "2026-11-03")  // Saturday's slot onto Tuesday (trades places)
    #expect(try f.doublePosts().isEmpty)
    try p.pushPlan(from: "2026-11-04", days: 1)
    #expect(try f.doublePosts().isEmpty)
    try p.postToday(videoId: "clip-7")
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func pinnedSlotsNeverMoveOnPush() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    try p.proposeWeek(f.week)
    try p.pin(videoId: "clip-7", date: "2026-11-04")
    try p.approveWeek(f.week)
    try p.pushPlan(from: "2026-11-02", days: 1)
    let wed = try #require(try f.store.planSlots(where: "date=?", ["2026-11-04"]).first)
    #expect(wed.videoId == "clip-7" && wed.pinned)
    #expect(try f.post(.tiktok, day: "2026-11-04")?.videoId == "clip-7")
    #expect(try f.store.planSlots(where: "date=?", ["2026-11-03"]).first?.videoId == "clip-0")
    #expect(try f.store.planSlots(where: "date=?", ["2026-11-05"]).first?.videoId == "clip-1")  // jumped over Wed
    #expect(try f.doublePosts().isEmpty)
    #expect(throws: EngineError.self) { try p.pushPlan(from: "2026-11-02", days: 0) }
  }

  @Test func postTodayWithTwoPostsPerDay() throws {
    let f = try Fixture.engine(16)
    try f.updateSettings { $0.postsPerDay = 2 }
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    #expect(try f.posts().count == 7 * 2 * 6)
    try p.postToday(videoId: "clip-15")
    #expect(try f.doublePosts().isEmpty)
    #expect(try f.post(.tiktok, day: "2026-11-02")?.videoId == "clip-15")
    try p.postToday(videoId: "clip-14")  // second position today is free now
    #expect(try f.doublePosts().isEmpty)
    let today = try f.store.planSlots(where: "date=?", ["2026-11-02"])
    #expect(Set(today.map(\.videoId)) == ["clip-15", "clip-14"])
  }

  @Test func swapKeepsPendingRetry() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    let a = PostActions(store: f.store)
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    try a.reportProblem(postId: fb.id, type: .uploadFailed, message: "stuck")
    let retry = try a.fixed(postId: fb.id)
    let slots = try p.slots(week: f.week)
    try p.swap(slots[0].id, slots[1].id)
    let kept = try #require(try f.store.post(id: retry.id))
    #expect(kept.state == .planned && kept.scheduledAt == retry.scheduledAt && kept.videoId == "clip-0")
    #expect(try f.store.post(id: fb.id)?.state == .failed)  // history kept
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func manualTooLongReportWaitsForARealFix() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, _) = engine(f)
    let x = try #require(try f.post(.x, day: "2026-11-02"))
    try PostActions(store: f.store).reportProblem(postId: x.id, type: .tooLong, message: "X rejected the upload")
    e.tick(reason: "t")
    e.tick(reason: "t")
    #expect(try f.posts(.x).filter { $0.videoId == "clip-0" }.count == 1)  // no automatic retry
    var edit = try f.store.edit(videoId: "clip-0")
    edit.platformTrims[.x] = TrimRange(start: 0, end: 15)
    try f.store.save(edit, videoId: "clip-0")
    e.tick(reason: "t")
    #expect(try f.posts(.x).filter { $0.videoId == "clip-0" }.count == 2)  // trim changed → re-queued
  }

  @Test func resettingAnOverduePostDoesNotShiftAgain() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, n) = engine(f)
    e.tick(reason: "t")
    f.setTime("2026-11-04", "10:00")
    e.tick(reason: "wake")
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    #expect(fb.state == .overdue)
    #expect(try f.post(.facebook, day: "2026-11-05")?.videoId == "clip-1")
    try PostActions(store: f.store).reset(postId: fb.id)
    e.tick(reason: "t")
    #expect(try f.store.post(id: fb.id)?.state == .overdue)
    #expect(try f.post(.facebook, day: "2026-11-05")?.videoId == "clip-1")  // not moved a second time
    #expect(n.delivered.filter { $0.title.hasPrefix("Facebook") && $0.title.hasSuffix("missed") }.count == 1)
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func twoEnginesTickingShiftOnce() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e1, _) = engine(f), (e2, _) = engine(f)
    e1.tick(reason: "t")
    f.setTime("2026-11-04", "10:00")
    e1.tick(reason: "a")
    e2.tick(reason: "b")
    #expect(try f.post(.facebook, day: "2026-11-05")?.videoId == "clip-1")
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func unneededRendersAreDeletedPostedKept() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let fake = FakeRenderer(store: f.store)
    let (e, _) = engine(f, renderer: fake)
    e.tick(reason: "t")
    let monday = try #require(try f.post(.facebook, day: "2026-11-02")?.renderId)
    try PostActions(store: f.store).markPosted(postId: try #require(try f.post(.facebook, day: "2026-11-02")).id,
                                              url: Fixture.postURLs[.facebook]!)
    let preview = try fake.ensureRender(videoId: "clip-7", versionNo: 1, platform: nil)  // editor/CLI preview
    e.tick(reason: "t")
    #expect(try f.store.render(id: preview.id)?.deletedAt == nil)  // < 24 h old: kept
    f.setTime("2026-11-03", "10:00")
    e.tick(reason: "t")
    #expect(try f.store.render(id: preview.id)?.deletedAt != nil)  // nothing needs it → deleted
    #expect(try f.store.render(id: monday)?.deletedAt == nil)  // posted render kept
    #expect(fake.lastKeep?.contains(monday) == true)
  }

  @Test func skipDoesNotPullRepostEarlier() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let a = PostActions(store: f.store)
    f.setTime("2026-11-02", "20:00")
    try a.markPosted(postId: try #require(try f.post(.x, day: "2026-11-02")).id, url: Fixture.postURLs[.x]!)
    var v2 = Version(number: 2)
    v2.text = "again"
    try f.store.save(v2, videoId: "clip-0")
    let rp = try a.repost(videoId: "clip-0", platform: .x)
    let (e, _) = engine(f)
    e.tick(reason: "t")
    f.setTime("2026-11-05", "10:00")  // Tue + Wed X posts missed
    e.tick(reason: "wake")
    let tue = try #require(try f.post(.x, day: "2026-11-03"))
    #expect(tue.state == .overdue)
    try a.skip(postId: tue.id)
    #expect(try f.store.post(id: rp.id)?.scheduledAt == rp.scheduledAt)
    #expect(try f.post(.x, day: "2026-11-05")?.videoId == "clip-2")  // gap closed with the next regular post
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func postNowRefusedWhenPlatformAlreadyPostedToday() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, _) = engine(f)
    e.tick(reason: "t")
    f.setTime("2026-11-03", "10:00")
    e.tick(reason: "wake")  // Monday overdue, plans shifted: Tuesday is free
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    let a = PostActions(store: f.store)
    try a.postNow(postId: fb.id)
    #expect(try f.store.post(id: fb.id)?.state == .due)
    #expect(try f.doublePosts().isEmpty)
    try a.markPosted(postId: fb.id, url: Fixture.postURLs[.facebook]!)
    let th = try #require(try f.post(.threads, day: "2026-11-02"))
    try a.shiftPlan(postId: th.id)
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func doctorIsReadOnly() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).proposeWeek(f.week)
    try Queue(store: f.store).skipOnce("clip-7")
    try f.store.save(PlanSlot(id: "x", date: "2026-11-20", position: 0, videoId: "clip-7", pinned: false, weekStart: "2026-11-16"))
    let before = try f.store.db.one("SELECT total_changes() AS n")!.int("n")!
    let d = Doctor(store: f.store)
    d.agentLoaded = { false }
    d.probeDurations = false
    _ = d.run()
    let after = try f.store.db.one("SELECT total_changes() AS n")!.int("n")!
    #expect(before == after)
  }

  @Test func longformRefusesPathsOutsideReadyFolder() throws {
    let f = try Fixture.engine(2)
    var v = try #require(try f.store.video(id: "long-0001"))
    let clip = "Clips/2026-10-23 – Afroween Jazz Piano – song0 x mix0.mp4"
    v.file = "Ready to Post/Longform/../../" + clip
    try f.store.saveIdentity(v)
    try PostActions(store: f.store).markLongformPosted(videoId: v.id, url: "https://youtu.be/x")
    #expect(FileManager.default.fileExists(atPath: f.sessionDir.appendingPathComponent(clip).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sessionDir.appendingPathComponent("Posted/Longform").path).isEmpty)
  }
}
