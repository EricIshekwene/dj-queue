import Foundation
import Testing
@testable import DJQCore

/// v0.8.3: own caption templates, tags typed in them, and the schema 7 install hold.
@Suite struct R11TemplateTests {
  func chose(_ f: Fixture, _ id: String, _ template: String) throws {
    var v = try #require(try f.store.versions(videoId: id).first)
    v.captionTemplateId = template
    try f.store.save(v, videoId: id)
  }

  func mine(_ f: Fixture, _ text: String = "{text}\n\n{hashtags}") throws -> CaptionTemplate {
    let t = CaptionTemplates.make(name: "Mine", template: text, existing: try f.store.captionTemplates())
    try CaptionTemplates.create(t, store: f.store, bulk: f.bulk)
    return t
  }

  func group(_ f: Fixture, _ id: String, tags: [String]) throws {
    try f.store.save(HashtagSet(id: "g", name: "G", category: "My groups", tags: tags, sort: 0))
    var v = try #require(try f.store.versions(videoId: id).first)
    v.hashtagSetIds = ["g"]
    try f.store.save(v, videoId: id)
  }

  // MARK: Edit and delete

  @Test func editLeavesScheduledClipsAloneAndOthersFollow() throws {
    let f = try Fixture.planned()
    var t = try mine(f, "{text} first\n{hashtags}")
    try group(f, "clip-0", tags: ["#a", "#b"])
    for id in ["clip-0", "clip-1"] { try chose(f, id, t.id) }
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    t.template = "{text} second\n{hashtags}"
    let c = try CaptionTemplates.update(t, store: f.store, bulk: f.bulk)
    #expect(c.kept == ["clip-0"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.versions(videoId: "clip-0").first?.caption?.contains("{hashtags}") == true)
    #expect(try f.captions("clip-1")[1]?[.x]?.contains("second") == true)
  }

  @Test func editingTheDefaultHoldsFollowersOnEveryPlatform() throws {
    let f = try Fixture.planned()
    var s = try f.store.settings()
    s.defaults.platformCaptionTemplates = [.instagram: "question"]
    try f.store.save(s)
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    var t = try #require(try f.store.captionTemplates().first { $0.id == "set-link" })
    t.template = "Changed {text}"
    try CaptionTemplates.update(t, store: f.store, bulk: f.bulk)
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.captions("clip-1")[1]?[.x]?.hasPrefix("Changed") == true)
  }

  @Test func aRenameReachesNothing() throws {
    let f = try Fixture.planned()
    var t = try mine(f)
    try chose(f, "clip-0", t.id)
    t.name = "Renamed"
    #expect(try CaptionTemplates.update(t, store: f.store, bulk: f.bulk).kept.isEmpty)
    #expect(try f.store.versions(videoId: "clip-0").first?.caption == nil)
  }

  @Test func undoOfAnEditRestoresExactly() throws {
    let f = try Fixture.planned()
    var t = try mine(f)
    try chose(f, "clip-0", t.id)
    let version = try f.journal("clip-0"), hashes = try f.hashes(), templates = try f.store.captionTemplates()
    t.template = "Changed"
    let b = try #require(try CaptionTemplates.update(t, store: f.store, bulk: f.bulk).result.batchId)
    try f.bulk.undo(b)
    #expect(try f.journal("clip-0") == version)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.captionTemplates() == templates)
  }

  @Test func deleteKeepsScheduledAndSendsOthersToTheDefault() throws {
    let f = try Fixture.planned()
    let t = try mine(f, "Mine {text} {hashtags}")
    for id in ["clip-0", "clip-1"] { try chose(f, id, t.id) }
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    let c = try CaptionTemplates.delete(t, store: f.store, bulk: f.bulk)
    #expect(c.kept == ["clip-0"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.store.versions(videoId: "clip-1").first?.captionTemplateId == nil)
    #expect(try f.captions("clip-1")[1]?[.x]?.hasPrefix("Mine") == false)
    #expect(try !f.store.captionTemplates().contains { $0.id == t.id })
    let b = try #require(c.result.batchId)
    try f.bulk.undo(b)
    #expect(try f.store.captionTemplates().contains { $0.id == t.id })
    #expect(try f.store.versions(videoId: "clip-1").first?.captionTemplateId == t.id)
    #expect(try f.store.versions(videoId: "clip-0").first?.caption == nil)
    #expect(try f.hashes() == hashes)
  }

  @Test func theDefaultCantBeDeleted() throws {
    let f = try Fixture.planned()
    let t = try #require(try f.store.captionTemplates().first { $0.id == "set-link" })
    #expect(throws: (any Error).self) { try CaptionTemplates.delete(t, store: f.store, bulk: f.bulk) }
    #expect(CaptionTemplates.blocker(of: "set-link", settings: try f.store.settings())?.contains("New clip defaults") == true)
    var s = try f.store.settings()
    s.defaults.platformCaptionTemplates = [.x: "short"]
    #expect(CaptionTemplates.blocker(of: "short", settings: s)?.contains("X") == true)
    #expect(CaptionTemplates.blocker(of: "tracks", settings: s) == nil)
  }

  @Test func anOpenEditorSessionNeverClaimsAFreeze() throws {
    let f = try Fixture.planned()
    var t = try mine(f)
    try chose(f, "clip-0", t.id)
    let session = try f.bulk.begin("editor", ids: ["clip-0"])
    t.template = "Changed"
    try CaptionTemplates.update(t, store: f.store, bulk: f.bulk)
    #expect(try f.bulk.commit(session).batchId == nil)
    let again = try f.bulk.begin("editor", ids: ["clip-0"])
    try CaptionTemplates.delete(t, store: f.store, bulk: f.bulk)
    #expect(try f.bulk.commit(again).batchId == nil)
  }

  @Test func undoIsRefusedWhenAClipScheduledLaterWouldChange() throws {
    let f = try Fixture.planned()
    var t = try mine(f, "First {text}")
    try chose(f, "clip-1", t.id)
    t.template = "Second {text}"
    let b = try #require(try CaptionTemplates.update(t, store: f.store, bulk: f.bulk).result.batchId)
    try f.store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('later','clip-1','x',1,1,'regular',0,'planned','manual',0,0)
      """)
    #expect(throws: (any Error).self) { try f.bulk.undo(b) }
    #expect(try f.store.captionTemplates().first { $0.id == t.id }?.template == "Second {text}")
  }

  @Test func problems() {
    let t = CaptionTemplate(id: "a", name: "Plug", template: "{text}", sort: 0)
    #expect(CaptionTemplates.problem(name: "  ", template: "x", existing: []) == .noName)
    #expect(CaptionTemplates.problem(name: "A", template: " \n", existing: []) == .noText)
    #expect(CaptionTemplates.problem(name: "plug ", template: "x", existing: [t]) == .duplicateName("Plug"))
    #expect(CaptionTemplates.problem(name: "plug", template: "x", existing: [t], editing: "a") == nil)
  }

  // MARK: Tags in templates

  func caption(_ f: Fixture, _ id: String, _ p: Platform = .x) throws -> String { try #require(try f.captions(id)[1]?[p]) }

  @Test func aTemplateCanHoldTagsTokensOrBoth() throws {
    let f = try Fixture.planned()
    try group(f, "clip-1", tags: ["#g"])
    let literal = try mine(f, "{text} #own")
    try chose(f, "clip-1", literal.id)
    #expect(try caption(f, "clip-1") == "Text clip-1 #own")
    var both = literal
    both.template = "{text} #own\n{hashtags}"
    try CaptionTemplates.update(both, store: f.store, bulk: f.bulk)
    #expect(try caption(f, "clip-1") == "Text clip-1 #own\n#g")
  }

  @Test func aTagInBothAppearsOnceAtItsFirstPosition() throws {
    let f = try Fixture.planned()
    try group(f, "clip-1", tags: ["#Own", "#g"])
    let t = try mine(f, "{text} #own\n{hashtags}")
    try chose(f, "clip-1", t.id)
    #expect(try caption(f, "clip-1") == "Text clip-1 #own\n#g")
    var groupsFirst = t
    groupsFirst.template = "{hashtags}\n{text} #own"
    try CaptionTemplates.update(groupsFirst, store: f.store, bulk: f.bulk)
    #expect(try caption(f, "clip-1") == "#own #g\nText clip-1")
  }

  @Test func aWrittenCaptionWithTheTokenIsTheSame() throws {
    let f = try Fixture.planned()
    try group(f, "clip-1", tags: ["#own", "#g"])
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.caption = "Mine #own\n{hashtags}"
    try f.store.save(v, videoId: "clip-1")
    #expect(try caption(f, "clip-1") == "Mine #own\n#g")
    v.caption = "Literal #own #own"
    try f.store.save(v, videoId: "clip-1")
    #expect(try caption(f, "clip-1") == "Literal #own #own")
  }

  @Test func removingAGroupLeavesALiteralTag() throws {
    let f = try Fixture.planned()
    try group(f, "clip-1", tags: ["#own", "#g"])
    let t = try mine(f, "{text} #own\n{hashtags}")
    try chose(f, "clip-1", t.id)
    var v = try #require(try f.store.versions(videoId: "clip-1").first)
    v.hashtagSetIds = []
    try f.store.save(v, videoId: "clip-1")
    #expect(try caption(f, "clip-1") == "Text clip-1 #own")
  }

  @Test func dropHashtagsRemovesLiteralTagsToo() throws {
    let f = try Fixture.planned()
    try group(f, "clip-1", tags: ["#g"])
    let t = try mine(f, "{text} #own\n{hashtags}")
    try chose(f, "clip-1", t.id)
    let video = try #require(try f.store.video(id: "clip-1")), s = try CaptionHold.Sources(f.store)
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-1", number: 1))
    let bare = Captions.withoutHashtags(for: .x, version: r, video: video, sessionName: "Set", templates: s.templates, settings: s.settings, sets: s.sets)
    #expect(bare == "Text clip-1")
  }

  // MARK: Save as template

  func saved(_ f: Fixture, _ caption: String, tags: [String] = [], title: String? = nil) throws -> String {
    if !tags.isEmpty { try group(f, "clip-1", tags: tags) }
    if let title { try f.store.setTitle("clip-1", title) }
    let video = try #require(try f.store.video(id: "clip-1"))
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-1", number: 1))
    return CaptionTemplates.template(fromCaption: caption, version: r, video: video, sessionName: "2026-10-23 – Afroween Jazz Piano",
                                     sets: try f.store.hashtagSets(), link: Defaults.captionLink)
  }

  @Test func saveAsMakesTokensAndKeepsHandTypedTags() throws {
    let f = try Fixture.planned()
    let t = try saved(f, "Text clip-1\nSong name\n🎧 Afroween Jazz Piano — Full set on YouTube (link in bio) #mine\n#a #b",
                      tags: ["#a", "#b"], title: "Song name")
    #expect(t == "{text}\n{title}\n🎧 {set} — {link} #mine\n{hashtags}")
  }

  @Test func saveAsAddsTheTokenSoGroupsStillArrive() throws {
    let f = try Fixture.planned()
    #expect(try saved(f, "Words #mine") == "Words #mine\n\n{hashtags}")
  }

  @Test func saveAsHandlesTagsNotInARun() throws {
    let f = try Fixture.planned()
    #expect(try saved(f, "#a words #mine #b", tags: ["#a", "#b"]) == "{hashtags} words #mine")
  }

  @Test func saveAsMatchesWholeWordsOnly() throws {
    let f = try Fixture.planned()
    #expect(try saved(f, "Songs of love", title: "Song").contains("Songs") == true)
  }

  @Test func saveAsRoundTrips() throws {
    let f = try Fixture.planned()
    try group(f, "clip-1", tags: ["#a", "#b"])
    let before = try caption(f, "clip-1")
    let t = try mine(f, try saved(f, before))
    try chose(f, "clip-1", t.id)
    #expect(try caption(f, "clip-1") == before)
  }

  // MARK: Tokens and the install hold

  @Test func titleAndLinkAreTokens() throws {
    let f = try Fixture.planned()
    try f.store.setTitle("clip-1", "Song")
    let t = try mine(f, "{title}\n{link}")
    try chose(f, "clip-1", t.id)
    #expect(try caption(f, "clip-1") == "Song\n\(Defaults.captionLink)")
    var s = try f.store.settings()
    s.captionLink = "Elsewhere"
    try f.store.save(s)
    #expect(try caption(f, "clip-1") == "Song\nElsewhere")
  }

  @Test func anOldSettingsRowGetsTheLink() {
    #expect(Store.decodeSettings("{}").captionLink == Defaults.captionLink)
  }

  @Test func installKeepsAScheduledClipThatTheNewRulesWouldChange() throws {
    let f = try Fixture.planned()
    try group(f, "clip-0", tags: ["#own"])
    try group(f, "clip-1", tags: ["#own"])
    let t = try mine(f, "{text} #own {title} {hashtags}")
    for id in ["clip-0", "clip-1"] { try chose(f, id, t.id) }
    let video = try #require(try f.store.video(id: "clip-0"))
    let old = try CaptionHold.outputs(video, CaptionHold.Sources(f.store), store: f.store, legacy: true)
    #expect(old[1]?[.x]?.contains("{title}") == true)
    let held = try CaptionRulesMigration.run(f.store)
    #expect(held == ["clip-0"])
    #expect(try f.captions("clip-0") == old)
    #expect(try f.store.db.one("PRAGMA user_version")?.int("user_version") == 7)
    let batch = try #require(try f.bulk.batches().first { $0.action == CaptionRulesMigration.action })
    try f.bulk.undo(batch.id)
    #expect(try f.store.versions(videoId: "clip-0").first?.platformCaptions == nil)
  }

  @Test func installChangesNothingWhenNoRuleApplies() throws {
    let f = try Fixture.planned()
    let before = try f.captions("clip-0")
    #expect(try CaptionRulesMigration.run(f.store).isEmpty)
    #expect(try f.captions("clip-0") == before)
    #expect(try f.bulk.batches().first { $0.action == CaptionRulesMigration.action } == nil)
  }
}
