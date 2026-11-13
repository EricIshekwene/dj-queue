import Foundation
import Testing
@testable import DJQCore

/// Round 31: every version of a clip is its own post in the plan, and each posts its count (2) on every platform, spaced
/// (DECISIONS-R31.md).
@Suite struct R31VersionUnitsTests {
  /// `n` Queue clips, posts/day 2, every version posting twice. The clock stands Monday 2026-11-02 09:00.
  func setup(_ n: Int = 3, perDay: Int = 2, each: Int = 2) throws -> Fixture {
    let f = try Fixture.engine(n)
    try f.updateSettings {
      $0.postsPerDay = perDay
      $0.postsPerVersion = each
    }
    return f
  }

  func addVersion(_ f: Fixture, _ id: String, _ n: Int) throws {
    var v = Version(number: n)
    v.text = "Hook \(n) \(id)"
    v.captionTemplateId = "short"
    v.standalone = true
    try f.store.save(v, videoId: id)
  }

  func slots(_ f: Fixture, _ id: String? = nil) throws -> [PlanSlot] {
    try f.store.planSlots().filter { id == nil || $0.videoId == id }.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
  }

  @Test func everyVersionPostsTwiceSpacedAndInterleaved() throws {
    let f = try setup(3)
    try addVersion(f, "clip-0", 2)
    let r = try Planner(store: f.store).autoSchedule()
    // clip-0: v1 and v2 twice each; clip-1 and clip-2: v1 twice. Eight version posts, each one day.
    #expect(r.scheduled == 8 && r.waiting == 0)
    let all = try slots(f)
    #expect(all.count == 8)
    #expect(Set(all.map { "\($0.videoId)#\($0.unit)" }).count == 8, "each version post has one day")
    #expect(Set(try slots(f, "clip-0").map(\.unit)) == [PostUnit(version: 1, post: 1), PostUnit(version: 2, post: 1),
                                                       PostUnit(version: 1, post: 2), PostUnit(version: 2, post: 2)])
    // Round robin: every clip's first post before any repeat, worst score first (Queue sort), new clips first.
    #expect(all.prefix(3).map(\.videoId) == ["clip-0", "clip-1", "clip-2"] && all.prefix(3).allSatisfy { $0.unit == .first })
    let dm = f.dm
    for id in ["clip-0", "clip-1", "clip-2"] {
      let mine = try slots(f, id)
      // Never back to back: two posts of one clip are at least 2 days apart, the same version at least 7.
      for (i, a) in mine.enumerated() {
        for b in mine[(i + 1)...] {
          #expect(dm.days(from: a.date, to: b.date) >= 2, "\(id) \(a.unit) \(a.date) / \(b.unit) \(b.date)")
          if a.versionNo == b.versionNo { #expect(dm.days(from: a.date, to: b.date) >= 7) }
        }
      }
      // Inside a clip: first posts before repeats, older versions first.
      #expect(mine.map(\.unit) == mine.map(\.unit).sorted())
    }
    // Two slots in a row are never the same clip.
    for (a, b) in zip(all, all.dropFirst()) { #expect(a.videoId != b.videoId) }
    // Each post carries its version post; one live post per version post and platform.
    for s in all {
      let posts = try f.store.slotPosts(s.id)
      #expect(posts.count == Settings().activePlatforms.count)
      #expect(posts.allSatisfy { $0.versionNo == s.versionNo && $0.postNo == s.postNo && $0.kind == .regular })
    }
    let lineages = try f.store.posts().map(PostizJob.lineage)
    #expect(Set(lineages).count == lineages.count, "every post is its own never-double-post lineage")
    #expect(try f.doublePosts().isEmpty)
    // YouTube never lands in the quiet window.
    #expect(try f.posts(.youtube).allSatisfy { YouTubeWindow.clear($0.scheduledAt, .youtube) == $0.scheduledAt })
    // A second pass has nothing to add.
    #expect(try Planner(store: f.store).autoSchedule().scheduled == 0)
  }

  @Test func aClipStaysInProgressUntilEveryVersionPostIsOut() throws {
    let f = try setup(1)
    try f.updateSettings { $0.enabledPlatforms = [.tiktok] }
    try Planner(store: f.store).autoSchedule()
    let a = PostActions(store: f.store)
    let ps = try f.store.posts().sorted { $0.scheduledAt < $1.scheduledAt }
    #expect(ps.map(\.unit) == [.first, PostUnit(version: 1, post: 2)])
    f.clock.set(ps[0].scheduledAt.addingTimeInterval(60))
    try a.markPosted(postId: ps[0].id, url: Fixture.postURLs[.tiktok]!)
    #expect(try f.store.video(id: "clip-0")?.state == .planned || f.store.video(id: "clip-0")?.state == .posting)
    #expect(ClipStage.of(try #require(try f.store.video(id: "clip-0"))) == .scheduled)
    f.clock.set(ps[1].scheduledAt.addingTimeInterval(60))
    try a.markPosted(postId: ps[1].id, url: "https://www.tiktok.com/@dj.lovd/video/2")
    #expect(try f.store.video(id: "clip-0")?.state == .posted)
  }

  @Test func aVersionsOwnCountWinsAndZeroTakesItOut() throws {
    let f = try setup(1)
    try addVersion(f, "clip-0", 2)
    #expect(try f.store.pendingUnits(videoId: "clip-0").count == 4)
    try f.store.setPostCount(videoId: "clip-0", number: 1, 3)
    try f.store.setPostCount(videoId: "clip-0", number: 2, 0)
    #expect(try f.store.pendingUnits(videoId: "clip-0") == [1, 2, 3].map { PostUnit(version: 1, post: $0) })
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 3)
    #expect(throws: EngineError.self) { try f.store.setPostCount(videoId: "clip-0", number: 1, PostUnits.maxCount + 1) }
    // The count never touches how the clip looks: no new preview stamp, the version's updated_at stays.
    let before = try f.store.db.one("SELECT updated_at FROM versions WHERE video_id='clip-0' AND number=2")?.double("updated_at")
    try f.store.setPostCount(videoId: "clip-0", number: 2, nil)
    #expect(try f.store.db.one("SELECT updated_at FROM versions WHERE video_id='clip-0' AND number=2")?.double("updated_at") == before)
    #expect(try f.store.pendingUnits(videoId: "clip-0").count == 5)
  }

  @Test func aCopiedVersionPostsTheDefaultCount() throws {
    let f = try setup(1)
    try f.store.setPostCount(videoId: "clip-0", number: 1, 4)
    let copy = VersionCopy.duplicate(try f.store.versions(videoId: "clip-0"), source: 1, as: 2, settings: try f.store.settings())
    #expect(copy.postCount == nil)
    try f.store.save(copy, videoId: "clip-0")
    #expect(try f.store.postCount(videoId: "clip-0", version: 2) == 2)
  }

  @Test func eachVersionPostIsItsOwnPostizLineageAndRetryKey() throws {
    func post(_ v: Int, _ k: Int, _ kind: PostKind = .regular) -> PlatformPost {
      var p = PlatformPost(id: "p", videoId: "c", platform: .tiktok, versionNo: v, attemptNo: 1, kind: kind, planSlotId: nil,
                           scheduledAt: Date(), renderId: nil, state: .planned, publisher: "postiz", externalId: nil, url: nil,
                           postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil,
                           createdAt: Date(), updatedAt: Date())
      p.postNo = k
      return p
    }
    // v1 · 1 keeps round 6's lineage and a repost of v2 keeps its own, so nothing already in Postiz changes key.
    #expect(PostizJob.lineage(post(1, 1)) == "c#tiktok#main" && PostizJob.lineage(post(1, 1, .retry)) == "c#tiktok#main")
    #expect(PostizJob.lineage(post(2, 1, .repost)) == "c#tiktok#v2" && PostizJob.lineage(post(2, 1)) == "c#tiktok#v2")
    #expect(PostizJob.lineage(post(1, 2)) == "c#tiktok#v1p2" && PostizJob.lineage(post(2, 2, .retry)) == "c#tiktok#v2p2")
    #expect(PostizService.autoRetryKey(post(1, 1)) == "postiz.autoRetry.c#tiktok#v1")
    #expect(PostizService.autoRetryKey(post(1, 2)) == "postiz.autoRetry.c#tiktok#v1p2")
    // A post from before round 31 reads as its version's first post.
    #expect(post(1, 1).postNumber == nil)
  }

  @Test func aRetryStaysTheSameVersionPost() throws {
    let f = try setup(1)
    try f.updateSettings { $0.enabledPlatforms = [.tiktok] }
    try Planner(store: f.store).autoSchedule()
    let second = try #require(try f.store.posts().first { $0.postNo == 2 })
    f.clock.set(second.scheduledAt.addingTimeInterval(60))
    let a = PostActions(store: f.store)
    try a.reportProblem(postId: second.id, type: .uploadFailed, message: "boom")
    let retry = try a.fixed(postId: second.id)
    #expect(retry.versionNo == 1 && retry.postNo == 2 && retry.kind == .retry)
    #expect(PostizJob.lineage(retry) == PostizJob.lineage(second))
  }

  @Test func longFormNeverReposts() throws {
    let f = try setup(1)
    let long = try #require(try f.store.videos(where: "type='long-form'").first)
    #expect(try f.store.pendingUnits(videoId: long.id).isEmpty)
    #expect(throws: EngineError.self) { try f.store.setPostCount(videoId: long.id, number: 1, 2) }
  }

  @Test func slotsAndPostsFromBeforeRound31ReadAsV1Post1() throws {
    let f = try setup(1)
    try Planner(store: f.store).autoSchedule()
    let s = try #require(try slots(f).first)
    #expect(try f.store.db.one("SELECT version_no, post_no FROM plan_slots WHERE id=?", [s.id])?.int("post_no") == nil)
    // A journal snapshot written before round 31 has no unit fields and decodes as v1 · 1.
    let old = #"{"id":"x","date":"2026-11-02","position":0,"videoId":"c","pinned":false,"weekStart":"2026-11-02"}"#
    let decoded = try JSONCoding.decoder.decode(PlanSlot.self, from: Data(old.utf8))
    #expect(decoded.unit == .first && decoded.versionNumber == nil)
  }

  /// Schema 12 on a schema-11 file: the columns arrive empty (v1 · 1), and a clip that had finished posting keeps the one
  /// post it had, while a scheduled clip gets its second.
  @Test func schema12KeepsTheBackCatalogueAsItWas() throws {
    let f = try Fixture.engine(2)
    try f.paths.ensure()
    let file = f.paths.database
    do {
      let s = try Store(paths: f.paths, clock: f.clock)
      _ = try Intake(store: s).run()
      for id in ["clip-0", "clip-1"] {
        var e = Edit()
        e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
        try s.save(e, videoId: id)
        var v = Version(number: 1)
        v.text = "T"
        v.captionTemplateId = "short"
        try s.save(v, videoId: id)
        try s.setScore(id, 50)
        try s.setSentToQueue(id, true)
      }
      var v2 = Version(number: 2)
      v2.text = "Old v2"
      v2.standalone = true
      try s.save(v2, videoId: "clip-0")
      try s.db.exec("""
        ALTER TABLE plan_slots DROP COLUMN version_no; ALTER TABLE plan_slots DROP COLUMN post_no;
        ALTER TABLE platform_posts DROP COLUMN post_no; DELETE FROM kv WHERE key='\(PostUnits.finishedKey)';
        UPDATE videos SET state='posted' WHERE id='clip-0'; UPDATE videos SET state='planned' WHERE id='clip-1';
        PRAGMA user_version = 11;
        """)
    }
    let s = try Store(paths: f.paths, clock: f.clock, path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == 12)
    let finished: [String: Int]? = try s.kv(PostUnits.finishedKey)
    #expect(finished == ["clip-0": 2])
    #expect(try s.postCount(videoId: "clip-0", version: 1) == 1 && s.postCount(videoId: "clip-1", version: 1) == 2)
    #expect(try s.postCount(videoId: "clip-0", version: 2) == 0, "an old v2 of a finished clip never posts by itself")
    #expect(try s.postCount(videoId: "clip-0", version: 3) == 2, "a version added later follows the new rule")
    let backups = try FileManager.default.contentsOfDirectory(atPath: f.paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema12-") })
  }

  @Test func pinAndPostTodayTakeTheNextVersionPost() throws {
    let f = try setup(1)
    try addVersion(f, "clip-0", 2)
    let planner = Planner(store: f.store)
    try planner.pin(videoId: "clip-0", date: "2026-11-05")
    #expect(try slots(f, "clip-0").map(\.unit) == [.first])
    try planner.autoSchedule()
    let units = try slots(f, "clip-0").map(\.unit)
    #expect(units.count == 4 && Set(units).count == 4)
  }

  @Test func theQueueShowsTheVersionPostsOfEachClip() throws {
    let f = try setup(2)
    try addVersion(f, "clip-1", 2)
    let units = try AgentAPI.units("clip-1", store: f.store, settings: f.store.settings())
    #expect(units.map(\.label) == ["v1 · 1 of 2", "v2 · 1 of 2", "v1 · 2 of 2", "v2 · 2 of 2"])
    #expect(units.allSatisfy { $0.status == "waiting" })
    try Planner(store: f.store).autoSchedule()
    #expect(try AgentAPI.units("clip-1", store: f.store, settings: f.store.settings()).allSatisfy { $0.status == "scheduled" && $0.date != nil })
  }
}
