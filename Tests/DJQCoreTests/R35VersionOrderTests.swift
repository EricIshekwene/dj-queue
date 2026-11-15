import Foundation
import Testing
@testable import DJQCore

/// Round 35: a clip's versions post in Eric's order ("v2, then v1, then v3"), days already planned swap which version they
/// carry, the version list says when each version posts, and a clip thrown away on purpose isn't "File missing"
/// (DECISIONS-R35.md).
@Suite struct R35VersionOrderTests {
  func setup(_ n: Int = 1, perDay: Int = 2, each: Int = 2) throws -> Fixture {
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

  func slots(_ f: Fixture, _ id: String) throws -> [PlanSlot] {
    try f.store.planSlots(where: "video_id=?", [id]).sorted { ($0.date, $0.position) < ($1.date, $1.position) }
  }

  @Test func normalizedOrderKeepsEveryVersionOnce() {
    #expect(VersionOrder.normalized([2, 1, 3], versions: [1, 2, 3]) == [2, 1, 3])
    #expect(VersionOrder.normalized([3, 3, 9], versions: [1, 2, 3]) == [3, 1, 2], "unknown and repeated numbers dropped, the rest after")
    #expect(VersionOrder.normalized([], versions: [3, 1, 2]) == [1, 2, 3])
    #expect(VersionOrder.normalized([2], versions: [1, 2, 4]) == [2, 1, 4], "a newer version posts after the listed ones")
    #expect(VersionOrder.text([2, 1, 3]) == "v2, then v1, then v3")
    #expect([1, 2, 3, 4, 11, 12, 13, 21, 22].map(VersionOrder.ordinal) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"])
  }

  @Test func theOrderDecidesWhichVersionPostsNextFirstPostsBeforeRepeats() throws {
    let f = try setup()
    try addVersion(f, "clip-0", 2)
    try addVersion(f, "clip-0", 3)
    #expect(try f.store.pendingUnits(videoId: "clip-0").map(\.description) == ["v1p1", "v2p1", "v3p1", "v1p2", "v2p2", "v3p2"])
    #expect(try f.store.setVersionOrder(videoId: "clip-0", [2, 1, 3]))
    #expect(try f.store.pendingUnits(videoId: "clip-0").map(\.description) == ["v2p1", "v1p1", "v3p1", "v2p2", "v1p2", "v3p2"])
    #expect(try f.store.versionOrder(videoId: "clip-0") == [2, 1, 3])
    #expect(try f.store.hasOwnVersionOrder(videoId: "clip-0"))
    #expect(try !f.store.setVersionOrder(videoId: "clip-0", [2, 1, 3]), "the same order changes nothing")
    // The plain order is stored as nothing.
    #expect(try f.store.setVersionOrder(videoId: "clip-0", nil))
    #expect(try f.store.versionOrders()["clip-0"] == nil)
    #expect(throws: EngineError.self) { try f.store.setVersionOrder(videoId: "clip-0", [4, 1]) }
    #expect(throws: EngineError.self) { try f.store.setVersionOrder(videoId: "clip-0", [2, 2]) }
  }

  @Test func theFirstDayGoesToTheFirstVersionInTheOrder() throws {
    let f = try setup()
    try addVersion(f, "clip-0", 2)
    try f.store.setVersionOrder(videoId: "clip-0", [2, 1])
    try Planner(store: f.store).autoSchedule()
    let first = try #require(try slots(f, "clip-0").first)
    #expect(first.unit == PostUnit(version: 2, post: 1))
    #expect(try f.store.slotPosts(first.id).allSatisfy { $0.versionNo == 2 && $0.postNo == 1 })
  }

  @Test func plannedDaysSwapWhichVersionTheyCarry() throws {
    let f = try setup()
    try addVersion(f, "clip-0", 2)
    try addVersion(f, "clip-0", 3)
    try Planner(store: f.store).autoSchedule()
    let before = try slots(f, "clip-0")
    #expect(before.first?.unit == .first)
    let firstDay = try #require(before.first)
    try f.store.setVersionOrder(videoId: "clip-0", [2, 1, 3])
    let after = try slots(f, "clip-0")
    // Same day and position, now v2 · 1 with its posts made again for v2; nothing else moved.
    let swapped = try #require(after.first { $0.id == firstDay.id })
    #expect(swapped.date == firstDay.date && swapped.position == firstDay.position)
    #expect(swapped.unit == PostUnit(version: 2, post: 1))
    let posts = try f.store.slotPosts(swapped.id)
    #expect(posts.count == Settings().activePlatforms.count)
    #expect(posts.allSatisfy { $0.versionNo == 2 && $0.postNo == 1 && $0.state == .planned && $0.renderId == nil })
    // The days keep their dates; the units on them follow the new order (v2 · 1, v1 · 1, v3 · 1, …).
    #expect(after.map(\.id) == before.map(\.id))
    let firstPosts = after.prefix { $0.postNo == 1 }.map(\.versionNo)
    #expect(Array(firstPosts) == Array([2, 1, 3].prefix(firstPosts.count)), "\(after.map(\.unit))")
    for s in after { #expect(try f.store.slotPosts(s.id).allSatisfy { $0.versionNo == s.versionNo && $0.postNo == s.postNo }) }
    #expect(after.count == before.count)
    #expect(try f.doublePosts().isEmpty)
    // The engine's next pass gives v1 · 1 a day; the spacing rules still hold.
    try Planner(store: f.store).autoSchedule()
    let all = try slots(f, "clip-0")
    for (i, a) in all.enumerated() {
      for b in all[(i + 1)...] where a.versionNo == b.versionNo {
        #expect(f.dm.days(from: a.date, to: b.date) >= (try f.store.settings()).sameVersionGapDays)
      }
    }
  }

  @Test func aDayAlreadyInPostizOrPostedKeepsItsVersion() throws {
    let f = try setup()
    try addVersion(f, "clip-0", 2)
    try Planner(store: f.store).autoSchedule()
    let first = try #require(try slots(f, "clip-0").first)
    // Inside the hour before it posts: it can't change any more.
    let soonest = try #require(try f.store.slotPosts(first.id).map(\.scheduledAt).min())
    f.clock.set(soonest.addingTimeInterval(-10 * 60))
    try f.store.setVersionOrder(videoId: "clip-0", [2, 1])
    let kept = try #require(try f.store.planSlots(where: "id=?", [first.id]).first)
    #expect(kept.unit == .first)
    #expect(try f.store.slotPosts(first.id).allSatisfy { $0.versionNo == 1 })
  }

  @Test func aPinnedDayStaysPinned() throws {
    let f = try setup()
    try addVersion(f, "clip-0", 2)
    try Planner(store: f.store).autoSchedule()
    let first = try #require(try slots(f, "clip-0").first)
    try f.store.db.run("UPDATE plan_slots SET pinned=1 WHERE id=?", [first.id])
    try f.store.setVersionOrder(videoId: "clip-0", [2, 1])
    let s = try #require(try f.store.planSlots(where: "id=?", [first.id]).first)
    #expect(s.pinned && s.date == first.date && s.unit == PostUnit(version: 2, post: 1))
  }

  @Test func theVersionListSaysWhenEachVersionPosts() throws {
    let f = try setup()
    try addVersion(f, "clip-0", 2)
    try Planner(store: f.store).autoSchedule()
    let settings = try f.store.settings()
    let posts = try f.store.posts(where: "video_id='clip-0'")
    let slots = try slots(f, "clip-0")
    let pending = try f.store.pendingUnits(videoId: "clip-0")
    func line(_ n: Int, inQueue: Bool = true, count: Int = 2, posts: [PlatformPost]? = nil, slots: [PlanSlot]? = nil,
              pending: [PostUnit]? = nil) -> String {
      VersionPlanLine.text(number: n, posts: posts ?? [], slots: slots ?? [], pending: pending ?? [], count: count,
                           inQueue: inQueue, now: f.clock.now, settings: settings)
    }
    let v1 = line(1, posts: posts, slots: slots, pending: pending)
    #expect(v1.hasPrefix("Planned to post "))
    #expect(!v1.contains("TikTok") && !v1.contains("Facebook"), "one time, no platform list")
    let earliest = try #require(posts.filter { $0.versionNo == 1 && $0.postNo == 1 }.map(\.scheduledAt).min())
    #expect(v1.contains(Sched.shortTime(earliest, settings)))
    #expect(line(2, pending: [PostUnit(version: 2, post: 1)]) == "Waiting for a day in the Queue")
    #expect(line(2, inQueue: false, pending: [PostUnit(version: 2, post: 1)]).hasPrefix("Not planned yet"))
    #expect(line(2, count: 0) == "Doesn't post (Posts: Never)")
    // A day with no posts yet says the day.
    let bare = PlanSlot(id: "s", date: f.dm.addDays(f.dm.key(f.clock.now), 3), position: 0, videoId: "clip-0", pinned: false,
                        weekStart: "2026-11-02", unit: PostUnit(version: 2, post: 1))
    #expect(line(2, slots: [bare]).hasPrefix("Planned to post "))
  }

  @Test func aClipThrownAwayOnPurposeIsRemovedNotMissing() throws {
    let f = try setup(2)
    try f.store.db.run("UPDATE videos SET missing=1, state='missing_file' WHERE id IN ('clip-0','clip-1')")
    try f.store.db.run("UPDATE videos SET excluded=1, in_manifest=0 WHERE id='clip-1'")
    let v0 = try #require(try f.store.video(id: "clip-0")), v1 = try #require(try f.store.video(id: "clip-1"))
    #expect(!v0.isDiscarded && v1.isDiscarded)
    let found = try Doctor(store: f.store).missingFiles()
    let missing = try #require(found.first { $0.id == "files.missing" })
    #expect(missing.severity == .error && missing.where_.count == 1 && missing.where_[0].hasPrefix("clip-0"))
    let removed = try #require(found.first { $0.id == "files.removed" })
    #expect(removed.severity == .info && removed.where_.count == 1 && removed.where_[0].hasPrefix("clip-1"))
  }
}
