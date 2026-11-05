import Foundation
import Testing
@testable import DJQCore

/// Regression tests for the round 13 review of Part A (H1–H4, M1–M3, L1–L3).
@Suite struct R13ReviewFixTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  /// Nothing to fix, scored, never sent.
  func unsent(_ f: Fixture, _ id: String = "clip-0", score: Int = 50) throws {
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: id)
    var v = Version(number: 1)
    v.text = "Text \(id)"
    v.captionTemplateId = "short"
    try f.store.save(v, videoId: id)
    try f.store.setScore(id, score)
    try f.store.refreshState(videoId: id)
  }

  // MARK: H1: plan days past midnight

  /// Two live regular posts on one platform at the same minute.
  func clashes(_ f: Fixture) throws -> [String] {
    let s = try f.store.settings()
    let live = try f.store.posts(where: "kind='regular'").filter { !$0.state.isTerminal }
    return Dictionary(grouping: live) { "\($0.platform.rawValue) \(Sched.shortTime($0.scheduledAt, s))" }
      .filter { $0.value.count > 1 }.map { "\($0.key) x\($0.value.count)" }.sorted()
  }

  /// Every post at its own slot's time, on every platform.
  func offSlot(_ f: Fixture) throws -> [String] {
    let s = try f.store.settings()
    let dm = DayMath(settings: s)
    var out: [String] = []
    for slot in try f.store.planSlots() {
      for p in try f.store.slotPosts(slot.id) where p.scheduledAt != Sched.slotTime(s, dm, date: slot.date, position: slot.position, platform: p.platform) {
        out.append("\(p.platform.rawValue) of \(slot.date)#\(slot.position) at \(Sched.shortTime(p.scheduledAt, s))")
      }
    }
    return out
  }

  /// `perDay` clips at first, then one Send to Queue per pass, as in real use: each pass builds a new Placer.
  func onePerPass(perDay: Int, clips: Int = 24) throws -> Fixture {
    let f = try Fixture.engine(clips, ready: perDay)
    try f.updateSettings { $0.postsPerDay = perDay; $0.secondPostOffsetMinutes = 180 }
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    for i in perDay..<clips {
      try f.makeReady("clip-\(i)", score: 50)
      try planner.autoSchedule()
    }
    return f
  }

  @Test func threeADayWithAPositionPastMidnightNeverClashes() throws {
    let f = try onePerPass(perDay: 3)
    #expect(try f.store.planSlots().count == 24)
    #expect(try clashes(f) == [])
    #expect(try offSlot(f) == [])
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func twoADayWithOnePerPassStaysOnItsSlots() throws {
    let f = try onePerPass(perDay: 2)
    #expect(try clashes(f) == [] && offSlot(f) == [])
  }

  @Test func aMissedPostShiftsPlanDaysPastMidnightOneDayEach() throws {
    let f = try onePerPass(perDay: 3, clips: 12)
    let dm = DayMath(settings: try f.store.settings())
    let slot = try #require(try f.store.planSlots(where: "date='2026-11-03' AND position=2").first)
    let first = try #require(try f.store.slotPosts(slot.id).first { $0.platform == .instagram })
    let rest = try f.store.movablePosts(platform: .instagram, position: 2, after: first.scheduledAt, excluding: first.id)
    #expect(!rest.isEmpty)
    let before = try rest.map { try f.store.planDay(of: $0, dm: dm) }
    #expect(try f.store.reflow(rest, days: 1, dm: dm, note: "t") == rest.count)
    let after = try rest.map { try f.store.planDay(of: try #require(try f.store.post(id: $0.id)), dm: dm) }
    #expect(after == before.map { dm.addDays($0, 1) })
    #expect(try clashes(f) == [])
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func pushingThePlanKeepsPostsPastMidnightOnTheirSlots() throws {
    let f = try onePerPass(perDay: 3, clips: 9)
    try Planner(store: f.store).pushPlan(from: "2026-11-02", days: 2)
    #expect(try offSlot(f) == [] && clashes(f) == [])
  }

  @Test func makingRoomSeesThePlanDayOfAPostPastMidnight() throws {
    let f = try onePerPass(perDay: 3, clips: 9)
    let dm = DayMath(settings: try f.store.settings())
    let s = try f.store.settings()
    // Tuesday position 2 on Instagram posts at 00:00 Wednesday: it's Tuesday's, and it can be moved out of Tuesday.
    let room = try PostActions(store: f.store).makeRoom(platform: .instagram, position: 2, day: "2026-11-03", excluding: "none", dm: dm, settings: s)
    #expect(room)
    #expect(try clashes(f) == [])
  }

  // MARK: H2: the migration needs proof of a send

  func migrate(_ f: Fixture, setup: (SQLite) throws -> Void) throws -> Store {
    let dir = f.dir.appendingPathComponent("v6-\(UUID().uuidString)")
    let paths = Paths(root: f.paths.root, appSupport: dir, logs: f.paths.logs, launchAgents: f.paths.launchAgents)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("queue.sqlite").path
    try f.store.db.backup(to: file)
    do {
      let db = try SQLite(path: file)
      try db.run("UPDATE videos SET sent_to_queue=0")
      try setup(db)
      try db.exec("ALTER TABLE videos DROP COLUMN sent_to_queue; PRAGMA user_version = 6;")
    }
    return try Store(paths: paths, clock: f.clock, path: file)
  }

  @Test func aReadyClipCountsAsSentOnlyWithProof() throws {
    let f = try Fixture.engine(5)
    let s = try migrate(f) { db in
      func event(_ id: String, _ message: String) throws {
        try db.run("INSERT INTO events(at,kind,message,video_id) VALUES(1,'queue',?,?)", [message, id])
      }
      try db.run("DELETE FROM events WHERE kind='queue'")
      try event("clip-1", "Sent to Queue")
      try event("clip-2", "Sent to Queue")
      try event("clip-2", "Sent back to Edit from Queue")
      try event("clip-3", "Sent back to Edit from Queue")
      try event("clip-3", "Sent to Queue")
    }
    #expect(try s.videos(where: "type='short-form'").filter(\.sentToQueue).map(\.id).sorted() == ["clip-1", "clip-3"])
    #expect(try s.videos(where: "type='short-form'").allSatisfy { $0.state == .ready })  // no state changes in the migration
    // The first stage check after it: no proof, so Edit, and the scheduler never sees them.
    try Revalidation(store: s).run()
    #expect(try Queue(store: s).ordered().map(\.id).sorted() == ["clip-1", "clip-3"])
    #expect(try s.video(id: "clip-0")?.state == .needsEdit)
  }

  @Test func clipsWithADayOrPostsStaySentWithoutAnEvent() throws {
    let f = try Fixture.engine(4)
    let s = try migrate(f) { db in
      try db.run("DELETE FROM events WHERE kind='queue'")
      for (id, state) in [("clip-0", "planned"), ("clip-1", "posting"), ("clip-2", "posted"), ("clip-3", "partial")] {
        try db.run("UPDATE videos SET state=? WHERE id=?", [state, id])
      }
    }
    #expect(try s.videos(where: "type='short-form'").filter(\.sentToQueue).count == 4)
  }

  // MARK: H3: a partial undo

  @Test func aPartialUndoLeavesThePlanSoAHeldClipHasNoLivePosts() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let thu = try #require(try f.store.planSlots(where: "date='2026-11-05'").first)
    let b = BulkActions(store: f.store)
    let back = try b.back([thu.videoId])
    try planner.autoSchedule()
    try b.setTitle([thu.videoId], "Fixed in Edit")
    let r = try b.undo(try #require(back.batchId))
    #expect(r.skipped[thu.videoId] != nil && r.summary.contains("plan left as it is"))
    let v = try #require(try f.store.video(id: thu.videoId))
    #expect(v.heldInEdit && !v.sentToQueue)
    #expect(try f.store.posts(where: "video_id=?", [thu.videoId]).isEmpty && f.store.planSlot(id: thu.id) == nil)
    // The batch stays open: a forced undo restores all of it.
    let forced = try b.undo(try #require(back.batchId), force: true)
    #expect(forced.skipped.isEmpty)
    #expect(try f.store.planSlot(id: thu.id) == thu && f.store.video(id: thu.videoId)?.state == .planned)
    #expect(try f.store.video(id: thu.videoId)?.heldInEdit == false)
  }

  @Test func aPartialUndoSendsNothingOfAHeldClipToPostiz() throws {
    let rig = try Rig(4, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()
    let thu = try #require(try rig.store.planSlots(where: "date='2026-11-05'").first)
    let vid = thu.videoId
    let b = BulkActions(store: rig.store)
    let back = try b.back([vid])
    rig.settle()
    try b.setKind([vid], .talking)
    try b.undo(try #require(back.batchId))
    rig.settle()
    #expect(try rig.fake.livePosts.filter { try rig.video(of: $0) == vid }.isEmpty)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func publishRefusesAHeldClipOnItsOwn() throws {
    let rig = try Rig(2, change: { $0.paused = true })
    rig.settle()  // rendered, nothing in Postiz while paused
    #expect(try rig.store.posts().contains { $0.renderId != nil })
    try rig.store.setHeldInEdit("clip-0", true)  // posts left behind, whatever the cause
    try rig.f.updateSettings { $0.paused = false }
    rig.settle()
    #expect(try rig.fake.livePosts.allSatisfy { try rig.video(of: $0) == "clip-1" })
    #expect(rig.fake.createCount == 6)
  }

  // MARK: H4: final Postiz jobs

  @Test func aRelayNeverSendsBackAPostEricDeletedInPostiz() throws {
    let rig = try Rig(4, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()
    let th = try #require(try rig.f.post(.threads, day: "2026-11-05"))
    rig.fake.vanish(try #require(try rig.job(th)).postizId!)
    rig.f.clock.advance(600)
    rig.tick()
    let manual = try #require(try rig.store.post(id: th.id))
    #expect(manual.publisher == "manual")
    rig.tick(2)
    try rig.f.updateSettings { $0.postsPerDay = 2 }
    rig.settle()
    #expect(try rig.store.post(id: th.id) != nil)  // same post, same slot
    #expect(try rig.store.posts(where: "video_id=? AND platform='threads'", [th.videoId]).allSatisfy { try rig.job($0) == nil })
    #expect(try rig.invariants().isEmpty)
  }

  @Test func undoWontDropADerivedPostWithAFinalPostizJob() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store), b = BulkActions(store: f.store)
    try f.store.setHeldInEdit("clip-3", true)
    try planner.autoSchedule()
    let r = try b.back(["clip-2"])
    try f.store.setHeldInEdit("clip-3", false)
    try f.store.setSentToQueue("clip-3", true)
    try planner.autoSchedule()
    let p = try #require(try f.store.posts(where: "video_id='clip-3'").first)
    let job = PostizJob(postId: p.id, videoId: p.videoId, platform: p.platform, integrationId: "ch", phase: .live, postizId: "z",
                        renderId: "r", contentHash: "h", scheduledAt: p.scheduledAt, remoteDate: p.scheduledAt, testMode: false,
                        postType: "schedule", createdAt: f.clock.now, updatedAt: f.clock.now)
    try f.store.save(job)
    try f.store.closePostizJob(id: job.id, reason: .vanished, note: "gone")
    #expect(throws: EngineError.self) { try b.undo(try #require(r.batchId)) }
  }

  // MARK: M1: swaps inside the lead

  @Test func aSwapOntoTodayInsideTheLeadIsRefused() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    let wed = try #require(try f.store.planSlots(where: "date='2026-11-04'").first)
    let posts = try f.store.posts().map(\.id).sorted()
    f.setTime("2026-11-02", "13:00")
    #expect(throws: EngineError("Today's slot is too soon")) { try planner.move(slotId: mon.id, to: "2026-11-04") }
    #expect(throws: EngineError("Today's slot is too soon")) { try planner.swap(mon.id, wed.id) }
    #expect(throws: EngineError("Today's slot is too soon")) { try planner.skipNext(videoId: mon.videoId) }
    #expect(try f.store.posts().map(\.id).sorted() == posts)
    #expect(try f.store.planSlot(id: mon.id) == mon)
  }

  @Test func aSwapBeforeTheLeadStillWorks() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    let wed = try #require(try f.store.planSlots(where: "date='2026-11-04'").first)
    try planner.move(slotId: mon.id, to: "2026-11-04")  // 09:00: Monday's Facebook is 3.5 h away
    #expect(try f.store.planSlot(id: wed.id)?.date == "2026-11-02")
    #expect(try f.store.posts().allSatisfy { $0.scheduledAt >= f.clock.now.addingTimeInterval(Planner.autoScheduleLead) })
  }

  // MARK: M2, M3

  @Test func undoingAnUnrelatedEditDoesntSendAClipBackToTheQueue() throws {
    let f = try Fixture.engine(3)
    let b = BulkActions(store: f.store)
    let t = try b.setTitle(["clip-0"], "New title")
    let old = try #require(try f.store.settings().limits[.x]?.maxDuration)
    try f.updateSettings { $0.limits[.x]?.maxDuration = 5 }
    try Revalidation(store: f.store).run()
    try f.updateSettings { $0.limits[.x]?.maxDuration = old }
    try Revalidation(store: f.store).run()
    #expect(try f.store.video(id: "clip-0")?.state == .needsEdit)
    let u = try b.undo(try #require(t.batchId))
    #expect(u.changed == ["clip-0"])  // the title came back
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.titleText == nil && v.state == .needsEdit && !v.sentToQueue)
  }

  @Test func makeReadyWontSendAnExcludedClip() throws {
    let f = try Fixture.engine(2, ready: 0)
    try unsent(f)
    let b = BulkActions(store: f.store)
    try b.setExcluded(["clip-0"], true)
    let r = try b.makeReadyWithDefaults(["clip-0"])
    #expect(r.changed.isEmpty && r.skipped["clip-0"] == "excluded — include it first")
    try b.setExcluded(["clip-0"], false)
    #expect(try f.store.video(id: "clip-0")?.state == .needsEdit)
  }

  // MARK: L1, L2

  @Test func aSlotJustAfterMidnightInsideTheLeadIsNotTaken() throws {
    let f = try Fixture.engine(1)
    try f.updateSettings { s in for p in Platform.allCases { s.slotMinutes[p] = 10 } }
    f.setTime("2026-11-02", "23:50")
    try Planner(store: f.store).autoSchedule()
    let slots = try f.store.planSlots()
    #expect(slots.map(\.date) == ["2026-11-04"])
    #expect(try slots.allSatisfy { try !f.store.slotPosts($0.id).isEmpty })
    #expect(try f.store.posts().count == 6)
  }

  @Test func aClipThatCanNeverGetADayIsntCountedAsWaiting() throws {
    let f = try Fixture.engine(2)
    try f.store.setAlreadyPostedOn("clip-0", Platform.allCases)
    try f.store.setAlreadyPostedOn("clip-1", Platform.allCases)
    let r = try Planner(store: f.store).autoSchedule()
    #expect(r.waiting == 0 && r.nowhereToPost == 2)
    #expect(r.reason == "2 clips in the Queue with nowhere left to post")
    let rw = try Queue(store: f.store).runway()
    let settings = try f.store.settings()
    #expect(rw.readyDays == 0 && rw.isLow(settings))
    let d = Doctor(store: f.store)
    let info = try #require(try d.nowhereToPost().first)
    #expect(info.id == "plan.nowhereToPost" && info.severity == .info && info.where_.count == 2)
  }

  // MARK: Kept from the review's probes

  @Test func aRelayKeepsASkippedPostSkipped() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let thu = try #require(try f.store.planSlots(where: "date='2026-11-05'").first)
    let tt = try #require(try f.store.slotPosts(thu.id).first { $0.platform == .tiktok })
    try PostActions(store: f.store).skip(postId: tt.id)
    try f.updateSettings { $0.postsPerDay = 2 }
    try planner.autoSchedule()
    let all = try f.store.posts(where: "video_id=?", [thu.videoId])
    #expect(all.filter { !$0.state.isTerminal }.count == 5 && !all.contains { $0.platform == .tiktok && !$0.state.isTerminal })
  }

  @Test func backToEditThenUndoKeepsOneLivePostizPostPerClip() throws {
    let rig = try Rig(4, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()
    let thu = try #require(try rig.store.planSlots(where: "date='2026-11-05'").first)
    let b = BulkActions(store: rig.store)
    let back = try b.back([thu.videoId])
    rig.settle()
    try b.undo(try #require(back.batchId))
    rig.settle()
    #expect(try rig.invariants().isEmpty && rig.fake.livePosts.count == 24)
  }

  // MARK: L3

  @Test func wordsLeftOver() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let guide = try String(contentsOf: repo.appendingPathComponent("docs/postiz-test.md"), encoding: .utf8)
    #expect(!guide.contains("Approve") && !guide.contains("approved") && !guide.contains("Today"))
    let cli = try String(contentsOf: repo.appendingPathComponent("Sources/djq/PostizCommand.swift"), encoding: .utf8)
    #expect(!cli.contains("approved week"))
    let main = try String(contentsOf: repo.appendingPathComponent("Sources/djq/main.swift"), encoding: .utf8)
    #expect(main.contains("make-ready (Send to Queue with defaults"))
  }
}

/// Regression tests for the second review (N1–N6, and held clips in the platform step).
@Suite struct R13ReReviewTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  /// Thursday's Threads post, deleted in Postiz: its job is closed for good.
  func deletedInPostiz() throws -> (Rig, PlatformPost) {
    let rig = try Rig(4, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()
    let th = try #require(try rig.f.post(.threads, day: "2026-11-05"))
    rig.fake.vanish(try #require(try rig.job(th)).postizId!)
    rig.f.clock.advance(600)
    rig.tick(3)
    #expect(try rig.store.post(id: th.id)?.publisher == "manual")
    return (rig, th)
  }

  @Test func aSwapNeverSendsBackAPostEricDeletedInPostiz() throws {
    let (rig, th) = try deletedInPostiz()
    let planner = Planner(store: rig.store)
    let thu = try #require(try rig.store.planSlots(where: "date='2026-11-05'").first)
    let wed = try #require(try rig.store.planSlots(where: "date='2026-11-04'").first)
    let name = try #require(try rig.store.video(id: th.videoId)).displayName
    let refusal = EngineError("\(name) has a post you removed from Postiz")
    #expect(throws: refusal) { try planner.move(slotId: wed.id, to: "2026-11-05") }  // another clip dragged onto Thursday
    #expect(throws: refusal) { try planner.swap(wed.id, thu.id) }
    #expect(throws: refusal) { try planner.move(slotId: thu.id, to: "2026-11-20") }  // or the clip itself
    #expect(throws: refusal) { try planner.postToday(videoId: th.videoId) }
    #expect(throws: refusal) { try planner.pin(videoId: th.videoId, date: "2026-11-20") }
    #expect(throws: refusal) { try planner.remove(slotId: thu.id) }  // Move one slot later with no swap partner lands here
    rig.settle()
    #expect(try rig.store.post(id: th.id) != nil && rig.job(th) == nil)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func backToEditThenSendStaysTheExplicitWayToSendItAgain() throws {
    let (rig, th) = try deletedInPostiz()
    let b = BulkActions(store: rig.store)
    #expect(try b.back([th.videoId]).changed == [th.videoId])
    rig.settle()
    #expect(try b.sendToQueue([th.videoId]).changed == [th.videoId])
    rig.settle()
    #expect(try rig.store.posts(where: "video_id=? AND platform='threads'", [th.videoId]).contains { !$0.state.isTerminal })
    #expect(try rig.invariants().isEmpty)
  }

  @Test func undoWontRestoreAPostInsideTheLead() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store), b = BulkActions(store: f.store)
    try planner.autoSchedule()
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    let back = try b.back([mon.videoId])
    try planner.autoSchedule()
    f.setTime("2026-11-02", "13:00")
    #expect(throws: EngineError.self) { try b.undo(try #require(back.batchId)) }
    do {
      try b.undo(try #require(back.batchId))
    } catch {
      #expect("\(error)".contains("its slot has passed"))
    }
    #expect(try f.store.posts(where: "video_id=?", [mon.videoId]).isEmpty)  // nothing half done
    #expect(try f.store.video(id: mon.videoId)?.heldInEdit == true)
    try b.undo(try #require(back.batchId), force: true)  // Eric's force still can
    #expect(try f.store.posts(where: "video_id=?", [mon.videoId]).count == 6)
  }

  @Test func undoOfASwapHoursLaterIsRefusedAndTheEarlyOneStillWorks() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store), b = BulkActions(store: f.store)
    try planner.autoSchedule()
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    let r = try b.record("move", ids: [mon.videoId], plan: true) { try planner.move(slotId: mon.id, to: "2026-11-04") }
    f.setTime("2026-11-02", "11:59")  // Facebook at 12:30 is 31 min away
    let u = try b.undo(try #require(r.batchId), dryRun: true)
    #expect(u.skipped.isEmpty)
    f.setTime("2026-11-02", "12:01")
    #expect(throws: EngineError.self) { try b.undo(try #require(r.batchId)) }
  }

  @Test func aLaterMoveToEditVoidsAnOlderSendInTheMigration() throws {
    let f = try Fixture.engine(3)
    let s = try R13ReviewFixTests().migrate(f) { db in
      try db.run("DELETE FROM events WHERE kind='queue'")
      func event(_ kind: String, _ message: String, _ id: String) throws {
        try db.run("INSERT INTO events(at,kind,message,video_id) VALUES(1,?,?,?)", [kind, message, id])
      }
      try event("queue", "Sent to Queue", "clip-0")
      try event("stage", "Moved to Edit: No crop", "clip-0")  // then round 4 promoted it by itself
      try event("queue", "Sent to Queue", "clip-1")
      try event("stage", "Moved to Edit: No crop", "clip-1")
      try event("queue", "Sent to Queue", "clip-1")  // sent again by hand
    }
    #expect(try s.video(id: "clip-0")?.sentToQueue == false)
    #expect(try s.video(id: "clip-1")?.sentToQueue == true)
    #expect(try s.video(id: "clip-2")?.sentToQueue == false)
  }

  @Test func aPartialUndoOfAPinStillTakesThePinOff() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store), b = BulkActions(store: f.store)
    try planner.autoSchedule()
    let tue = try #require(try f.store.planSlots(where: "date='2026-11-03'").first)
    let r = try b.record("pin", ids: [tue.videoId], plan: true) { try planner.pin(videoId: tue.videoId, date: "2026-11-09") }
    try b.setTitle([tue.videoId], "Later title")
    let u = try b.undo(try #require(r.batchId))
    #expect(u.skipped[tue.videoId] != nil && !u.summary.contains("plan left as it is"))
    #expect(try f.store.planSlots(where: "video_id=?", [tue.videoId]).first == tue)
    #expect(try f.store.video(id: tue.videoId)?.titleText == "Later title")
  }

  @Test func postNowBeforeDawnHoldsItsDay() throws {
    let f = try Fixture.engine(9)
    try f.updateSettings { $0.postsPerDay = 3; $0.secondPostOffsetMinutes = 180 }
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    f.setTime("2026-11-05", "04:04")  // Thursday, before dawn
    let slot = try #require(try f.store.planSlots(where: "date='2026-11-03' AND position=2").first)
    let x = try #require(try f.store.slotPosts(slot.id).first { $0.platform == .x })
    try PostActions(store: f.store).postNow(postId: x.id)
    let dm = DayMath(settings: try f.store.settings())
    let now = try #require(try f.store.post(id: x.id))
    #expect(try f.store.planDay(of: now, dm: dm) == "2026-11-05")
    let placer = try Placer(store: f.store, dm: dm)
    #expect(placer.isTaken(.x, day: "2026-11-05", position: 2))
    // Shifted back onto a slot, it's a plan day like any other.
    try PostActions(store: f.store).shiftPlan(postId: x.id)
    let shifted = try #require(try f.store.post(id: x.id))
    #expect(shifted.state != .due || shifted.scheduledAt != now.scheduledAt)
  }

  @Test func aClipThatJustWasntSentMovesToEditWithoutABlankReason() throws {
    let f = try Fixture.engine(2)
    try f.store.db.run("UPDATE videos SET sent_to_queue=0 WHERE id='clip-0'")  // as a migrated, unproven clip
    let r = try Revalidation(store: f.store).run()
    #expect(try f.store.video(id: "clip-0")?.state == .needsEdit)
    #expect(r.movedToEdit["clip-0"] == [])
    #expect(try !f.store.events(videoId: "clip-0").contains { $0.message.hasPrefix("Moved to Edit") })
  }

  @Test func aHeldClipWithAFixedTooLongFailureDoesntStopThePlatformStep() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    var q = try #require(try f.store.slotPosts(mon.id).first { $0.platform == .x })
    q.state = .failed; q.errorType = .tooLong; q.rawResponse = Engine.platformCheckMarker; q.errorMessage = "too long"
    try f.store.save(q, note: "t")
    try BulkActions(store: f.store).back([mon.videoId])
    let r = Engine(store: f.store, renderer: FakeRenderer(store: f.store), publisher: nil, notifier: LogNotifier()).planFrozen.tick(reason: "t")
    #expect(r.errors.isEmpty, "\(r.errors)")
    #expect(try f.store.post(id: q.id)?.state == .failed)
  }
}
