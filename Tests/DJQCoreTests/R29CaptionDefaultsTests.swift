import Foundation
import Testing
@testable import DJQCore

/// Round 29: "Make default…" in the editor's Caption section. New clips start with the choice; existing clips keep what
/// they post unless Eric asks the ones without posts to follow; clips with posts are always byte-identical.
@Suite struct R29CaptionDefaultsTests {
  private func withGroup(_ f: Fixture) throws {
    try f.store.save(HashtagSet(id: "piano", name: "Piano", category: "Mine", tags: ["#amapiano", "#piano"], sort: 0))
  }

  private var choice: CaptionDefaults.Choice {
    CaptionDefaults.Choice(captionTemplateId: "short", youtubeTitleTemplateId: nil, hashtagSetIds: ["piano"], extraHashtags: ["#djlovd"],
                           platforms: [.tiktok, .instagram])
  }

  private func titles(_ f: Fixture, _ id: String) throws -> [String] {
    let v = try #require(try f.store.video(id: id))
    let s = try f.store.settings()
    let vs = try f.store.versions(videoId: id)
    return [1].map { Captions.youtubeTitle(VersionResolver.resolve(vs, number: $0, settings: s, video: v), video: v, settings: s) }
  }

  private func posting(_ f: Fixture, _ id: String) throws -> [Platform] {
    let d = try f.store.settings().defaults
    let e = try f.store.edit(videoId: id)
    return Platform.allCases.filter { !e.isSkipped($0, defaults: d) }
  }

  @Test func existingClipsKeepEverythingByDefault() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    let ids = ["clip-0", "clip-1", "clip-2"]
    let captions = try ids.map { try f.captions($0) }, hashes = try f.hashes(), where_ = try ids.map { try posting(f, $0) }
    let reach = try CaptionDefaults.reach(choice, store: f.store)
    #expect(reach.held == ["clip-0"])
    #expect(Set(reach.follow) == ["clip-1", "clip-2"])
    let c = try CaptionDefaults.save(choice, updateExisting: false, store: f.store, bulk: f.bulk)
    #expect(Set(c.kept) == Set(ids))
    let d = try f.store.settings().defaults
    #expect(d.captionTemplateId == "short" && d.hashtagSetIds == ["piano"] && d.extraHashtags == ["#djlovd"])
    #expect(d.platforms == [.tiktok, .instagram])
    #expect(try ids.map { try f.captions($0) } == captions)
    #expect(try ids.map { try posting(f, $0) } == where_)
    #expect(try f.hashes() == hashes)
    // Pinned explicitly, not as a platform's own caption: the clip still reads as a template caption.
    let v1 = try #require(try f.store.versions(videoId: "clip-1").first)
    #expect(v1.captionTemplateId == "set-link" && v1.hashtagSetIds == [] && v1.extraHashtags == [])
    #expect(v1.platformCaptions == nil || v1.platformCaptions?.isEmpty == true)
  }

  @Test func aNewClipStartsWithTheChoice() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    try CaptionDefaults.save(choice, updateExisting: false, store: f.store, bulk: f.bulk)
    let v = try #require(try f.store.video(id: "clip-2"))
    // A clip with no versions and no edit stands in for one found after the change.
    try f.store.db.run("DELETE FROM versions WHERE video_id=?", ["clip-2"])
    try f.store.db.run("DELETE FROM edits WHERE video_id=?", ["clip-2"])
    let s = try f.store.settings()
    let r = VersionResolver.resolve([], number: 1, settings: s, video: v)
    #expect(r.captionTemplateId == nil && r.hashtagSetIds == ["piano"] && r.extraHashtags == ["#djlovd"])
    #expect(Captions.output(.tiktok, r, v, "", try f.store.hashtagSets(), try f.store.captionTemplates(), s).contains("#piano"))
    #expect(Set(try posting(f, "clip-2")) == [.tiktok, .instagram])
  }

  @Test func updateExistingMovesOnlyClipsWithoutPosts() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    let held = try f.captions("clip-0"), hashes = try f.hashes(), heldWhere = try posting(f, "clip-0"), other = try f.captions("clip-1")
    let c = try CaptionDefaults.save(choice, updateExisting: true, store: f.store, bulk: f.bulk)
    #expect(c.kept == ["clip-0"])
    #expect(try f.captions("clip-0") == held)
    #expect(try f.hashes() == hashes)
    #expect(try posting(f, "clip-0") == heldWhere)
    #expect(try f.captions("clip-1") != other)
    #expect(try f.captions("clip-1")[1]?[.tiktok]?.contains("#piano #djlovd") == true)
    #expect(Set(try posting(f, "clip-1")) == [.tiktok, .instagram])
  }

  @Test func undoRestoresExactly() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    let settings = try f.store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json")
    let journals = try ["clip-0", "clip-1"].map { try f.journal($0) }, hashes = try f.hashes()
    let b = try #require(try CaptionDefaults.save(choice, updateExisting: false, store: f.store, bulk: f.bulk).result.batchId)
    try f.bulk.undo(b)
    #expect(try f.store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json") == settings)
    #expect(try ["clip-0", "clip-1"].map { try f.journal($0) } == journals)
    #expect(try f.hashes() == hashes)
  }

  @Test func aYouTubeTitleTemplateIsHeldToo() throws {
    let f = try Fixture.planned()
    var s = try f.store.settings()
    s.youtubeTitleTemplates.append(TitleTemplate(id: "plain", name: "Plain", template: "{text} plain"))
    try f.store.save(s)
    let before = try titles(f, "clip-1")
    try CaptionDefaults.save(CaptionDefaults.Choice(youtubeTitleTemplateId: "plain"), updateExisting: false, store: f.store, bulk: f.bulk)
    #expect(try f.store.settings().defaults.youtubeTitleTemplateId == "plain")
    #expect(try titles(f, "clip-1") == before)
    #expect(try f.store.versions(videoId: "clip-1").first?.youtubeTitleTemplateId == s.defaults.youtubeTitleTemplateId)
  }

  @Test func writtenCaptionsAndOwnChoicesAreLeftAlone() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.caption = "My own words"
    v.hashtagSetIds = ["piano"]
    try f.store.save(v, videoId: "clip-1")
    var e = try f.store.edit(videoId: "clip-1")
    e.skippedPlatforms = [.youtube]
    try f.store.save(e, videoId: "clip-1")
    let p = try CaptionDefaults.pin(try #require(try f.store.video(id: "clip-1")), from: try f.store.settings(),
                                    to: CaptionDefaults.Choice(captionTemplateId: "short", hashtagSetIds: ["piano"], platforms: [.tiktok, .instagram, .facebook, .threads, .x])
                                      .applied(to: try f.store.settings().defaults), store: f.store)
    #expect(p == nil)
  }

  @Test func nothingToChangeIsANoOp() throws {
    let f = try Fixture.planned()
    let d = try f.store.settings().defaults
    let c = try CaptionDefaults.save(CaptionDefaults.Choice(captionTemplateId: d.captionTemplateId), updateExisting: false, store: f.store, bulk: f.bulk)
    #expect(c.result.batchId == nil && c.kept.isEmpty)
  }

  @Test func unknownIdsAreRefused() throws {
    let f = try Fixture.planned()
    #expect(throws: EngineError.self) {
      try CaptionDefaults.save(CaptionDefaults.Choice(hashtagSetIds: ["nope"]), updateExisting: false, store: f.store, bulk: f.bulk)
    }
    #expect(throws: EngineError.self) {
      try CaptionDefaults.save(CaptionDefaults.Choice(captionTemplateId: "nope"), updateExisting: false, store: f.store, bulk: f.bulk)
    }
  }

  /// The clip the choice came from reads "Default" afterwards, posts the same, and Undo puts its own values back.
  @Test func theSourceClipFollowsTheNewDefaults() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.captionTemplateId = "short"
    v.hashtagSetIds = ["piano"]
    v.extraHashtags = ["#djlovd"]
    try f.store.save(v, videoId: "clip-1")
    var e = try f.store.edit(videoId: "clip-1")
    e.skippedPlatforms = [.x, .threads]
    try f.store.save(e, videoId: "clip-1")
    let journal = try f.journal("clip-1"), captions = try f.captions("clip-1"), where_ = try posting(f, "clip-1")
    let c = try CaptionDefaults.save(choice.with(platforms: Set(where_)), updateExisting: false, source: ("clip-1", 1), store: f.store, bulk: f.bulk)
    #expect(!c.kept.contains("clip-1"))
    #expect(try f.captions("clip-1") == captions)
    #expect(try posting(f, "clip-1") == where_)
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-1", number: 1))
    #expect(r.isDefault("captionTemplateId") && r.isDefault("hashtagSetIds") && r.isDefault("extraHashtags"))
    let after = try f.store.edit(videoId: "clip-1")
    #expect(after.skippedPlatforms.isEmpty && after.includedPlatforms.isEmpty)
    try f.bulk.undo(try #require(c.result.batchId))
    #expect(try f.journal("clip-1") == journal)
  }

  /// Review r29 #1: a version that chose a title template that was later deleted follows the default one, so it's held too.
  @Test func aDeletedTitleTemplateIsHeld() throws {
    let f = try Fixture.planned()
    var s = try f.store.settings()
    s.youtubeTitleTemplates.append(TitleTemplate(id: "plain", name: "Plain", template: "{text} plain"))
    try f.store.save(s)
    for id in ["clip-0", "clip-1"] {
      var v = try #require(try f.store.versions(videoId: id).first)
      v.youtubeTitleTemplateId = "gone"
      try f.store.save(v, videoId: id)
    }
    let before = try ["clip-0", "clip-1"].map { try titles(f, $0) }, hashes = try f.hashes()
    for update in [false, true] {
      let c = try CaptionDefaults.save(CaptionDefaults.Choice(youtubeTitleTemplateId: update ? s.defaults.youtubeTitleTemplateId : "plain"),
                                       updateExisting: false, store: f.store, bulk: f.bulk)
      if !update { #expect(c.kept.contains("clip-0") && c.kept.contains("clip-1")) }
      #expect(try ["clip-0", "clip-1"].map { try titles(f, $0) } == before)
      #expect(try f.hashes() == hashes)
    }
  }

  /// Review r29 #2: with the switch on, a source clip without posts saves even when its other versions follow the old defaults;
  /// its source version posts the same and its other versions follow, with no own captions frozen in.
  @Test func followModeWithASourceOfSeveralVersions() throws {
    let f = try Fixture.planned()
    try withGroup(f)
    var v2 = Version(number: 2)
    v2.text = "Second"
    v2.hashtagSetIds = ["piano"]
    v2.captionTemplateId = "short"
    try f.store.save(v2, videoId: "clip-1")
    let source = try f.captions("clip-1")[2]
    try CaptionDefaults.save(CaptionDefaults.Choice(captionTemplateId: "short", hashtagSetIds: ["piano"]), updateExisting: true,
                             source: ("clip-1", 2), store: f.store, bulk: f.bulk)
    let now = try f.captions("clip-1")
    #expect(now[2] == source)
    #expect(now[1]?[.tiktok]?.contains("#piano") == true)
    #expect(try f.store.versions(videoId: "clip-1").allSatisfy { ($0.platformCaptions ?? [:]).isEmpty })
  }

  /// Review r29 #5: a photo post isn't pinned for a YouTube title template it never uses.
  @Test func aPhotoPostIgnoresTheTitleTemplate() throws {
    let f = try Fixture.planned()
    var s = try f.store.settings()
    s.youtubeTitleTemplates.append(TitleTemplate(id: "plain", name: "Plain", template: "{text} plain"))
    try f.store.save(s)
    let photo = try #require(try f.store.video(id: "clip-2"))
    var p = photo
    p.photos = [PhotoItem(file: "a.jpg", width: 1080, height: 1350)]
    let pinned = try CaptionDefaults.pin(p, from: s, to: CaptionDefaults.Choice(youtubeTitleTemplateId: "plain").applied(to: s.defaults), store: f.store)
    #expect(pinned == nil)
    #expect(try CaptionDefaults.pin(photo, from: s, to: CaptionDefaults.Choice(youtubeTitleTemplateId: "plain").applied(to: s.defaults), store: f.store) != nil)
  }
}

private extension CaptionDefaults.Choice {
  func with(platforms: Set<Platform>) -> Self { var c = self; c.platforms = platforms; return c }
}
