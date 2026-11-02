import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 2 #11: bulk actions, one transaction each, journal + undo.
@Suite struct R2BulkTests {
  func bulk(_ f: Fixture) -> BulkActions {
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    return b
  }

  @Test func makeReadyConfirmsDefaultCropAndReportsRemaining() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.setTitle("clip-0", "Yayo x Johnny")
    var custom = Edit()
    custom.crop = CropRect(x: 0, y: 0, w: 1216, h: 2160)
    try f.store.save(custom, videoId: "clip-3")
    let r = try bulk(f).makeReadyWithDefaults(["clip-0", "clip-2", "clip-3", "long-0001", "nope"])
    #expect(Set(r.changed) == ["clip-0", "clip-2"])
    #expect(r.skipped["long-0001"] == "long-form" && r.skipped["nope"] == "no such video")
    #expect(try f.store.edit(videoId: "clip-0").crop == CropRect(x: 1312, y: 0, w: 1216, h: 2160))
    #expect(try f.store.edit(videoId: "clip-3").crop?.x == 0)  // a custom crop is never touched
    #expect(r.remainingIssues["clip-0"] == [])
    #expect(r.remainingIssues["clip-2"]?.map(\.kind) == [.noText])
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
    #expect(try f.store.video(id: "clip-2")?.sourceWidth == 3840)  // size cached
    #expect(try f.store.events(videoId: "clip-0").contains { $0.kind == "bulk" && $0.message.contains("make-ready") })
    // Undo puts both back exactly.
    let u = try bulk(f).undo(try #require(r.batchId))
    #expect(Set(u.changed) == ["clip-0", "clip-2"])
    #expect(try f.store.edit(videoId: "clip-0").crop == nil && !(try f.store.hasEdit(videoId: "clip-0")))
    #expect(try f.store.video(id: "clip-0")?.state == .needsEdit)
    #expect(throws: EngineError.self) { try bulk(f).undo(r.batchId!) }  // only once
  }

  /// The confirmation sheet and toast quote `outlook`; it must match what validation says after the apply,
  /// for unchanged clips too (Edit's "N will be ready · M still need a title").
  @Test func makeReadyOutlookMatchesRemainingIssues() throws {
    let f = try Fixture()
    try f.intake()
    for id in ["clip-0", "clip-2", "clip-3"] { try f.store.setScore(id, 50) }  // round 4: unscored clips go to Score, not the Queue
    try f.store.setTitle("clip-0", "Yayo x Johnny")
    var custom = Edit()
    custom.crop = CropRect(x: 0, y: 0, w: 1216, h: 2160)
    try f.store.save(custom, videoId: "clip-3")
    let ids = ["clip-0", "clip-2", "clip-3", "long-0001"]
    let dry = try bulk(f).makeReadyWithDefaults(ids, dryRun: true)
    let r = try bulk(f).makeReadyWithDefaults(ids)
    #expect(dry.outlook == r.outlook)
    #expect(Set(r.remainingIssues.keys) == ["clip-0", "clip-2", "clip-3"])  // clip-3 unchanged but reported
    for (id, issues) in r.remainingIssues {
      let v = try #require(try f.store.video(id: id))
      #expect(issues == (try Validation.issues(video: v, store: f.store)))
    }
    let o = try #require(r.outlook)
    #expect(o.ready == ["clip-0"])
    #expect(Set(o.needTitle) == ["clip-2", "clip-3"] && o.other.isEmpty)
    #expect(o.summary == "1 to the Queue · 2 still need a title")
    // "Use raw tag as title" sets the tag verbatim; those clips are then ready.
    let t = try bulk(f).useRawTagAsTitle(o.needTitle + ["clip-0"])
    #expect(t.skipped["clip-0"] == "already has a title")
    let v2 = try #require(try f.store.video(id: "clip-2"))
    #expect(v2.title == v2.tag)
    #expect(try bulk(f).makeReadyWithDefaults(ids, dryRun: true).outlook?.ready.sorted() == ["clip-0", "clip-2", "clip-3"])
    try bulk(f).undo(try #require(t.batchId))
    #expect(try f.store.video(id: "clip-2")?.titleText == nil)
  }

  @Test func dryRunChangesNothing() throws {
    let f = try Fixture()
    try f.intake()
    let r = try bulk(f).setScore(["clip-0", "clip-1"], 70, dryRun: true)
    #expect(r.dryRun && r.changed.count == 2 && r.batchId == nil)
    #expect(try f.store.video(id: "clip-0")?.score == nil)
    #expect(try bulk(f).batches().isEmpty)
  }

  @Test func scoreKindExcludeAndUndo() throws {
    let f = try Fixture()
    try f.intake()
    let b = bulk(f)
    try b.setScore(["clip-0", "clip-1"], 50)
    let adj = try b.adjustScore(["clip-0", "clip-1", "clip-2"], by: 60)
    #expect(adj.skipped["clip-2"] == "not scored yet")
    #expect(try f.store.video(id: "clip-0")?.score == 100)
    try b.undo(adj.batchId!)
    #expect(try f.store.video(id: "clip-0")?.score == 50)
    let k = try b.setKind(["clip-0"], .talking)
    #expect(try f.store.video(id: "clip-0")?.kind == .talking)
    let x = try b.setExcluded(["clip-0", "clip-1"], true)
    #expect(try f.store.video(id: "clip-1")?.state == .excluded)
    try b.undo(x.batchId!)
    try b.undo(k.batchId!)
    #expect(try f.store.video(id: "clip-0")?.kind == .djVid && f.store.video(id: "clip-1")?.state == .needsEdit)
    #expect(try b.batches().count == 4)
  }

  @Test func undoSkipsClipsChangedSince() throws {
    let f = try Fixture()
    try f.intake()
    let b = bulk(f)
    let r = try b.setScore(["clip-0", "clip-1"], 40)
    try f.store.setScore("clip-1", 90)  // Eric changed it afterwards
    let u = try b.undo(r.batchId!)
    #expect(u.changed == ["clip-0"] && u.skipped["clip-1"] != nil)
    #expect(try f.store.video(id: "clip-1")?.score == 90)
    // Partial undo leaves the batch open and remembers what was restored.
    let rec = try #require(try b.batch(id: r.batchId!))
    #expect(rec.undoneAt == nil && rec.restored == ["clip-0"])
    // Eric changes clip-0 again; a plain undo still skips clip-1 and doesn't touch the already-restored clip-0.
    try f.store.setScore("clip-0", 77)
    let u2 = try b.undo(r.batchId!)
    #expect(u2.changed.isEmpty && u2.skipped.keys.sorted() == ["clip-1"])
    #expect(try f.store.video(id: "clip-0")?.score == 77)
    // force restores the remainder and only then marks the batch undone.
    let u3 = try b.undo(r.batchId!, force: true)
    #expect(u3.changed == ["clip-1"] && u3.skipped.isEmpty)
    #expect(try f.store.video(id: "clip-1")?.score == nil && f.store.video(id: "clip-0")?.score == 77)
    #expect(try b.batch(id: r.batchId!)?.undoneAt != nil)
    #expect(throws: EngineError.self) { try b.undo(r.batchId!, force: true) }
  }

  @Test func captionHashtagsPlatformsAndApplyDefaults() throws {
    let f = try Fixture()
    try f.intake()
    let b = bulk(f)
    var v1 = Version(number: 1)
    v1.caption = "written"
    v1.style = .outline
    try f.store.save(v1, videoId: "clip-0")
    try b.setCaptionTemplate(["clip-0", "clip-1"], "short")
    var got = try #require(try f.store.versions(videoId: "clip-0").first)
    #expect(got.captionTemplateId == "short" && got.caption == nil && got.style == .outline)
    #expect(throws: EngineError.self) { try b.setCaptionTemplate(["clip-0"], "missing") }
    try b.setHashtagSets(["clip-0"], ["afrobeats"])
    try b.setExtraHashtags(["clip-0"], ["#extra"])
    try b.setPlatform(["clip-0"], .x, skipped: true)
    var e = Edit()
    e.trimIn = 5
    e.coverTime = 6
    var cur = try f.store.edit(videoId: "clip-0")
    cur.trimIn = e.trimIn; cur.coverTime = e.coverTime
    try f.store.save(cur, videoId: "clip-0")
    #expect(try f.store.resolvedEdit(videoId: "clip-0").isSkipped(.x))
    // Apply defaults for caption + trim only: text style stays, cover stays.
    let r = try b.applyDefaults(["clip-0"], sections: [.caption, .trim])
    got = try #require(try f.store.versions(videoId: "clip-0").first)
    #expect(got.captionTemplateId == nil && got.hashtagSetIds == nil && got.extraHashtags == nil && got.style == .outline)
    let ed = try f.store.edit(videoId: "clip-0")
    #expect(ed.trimIn == nil && ed.coverTime == 6 && ed.skippedPlatforms == [.x])
    try b.applyDefaults(["clip-0"], sections: [.platforms, .text, .cover])
    #expect(try f.store.edit(videoId: "clip-0").isEmpty)
    #expect(try f.store.versions(videoId: "clip-0").first.map { $0 == Version(number: 1) } == true)
    try b.undo(r.batchId!, force: true)
    #expect(try f.store.versions(videoId: "clip-0").first?.captionTemplateId == "short")
  }

  @Test func acceptTopSuggestion() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Low", confidence: 0.2),
                                                   SuggestionInput(text: "Yayo x Johnny", tracks: [Track(title: "Yayo")], confidence: 0.9)])
    try f.store.setTitle("clip-1", "Mine")
    try f.store.addSuggestions(videoId: "clip-1", [SuggestionInput(text: "Theirs", confidence: 1)])
    let r = try bulk(f).acceptTopTitleSuggestion(["clip-0", "clip-1", "clip-2"])
    #expect(r.changed == ["clip-0"] && r.skipped["clip-1"] == "already has a title" && r.skipped["clip-2"] == "no suggestions")
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.title == "Yayo x Johnny" && v.titleSource == "suggestion" && v.titleTracks == [Track(title: "Yayo")])
    try bulk(f).undo(r.batchId!)
    #expect(try f.store.video(id: "clip-0")?.title == nil)
  }

  @Test func planActionsAndUndo() throws {
    let f = try Fixture.engine(6)
    let b = bulk(f)
    let before = try f.store.planSlots()
    let r = try b.pinConsecutive(["clip-0", "clip-1"], from: "2026-11-04")
    #expect(r.changed == ["clip-0", "clip-1"])
    let slots = try f.store.planSlots(where: "pinned=1")
    #expect(Set(slots.map { "\($0.videoId)@\($0.date)" }) == ["clip-0@2026-11-04", "clip-1@2026-11-05"])
    try b.undo(r.batchId!)
    #expect(try f.store.planSlots() == before)
    let t = try b.postToday(["clip-4", "clip-5"])
    #expect(t.changed == ["clip-4"] && t.skipped["clip-5"] != nil)  // one post a day
    #expect(try f.store.planSlots(where: "date='2026-11-02' AND video_id='clip-4'").count == 1)
    #expect(try !f.store.posts(where: "video_id='clip-4'").isEmpty)
    try b.undo(t.batchId!)
    #expect(try f.store.planSlots() == before && f.store.posts().isEmpty)
    let w = try b.addToWeek(["clip-2", "clip-3"], week: "2026-11-02")
    #expect(w.changed.count == 2)
    #expect(Set(try f.store.planSlots(where: "pinned=1").map(\.date)) == ["2026-11-02", "2026-11-03"])
    let again = try b.addToWeek(["clip-2"], week: "2026-11-02")
    #expect(again.skipped["clip-2"] == "already planned")
    try b.undo(w.batchId!)
    #expect(try f.store.planSlots() == before)
  }

  @Test func planUndoRefusesWhenSomethingWasPostedSince() throws {
    let f = try Fixture.engine(4)
    let b = bulk(f)
    let t = try b.postToday(["clip-2"])
    let post = try #require(try f.store.posts(where: "video_id='clip-2' AND platform='x'").first)
    try PostActions(store: f.store).markPosted(postId: post.id, url: "https://x.com/djlovdreal/status/1")
    #expect(throws: EngineError.self) { try b.undo(t.batchId!) }
    #expect(try f.store.post(id: post.id)?.state == .posted)
  }

  @Test func reRenderRetiresRendersAndUndoRestoresThem() throws {
    let f = try Fixture.engine(2)
    let fake = FakeRenderer(store: f.store)
    let r1 = try fake.ensureRender(videoId: "clip-0", versionNo: 1, platform: nil)
    let b = bulk(f)
    let r = try b.reRender(["clip-0", "clip-1"])
    #expect(r.changed == ["clip-0"] && r.skipped["clip-1"] == "nothing rendered yet")
    #expect(try f.store.render(id: r1.id)?.deletedAt != nil)
    #expect(try fake.currentRender(videoId: "clip-0", versionNo: 1, platform: nil) == nil)
    try b.undo(r.batchId!)
    #expect(try f.store.render(id: r1.id)?.deletedAt == nil)
  }

  @Test func filters() throws {
    let f = try Fixture.engine(4, ready: 2)
    let b = bulk(f)
    #expect(try b.ids(filter: "ready") == ["clip-0", "clip-1"])
    #expect(try b.ids(filter: "all").count == 4)
    #expect(try b.ids(filter: "unscored") == ["clip-2", "clip-3"])
    #expect(throws: EngineError.self) { try b.ids(filter: "bogus") }
  }
}
