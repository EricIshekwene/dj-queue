import Foundation
import Testing
@testable import DJQCore

/// Round 20: "Ready to repost" per text version. Data and read-only logic for a later repost round; marking a version
/// never moves, queues, schedules or posts anything (the ONLY way into Queue is Eric's Send to Queue).
@Suite struct R20RepostReadyTests {
  /// Everything about a clip that marking a version must leave alone.
  struct Snap: Equatable {
    var state: VideoState
    var sent: Bool
    var held: Bool
    var stage: ClipStage?
    var slots: [String]
    var posts: [String]
    var resolved: [ResolvedVersion]
    var previewStamp: String
  }

  func snap(_ f: Fixture, _ id: String) throws -> Snap {
    let v = try #require(try f.store.video(id: id))
    let numbers = Set(try f.store.versions(videoId: id).map(\.number)).union([1]).sorted()
    return Snap(state: v.state, sent: v.sentToQueue, held: v.heldInEdit, stage: ClipStage.of(v),
                slots: try f.store.planSlots(where: "video_id=?", [id]).map { "\($0.id)@\($0.date)#\($0.position)\($0.pinned)" }.sorted(),
                posts: try f.store.posts(where: "video_id=?", [id]).map { "\($0.id)|\($0.state.rawValue)|v\($0.versionNo)|\($0.scheduledAt)" }.sorted(),
                resolved: try numbers.compactMap { try f.store.resolvedVersion(videoId: id, number: $0) },
                previewStamp: try f.store.previewStampTable().stamp(for: v, version: 1))
  }

  @Test func flagIsPerVersionAndNeverCarriedForward() throws {
    let f = try Fixture.engine(3, ready: 1)
    var v2 = Version(number: 2)
    v2.text = "Second hook"
    try f.store.save(v2, videoId: "clip-0")
    try f.store.save(Version(number: 3), videoId: "clip-0")
    #expect(try f.store.setRepostReady(videoId: "clip-0", number: 2, true))
    #expect(try f.store.repostReadyVersions(videoId: "clip-0") == [2])
    let all = try f.store.versions(videoId: "clip-0")
    #expect(all.first { $0.number == 3 }?.repostReady == nil)  // v3 doesn't inherit it
    #expect(all.first { $0.number == 1 }?.repostReady == nil)
    // Already ready: nothing written, nothing logged twice.
    #expect(try !f.store.setRepostReady(videoId: "clip-0", number: 2, true))
    #expect(try f.store.events(videoId: "clip-0").filter { $0.kind == "version" }.count == 1)
    #expect(try f.store.setRepostReady(videoId: "clip-0", number: 2, false))
    #expect(try f.store.repostReadyVersions(videoId: "clip-0").isEmpty)
    // Cleared = the key is gone again, so the stored JSON is as it was.
    #expect(try f.store.versions(videoId: "clip-0").first { $0.number == 2 } == v2)
  }

  @Test func markingNeverMovesQueuesOrSchedulesAClip() throws {
    let f = try Fixture.engine(4, ready: 2)
    try Planner(store: f.store).approveWeek(f.week)
    try f.store.setHeldInEdit("clip-1", true)
    var v2 = Version(number: 2)
    v2.text = "Repost hook"
    for id in ["clip-0", "clip-1", "clip-2", "clip-3"] { try f.store.save(v2, videoId: id) }
    let before = try ["clip-0", "clip-1", "clip-2", "clip-3"].map { try snap(f, $0) }
    #expect(before.map(\.stage).contains(.edit))  // the Edit clips stay in Edit…
    for id in ["clip-0", "clip-1", "clip-2", "clip-3"] {
      try f.store.setRepostReady(videoId: id, number: 1, true)
      try f.store.setRepostReady(videoId: id, number: 2, true)
    }
    let marked = try ["clip-0", "clip-1", "clip-2", "clip-3"].map { try snap(f, $0) }
    #expect(marked == before)  // …and nothing about any clip changed: stage, Queue, slots, posts, looks, previews
    for id in ["clip-0", "clip-1", "clip-2", "clip-3"] { try f.store.setRepostReady(videoId: id, number: 2, false) }
    #expect(try ["clip-0", "clip-1", "clip-2", "clip-3"].map { try snap(f, $0) } == before)
    // An engine tick with ready versions doesn't plan reposts either.
    let posts = try f.store.posts().count
    Engine(store: f.store, renderer: FakeRenderer(store: f.store), publisher: nil, notifier: LogNotifier()).planFrozen.tick(reason: "test")
    #expect(try f.store.posts().count == posts)
    #expect(try f.store.posts().allSatisfy { $0.kind != .repost })
  }

  @Test func v1CanBeMarkedBeforeItWasSaved() throws {
    let f = try Fixture.engine(2, ready: 0)
    #expect(try f.store.versions(videoId: "clip-1").isEmpty)
    let before = try snap(f, "clip-1")
    try f.store.setRepostReady(videoId: "clip-1", number: 1, true)
    #expect(try f.store.repostReadyVersions(videoId: "clip-1") == [1])
    let after = try snap(f, "clip-1")
    #expect(after.resolved == before.resolved && after.state == before.state && after.stage == before.stage)
    // Unmarking a v1 that was never saved writes nothing.
    #expect(try !f.store.setRepostReady(videoId: "clip-0", number: 1, false))
    #expect(try f.store.versions(videoId: "clip-0").isEmpty)
  }

  @Test func refusesWhatCantBeReposted() throws {
    let f = try Fixture.engine(2)
    #expect(throws: EngineError.self) { try f.store.setRepostReady(videoId: "long-0001", number: 1, true) }
    #expect(throws: EngineError("song0 x mix0 has no v3")) { try f.store.setRepostReady(videoId: "clip-0", number: 3, true) }
    #expect(throws: EngineError.self) { try f.store.setRepostReady(videoId: "nope", number: 1, true) }
  }

  @Test func candidatesAreReadyVersionsThePlatformHasntHad() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let a = PostActions(store: f.store)
    let tt = try #require(try f.post(.tiktok, day: "2026-11-02"))
    let id = tt.videoId
    try a.markPosted(postId: tt.id, url: Fixture.postURLs[.tiktok]!)
    for n in [2, 3] {
      var v = Version(number: n)
      v.text = "Hook \(n)"
      try f.store.save(v, videoId: id)
    }
    #expect(try f.store.nextRepostReadyVersion(videoId: id, platform: .tiktok) == nil)  // nothing marked yet
    for n in [1, 3] { try f.store.setRepostReady(videoId: id, number: n, true) }
    #expect(try f.store.nextRepostReadyVersion(videoId: id, platform: .tiktok) == 3)  // v1 is out there already
    #expect(try f.store.nextRepostReadyVersion(videoId: id, platform: .youtube) == 3)  // v1 is planned there
    // A skipped post doesn't count as having had that version.
    let yt = try #require(try f.store.posts(where: "video_id=? AND platform=?", [id, Platform.youtube.rawValue]).first)
    try a.skip(postId: yt.id)
    #expect(try f.store.nextRepostReadyVersion(videoId: id, platform: .youtube) == 1)
    #expect(RepostReady.candidates(versions: try f.store.versions(videoId: id), posts: try f.store.posts(where: "video_id=?", [id]),
                                   platform: .tiktok) == [3])
    #expect(RepostReady.label([2, 3]) == "v2 · v3")
  }

  @Test func filtersApiAndSearchSeeIt() throws {
    let f = try Fixture.engine(3, ready: 1)
    var v2 = Version(number: 2)
    v2.text = "Second"
    try f.store.save(v2, videoId: "clip-2")
    try f.store.setRepostReady(videoId: "clip-2", number: 2, true)
    #expect(try BulkActions(store: f.store).ids(filter: "repost-ready") == ["clip-2"])
    #expect(try f.store.repostReadyVersions() == ["clip-2": [2]])
    let list = try AgentAPI.videos(store: f.store)
    #expect(list.first { $0.id == "clip-2" }?.repost_ready_versions == [2])
    #expect(list.first { $0.id == "clip-0" }?.repost_ready_versions == [])
    #expect(try AgentAPI.video("clip-2", store: f.store).versions.first { $0.number == 2 }?.repostReady == true)
    let s = try f.store.settings(), videos = try f.store.videos()
    let text = try f.store.searchClipText(videos: videos, settings: s, sets: try f.store.hashtagSets())
    #expect(text["clip-2"]?.repostReady == [2])
    let index = SearchCorpus.index(SearchInput(settings: s, sessions: try f.store.sessions(), videos: videos, posts: [], weekStates: [:],
                                               weekClips: [:], clipText: text, hashtagSets: [], captionTemplates: [], now: f.clock.now))
    let hits = index.search(SearchQuery("ready to repost")).filter { $0.kind == .clip }.map(\.id)
    #expect(hits == [SearchId.clip("clip-2")])
  }

  @Test func storedJsonOnlyGainsTheKeyWhenSet() throws {
    var v = Version(number: 2)
    v.text = "x"
    #expect(!JSONCoding.string(v).contains("repostReady"))
    v.repostReady = true
    #expect(JSONCoding.string(v).contains("\"repostReady\":true"))
    let old = try JSONCoding.decoder.decode(Version.self, from: Data(#"{"number":2,"text":"x"}"#.utf8))
    #expect(old.repostReady == nil)
  }
}

/// Round 20 (Eric): a bulk edit on a clip with several versions applies to every version except captions.
@Suite struct R20EditorMergeTests {
  /// What the editor saves keeps the mark and a bulk pin made while it was open, unless the editor changed them itself.
  @Test func outsideChangesSurviveTheEditorsSave() {
    // The editor's own logic lives in the app target; this is the same rule (EditorModel.keepingOutsideChanges), in core terms.
    var base = Version(number: 2)
    base.text = "Hook"
    var stored = base
    stored.repostReady = true
    stored.captionsOwn = true
    stored.captionTemplateId = "short"
    var editor = base
    editor.text = "Hook, edited"
    let out = VersionMerge.keepingOutsideChanges(editor, base: base, stored: stored)
    #expect(out.text == "Hook, edited" && out.repostReady == true && out.captionsOwn == true && out.captionTemplateId == "short")
    var unmarked = base
    unmarked.repostReady = false
    var marked = base
    marked.repostReady = true
    #expect(VersionMerge.keepingOutsideChanges(unmarked, base: marked, stored: marked).repostReady == false)
  }
}

@Suite struct R20BulkVersionsTests {
  func setup() throws -> (Fixture, Settings) {
    let f = try Fixture.engine(3, ready: 2)
    try f.store.save(CaptionTemplate(id: "other", name: "Other", template: "Other {text}", sort: 9))
    try f.store.save(HashtagSet(id: "g1", name: "G1", category: "Mine", tags: ["#one"], sort: 0))
    var v2 = Version(number: 2)
    v2.text = "Hook two"
    v2.style = .outline
    v2.size = 90
    try f.store.save(v2, videoId: "clip-0")
    try f.store.save(Version(number: 3), videoId: "clip-0")
    return (f, try f.store.settings())
  }

  func face(_ f: Fixture, _ n: Int, _ s: Settings) throws -> BulkActions.CaptionFace {
    BulkActions.CaptionFace(try #require(try f.store.resolvedVersion(videoId: "clip-0", number: n, settings: s)))
  }

  @Test func captionChangesStayOnV1() throws {
    let (f, s) = try setup()
    let b = BulkActions(store: f.store)
    let v2 = try face(f, 2, s), v3 = try face(f, 3, s)
    #expect(v2.template == "short")  // inherited from v1
    try b.setCaptionTemplate(["clip-0", "clip-1"], "other")
    try b.setHashtagSets(["clip-0"], ["g1"])
    try b.setExtraHashtags(["clip-0"], ["#x"])
    try b.setYouTubeTitleTemplate(["clip-0"], nil)
    #expect(try face(f, 1, s).template == "other" && face(f, 1, s).groups == ["g1"])
    #expect(try face(f, 2, s) == v2)
    #expect(try face(f, 3, s) == v3)
    // Only v2 had to stop inheriting; v3 follows v2, which now holds what it showed.
    let raw = try f.store.versions(videoId: "clip-0")
    #expect(raw.first { $0.number == 2 }?.captionsOwn == true)
    #expect(raw.first { $0.number == 3 }?.captionsOwn == true)  // follows v2, so it's kept too
    // Text still follows v1 where a version doesn't set its own.
    #expect(try f.store.resolvedVersion(videoId: "clip-0", number: 3, settings: s)?.text == "Hook two")
    // A clip with only v1 gets nothing extra.
    #expect(try f.store.versions(videoId: "clip-1").allSatisfy { $0.captionsOwn == nil })
    // Deleting v2 later doesn't hand v3 v1's new caption.
    var copy = try f.store.versions(videoId: "clip-0")
    try f.store.deleteVersion(videoId: "clip-0", number: 2)
    #expect(try face(f, 3, s) == v3)
    for v in copy where v.number == 2 { try f.store.save(v, videoId: "clip-0") }
    copy = []
    // Marking a version after the batch doesn't block its undo, and the undo keeps the mark.
    try f.store.setRepostReady(videoId: "clip-0", number: 2, true)
    // Bulk undo takes all of it back.
    let batches = try b.batches()
    for batch in batches { _ = try b.undo(batch.id) }
    #expect(try f.store.versions(videoId: "clip-0").allSatisfy { $0.captionsOwn == nil })
    #expect(try f.store.repostReadyVersions(videoId: "clip-0") == [2])
    #expect(try face(f, 1, s).template == "short")
  }

  @Test func resetToDefaultsTextReachesEveryVersionButKeepsWords() throws {
    let (f, s) = try setup()
    let b = BulkActions(store: f.store)
    let v2 = try face(f, 2, s)
    try b.applyDefaults(["clip-0"], sections: [.text, .caption])
    let raw = try f.store.versions(videoId: "clip-0")
    let r2 = try #require(raw.first { $0.number == 2 })
    #expect(r2.style == nil && r2.size == nil)  // look reset on v2 too
    #expect(r2.text == "Hook two")  // its words stay
    #expect(try face(f, 2, s) == v2)  // its caption stays
    #expect(try face(f, 1, s).template == nil)  // v1's caption follows the defaults
  }

  @Test func editLevelChangesAreSharedByEveryVersion() throws {
    let (f, _) = try setup()
    let b = BulkActions(store: f.store)
    try b.setPlatform(["clip-0"], .x, skipped: true)
    // One edit per clip: every version renders and posts from it.
    #expect(try f.store.edit(videoId: "clip-0").skippedPlatforms.contains(.x))
  }

  @Test func captionsOwnCutsInheritanceOnlyForCaptions() throws {
    var v1 = Version(number: 1)
    v1.text = "One"; v1.captionTemplateId = "short"; v1.caption = "Written"; v1.hashtagSetIds = ["g1"]; v1.style = .outline
    var v2 = Version(number: 2)
    v2.captionsOwn = true
    let r = VersionResolver.resolve([v1, v2], number: 2, settings: Settings())
    #expect(r.text == "One" && r.style == .outline)  // text and look still carry forward
    #expect(r.caption == "" && r.captionTemplateId == nil && r.hashtagSetIds == Settings().defaults.hashtagSetIds)
    #expect(r.isDefault("caption") && r.isDefault("hashtagSetIds") && !r.inherited.contains("caption"))
  }

  @Test func notesSayWhatReachesWhichVersion() {
    #expect(BulkVersionScope.every.note(multi: 0) == nil)
    #expect(BulkVersionScope.captionsV1Only.note(multi: 2)?.contains("Captions change on v1 only") == true)
    #expect(BulkVersionScope.of([.text, .caption]) == .allButCaptions)
    #expect(BulkVersionScope.of([.caption]) == .captionsV1Only)
    #expect(BulkVersionScope.of([.frame]) == .every)
    #expect(BulkVersionScope.allButCaptions.note(multi: 1, keepsWords: true)?.hasSuffix("keeps its own on-video words.") == true)
  }
}
