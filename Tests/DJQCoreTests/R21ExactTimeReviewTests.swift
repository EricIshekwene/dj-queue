import Foundation
import Testing
@testable import DJQCore

/// Round 21, the fixes from the review of "Post at a set time": a per-platform sort (M1), a retry on its way (M2), a
/// Postiz copy about to go out (M3), push and retries (m1), one channel and one minute (m2), the unchanged time inside
/// the lead (m3) and the hour the clocks skip (m4).
@Suite struct R21ExactTimeReviewTests {
  typealias R = ExactRig
  typealias Rig = R6PostizLifecycleTests.Rig

  /// Every post that isn't one of `videos`': id → "clip platform time state". The card it sits on is left out.
  func times(_ f: Fixture, except videos: String...) throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try f.store.posts().filter { !videos.contains($0.videoId) }.map {
      ($0.id, "\($0.videoId) \($0.platform.rawValue) \($0.scheduledAt.timeIntervalSince1970) \($0.state.rawValue)")
    })
  }

  /// Live regular posts that share a platform and a minute.
  func sameMinute(_ f: Fixture) throws -> [String] {
    var seen = Set<String>()
    return try f.store.posts(where: "kind='regular'").filter { !$0.state.isTerminal }
      .map { "\($0.platform.rawValue) \(Int($0.scheduledAt.timeIntervalSince1970 / 60))" }.filter { !seen.insert($0).inserted }
  }

  func slot(_ f: Fixture, _ video: String) throws -> PlanSlot { try #require(try f.store.planSlots(where: "video_id=?", [video]).first) }

  // MARK: M1 — a per-platform sort

  @Test func withAPerPlatformSortEveryPlatformGoesToTheSetTimeAndNoOtherClipLosesAPost() throws {
    let f = try Fixture.engine(5, ready: 4)
    try f.updateSettings { $0.sortOverrides[.tiktok] = .bestFirst }
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    // TikTok runs best first: clip-0's TikTok post sits on clip-3's Thursday card, and clip-3's on clip-0's Monday card.
    let mine = try #require(try f.store.posts(where: "video_id='clip-0' AND platform='tiktok'").first)
    let theirs = try #require(try f.store.posts(where: "video_id='clip-3' AND platform='tiktok'").first)
    #expect(mine.scheduledAt == f.at("2026-11-05", "19:00") && theirs.scheduledAt == f.at("2026-11-02", "19:00"))
    #expect(try theirs.planSlotId == slot(f, "clip-0").id && mine.planSlotId == slot(f, "clip-3").id)
    let before = try times(f, except: "clip-0")
    let at = f.at("2026-11-14", "15:15")
    let preview = try planner.postAtPreview(videoId: "clip-0", at: at)
    #expect(preview.platforms.count == 6 && preview.skipped.isEmpty && preview.blocker == nil)
    let set = try planner.postAt(videoId: "clip-0", at: at)
    // Six posts at the set time, all its own.
    let own = try f.store.posts(where: "video_id='clip-0'")
    #expect(own.count == 6 && Set(own.map(\.platform)).count == 6)
    #expect(own.allSatisfy { $0.scheduledAt == at && $0.planSlotId == set.id && $0.state == .planned })
    #expect(try f.store.posts(where: "plan_slot_id=?", [set.id]).allSatisfy { $0.videoId == "clip-0" })
    // No other clip lost or moved a post: clip-3's TikTok is the same post at the same time, off the card that left.
    #expect(try times(f, except: "clip-0") == before)
    #expect(try f.store.post(id: theirs.id)?.planSlotId == nil)
    #expect(try f.store.video(id: "clip-3")?.state == .planned)
    // It still holds TikTok's Monday; the place clip-0's TikTok left on Thursday is free.
    let placer = try Placer(store: f.store, dm: f.dm)
    #expect(placer.isTaken(.tiktok, day: "2026-11-02", position: 0) && !placer.isTaken(.tiktok, day: "2026-11-05", position: 0))
    // The open Monday is filled from the Queue; its TikTok goes to the free Thursday, never onto Monday's minute.
    #expect(try planner.autoSchedule().scheduled == 0)
    try f.makeReady("clip-4", score: 50)
    #expect(try planner.autoSchedule().scheduled == 1)
    #expect(try slot(f, "clip-4").date == "2026-11-02")
    #expect(try f.post(.tiktok, day: "2026-11-05", video: "clip-4") != nil)
    #expect(try times(f, except: "clip-0", "clip-4") == before)
    #expect(try sameMinute(f).isEmpty && R.twice(f).isEmpty)
  }

  @Test func aPostThatLostItsCardKeepsItsPositionWithTwoADay() throws {
    let f = try Fixture.engine(4)
    try f.updateSettings { $0.postsPerDay = 2; $0.sortOverrides[.tiktok] = .bestFirst }
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    // clip-1's card (Monday, second place) holds clip-2's TikTok at 10 pm; clip-1's own TikTok is on clip-2's card.
    let theirs = try #require(try f.store.posts(where: "video_id='clip-2' AND platform='tiktok'").first)
    #expect(try theirs.scheduledAt == f.at("2026-11-02", "22:00") && theirs.planSlotId == slot(f, "clip-1").id)
    let before = try times(f, except: "clip-1")
    let at = f.at("2026-11-14", "15:15")
    try planner.postAt(videoId: "clip-1", at: at)
    #expect(try f.store.posts(where: "video_id='clip-1'").count == 6)
    #expect(try f.store.posts(where: "video_id='clip-1'").allSatisfy { $0.scheduledAt == at })
    #expect(try times(f, except: "clip-1") == before)
    let kept = try #require(try f.store.post(id: theirs.id))
    #expect(try kept.planSlotId == nil && f.store.position(of: kept) == 1 && f.store.planDay(of: kept, dm: f.dm) == "2026-11-02")
    let placer = try Placer(store: f.store, dm: f.dm)
    #expect(placer.isTaken(.tiktok, day: "2026-11-02", position: 1) && placer.isTaken(.tiktok, day: "2026-11-02", position: 0))
    #expect(!placer.isTaken(.tiktok, day: "2026-11-03", position: 0))  // where clip-1's TikTok was
    // A slot-time change still finds it at its position.
    try PostActions(store: f.store).setSlot(.tiktok, minutes: 18 * 60)
    #expect(try f.store.post(id: theirs.id)?.scheduledAt == f.at("2026-11-02", "21:00"))
    #expect(try sameMinute(f).isEmpty && R.twice(f).isEmpty)
  }

  @Test func undoPutsTheOtherClipsPostBackOnItsCard() throws {
    let f = try Fixture.engine(4)
    try f.updateSettings { $0.sortOverrides[.tiktok] = .bestFirst }
    try Planner(store: f.store).autoSchedule()
    let plan = try R.plan(f)
    let bulk = BulkActions(store: f.store)
    let r = try bulk.postAt(["clip-0"], at: f.at("2026-11-14", "15:15"))
    #expect(r.changed == ["clip-0"])
    try bulk.undo(try #require(r.batchId))
    #expect(try R.plan(f) == plan)
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
    try planner.clearExact(videoId: "clip-0")
    let left = try #require(try f.store.post(id: retry.id))
    #expect(left.state == .planned && left.scheduledAt == f.at("2026-11-10", "12:00") && left.planSlotId == nil)
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
