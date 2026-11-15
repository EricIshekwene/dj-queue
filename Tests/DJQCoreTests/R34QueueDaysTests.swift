import Foundation
import Testing
@testable import DJQCore

/// Round 34: every post in the Queue has a day, and a clip's posts go out in order (DECISIONS-R34.md).
@Suite struct R34QueueDaysTests {
  func slots(_ f: Fixture, _ id: String) throws -> [PlanSlot] {
    try f.store.planSlots().filter { $0.videoId == id }.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
  }

  /// Eric's 15 Nov Queue: a clip's first post sat a week out (moved there), and its repeat took today, so "v1 · 2 of 2"
  /// was to post before "v1 · 1 of 2". The repeat now only takes a day after the first post.
  @Test func aRepeatNeverGoesBeforeTheClipsFirstPost() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.postsPerDay = 2; $0.postsPerVersion = 2 }
    try Planner(store: f.store).autoSchedule()
    let mine = try slots(f, "clip-0")
    #expect(mine.map(\.unit) == [.first, PostUnit(version: 1, post: 2)])
    // The first post moves 10 days on and the repeat comes off: the next pass must put the repeat after the first post.
    try Planner(store: f.store).move(slotId: mine[0].id, to: f.dm.addDays("2026-11-02", 10))
    try Planner(store: f.store).remove(slotId: mine[1].id)
    try Planner(store: f.store).autoSchedule()
    let after = try slots(f, "clip-0")
    #expect(after.map(\.unit) == [.first, PostUnit(version: 1, post: 2)], "\(after.map { "\($0.date) \($0.unit)" })")
    #expect(try Planner(store: f.store).schedulable(f.store.settings()).isEmpty)
  }

  /// A new clip takes the clip's last repeat only, so a moved repeat never jumps ahead of its own clip's later post.
  @Test func aNewClipTakesOnlyAClipsLastPost() throws {
    let f = try Fixture.engine(4)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 3 }
    try f.store.setSentToQueue("clip-3", false)
    try f.store.refreshState(videoId: "clip-3")
    try Planner(store: f.store).autoSchedule()
    try f.store.setSentToQueue("clip-3", true)
    try f.store.refreshState(videoId: "clip-3")
    try Planner(store: f.store).autoSchedule()
    #expect(try Planner(store: f.store).schedulable(f.store.settings()).isEmpty)
    for id in (0..<4).map({ "clip-\($0)" }) {
      let mine = try slots(f, id)
      #expect(mine.map(\.unit) == mine.map(\.unit).sorted(), "\(id): \(mine.map { "\($0.date) \($0.unit)" })")
    }
    let new = try #require(try slots(f, "clip-3").first)
    #expect(new.date <= f.dm.addDays("2026-11-02", Planner.firmDays))
  }
}
