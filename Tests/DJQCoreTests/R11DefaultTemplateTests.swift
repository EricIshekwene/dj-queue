import Foundation
import Testing
@testable import DJQCore

/// v0.8.3: "Set as default" in the editor. Clips with posts keep byte-identical captions, others follow.
@Suite struct R11DefaultTemplateTests {
  @Test func scheduledClipKeepsItsCaptionAndHashAndOthersFollow() throws {
    let f = try Fixture.planned()
    let before = try f.captions("clip-0"), hashes = try f.hashes(), other = try f.captions("clip-1")
    let c = try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    #expect(c.kept == ["clip-0"])
    #expect(try f.store.settings().defaults.captionTemplateId == "short")
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.versions(videoId: "clip-0").first?.captionTemplateId == "set-link")
    #expect(try f.captions("clip-1") != other)
    #expect(try f.store.versions(videoId: "clip-1").first?.captionTemplateId == nil)
  }

  /// What the Postiz hash takes from the render is its id, and that follows the render hash: a pin must not start a new render.
  @Test func renderHashIgnoresTheCaption() throws {
    let f = try Fixture.planned()
    let renderer = Renderer(store: f.store)
    let before = try renderer.editHash(videoId: "clip-0", versionNo: 1, platform: nil)
    try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    #expect(try renderer.editHash(videoId: "clip-0", versionNo: 1, platform: nil) == before)
  }

  @Test func undoRestoresExactly() throws {
    let f = try Fixture.planned()
    let settings = try f.store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json")
    let version = try f.journal("clip-0"), hashes = try f.hashes(), other = try f.captions("clip-1")
    let b = try #require(try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk).result.batchId)
    try f.bulk.undo(b)
    #expect(try f.store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json") == settings)
    #expect(try f.journal("clip-0") == version)
    #expect(try f.hashes() == hashes)
    #expect(try f.captions("clip-1") == other)
  }

  @Test func aPlatformDefaultKeepsItsCaption() throws {
    let f = try Fixture.planned()
    var s = try f.store.settings()
    s.defaults.platformCaptionTemplates = [.instagram: "question"]
    try f.store.save(s)
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    #expect(before[1]?[.instagram] != before[1]?[.tiktok])
    try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.settings().defaults.platformCaptionTemplates == [.instagram: "question"])
    // Pinning alone would have moved Instagram onto the old default.
    #expect(try f.store.versions(videoId: "clip-0").first?.platformCaptions?.keys.sorted() == [.instagram])
    let unscheduled = try f.captions("clip-1")
    #expect(unscheduled[1]?[.instagram] == before[1]?[.instagram]?.replacingOccurrences(of: "clip-0", with: "clip-1"))
  }

  @Test func everyVersionIsHeld() throws {
    let f = try Fixture.planned()
    var v2 = Version(number: 2)
    v2.text = "Second"
    try f.store.save(v2, videoId: "clip-0")
    var v3 = Version(number: 3)
    v3.captionTemplateId = "question"
    try f.store.save(v3, videoId: "clip-0")
    let before = try f.captions("clip-0")
    try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    #expect(try f.captions("clip-0") == before)
    #expect(try f.store.versions(videoId: "clip-0").last?.captionTemplateId == "question")
  }

  @Test func aWrittenCaptionIsLeftAlone() throws {
    let f = try Fixture.planned()
    var v = try #require(try f.store.versions(videoId: "clip-0").first)
    v.caption = "My own words"
    try f.store.save(v, videoId: "clip-0")
    let c = try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    #expect(c.kept.isEmpty)
    #expect(try f.store.versions(videoId: "clip-0").first?.captionTemplateId == nil)
  }

  /// R1's trap: without the rebase, closing the editor would journal the pin as "Edits to X" and its Undo would unpin the clip.
  @Test func anOpenEditorSessionNeverClaimsThePin() throws {
    let f = try Fixture.planned()
    let session = try f.bulk.begin("editor", ids: ["clip-0"])
    try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    #expect(try f.bulk.commit(session).batchId == nil)
    let next = try f.bulk.begin("editor", ids: ["clip-0"])
    try f.store.setTitle("clip-0", "Real edit")
    #expect(try f.bulk.commit(next).changed == ["clip-0"])
  }

  /// Like decision 27: a clip scheduled after the change has taken up the new default.
  @Test func undoIsRefusedWhenAClipScheduledLaterWouldChange() throws {
    let f = try Fixture.planned()
    let b = try #require(try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk).result.batchId)
    try f.store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('later','clip-1','x',1,1,'regular',0,'planned','manual',0,0)
      """)
    let later = try f.captions("clip-1")
    #expect(throws: (any Error).self) { try f.bulk.undo(b) }
    #expect(try f.store.settings().defaults.captionTemplateId == "short")
    #expect(try f.captions("clip-1") == later)
    try f.bulk.undo(b, force: true)
    #expect(try f.store.settings().defaults.captionTemplateId == "set-link")
  }

  @Test func theSameDefaultOrAnUnknownOneChangesNothing() throws {
    let f = try Fixture.planned()
    #expect(try CaptionTemplates.setDefault("set-link", store: f.store, bulk: f.bulk).result.batchId == nil)
    #expect(throws: (any Error).self) { try CaptionTemplates.setDefault("nope", store: f.store, bulk: f.bulk) }
  }
}
