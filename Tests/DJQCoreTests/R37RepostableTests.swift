import Foundation
import Testing
@testable import DJQCore

/// Round 37: bulk Mark repostable / not repostable, its undo, the filter and the old names (DECISIONS-R37.md).
@Suite struct R37RepostableTests {
  func slots(_ f: Fixture, _ id: String) throws -> [PlanSlot] { try f.store.planSlots().filter { $0.videoId == id } }

  @Test func markRepostableGivesRepostsDaysAndUndoTakesThemBack() throws {
    let f = try Fixture.engine(3)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2 }
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").count == 1 && slots(f, "clip-1").count == 1)
    let r = try BulkActions(store: f.store).setRepostable(["clip-0", "clip-1"], true)
    #expect(r.changed.sorted() == ["clip-0", "clip-1"] && r.batchId != nil)
    #expect(try f.store.repostableClips() == ["clip-0", "clip-1"])
    #expect(try BulkActions(store: f.store).ids(filter: "repostable").sorted() == ["clip-0", "clip-1"])
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").count == 2 && slots(f, "clip-1").count == 2 && slots(f, "clip-2").count == 1)
    // Undo: the mark as it was; the next pass takes the reposts off again.
    _ = try BulkActions(store: f.store).undo(try #require(r.batchId))
    #expect(try f.store.repostableClips().isEmpty)
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").count == 1 && slots(f, "clip-1").count == 1)
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func notRepostableClearsOwnCountsAboveOnceAndKeepsNever() throws {
    let f = try Fixture.engine(1)
    var v2 = Version(number: 2)
    v2.text = "Hook 2"
    v2.standalone = true
    try f.store.save(v2, videoId: "clip-0")
    var v3 = Version(number: 3)
    v3.text = "Hook 3"
    v3.standalone = true
    try f.store.save(v3, videoId: "clip-0")
    try f.store.setPostCount(videoId: "clip-0", number: 2, 3)
    try f.store.setPostCount(videoId: "clip-0", number: 3, 0)
    #expect(try f.store.isRepostable(videoId: "clip-0"), "a version's own Posts above once makes the clip repostable")
    let r = try BulkActions(store: f.store).setRepostable(["clip-0"], false)
    #expect(r.changed == ["clip-0"])
    #expect(try f.store.postCount(videoId: "clip-0", version: 2) == 1)
    #expect(try f.store.postCount(videoId: "clip-0", version: 3) == 0, "Never stays Never")
    #expect(try !f.store.isRepostable(videoId: "clip-0"))
    // Undo brings v2's own 3 back.
    _ = try BulkActions(store: f.store).undo(try #require(r.batchId))
    #expect(try f.store.postCount(videoId: "clip-0", version: 2) == 3)
  }

  @Test func anUnrelatedBatchsUndoLeavesTheMarkAlone() throws {
    let f = try Fixture.engine(1)
    let k = try BulkActions(store: f.store).setKind(["clip-0"], .talking)
    try f.store.setRepost(videoId: "clip-0", true)
    let u = try BulkActions(store: f.store).undo(try #require(k.batchId))
    #expect(u.skipped.isEmpty, "a later mark doesn't block the kind's undo")
    #expect(try f.store.repostOn(videoId: "clip-0"), "and the undo doesn't take the mark back")
  }

  @Test func longFormIsSkipped() throws {
    let f = try Fixture.engine(1)
    try f.store.db.run("UPDATE videos SET type='long-form' WHERE id='clip-0'")
    let r = try BulkActions(store: f.store).setRepostable(["clip-0"], true)
    #expect(r.changed.isEmpty && r.skipped["clip-0"] != nil)
  }

  /// Review B1: the engine compacts within seconds of Not repostable; the undo must still work.
  @Test func notRepostableUndoesAfterTheEngineRan() throws {
    let f = try Fixture.engine(3)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2 }
    _ = try BulkActions(store: f.store).setRepostable(["clip-0", "clip-1"], true)
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").count == 2)
    let r = try BulkActions(store: f.store).setRepostable(["clip-0", "clip-1"], false)
    try Planner(store: f.store).autoSchedule()  // compaction re-lays the movable days
    #expect(try slots(f, "clip-0").count == 1)
    let u = try BulkActions(store: f.store).undo(try #require(r.batchId))
    #expect(u.skipped.isEmpty, "\(u.skipped)")
    #expect(try f.store.repostableClips() == ["clip-0", "clip-1"])
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").count == 2 && slots(f, "clip-1").count == 2)
    #expect(try f.doublePosts().isEmpty)
  }

  /// Review N1: undoing an older, unrelated batch keeps the Posts set since.
  @Test func anOlderUndoKeepsTodaysPosts() throws {
    let f = try Fixture.engine(1)
    let k = try BulkActions(store: f.store).setKind(["clip-0"], .talking)
    try f.store.setPostCount(videoId: "clip-0", number: 1, 3)
    _ = try BulkActions(store: f.store).undo(try #require(k.batchId))
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 3)
  }
}
