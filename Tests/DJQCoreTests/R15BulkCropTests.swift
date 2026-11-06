import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 15: one crop offset for many horizontally filmed clips, one batch.
@Suite struct R15BulkCropTests {
  let source = CGSize(width: 3840, height: 2160)

  func setUp() throws -> (Fixture, BulkActions) {
    let f = try Fixture()
    try f.intake()
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    return (f, b)
  }

  @Test func theOffsetMovesTheCentreAndKeepsSize() {
    let base = CropRect(x: 1312, y: 0, w: 1216, h: 2160)
    #expect(CropChange.moved(base, offset: 0, source: source) == base)
    #expect(CropChange.moved(base, offset: 0.1, source: source).x == 1696)
    #expect(CropChange.moved(base, offset: -0.1, source: source).x == 928)
    #expect(CropChange.moved(base, offset: 0.1, source: source).w == 1216)
    #expect(abs(CropChange.offset(of: CropChange.moved(base, offset: 0.1, source: source), source: source) - 0.1) < 0.001)
  }

  @Test func itNeverLeavesTheFrame() {
    let base = CropRect(x: 1312, y: 0, w: 1216, h: 2160)
    #expect(CropChange.moved(base, offset: 0.9, source: source).x == 2624)
    #expect(CropChange.moved(base, offset: -0.9, source: source).x == 0)
  }

  /// A zoomed crop keeps its zoom and height.
  @Test func aZoomedCropKeepsItsSizeAndHeight() {
    let base = CropRect(x: 1000, y: 200, w: 800, h: 1422)
    let c = CropChange.moved(base, offset: 0.05, source: source)
    #expect(c.w == 800 && c.h == 1422 && c.y == 200)
  }

  @Test func oneBatchSetsEveryClipAndUndoGoesBack() throws {
    let (f, b) = try setUp()
    let r = try b.setCropOffset(["clip-0", "clip-2"], CropChange(offset: 0.1))
    #expect(Set(r.changed) == ["clip-0", "clip-2"] && r.batchId != nil)
    #expect(try f.store.edit(videoId: "clip-0").crop?.x == 1696)
    #expect(try f.store.edit(videoId: "clip-2").crop?.x == 1696)
    _ = try b.undo(try #require(r.batchId))
    #expect(try f.store.edit(videoId: "clip-0").crop == nil)
  }

  @Test func aClipWithACropKeepsItUntilAsked() throws {
    let (f, b) = try setUp()
    var e = Edit()
    e.crop = CropRect(x: 2000, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    let keep = try b.setCropOffset(["clip-0", "clip-2"], CropChange(offset: 0.1))
    #expect(keep.changed == ["clip-2"] && keep.skipped.isEmpty)
    #expect(try f.store.edit(videoId: "clip-0").crop?.x == 2000)
    #expect(try b.previewCrop(["clip-0"], CropChange(offset: 0.1)).first?.keepsOwn == true)
    try b.setCropOffset(["clip-0"], CropChange(offset: 0.1, movesOwnCrops: true))
    #expect(try f.store.edit(videoId: "clip-0").crop?.x == 1696)
  }

  /// Dragging one clip wins over the slider, even on a clip that had a crop.
  @Test func anAdjustedClipGoesItsOwnWay() throws {
    let (f, b) = try setUp()
    var e = Edit()
    e.crop = CropRect(x: 2000, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    try b.setCropOffset(["clip-0", "clip-2"], CropChange(offset: 0.1, overrides: ["clip-0": -0.1]))
    #expect(try f.store.edit(videoId: "clip-0").crop?.x == 928)
    #expect(try f.store.edit(videoId: "clip-2").crop?.x == 1696)
  }

  /// The dialog shows what will be written, byte for byte.
  @Test func previewMatchesWhatApplyWrites() throws {
    let (f, b) = try setUp()
    var e = Edit()
    e.crop = CropRect(x: 2000, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-3")
    let ids = ["clip-0", "clip-2", "clip-3"]
    let change = CropChange(offset: -0.07, overrides: ["clip-2": 0.03])
    let p = try b.previewCrop(ids, change)
    let dry = try b.setCropOffset(ids, change, dryRun: true)
    #expect(Set(p.filter(\.changes).map(\.id)) == Set(dry.changed))
    try b.setCropOffset(ids, change)
    for row in p { #expect(row.crop == (try f.store.edit(videoId: row.id).crop)) }
  }

  /// Eric's 22 scheduled clips can still be fixed; one that went out can't.
  @Test func scheduledClipsMoveAndClipsThatWentOutStay() throws {
    let (f, b) = try setUp()
    func post(_ id: String, _ video: String, _ state: String) throws {
      try f.store.db.run("""
        INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
        VALUES(?,?,'tiktok',1,1,'regular',0,?,'manual',0,0)
        """, [id, video, state])
    }
    try post("p0", "clip-0", "planned")
    try post("p2", "clip-2", "posted")
    let r = try b.setCropOffset(["clip-0", "clip-2"], CropChange(offset: 0.1))
    #expect(r.changed == ["clip-0"] && r.skipped["clip-2"] != nil)
    #expect(try f.store.edit(videoId: "clip-2").crop == nil)
    let p = try b.previewCrop(["clip-0"], CropChange(offset: 0.2, movesOwnCrops: true))
    #expect(p.first?.scheduled == true && p.first?.changes == true)
  }

  /// The one door to the Queue stays Send to Queue: a confirmed crop alone doesn't promote a clip.
  @Test func cropAloneNeverSendsAClipToTheQueue() throws {
    let (f, b) = try setUp()
    try f.store.setScore("clip-0", 50)
    try f.store.setTitle("clip-0", "Boots x Rider")
    try b.setCropOffset(["clip-0"], CropChange(offset: 0.1))
    #expect(try f.store.video(id: "clip-0")?.sentToQueue == false)
  }
}
