import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// The core behaviour the round-2 pipeline screens (Score, Edit, Queue) build on: Queue's drag-to-a-day and the
/// Score grid's "Save scores" (one batch per typed value, every batch undoable).
@Suite struct R2PipelineScreenTests {
  func bulk(_ f: Fixture) -> BulkActions {
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    return b
  }

  /// Queue drag: dropping a backlog clip on a planned (proposed, unpinned) clip = pin it to that day. The dropped-on
  /// clip goes back to the backlog, and one undo restores the plan exactly.
  @Test func dragBacklogClipOntoPlannedDayAndUndo() throws {
    let f = try Fixture.engine(9)
    let planned = try Planner(store: f.store).proposeWeek(f.week)
    let before = try f.store.planSlots()
    let target = try #require(planned.first { $0.date == "2026-11-04" })
    let backlog = try #require(try Queue(store: f.store).ordered().first)
    let r = try bulk(f).pinConsecutive([backlog.id], from: target.date)
    #expect(r.changed == [backlog.id])
    let now = try #require(try f.store.planSlots(where: "date=?", [target.date]).first)
    #expect(now.videoId == backlog.id && now.pinned)
    #expect(try Queue(store: f.store).ordered().contains { $0.id == target.videoId })
    try bulk(f).undo(try #require(r.batchId))
    #expect(try f.store.planSlots() == before)
  }

  /// Queue drag between two planned clips: the dragged clip takes the other's day (pinned), they trade places.
  @Test func dragPlannedClipOntoAnotherPlannedDay() throws {
    let f = try Fixture.engine(7)
    let planned = try Planner(store: f.store).proposeWeek(f.week)
    let a = try #require(planned.first { $0.date == "2026-11-03" })
    let b = try #require(planned.first { $0.date == "2026-11-06" })
    let r = try bulk(f).pinConsecutive([a.videoId], from: b.date)
    #expect(r.changed == [a.videoId])
    #expect(try f.store.planSlots(where: "video_id=?", [a.videoId]).map(\.date) == [b.date])
    #expect(try f.store.planSlots(where: "video_id=?", [b.videoId]).map(\.date) == [a.date])
  }

  /// Score grid "Save scores": clips that share a typed value share a batch; undoing every batch clears them all.
  @Test func typedScoresSaveInGroupsAndUndoAll() throws {
    let f = try Fixture()
    try f.intake()
    let b = bulk(f)
    let typed = ["clip-0": 72, "clip-1": 72, "clip-2": 40]
    var batches: [String] = []
    for (score, ids) in Dictionary(grouping: typed.keys.sorted(), by: { typed[$0]! }) {
      let r = try b.setScore(ids, score)
      #expect(r.changed.count == ids.count)
      batches.append(try #require(r.batchId))
    }
    #expect(try f.store.video(id: "clip-0")?.score == 72 && f.store.video(id: "clip-2")?.score == 40)
    for id in batches.reversed() { try b.undo(id) }
    #expect(try ["clip-0", "clip-1", "clip-2"].allSatisfy { try f.store.video(id: $0)?.score == nil })
  }
}
