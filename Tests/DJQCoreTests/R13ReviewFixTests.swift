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
