import Foundation
import Testing
@testable import DJQCore

/// v0.8.3 review fixes.
@Suite struct R11ReviewFixTests {
  func state(_ f: Fixture, _ s: PostState) throws { try f.store.db.run("UPDATE platform_posts SET state=? WHERE video_id='clip-0'", [s.rawValue]) }

  func groups(_ f: Fixture) throws {
    for (i, id) in ["a", "b"].enumerated() {
      try f.store.save(HashtagSet(id: id, name: id, category: "My groups", tags: ["#\(id)"], sort: i))
    }
  }

  func defaults(_ f: Fixture, _ change: (inout NewClipDefaults) -> Void) throws -> HashtagGroups.Change {
    var d = try f.store.settings().defaults
    change(&d)
    return try CaptionTemplates.saveDefaults(d, store: f.store, bulk: f.bulk)
  }

  // MARK: H1 New clip defaults

  @Test(arguments: [PostState.planned, .posted, .copyrightMuted])
  func aNewDefaultTemplateHoldsClipsWithPosts(_ s: PostState) throws {
    let f = try Fixture.planned()
    try state(f, s)
    let before = try f.captions("clip-0"), hashes = try f.hashes(), other = try f.captions("clip-1")
    let c = try defaults(f) { $0.captionTemplateId = "short" }
    #expect(c.kept == ["clip-0"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.versions(videoId: "clip-0").first?.captionTemplateId == "set-link")
    #expect(try f.captions("clip-1") != other)
  }

  @Test func aPlatformDefaultTemplateHoldsClipsWithPosts() throws {
    let f = try Fixture.planned()
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    try defaults(f) { $0.platformCaptionTemplates = [.instagram: "question"] }
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.captions("clip-1")[1]?[.instagram]?.contains("Who knows") == true)
  }

  @Test func defaultGroupsHoldTheYouTubeTagsToo() throws {
    let f = try Fixture.planned()
    try groups(f)
    try defaults(f) { $0.hashtagSetIds = ["a"] }
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    let tags = Captions.hashtags(r, sets: try f.store.hashtagSets())
    try defaults(f) { $0.hashtagSetIds = ["b"] }
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    let after = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.hashtags(after, sets: try f.store.hashtagSets()) == tags)
  }

  @Test func theYouTubeTitleTemplateHoldsToo() throws {
    let f = try Fixture.planned()
    var s = try f.store.settings()
    s.youtubeTitleTemplates.append(TitleTemplate(id: "live", name: "Live", template: "{text} (live)"))
    try f.store.save(s)
    let hashes = try f.hashes()
    try defaults(f) { $0.youtubeTitleTemplateId = "live" }
    #expect(try f.hashes() == hashes)
  }

  @Test func resetHoldsAndUndoRestoresExactly() throws {
    let f = try Fixture.planned()
    try CaptionTemplates.setDefault("short", store: f.store, bulk: f.bulk)
    try f.store.db.run("UPDATE platform_posts SET video_id='clip-1' WHERE video_id='clip-0'")
    let version = try f.journal("clip-1"), hashes = try f.hashes("clip-1"), row = try f.store.settings()
    let c = try CaptionTemplates.saveDefaults(NewClipDefaults(), store: f.store, bulk: f.bulk)
    #expect(try f.hashes("clip-1") == hashes)
    try f.bulk.undo(#require(c.result.batchId))
    #expect(try f.journal("clip-1") == version)
    #expect(try f.hashes("clip-1") == hashes)
    #expect(try f.store.settings() == row)
  }

  @Test func anOpenEditorSessionNeverClaimsAndUndoChecksConflicts() throws {
    let f = try Fixture.planned()
    let session = try f.bulk.begin("editor", ids: ["clip-0"])
    let b = try #require(try defaults(f) { $0.captionTemplateId = "short" }.result.batchId)
    #expect(try f.bulk.commit(session).batchId == nil)
    try f.store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('later','clip-1','x',1,1,'regular',0,'planned','manual',0,0)
      """)
    #expect(throws: (any Error).self) { try f.bulk.undo(b) }
  }

  // MARK: H2 unsaved memory

  @Test func aHoldComesAcrossAndUnsavedWorkStays() {
    var base = Version(number: 1)
    base.text = "T"
    var memory = base
    memory.size = 0.5
    var saved = base
    saved.caption = "Held {hashtags}"
    saved.captionTemplateId = "old"
    saved.platformCaptions = [.threads: "Held"]
    for b in [[base], nil] as [[Version]?] {
      let merged = HashtagGroups.keepingFreeze(memory: [memory], saved: [saved], base: b)?.first
      #expect(merged?.size == 0.5)
      #expect(merged?.caption == "Held {hashtags}" && merged?.captionTemplateId == "old" && merged?.platformCaptions == [.threads: "Held"])
    }
  }

  @Test func withABaseEricsOwnEditIsntMistakenForAHold() {
    let base = Version(number: 1)
    var memory = base
    memory.caption = "Typed and not saved yet"
    var saved = base
    saved.captionTemplateId = "old"
    let merged = HashtagGroups.keepingFreeze(memory: [memory], saved: [saved], base: [base])?.first
    #expect(merged?.caption == "Typed and not saved yet" && merged?.captionTemplateId == "old")
    #expect(HashtagGroups.keepingFreeze(memory: [memory], saved: [base], base: [base]) == nil)
  }

  // MARK: H3, M3 parts

  @Test func goneOutLocksPartsAndScheduledDoesnt() throws {
    let f = try Fixture.planned()
    let any = try #require(try f.store.posts(where: "video_id='clip-0'", [], order: "id").first)
    func post(_ s: PostState) -> PlatformPost {
      var p = any
      p.state = s
      return p
    }
    for s in [PostState.posted, .copyrightBlocked, .copyrightMuted, .removed] { #expect(CaptionParts.lockReason(posts: [post(s)]) != nil) }
    for s in [PostState.planned, .rendering, .rendered, .due, .overdue, .failed, .skipped] { #expect(CaptionParts.lockReason(posts: [post(s)]) == nil) }
  }

  @Test func bulkTogglesPartsWithTheSameRule() throws {
    let f = try Fixture.planned()
    try state(f, .posted)
    let posted = try f.captions("clip-0")
    let r = try f.bulk.togglePart(["clip-0", "clip-1", "nope"], .title)
    #expect(try f.store.versions(videoId: "clip-1").first?.caption == nil, "no title yet, so nothing changes")
    #expect(r.skipped["clip-0"]?.contains("gone out") == true)
    try f.store.setTitle("clip-1", "Song")
    let on = try f.bulk.togglePart(["clip-0", "clip-1"], .title)
    #expect(on.changed == ["clip-1"])
    #expect(try f.captions("clip-1")[1]?[.x]?.contains("Song") == true)
    #expect(try f.captions("clip-0") == posted)
    try f.bulk.undo(#require(on.batchId))
    #expect(try f.store.versions(videoId: "clip-1").first?.caption == nil)
    #expect(try f.bulk.togglePart(["clip-1"], .title, dryRun: true).dryRun)
  }

  @Test func aChipOnAScheduledClipIsAnEdit() throws {
    let f = try Fixture.planned()
    try f.store.setTitle("clip-0", "Song")
    #expect(try f.bulk.togglePart(["clip-0"], .title).changed == ["clip-0"])
    #expect(try f.store.versions(videoId: "clip-0").first?.caption?.contains("Song") == true)
  }

  // MARK: M1, L1 moves

  @Test func aMoveReordersTheDefaultGroupsAndHoldsClipsWithPosts() throws {
    let f = try Fixture.planned()
    try groups(f)
    try defaults(f) { $0.hashtagSetIds = ["a", "b"] }
    let before = try f.captions("clip-0"), hashes = try f.hashes(), defaultsBefore = try f.store.settings().defaults.hashtagSetIds
    let c = try HashtagGroups.move("b", by: -1, store: f.store, bulk: f.bulk)
    #expect(try f.store.settings().defaults.hashtagSetIds == ["b", "a"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-1", number: 1))
    #expect(Captions.hashtags(r, sets: try f.store.hashtagSets()) == ["#b", "#a"])
    try f.bulk.undo(#require(c.result.batchId))
    #expect(try f.store.settings().defaults.hashtagSetIds == defaultsBefore)
    #expect(try f.store.hashtagSets().map(\.id) == ["a", "b"])
    #expect(try f.hashes() == hashes)
  }

  @Test func aMoveAcrossCategoriesDoesMove() throws {
    let f = try Fixture.planned()
    try f.store.save(HashtagSet(id: "x", name: "X", category: "Dj", tags: ["#x"], sort: 0))
    try f.store.save(HashtagSet(id: "y", name: "Y", category: "My groups", tags: ["#y"], sort: 1))
    #expect(try HashtagGroups.move("y", by: -1, store: f.store, bulk: f.bulk).result.batchId != nil)
    #expect(try f.store.hashtagSets().map(\.id) == ["y", "x"])
  }

  // MARK: M2, L3, L4, L5

  @Test func theWordsSayWhatHappened() throws {
    let note = Captions.CapNote(platform: .threads, cap: 1, total: 4, dropped: [], own: true, scheduled: true)
    #expect(note.message.hasPrefix("Threads keeps this clip's scheduled caption"))
    #expect(!note.message.contains("wrote"))
    var change = HashtagGroups.Change(result: BulkResult(batchId: nil, action: "", dryRun: false, videoIds: [], changed: [], skipped: [:], remainingIssues: [:], summary: ""), kept: [])
    #expect(change.keptNote == "")
    change.kept = ["a"]
    #expect(change.keptNote == ". 1 clip with scheduled or posted posts keeps its caption")
    change.kept = ["a", "b"]
    #expect(change.keptNote == ". 2 clips with scheduled or posted posts keep their captions")
  }

  @Test func addedTemplatesGetTheirOwnNames() {
    let t = { (n: String) in CaptionTemplate(id: n, name: n, template: "x", sort: 0) }
    #expect(CaptionTemplates.uniqueName("New template", existing: [t("Other")]) == "New template")
    #expect(CaptionTemplates.uniqueName("New template", existing: [t("New template"), t("New template 2")]) == "New template 3")
  }

  @Test func aNumberIsntAHashtag() {
    #expect(Captions.capped("Track #1 live #a #b", to: 1).text == "Track #1 live #a")
    #expect(Captions.capped("Track #1 live #a #b", to: 1).dropped == ["#b"])
    #expect(Captions.tags(in: "#1 #2024 #a1 #1a #_x") == ["#a1", "#1a", "#_x"])
    #expect(Captions.isHashtagLine("#a #b") && !Captions.isHashtagLine("#1 #2"))
  }

  @Test func aOneWordPartHasToStandAlone() {
    let v = CaptionParts.Values(text: "Long overlay text", set: "Set", link: "L", title: "Fire")
    #expect(!CaptionParts.isOn(.title, in: "pure fire tonight", v))
    #expect(!CaptionParts.isOn(.title, in: "Pure Fire tonight", v))
    #expect(CaptionParts.isOn(.title, in: "Fire\n\n#a", v))
    #expect(CaptionParts.isOn(.title, in: "Fire — live at the set", v))
    #expect(CaptionParts.isOn(.title, in: "🎧 Fire #a", v))
    #expect(CaptionParts.isOn(.set, in: "🎧 Set — full set", v))
    #expect(CaptionParts.toggled(.title, in: "pure fire tonight", v) == "pure fire tonight\nFire")
    let on = CaptionParts.toggled(.title, in: "#a", v)
    #expect(CaptionParts.toggled(.title, in: on, v) == "#a")
  }
}
