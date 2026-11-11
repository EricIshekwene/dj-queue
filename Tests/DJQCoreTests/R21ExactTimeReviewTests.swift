import Foundation
import Testing
@testable import DJQCore

/// Round 21, the fixes from the two reviews of "Post at a set time": a day shared through a per-platform sort is refused
/// (M1), a retry on its way (M2), a Postiz copy about to go out (M3) and its undo (N2), push and retries (m1), one
/// channel and one minute (m2), the unchanged time inside the lead (m3), the hour the clocks skip (m4) and the retry
/// "Use the regular schedule" leaves (N4).
@Suite struct R21ExactTimeReviewTests {
  typealias R = ExactRig
  typealias Rig = R6PostizLifecycleTests.Rig

  func slot(_ f: Fixture, _ video: String) throws -> PlanSlot { try #require(try f.store.planSlots(where: "video_id=?", [video]).first) }

  // MARK: M1 — a per-platform sort (second review: refused, nothing detached or guessed)

  /// TikTok runs best first, four clips scheduled Monday to Thursday: clip-0's Monday card carries clip-3's TikTok post,
  /// and clip-0's own TikTok post sits on clip-3's Thursday card.
  func shared() throws -> (Fixture, mine: PlatformPost, theirs: PlatformPost) {
    let f = try Fixture.engine(5, ready: 4)
    try f.updateSettings { $0.sortOverrides[.tiktok] = .bestFirst }
    try Planner(store: f.store).autoSchedule()
    let mine = try #require(try f.store.posts(where: "video_id='clip-0' AND platform='tiktok'").first)
    let theirs = try #require(try f.store.posts(where: "video_id='clip-3' AND platform='tiktok'").first)
    #expect(try theirs.planSlotId == slot(f, "clip-0").id && mine.planSlotId == slot(f, "clip-3").id)
    return (f, mine, theirs)
  }

  static let sharedWords = "TikTok has its own order, so this day is shared with another clip. Send it back to Edit, then set the time."

  /// Refused by every door, and the plan is exactly as it was.
  func expectRefused(_ f: Fixture, _ id: String, _ c: SourceLocation = #_sourceLocation) throws {
    let plan = try R.plan(f), events = try f.store.events().count
    let at = f.at("2026-11-14", "15:15")
    let planner = Planner(store: f.store), bulk = BulkActions(store: f.store)
    #expect(throws: EngineError(Self.sharedWords), sourceLocation: c) { try planner.postAt(videoId: id, at: at) }
    #expect(try planner.postAtPreview(videoId: id, at: at).blocker == Self.sharedWords, sourceLocation: c)
    #expect(try bulk.postAtPreview(id, at: at).blocker == Self.sharedWords, sourceLocation: c)
    let r = try bulk.postAt([id], at: at)
    #expect(r.changed.isEmpty && r.batchId == nil && r.skipped[id] == Self.sharedWords, sourceLocation: c)
    #expect(try R.plan(f) == plan && f.store.events().count == events && R.cardless(f).isEmpty, sourceLocation: c)
  }

  @Test func aScheduledItemOnASharedDayIsRefusedAndNothingChanges() throws {
    let (f, _, _) = try shared()
    try expectRefused(f, "clip-0")
    try expectRefused(f, "clip-3")
  }

  @Test func anotherClipsPostOnItsCardAloneRefusesIt() throws {
    let (f, mine, theirs) = try shared()
    try PostActions(store: f.store).skip(postId: mine.id)  // its own TikTok post is done with; clip-3's is still on its card
    #expect(try f.store.post(id: theirs.id)?.state.isTerminal == false)
    try expectRefused(f, "clip-0")
  }

  @Test func itsOwnPostOnAnotherClipsCardAloneRefusesIt() throws {
    let (f, mine, theirs) = try shared()
    try PostActions(store: f.store).skip(postId: theirs.id)  // nothing live of another clip on its card any more
    #expect(try f.store.post(id: mine.id)?.state.isTerminal == false)
    try expectRefused(f, "clip-0")
  }

  @Test func backToEditIsTheWayOutAndAQueueItemTakesASetTimeAsBefore() throws {
    let (f, _, _) = try shared()
    let bulk = BulkActions(store: f.store)
    let at = f.at("2026-11-14", "15:15")
    // The way the blocker names: Back to Edit takes the day off (as it always did), then the time can be set.
    #expect(try bulk.back(["clip-0"]).changed == ["clip-0"])
    let r = try bulk.postAt(["clip-0"], at: at)
    #expect(r.changed == ["clip-0"] && r.moves?["clip-0"]?.from == .edit)
    let own = try f.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }
    #expect(own.count == 6 && Set(own.map(\.platform)).count == 6 && own.allSatisfy { $0.scheduledAt == at })
    // An item still in the Queue has no card: its own clip on every platform, no picker.
    try f.makeReady("clip-4", score: 50)
    let slot = try Planner(store: f.store).postAt(videoId: "clip-4", at: at)
    let queued = try f.store.posts(where: "plan_slot_id=?", [slot.id])
    #expect(queued.count == 6 && queued.allSatisfy { $0.videoId == "clip-4" && $0.scheduledAt == at })
    // And a set time never carries another clip's post, so changing or clearing it isn't touched by the rule.
    try Planner(store: f.store).autoSchedule()
    #expect(try bulk.postAt(["clip-4"], at: f.at("2026-11-15", "15:15")).changed == ["clip-4"])
    #expect(try bulk.clearExact(["clip-4"]).changed == ["clip-4"])
    #expect(try R.cardless(f).isEmpty && R.twice(f).isEmpty)
  }

  @Test func aScheduledClipWithNoSharedCardStillTakesASetTime() throws {
    let f = try Fixture.engine(4)
    try f.updateSettings { $0.sortOverrides[.tiktok] = .worstFirst }  // an override equal to the main order shares nothing
    try Planner(store: f.store).autoSchedule()
    let at = f.at("2026-11-14", "15:15")
    #expect(try BulkActions(store: f.store).postAt(["clip-1"], at: at).changed == ["clip-1"])
    #expect(try f.store.posts(where: "video_id='clip-1'").count == 6 && f.store.posts(where: "video_id='clip-1'").allSatisfy { $0.scheduledAt == at })
    #expect(try R.cardless(f).isEmpty)
  }

  // MARK: M2 — a retry on its way

  @Test func aRetryOnItsWayMovesToTheNewTimeAsTheSamePost() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let actions = PostActions(store: f.store)
    let first = f.at("2026-11-06", "10:00")
    try planner.postAt(videoId: "clip-0", at: first)
    let tt = try #require(try f.store.posts(where: "platform='tiktok'").first)
    try actions.reportProblem(postId: tt.id, type: .other, message: "upload failed")
    let retry = try actions.fixed(postId: tt.id)
    #expect(retry.kind == .retry && retry.scheduledAt == first)
    let to = f.at("2026-11-09", "12:00")
    let preview = try planner.postAtPreview(videoId: "clip-0", at: to)
    #expect(preview.platforms.count == 6 && preview.skipped.isEmpty)
    #expect(preview.platforms.first { $0.platform == .tiktok } == .init(platform: .tiktok, at: to, moved: false, retry: true))
    let slot = try planner.postAt(videoId: "clip-0", at: to)
    let live = try f.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }
    #expect(live.count == 6 && Set(live.map(\.platform)).count == 6 && live.allSatisfy { $0.scheduledAt == to && $0.planSlotId == slot.id })
    let moved = try #require(try f.store.post(id: retry.id))
    #expect(moved.kind == .retry && moved.scheduledAt == to && moved.attemptNo == retry.attemptNo)  // the same post, the same lineage
    #expect(try f.store.posts(where: "video_id='clip-0' AND platform='tiktok'").count == 2)  // the failure and its one attempt
    // A move to another day carries it too; the regular schedule leaves it be, at its own time.
    try planner.move(slotId: slot.id, to: "2026-11-10")
    #expect(try f.store.post(id: retry.id)?.scheduledAt == f.at("2026-11-10", "12:00"))
    #expect(try f.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }.allSatisfy { $0.scheduledAt == f.at("2026-11-10", "12:00") })
    // "Use the regular schedule" says so: in the dry run, in the note, and the retry is still there afterwards.
    let bulk = BulkActions(store: f.store)
    let words = "Back on the regular schedule · TikTok's retry still goes out Tue 10 Nov 12:00 PM"
    #expect(try bulk.clearExact(["clip-0"], dryRun: true).moves?["clip-0"]?.note == words)
    #expect(try bulk.clearExact(["clip-0"]).moves?["clip-0"]?.note == words)
    let left = try #require(try f.store.post(id: retry.id))
    #expect(left.state == .planned && left.scheduledAt == f.at("2026-11-10", "12:00") && left.planSlotId == nil)
    #expect(try R.cardless(f).isEmpty)  // a retry is no regular post; every live regular post has its card
    // With nothing left over the note is the plain one.
    try planner.postAt(videoId: "clip-1", at: to)
    #expect(try bulk.clearExact(["clip-1"]).moves?["clip-1"]?.note == "Back on the regular schedule")
  }

  /// The reviewer's case: TikTok failed in Postiz and its automatic retry is queued when Eric picks a new time.
  @Test func anAutomaticRetryQueuedInPostizFollowsTheNewTime() throws {
    let rig = try Rig(1, platforms: [.tiktok], approve: false)
    let bulk = BulkActions(store: rig.store)
    try bulk.postAt(["clip-0"], at: rig.f.at("2026-11-03", "22:00"))
    rig.settle()
    let tt = try #require(try rig.store.posts(where: "platform='tiktok'").first)
    let job = try #require(try rig.job(tt))
    rig.fake.fail(job.postizId!, error: "Something went wrong")
    rig.f.clock.set(job.remoteDate.addingTimeInterval(60))
    rig.tick()
    let attempt = try #require(try rig.store.posts(where: "platform='tiktok' AND kind='retry'").first)
    #expect(try !attempt.state.isTerminal && rig.store.post(id: tt.id)?.resolution == "retried")
    let to = rig.f.at("2026-11-05", "10:00")
    let r = try bulk.postAt(["clip-0"], at: to)
    #expect(r.changed == ["clip-0"])
    let slot = try #require(try Planner(store: rig.store).exactSlot(videoId: "clip-0"))
    let live = try rig.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }
    #expect(live.count == 6 && Set(live.map(\.platform)).count == 6 && live.allSatisfy { $0.scheduledAt == to && $0.planSlotId == slot.id })
    #expect(try rig.store.post(id: attempt.id)?.scheduledAt == to)  // never "retried" with nothing coming
    #expect(try rig.store.autoRetries(attempt).nextRetryAt == to)
    rig.f.clock.advance(600)
    rig.settle()
    // Postiz holds exactly one TikTok copy of it, at the new time.
    let copies = rig.fake.livePosts.filter { $0.integrationId == "ch-tiktok" && ["QUEUE", "DRAFT"].contains($0.state) }
    #expect(copies.map(\.date) == [to])
    #expect(try rig.invariants().isEmpty)
    #expect(try rig.service.isRetryAttempt(try #require(try rig.store.post(id: attempt.id))))
  }

  @Test func aFailureWhoseRetryIsStillToBeMadeGetsItForTheSetTime() throws {
    let rig = try Rig(1, platforms: [.tiktok], approve: false)
    let bulk = BulkActions(store: rig.store)
    try bulk.postAt(["clip-0"], at: rig.f.at("2026-11-03", "22:00"))
    rig.settle()
    let tt = try #require(try rig.store.posts(where: "platform='tiktok'").first)
    let job = try #require(try rig.job(tt))
    rig.fake.fail(job.postizId!, error: "Something went wrong")
    rig.f.clock.set(job.remoteDate.addingTimeInterval(60))
    try rig.f.updateSettings { $0.paused = true }  // the failure is read, the attempt waits
    rig.tick(3)
    #expect(try rig.store.posts(where: "platform='tiktok'").count == 1 && rig.store.retryIsComing(try #require(try rig.store.post(id: tt.id))))
    let to = rig.f.at("2026-11-05", "10:00")
    let preview = try bulk.postAtPreview("clip-0", at: to)
    #expect(preview.blocker == nil && preview.platforms.count == 5)
    #expect(preview.skipped == [.init(platform: .tiktok, reason: .retrying, why: "TikTok failed and retries by itself, around the set time")])
    #expect(try bulk.postAt(["clip-0"], at: to).changed == ["clip-0"])
    let slot = try #require(try Planner(store: rig.store).exactSlot(videoId: "clip-0"))
    let failed = try #require(try rig.store.post(id: tt.id))
    #expect(try failed.resolution == nil && rig.store.retryIsComing(failed) && failed.planSlotId == slot.id)  // still promised
    #expect(try rig.store.autoRetries(failed).nextRetryAt == to)
    try rig.f.updateSettings { $0.paused = false }
    rig.tick(3)
    let attempt = try #require(try rig.store.posts(where: "platform='tiktok' AND kind='retry'").first)
    #expect(attempt.scheduledAt == to && attempt.planSlotId == slot.id && !attempt.state.isTerminal)
    #expect(try rig.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }.allSatisfy { $0.scheduledAt == to })
    #expect(try rig.invariants().isEmpty)
  }

  // MARK: M3 — a Postiz copy about to go out

  @Test func aCopyPostizSendsWithinTenMinutesRefusesANewTime() throws {
    let rig = try Rig(2, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()  // clip-0 is on Monday; Facebook 12:30 pm is in Postiz
    let planner = Planner(store: rig.store)
    let bulk = BulkActions(store: rig.store)
    let at = rig.f.at("2026-11-06", "15:15")  // inside the render horizon, so Postiz gets the new copies at once
    rig.f.setTime("2026-11-02", "12:27")
    let plan = try R.plan(rig.f)
    let refusal = "Facebook goes out in 3 minutes — too late to change"
    #expect(throws: EngineError(refusal)) { try planner.postAt(videoId: "clip-0", at: at) }
    #expect(try planner.postAtPreview(videoId: "clip-0", at: at).blocker == refusal)
    #expect(try bulk.postAt(["clip-0"], at: at).skipped["clip-0"] == refusal)
    #expect(try R.plan(rig.f) == plan)
    rig.f.setTime("2026-11-02", "12:31")
    #expect(try planner.postAtPreview(videoId: "clip-0", at: at).blocker == "Facebook is going out now — too late to change")
    #expect(try R.plan(rig.f) == plan)
    // With more than ten minutes to go Postiz can still take it back: every copy follows the new time.
    let other = try Rig(2, approve: false)
    other.engine.autoSchedules = true
    other.settle()
    other.f.setTime("2026-11-02", "12:15")
    #expect(try BulkActions(store: other.store).postAt(["clip-0"], at: at).changed == ["clip-0"])
    other.settle()
    let copies = try R21ExactTimePostizTests().dates(other, "clip-0")
    #expect(copies.count == 6 && copies.values.allSatisfy { $0 == at })
    #expect(try other.invariants().isEmpty)
  }

  @Test func clearingOrMovingASetTimeAboutToGoOutIsRefusedToo() throws {
    let rig = try Rig(2, approve: false)
    let planner = Planner(store: rig.store)
    let bulk = BulkActions(store: rig.store)
    let slot = try planner.postAt(videoId: "clip-1", at: rig.f.at("2026-11-02", "12:30"))
    rig.settle()
    rig.f.setTime("2026-11-02", "12:22")
    let plan = try R.plan(rig.f)
    func refused(_ body: () throws -> Void) -> Bool { R.message(body)?.hasSuffix("goes out in 8 minutes — too late to change") == true }
    #expect(refused { try planner.clearExact(videoId: "clip-1") })
    #expect(refused { try planner.move(slotId: slot.id, to: "2026-11-03") })
    #expect(refused { try planner.pin(videoId: "clip-1", date: "2026-11-03") })
    #expect(refused { try planner.postAt(videoId: "clip-1", at: rig.f.at("2026-11-03", "12:30")) })
    #expect(try bulk.clearExact(["clip-1"]).skipped["clip-1"]?.hasSuffix("too late to change") == true)
    #expect(try R.plan(rig.f) == plan)
    // A post Postiz doesn't hold can always change: the same minute on Manual.
    let manual = try Fixture.engine(1)
    try Planner(store: manual.store).postAt(videoId: "clip-0", at: manual.at("2026-11-02", "12:30"))
    manual.setTime("2026-11-02", "12:22")
    try Planner(store: manual.store).clearExact(videoId: "clip-0")
    #expect(try manual.store.planSlots().isEmpty)
  }

  // MARK: N2 — undo in the last minutes

  @Test func undoIsRefusedWhilePostizSendsTheSetTimeWithinTenMinutes() throws {
    let rig = try Rig(2, approve: false)
    rig.engine.autoSchedules = true
    rig.settle()  // clip-0 has Monday on the regular schedule
    let bulk = BulkActions(store: rig.store)
    let at = rig.f.at("2026-11-02", "09:20")
    let set = try bulk.postAt(["clip-0"], at: at)
    rig.settle()
    #expect(try R21ExactTimePostizTests().dates(rig, "clip-0").values.allSatisfy { $0 == at })
    rig.f.setTime("2026-11-02", "09:17")
    let plan = try R.plan(rig.f)
    let batch = try #require(set.batchId)
    #expect(R.message { try bulk.undo(batch) }?.hasSuffix("goes out in 3 minutes — too late to undo") == true)
    #expect(R.message { try bulk.undo(batch, force: true) }?.hasSuffix("too late to undo") == true)  // force can't call it back either
    #expect(try R.plan(rig.f) == plan && bulk.batch(id: batch)?.undoneAt == nil)
    // With more than ten minutes to go the undo goes through and Postiz follows.
    let early = try Rig(2, approve: false)
    early.engine.autoSchedules = true
    early.settle()
    let regular = try R.plan(early.f)
    let b = BulkActions(store: early.store)
    let made = try b.postAt(["clip-0"], at: early.f.at("2026-11-02", "09:20"))
    early.settle()
    early.f.setTime("2026-11-02", "09:05")
    try b.undo(try #require(made.batchId))
    #expect(try R.plan(early.f) == regular)
    early.settle()
    #expect(try R21ExactTimePostizTests().dates(early, "clip-0")["ch-facebook"] == early.f.at("2026-11-02", "12:30"))
    #expect(try early.invariants().isEmpty && R.cardless(early.f).isEmpty)
  }

  // MARK: m1 — push and Post today

  @Test func pushAndPostTodayLeaveASetTimeItemsRetryAtTheSetTime() throws {
    let f = try Fixture.engine(5, ready: 4)
    let planner = Planner(store: f.store)
    let actions = PostActions(store: f.store)
    let at = f.at("2026-11-06", "10:00")
    try planner.postAt(videoId: "clip-0", at: at)
    try planner.autoSchedule()
    let tt = try #require(try f.store.posts(where: "video_id='clip-0' AND platform='tiktok'").first)
    try actions.reportProblem(postId: tt.id, type: .other, message: "upload failed")
    let retry = try actions.fixed(postId: tt.id)
    #expect(retry.scheduledAt == at && retry.planSlotId == tt.planSlotId)
    try planner.pushPlan(from: "2026-11-02", days: 1)
    #expect(try f.store.post(id: retry.id)?.scheduledAt == at)
    try f.makeReady("clip-4", score: 50)
    try planner.postToday(videoId: "clip-4")  // pushes the regular days once more
    #expect(try f.store.post(id: retry.id)?.scheduledAt == at)
    #expect(try f.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }.allSatisfy { $0.scheduledAt == at })
  }

  // MARK: m2 — one channel, one minute

  @Test func thePreviewSaysWhenPostizSendsItAMinuteLater() throws {
    let rig = try Rig(3, approve: false)
    let bulk = BulkActions(store: rig.store)
    let at = rig.f.at("2026-11-04", "12:00")
    try bulk.postAt(["clip-0"], at: at)
    // Neither is in Postiz yet: one of the two moves, and it can't be known which.
    var notes = try bulk.postAtPreview("clip-1", at: at).notes
    #expect(notes.count == 6 && notes.contains("TikTok: another post has 12:00 PM, so one of the two goes out a minute later"))
    rig.settle()
    // The first one is in Postiz on that minute: the second goes at 12:01 on every channel.
    notes = try bulk.postAtPreview("clip-1", at: at).notes
    #expect(notes.count == 6 && notes.contains("TikTok goes out at 12:01 PM: another post has 12:00 PM"))
    try bulk.postAt(["clip-1"], at: at)
    rig.settle()
    let copies = try R21ExactTimePostizTests().dates(rig, "clip-1")
    #expect(copies.count == 6 && copies.values.allSatisfy { $0 == at.addingTimeInterval(60) })
    #expect(try bulk.postAtPreview("clip-2", at: rig.f.at("2026-11-04", "12:30")).notes.isEmpty)
    #expect(try rig.invariants().isEmpty)
    // On Manual nothing moves and nothing is said.
    let f = try Fixture.engine(2)
    try Planner(store: f.store).postAt(videoId: "clip-0", at: at)
    #expect(try Planner(store: f.store).postAtPreview(videoId: "clip-1", at: at).notes.isEmpty)
  }

  // MARK: m3 — the time it already has

  @Test func theBatchLeavesTheTimeItAlreadyHasAloneInsideTheLead() throws {
    let f = try Fixture.engine(2)
    let bulk = BulkActions(store: f.store)
    let at = f.at("2026-11-02", "10:00")
    try bulk.postAt(["clip-0"], at: at)
    f.setTime("2026-11-02", "09:55")
    let face = try R.plan(f)
    let r = try bulk.postAt(["clip-0"], at: at)
    #expect(r.changed.isEmpty && r.skipped.isEmpty && r.batchId == nil)
    #expect(try bulk.postAtPreview("clip-0", at: at).unchanged)
    #expect(try R.plan(f) == face)
    // Anything that would change still fails at once.
    #expect(throws: EngineError(StageWording.setTimeTooSoon)) { try bulk.postAt(["clip-0", "clip-1"], at: at) }
    #expect(throws: EngineError(StageWording.setTimeTooSoon)) { try bulk.postAt(["clip-1"], at: at) }
    #expect(StageWording.setTimeTooSoon == "Pick a time at least 10 minutes from now")
  }

  // MARK: m4 — the hour the clocks skip

  @Test func aTimeTheClocksSkipIsRefused() throws {
    let s = Settings()
    let words = "2:30 AM doesn't exist on Sun 14 Mar: the clocks go forward that night"
    #expect(throws: EngineError(words)) { try Planner.parseExact("2027-03-14 02:30", settings: s) }
    #expect(throws: EngineError.self) { try Planner.parseExact("2027-03-14 02:00", settings: s) }
    #expect(try Planner.parseExact("2027-03-14 01:59", settings: s) == R.utc("2027-03-14", 6, 59))
    #expect(try Planner.parseExact("2027-03-14 03:00", settings: s) == R.utc("2027-03-14", 7))
    #expect(try Planner.parseExact("2026-11-01 01:30", settings: s) == R.utc("2026-11-01", 5, 30))  // the hour that comes twice: the first
    // A move onto that night is refused rather than drifting to 3:30 for good.
    let f = try Fixture.engine(1)
    let planner = Planner(store: f.store)
    let made = try planner.postAt(videoId: "clip-0", at: f.at("2027-03-13", "02:30"))
    #expect(throws: EngineError(words)) { try planner.move(slotId: made.id, to: "2027-03-14") }
    #expect(try slot(f, "clip-0") == made)
    try planner.move(slotId: made.id, to: "2027-03-15")
    #expect(try slot(f, "clip-0").exactAt == f.at("2027-03-15", "02:30"))
  }
}
