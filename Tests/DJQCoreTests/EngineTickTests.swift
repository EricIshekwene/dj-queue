import Foundation
import Testing
@testable import DJQCore

@Suite struct EngineTickTests {
  func engine(_ f: Fixture, renderer: RenderService? = nil) -> (Engine, LogNotifier) {
    let n = LogNotifier()
    return (Engine(store: f.store, renderer: renderer, publisher: nil, notifier: n).planFrozen, n)
  }

  @Test func tickRunsEveryStepWithoutErrors() throws {
    let f = try Fixture.engine(8)
    let (e, _) = engine(f, renderer: FakeRenderer(store: f.store))
    e.autoSchedules = true
    let r = e.tick(reason: "test")
    #expect(r.errors.isEmpty, "\(r.errors)")
    #expect(Set(r.steps.keys) == Set(TickReport.order))
    #expect(r.steps["plan"]?.contains("scheduled 8") == true)  // the first tick puts the Queue on the calendar
    #expect(try f.store.week(f.week)?.state == .approved)
    #expect(Backup.list(f.paths).count == 1)
  }

  @Test func dueNotificationOnce() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, n) = engine(f)
    e.tick(reason: "t")
    #expect(n.titles(containing: "due").isEmpty)
    f.setTime("2026-11-02", "12:31")
    e.tick(reason: "t")
    e.tick(reason: "t")
    #expect(n.titles(containing: "· due now") == ["Facebook · song0 x mix0 · due now"])
    #expect(try f.post(.facebook, day: "2026-11-02")?.state == .due)
    #expect(try f.post(.threads, day: "2026-11-02")?.state == .planned)
    f.setTime("2026-11-02", "13:31")
    e.tick(reason: "t")
    #expect(n.titles(containing: "· due now").count == 2)
  }

  @Test func macOffFifteenHoursLateButWithinGraceStaysDue() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, n) = engine(f)
    e.tick(reason: "t")
    f.clock.advance(15 * 3600)  // Mac off 09:00 → 00:00 Tuesday, no ticks
    let r = e.tick(reason: "wake")
    #expect(r.errors.isEmpty, "\(r.errors)")
    // TikTok 19:00 is 5 h late (< 6 h) → still due, with a "late" notification.
    #expect(try f.post(.tiktok, day: "2026-11-02")?.state == .due)
    #expect(n.titles(containing: "TikTok") == ["TikTok · song0 x mix0 · 5 h late"])
    // FB … IG were ≥ 6 h late and their day has passed → overdue; their plans moved a day.
    for p in [Platform.facebook, .threads, .youtube, .x, .instagram] {
      #expect(try f.post(p, day: "2026-11-02")?.state == .overdue, "\(p)")
      #expect(try f.post(p, day: "2026-11-03") == nil, "\(p) Tuesday should be free")
      #expect(try f.post(p, day: "2026-11-04")?.videoId == "clip-1", "\(p)")
    }
    #expect(try f.post(.tiktok, day: "2026-11-03")?.videoId == "clip-1")  // TikTok's plan is untouched
    let missed = n.delivered.filter { $0.title.hasSuffix("missed") }
    #expect(missed.count == 5)
    #expect(missed.allSatisfy { $0.actions == [.postNow, .shiftPlan, .skip] })
    // The heartbeat gap was recorded as asleep.
    #expect(r.steps["heartbeat"]?.contains("woke") == true)
    e.tick(reason: "again")
    #expect(n.delivered.filter { $0.title.hasSuffix("missed") || $0.title.contains("late") }.count == 6)  // no repeats
  }

  @Test func wholeMissedDayShiftsPlanWithoutDoublePosting() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, n) = engine(f)
    e.tick(reason: "t")
    f.setTime("2026-11-04", "10:00")  // Wednesday: Monday and Tuesday missed
    e.tick(reason: "wake")
    let tt = try #require(try f.post(.tiktok, day: "2026-11-02"))
    #expect(tt.state == .overdue)
    #expect(try f.post(.tiktok, day: "2026-11-03") == nil)
    #expect(try f.post(.tiktok, day: "2026-11-04") == nil)  // today is free for the missed post
    #expect(try f.post(.tiktok, day: "2026-11-05")?.videoId == "clip-1")  // shifted by the 2 days missed
    #expect(try f.post(.tiktok, day: "2026-11-06")?.videoId == "clip-2")
    // Never two live posts on one day for a platform.
    for p in Platform.allCases {
      let live = try f.posts(p).filter { !$0.state.isTerminal }
      let perDay = Dictionary(grouping: live, by: { f.dm.key($0.scheduledAt) })
      #expect(perDay.values.allSatisfy { $0.count == 1 }, "\(p)")
    }
    #expect(n.delivered.filter { $0.title.hasSuffix("missed") }.count == 6)
    #expect(try Health.missedSlots(store: f.store, since: f.at("2026-11-01", "00:00")).count == 6)

    // Missed-slot actions.
    let a = PostActions(store: f.store)
    try a.shiftPlan(postId: tt.id)  // → today's free TikTok slot
    #expect(try f.store.post(id: tt.id)?.scheduledAt == f.at("2026-11-04", "19:00"))
    #expect(try f.store.post(id: tt.id)?.state == .planned)
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    try a.skip(postId: fb.id)  // skipped; FB's plan pulls back so its next post fills today
    #expect(try f.store.post(id: fb.id)?.state == .skipped)
    #expect(try f.post(.facebook, day: "2026-11-04")?.videoId == "clip-1")
    let th = try #require(try f.post(.threads, day: "2026-11-02"))
    try a.postNow(postId: th.id)
    #expect(try f.store.post(id: th.id)?.state == .due)
    // Shift plan when today's slot is taken pushes that platform's later posts one more day.
    var ytThu = try #require(try f.post(.youtube, day: "2026-11-05"))
    ytThu.scheduledAt = f.at("2026-11-04", "15:00")  // simulate Eric having moved it onto today
    try f.store.save(ytThu)
    let yt = try #require(try f.post(.youtube, day: "2026-11-02"))
    try a.shiftPlan(postId: yt.id)
    #expect(try f.store.post(id: yt.id)?.scheduledAt == f.at("2026-11-04", "15:00"))
    #expect(try f.store.post(id: ytThu.id)?.scheduledAt == f.at("2026-11-05", "15:00"))
    let live = try f.posts(.youtube).filter { !$0.state.isTerminal && $0.state != .overdue }
    #expect(Dictionary(grouping: live, by: { f.dm.key($0.scheduledAt) }).values.allSatisfy { $0.count == 1 })
  }

  @Test func pauseAllAndPausePlatform() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let (e, _) = engine(f)
    try f.updateSettings { $0.paused = true }
    f.setTime("2026-11-02", "19:05")
    e.tick(reason: "t")
    #expect(try f.posts().filter { $0.state == .due }.isEmpty)
    try f.updateSettings { $0.paused = false; $0.pausedPlatforms = [.tiktok] }
    e.tick(reason: "t")
    #expect(try f.post(.facebook, day: "2026-11-02")?.state == .due)
    #expect(try f.post(.tiktok, day: "2026-11-02")?.state == .planned)
    // A paused platform never goes overdue while paused.
    f.setTime("2026-11-04", "10:00")
    e.tick(reason: "t")
    #expect(try f.post(.tiktok, day: "2026-11-02")?.state == .planned)
  }

  @Test func renderAheadThenMoveToPostedWhenAllTerminal() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let fake = FakeRenderer(store: f.store)
    let (e, _) = engine(f, renderer: fake)
    e.tick(reason: "t")  // one new render per tick; all six Monday posts share it
    let monday = try f.posts().filter { f.dm.key($0.scheduledAt) == "2026-11-02" }
    #expect(monday.allSatisfy { $0.state == .rendered && $0.renderId != nil })
    #expect(fake.renderCount == 1)
    let render = try #require(try f.store.render(id: monday[0].renderId!))
    #expect(render.outputPath!.contains("/Ready to Post/Shortform/"))
    #expect(FileManager.default.fileExists(atPath: render.outputPath!))
    // An edit change re-renders.
    var v = try f.store.versions(videoId: "clip-0")[0]
    v.text = "New text"
    try f.store.save(v, videoId: "clip-0")
    e.tick(reason: "t")
    #expect(fake.renderCount == 2)
    let newRender = try #require(try f.post(.tiktok, day: "2026-11-02")?.renderId)
    #expect(newRender != render.id)
    // Post everything for Monday → the render moves to Posted/Shortform.
    f.setTime("2026-11-02", "19:05")
    e.tick(reason: "t")
    let a = PostActions(store: f.store)
    for p in try f.posts().filter({ f.dm.key($0.scheduledAt) == "2026-11-02" }) {
      try a.markPosted(postId: p.id, url: Fixture.postURLs[p.platform]!)
    }
    #expect(try f.store.video(id: "clip-0")?.state == .posted)
    e.tick(reason: "t")
    let moved = try #require(try f.store.render(id: newRender))
    #expect(moved.outputPath!.contains("/Posted/Shortform/"))
    #expect(moved.coverPath!.contains("/Posted/Shortform/"))
    #expect(FileManager.default.fileExists(atPath: moved.outputPath!))
    #expect(!FileManager.default.fileExists(atPath: f.sessionDir.appendingPathComponent("Ready to Post/Shortform/\(URL(fileURLWithPath: moved.outputPath!).lastPathComponent)").path))
  }

  @Test func renderFailureIsReportedAndDoesNotBlockOtherVideos() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let fake = FakeRenderer(store: f.store)
    fake.failVideos = ["clip-0"]
    let (e, n) = engine(f, renderer: fake)
    let r = e.tick(reason: "t")
    #expect(r.errors.isEmpty, "\(r.errors)")  // a render failure is recorded, not thrown
    #expect(r.steps["render"]?.contains("failed 1") == true)
    #expect(n.titles(containing: "Render failed").count == 1)
    #expect(try f.post(.facebook, day: "2026-11-02")?.state == .planned)
    #expect(try f.post(.facebook, day: "2026-11-03")?.state == .rendered)  // clip-1 rendered in the same tick
    #expect(fake.attempts.filter { $0 == "clip-0" }.count == 1)  // the other Monday platforms backed off
    // Next ticks within the hour: no retry of clip-0; other videos keep rendering.
    f.clock.advance(60)
    e.tick(reason: "t")
    f.clock.advance(60)
    e.tick(reason: "t")
    #expect(fake.attempts.filter { $0 == "clip-0" }.count == 1)
    #expect(try f.post(.facebook, day: "2026-11-05")?.state == .rendered)
    #expect(n.titles(containing: "Render failed").count == 1)
    // After an hour it retries (and succeeds once the cause is gone).
    fake.failVideos = []
    f.clock.advance(3600)
    e.tick(reason: "t")
    #expect(try f.post(.facebook, day: "2026-11-02")?.state == .rendered)
  }

  @Test func editChangeRetriesFailedRenderImmediately() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let fake = FakeRenderer(store: f.store)
    fake.failVideos = ["clip-0"]
    let (e, _) = engine(f, renderer: fake)
    e.tick(reason: "t")
    #expect(fake.attempts.filter { $0 == "clip-0" }.count == 1)
    fake.failVideos = []
    var v = try f.store.versions(videoId: "clip-0")[0]
    v.text = "Fixed text"
    try f.store.save(v, videoId: "clip-0")  // new hash → no back-off
    f.clock.advance(60)
    e.tick(reason: "t")
    #expect(fake.attempts.filter { $0 == "clip-0" }.count == 2)
    #expect(try f.post(.tiktok, day: "2026-11-02")?.state == .rendered)
  }

  @Test func tooLongForXFailsThenPerPlatformTrimRequeuesNextDay() throws {
    let f = try Fixture.engine(8, scores: [20, 10, 30, 40, 50, 60, 70, 80])  // clip-1 (21 s) posts Monday
    try Planner(store: f.store).approveWeek(f.week)
    // Round 2: the default trim is Eric's markers (3 s in from each end in the fixture); this test is about the
    // whole-file length, so use the whole-file trim default (behaviour under markers is covered in DefaultsTests).
    try f.updateSettings { $0.limits[.x]!.maxDuration = 20; $0.defaults.trimMode = .wholeFile }
    let (e, n) = engine(f)
    e.tick(reason: "t")
    let x = try #require(try f.post(.x, day: "2026-11-02"))
    #expect(x.videoId == "clip-1")
    #expect(x.state == .failed && x.errorType == .tooLong)
    #expect(x.errorMessage == "Too long for X (0:21 > 0:20)")
    #expect(n.titles(containing: "Failed on X").count >= 1)
    #expect(try f.post(.tiktok, day: "2026-11-02")?.state == .planned)  // other platforms carry on
    var edit = try f.store.edit(videoId: "clip-1")
    edit.platformTrims[.x] = TrimRange(start: 0, end: 19)
    try f.store.save(edit, videoId: "clip-1")
    e.tick(reason: "t")
    let retry = try #require(try f.posts(.x).first { $0.videoId == "clip-1" && $0.attemptNo == 2 })
    #expect(retry.kind == .retry && retry.state == .planned)
    #expect(retry.scheduledAt == f.at("2026-11-03", "20:00"))  // next day, 3 h after X's 17:00 post
    #expect(try f.store.post(id: x.id)?.resolution == "retried")
    // A video whose edit skips X instead → skipped.
    let tue = try #require(try f.posts(.x).first { $0.videoId == "clip-0" })
    #expect(tue.state == .planned)  // clip-0 is exactly 20 s
    let wed = try #require(try f.posts(.x).first { $0.videoId == "clip-2" })
    #expect(wed.state == .failed)
    var e2 = try f.store.edit(videoId: "clip-2")
    e2.skippedPlatforms = [.x]
    try f.store.save(e2, videoId: "clip-2")
    e.tick(reason: "t")
    #expect(try f.store.post(id: wed.id)?.state == .skipped)
  }

  @Test func alertsQueueLowAndRecordOnce() throws {
    let f = try Fixture.engine(2)
    let (e, n) = engine(f)
    e.autoSchedules = true
    e.tick(reason: "t")
    e.tick(reason: "t")
    let low = try #require(n.delivered.first { $0.key == "alert.queuelow:2026-11-02" })
    #expect(low.title == "Queue running low" && low.body == "Scheduled through Tue 3 Nov. Send more clips from Edit.")
    #expect(n.titles(containing: "Queue running low").count == 1)
    #expect(n.titles(containing: "Record a new set").count == 1)
    f.setTime("2026-11-08", "18:05")  // the Sunday reminder is gone; a new day alerts about the Queue again
    e.tick(reason: "t")
    #expect(n.titles(containing: "Queue running low").count == 2)
    #expect(!n.delivered.contains { $0.key.hasPrefix("alert.weekly") || $0.title.contains("Approve") })
  }

  /// Plenty waiting in the Queue is not "running low", whatever the calendar says (posting paused, say).
  @Test func aFullQueueIsNotLow() throws {
    let f = try Fixture.engine(5)
    try f.updateSettings { $0.paused = true }
    let (e, n) = engine(f)
    e.autoSchedules = true
    e.tick(reason: "t")
    #expect(n.titles(containing: "Queue running low").isEmpty)
  }

  @Test func heartbeatGapGivesAwakePeriods() throws {
    let f = try Fixture.engine(2)
    let (e, _) = engine(f)
    let t0 = f.clock.now
    e.tick(reason: "t")
    f.clock.advance(60)
    e.tick(reason: "t")
    f.clock.advance(2 * 3600)  // asleep
    e.tick(reason: "t")
    f.clock.advance(60)
    e.tick(reason: "t")
    let periods = try Health.awakePeriods(store: f.store, since: t0.addingTimeInterval(-60))
    #expect(periods.count == 2)
    #expect(periods[0].start == t0 && periods[0].end == t0.addingTimeInterval(60))
    #expect(periods[1].start == t0.addingTimeInterval(60 + 7200))
    #expect(periods[1].end == t0.addingTimeInterval(60 + 7200 + 60))
    let kinds = try f.store.heartbeats(since: t0).map(\.kind)
    #expect(kinds.contains(.sleep) && kinds.contains(.wake))
  }
}

@Suite struct EngineDayMathTests {
  @Test func slotTimesAreWallClockOnDSTDays() {
    let dm = DayMath(settings: Settings())
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    for day in ["2026-11-01", "2026-03-08", "2026-11-02"] {  // fall back, spring forward, normal
      let d = dm.at(day, minutes: 12 * 60 + 30)
      let comps = c.dateComponents([.hour, .minute], from: d)
      #expect(comps.hour == 12 && comps.minute == 30, "\(day)")
      #expect(dm.key(d) == day)
    }
    #expect(dm.key(dm.at("2026-11-02", minutes: 25 * 60)) == "2026-11-03")
  }
}
