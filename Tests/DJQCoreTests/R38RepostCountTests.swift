import Foundation
import Testing
@testable import DJQCore

/// Round 38: a repostable clip carries its count; every version posts it unless the version has its own Posts
/// (an override). DECISIONS-R38.md.
@Suite struct R38RepostCountTests {
  func addVersion(_ f: Fixture, _ id: String, _ n: Int) throws {
    var v = Version(number: n)
    v.text = "Hook \(n)"
    v.standalone = true
    try f.store.save(v, videoId: id)
  }

  @Test func everyVersionPostsTheClipsCountUnlessItOverrides() throws {
    let f = try Fixture.engine(1)
    try addVersion(f, "clip-0", 2)
    try addVersion(f, "clip-0", 3)
    try f.store.setRepost(videoId: "clip-0", count: 3)
    #expect(try (1...3).map { try f.store.postCount(videoId: "clip-0", version: $0) } == [3, 3, 3])
    try f.store.setPostCount(videoId: "clip-0", number: 2, 1)
    try f.store.setPostCount(videoId: "clip-0", number: 3, 5)
    #expect(try (1...3).map { try f.store.postCount(videoId: "clip-0", version: $0) } == [3, 1, 5])
    // A new count reaches the versions that follow the clip only.
    try f.store.setRepost(videoId: "clip-0", count: 2)
    #expect(try (1...3).map { try f.store.postCount(videoId: "clip-0", version: $0) } == [2, 1, 5])
    // Not repostable: once, except the overrides.
    try f.store.setRepost(videoId: "clip-0", count: nil)
    #expect(try (1...3).map { try f.store.postCount(videoId: "clip-0", version: $0) } == [1, 1, 5])
    #expect(throws: EngineError.self) { try f.store.setRepost(videoId: "clip-0", count: 1) }
  }

  @Test func bulkPicksTheCountAndUndoRestoresIt() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2 }
    try f.store.setRepost(videoId: "clip-0", count: 4)
    let r = try BulkActions(store: f.store).setRepostable(["clip-0", "clip-1"], count: 3)
    #expect(r.changed.sorted() == ["clip-0", "clip-1"])
    #expect(try f.store.repostCounts() == ["clip-0": 3, "clip-1": 3])
    try Planner(store: f.store).autoSchedule()
    #expect(try f.store.planSlots().filter { $0.videoId == "clip-1" }.count == 3)
    _ = try BulkActions(store: f.store).undo(try #require(r.batchId))
    #expect(try f.store.repostCounts() == ["clip-0": 4])
  }

  @Test func round37ListOfIdsReadsAsTheDefaultCount() throws {
    let f = try Fixture.engine(1)
    try f.updateSettings { $0.postsPerVersion = 3 }
    try f.store.setKV(RepostSwitch.key, ["clip-0"])
    #expect(try f.store.repostCounts() == ["clip-0": 3])
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 3)
  }

  @Test func aLowerCountTakesTheExtraRepostsOff() throws {
    let f = try Fixture.engine(1)
    try f.updateSettings { $0.postsPerDay = 1 }
    try f.store.setRepost(videoId: "clip-0", count: 4)
    try Planner(store: f.store).autoSchedule()
    #expect(try f.store.planSlots().count == 4)
    try f.store.setRepost(videoId: "clip-0", count: 2)
    try Planner(store: f.store).autoSchedule()
    #expect(try f.store.planSlots().map(\.postNo).sorted() == [1, 2])
    #expect(try f.doublePosts().isEmpty)
  }

  /// Review: "on" without a count keeps the count a clip has (it never resets ×4 to the Settings count).
  @Test func onWithoutACountKeepsTheClipsCount() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.postsPerVersion = 2 }
    try f.store.setRepost(videoId: "clip-0", count: 4)
    #expect(try !f.store.setRepost(videoId: "clip-0", true))
    _ = try BulkActions(store: f.store).setRepostable(["clip-0", "clip-1"], true)
    #expect(try f.store.repostCounts() == ["clip-0": 4, "clip-1": 2])
  }
}
