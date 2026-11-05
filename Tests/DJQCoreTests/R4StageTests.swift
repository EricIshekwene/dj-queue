import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 4 S1 "Stage = readiness": the Queue only ever holds ready clips; an invalid one moves to Edit by itself with
/// a reason chip; the stage control names the real neighbour; no "Ready" / "Needs edit" / "Unready" wording.
@Suite struct R4StageTests {
  // MARK: helpers

  /// Clears the crop behind the store's back (no refreshState), like a path that leaves the stored state stale.
  func clearCropStale(_ f: Fixture, _ id: String) throws {
    var e = try f.store.edit(videoId: id)
    e.crop = nil
    try f.store.db.run("UPDATE edits SET json=? WHERE video_id=?", [JSONCoding.string(e), id])
  }

  /// Lowers X's length limit so only clips trimmed longer than 18.5 s fail (clip-5 = 19 s in `Fixture.engine`).
  func lowerXLimit(_ f: Fixture) throws {
    try f.updateSettings { $0.limits[.x]?.maxDuration = 18.5 }
  }

  func removeFile(_ f: Fixture, _ id: String) throws {
    let v = try #require(try f.store.video(id: id))
    try FileManager.default.removeItem(at: try #require(try f.store.fileURL(for: v)))
  }

  func engine(_ f: Fixture, renderer: RenderService? = nil) -> (Engine, LogNotifier) {
    let n = LogNotifier()
    return (Engine(store: f.store, renderer: renderer, publisher: nil, notifier: n), n)
  }

  func video(_ f: Fixture, _ id: String) throws -> Video { try #require(try f.store.video(id: id)) }

  func chips(_ f: Fixture, _ id: String) throws -> [String] {
    try Validation.issues(video: video(f, id), store: f.store).map(\.chipText)
  }

  /// The three S1 cases are invalid but their stored state still says Queue.
  func makeThreeStale(_ f: Fixture) throws {
    try clearCropStale(f, "clip-0")
    try lowerXLimit(f)
    try removeFile(f, "clip-2")
    for id in ["clip-0", "clip-2", "clip-5"] { #expect(try ClipStage.of(video(f, id)) == .queue) }
  }

  func expectThreeInEdit(_ f: Fixture) throws {
    #expect(try ClipStage.of(video(f, "clip-0")) == .edit)
    #expect(try chips(f, "clip-0") == ["No crop"])
    #expect(try ClipStage.of(video(f, "clip-5")) == .edit)
    #expect(try chips(f, "clip-5") == ["Too long for X"])
    let missing = try video(f, "clip-2")
    #expect(missing.missing && ClipStage.of(missing) == .edit)
    #expect(try chips(f, "clip-2").first == "File missing")
    // The Queue never lists them; the others stay.
    let queued = Set(try Queue(store: f.store).ordered().map(\.id))
    #expect(queued.isDisjoint(with: ["clip-0", "clip-2", "clip-5"]))
    // …and the Edit list (Edit page, djq status/queue counts) has all three, the missing-file clip included.
    let edit = try Queue(store: f.store).needsEdit()
    #expect(Set(edit.map(\.id)) == ["clip-0", "clip-2", "clip-5"])
    #expect(edit.allSatisfy { ClipStage.of($0) == .edit })
    // Runway counts only clips that can become posting days (not the missing file).
    let rw = try Queue(store: f.store).runway()
    #expect(rw.totalDays == rw.approvedDays + (queued.count + 2))
    for id in ["clip-0", "clip-2", "clip-5"] {
      #expect(try f.store.events(videoId: id).contains { $0.kind == "stage" && $0.message.hasPrefix("Moved to Edit: ") })
    }
    #expect(try f.store.events(videoId: "clip-5").contains { $0.message == "Moved to Edit: Too long for X" })
    #expect(try f.store.events(videoId: "clip-0").contains { $0.message == "Moved to Edit: No crop" })
    for id in ["clip-1", "clip-3", "clip-4"] { #expect(try ClipStage.of(video(f, id)) == .queue) }
  }

  // MARK: auto-move (S1-R2)

  @Test func invalidQueueClipsMoveToEditOnTheNextTick() throws {
    let f = try Fixture.engine(6)
    try makeThreeStale(f)
    let (e, _) = engine(f)
    let r = e.tick(reason: "test")
    #expect(r.errors.isEmpty, "\(r.errors)")
    // Intake (first step) already re-derives what it touches; the "stages" step checks the rest.
    #expect(r.steps["stages"]?.hasPrefix("checked") == true, "\(r.steps["stages"] ?? "")")
    try expectThreeInEdit(f)
    // No draft day holds a clip that left the Queue.
    for s in try f.store.planSlots() { #expect(!["clip-0", "clip-2", "clip-5"].contains(s.videoId)) }
  }

  @Test func invalidQueueClipsMoveToEditAfterADjqStyleWrite() throws {
    let f = try Fixture.engine(6)
    try makeThreeStale(f)
    // Any djq write (e.g. `djq score` on another clip) runs the stage check afterwards (djq main.swift's hook).
    try f.store.setScore("clip-3", 77)
    let r = try #require(Revalidation.afterWrite(store: f.store, command: "score"))
    #expect(Set(r.movedToEdit.keys) == ["clip-0", "clip-5"])
    #expect(r.movedToEdit["clip-5"] == ["Too long for X"] && r.movedToEdit["clip-0"] == ["No crop"])
    // `djq intake` (a write) notices the missing file.
    try f.intake()
    try Revalidation(store: f.store).run()
    try expectThreeInEdit(f)
    // Valid again (limit raised, file back) → back in the Queue on the next check.
    try f.updateSettings { $0.limits[.x]?.maxDuration = 140 }
    let back = try Revalidation(store: f.store).run()
    #expect(back.movedToQueue == ["clip-5"])
    #expect(try f.store.events(videoId: "clip-5").contains { $0.message == "Moved to the Queue: nothing missing any more" })
    try f.fakeFile("Clips/\(f.sessionDir.lastPathComponent) – song2 x mix2.mp4", seed: "song2 x mix2")
    try f.intake()
    try Revalidation(store: f.store).run()
    #expect(try ClipStage.of(video(f, "clip-5")) == .queue && ClipStage.of(video(f, "clip-2")) == .queue)
    #expect(try ClipStage.of(video(f, "clip-0")) == .edit)  // its crop is still missing
  }

  @Test func appSettingsChangeMovesQueueClipsAtOnceAndUndoBringsThemBack() throws {
    let f = try Fixture.engine(6)
    let b = BulkActions(store: f.store)
    var s = try f.store.settings()
    s.limits[.x]?.maxDuration = 18.5
    let r = try b.record("settings", settings: true) { try f.store.save(s) }
    #expect(r.batchId != nil)
    #expect(try ClipStage.of(video(f, "clip-5")) == .edit && chips(f, "clip-5") == ["Too long for X"])
    _ = try b.undo(try #require(r.batchId))
    #expect(try ClipStage.of(video(f, "clip-5")) == .queue)
  }

  @Test func heldClipStaysInEditWhenItsEditIsValid() throws {
    let f = try Fixture.engine(3)
    try f.store.setHeldInEdit("clip-1", true)
    try Revalidation(store: f.store).run()
    #expect(try ClipStage.of(video(f, "clip-1")) == .edit && chips(f, "clip-1") == ["Sent back from Queue"])
    // Its own event is "Sent back to Edit from Queue", not "Moved to Edit".
    #expect(try !f.store.events(videoId: "clip-1").contains { $0.message.hasPrefix("Moved to Edit") })
  }

  // MARK: draft weeks, approval, scheduled and pinned clips

  @Test func draftDayOfAClipThatLeftTheQueueIsRefilledAndApprovalNeverSchedulesIt() throws {
    let f = try Fixture.engine(9)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)  // Mon–Sun, one a day; two clips stay in the backlog
    let mon = try #require(try f.store.planSlots(where: "date=?", ["2026-11-02"]).first)
    let tue = try #require(try f.store.planSlots(where: "date=?", ["2026-11-03"]).first)
    #expect(try ClipStage.of(video(f, mon.videoId)) == .queue)  // a proposed day still counts as Queue
    // Monday's clip goes invalid (stale); approving straight away must not schedule it.
    try clearCropStale(f, mon.videoId)
    try planner.approveWeek(f.week)
    #expect(try f.store.posts(where: "video_id=?", [mon.videoId]).isEmpty)
    #expect(try ClipStage.of(video(f, mon.videoId)) == .edit)
    let newMon = try #require(try f.store.planSlots(where: "date=?", ["2026-11-02"]).first)
    #expect(newMon.videoId != mon.videoId && !newMon.pinned)
    #expect(try ClipStage.of(video(f, newMon.videoId)) == .scheduled)
    #expect(try f.store.events(videoId: mon.videoId).contains { $0.message.hasPrefix("Removed from the draft plan") })
    _ = tue
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func approvalRechecksStatesFirstSoAStaleReadyBacklogClipIsNeverPicked() throws {
    let f = try Fixture.engine(9)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)
    let backlog = try Queue(store: f.store).ordered().map(\.id)
    #expect(backlog.count == 2)
    let mon = try #require(try f.store.planSlots(where: "date=?", ["2026-11-02"]).first)
    // Monday's clip and BOTH backlog clips go invalid behind the store's back (stored states still say Queue).
    for id in [mon.videoId] + backlog { try clearCropStale(f, id) }
    try planner.approveWeek(f.week)
    for id in [mon.videoId] + backlog {
      #expect(try f.store.posts(where: "video_id=?", [id]).isEmpty)
      #expect(try ClipStage.of(video(f, id)) == .edit)
    }
    // Monday is left open (nothing valid to refill it); the rest of the week is approved.
    #expect(try f.store.planSlots(where: "date=?", ["2026-11-02"]).isEmpty)
    #expect(try f.store.week(f.week)?.state == .approved)
  }

  @Test func approvalThatFailsLeavesTheDraftUntouched() throws {
    let f = try Fixture.engine(1)
    let planner = Planner(store: f.store)
    f.setTime("2026-11-08", "09:00")  // Sunday: one day left
    try planner.proposeWeek(f.week)
    let sun = try #require(try f.store.planSlots(where: "date=?", ["2026-11-08"]).first)
    try clearCropStale(f, sun.videoId)
    #expect(throws: EngineError.self) { try planner.approveWeek(f.week) }
    // Refused as a whole: the draft day and the stored state are as they were.
    #expect(try f.store.planSlot(id: sun.id) != nil)
    #expect(try video(f, sun.videoId).state == .ready)
  }

  @Test func makeReadyOutlookCountsUnscoredClipsAsNeedingAScore() throws {
    let o = ReadyOutlook.classify([(id: "a", issues: [], hasTitle: true, hasScore: true),
                                   (id: "b", issues: [], hasTitle: true, hasScore: false)])
    #expect(o.ready == ["a"] && o.needScore == ["b"] && o.summary == "1 to the Queue · 1 still needs a score")
  }

  @Test func revalidationRefillsADraftDay() throws {
    let f = try Fixture.engine(9)
    try Planner(store: f.store).proposeWeek(f.week)
    let wed = try #require(try f.store.planSlots(where: "date=?", ["2026-11-04"]).first)
    try clearCropStale(f, wed.videoId)
    let r = try Revalidation(store: f.store).run()
    #expect(r.movedToEdit[wed.videoId] == ["No crop"])
    #expect(r.draftSlotsRemoved.map(\.id) == [wed.id])
    let now = try #require(try f.store.planSlots(where: "date=?", ["2026-11-04"]).first)
    #expect(now.videoId != wed.videoId)
    #expect(try ClipStage.of(video(f, now.videoId)) == .queue)
  }

  @Test func scheduledAndPinnedClipsThatBecomeInvalidStayAndShowAProblem() throws {
    let f = try Fixture.engine(9)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    let thu = try #require(try f.store.planSlots(where: "date=?", ["2026-11-05"]).first)
    let postsBefore = try f.store.posts(where: "video_id=?", [thu.videoId]).count
    // A clip pinned to a day of next week's (draft) plan.
    let backlog = try Queue(store: f.store).ordered().map(\.id)
    let pinnedId = try #require(backlog.first)
    try planner.pin(videoId: pinnedId, date: "2026-11-10")
    // Both go invalid.
    try clearCropStale(f, thu.videoId)
    try clearCropStale(f, pinnedId)
    f.setTime("2026-11-02", "10:00")
    let (e, n) = engine(f, renderer: FakeRenderer(store: f.store))
    let r = e.tick(reason: "test")
    #expect(r.errors.isEmpty, "\(r.errors)")
    // Scheduled: never unscheduled silently — same slot, same posts, stage Scheduled; the engine says it can't post.
    let v = try video(f, thu.videoId)
    #expect(v.state == .planned && ClipStage.of(v) == .scheduled)
    #expect(try f.store.planSlot(id: thu.id) != nil)
    #expect(try f.store.posts(where: "video_id=?", [thu.videoId]).count == postsBefore)
    #expect(!n.titles(containing: "can't post").isEmpty)
    // Pinned: its slot stays pinned on its day, and its history says it can't post there (not "Moved to Edit").
    let pinned = try #require(try f.store.planSlots(where: "video_id=?", [pinnedId]).first)
    #expect(pinned.pinned && pinned.date == "2026-11-10")
    let pinEvents = try f.store.events(videoId: pinnedId).map(\.message)
    #expect(pinEvents.contains("Can't post on Tue 10 Nov: No crop"), "\(pinEvents)")
    #expect(!pinEvents.contains { $0.hasPrefix("Moved to Edit") })
    // Doctor reports both.
    let doc = Doctor(store: f.store).run()
    let where_ = doc.findings.first { $0.id == "plan.notReady" }?.where_ ?? []
    #expect(where_.contains { $0.contains(thu.videoId) } && where_.contains { $0.contains(pinnedId) })
  }

  @Test func missingFileOfAScheduledClipKeepsItScheduled() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let fri = try #require(try f.store.planSlots(where: "date=?", ["2026-11-06"]).first)
    try removeFile(f, fri.videoId)
    let (e, _) = engine(f)
    e.tick(reason: "test")
    let v = try video(f, fri.videoId)
    #expect(v.missing && v.state == .planned && ClipStage.of(v) == .scheduled)
    #expect(try f.store.planSlot(id: fri.id) != nil)
  }

  @Test func missingScoredClipIsInEditAndCantMoveOrBePlanned() throws {
    let f = try Fixture.engine(3)
    try removeFile(f, "clip-1")
    try f.intake()
    let v = try video(f, "clip-1")
    #expect(v.state == .missingFile && ClipStage.of(v) == .edit)
    let b = BulkActions(store: f.store)
    #expect(try b.blocker(v, .forward) == "File missing — relink it first")
    #expect(try b.blocker(v, .back) == "File missing — relink it first")
    #expect(try b.forward(["clip-1"]).changed.isEmpty)
    #expect(throws: EngineError.self) { try Planner(store: f.store).pin(videoId: "clip-1", date: "2026-11-05") }
    try Planner(store: f.store).proposeWeek(f.week)
    #expect(try f.store.planSlots(where: "video_id='clip-1'").isEmpty)
    // Unscored + missing: no stage (Library only).
    try f.store.setScore("clip-1", nil)
    try f.store.refreshState(videoId: "clip-1")
    #expect(try ClipStage.of(video(f, "clip-1")) == nil)
  }

  // MARK: stage control and wording (S1-R1/R3/R4)

  @Test func stageControlNamesTheRealNeighbour() throws {
    #expect(ClipStage.queue.backTitle == "Back to Edit")
    #expect(ClipStage.edit.backTitle == "Back to Score")
    #expect(ClipStage.scheduled.backTitle == "Back to Queue")
    #expect(ClipStage.score.backTitle == nil && ClipStage.posted.backTitle == nil)
    #expect(ClipStage.edit.forwardTitle == "Send to Queue" && ClipStage.edit.forwardTarget == .queue)
    #expect(ClipStage.queue.forwardTitle == "Schedule" && ClipStage.queue.forwardTarget == .scheduled)
    #expect(ClipStage.score.forwardTitle == "Score it")
    for st in ClipStage.allCases {
      if let t = st.backTarget { #expect(st.backTitle == "Back to \(t.displayName)") }
    }
    let f = try Fixture.engine(2, ready: 1)
    try f.store.setScore("clip-1", 40)
    try f.store.refreshState(videoId: "clip-1")
    let q = try video(f, "clip-0"), e = try video(f, "clip-1")
    #expect(StageWording.backTitle(q) == "Back to Edit" && StageWording.forwardTitle(q) == "Schedule")
    #expect(StageWording.backTitle(e) == "Back to Score" && StageWording.forwardTitle(e) == "Send to Queue")
    #expect(StageWording.backHelp(q) == StageWording.backToEditHelp)
    #expect(StageWording.backHelp(e).contains("(40)"))
    // A Queue clip never offers "Send to queue".
    #expect(!StageWording.forwardTitle(q).lowercased().contains("send to queue"))
    // The moves use the same words.
    let back = try BulkActions(store: f.store).back(["clip-0"])
    #expect(back.moves?["clip-0"]?.note.hasPrefix(StageWording.backInEdit) == true)
  }

  @Test func reasonChipsAreBucketedInChipOrder() throws {
    let tooX = ValidationIssue(kind: .tooLong, platform: .x, message: "", count: 45, limit: 30)
    let tooIG = ValidationIssue(kind: .tooLong, platform: .instagram, message: "", count: 200, limit: 180)
    let crop = ValidationIssue(kind: .noCrop, platform: nil, message: "")
    let held = ValidationIssue(kind: .heldInEdit, platform: nil, message: "")
    #expect(tooX.chipText == "Too long for X" && tooX.chipDetail == "0:45 > 0:30" && tooX.kind.chipLabel == "Too long")
    #expect(ValidationIssue.buckets([tooX, crop, tooIG, held]) == [.heldInEdit, .noCrop, .tooLong])
    let counts = ValidationIssue.bucketCounts(["a": [tooX, tooIG], "b": [crop, tooX], "c": []])
    #expect(counts.map(\.kind) == [.noCrop, .tooLong] && counts.map(\.count) == [1, 2])
    #expect(StageWording.reasonsText([tooX, crop]) == "No crop · Too long for X")
    #expect(ValidationIssue.Kind.inChipOrder.count == 11)
    for k in ValidationIssue.Kind.inChipOrder { #expect(!k.chipLabel.isEmpty && !k.chipHelp.isEmpty) }
  }

  @Test func noClipReadinessTextSaysReadyNeedsEditOrUnready() throws {
    var texts: [String] = []
    texts += VideoState.allCases.map(\.displayName)
    texts += PostState.allCases.map(\.displayName)
    texts += ClipStage.allCases.flatMap { [$0.displayName, $0.backTitle, $0.forwardTitle, $0.backHelp(score: 42), $0.forwardHelp].compactMap { $0 } }
    texts += ValidationIssue.Kind.inChipOrder.flatMap { [$0.chipLabel, $0.chipHelp] }
    texts += [StageWording.backToEditHelp, StageWording.sentToQueue, StageWording.backInEdit, StageWording.fileMissing,
              ReadyOutlook(ready: ["a"], needTitle: ["b"], other: ["c"]).summary]
    texts += PostState.allCases.map { s in
      PostGrouping.bucket(PlatformPost(id: "p", videoId: "v", platform: .x, versionNo: 1, attemptNo: 1, kind: .regular,
                                       planSlotId: nil, scheduledAt: Date(), renderId: nil, state: s, publisher: "manual",
                                       externalId: nil, url: nil, postedAt: nil, errorType: nil, errorMessage: nil,
                                       rawResponse: nil, resolution: nil, metrics: nil, createdAt: Date(), updatedAt: Date()))
    }
    let banned = try Regex("(?i)\\b(un)?ready\\b|needs? edit")
    for t in texts { #expect(t.firstMatch(of: banned) == nil, "\(t)") }
    #expect(VideoState.needsEdit.displayName == "In Edit" && VideoState.ready.displayName == "In Queue")
    #expect(PostState.rendered.displayName == "Rendered")
  }

  @Test func videosJSONCarriesStageAndReasons() throws {
    let f = try Fixture.engine(3)
    try f.store.save(Edit(), videoId: "clip-2")  // crop cleared → Edit
    let list = try AgentAPI.videos(store: f.store)
    let c2 = try #require(list.first { $0.id == "clip-2" })
    #expect(c2.stage == "edit" && c2.reasons == ["No crop"] && c2.state == "needs_edit")
    #expect(list.first { $0.id == "clip-0" }?.stage == "queue")
    #expect(list.first { $0.id == "long-0001" }?.stage == nil)
    #expect(try AgentAPI.videos(store: f.store, stage: .edit).map(\.id) == ["clip-2"])
  }

  @Test func revalidationIsCheapForHundredsOfClips() throws {
    let clips = (0..<200).map { (tag: "s\($0) x m\($0)", duration: 20.0) }
    let f = try Fixture(clips: clips, longform: false)
    try f.intake()
    for i in 0..<200 { try f.makeReady("clip-\(i)", score: 50) }
    // This thread's CPU time, not wall time: the update gate runs tests while the Mac is busy, and a wall clock then
    // measures the load (5.06 s here on 2026-11-05 with the Mac busy), not the work.
    let t0 = threadCPUSeconds()
    let r = try Revalidation(store: f.store).run()
    let dt = threadCPUSeconds() - t0
    #expect(r.checked == 200 && r.movedToEdit.isEmpty)
    #expect(dt < 5, "revalidation of 200 clips took \(dt) s")
  }
}
