import Foundation
import Testing
@testable import DJQCore

@Suite struct EngineQueueTests {
  @Test func orderingBothDirectionsWithTieBreak() throws {
    let f = try Fixture.engine(4, scores: [50, 50, 30, 70])
    try f.addSession("2026-09-01 – Older Set", id: "old-0", tag: "old one")
    try f.intake()
    try f.makeReady("old-0", score: 50)
    let q = Queue(store: f.store)
    // Worst first; ties: older session, then part, then start.
    #expect(try q.ordered().map(\.id) == ["clip-2", "old-0", "clip-0", "clip-1", "clip-3"])
    try f.updateSettings { $0.sort = .bestFirst }
    #expect(try q.ordered().map(\.id) == ["clip-3", "old-0", "clip-0", "clip-1", "clip-2"])
  }

  @Test func filtersUnscoredExcludedMissingAndPlanned() throws {
    let f = try Fixture.engine(6, ready: 5)
    try f.store.setScore("clip-4", nil)
    try f.store.refreshState(videoId: "clip-4")
    try f.store.setExcluded("clip-3", true)
    try FileManager.default.removeItem(at: f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – song2 x mix2.mp4"))
    try f.intake()
    try f.store.save(PlanSlot(id: "s1", date: "2026-11-05", position: 0, videoId: "clip-1", pinned: false, weekStart: f.week))
    let q = Queue(store: f.store)
    #expect(try q.ordered().map(\.id) == ["clip-0"])
    #expect(try q.toScore().map(\.id).contains("clip-4"))
    try f.store.setScore("clip-5", 40)
    #expect(try q.needsEdit().map(\.id) == ["clip-5"])
  }

  @Test func perPlatformOverrideUsesItsOwnOrder() throws {
    let f = try Fixture.engine(8)
    try f.updateSettings { $0.sortOverrides[.tiktok] = .bestFirst }
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    let days = f.dm.weekDays(f.week)
    #expect(try f.post(.facebook, day: days[0])?.videoId == "clip-0")
    #expect(try f.post(.tiktok, day: days[0])?.videoId == "clip-7")
    #expect(try f.post(.tiktok, day: days[1])?.videoId == "clip-6")
    let tt = try f.posts(.tiktok).map(\.videoId)
    #expect(tt.count == 7 && Set(tt).count == 7)  // never the same video twice on TikTok
    #expect(try Queue(store: f.store).ordered(platform: .tiktok).map(\.id) == ["clip-0"])
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-7"])  // still due on the other platforms
  }

  @Test func runwayNumbers() throws {
    let f = try Fixture.engine(10, ready: 8)
    try f.store.setScore("clip-8", 5)
    try f.store.setScore("clip-9", 6)
    let q = Queue(store: f.store)
    #expect(try q.runway() == Runway(approvedDays: 0, readyDays: 8, totalDays: 10))
    try Planner(store: f.store).approveWeek(f.week)
    #expect(try q.runway() == Runway(approvedDays: 7, readyDays: 1, totalDays: 10))
    try f.updateSettings { $0.postsPerDay = 2 }
    #expect(try q.runway().readyDays == 0)
  }

  @Test func avoidOverlapSkipsOverlappingClip() throws {
    let f = try Fixture.engine(3, scores: [10, 20, 30])
    f.entries[2]["start"] = 10.0  // clip-1 now overlaps clip-0 (same session, part 1)
    f.entries[2]["end"] = 31.0
    try f.saveManifest()
    try f.intake()
    #expect(Queue.overlaps(try f.store.video(id: "clip-0")!, try f.store.video(id: "clip-1")!))
    try f.updateSettings { $0.avoidOverlap = true; $0.avoidOverlapDays = 3 }
    let slots = try Planner(store: f.store).proposeWeek(f.week)
    #expect(slots.first { $0.date == "2026-11-03" }?.videoId == "clip-2")
    #expect(slots.first { $0.date == "2026-11-06" }?.videoId == "clip-1")
  }
}

@Suite struct EnginePlannerTests {
  @Test func proposeIsDraftAndApproveCreatesPosts() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    let slots = try p.proposeWeek(f.week)
    #expect(slots.count == 7)
    #expect(slots.map(\.videoId) == (0..<7).map { "clip-\($0)" })
    #expect(try f.posts().isEmpty)
    #expect(try f.store.video(id: "clip-0")?.state == .ready)  // draft doesn't plan
    try p.approveWeek(f.week)
    let posts = try f.posts()
    #expect(posts.count == 42)
    #expect(posts.allSatisfy { $0.state == .planned && $0.versionNo == 1 && $0.attemptNo == 1 && $0.kind == .regular && $0.publisher == "manual" })
    #expect(try f.post(.tiktok, day: "2026-11-02")?.scheduledAt == f.at("2026-11-02", "19:00"))
    #expect(try f.post(.facebook, day: "2026-11-02")?.scheduledAt == f.at("2026-11-02", "12:30"))
    #expect(try f.store.week(f.week)?.state == .approved)
    #expect(try f.store.video(id: "clip-0")?.state == .planned)
    try p.approveWeek(f.week)  // idempotent
    #expect(try f.posts().count == 42)
  }

  @Test func approveOnPartiallyPastWeekOnlyFromToday() throws {
    let f = try Fixture.engine(8)
    f.setTime("2026-11-05", "08:00")  // Thursday
    try Planner(store: f.store).approveWeek(f.week)
    let days = Set(try f.posts().map { f.dm.key($0.scheduledAt) })
    #expect(days == ["2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"])
  }

  @Test func skippedPlatformInEditGetsNoPost() throws {
    let f = try Fixture.engine(8)
    var e = try f.store.edit(videoId: "clip-0")
    e.skippedPlatforms = [.x]
    try f.store.save(e, videoId: "clip-0")
    try Planner(store: f.store).approveWeek(f.week)
    #expect(try f.post(.x, day: "2026-11-02") == nil)
    #expect(try f.post(.tiktok, day: "2026-11-02")?.videoId == "clip-0")
  }

  @Test func pinSwapRebuildPush() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    try p.proposeWeek(f.week)
    // Pin the backlog video to Wednesday: replaces the unpinned slot there.
    try p.pin(videoId: "clip-7", date: "2026-11-04")
    var slots = try p.slots(week: f.week)
    let wed = try #require(slots.first { $0.date == "2026-11-04" })
    #expect(wed.videoId == "clip-7" && wed.pinned)
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-2"])
    // Swap Monday and Tuesday.
    try p.swap(slots[0].id, slots[1].id)
    slots = try p.slots(week: f.week)
    #expect(slots[0].videoId == "clip-1" && slots[1].videoId == "clip-0")
    // Approve, then rebuild: the pinned slot stays (with its posts), everything else is re-proposed as draft.
    try p.approveWeek(f.week)
    try f.updateSettings { $0.sort = .bestFirst }
    try p.rebuildWeek(f.week)
    #expect(try f.store.week(f.week)?.state == .draft)
    slots = try p.slots(week: f.week)
    #expect(slots.first { $0.date == "2026-11-04" }?.videoId == "clip-7")
    #expect(slots.first { $0.date == "2026-11-02" }?.videoId == "clip-6")  // best first now
    #expect(try f.posts().count == 6)  // only the pinned slot's posts survive
    // Approve again and push from Thursday by one day.
    try p.approveWeek(f.week)
    let thu = try #require(slots.first { $0.date == "2026-11-05" })
    let thuTT = try #require(try f.store.slotPosts(thu.id).first { $0.platform == .tiktok })
    try p.pushPlan(from: "2026-11-05", days: 1)
    #expect(try f.store.planSlot(id: thu.id)?.date == "2026-11-06")
    #expect(try f.store.post(id: thuTT.id)?.scheduledAt == f.at("2026-11-06", "19:00"))
    let sunday = try #require(try f.store.planSlots(where: "date=?", ["2026-11-09"]).first)
    #expect(sunday.weekStart == "2026-11-09")
    #expect(try p.slots(week: f.week).first { $0.date == "2026-11-05" } == nil)
  }

  @Test func moveRemovePostTodaySkipNext() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    var slots = try p.slots(week: f.week)
    // Move Monday's slot to Friday (occupied) → they trade places, posts regenerate at the new times.
    try p.move(slotId: slots[0].id, to: "2026-11-06")
    #expect(try f.store.planSlot(id: slots[0].id)?.date == "2026-11-06")
    #expect(try f.store.planSlot(id: slots[4].id)?.date == "2026-11-02")
    #expect(try f.post(.tiktok, day: "2026-11-06")?.videoId == "clip-0")
    #expect(try f.post(.tiktok, day: "2026-11-02")?.videoId == "clip-4")
    // Remove Sunday's slot → its posts go, the video returns to the backlog.
    slots = try p.slots(week: f.week)
    try p.remove(slotId: slots[6].id)
    #expect(try f.post(.tiktok, day: "2026-11-08") == nil)
    #expect(try Set(Queue(store: f.store).ordered().map(\.id)) == ["clip-6", "clip-7"])
    // Post today: clip-7 goes on today, everything else moves a day later.
    try p.postToday(videoId: "clip-7")
    #expect(try f.post(.tiktok, day: "2026-11-02")?.videoId == "clip-7")
    #expect(try f.post(.tiktok, day: "2026-11-03")?.videoId == "clip-4")
    #expect(try f.post(.tiktok, day: "2026-11-02", video: "clip-4") == nil)  // never two on a day
    // Skip next: clip-7 trades with the next slot.
    try p.skipNext(videoId: "clip-7")
    #expect(try f.post(.tiktok, day: "2026-11-02")?.videoId == "clip-4")
    #expect(try f.post(.tiktok, day: "2026-11-03")?.videoId == "clip-7")
  }

  @Test func cannotChangePostedSlot() throws {
    let f = try Fixture.engine(8)
    let p = Planner(store: f.store)
    try p.approveWeek(f.week)
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    try PostActions(store: f.store).markPosted(postId: fb.id, url: Fixture.postURLs[.facebook]!)
    #expect(throws: EngineError.self) { try p.remove(slotId: fb.planSlotId!) }
  }
}
