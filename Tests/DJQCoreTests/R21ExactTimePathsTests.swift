import Foundation
import Testing
@testable import DJQCore

/// Round 21 (D12): every planner path with set-time slots present. A set time sits outside the cadence, so the scheduler
/// never fills, shifts, swaps or re-lays it, and it never takes a regular position or blocks one.
/// The clock stands Monday 2026-11-02 09:00 New York; clip-0 is first in the Queue.
@Suite struct R21ExactTimePathsTests {
  typealias R = ExactRig

  func slot(_ f: Fixture, _ video: String) throws -> PlanSlot { try #require(try f.store.planSlots(where: "video_id=?", [video]).first) }

  /// The set-time clip's slot and posts, to compare before and after.
  func face(_ f: Fixture, _ video: String) throws -> [String] {
    try f.store.planSlots(where: "video_id=?", [video]).map { "slot \($0.id) \($0.date)#\($0.position) \($0.pinned) \($0.weekStart) \($0.exactAt?.timeIntervalSince1970 ?? -1)" }
      + f.store.posts(where: "video_id=?", [video], order: "id").map { "post \($0.id) \($0.platform.rawValue) \($0.scheduledAt.timeIntervalSince1970) \($0.state.rawValue) \($0.planSlotId ?? "-")" }
  }

  // MARK: openPositions / fill / isOpen

  @Test func aSetTimeSlotTakesNoneOfTheDaysRegularRoom() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-3", at: f.at("2026-11-03", "10:00"))
    let open = try planner.openPositions(now: f.clock.now, settings: f.store.settings(), dm: f.dm)
    #expect(open.prefix(3).map { "\($0.date)#\($0.position)" } == ["2026-11-02#0", "2026-11-03#0", "2026-11-04#0"])
    #expect(open.allSatisfy { $0.position < PlanSlot.exactBase })
    try planner.autoSchedule()
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-03#100 clip-3", "2026-11-04#0 clip-2"])
    #expect(try f.store.planSlots().filter { $0.position >= PlanSlot.exactBase }.map(\.videoId) == ["clip-3"])
  }

  @Test func twoADayStillFillsBothPositionsBesideSetTimes() throws {
    let f = try Fixture.engine(6)
    try f.updateSettings { $0.postsPerDay = 2 }
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-4", at: f.at("2026-11-02", "20:00"))
    try planner.postAt(videoId: "clip-5", at: f.at("2026-11-02", "20:30"))
    try planner.autoSchedule()
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#1 clip-1", "2026-11-02#100 clip-4", "2026-11-02#101 clip-5",
                                "2026-11-03#0 clip-2", "2026-11-03#1 clip-3"])
    #expect(try f.doublePosts().isEmpty && R.twice(f).isEmpty)
  }

  @Test func autoScheduleIsIdempotentWithSetTimesPresent() throws {
    let f = try Fixture.engine(6)
    try f.updateSettings { $0.postsPerDay = 2 }
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-5", at: f.at("2026-11-02", "20:00"))
    try planner.postAt(videoId: "clip-4", at: f.at("2026-11-09", "22:00"))
    #expect(try planner.autoSchedule().scheduled == 4)
    let plan = try R.plan(f)
    let events = try f.store.events().count
    for _ in 0..<3 {
      let r = try planner.autoSchedule()
      #expect(r.scheduled == 0 && r.relaid == 0 && r.clips.isEmpty)
      #expect(try R.plan(f) == plan && f.store.events().count == events)
    }
    // The engine's own tick agrees.
    let engine = Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier())
    engine.tick(reason: "t")
    engine.tick(reason: "t")
    #expect(try R.plan(f) == plan)
  }

  // MARK: Placer and plan days

  @Test func aSetTimePostHoldsNoRegularKeyAndItsPlanDayIsItsSlotsDate() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-2", at: f.at("2026-11-03", "15:00"))  // the very minute of YouTube's regular slot
    try planner.postAt(videoId: "clip-1", at: f.at("2026-11-03", "22:00"))  // YouTube goes at 2:30 am on the 4th
    let placer = try Placer(store: f.store, dm: f.dm)
    #expect(placer.taken.isEmpty)
    for p in Platform.allCases {
      #expect(!placer.isTaken(p, day: "2026-11-03", position: 0) && !placer.isTaken(p, day: "2026-11-03", position: 100))
    }
    #expect(try f.store.posts().allSatisfy { try f.store.planDay(of: $0, dm: f.dm) == "2026-11-03" })
    // A regular clip still takes that day, YouTube on the same minute: the set time is outside the cadence.
    try planner.clearExact(videoId: "clip-1")
    try planner.autoSchedule()
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-03#100 clip-2"])
    #expect(try f.post(.youtube, day: "2026-11-03", video: "clip-1")?.scheduledAt == f.at("2026-11-03", "15:00"))
    #expect(try f.post(.youtube, day: "2026-11-03", video: "clip-2")?.scheduledAt == f.at("2026-11-03", "15:00"))
    #expect(try R.twice(f).isEmpty)
  }

  // MARK: Slot times, push, relay

  @Test func aSlotTimeChangeLeavesSetTimePostsAlone() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try planner.postAt(videoId: "clip-2", at: f.at("2026-11-10", "19:00"))  // TikTok's own slot time, by chance
    let before = try face(f, "clip-2")
    let actions = PostActions(store: f.store)
    let dry = try actions.setSlot(.tiktok, minutes: 20 * 60, dryRun: true)
    #expect(dry.moved.map(\.post.videoId).sorted() == ["clip-0", "clip-1"])
    let change = try actions.setSlot(.tiktok, minutes: 20 * 60)
    #expect(change.moved.map(\.post.videoId).sorted() == ["clip-0", "clip-1"])
    #expect(change.kept.filter { $0.post.videoId == "clip-2" }.map(\.why) == ["it has a set time"])
    #expect(try face(f, "clip-2") == before)
    #expect(try f.post(.tiktok, day: "2026-11-02", video: "clip-0")?.scheduledAt == f.at("2026-11-02", "20:00"))
    // Undoing the slot change doesn't touch it either.
    try BulkActions(store: f.store).undo(try #require(change.batchId))
    #expect(try face(f, "clip-2") == before)
  }

  @Test func pushingThePlanLeavesSetTimesAlone() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try planner.postAt(videoId: "clip-2", at: f.at("2026-11-04", "10:00"))
    let before = try face(f, "clip-2")
    try planner.pushPlan(from: "2026-11-02", days: 2)
    #expect(try R.layout(f) == ["2026-11-04#0 clip-0", "2026-11-04#100 clip-2", "2026-11-05#0 clip-1"])
    #expect(try face(f, "clip-2") == before)
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func aRelayLeavesSetTimesAlone() throws {
    let f = try Fixture.engine(5)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()  // records the layout
    try planner.postAt(videoId: "clip-4", at: f.at("2026-11-04", "10:00"))
    let before = try face(f, "clip-4")
    try f.updateSettings { $0.postsPerDay = 2 }
    #expect(try planner.autoSchedule().relaid == 4)
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#1 clip-1", "2026-11-03#0 clip-2", "2026-11-03#1 clip-3", "2026-11-04#100 clip-4"])
    #expect(try face(f, "clip-4") == before)
    try f.updateSettings { $0.sort = .bestFirst }
    #expect(try planner.autoSchedule().relaid > 0)
    #expect(try face(f, "clip-4") == before)
    try f.updateSettings { $0.postsPerDay = 1 }
    #expect(try planner.autoSchedule().relaid > 0)
    #expect(try face(f, "clip-4") == before && f.doublePosts().isEmpty && R.twice(f).isEmpty)
  }

  // MARK: Missed days (the engine)

  @Test func aMissedSetTimeGoesOverdueAndIsNeverShifted() throws {
    let f = try Fixture.engine(5)
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-3", at: f.at("2026-11-03", "10:00"))
    try planner.postAt(videoId: "clip-4", at: f.at("2026-11-10", "10:00"))
    try planner.autoSchedule()
    let later = try face(f, "clip-4")
    f.setTime("2026-11-05", "09:00")  // the Mac slept through three days
    let n = LogNotifier()
    let engine = Engine(store: f.store, renderer: nil, publisher: nil, notifier: n).planFrozen
    let report = engine.tick(reason: "wake")
    #expect(report.errors.isEmpty, "\(report.errors)")
    let missed = try f.store.posts(where: "video_id='clip-3'")
    #expect(missed.count == 6 && missed.allSatisfy { $0.state == .overdue && $0.scheduledAt == f.at("2026-11-03", "10:00") })
    #expect(try slot(f, "clip-3").exactAt == f.at("2026-11-03", "10:00"))
    #expect(try face(f, "clip-4") == later)  // a set time ahead never joins a shift
    let body = try #require(n.delivered.first { $0.postId == missed[0].id }?.body)
    #expect(body.contains("Nothing else moved."))
    #expect(try f.doublePosts().isEmpty)
    // It has no slot to shift into; Post now and Skip work as for any post, and still nothing else moves.
    let actions = PostActions(store: f.store)
    #expect(throws: EngineError(StageWording.setTimeNoShift)) { try actions.shiftPlan(postId: missed[0].id) }
    try actions.postNow(postId: missed[1].id)
    #expect(try f.store.post(id: missed[1].id)?.state == .due && f.store.post(id: missed[1].id)?.scheduledAt == f.clock.now)
    try actions.skip(postId: missed[2].id)
    #expect(try f.store.post(id: missed[2].id)?.state == .skipped)
    #expect(try face(f, "clip-4") == later)
    // And a regular post that was missed doesn't drag a set time along.
    engine.tick(reason: "again")
    #expect(try face(f, "clip-4") == later)
  }

  // MARK: Moves

  @Test func movingASetTimeSlotKeepsItsClockTimeAndNeverSwaps() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let made = try planner.postAt(videoId: "clip-3", at: f.at("2026-11-14", "15:15"))
    let before = try R.others(f, except: "clip-3")
    try planner.move(slotId: made.id, to: "2026-11-03")  // a day that holds a regular clip
    var s = try slot(f, "clip-3")
    #expect(s.id == made.id && s.date == "2026-11-03" && s.exactAt == f.at("2026-11-03", "15:15") && s.position == 100 && s.pinned && s.weekStart == "2026-11-02")
    #expect(try f.store.posts(where: "video_id='clip-3'").count == 6)
    #expect(try f.store.posts(where: "video_id='clip-3'").allSatisfy { $0.scheduledAt == f.at("2026-11-03", "15:15") && $0.planSlotId == made.id })
    #expect(try R.others(f, except: "clip-3") == before)
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-03#100 clip-3", "2026-11-04#0 clip-2"])
    #expect(try f.store.events(videoId: "clip-3").first { $0.kind == "plan" }?.message == "Set for Tue 3 Nov 3:15 PM")
    // The same day: nothing to do.
    let same = try face(f, "clip-3")
    try planner.move(slotId: made.id, to: "2026-11-03")
    #expect(try face(f, "clip-3") == same)
    // Pin to date is the same move.
    try planner.pin(videoId: "clip-3", date: "2026-11-20")
    s = try slot(f, "clip-3")
    #expect(s.date == "2026-11-20" && s.exactAt == f.at("2026-11-20", "15:15") && s.weekStart == "2026-11-16")
    #expect(try f.store.week("2026-11-16")?.state == .approved)
    #expect(try R.others(f, except: "clip-3") == before)
    // Onto a day where that clock time is too close or gone: refused, and it stays where it is.
    let kept = try face(f, "clip-3")
    f.setTime("2026-11-02", "15:08")
    #expect(throws: EngineError(StageWording.setTimeTooSoon)) { try planner.move(slotId: made.id, to: "2026-11-02") }
    f.setTime("2026-11-02", "16:00")
    #expect(throws: EngineError(StageWording.setTimePassed)) { try planner.move(slotId: made.id, to: "2026-11-02") }
    #expect(throws: EngineError.self) { try planner.move(slotId: made.id, to: "2026-11-01") }
    #expect(try face(f, "clip-3") == kept)
  }

  @Test func aSetTimeMovedOntoADayWithAnotherTakesTheNextFreePlace() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let a = try planner.postAt(videoId: "clip-0", at: f.at("2026-11-14", "15:15"))
    let b = try planner.postAt(videoId: "clip-1", at: f.at("2026-11-15", "15:15"))
    try planner.move(slotId: b.id, to: "2026-11-14")
    #expect(try R.layout(f) == ["2026-11-14#100 clip-0", "2026-11-14#101 clip-1"])
    #expect(try slot(f, "clip-0") == a)
    #expect(try f.store.posts().allSatisfy { $0.scheduledAt == f.at("2026-11-14", "15:15") } && f.doublePosts().isEmpty)
  }

  @Test func aRegularSlotMovedOntoADayIgnoresTheSetTimeThere() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-2", at: f.at("2026-11-06", "10:00"))
    try planner.autoSchedule()
    let exact = try face(f, "clip-2")
    // The day's regular position is free: it takes it, no swap.
    try planner.move(slotId: try slot(f, "clip-0").id, to: "2026-11-06")
    #expect(try R.layout(f) == ["2026-11-03#0 clip-1", "2026-11-06#0 clip-0", "2026-11-06#100 clip-2"])
    #expect(try face(f, "clip-2") == exact)
    // The day is full: it swaps with the regular clip, never with the set-time one.
    try planner.move(slotId: try slot(f, "clip-1").id, to: "2026-11-06")
    #expect(try R.layout(f) == ["2026-11-03#0 clip-0", "2026-11-06#0 clip-1", "2026-11-06#100 clip-2"])
    #expect(try face(f, "clip-2") == exact)
    // Pinning a Queue clip to that day sees the same.
    try BulkActions(store: f.store).back(["clip-1"])
    try BulkActions(store: f.store).sendToQueue(["clip-1"])
    try planner.pin(videoId: "clip-1", date: "2026-11-06")
    #expect(try R.layout(f) == ["2026-11-03#0 clip-0", "2026-11-06#0 clip-1", "2026-11-06#100 clip-2"])
    #expect(try slot(f, "clip-1").pinned && face(f, "clip-2") == exact)
    #expect(try f.doublePosts().isEmpty && R.twice(f).isEmpty)
  }

  // MARK: Swap, Skip next, Post today

  @Test func swapSkipNextAndPostTodayLeaveASetTimeAlone() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let exact = try planner.postAt(videoId: "clip-1", at: f.at("2026-11-03", "10:00"))
    let plan = try R.plan(f)
    let other = try slot(f, "clip-0")
    #expect(throws: EngineError("It has a set time — change the time instead")) { try planner.swap(exact.id, other.id) }
    #expect(throws: EngineError(StageWording.hasSetTime)) { try planner.swap(other.id, exact.id) }
    #expect(throws: EngineError(StageWording.hasSetTime)) { try planner.skipNext(videoId: "clip-1") }
    #expect(throws: EngineError(StageWording.hasSetTime)) { try planner.postToday(videoId: "clip-1") }
    #expect(try BulkActions(store: f.store).postToday(["clip-1"]).skipped["clip-1"] == StageWording.hasSetTime)
    #expect(try R.plan(f) == plan)
    let face1 = try face(f, "clip-1")
    // Skip next on a regular clip passes over the set-time slot to the next regular one.
    try planner.skipNext(videoId: "clip-0")
    #expect(try R.layout(f) == ["2026-11-02#0 clip-2", "2026-11-03#100 clip-1", "2026-11-04#0 clip-0", "2026-11-05#0 clip-3"])
    #expect(try face(f, "clip-1") == face1)
    // Post today for another clip pushes the regular days and leaves it where it is.
    try planner.postToday(videoId: "clip-3")
    #expect(try R.layout(f) == ["2026-11-02#0 clip-3", "2026-11-03#0 clip-2", "2026-11-03#100 clip-1", "2026-11-05#0 clip-0"])
    #expect(try face(f, "clip-1") == face1)
    #expect(try f.doublePosts().isEmpty && R.twice(f).isEmpty)
  }

  // MARK: The week seams

  @Test func rebuildProposeApproveAndAdoptLeaveASetTimeAsItIs() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-3", at: f.at("2026-11-04", "22:00"))
    let exact = try face(f, "clip-3")
    #expect(throws: EngineError.self) { try planner.proposeWeek(f.week) }  // its week is approved, as `fill` leaves one
    try planner.rebuildWeek(f.week)  // back to a draft, re-proposed
    #expect(try f.store.week(f.week)?.state == .draft)
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-04#0 clip-2", "2026-11-04#100 clip-3"])
    #expect(try face(f, "clip-3") == exact)
    try planner.rebuildWeek(f.week)
    #expect(try face(f, "clip-3") == exact)
    // Adopting the draft week: the regular days become real, and the set time isn't counted or logged again.
    let events = try f.store.events(videoId: "clip-3").count
    let r = try planner.autoSchedule()
    #expect(r.scheduled == 3 && !r.clips.contains { $0.videoId == "clip-3" })
    #expect(try f.store.week(f.week)?.state == .approved)
    #expect(try face(f, "clip-3") == exact && f.store.events(videoId: "clip-3").count == events)
    // Approving again adds nothing to it.
    try planner.approveWeek(f.week)
    #expect(try face(f, "clip-3") == exact)
    #expect(try f.doublePosts().isEmpty && R.twice(f).isEmpty)
  }

  @Test func postsRegeneratedForASetTimeSlotComeBackAtItsTime() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.enabledPlatforms = Set(Platform.allCases).subtracting([.x]) }
    let planner = Planner(store: f.store)
    let at = f.at("2026-11-04", "22:00")
    let s = try planner.postAt(videoId: "clip-0", at: at)
    #expect(try f.store.posts().count == 5)
    let old = try f.store.posts().map(\.id)
    try f.store.db.transaction { try planner.regenerateMany([(s, true)], settings: f.store.settings(), dm: f.dm) }
    var posts = try f.store.posts()
    #expect(posts.count == 5 && Set(posts.map(\.id)).isDisjoint(with: old))
    #expect(posts.allSatisfy { $0.videoId == "clip-0" && $0.planSlotId == s.id && $0.scheduledAt == ($0.platform == .youtube ? R.utc("2026-11-05", 7, 30) : at) })
    // A platform turned on later is topped up by the approval seam at the set time, never at a slot time.
    try f.updateSettings { $0.enabledPlatforms = Set(Platform.allCases) }
    try planner.approveWeek(f.week)
    posts = try f.store.posts()
    #expect(posts.count == 6 && posts.first { $0.platform == .x }?.scheduledAt == at)
    // Not once the time has passed: nothing new is created in the past.
    let g = try Fixture.engine(1)
    try g.updateSettings { $0.enabledPlatforms = Set(Platform.allCases).subtracting([.x]) }
    try Planner(store: g.store).postAt(videoId: "clip-0", at: g.at("2026-11-02", "10:00"))
    g.setTime("2026-11-02", "11:00")
    try g.updateSettings { $0.enabledPlatforms = Set(Platform.allCases) }
    try Planner(store: g.store).approveWeek(g.week)
    #expect(try g.store.posts().count == 5)
  }

  @Test func aPastSetTimeIsNeverDroppedAsAStaleDraftDay() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    try planner.postAt(videoId: "clip-1", at: f.at("2026-11-03", "10:00"))
    try planner.rebuildWeek(f.week)  // draft week
    let exact = try face(f, "clip-1")
    f.setTime("2026-11-10", "09:00")
    #expect(try f.store.dropStalePastDraftSlots(today: "2026-11-10").map(\.videoId) == ["clip-0"])  // only the draft day with no posts
    #expect(try face(f, "clip-1") == exact)
  }

  // MARK: Back to Edit

  @Test func backToEditRemovesASetTimeLikeAnyOtherDay() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let at = f.at("2026-11-14", "22:00")
    try planner.postAt(videoId: "clip-0", at: at)
    let plan = try R.plan(f)
    let preview = try planner.unplanPreview(videoId: "clip-0")
    #expect(preview.map(\.date) == ["2026-11-14", "2026-11-15"])  // YouTube goes out the morning after
    #expect(preview[0].platforms.count == 5 && preview[0].pinned && preview[0].setTime == at)
    #expect(preview[1].platforms == [.youtube] && !preview[1].pinned && preview[1].setTime == nil)
    let bulk = BulkActions(store: f.store)
    let r = try bulk.back(["clip-0"])
    #expect(r.changed == ["clip-0"] && r.unplanned?["clip-0"] == preview)
    #expect(r.moves?["clip-0"]?.to == .edit)
    #expect(r.moves?["clip-0"]?.note == "Back in Edit — held there until you send it to the Queue · removed Sat 14 Nov · 5 platforms, Sun 15 Nov · 1 platform")
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.heldInEdit && ClipStage.of(v) == .edit)
    #expect(try planner.autoSchedule().clips.map(\.videoId) == ["clip-1"])  // held: it gets no day
    // Undo: the set time and its posts are back (the scheduler's own day for clip-1 is derived, so it doesn't block).
    try bulk.undo(try #require(r.batchId))
    #expect(try R.plan(f).filter { $0.contains("clip-0") } == plan.filter { $0.contains("clip-0") })
    #expect(try f.store.video(id: "clip-0")?.heldInEdit == false)
    // Remove from queue (the older door) and `remove(slotId:)` do the same.
    #expect(try bulk.removeFromQueue(["clip-0"]).unplanned?["clip-0"]?.first?.setTime == at)
    #expect(try f.store.planSlots(where: "video_id='clip-0'").isEmpty)
    try bulk.sendToQueue(["clip-0"])
    let again = try planner.postAt(videoId: "clip-0", at: at)
    try planner.remove(slotId: again.id)
    #expect(try f.store.planSlots(where: "video_id='clip-0'").isEmpty && f.store.posts(where: "video_id='clip-0'").isEmpty)
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
  }

  // MARK: Runway

  @Test func setTimesAreNotScheduledDaysOfTheCadence() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    let queue = Queue(store: f.store)
    try planner.postAt(videoId: "clip-2", at: f.at("2026-11-03", "10:00"))
    var rw = try queue.runway()
    #expect(rw.approvedDays == 0 && rw.scheduledThrough == nil && rw.readyDays == 2)
    try planner.autoSchedule()
    rw = try queue.runway()
    #expect(rw.approvedDays == 2 && rw.scheduledThrough == "2026-11-03")
    try planner.postAt(videoId: "clip-1", at: f.at("2026-11-04", "10:00"))  // leaves Tuesday; Wednesday holds only a set time
    rw = try queue.runway()
    #expect(rw.approvedDays == 1 && rw.scheduledThrough == "2026-11-02")
    #expect(StageWording.scheduledThrough(rw.scheduledThrough, settings: try f.store.settings()) == "Scheduled through Mon 2 Nov")
  }

  @Test func addToWeekCountsOnlyRegularSlots() throws {
    let f = try Fixture.engine(2)
    try Planner(store: f.store).postAt(videoId: "clip-1", at: f.at("2026-11-02", "20:00"))
    try BulkActions(store: f.store).addToWeek(["clip-0"], week: f.week)
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#100 clip-1"])
  }
}

/// Round 21 through Postiz: a set time reaches Postiz at that minute on every channel, a change replaces its copies, and
/// "never double-post" holds on Postiz's side throughout.
@Suite struct R21ExactTimePostizTests {
  typealias Rig = R6PostizLifecycleTests.Rig
  typealias R = ExactRig

  /// Channel → when Postiz will publish `video` there (live copies only).
  func dates(_ rig: Rig, _ video: String) throws -> [String: Date] {
    var out: [String: Date] = [:]
    for p in rig.fake.livePosts where try rig.video(of: p) == video {
      #expect(out[p.integrationId] == nil, "two live copies on \(p.integrationId)")
      out[p.integrationId] = p.date
    }
    return out
  }

  @Test func aSetTimeGoesToPostizAtThatMinuteAndAChangeReplacesItsCopies() throws {
    let rig = try Rig(3, approve: false)
    rig.engine.autoSchedules = true
    let bulk = BulkActions(store: rig.store)
    let at = rig.f.at("2026-11-04", "22:00")
    #expect(try bulk.postAt(["clip-2"], at: at).changed == ["clip-2"])
    rig.settle()
    var d = try dates(rig, "clip-2")
    #expect(d.count == 6 && d["ch-youtube"] == R.utc("2026-11-05", 7, 30))
    #expect(d.filter { $0.key != "ch-youtube" }.values.allSatisfy { $0 == at })
    #expect(try rig.invariants().isEmpty)
    // The regular clips went out on their own days beside it.
    #expect(try R.layout(rig.f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-04#100 clip-2"])
    // A new time: the old copies go, the new ones carry it, one per channel.
    let to = rig.f.at("2026-11-05", "09:45")
    #expect(try bulk.postAt(["clip-2"], at: to).changed == ["clip-2"])
    rig.f.clock.advance(600)
    rig.settle()
    d = try dates(rig, "clip-2")
    #expect(d.count == 6 && d.values.allSatisfy { $0 == to })
    #expect(try rig.invariants().isEmpty)
    // Back on the regular schedule: the scheduler gives it a day and Postiz follows.
    #expect(try bulk.clearExact(["clip-2"]).changed == ["clip-2"])
    rig.f.clock.advance(600)
    rig.settle()
    let day = try #require(try rig.store.planSlots(where: "video_id='clip-2'").first)
    #expect(!day.isExact && day.position == 0)
    d = try dates(rig, "clip-2")
    #expect(d.count == 6 && d["ch-tiktok"] == rig.f.at(day.date, "19:00"))
    #expect(try rig.invariants().isEmpty)
  }

  @Test func aPostEricDeletedInPostizIsNeverSentBackBySettingATime() throws {
    let rig = try Rig(4, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()
    let th = try #require(try rig.f.post(.threads, day: "2026-11-05"))
    rig.fake.vanish(try #require(try rig.job(th)).postizId!)
    rig.f.clock.advance(600)
    rig.tick(3)
    let name = try #require(try rig.store.video(id: th.videoId)).displayName
    let refusal = "\(name) has a post you removed from Postiz"
    let plan = try R.plan(rig.f)
    let at = rig.f.at("2026-11-14", "15:15")
    #expect(throws: EngineError(refusal)) { try Planner(store: rig.store).postAt(videoId: th.videoId, at: at) }
    #expect(try Planner(store: rig.store).postAtPreview(videoId: th.videoId, at: at).blocker == refusal)
    let r = try BulkActions(store: rig.store).postAt([th.videoId], at: at)
    #expect(r.changed.isEmpty && r.skipped[th.videoId] == refusal)
    #expect(try R.plan(rig.f) == plan)
    #expect(try rig.invariants().isEmpty)
  }
}
