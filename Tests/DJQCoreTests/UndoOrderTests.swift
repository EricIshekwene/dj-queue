import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 3 F8: every one-click action is a journal entry (`BulkActions.record`), and ⌘Z (UndoHistory) undoes the
/// MOST RECENT action — never an older, unrelated bulk batch.
@Suite struct UndoOrderTests {
  func bulk(_ f: Fixture) -> BulkActions {
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    return b
  }

  func plan(_ f: Fixture) throws -> [String] {
    try f.store.planSlots().sorted { $0.id < $1.id }.map { "\($0.videoId)@\($0.date)\($0.pinned ? "*" : "")" }
  }

  func weeks(_ f: Fixture) throws -> [String] {
    try f.store.db.query("SELECT week_start, state FROM weeks ORDER BY week_start").map { "\($0.string("week_start")!)|\($0.string("state")!)" }
  }

  @Test func undoTakesTheMostRecentActionFirst() throws {
    let f = try Fixture.engine(4)
    let b = bulk(f)
    var history = UndoHistory()
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)
    let plan0 = try plan(f)

    // 1. An older bulk batch: scores.
    let score0 = try f.store.video(id: "clip-1")?.score
    let a = try b.setScore(["clip-1"], 77)
    history.push(try #require(a.batchId), label: "Score 77")
    // 2. The most recent action: a one-click plan change (post today), journaled by `record`.
    let r = try b.record("post-today", ids: ["clip-2"], plan: true) { try planner.postToday(videoId: "clip-2") }
    history.push(try #require(r.batchId), label: "Posting today")
    #expect(try plan(f) != plan0)
    #expect(r.changed.contains("clip-2"))

    // ⌘Z → the plan change, not the score.
    let popped = history.popTop()
    let top = try #require(popped)
    #expect(top.label == "Posting today")
    try b.undo(top.batchId)
    #expect(try plan(f) == plan0)
    #expect(try f.store.video(id: "clip-1")?.score == 77)
    // ⌘Z again → the score.
    let popped2 = history.popTop()
    let next = try #require(popped2)
    try b.undo(next.batchId)
    #expect(try f.store.video(id: "clip-1")?.score == score0)
    #expect(history.popTop() == nil)
  }

  @Test func toastUndoRemovesThatEntryOnly() {
    var h = UndoHistory(limit: 3)
    h.push("a", label: "A"); h.push("b", label: "B"); h.push("c", label: "C")
    h.remove("b")
    #expect(h.entries.map(\.batchId) == ["a", "c"])
    h.push("d", label: "D"); h.push("e", label: "E")
    #expect(h.entries.map(\.batchId) == ["c", "d", "e"])  // bounded, oldest dropped
    h.push("c", label: "C again")
    #expect(h.top?.batchId == "c" && h.entries.count == 3)  // re-push moves to the top
  }

  @Test func weekOnlyChangesAreJournaledAndUndone() throws {
    let f = try Fixture.engine(3)
    let b = bulk(f)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)
    let w0 = try weeks(f), posts0 = try f.store.posts().count
    let r = try b.record("approve-week", plan: true) { try planner.approveWeek(f.week) }
    #expect(r.batchId != nil)
    #expect(try weeks(f) != w0 && f.store.posts().count > posts0)
    try b.undo(try #require(r.batchId))
    #expect(try weeks(f) == w0)
    #expect(try f.store.posts().count == posts0)  // posts created by approve are gone again
  }

  @Test func settingsChangesUndoAndRefuseWhenChangedSince() throws {
    let f = try Fixture.engine(1)
    let b = bulk(f)
    var s = try f.store.settings()
    let paused0 = s.paused
    s.paused = !paused0
    let r = try b.record("settings", settings: true) { try f.store.save(s) }
    #expect(try f.store.settings().paused == !paused0)
    // Changed again since → refused unless forced.
    var s2 = try f.store.settings()
    s2.postsPerDay += 1
    try f.store.save(s2)
    #expect(throws: EngineError.self) { try b.undo(r.batchId!) }
    try b.undo(r.batchId!, force: true)
    #expect(try f.store.settings().paused == paused0)
  }

  @Test func nothingChangedMeansNoJournalEntry() throws {
    let f = try Fixture.engine(1)
    let r = try bulk(f).record("noop", ids: ["clip-0"], plan: true, settings: true) {}
    #expect(r.batchId == nil && r.changed.isEmpty)
    #expect(try bulk(f).batches().isEmpty)
  }

  @Test func clipFieldsUndoThroughRecord() throws {
    let f = try Fixture.engine(2)
    let b = bulk(f)
    let k0 = try #require(try f.store.video(id: "clip-0")?.kind)
    let other: Kind = k0 == .djVid ? .talking : .djVid
    let r = try b.record("kind", ids: ["clip-0"]) { try f.store.setKind("clip-0", other) }
    #expect(r.changed == ["clip-0"])
    try b.undo(r.batchId!)
    #expect(try f.store.video(id: "clip-0")?.kind == k0)
  }

  /// Reviewer scenario: score clip A, edit clip B in the editor, close, ⌘Z → B's edits go, A's score stays.
  @Test func editorSessionIsOneUndoEntryOnTop() throws {
    let f = try Fixture.engine(3)
    let b = bulk(f)
    var history = UndoHistory()
    let a = try b.setScore(["clip-0"], 88)
    history.push(try #require(a.batchId), label: "Score 88")
    // Editor opens on B (with its neighbours reachable), several changes, closes.
    let session = try b.begin("editor", ids: ["clip-1", "clip-2"])
    let title0 = try f.store.video(id: "clip-1")?.title
    try f.store.setTitle("clip-1", "Edited in the editor")
    var e = try f.store.edit(videoId: "clip-1")
    e.coverTime = 1.5
    try f.store.save(e, videoId: "clip-1")
    let r = try b.commit(session)
    #expect(r.changed == ["clip-1"])  // clip-2 untouched → not journaled
    history.push(try #require(r.batchId), label: "Edits to clip-1")
    let top = history.popTop()
    #expect(top?.label == "Edits to clip-1")
    try b.undo(try #require(top?.batchId))
    #expect(try f.store.video(id: "clip-1")?.title == title0)
    #expect(try f.store.edit(videoId: "clip-1").coverTime == nil)
    #expect(try f.store.video(id: "clip-0")?.score == 88)  // the older action is untouched
    // A session with no changes leaves no entry.
    #expect(try b.commit(try b.begin("editor", ids: ["clip-2"])).batchId == nil)
  }

  /// Rapid ⌘Z⌘Z: 10 → 50 → 60, two undos submitted back to back → 10 (the runner keeps them in order).
  @Test func rapidUndosApplyInOrder() throws {
    let f = try Fixture.engine(1)
    let b = bulk(f)
    _ = try b.setScore(["clip-0"], 10)
    let s50 = try #require(try b.setScore(["clip-0"], 50).batchId)
    let s60 = try #require(try b.setScore(["clip-0"], 60).batchId)
    let runner = UndoRunner(bulk: b)
    runner.undo(s60) { _ in }
    runner.undo(s50) { _ in }
    runner.wait()
    #expect(try f.store.video(id: "clip-0")?.score == 10)
  }
}
