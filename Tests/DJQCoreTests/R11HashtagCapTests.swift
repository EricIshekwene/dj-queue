import Foundation
import Testing
@testable import DJQCore

/// v0.8.3: the order in the caption is the priority; a platform's cap keeps the first tags.
@Suite struct R11HashtagCapTests {
  func caption(_ f: Fixture, _ id: String, _ p: Platform) throws -> String { try #require(try f.captions(id)[1]?[p]) }

  /// Written captions, so the fixture's text doesn't matter.
  func write(_ f: Fixture, _ id: String, _ text: String) throws {
    var v = try #require(try f.store.versions(videoId: id).first)
    v.caption = text
    try f.store.save(v, videoId: id)
  }

  func cap(_ f: Fixture, _ n: Int?, _ p: Platform) throws {
    var s = try f.store.settings()
    s.limits[p]?.maxHashtags = n
    try f.store.save(s)
  }

  @Test func theFirstTagsInCaptionOrderStay() {
    #expect(Captions.capped("Words\n#a #b #c #d", to: 2).text == "Words\n#a #b")
    #expect(Captions.capped("Words\n#a #b #c #d", to: 2).dropped == ["#c", "#d"])
    #expect(Captions.capped("#d #c #b #a", to: 1).text == "#d")
  }

  @Test func tagsInTheTextCountToo() {
    #expect(Captions.capped("Love #amapiano tonight\n#a #b", to: 2).text == "Love #amapiano tonight\n#a")
    #expect(Captions.capped("Love #amapiano tonight\n#a #b", to: 1).text == "Love #amapiano tonight")
    #expect(Captions.capped("#x words #y more", to: 1).text == "#x words more")
  }

  @Test func capsOfNothingOneAndNone() {
    #expect(Captions.capped("Words\n#a #b", to: 0).text == "Words")
    #expect(Captions.capped("Words\n#a #b", to: 0).dropped == ["#a", "#b"])
    #expect(Captions.capped("Words\n#a #b", to: 1).text == "Words\n#a")
    #expect(Captions.capped("Words\n#a #b", to: nil).text == "Words\n#a #b")
    #expect(Captions.capped("Words\n#a #b", to: 2).dropped.isEmpty)
    #expect(Captions.capped("No tags", to: 0).text == "No tags")
  }

  @Test func eachPlatformIsCappedOnItsOwn() throws {
    let f = try Fixture.planned()
    try write(f, "clip-1", "Words\n#a #b #c")
    try cap(f, 1, .threads)
    try cap(f, 2, .instagram)
    try cap(f, nil, .x)
    #expect(try caption(f, "clip-1", .threads) == "Words\n#a")
    #expect(try caption(f, "clip-1", .instagram) == "Words\n#a #b")
    #expect(try caption(f, "clip-1", .x) == "Words\n#a #b #c")
  }

  @Test func templateTagsCountInOrderAndTheFieldStaysWhole() throws {
    let f = try Fixture.planned()
    try f.store.save(HashtagSet(id: "g", name: "G", category: "My groups", tags: ["#g1", "#g2"], sort: 0))
    let t = CaptionTemplates.make(name: "T", template: "{text} #own\n{hashtags}", existing: try f.store.captionTemplates())
    try CaptionTemplates.create(t, store: f.store, bulk: f.bulk)
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.captionTemplateId = t.id
    v.hashtagSetIds = ["g"]
    try f.store.save(v, videoId: "clip-1")
    try cap(f, 2, .threads)
    #expect(try caption(f, "clip-1", .threads) == "Text clip-1 #own\n#g1")
    let video = try #require(try f.store.video(id: "clip-1")), s = try CaptionHold.Sources(f.store)
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-1", number: 1))
    let shared = Captions.sharedCaption(version: r, video: video, sessionName: "S", sets: s.sets, templates: s.templates, settings: s.settings)
    #expect(shared == "Text clip-1 #own\n#g1 #g2")
  }

  @Test func anOwnCaptionIsLeftAsWrittenAndWarned() throws {
    let f = try Fixture.planned()
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.platformCaptions = [.threads: "Mine #a #b #c"]
    try f.store.save(v, videoId: "clip-1")
    try cap(f, 1, .threads)
    #expect(try caption(f, "clip-1", .threads) == "Mine #a #b #c")
    let notes = try note(f, "clip-1", [.threads])
    #expect(notes.map(\.own) == [true])
    #expect(notes.first?.message.contains("left as you wrote it") == true)
  }

  func note(_ f: Fixture, _ id: String, _ platforms: [Platform]) throws -> [Captions.CapNote] {
    let video = try #require(try f.store.video(id: id)), s = try CaptionHold.Sources(f.store)
    let r = try #require(try f.store.resolvedVersion(videoId: id, number: 1))
    return Captions.capNotes(platforms, version: r, video: video, sessionName: "S", sets: s.sets, templates: s.templates, settings: s.settings)
  }

  @Test func theLineSaysWhatsDropped() throws {
    let f = try Fixture.planned()
    try write(f, "clip-1", "Words #a #b #c #d")
    try cap(f, 1, .threads)
    try cap(f, 0, .x)
    try cap(f, nil, .tiktok)
    let notes = try note(f, "clip-1", [.threads, .x, .tiktok])
    #expect(notes.map(\.message) == ["Threads keeps 1 of 4: drops #b #c #d", "X keeps no hashtags: drops #a #b #c #d"])
  }

  @Test func aCapDoesntBlockValidation() throws {
    let f = try Fixture.planned()
    try write(f, "clip-0", "Words #a #b #c")
    let before = try Validation.issues(video: #require(try f.store.video(id: "clip-0")), store: f.store)
    try cap(f, 1, .threads)
    #expect(try Validation.issues(video: #require(try f.store.video(id: "clip-0")), store: f.store) == before)
  }

  // MARK: Scheduled clips

  @Test func aNewCapFreezesScheduledClipsAndUndoRestores() throws {
    let f = try Fixture.planned()
    try cap(f, nil, .threads)
    try write(f, "clip-0", "Words #a #b #c")
    try write(f, "clip-1", "Words #a #b #c")
    let version = try f.journal("clip-0"), before = try f.captions("clip-0"), hashes = try f.hashes()
    let c = try CaptionTemplates.setHashtagCap(1, for: .threads, store: f.store, bulk: f.bulk)
    #expect(c.kept == ["clip-0"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.versions(videoId: "clip-0").first?.platformCaptions?[.threads] == "Words #a #b #c")
    #expect(try caption(f, "clip-1", .threads) == "Words #a")
    try f.bulk.undo(#require(c.result.batchId))
    #expect(try f.journal("clip-0") == version)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.settings().limits[.threads]?.maxHashtags == nil)
  }

  @Test func raisingACapHoldsScheduledClipsToo() throws {
    let f = try Fixture.planned()
    try cap(f, 1, .threads)
    try write(f, "clip-0", "Words #a #b #c")
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    #expect(before[1]?[.threads] == "Words #a")
    try CaptionTemplates.setHashtagCap(nil, for: .threads, store: f.store, bulk: f.bulk)
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
  }

  @Test func anOpenEditorSessionNeverClaimsACapFreeze() throws {
    let f = try Fixture.planned()
    try cap(f, nil, .threads)
    try write(f, "clip-0", "Words #a #b")
    let session = try f.bulk.begin("editor", ids: ["clip-0"])
    try CaptionTemplates.setHashtagCap(1, for: .threads, store: f.store, bulk: f.bulk)
    #expect(try f.bulk.commit(session).batchId == nil)
  }

  @Test func undoIsRefusedWhenAClipScheduledLaterWouldChange() throws {
    let f = try Fixture.planned()
    try cap(f, nil, .threads)
    try write(f, "clip-1", "Words #a #b")
    let b = try #require(try CaptionTemplates.setHashtagCap(1, for: .threads, store: f.store, bulk: f.bulk).result.batchId)
    try f.store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('later','clip-1','threads',1,1,'regular',0,'planned','manual',0,0)
      """)
    #expect(throws: (any Error).self) { try f.bulk.undo(b) }
  }

  /// The defaults arrive with v0.8.3: Threads goes to 1 on Eric's own data the first time this build opens it.
  @Test func installKeepsScheduledClipsTheDefaultCapsWouldChange() throws {
    let f = try Fixture.planned()
    try write(f, "clip-0", "Words #a #b #c")
    try write(f, "clip-1", "Words #a #b #c")
    let video = try #require(try f.store.video(id: "clip-0")), s = try CaptionHold.Sources(f.store)
    let old = try CaptionHold.outputs(video, s, store: f.store, legacy: true)
    #expect(try CaptionRulesMigration.run(f.store) == ["clip-0"])
    #expect(try f.captions("clip-0") == old)
    #expect(try caption(f, "clip-1", .threads) == "Words #a")
  }

  @Test func defaultsAreOnlyWhatsConfirmedAndEricsCapsStay() {
    let d = PlatformLimits.defaults
    #expect(d[.threads]?.maxHashtags == 1 && d[.youtube]?.maxHashtags == 60 && d[.instagram]?.maxHashtags == 30)
    for p in [Platform.tiktok, .x, .facebook] { #expect(d[p]?.maxHashtags == nil) }
    var stored = d
    stored[.threads]?.maxHashtags = 3
    stored[.instagram]?.maxHashtags = nil
    let moved = PlatformLimits.migrateStored(stored, from: 2)
    #expect(moved[.threads]?.maxHashtags == 3 && moved[.instagram]?.maxHashtags == 30)
    #expect(PlatformLimits.migrateStored(stored, from: 3)[.instagram]?.maxHashtags == nil)
  }

  // MARK: Order

  @Test func aGroupsTagsStayInTheOrderTyped() throws {
    #expect(HashtagGroups.parseTags("#zebra #apple #mango") == ["#zebra", "#apple", "#mango"])
    let f = try Fixture.planned()
    try f.store.save(HashtagSet(id: "g", name: "G", category: "My groups", tags: ["#zebra", "#apple"], sort: 0))
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.hashtagSetIds = ["g"]
    try f.store.save(v, videoId: "clip-1")
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-1", number: 1))
    #expect(Captions.hashtags(r, sets: try f.store.hashtagSets()) == ["#zebra", "#apple"])
  }

  @Test func groupsMoveAndUndoAndReachNoCaption() throws {
    let f = try Fixture.planned()
    for (i, id) in ["a", "b", "c"].enumerated() {
      try f.store.save(HashtagSet(id: id, name: id, category: "My groups", tags: ["#\(id)"], sort: 5))
      if i == 2 { try write(f, "clip-0", "{hashtags}") }
    }
    var v = try #require(try f.store.versions(videoId: "clip-0").first)
    v.hashtagSetIds = ["a", "b"]
    try f.store.save(v, videoId: "clip-0")
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    let r = try HashtagGroups.move("b", by: -1, store: f.store, bulk: f.bulk).result
    #expect(try f.store.hashtagSets().map(\.id) == ["b", "a", "c"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try HashtagGroups.move("b", by: -1, store: f.store, bulk: f.bulk).result.batchId == nil)
    try f.bulk.undo(#require(r.batchId))
    #expect(try f.store.hashtagSets().map(\.id) == ["a", "b", "c"])
  }
}
