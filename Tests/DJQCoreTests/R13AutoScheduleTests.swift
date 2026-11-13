import Foundation
import Testing
@testable import DJQCore

/// Round 13: a clip in the Queue is approved and the engine keeps it on the calendar by itself (`Planner.autoSchedule`).
@Suite struct R13AutoScheduleTests {
  /// Posts per day and clips ready; the clock stands Monday 2026-11-02 09:00, scores 10, 20, … (worst first: clip-0 first).
  func setup(_ n: Int = 8, ready: Int? = nil, perDay: Int = 1) throws -> Fixture {
    let f = try Fixture.engine(n, ready: ready)
    try f.updateSettings { $0.postsPerDay = perDay }
    return f
  }

  func order(_ f: Fixture) throws -> [String] {
    try f.store.planSlots().sorted { ($0.date, $0.position) < ($1.date, $1.position) }.map(\.videoId)
  }

  func layout(_ f: Fixture) throws -> [String] {
    try f.store.planSlots().sorted { ($0.date, $0.position) < ($1.date, $1.position) }.map { "\($0.date)#\($0.position) \($0.videoId)" }
  }

  /// One live regular post per clip + platform, and no post inside the past.
  func oneLivePostEach(_ f: Fixture) throws -> [String] {
    var seen = Set<String>(), bad: [String] = []
    for p in try f.store.posts(where: "kind='regular'") where !p.state.isTerminal {
      if !seen.insert("\(p.videoId)#\(p.platform.rawValue)").inserted { bad.append("\(p.videoId) twice on \(p.platform.rawValue)") }
    }
    return bad + (try f.doublePosts())
  }

  func engine(_ f: Fixture, renderer: RenderService? = nil) -> (Engine, LogNotifier) {
    let n = LogNotifier()
    return (Engine(store: f.store, renderer: renderer, publisher: nil, notifier: n), n)
  }

  // MARK: Fill

  @Test func fillsTwoADayInOrderWithRealPostsAtOnce() throws {
    let f = try setup(5, perDay: 2)
    let r = try Planner(store: f.store).autoSchedule()
    #expect(r.scheduled == 5 && r.relaid == 0 && r.reason == nil && r.waiting == 0)
    #expect(try layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#1 clip-1", "2026-11-03#0 clip-2", "2026-11-03#1 clip-3", "2026-11-04#0 clip-4"])
    #expect(try f.store.posts(where: "kind='regular'").count == 30)
    #expect(try f.store.week(f.week)?.state == .approved)
    #expect(try f.store.video(id: "clip-0")?.state == .planned)
    let first = try #require(try f.store.posts(where: "video_id='clip-0'").first)
    #expect(try f.store.history(postId: first.id).first?.note == "auto-scheduled")
    #expect(try f.store.events(videoId: "clip-0").filter { $0.kind == "plan" }.map(\.message) == ["Scheduled for Mon 2 Nov"])
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func pinnedClipsKeepTheirDays() throws {
    let f = try setup(4)
    let planner = Planner(store: f.store)
    try planner.pin(videoId: "clip-3", date: "2026-11-03")
    let pin = try #require(try f.store.planSlots(where: "video_id='clip-3'").first)
    try planner.autoSchedule()
    #expect(try layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-3", "2026-11-04#0 clip-1", "2026-11-05#0 clip-2"])
    #expect(try f.store.planSlots(where: "video_id='clip-3'").first == pin)
  }

  @Test func aGapIsFilledFromTheBacklogOnlyAndOtherClipsKeepTheirDays() throws {
    let f = try setup(6)
    let planner = Planner(store: f.store)
    try f.updateSettings { $0.enabledPlatforms = [.x] }
    let held = "clip-5"  // the last one stays in the backlog for now
    try BulkActions(store: f.store).removeFromQueue([held])
    try planner.autoSchedule()
    let before = try layout(f)
    #expect(before.count == 5)
    try BulkActions(store: f.store).back(["clip-1"])  // Tuesday opens
    try planner.autoSchedule()
    #expect(try layout(f) == before.filter { !$0.hasSuffix("clip-1") })  // nothing moved up: no compaction
    try BulkActions(store: f.store).sendToQueue([held])
    try planner.autoSchedule()
    #expect(try layout(f).contains("2026-11-03#0 clip-5"))
    #expect(try layout(f).filter { !$0.hasPrefix("2026-11-03") } == before.filter { !$0.hasPrefix("2026-11-03") })
  }

  @Test func horizonIsThirtyDaysAfterToday() throws {
    let f = try setup(40)
    let r = try Planner(store: f.store).autoSchedule()
    #expect(r.scheduled == 31 && r.waiting == 9)
    let last = try #require(try f.store.planSlots().map(\.date).max())
    #expect(last == "2026-12-02")  // Nov 2 + 30
    #expect(r.reason == nil)
    let next = try Planner(store: f.store).autoSchedule()
    #expect(next.scheduled == 0 && next.reason == "no open day")
  }

  @Test func aDayNeverGoesPastPostsPerDay() throws {
    let f = try setup(4)
    let planner = Planner(store: f.store)
    try f.store.save(Week(weekStart: f.week, state: .approved, approvedAt: f.clock.now))
    try f.store.save(PlanSlot(id: "high", date: "2026-11-02", position: 3, videoId: "clip-3", pinned: true, weekStart: f.week))
    try planner.autoSchedule()
    #expect(try f.store.planSlots(where: "date='2026-11-02'").count == 1)
  }

  // MARK: Lead time

  @Test func aPositionOnTodayNeedsThirtyMinutesBeforeItsEarliestPlatform() throws {
    let f = try setup(3)
    f.setTime("2026-11-02", "12:00")  // Facebook 12:30: exactly the lead
    #expect(try Planner(store: f.store).autoSchedule().scheduled == 3)
    #expect(try layout(f).first == "2026-11-02#0 clip-0")

    let g = try setup(3)
    g.setTime("2026-11-02", "12:01")
    try Planner(store: g.store).autoSchedule()
    #expect(try layout(g).first == "2026-11-03#0 clip-0")
  }

  @Test func theSecondPositionCanStillBeOpenWhenTheFirstIsNot() throws {
    let f = try setup(3, perDay: 2)
    f.setTime("2026-11-02", "13:00")  // position 1 starts 15:30
    try Planner(store: f.store).autoSchedule()
    #expect(try layout(f) == ["2026-11-02#1 clip-0", "2026-11-03#0 clip-1", "2026-11-03#1 clip-2"])
    let limit = f.clock.now.addingTimeInterval(Planner.autoScheduleLead)
    #expect(try f.store.posts().allSatisfy { $0.scheduledAt >= limit })
  }

  @Test func noPostIsEverCreatedInThePast() throws {
    let f = try setup(3)
    f.setTime("2026-11-02", "23:00")
    let r = try Planner(store: f.store).autoSchedule()
    #expect(try r.scheduled == 3 && !f.store.planSlots().contains { $0.date == "2026-11-02" })
    #expect(try f.store.posts().allSatisfy { $0.scheduledAt > f.clock.now })
    // Tonight has no slot, and the calendar still counts from tomorrow.
    let rw = try Queue(store: f.store).runway()
    #expect(rw.approvedDays == 3 && rw.scheduledThrough == "2026-11-05")
  }

  // MARK: Pause, no platforms

  @Test func pausedDoesNothingAndResumingNeedsNoSpecialStep() throws {
    let f = try setup(3)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)
    let draft = try layout(f)
    try f.updateSettings { $0.paused = true; $0.postsPerDay = 2 }
    let r = try planner.autoSchedule()
    #expect(r == {
      var e = Planner.AutoScheduleReport()
      e.reason = "paused"
      return e
    }())
    #expect(try layout(f) == draft && f.store.posts().isEmpty)
    try f.updateSettings { $0.paused = false }
    #expect(try planner.autoSchedule().scheduled == 3)
  }

  @Test func aPausedPlatformBehavesAsActivePlatformsDoes() throws {
    let f = try setup(1)
    try f.updateSettings { $0.pausedPlatforms = [.x] }
    try Planner(store: f.store).autoSchedule()
    #expect(try f.store.posts().count == 6)  // planned as ever; the engine doesn't advance it while paused
  }

  @Test func noPlatformsMeansNoEmptySlots() throws {
    let f = try setup(2)
    try f.updateSettings { $0.enabledPlatforms = [] }
    let r = try Planner(store: f.store).autoSchedule()
    #expect(try r.reason == "no platforms on" && f.store.planSlots().isEmpty)
  }

  // MARK: Adopting draft weeks

  @Test func aDraftWeekBecomesRealWithNoApprovalStep() throws {
    let f = try setup(9)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)
    let draft = try layout(f)
    let r = try planner.autoSchedule()
    #expect(try layout(f).prefix(7) == draft[...])  // same days, now real
    #expect(try f.store.week(f.week)?.state == .approved)
    #expect(try f.store.posts(where: "kind='regular'").count == 9 * 6)
    #expect(r.scheduled == 9)
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func adoptionDropsNotReadyDraftSlotsAndKeepsThePinnedRule() throws {
    let f = try setup(9)
    let planner = Planner(store: f.store)
    try planner.pin(videoId: "clip-8", date: "2026-11-10")  // a pinned day in a draft week
    try planner.proposeWeek(f.week)
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    try f.store.db.run("UPDATE edits SET json='{}' WHERE video_id=?", [mon.videoId])
    try f.store.db.run("UPDATE edits SET json='{}' WHERE video_id='clip-8'")  // stale, for both
    try planner.autoSchedule(revalidate: true)
    #expect(try f.store.posts(where: "video_id=?", [mon.videoId]).isEmpty)
    #expect(try f.store.planSlots(where: "video_id=?", [mon.videoId]).isEmpty)
    #expect(try f.store.planSlots(where: "date='2026-11-02'").first?.videoId != mon.videoId)
    // Pinned stays on its day and the engine reports it, as before.
    #expect(try f.store.planSlots(where: "video_id='clip-8'").first?.date == "2026-11-10")
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func aDraftDayTooCloseToPostGoesBackToTheQueue() throws {
    let f = try setup(2)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)  // clip-0 Monday, clip-1 Tuesday
    f.setTime("2026-11-02", "15:00")
    try planner.autoSchedule()
    #expect(try f.store.posts().allSatisfy { $0.scheduledAt >= f.clock.now.addingTimeInterval(Planner.autoScheduleLead) })
    #expect(try f.store.planSlots(where: "date='2026-11-02'").isEmpty)
    #expect(try f.store.planSlots(where: "video_id='clip-0'").first?.date == "2026-11-04")
  }

  @Test func aPinnedDraftDayPartlyPastPostsOnlyWhatsStillAhead() throws {
    let f = try setup(1)
    let planner = Planner(store: f.store)
    try planner.pin(videoId: "clip-0", date: "2026-11-02")  // no week row yet: a draft day
    f.setTime("2026-11-02", "16:00")
    try planner.autoSchedule()
    #expect(try f.store.planSlots(where: "video_id='clip-0'").first?.pinned == true)
    #expect(Set(try f.store.posts().map(\.platform)) == [.x, .instagram, .tiktok])  // 5, 6, 7 pm
    // After all of them it can't post at all: back to the Queue, and the next open day.
    let g = try setup(1)
    try Planner(store: g.store).pin(videoId: "clip-0", date: "2026-11-02")
    g.setTime("2026-11-02", "22:00")
    try Planner(store: g.store).autoSchedule()
    #expect(try layout(g) == ["2026-11-03#0 clip-0"])
    #expect(try g.store.planSlots(where: "pinned=1").isEmpty)
  }

  // MARK: What never gets a day

  @Test func notReadyHeldExcludedAndMissingClipsNeverGetADay() throws {
    let f = try setup(6, ready: 5)
    try f.store.setScore("clip-5", 90)  // in Edit, not ready
    try BulkActions(store: f.store).removeFromQueue(["clip-1"])  // held
    try f.store.setExcluded("clip-2", true)
    try f.store.db.run("UPDATE videos SET missing=1 WHERE id='clip-3'")
    try f.store.refreshState(videoId: "clip-3")
    try Planner(store: f.store).autoSchedule()
    #expect(try order(f) == ["clip-0", "clip-4"])
  }

  /// With no review step, a clip that already went out on a platform skips it: nobody else's post lands on its card.
  @Test func aClipWithPartialHistorySkipsThatPlatformAndPullsNoOtherClip() throws {
    let f = try setup(3)
    try f.store.setAlreadyPostedOn("clip-0", [.tiktok])
    let e = engine(f).0
    e.tick(reason: "t")
    let slot0 = try #require(try f.store.planSlots(where: "video_id='clip-0'").first)
    let posts0 = try f.store.slotPosts(slot0.id)
    #expect(posts0.count == 5 && posts0.allSatisfy { $0.videoId == "clip-0" && $0.platform != .tiktok })
    #expect(try f.store.posts(where: "video_id='clip-1' AND platform='tiktok'").count == 1)
    #expect(try f.store.posts(where: "plan_slot_id<>'' AND platform='tiktok'").allSatisfy { p in
      try f.store.planSlot(id: p.planSlotId!)?.videoId == p.videoId
    })
    #expect(try oneLivePostEach(f).isEmpty)
    e.tick(reason: "t")
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func aClipWithNowhereLeftToPostTakesNoDay() throws {
    let f = try setup(2)
    try f.store.setAlreadyPostedOn("clip-0", Platform.allCases)
    let r = try Planner(store: f.store).autoSchedule()
    #expect(try order(f) == ["clip-1"] && r.scheduled == 1)
    // It waits in the Queue, and Doctor doesn't call that stuck.
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-0"])
    #expect(r.waiting == 0 && r.nowhereToPost == 1)
    #expect(try !Doctor(store: f.store).planGaps().contains { $0.id == "plan.gaps" })
  }

  // MARK: Relay

  @Test func theFirstRunRecordsTheLayoutAndMovesNothing() throws {
    let f = try setup(4)
    let planner = Planner(store: f.store)
    try f.store.save(Week(weekStart: f.week, state: .approved, approvedAt: f.clock.now))
    try f.store.save(PlanSlot(id: "a", date: "2026-11-06", position: 0, videoId: "clip-3", pinned: false, weekStart: f.week))
    try f.updateSettings { $0.postsPerDay = 2 }
    let r = try planner.autoSchedule()
    #expect(r.relaid == 0)
    #expect(try f.store.planSlot(id: "a")?.date == "2026-11-06")
    #expect(try store(f, sig: "plan.layoutSig") != nil)
  }

  func store(_ f: Fixture, sig: String) throws -> Planner.LayoutSig? { try f.store.kv(sig) }

  @Test func postsPerDayUpLaysClipsCloserInTheirOldOrder() throws {
    let f = try setup(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try f.updateSettings { $0.postsPerDay = 2 }
    let r = try planner.autoSchedule()
    #expect(r.relaid == 4 && r.scheduled == 0)
    #expect(try layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#1 clip-1", "2026-11-03#0 clip-2", "2026-11-03#1 clip-3"])
    #expect(try f.store.posts(where: "kind='regular'").count == 24)
    #expect(try oneLivePostEach(f).isEmpty)
    #expect(try planner.autoSchedule().relaid == 0)  // once
  }

  @Test func postsPerDayDownSpreadsThemInTheirOldOrder() throws {
    let f = try setup(5, perDay: 2)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try f.store.setScore("clip-0", 95)  // in the Queue's order it would go last now; a posts/day change keeps the plan's
    try f.updateSettings { $0.postsPerDay = 1 }
    try planner.autoSchedule()
    #expect(try layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-04#0 clip-2", "2026-11-05#0 clip-3", "2026-11-06#0 clip-4"])
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func aSortChangeLaysInTheNewOrder() throws {
    let f = try setup(3)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    #expect(try order(f) == ["clip-0", "clip-1", "clip-2"])
    try f.updateSettings { $0.sort = .bestFirst }
    #expect(try planner.autoSchedule().relaid == 3)
    #expect(try order(f) == ["clip-2", "clip-1", "clip-0"])
    try f.updateSettings { $0.sortOverrides = [.x: .worstFirst] }
    #expect(try planner.autoSchedule().relaid == 3)  // an override is a sort change too
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func aRelayLeavesPinnedPostedAndSoonSlotsAlone() throws {
    let f = try setup(5)
    let planner = Planner(store: f.store)
    try planner.pin(videoId: "clip-4", date: "2026-11-05")
    try planner.autoSchedule()
    f.setTime("2026-11-03", "20:00")
    let tue = try #require(try f.store.planSlots(where: "date='2026-11-03'").first)
    let posted = try #require(try f.store.slotPosts(tue.id).first { $0.platform == .facebook })
    try PostActions(store: f.store).markPosted(postId: posted.id, url: Fixture.postURLs[.facebook]!)
    let wed = try #require(try f.store.planSlots(where: "date='2026-11-04'").first)
    f.setTime("2026-11-04", "12:00")  // Wednesday's Facebook goes in 30 min
    try f.updateSettings { $0.sort = .bestFirst }
    let r = try planner.autoSchedule()
    #expect(try f.store.planSlot(id: tue.id) != nil && f.store.planSlot(id: wed.id) != nil)
    #expect(try f.store.planSlots(where: "video_id='clip-4'").first?.date == "2026-11-05")
    #expect(r.relaid == 1)  // only the one unpinned, unposted slot far enough away
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func changingOnlyTheSecondPostOffsetDoesntRelay() throws {
    let f = try setup(3)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try f.updateSettings { $0.secondPostOffsetMinutes = 120; $0.sortOverrides = [:] }
    #expect(try planner.autoSchedule().relaid == 0)
  }

  // MARK: Idempotence and races

  @Test func repeatedTicksCreateNothingAndKeepTheSamePostIds() throws {
    let f = try setup(40)
    let (e, _) = engine(f, renderer: FakeRenderer(store: f.store))
    e.tick(reason: "t")
    let ids = try f.store.posts().map(\.id).sorted(), slots = try layout(f)
    let events = try f.store.events(limit: 2000).filter { $0.kind == "plan" }.count
    for _ in 0..<5 { e.tick(reason: "t") }
    #expect(try f.store.posts().map(\.id).sorted() == ids && layout(f) == slots)
    #expect(try f.store.events(limit: 2000).filter { $0.kind == "plan" }.count == events)
  }

  @Test func twoTicksRacingInOneDatabaseDontDoubleSlot() throws {
    let f = try Fixture(clips: (0..<20).map { (tag: "song\($0) x mix\($0)", duration: 20.0) })
    try f.paths.ensure()
    let a = try Store(paths: f.paths, clock: f.clock), b = try Store(paths: f.paths, clock: f.clock)
    try Fixture.onePostEach(a)
    _ = try Intake(store: a).run()
    for i in 0..<20 {
      var e = Edit()
      e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
      try a.save(e, videoId: "clip-\(i)")
      var v = Version(number: 1)
      v.text = "Text"
      v.captionTemplateId = "short"
      try a.save(v, videoId: "clip-\(i)")
      try a.setScore("clip-\(i)", i + 1)
      try a.setSentToQueue("clip-\(i)", true)
    }
    DispatchQueue.concurrentPerform(iterations: 8) { i in
      _ = try? Planner(store: i % 2 == 0 ? a : b).autoSchedule()
    }
    let slots = try a.planSlots()
    #expect(slots.count == 20 && Set(slots.map(\.videoId)).count == 20)
    #expect(Set(slots.map { "\($0.date)#\($0.position)" }).count == 20)
    #expect(try a.posts().count == 120)
  }

  @Test func aDryRunWritesNothing() throws {
    let f = try setup(3)
    let before = try f.store.planSlots().count
    let r = try Planner(store: f.store).autoSchedule(dryRun: true)
    #expect(r.dryRun && r.scheduled == 3 && r.clips.count == 3)
    #expect(try f.store.planSlots().count == before && f.store.posts().isEmpty)
    #expect(try f.store.kv(Planner.layoutKey, as: Planner.LayoutSig.self) == nil)
    #expect(try f.store.week(f.week) == nil)
    #expect(try f.store.events(videoId: "clip-0").filter { $0.kind == "plan" }.isEmpty)
  }

  // MARK: Stages

  @Test func unschedulingHoldsTheClipSoTheNextTickDoesntPutItBack() throws {
    let f = try setup(3)
    let (e, _) = engine(f)
    e.tick(reason: "t")
    let b = BulkActions(store: f.store)
    let v = try #require(try f.store.video(id: "clip-1"))
    #expect(StageWording.backTitle(v) == "Back to Edit")
    #expect(StageWording.backHelp(v) == "Takes it off the calendar and holds it in Edit until you send it to the Queue again")
    let r = try b.back(["clip-1"])
    #expect(r.moves?["clip-1"]?.from == .scheduled && r.moves?["clip-1"]?.to == .edit)
    e.tick(reason: "t")
    #expect(try f.store.planSlots(where: "video_id='clip-1'").isEmpty)
    #expect(try f.store.video(id: "clip-1")?.state == .needsEdit)
  }

  // MARK: Undo survives the scheduler (A6)

  /// The gap really gets taken by the backlog, and that clip goes back to waiting.
  func filledGap() throws -> (Fixture, BulkActions, Planner, BulkResult, PlanSlot) {
    let f = try setup(4)
    let planner = Planner(store: f.store), b = BulkActions(store: f.store)
    try f.store.setHeldInEdit("clip-3", true)
    try planner.autoSchedule()
    let wed = try #require(try f.store.planSlots(where: "video_id='clip-2'").first)
    let r = try b.back(["clip-2"])
    try f.store.setHeldInEdit("clip-3", false)
    try f.store.setSentToQueue("clip-3", true)
    try planner.autoSchedule()
    #expect(try f.store.planSlots(where: "video_id='clip-3'").first?.date == wed.date)
    return (f, b, planner, r, wed)
  }

  @Test func backToEditThenAutoFillThenUndoPutsTheClipBackOnItsDay() throws {
    let (f, b, planner, r, wed) = try filledGap()
    let u = try b.undo(try #require(r.batchId))
    #expect(u.skipped.isEmpty)
    #expect(try f.store.planSlots(where: "date=?", [wed.date]) == [wed])
    #expect(try f.store.slotPosts(wed.id).count == 6)
    #expect(try f.store.video(id: "clip-2")?.state == .planned)
    #expect(try f.store.posts(where: "video_id='clip-3'").isEmpty)
    #expect(try f.store.video(id: "clip-3")?.state == .ready)  // nobody left it Scheduled
    #expect(try f.store.video(id: "clip-2")?.heldInEdit == false)
    try planner.autoSchedule()
    #expect(try f.store.planSlots(where: "video_id='clip-3'").first?.date == "2026-11-05")
    #expect(try oneLivePostEach(f).isEmpty)
  }

  @Test func undoStillRefusesWhatEricDidAfterTheBatch() throws {
    // A pin.
    do {
      let (f, b, planner, r, _) = try filledGap()
      try planner.pin(videoId: "clip-3", date: "2026-11-09")
      #expect(throws: EngineError.self) { try b.undo(try #require(r.batchId)) }
      #expect(try f.store.planSlots(where: "video_id='clip-3'").first?.pinned == true)
    }
    // A slot of the batch that moved.
    do {
      let (f, b, planner, r, _) = try filledGap()
      let mon = try #require(try f.store.planSlots(where: "video_id='clip-0'").first)
      try planner.move(slotId: mon.id, to: "2026-11-20")
      #expect(throws: EngineError.self) { try b.undo(try #require(r.batchId)) }
    }
    // A derived post that was acted on.
    do {
      let (f, b, _, r, _) = try filledGap()
      let p = try #require(try f.store.posts(where: "video_id='clip-3'").first)
      try PostActions(store: f.store).skip(postId: p.id)
      #expect(throws: EngineError.self) { try b.undo(try #require(r.batchId)) }
    }
    // A derived post Postiz already holds.
    do {
      let (f, b, _, r, _) = try filledGap()
      let p = try #require(try f.store.posts(where: "video_id='clip-3'").first)
      let job = PostizJob(postId: p.id, videoId: p.videoId, platform: p.platform, integrationId: "ch", phase: .live, postizId: "z",
                          renderId: "r", contentHash: "h", scheduledAt: p.scheduledAt, remoteDate: p.scheduledAt, testMode: false,
                          postType: "schedule", createdAt: f.clock.now, updatedAt: f.clock.now)
      try f.store.save(job)
      #expect(throws: EngineError.self) { try b.undo(try #require(r.batchId)) }
    }
  }

  @Test func sendToQueueThenAutoFillThenUndoTakesTheDayBack() throws {
    let f = try setup(2)
    try f.store.setHeldInEdit("clip-1", true)
    let b = BulkActions(store: f.store)
    let r = try b.sendToQueue(["clip-1"])
    try Planner(store: f.store).autoSchedule()
    #expect(try f.store.video(id: "clip-1")?.state == .planned)
    let u = try b.undo(try #require(r.batchId))
    #expect(u.skipped.isEmpty)
    let v = try #require(try f.store.video(id: "clip-1"))
    #expect(v.state == .needsEdit && v.heldInEdit && !v.sentToQueue)
    #expect(try f.store.posts(where: "video_id='clip-1'").isEmpty && f.store.planSlots(where: "video_id='clip-1'").isEmpty)
  }

  // MARK: Runway, Doctor

  @Test func runwayCountsDaysWithSlotsAndNamesTheLastOne() throws {
    let f = try setup(3)
    try Planner(store: f.store).autoSchedule()
    let rw = try Queue(store: f.store).runway()
    let s = try f.store.settings()
    #expect(rw.approvedDays == 3 && rw.scheduledThrough == "2026-11-04")
    #expect(StageWording.scheduledThrough(rw.scheduledThrough, settings: s) == "Scheduled through Wed 4 Nov")
    #expect(StageWording.scheduledThrough(nil, settings: s) == "Nothing scheduled")
    #expect(StageWording.queueLowBody(rw.scheduledThrough, settings: s) == "Scheduled through Wed 4 Nov. Send more clips from Edit.")
  }

  @Test func doctorWordsQueueLowAndNeverSaysApprove() throws {
    let f = try setup(1)
    try Planner(store: f.store).autoSchedule()
    let d = Doctor(store: f.store)
    let low = try #require(try d.runway().first { $0.id == "runway.queue" })
    #expect(low.title == "Queue running low" && low.fix == "Send clips to the Queue from Edit.")
    #expect(!(low.detail + low.fix).lowercased().contains("approv"))
  }

  @Test func planGapsOnlyWarnWhenAClipIsWaiting() throws {
    let f = try setup(3)
    let d = Doctor(store: f.store)
    #expect(try d.planGaps().map(\.id) == ["plan.gaps"])  // nothing ticked yet: stuck
    #expect(try d.planGaps().first?.severity == .warning)
    #expect(try d.planGaps().first?.where_.count == 3)  // the three days those clips would take
    try Planner(store: f.store).autoSchedule()
    #expect(try d.planGaps().isEmpty)  // the rest of the month is open, and the Queue is empty
    try f.updateSettings { $0.paused = true }
    #expect(try d.planGaps().isEmpty)
  }

  // MARK: Wording

  /// Nothing aimed at Eric says "approve" any more: every notification of a full run, end to end.
  @Test func noNotificationOrStageWordSaysApproveOrSchedule() throws {
    let f = try setup(2)
    let (e, n) = engine(f)
    e.tick(reason: "t")
    #expect(!n.delivered.contains { ($0.title + $0.body).lowercased().contains("approv") })
    for st in ClipStage.allCases {
      let words = [st.backTitle, st.forwardTitle, st.backHelp(score: 1), st.forwardHelp].compactMap { $0 }.joined(separator: " ")
      #expect(!words.contains("Schedule ") && !words.lowercased().contains("approv") && !words.contains("Today") && !words.contains("Week"))
    }
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(try !BulkActions(store: f.store).blocker(v, .forward)!.contains("Today"))
  }
}

/// Relay with Postiz in the loop, against `FakePostiz`.
@Suite struct R13RelayPostizTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  /// Four clips on Monday–Thursday, rendered and in Postiz.
  func scheduled(budget: Int = 1000) throws -> Rig {
    let rig = try Rig(4, budget: budget, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()
    #expect(rig.fake.createCount == 24 && rig.fake.livePosts.count == 24)
    return rig
  }

  /// One live Postiz post per clip + channel, for the clips and channels expected.
  func onePerClipAndChannel(_ rig: Rig) throws -> Bool {
    let live = try rig.fake.livePosts.map { "\(try rig.video(of: $0))|\($0.integrationId)" }
    return Set(live).count == live.count && live.count == 24
  }

  @Test func aRelayCancelsTheOldJobAndNeverDoubleCreates() throws {
    let rig = try scheduled()
    let oldJobs = try rig.store.openPostizJobs().map(\.id)
    try rig.f.updateSettings { $0.postsPerDay = 2 }
    rig.settle()
    #expect(rig.fake.deleteCount == 24 && rig.fake.createCount == 48)
    #expect(try onePerClipAndChannel(rig))
    #expect(try rig.invariants().isEmpty)
    #expect(try rig.store.openPostizJobs().allSatisfy { !oldJobs.contains($0.id) })
    let days = try rig.store.planSlots().map(\.date)
    #expect(Set(days) == ["2026-11-02", "2026-11-03"])
    for p in try rig.store.posts() { #expect(p.state != .posted) }
  }

  @Test func nothingIsCreatedUntilTheDeleteIsConfirmed() throws {
    let rig = try scheduled()
    let created = rig.fake.createCount
    rig.fake.failNext["DELETE posts"] = Array(repeating: 500, count: 6)
    try rig.f.updateSettings { $0.postsPerDay = 2 }
    rig.tick()
    #expect(rig.fake.livePosts.count >= 18)  // the deletes that failed stay in Postiz, each still a job
    #expect(try rig.invariants().isEmpty)
    rig.settle()
    #expect(rig.fake.createCount == created + 24)  // one create per post, however many tries the delete took
    #expect(try onePerClipAndChannel(rig))
    #expect(try rig.invariants().isEmpty)
  }

  @Test func aSlotPostizPostsSoonStaysPut() throws {
    let rig = try scheduled()
    rig.f.setTime("2026-11-02", "12:00")
    let mon = try #require(try rig.store.planSlots(where: "date='2026-11-02'").first)
    let ids = try rig.store.slotPosts(mon.id).map(\.id).sorted()
    try rig.f.updateSettings { $0.sort = .bestFirst }
    rig.settle()
    #expect(try rig.store.planSlot(id: mon.id) != nil && rig.store.slotPosts(mon.id).map(\.id).sorted() == ids)
    #expect(try onePerClipAndChannel(rig))
    #expect(try rig.invariants().isEmpty)
  }

  /// The scheduler filling a gap behind a Back to Edit: the clip's job is cancelled, the new clip's goes in, no double.
  @Test func unscheduleAndGapFillStayClean() throws {
    let rig = try Rig(5, budget: 1000, approve: false)
    try rig.store.setHeldInEdit("clip-4", true)
    rig.engine.autoSchedules = true
    rig.settle()
    try BulkActions(store: rig.store).back(["clip-1"])
    try BulkActions(store: rig.store).sendToQueue(["clip-4"])
    rig.settle()
    #expect(try rig.store.planSlots(where: "video_id='clip-4'").first?.date == "2026-11-03")
    #expect(try rig.invariants().isEmpty)
    #expect(try rig.fake.livePosts.allSatisfy { try rig.video(of: $0) != "clip-1" })
  }
}

/// `djq schedule` and the retired week flags, against the built binary (no Postiz, no signal).
@Suite(.serialized) struct R13CLITests {
  typealias Env = R6PostizCLITests.Env

  @Test(.enabled(if: R6PostizCLITests.binary != nil)) func scheduleDryRunWritesNothingAndScheduleDoes() throws {
    let env = try Env(clips: 2)
    let dry = try env.json("schedule", "--dry-run")
    #expect(dry["dryRun"] as? Bool == true && dry["scheduled"] as? Int == 2)
    #expect(try env.store.planSlots().isEmpty)
    let real = try env.json("schedule")
    #expect(real["scheduled"] as? Int == 2)
    #expect(try env.store.planSlots().count == 2 && env.store.posts().count == 12)
    let again = try env.djq("schedule")
    #expect(again.status == 0 && again.out.contains("Queue 0 waiting"))
    let status = try env.djq("status")
    #expect(status.out.contains("Scheduled through ") && status.out.contains("Queue 0 waiting"))
    #expect(!status.out.contains("approved"))
  }

  @Test(.enabled(if: R6PostizCLITests.binary != nil)) func weekIsReadOnlyAndItsOldFlagsSayWhy() throws {
    let env = try Env(clips: 1)
    for flag in ["--propose", "--approve", "--rebuild"] {
      let r = try env.djq("week", flag)
      #expect(r.status == 2 && r.out.contains("Weeks don't need approval: clips in the Queue schedule themselves"))
    }
    #expect(try env.store.planSlots().isEmpty)
    #expect(try env.djq("week").status == 0)
  }

  @Test(.enabled(if: R6PostizCLITests.binary != nil)) func helpNoLongerOffersApprovalOrAddToWeek() throws {
    let env = try Env(clips: 1)
    let help = try env.djq("help").out
    #expect(!help.contains("add-to-week") && !help.contains("--approve") && !help.contains("--propose") && !help.contains("not scheduled yet"))
    #expect(help.contains("schedule [--dry-run] [--json]"))
    #expect(try env.djq("bulk", "add-to-week", "2026-11-02", "--ids", "clip-0").status != 0)
    #expect(try env.djq("queue").out.contains("scheduled 0"))
  }
}
