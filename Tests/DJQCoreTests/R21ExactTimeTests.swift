import Foundation
import Testing
@testable import DJQCore

/// What the round 21 set-time tests share.
enum ExactRig {
  static func utc(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    let p = day.split(separator: "-").compactMap { Int($0) }
    return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour, minute: minute))!
  }

  /// "2026-11-02#0 clip-0", in calendar order.
  static func layout(_ f: Fixture) throws -> [String] {
    try f.store.planSlots().sorted { ($0.date, $0.position) < ($1.date, $1.position) }.map { "\($0.date)#\($0.position) \($0.videoId)" }
  }

  /// Every post that isn't one of `videos`': id → "platform time state slot". Equal before and after = nothing else moved.
  static func others(_ f: Fixture, except videos: String...) throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try f.store.posts().filter { !videos.contains($0.videoId) }.map {
      ($0.id, "\($0.videoId) \($0.platform.rawValue) \($0.scheduledAt.timeIntervalSince1970) \($0.state.rawValue) \($0.planSlotId ?? "-")")
    })
  }

  /// The whole plan without `updatedAt` (a restored post is saved again): slots, weeks, posts.
  static func plan(_ f: Fixture) throws -> [String] {
    let s = try BulkActions(store: f.store).planSnapshot()
    return s.slots.map { "slot \($0.id) \($0.date)#\($0.position) \($0.videoId) \($0.pinned) \($0.weekStart) \($0.exactAt?.timeIntervalSince1970 ?? -1)" }
      + s.weeks.map { "week \($0.weekStart) \($0.state.rawValue)" }
      + s.posts.map { "post \($0.id) \($0.videoId) \($0.platform.rawValue) \($0.kind.rawValue) \($0.state.rawValue) \($0.scheduledAt.timeIntervalSince1970) \($0.planSlotId ?? "-") #\($0.attemptNo)" }
  }

  /// No clip has two live regular posts on one platform.
  static func twice(_ f: Fixture) throws -> [String] {
    var seen = Set<String>()
    return try f.store.posts(where: "kind='regular'").filter { !$0.state.isTerminal }
      .filter { !seen.insert("\($0.videoId)#\($0.platform.rawValue)").inserted }.map { "\($0.videoId) twice on \($0.platform.rawValue)" }
  }

  static func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return "\(error)" }
  }

  /// Nothing to fix, scored, never sent: an item waiting in Edit.
  static func unsent(_ f: Fixture, _ id: String, score: Int = 50) throws {
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
}

/// Round 21 (D12–D14): `Planner.postAt`, `clearExact`, the preview, the journaled batches and `djq post-at`.
/// The clock stands Monday 2026-11-02 09:00 New York; clip-0 is first in the Queue.
@Suite struct R21ExactTimeTests {
  typealias R = ExactRig

  // MARK: postAt

  @Test func aQueueClipGoesOutOnEveryPlatformAtThatMinute() throws {
    let f = try Fixture.engine(3)
    let at = f.at("2026-11-14", "15:15")
    let slot = try Planner(store: f.store).postAt(videoId: "clip-1", at: at.addingTimeInterval(42))  // seconds don't count
    #expect(slot.exactAt == at && slot.isExact && slot.pinned && slot.date == "2026-11-14" && slot.position == PlanSlot.exactBase)
    #expect(try slot.weekStart == "2026-11-09" && f.store.week("2026-11-09")?.state == .approved)
    let posts = try f.store.posts()
    #expect(posts.count == 6 && Set(posts.map(\.platform)) == Set(Platform.allCases))
    #expect(posts.allSatisfy { $0.scheduledAt == at && $0.planSlotId == slot.id && $0.kind == .regular && $0.state == .planned && $0.videoId == "clip-1" })
    #expect(try f.store.planSlots() == [slot])  // nothing in a regular position
    let v = try #require(try f.store.video(id: "clip-1"))
    #expect(v.state == .planned && ClipStage.of(v) == .scheduled)
    #expect(try f.store.events(videoId: "clip-1").filter { $0.kind == "plan" }.map(\.message) == ["Set for Sat 14 Nov 3:15 PM"])
    #expect(try f.store.history(postId: posts[0].id).first?.note == "set time")
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-0", "clip-2"])
    #expect(try Planner(store: f.store).exactSlot(videoId: "clip-1") == slot && Planner(store: f.store).exactSlot(videoId: "clip-0") == nil)
  }

  @Test func anAlreadyScheduledClipFreesItsDayAndNothingElseMoves() throws {
    let f = try Fixture.engine(5, ready: 4)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-04#0 clip-2", "2026-11-05#0 clip-3"])
    let before = try R.others(f, except: "clip-1")
    let at = f.at("2026-11-14", "15:15")
    try planner.postAt(videoId: "clip-1", at: at)
    #expect(try R.others(f, except: "clip-1") == before)
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-04#0 clip-2", "2026-11-05#0 clip-3", "2026-11-14#100 clip-1"])
    let own = try f.store.posts(where: "video_id='clip-1'")
    #expect(own.count == 6 && own.allSatisfy { $0.scheduledAt == at })
    // The day it left is simply open: the next pass fills it from the Queue and still nothing else moves.
    #expect(try planner.autoSchedule().scheduled == 0)
    #expect(try R.others(f, except: "clip-1") == before)
    try f.makeReady("clip-4", score: 50)
    #expect(try planner.autoSchedule().scheduled == 1)
    #expect(try R.layout(f).contains("2026-11-03#0 clip-4"))
    #expect(try R.others(f, except: "clip-1", "clip-4") == before)
    #expect(try R.twice(f).isEmpty && f.doublePosts().isEmpty)
  }

  @Test func aFullDayStillTakesASetTimeAndItsClipsStay() throws {
    let f = try Fixture.engine(5)
    try f.updateSettings { $0.postsPerDay = 2 }
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#1 clip-1", "2026-11-03#0 clip-2", "2026-11-03#1 clip-3", "2026-11-04#0 clip-4"])
    let before = try R.others(f, except: "clip-4")
    try planner.postAt(videoId: "clip-4", at: f.at("2026-11-03", "10:00"))
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-02#1 clip-1", "2026-11-03#0 clip-2", "2026-11-03#1 clip-3", "2026-11-03#100 clip-4"])
    #expect(try R.others(f, except: "clip-4") == before)
    #expect(try f.store.posts(where: "video_id='clip-4'").allSatisfy { $0.scheduledAt == f.at("2026-11-03", "10:00") })
    #expect(try planner.autoSchedule().scheduled == 0)
    #expect(try R.others(f, except: "clip-4") == before && f.doublePosts().isEmpty)
  }

  @Test func aTimeThatPassedOrIsUnderTenMinutesAwayIsRefused() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let now = f.clock.now
    #expect(Planner.exactLead == 600)
    #expect(throws: EngineError("That time has passed")) { try planner.postAt(videoId: "clip-0", at: now.addingTimeInterval(-60)) }
    #expect(throws: EngineError("That time has passed")) { try planner.postAt(videoId: "clip-0", at: now) }
    #expect(throws: EngineError("Pick a time at least 10 minutes from now")) { try planner.postAt(videoId: "clip-0", at: now.addingTimeInterval(9 * 60)) }
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty && f.store.events(videoId: "clip-0").filter { $0.kind == "plan" }.isEmpty)
    #expect(try planner.postAtPreview(videoId: "clip-0", at: now.addingTimeInterval(-60)).blocker == StageWording.setTimePassed)
    #expect(try planner.postAtPreview(videoId: "clip-0", at: now.addingTimeInterval(9 * 60)).blocker == StageWording.setTimeTooSoon)
    #expect(throws: EngineError(StageWording.setTimePassed)) { try BulkActions(store: f.store).postAt(["clip-0"], at: now.addingTimeInterval(-60)) }
    try planner.postAt(videoId: "clip-0", at: now.addingTimeInterval(600))  // exactly the lead
    #expect(try f.store.posts().count == 6)
  }

  @Test func youTubeInsideTheQuietWindowGoesAt0730UTCAndThePreviewSaysSo() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let at = f.at("2026-11-14", "22:00")  // 03:00 UTC on the 15th
    let events = try f.store.events().count
    let preview = try planner.postAtPreview(videoId: "clip-0", at: at)
    #expect(preview.blocker == nil && !preview.unchanged && preview.summary == "Set for Sat 14 Nov 10:00 PM" && preview.at == at)
    #expect(preview.platforms.map(\.platform) == Platform.allCases.sorted())
    #expect(preview.platforms.first { $0.platform == .youtube } == .init(platform: .youtube, at: R.utc("2026-11-15", 7, 30), moved: true))
    #expect(preview.platforms.filter { $0.platform != .youtube }.allSatisfy { $0.at == at && !$0.moved })
    #expect(preview.notes == ["YouTube moves to Sun 15 Nov 2:30 AM (07:30 UTC)"])
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty && f.store.events().count == events)  // read-only
    #expect(try f.store.week("2026-11-09") == nil)
    try planner.postAt(videoId: "clip-0", at: at)
    let posts = try f.store.posts()
    #expect(posts.sorted { $0.platform < $1.platform }.map { Planner.ExactPreview.Line(platform: $0.platform, at: $0.scheduledAt, moved: $0.scheduledAt != at) } == preview.platforms)
    let yt = try #require(posts.first { $0.platform == .youtube })
    #expect(try f.store.planDay(of: yt, dm: f.dm) == "2026-11-14")  // its slot's day, not the morning it goes out
    // Outside the window nothing moves.
    let day = f.at("2026-11-14", "15:15")
    let clear = try planner.postAtPreview(videoId: "clip-1", at: day)
    #expect(clear.notes.isEmpty && clear.platforms.allSatisfy { $0.at == day && !$0.moved })
    try planner.postAt(videoId: "clip-1", at: day)
    #expect(try f.store.posts(where: "video_id='clip-1'").allSatisfy { $0.scheduledAt == day })
  }

  @Test func skippedAndUsedPlatformsGetNoPost() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    try BulkActions(store: f.store).setPlatform(["clip-0"], .x, skipped: true)
    try f.store.db.run("UPDATE videos SET already_posted_on=? WHERE id='clip-0'", [JSONCoding.string([Platform.tiktok])])
    try planner.autoSchedule()
    #expect(try Set(f.store.posts(where: "video_id='clip-0'").map(\.platform)) == [.facebook, .threads, .youtube, .instagram])
    let ig = try #require(try f.store.posts(where: "video_id='clip-0' AND platform='instagram'").first)
    try PostActions(store: f.store).reportProblem(postId: ig.id, type: .other, message: "nope")
    let at = f.at("2026-11-14", "15:15")
    let preview = try planner.postAtPreview(videoId: "clip-0", at: at)
    #expect(preview.platforms.map(\.platform) == [.facebook, .threads, .youtube])
    #expect(preview.skipped.map(\.platform) == [.x, .instagram, .tiktok] && preview.skipped.map(\.reason) == [.off, .failed, .posted])
    #expect(preview.skipped.map(\.why) == ["X is off for it", "Instagram failed and waits for you in Posts", "Already posted on TikTok"])
    #expect(preview.replaces.map(\.date) == ["2026-11-02"])
    let slot = try planner.postAt(videoId: "clip-0", at: at)
    let live = try f.store.posts(where: "video_id='clip-0'").filter { !$0.state.isTerminal }
    #expect(Set(live.map(\.platform)) == [.facebook, .threads, .youtube] && live.allSatisfy { $0.scheduledAt == at && $0.planSlotId == slot.id })
    #expect(try f.store.post(id: ig.id)?.state == .failed)  // history stays
  }

  @Test func aPerPlatformSortNeverPullsAnotherClipOntoASetTime() throws {
    let f = try Fixture.engine(4)
    try f.updateSettings { $0.sortOverrides[.tiktok] = .bestFirst }
    let planner = Planner(store: f.store)
    let at = f.at("2026-11-14", "15:15")
    try planner.postAt(videoId: "clip-0", at: at)
    let own = try f.store.posts()
    #expect(own.count == 6 && own.allSatisfy { $0.videoId == "clip-0" && $0.scheduledAt == at })
    try planner.autoSchedule()  // TikTok's own order goes on for the regular days, without clip-0
    #expect(try f.store.posts(where: "video_id='clip-0'").map(\.id).sorted() == own.map(\.id).sorted())
    #expect(try f.store.posts(where: "plan_slot_id=?", [own[0].planSlotId]).allSatisfy { $0.videoId == "clip-0" })
    #expect(try R.twice(f).isEmpty && f.doublePosts().isEmpty)
  }

  @Test func twoSetTimeItemsShareADayAndAMinute() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    let at = f.at("2026-11-14", "15:15")
    let a = try planner.postAt(videoId: "clip-0", at: at)
    let b = try planner.postAt(videoId: "clip-1", at: at)
    let c = try planner.postAt(videoId: "clip-2", at: f.at("2026-11-14", "09:00"))
    #expect([a.position, b.position, c.position] == [100, 101, 102] && Set([a.id, b.id, c.id]).count == 3)
    #expect(try f.store.posts().count == 18 && R.twice(f).isEmpty && f.doublePosts().isEmpty)
    try planner.clearExact(videoId: "clip-0")
    #expect(try planner.postAt(videoId: "clip-0", at: at).position == 100)  // the first free one again
  }

  @Test func changingTheTimeReplacesTheSetTimeAndTheSameTimeChangesNothing() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let first = try planner.postAt(videoId: "clip-0", at: f.at("2026-11-14", "15:15"))
    let old = try f.store.posts().map(\.id)
    let to = f.at("2026-11-20", "08:05")
    let preview = try planner.postAtPreview(videoId: "clip-0", at: to)
    #expect(preview.replaces == [first] && preview.blocker == nil)
    let second = try planner.postAt(videoId: "clip-0", at: to)
    #expect(second.id == first.id && second.exactAt == to && second.date == "2026-11-20" && second.weekStart == "2026-11-16")
    #expect(try f.store.planSlots() == [second])
    let posts = try f.store.posts()
    #expect(posts.count == 6 && posts.allSatisfy { $0.scheduledAt == to } && Set(posts.map(\.id)).isDisjoint(with: old))
    #expect(try f.store.events(videoId: "clip-0").filter { $0.kind == "plan" }.map(\.message) == ["Set for Fri 20 Nov 8:05 AM", "Set for Sat 14 Nov 3:15 PM"])
    // The same time again: nothing is touched, not even when it's too close by now.
    f.setTime("2026-11-20", "08:00")
    #expect(try planner.postAtPreview(videoId: "clip-0", at: to).unchanged)
    #expect(try planner.postAt(videoId: "clip-0", at: to) == second)
    #expect(try f.store.posts().map(\.id) == posts.map(\.id))
    #expect(try f.store.events(videoId: "clip-0").filter { $0.kind == "plan" }.count == 2)
  }

  @Test func clearExactPutsItBackInTheQueueForTheNextOpenDay() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.autoSchedule()
    try planner.postAt(videoId: "clip-1", at: f.at("2026-11-14", "15:15"))
    let before = try R.others(f, except: "clip-1")
    try planner.clearExact(videoId: "clip-1")
    #expect(try f.store.planSlots(where: "video_id='clip-1'").isEmpty && f.store.posts(where: "video_id='clip-1'").isEmpty)
    let v = try #require(try f.store.video(id: "clip-1"))
    #expect(v.state == .ready && ClipStage.of(v) == .queue && v.sentToQueue)
    #expect(try f.store.events(videoId: "clip-1").first { $0.kind == "plan" }?.message == "Back on the regular schedule")
    #expect(try planner.autoSchedule().scheduled == 1)
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-03#0 clip-1", "2026-11-04#0 clip-2"])
    #expect(try R.others(f, except: "clip-1") == before)
    #expect(throws: EngineError(StageWording.noSetTime)) { try planner.clearExact(videoId: "clip-1") }
  }

  @Test func onceSomethingPostedTheSetTimeStays() throws {
    let f = try Fixture.engine(2)
    let planner = Planner(store: f.store)
    let slot = try planner.postAt(videoId: "clip-0", at: f.at("2026-11-03", "10:00"))
    f.setTime("2026-11-03", "10:05")
    let fb = try #require(try f.store.posts(where: "platform='facebook'").first)
    try PostActions(store: f.store).markPosted(postId: fb.id, url: Fixture.postURLs[.facebook]!)
    #expect(throws: EngineError("Already posted on Facebook — this slot can't change")) { try planner.clearExact(videoId: "clip-0") }
    #expect(throws: EngineError("Already posted on Facebook — it can't take a set time")) { try planner.postAt(videoId: "clip-0", at: f.at("2026-11-09", "10:00")) }
    #expect(throws: EngineError.self) { try planner.move(slotId: slot.id, to: "2026-11-09") }
    #expect(try BulkActions(store: f.store).clearExact(["clip-0"]).skipped["clip-0"] == "Already posted on Facebook — this slot can't change")
    #expect(try f.store.planSlots() == [slot] && f.store.posts().count == 6)
  }

  @Test func thePlannerTakesOnlyQueueOrScheduledItems() throws {
    let f = try Fixture.engine(3, ready: 1)
    try R.unsent(f, "clip-1")
    let planner = Planner(store: f.store)
    let at = f.at("2026-11-14", "15:15")
    #expect(R.message { try planner.postAt(videoId: "clip-1", at: at) }?.contains("is in Edit, not the Queue") == true)
    #expect(try planner.postAtPreview(videoId: "clip-1", at: at).blocker?.contains("send it to the Queue first") == true)
    #expect(R.message { try planner.postAt(videoId: "clip-2", at: at) }?.contains("is in Edit, not the Queue") == true)
    #expect(R.message { try planner.postAt(videoId: "long-0001", at: at) }?.contains("long-form") == true)
    #expect(R.message { try planner.postAt(videoId: "nope", at: at) } == "No video nope")
    #expect(try f.store.planSlots().isEmpty)
    // A scheduled clip that went invalid says what to fix, and keeps its day.
    try planner.autoSchedule()
    try f.store.db.run("UPDATE edits SET json='{}' WHERE video_id='clip-0'")
    let before = try R.plan(f)
    #expect(R.message { try planner.postAt(videoId: "clip-0", at: at) }?.contains("has something to fix first") == true)
    #expect(try R.plan(f) == before)
  }

  @Test func aClipWithNowhereLeftToPostIsRefused() throws {
    let f = try Fixture.engine(1)
    try f.store.db.run("UPDATE videos SET already_posted_on=? WHERE id='clip-0'", [JSONCoding.string(Platform.allCases)])
    #expect(R.message { try Planner(store: f.store).postAt(videoId: "clip-0", at: f.at("2026-11-14", "15:15")) }?.contains("nowhere left to post") == true)
    #expect(try f.store.planSlots().isEmpty && f.store.week("2026-11-09") == nil)
  }

  // MARK: BulkActions

  @Test func bulkPostAtIsOneBatchAndUndoPutsThePlanBackExactly() throws {
    let f = try Fixture.engine(4)
    let bulk = BulkActions(store: f.store)
    try Planner(store: f.store).autoSchedule()
    let before = try R.plan(f)
    let at = f.at("2026-11-14", "15:15")
    let r = try bulk.postAt(["clip-1", "clip-2"], at: at)
    #expect(r.action == "post-at" && r.changed == ["clip-1", "clip-2"] && r.skipped.isEmpty && r.batchId != nil)
    #expect(r.moves?["clip-1"] == StageMove(from: .scheduled, to: .scheduled, note: "Set for Sat 14 Nov 3:15 PM"))
    #expect(try bulk.batch(id: try #require(r.batchId))?.params == ["at": "2026-11-14 15:15"])
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-05#0 clip-3", "2026-11-14#100 clip-1", "2026-11-14#101 clip-2"])
    let after = try R.plan(f)
    // One undo: the regular days and every post of them are back, ids and times included.
    let undo = try bulk.undo(try #require(r.batchId))
    #expect(undo.skipped.isEmpty && Set(undo.changed) == ["clip-1", "clip-2"])
    #expect(try R.plan(f) == before)
    #expect(try f.store.planSlots().allSatisfy { !$0.isExact })
    // Doing it again gives the same plan (new ids aside).
    let again = try bulk.postAt(["clip-1", "clip-2"], at: at)
    #expect(again.changed == ["clip-1", "clip-2"])
    #expect(try R.layout(f) == ["2026-11-02#0 clip-0", "2026-11-05#0 clip-3", "2026-11-14#100 clip-1", "2026-11-14#101 clip-2"])
    #expect(try R.plan(f).count == after.count)
  }

  @Test func exactAtRoundTripsThroughUndo() throws {
    let f = try Fixture.engine(2)
    let bulk = BulkActions(store: f.store)
    let at = f.at("2026-11-14", "22:00")  // YouTube moves, so the posts aren't all alike
    let set = try bulk.postAt(["clip-0"], at: at)
    let slot = try #require(try Planner(store: f.store).exactSlot(videoId: "clip-0"))
    let withTime = try R.plan(f)
    // Clearing it, then undoing the clear: the same slot with its set time and the same posts.
    let clear = try bulk.clearExact(["clip-0"])
    #expect(clear.action == "post-at-clear" && clear.changed == ["clip-0"])
    #expect(clear.moves?["clip-0"] == StageMove(from: .scheduled, to: .queue, note: "Back on the regular schedule"))
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    try bulk.undo(try #require(clear.batchId))
    #expect(try f.store.planSlots() == [slot] && slot.exactAt == at)
    #expect(try R.plan(f) == withTime)
    #expect(try f.store.posts(where: "platform='youtube'").first?.scheduledAt == R.utc("2026-11-15", 7, 30))
    // Changing the time, then undoing: the first time is back. Undoing the first batch: no plan at all.
    let change = try bulk.postAt(["clip-0"], at: f.at("2026-11-21", "12:00"))
    #expect(change.moves?["clip-0"]?.note == "Set for Sat 21 Nov 12:00 PM")
    try bulk.undo(try #require(change.batchId))
    #expect(try R.plan(f) == withTime)
    try bulk.undo(try #require(set.batchId))
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
  }

  @Test func anEditItemGoesThroughSendToQueueFirst() throws {
    let f = try Fixture.engine(2, ready: 0)
    try R.unsent(f, "clip-0")
    #expect(try f.store.video(id: "clip-0")?.sentToQueue == false)
    let bulk = BulkActions(store: f.store)
    let at = f.at("2026-11-14", "15:15")
    let preview = try bulk.postAtPreview("clip-0", at: at)
    #expect(preview.blocker == nil && preview.platforms.count == 6)
    #expect(try f.store.video(id: "clip-0")?.sentToQueue == false && f.store.planSlots().isEmpty)  // the preview sent nothing
    let r = try bulk.postAt(["clip-0"], at: at)
    #expect(r.changed == ["clip-0"] && r.moves?["clip-0"] == StageMove(from: .edit, to: .scheduled, note: "Set for Sat 14 Nov 3:15 PM"))
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.sentToQueue && v.state == .planned && ClipStage.of(v) == .scheduled)
    #expect(try f.store.posts().count == 6)
    // Undo takes back the send too: it waits in Edit again, with nothing on the calendar.
    try bulk.undo(try #require(r.batchId))
    let back = try #require(try f.store.video(id: "clip-0"))
    #expect(!back.sentToQueue && ClipStage.of(back) == .edit)
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
  }

  @Test func aHeldItemIsReleasedBySettingATime() throws {
    let f = try Fixture.engine(2)
    let bulk = BulkActions(store: f.store)
    try bulk.back(["clip-0"])
    #expect(try f.store.video(id: "clip-0")?.heldInEdit == true)
    let r = try bulk.postAt(["clip-0"], at: f.at("2026-11-14", "15:15"))
    #expect(r.changed == ["clip-0"])
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(!v.heldInEdit && v.sentToQueue && v.state == .planned)
  }

  @Test func anEditItemWithIssuesStaysInEditAndSaysWhatIsMissing() throws {
    let f = try Fixture.engine(3, ready: 0)
    try f.store.setScore("clip-0", 50)  // no title, so no text; no crop yet
    try f.store.setTitle("clip-2", "Song Two")  // no score
    try f.store.refreshState(videoId: "clip-0")
    let bulk = BulkActions(store: f.store)
    bulk.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    let at = f.at("2026-11-14", "15:15")
    // Send to Queue's own words for the same clip.
    let send = try bulk.forward(["clip-0"], dryRun: true)
    let words = try #require(send.moves?["clip-0"]?.note)
    #expect(words.hasPrefix("Still in Edit: "))
    let before = try bulk.clipSnapshot("clip-0", renders: false)
    let r = try bulk.postAt(["clip-0", "clip-2"], at: at)
    #expect(r.changed.isEmpty && r.batchId == nil && r.skipped["clip-0"] == words)
    #expect(r.skipped["clip-2"] == "Give it a score on Score first")
    #expect(try bulk.clipSnapshot("clip-0", renders: false) == before)  // untouched: not even the crop was confirmed
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(!v.sentToQueue && ClipStage.of(v) == .edit && v.state == .needsEdit)
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    #expect(try bulk.postAtPreview("clip-0", at: at).blocker == words)
    // Fixed, the same call sets it.
    try f.store.setTitle("clip-0", "Song")
    #expect(try bulk.postAt(["clip-0"], at: at).changed == ["clip-0"])
    #expect(try f.store.posts().count == 6)
  }

  @Test func aDryRunWritesNothing() throws {
    let f = try Fixture.engine(3)
    let bulk = BulkActions(store: f.store)
    try Planner(store: f.store).autoSchedule()
    try Planner(store: f.store).postAt(videoId: "clip-2", at: f.at("2026-11-14", "15:15"))
    let before = try R.plan(f)
    let events = try f.store.events().count
    let r = try bulk.postAt(["clip-0"], at: f.at("2026-11-15", "15:15"), dryRun: true)
    #expect(r.dryRun && r.changed == ["clip-0"] && r.batchId == nil)
    #expect(try bulk.clearExact(["clip-2"], dryRun: true).changed == ["clip-2"])
    #expect(try bulk.clearExact(["clip-1"], dryRun: true).skipped["clip-1"] == "It has no set time")
    #expect(try R.plan(f) == before && f.store.events().count == events && bulk.batches().isEmpty)
  }

  // MARK: djq post-at

  @Test func theDayAndTimeAreReadInTheSettingsTimeZone() throws {
    var s = Settings()
    #expect(try Planner.parseExact("2026-11-14 15:15", settings: s) == ExactRig.utc("2026-11-14", 20, 15))
    #expect(try Planner.parseExact("2026-11-14T08:05", settings: s) == ExactRig.utc("2026-11-14", 13, 5))
    #expect(try Planner.parseExact(" 2026-07-04 9:00 ", settings: s) == ExactRig.utc("2026-07-04", 13))  // summer time
    s.timeZone = "Europe/London"
    #expect(try Planner.parseExact("2026-11-14 15:15", settings: s) == ExactRig.utc("2026-11-14", 15, 15))
    for bad in ["", "2026-11-14", "15:15", "2026-11-14 25:00", "2026-11-14 10:60", "2026-11-31 10:00", "2026-13-01 10:00",
                "14/11/2026 10:00", "2026-11-14 3pm", "tomorrow 10:00", "2026-11-14 10:00:30"] {
      #expect(ExactRig.message { _ = try Planner.parseExact(bad, settings: s) }?.contains("isn't a day and time") == true, "\(bad)")
    }
    #expect(Planner.exactMinute(ExactRig.utc("2026-11-14", 20, 15).addingTimeInterval(59.9)) == ExactRig.utc("2026-11-14", 20, 15))
  }

  @Test func theWordsReadRight() {
    let s = Settings()
    let at = ExactRig.utc("2026-11-14", 20, 15)
    #expect(StageWording.setFor(at, settings: s) == "Set for Sat 14 Nov 3:15 PM")
    #expect(StageWording.setTimeMark(at, settings: s) == "set time 3:15 PM")
    // The same local day reads as a clock time; another day names it.
    #expect(StageWording.youtubeMoves(to: ExactRig.utc("2026-11-15", 7, 30), setFor: ExactRig.utc("2026-11-15", 5, 30), settings: s) == "YouTube moves to 2:30 AM (07:30 UTC)")
    #expect(StageWording.youtubeMoves(to: ExactRig.utc("2026-11-15", 7, 30), setFor: ExactRig.utc("2026-11-15", 3), settings: s) == "YouTube moves to Sun 15 Nov 2:30 AM (07:30 UTC)")
  }
}

/// `djq post-at` end to end: the built binary on a throwaway file database (the real clock, so the times are relative).
@Suite(.serialized) struct R21PostAtCLITests {
  typealias Env = R6PostizCLITests.Env

  /// A whole minute `days` ahead, as `djq` wants it typed, in the Settings time zone.
  func typed(_ env: Env, days: Int, hour: Int = 15, minute: Int = 15) throws -> (text: String, date: Date) {
    let s = try env.store.settings()
    let dm = DayMath(settings: s)
    let day = dm.addDays(dm.key(Date()), days)
    return ("\(day) \(String(format: "%02d:%02d", hour, minute))", dm.at(day, minutes: hour * 60 + minute))
  }

  @Test func setShowAndClear() throws {
    guard R6PostizCLITests.binary != nil else { return }  // `binaryIsBuilt` reports it
    let env = try Env(clips: 2)
    let (text, at) = try typed(env, days: 5)
    // Dry run: says what it would do and writes nothing.
    let dry = try env.json("post-at", "clip-0", text, "--dry-run")
    let plan = try #require(dry["plan"] as? [String: Any])
    #expect(dry["dryRun"] as? Bool == true && dry["changed"] as? Bool == false && dry["exactAt"] == nil)
    #expect((plan["platforms"] as? [[String: Any]])?.count == 6 && plan["blocker"] == nil)
    #expect(try env.store.planSlots().isEmpty)
    // For real.
    let done = try env.json("post-at", "clip-0", text)
    #expect(done["changed"] as? Bool == true && done["batchId"] is String)
    #expect(done["exactAt"] as? String == ISO8601DateFormatter().string(from: at))
    let slot = try #require(try env.store.planSlots().first)
    #expect(slot.exactAt == at && slot.pinned && slot.position == 100 && slot.videoId == "clip-0")
    #expect(try env.store.posts().count == 6)
    // The other commands mark it.
    let week = try env.djq("week", String(text.prefix(10)))
    #expect(week.status == 0 && week.out.contains("set time 3:15 PM") && !week.out.contains("pinned"), "\(week.out)\(week.err)")
    #expect(try env.djq("status").out.contains("1 at a set time"))
    #expect(try env.djq("posts").out.contains("[set time]"))
    let video = try env.json("video", "clip-0")
    #expect(((video["plan"] as? [[String: Any]])?.first?["exactAt"] as? String) == ISO8601DateFormatter().string(from: at))
    // The same time again changes nothing; another time replaces it.
    let same = try env.djq("post-at", "clip-0", text)
    #expect(same.status == 0 && same.out.contains("already set for"), "\(same.out)\(same.err)")
    let (later, laterAt) = try typed(env, days: 6, hour: 9, minute: 0)
    let moved = try env.djq("post-at", "clip-0", String(later.prefix(10)), String(later.suffix(5)))  // unquoted works too
    #expect(moved.status == 0 && moved.out.contains("Set for") && moved.out.contains("replaces the set time") && moved.out.contains("undo: djq bulk undo"), "\(moved.out)\(moved.err)")
    #expect(try env.store.planSlots().map(\.exactAt) == [laterAt])
    // Back on the regular schedule.
    let clear = try env.djq("post-at", "clip-0", "--clear")
    #expect(clear.status == 0 && clear.out.contains("Back on the regular schedule"), "\(clear.out)\(clear.err)")
    #expect(try env.store.planSlots().isEmpty && env.store.posts().isEmpty)
    #expect(try env.djq("post-at", "clip-0", "--clear").status == 2)
    // One clock format in the rows, the summary's; and `--clear` takes no time.
    let rows = try env.djq("post-at", "clip-1", text, "--dry-run")
    #expect(rows.out.contains("3:15 PM") && !rows.out.contains("15:15"), "\(rows.out)")
    let both = try env.djq("post-at", "clip-1", "--clear", text)
    #expect(both.status != 0 && both.err.contains("--clear takes no time"), "\(both.out)\(both.err)")
  }

  @Test func refusalsAreReadable() throws {
    guard R6PostizCLITests.binary != nil else { return }
    let env = try Env(clips: 1)
    let past = try env.djq("post-at", "clip-0", "2020-01-01 10:00")
    #expect(past.status == 2 && past.out.contains("That time has passed"), "\(past.out)\(past.err)")
    let bad = try env.djq("post-at", "clip-0", "next friday")
    #expect(bad.status != 0 && bad.err.contains("isn't a day and time"), "\(bad.out)\(bad.err)")
    let none = try env.djq("post-at")
    #expect(none.status != 0 && none.err.contains("post-at <video>"))
    #expect(try env.djq("--help").out.contains("post-at <video>"))
    #expect(try env.store.planSlots().isEmpty)
  }
}
