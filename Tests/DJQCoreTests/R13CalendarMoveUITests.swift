import Foundation
import Testing
@testable import DJQCore

/// What the Calendar's moves do underneath: a move onto today late in the day, and its undo.
@Suite struct R13CalendarMoveUITests {
  /// Eight clips scheduled at 8 am, the clock moved to 5 pm with nothing ticked, and one clip waiting in the Queue.
  func lateInTheDay() throws -> (f: Fixture, today: String, tomorrow: String) {
    let f = try Fixture.engine(9, ready: 8)
    let today = f.dm.key(f.clock.now), tomorrow = f.dm.addDays(today, 1)
    f.setTime(today, "08:00")
    try Planner(store: f.store).autoSchedule()
    f.setTime(today, "17:00")
    try f.makeReady("clip-8", score: 90)  // waiting in the Queue, no day yet
    return (f, today, tomorrow)
  }

  /// Round 13 re-review N3: a skipped platform isn't filled with a clip Eric never touched.
  @Test func aMoveOntoTodayNeverPullsAnotherClip() throws {
    let (f, today, tomorrow) = try lateInTheDay()
    let planner = Planner(store: f.store)
    let slot = try #require(try f.store.planSlots(where: "date=?", [tomorrow]).first)
    let x = try #require(try f.store.slotPosts(slot.id).first { $0.platform == .x })
    try PostActions(store: f.store).skip(postId: x.id)
    try f.store.db.run("DELETE FROM plan_slots WHERE date=?", [today])
    try planner.pin(videoId: slot.videoId, date: today)
    let moved = try #require(try f.store.planSlots(where: "video_id=? AND date=?", [slot.videoId, today]).first)
    let posts = try f.store.slotPosts(moved.id)
    #expect(!posts.isEmpty)
    #expect(posts.allSatisfy { $0.videoId == slot.videoId })
  }

  /// N2: the other clip's posts were inside the lead, so the swap can't be undone; the app words this refusal.
  @Test func undoOfASwapInsideTheLeadIsRefused() throws {
    let (f, today, tomorrow) = try lateInTheDay()
    let a = try #require(try f.store.planSlots(where: "date=?", [tomorrow]).first)
    let bulk = BulkActions(store: f.store)
    let r = try bulk.pinConsecutive([a.videoId], from: today)
    #expect(r.changed == [a.videoId])
    let id = try #require(r.batchId)
    #expect(throws: EngineError.self) { try bulk.undo(id) }
    do { _ = try bulk.undo(id) } catch { #expect(error.localizedDescription.contains("its slot has passed")) }
  }
}
