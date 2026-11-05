import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 12: one caption pass over many clips, the template and several hashtag groups in one undoable batch.
@Suite struct R12BulkCaptionTests {
  let lovd = HashtagSet(id: "lovd", name: "DJ lovd", category: "My groups", tags: ["#djlovd"], sort: 1)
  let piano = HashtagSet(id: "piano", name: "Piano", category: "My groups", tags: ["#amapiano"], sort: 2)
  let afro = HashtagSet(id: "afro", name: "Afrobeats", category: "My groups", tags: ["#afrobeats"], sort: 3)
  let mash = HashtagSet(id: "mash", name: "General mashup", category: "My groups", tags: ["#djtransition", "#mashup", "#mix"], sort: 4)
  let plain = CaptionTemplate(id: "plain", name: "Text + hashtags", template: "{text}\n\n{hashtags}", sort: 9)

  func setUp() throws -> (Fixture, BulkActions) {
    let f = try Fixture()
    try f.intake()
    for s in [lovd, piano, afro, mash] { try f.store.save(s) }
    try f.store.save(plain)
    try f.store.setTitle("clip-0", "Boots x Rider")
    try f.store.setTitle("clip-2", "Yayo x Johnny")
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    return (f, b)
  }

  func caption(_ f: Fixture, _ id: String) throws -> String {
    let v = try #require(try f.store.video(id: id))
    let r = try #require(try f.store.resolvedVersion(videoId: id, number: 1))
    return Captions.sharedCaption(version: r, video: v, sessionName: try f.store.sessionName(for: v), sets: try f.store.hashtagSets(),
                                  templates: try f.store.captionTemplates(), settings: try f.store.settings())
  }

  /// Eric's ask: every selected clip gets text plus DJ lovd, General mashup and Afrobeats, in that order.
  @Test func templatePlusSeveralGroupsIsOneBatch() throws {
    let (f, b) = try setUp()
    let r = try b.setCaption(["clip-0", "clip-2"], CaptionChange(template: .use("plain"), addGroups: ["lovd", "mash", "afro"]))
    #expect(Set(r.changed) == ["clip-0", "clip-2"] && r.batchId != nil)
    #expect(try caption(f, "clip-0") == "Boots x Rider\n\n#djlovd #djtransition #mashup #mix #afrobeats")
    #expect(try caption(f, "clip-2") == "Yayo x Johnny\n\n#djlovd #djtransition #mashup #mix #afrobeats")
    #expect(try f.store.db.one("SELECT count(*) AS n FROM batches")?.int("n") == 1)
    _ = try b.undo(try #require(r.batchId))
    #expect(try f.store.versions(videoId: "clip-0").allSatisfy { $0.captionTemplateId == nil && $0.hashtagSetIds == nil })
  }

  /// The old menu replaced the groups, so a second pick wiped the first.
  @Test func addingAGroupKeepsTheClipsOtherGroups() throws {
    let (f, b) = try setUp()
    try b.setHashtagSets(["clip-0"], ["piano"])
    try b.setCaption(["clip-0", "clip-2"], CaptionChange(addGroups: ["lovd"]))
    try b.setCaption(["clip-0", "clip-2"], CaptionChange(addGroups: ["mash"]))
    #expect(try f.store.resolvedVersion(videoId: "clip-0", number: 1)?.hashtagSetIds == ["piano", "lovd", "mash"])
    #expect(try f.store.resolvedVersion(videoId: "clip-2", number: 1)?.hashtagSetIds == ["lovd", "mash"])
    try b.setCaption(["clip-0"], CaptionChange(removeGroups: ["piano"]))
    #expect(try f.store.resolvedVersion(videoId: "clip-0", number: 1)?.hashtagSetIds == ["lovd", "mash"])
  }

  /// With no template picked, a caption Eric wrote keeps its words and only its hashtags change.
  @Test func keepingCaptionsSwapsTagsInPlace() throws {
    let (f, b) = try setUp()
    try b.setHashtagSets(["clip-0"], ["lovd"])
    var v = try #require(try f.store.versions(videoId: "clip-0").first)
    v.caption = "My own words\n\n#djlovd"
    try f.store.save(v, videoId: "clip-0")
    let p = try b.previewCaption(["clip-0"], CaptionChange(addGroups: ["afro"]))
    #expect(p.first?.caption == "My own words\n\n#djlovd #afrobeats" && p.first?.replacesWritten == false)
    try b.setCaption(["clip-0"], CaptionChange(addGroups: ["afro"]))
    #expect(try caption(f, "clip-0") == "My own words\n\n#djlovd #afrobeats")
  }

  @Test func aTemplateReplacesAWrittenCaptionAndSaysSo() throws {
    let (f, b) = try setUp()
    try f.store.save({ var v = Version(number: 1); v.caption = "Written by hand"; return v }(), videoId: "clip-0")
    let change = CaptionChange(template: .use("plain"))
    #expect(try b.previewCaption(["clip-0", "clip-2"], change).map(\.replacesWritten) == [true, false])
    try b.setCaption(["clip-0"], change)
    #expect(try caption(f, "clip-0") == "Boots x Rider")
  }

  /// The dialog shows what will be written, byte for byte.
  @Test func previewMatchesWhatApplyWrites() throws {
    let (f, b) = try setUp()
    try f.store.save({ var v = Version(number: 1); v.caption = "Mine\n#djlovd"; v.hashtagSetIds = ["lovd"]; return v }(), videoId: "clip-2")
    let ids = ["clip-0", "clip-2", "clip-3"]
    for change in [CaptionChange(template: .use("plain"), addGroups: ["mash", "afro"]), CaptionChange(addGroups: ["afro"]),
                   CaptionChange(removeGroups: ["lovd"]), CaptionChange(template: .useDefault)] {
      let p = try b.previewCaption(ids, change)
      let dry = try b.setCaption(ids, change, dryRun: true)
      #expect(Set(p.filter(\.changes).map(\.id)) == Set(dry.changed))
      try b.setCaption(ids, change)
      for row in p { #expect(row.caption == (try caption(f, row.id))) }
    }
  }

  @Test func clipsWithPostsStayByteIdentical() throws {
    let (f, b) = try setUp()
    try f.store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('held','clip-0','tiktok',1,1,'regular',0,'planned','manual',0,0)
      """)
    let before = try caption(f, "clip-0")
    let change = CaptionChange(template: .use("plain"), addGroups: ["lovd"])
    let r = try b.setCaption(["clip-0", "clip-2"], change)
    #expect(r.changed == ["clip-2"] && r.skipped["clip-0"] == BulkActions.captionHeldReason)
    #expect(try caption(f, "clip-0") == before)
    #expect(try b.previewCaption(["clip-0"], change).first?.skipped == BulkActions.captionHeldReason)
    let use = try b.groupUse(["clip-0", "clip-2"])
    #expect(use.total == 1 && use.counts["lovd"] == 1)
  }

  @Test func chipClicksCycleAndRememberOrder() {
    var c = CaptionChange()
    // Off on every clip: on, then back.
    c.toggle("a", count: 0, total: 4)
    #expect(c.addGroups == ["a"] && c.mark("a", count: 0, total: 4) == .all)
    c.toggle("a", count: 0, total: 4)
    #expect(c.isEmpty)
    // On for some: on for all, off for all, back to as it was.
    c.toggle("a", count: 2, total: 4)
    #expect(c.addGroups == ["a"])
    c.toggle("a", count: 2, total: 4)
    #expect(c.removeGroups == ["a"] && c.addGroups.isEmpty && c.mark("a", count: 2, total: 4) == .none)
    c.toggle("a", count: 2, total: 4)
    #expect(c.isEmpty && c.mark("a", count: 2, total: 4) == .some)
    // On for all: off, then back.
    c.toggle("a", count: 4, total: 4)
    #expect(c.removeGroups == ["a"])
    c.toggle("a", count: 4, total: 4)
    #expect(c.isEmpty)
    // Click order is caption order.
    c.toggle("b", count: 0, total: 4)
    c.toggle("a", count: 0, total: 4)
    #expect(c.addGroups == ["b", "a"])
  }

  @Test func tooLongIsReportedPerPlatform() throws {
    let (f, b) = try setUp()
    var s = try f.store.settings()
    s.limits[.x]?.captionLimit = 20
    try f.store.save(s)
    let p = try b.previewCaption(["clip-0"], CaptionChange(template: .use("plain"), addGroups: ["lovd", "mash"]))
    #expect(p.first?.tooLong.contains(.x) == true)
  }

  @Test func unknownTemplateOrGroupIsRefused() throws {
    let (_, b) = try setUp()
    #expect(throws: EngineError.self) { try b.setCaption(["clip-0"], CaptionChange(template: .use("nope"))) }
    #expect(throws: EngineError.self) { try b.setCaption(["clip-0"], CaptionChange(addGroups: ["nope"])) }
  }
}
