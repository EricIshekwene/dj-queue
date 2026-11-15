import Foundation
import Testing
@testable import DJQCore

/// Round 36: Repost is off by default (each version posts once); a per-clip switch turns it on (DECISIONS-R36.md).
@Suite struct R36RepostOffTests {
  func slots(_ f: Fixture, _ id: String? = nil) throws -> [PlanSlot] {
    try f.store.planSlots().filter { id == nil || $0.videoId == id }.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
  }

  func addVersion(_ f: Fixture, _ id: String, _ n: Int) throws {
    var v = Version(number: n)
    v.text = "Hook \(n) \(id)"
    v.captionTemplateId = "short"
    v.standalone = true
    try f.store.save(v, videoId: id)
  }

  @Test func offByDefaultEachVersionPostsOnce() throws {
    let f = try Fixture.engine(3)
    try f.updateSettings { $0.postsPerDay = 2; $0.postsPerVersion = 2 }
    try addVersion(f, "clip-0", 2)
    #expect(try !f.store.repostOn(videoId: "clip-0"))
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 1)
    try Planner(store: f.store).autoSchedule()
    // clip-0: v1 and v2 once; clip-1, clip-2: v1 once. Labels read "v1", "v2" (no "1 of 2").
    #expect(try slots(f).count == 4)
    #expect(try slots(f).allSatisfy { $0.postNo == 1 })
    #expect(try UnitBook(store: f.store).label("clip-0", PostUnit(version: 2, post: 1)) == "v2")
    #expect(try Planner(store: f.store).schedulable(f.store.settings()).isEmpty)
  }

  @Test func onRepostsAndOffTakesThePlannedRepeatsOffAndClosesTheGaps() throws {
    let f = try Fixture.engine(4)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2 }
    try f.repostAll()
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f).count == 8)
    let firstDays = Dictionary(try slots(f).filter { $0.unit == .first }.map { ($0.videoId, $0.date) }, uniquingKeysWith: min)
    // Repost off on two clips: their repeats come off at once, the next pass closes the gaps in the same order.
    try f.store.setRepost(videoId: "clip-0", false)
    try f.store.setRepost(videoId: "clip-2", false)
    #expect(try slots(f, "clip-0").map(\.unit) == [.first] && slots(f, "clip-2").map(\.unit) == [.first])
    let r = try Planner(store: f.store).autoSchedule()
    #expect(r.relaid > 0)
    let all = try slots(f)
    #expect(all.count == 6)
    // The first posts sit on consecutive days again (the calendar closed up; the repeats keep their week's gap), and none
    // is later than before.
    let days = Set(all.filter { $0.unit == .first }.map(\.date)).sorted()
    #expect(f.dm.days(from: days.first!, to: days.last!) + 1 == days.count, "\(days)")
    for s in all where s.unit == .first { #expect(s.date <= firstDays[s.videoId]!) }
    #expect(try Planner(store: f.store).schedulable(f.store.settings()).isEmpty)
    #expect(try f.doublePosts().isEmpty)
    // A second pass changes nothing; Repost back on gives clip-0 its repeat again.
    let again = try Planner(store: f.store).autoSchedule()
    #expect(again.relaid == 0 && again.scheduled == 0)
    try f.store.setRepost(videoId: "clip-0", true)
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").map(\.unit) == [.first, PostUnit(version: 1, post: 2)])
  }

  /// Eric's Maladie clips: "2 of 2" went out (or is going out) before "1 of 2". With Repost off that post is the
  /// version's one post, so the later "1 of 2" comes off instead of posting the same video again.
  @Test func aRepeatThatAlreadyWentOutCountsAsTheOnePost() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2; $0.enabledPlatforms = [.tiktok] }
    try f.repostAll()
    try Planner(store: f.store).autoSchedule()
    let mine = try slots(f, "clip-0")
    #expect(mine.map(\.unit) == [.first, PostUnit(version: 1, post: 2)])
    // Swap them, as the old picker could: 2 of 2 on the first day, posted; 1 of 2 later.
    var a = mine[0], b = mine[1]
    a.unit = PostUnit(version: 1, post: 2)
    b.unit = .first
    for (s, u) in [(a, PostUnit(version: 1, post: 2)), (b, PostUnit.first)] {
      try f.store.save(s)
      for var p in try f.store.slotPosts(s.id) { p.versionNo = u.version; p.postNo = u.post; try f.store.save(p) }
    }
    let early = try #require(try f.store.slotPosts(a.id).first)
    f.clock.set(early.scheduledAt.addingTimeInterval(60))
    try PostActions(store: f.store).markPosted(postId: early.id, url: Fixture.postURLs[.tiktok]!)
    try f.store.setRepost(videoId: "clip-0", false)
    try Planner(store: f.store).autoSchedule()
    #expect(try slots(f, "clip-0").map(\.id) == [a.id], "the later 1 of 2 came off")
    #expect(try f.store.pendingUnits(videoId: "clip-0").isEmpty, "and nothing of v1 waits to post again")
  }

  @Test func zeroStillMeansNeverWithRepostOff() throws {
    let f = try Fixture.engine(1)
    try f.updateSettings { $0.postsPerVersion = 2 }
    try addVersion(f, "clip-0", 2)
    try f.store.setPostCount(videoId: "clip-0", number: 2, 0)
    #expect(try f.store.pendingUnits(videoId: "clip-0") == [.first])
    // A version's own count is Eric's override: it wins with Repost off too.
    try f.store.setPostCount(videoId: "clip-0", number: 1, 3)
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 3)
    try f.store.setPostCount(videoId: "clip-0", number: 1, nil)
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 1)
    try f.store.setRepost(videoId: "clip-0", true)
    #expect(try f.store.postCount(videoId: "clip-0", version: 1) == 2)
  }

  /// Review B1: "2 of 2" went out on TikTok only; with Instagram on too and Repost off, v1 · 1 still posts on Instagram,
  /// never again on TikTok, and the calendar settles (no re-lay every pass).
  @Test func aRepostOnOnePlatformDoesntPostAgainThereAndNothingChurns() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2; $0.enabledPlatforms = [.tiktok] }
    try f.repostAll()
    try Planner(store: f.store).autoSchedule()
    let mine = try slots(f, "clip-0")
    var a = mine[0], b = mine[1]
    a.unit = PostUnit(version: 1, post: 2)
    b.unit = .first
    for (s, u) in [(a, PostUnit(version: 1, post: 2)), (b, PostUnit.first)] {
      try f.store.save(s)
      for var p in try f.store.slotPosts(s.id) { p.versionNo = u.version; p.postNo = u.post; try f.store.save(p) }
    }
    let early = try #require(try f.store.slotPosts(a.id).first)
    f.clock.set(early.scheduledAt.addingTimeInterval(60))
    try PostActions(store: f.store).markPosted(postId: early.id, url: Fixture.postURLs[.tiktok]!)
    try f.updateSettings { $0.enabledPlatforms = [.tiktok, .instagram] }
    try f.store.setRepost(videoId: "clip-0", false)
    for _ in 0..<3 { try Planner(store: f.store).autoSchedule() }
    let r = try Planner(store: f.store).autoSchedule()
    #expect(r.relaid == 0 && r.scheduled == 0, "settled: \(r.summary)")
    let live = try f.store.posts().filter { $0.videoId == "clip-0" && $0.versionNo == 1 && $0.state != .skipped }
    #expect(live.filter { $0.platform == .tiktok }.count == 1, "TikTok has v1 once (the 2 of 2 that went out)")
    #expect(live.filter { $0.platform == .instagram }.count == 1, "Instagram still gets v1 once")
    #expect(try f.store.pendingUnits(videoId: "clip-0").isEmpty)
    #expect(try f.doublePosts().isEmpty)
  }
}
