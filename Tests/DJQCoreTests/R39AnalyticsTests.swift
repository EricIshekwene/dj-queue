import Foundation
import Testing
@testable import DJQCore

/// Round 39: analytics history (snapshots), the pull schedule, and the Analytics report math. DECISIONS-R39.md.
@Suite struct R39AnalyticsTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  // MARK: Parsing

  @Test func parsesEveryShapePostizSends() throws {
    let bare = Data(#"[{"label":"Views","data":[{"total":"317","date":"2026-11-19"}]},{"label":"Recent Likes","data":[{"total":17,"date":"2026-11-19"}]}]"#.utf8)
    let s = try #require(AnalyticsParse.series(bare))
    #expect(s.count == 2 && s[0].key == .views && s[1].key == .likes && !s[0].isDaily)
    let v = PostSnapshot.values(from: s)
    #expect(v == ["views": 317, "likes": 17])
    let wrapped = Data(#"{"output":{"analytics":[{"label":"Plays","data":[{"total":"158","date":"2026-11-19"}]}]}}"#.utf8)
    #expect(AnalyticsParse.series(wrapped)?.first?.key == .views)
    #expect(AnalyticsParse.series(Data(#"{"output":{"analytics":[]}}"#.utf8))?.isEmpty == true)
    #expect(AnalyticsParse.series(Data(#"{"missing":true}"#.utf8))?.isEmpty == true)
    #expect(AnalyticsParse.series(Data("[]".utf8))?.isEmpty == true)
    #expect(AnalyticsParse.series(Data(#"{"weird":1}"#.utf8)) == nil)
    // Daily series: kept per day; as one number, daily counts sum and a running total keeps its last value.
    let daily = AnalyticsSeries(label: "Reach", points: [.init(date: "a", value: 0), .init(date: "b", value: 104), .init(date: "c", value: 30)])
    #expect(daily.isDaily && daily.total == 134)
    let running = AnalyticsSeries(label: "Views", points: [.init(date: "a", value: 10), .init(date: "b", value: 25)])
    #expect(running.total == 25)
    // Labels from every platform land on the shared keys.
    #expect(MetricKey.from(label: "Page followers") == .followersGained && MetricKey.from(label: "Subscribers Lost") == .followersLost)
    #expect(MetricKey.from(label: "Reactions") == .likes && MetricKey.from(label: "Reposts") == .shares && MetricKey.from(label: "Favorites") == .saves)
    let snap = PostSnapshot(postId: "p", takenAt: Date(), source: "postiz", values: ["views": 56, "reach": 43, "likes": 1, "comments": 2, "saves": 3])
    #expect(snap.interactions == 6 && snap.views == 56)
  }

  // MARK: Schedule

  @Test func pullsAtSetAgesAndBacksOffAfterNothing() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ d: Double) -> Date { t0.addingTimeInterval(d * 86400) }
    #expect(AnalyticsSchedule.due(postedAt: t0, last: nil, now: at(0.4)) == nil)
    #expect(AnalyticsSchedule.due(postedAt: t0, last: nil, now: at(0.5)) == 0.5)
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(0.5), now: at(0.9)) == nil)
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(0.5), now: at(1.2)) == 1)
    // A post first seen late gets its latest age once, not every missed one.
    #expect(AnalyticsSchedule.due(postedAt: t0, last: nil, now: at(16)) == 14)
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(16), now: at(29)) == nil)
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(16), now: at(30)) == 30)
    // After an empty answer only 30, 90, 180, 365.
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(0.5), lastWasEmpty: true, now: at(14)) == nil)
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(0.5), lastWasEmpty: true, now: at(31)) == 30)
    // Nothing after a year.
    #expect(AnalyticsSchedule.due(postedAt: t0, last: at(365), now: at(900)) == nil)
    #expect(AnalyticsSchedule.next(postedAt: t0, last: at(3), now: at(4)) == at(7))
    #expect(AnalyticsSchedule.next(postedAt: t0, last: at(365), now: at(400)) == nil)
  }

  // MARK: The engine's sweep (against FakePostiz)

  @Test func sweepKeepsASnapshotAtEachAgeAndTheChannelDaily() throws {
    let rig = try Rig(1, platforms: [.tiktok])
    rig.settle()
    rig.f.setTime("2026-11-02", "19:30")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.tick()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    #expect(try rig.store.snapshots(postId: tt.id).isEmpty)  // too young
    let channelCalls = rig.fake.calls("GET analytics/ch-").count
    #expect(channelCalls == 1)  // the channel's first pull (90 days back)
    for (hours, expected) in [(12.0, 1), (13.0, 1), (25.0, 2), (73.0, 3), (100.0, 3)] {
      rig.f.setTime("2026-11-02", "19:30")
      rig.f.clock.advance(hours * 3600)
      rig.tick(2)
      #expect(try rig.store.snapshots(postId: tt.id).count == expected, "after \(hours) h")
    }
    let s = try rig.store.snapshots(postId: tt.id)
    #expect(s.allSatisfy { $0.source == "postiz" && $0.views == 25 && $0.likes == 3 })
    #expect(try rig.store.post(id: tt.id)?.metrics?.views == 25)
    // Channel: the fake's 2-point Views series is daily (2 days stored); the 1-point Likes total only after the first pull.
    let ch = try rig.store.channelMetrics(platform: .tiktok)
    #expect(ch.filter { $0.label == "Views" && $0.kind == "daily" }.count == 2)
    #expect(ch.contains { $0.label == "Likes" && $0.kind == "total" })
    #expect(rig.fake.calls("GET analytics/ch-").count >= 3)  // once a day (20 h apart), not every tick
    #expect(rig.fake.calls("GET analytics/ch-").count <= 5)
  }

  @Test func sweepNeverAsksMoreThanItsHourlyShare() throws {
    let rig = try Rig(3)
    rig.settle()
    rig.f.setTime("2026-11-04", "20:00")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.tick(2)
    let published = try rig.service.analyticsTargets().count
    #expect(published > AnalyticsSchedule.perHour)
    let before = rig.fake.calls("GET analytics/post").count
    rig.f.clock.advance(20 * 86400)
    for _ in 0..<12 { rig.f.clock.advance(300); rig.tick() }  // one hour of ticks
    let asked = rig.fake.calls("GET analytics/post").count - before
    #expect(asked == AnalyticsSchedule.perHour)
    for _ in 0..<60 { rig.f.clock.advance(300); rig.tick() }  // five more hours: everyone due gets asked once
    let after = rig.fake.calls("GET analytics/post").count - before
    #expect(after == published)
  }

  @Test func anEmptyAnswerIsRecordedAndAskedAgainOnlyMonthly() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    rig.f.setTime("2026-11-02", "17:30")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.fake.analyticsBody = Data("[]".utf8)
    rig.tick()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    rig.f.clock.advance(13 * 3600); rig.tick()
    #expect(try rig.store.snapshotsByPost(includeEmpty: true)[x.id]?.map(\.source) == ["empty"])
    #expect(try rig.store.snapshots(postId: x.id).first?.isEmpty == true)
    let n = rig.fake.calls("GET analytics/post").count
    rig.f.clock.advance(10 * 86400); rig.tick()
    #expect(rig.fake.calls("GET analytics/post").count == n)
    rig.f.clock.advance(20 * 86400); rig.tick()
    #expect(rig.fake.calls("GET analytics/post").count == n + 1)
    // Empty answers never reach the charts or the post's metrics.
    #expect(try rig.store.snapshotsByPost()[x.id] == nil && rig.store.post(id: x.id)?.metrics == nil)
  }

  // MARK: Report math

  func posted(_ f: Fixture, _ id: String, _ video: String, _ p: Platform, _ at: Date, version: Int = 1, postNo: Int = 1,
              kind: PostKind = .regular) throws -> PlatformPost {
    var post = PlatformPost(id: id, videoId: video, platform: p, versionNo: version, attemptNo: 1, kind: kind, planSlotId: nil,
                            scheduledAt: at, renderId: nil, state: .posted, publisher: "postiz", externalId: nil, url: nil, postedAt: at,
                            errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: at, updatedAt: at)
    post.postNo = postNo
    try f.store.save(post)
    return post
  }

  @Test func reportAddsUpViewsPostsStreaksAndComparisons() throws {
    let f = try Fixture.engine(3)
    try f.updateSettings { $0.postsPerDay = 1; $0.enabledPlatforms = [.tiktok, .instagram] }
    let t0 = f.clock.now.addingTimeInterval(-20 * 86400)
    func day(_ d: Double) -> Date { t0.addingTimeInterval(d * 86400) }
    // clip-0: first post on TikTok, 1000 views at day 7, 1500 at day 14.
    let a = try posted(f, "a", "clip-0", .tiktok, day(0))
    try f.store.addSnapshot(PostSnapshot(postId: a.id, takenAt: day(7), source: "postiz", values: ["views": 1000, "likes": 100]))
    try f.store.addSnapshot(PostSnapshot(postId: a.id, takenAt: day(14), source: "postiz", values: ["views": 1500, "likes": 120]))
    // clip-1: a repost on TikTok, 400 views at day 7 (posted day 5).
    let b = try posted(f, "b", "clip-1", .tiktok, day(5), postNo: 2)
    try f.store.addSnapshot(PostSnapshot(postId: b.id, takenAt: day(12), source: "postiz", values: ["views": 400, "likes": 10]))
    // clip-2 on Instagram, a typed-in number only.
    _ = try posted(f, "c", "clip-2", .instagram, day(1))
    try PostActions(store: f.store).setMetrics(postId: "c", PostMetrics(views: 300, likes: 30, at: day(10)))
    #expect(try f.store.snapshots(postId: "c").first?.source == "manual")

    let r = try AnalyticsReport.build(store: f.store, range: .d30, now: f.clock.now)
    // Every view is counted once, inside the range.
    let views = try #require(r.kpis.first { $0.id == .views }?.value)
    #expect(abs(views - 2200) < 0.001)
    #expect(abs(r.timeline.reduce(0) { $0 + $1.totalViews } - 2200) < 0.001)
    #expect(r.kpis.first { $0.id == .posts }?.value == 3)
    #expect(r.bucket == "day" && r.timeline.count == 30)
    // Between snapshots views are spread evenly: day 7→14 of post a adds 500 over 7 days.
    let c = AnalyticsReport.Cumulative(postedAt: a.postedAt!, snapshots: try f.store.snapshots(postId: "a"), metric: { $0.views })
    #expect(abs(c.at(day(10.5)) - 1250) < 0.001)
    #expect(c.at(day(3)) > 500 && c.at(day(3)) < 1000)  // front-loaded before the first snapshot
    #expect(c.at(day(40)) == 1500)
    // First post vs repost, views after 7 days.
    let tt = try #require(r.repostCompare.first { $0.platform == .tiktok })
    #expect(tt.first.median == 1000 && tt.repost.median == 400)
    // Top clip and its platform.
    #expect(r.topClips.first?.videoId == "clip-0" && r.topClips.first?.bestPlatform == .tiktok)
    // Consistency: posts on days 0, 1 and 5 → longest streak 2, nothing today.
    #expect(r.consistency.longestStreak == 2 && r.consistency.currentStreak == 0)
    #expect(r.consistency.targetPerDay == 2 && r.consistency.daysOnTarget == 0)
    // Filter: Instagram alone.
    let ig = try AnalyticsReport.build(store: f.store, range: .all, platforms: [.instagram], now: f.clock.now)
    #expect(ig.platforms == [.instagram] && ig.kpis.first { $0.id == .posts }?.value == 1)
    // Library's per-clip views.
    let byVideo = try ClipAnalytics.viewsByVideo(store: f.store)
    #expect(byVideo == ["clip-0": 1500, "clip-1": 400, "clip-2": 300])
    let clip = try ClipAnalytics.build(store: f.store, videoId: "clip-0", now: f.clock.now)
    #expect(clip.totalViews == 1500 && clip.posts.first?.snapshots.count == 2)
    // JSON for the CLI round-trips.
    let data = try AgentAPI.encoder.encode(r)
    #expect(String(decoding: data, as: UTF8.self).contains("\"tiktok\""))
  }

  @Test func followersComeFromTheChannelsThatGiveThem() throws {
    let f = try Fixture.engine(1)
    let dm = DayMath(settings: try f.store.settings())
    let today = dm.key(f.clock.now)
    try f.store.saveChannelMetrics([
      ChannelMetricPoint(platform: .facebook, label: "Page followers", day: dm.addDays(today, -1), value: 3, kind: "daily", fetchedAt: f.clock.now),
      ChannelMetricPoint(platform: .youtube, label: "Subscribers Gained", day: dm.addDays(today, -2), value: 5, kind: "daily", fetchedAt: f.clock.now),
      ChannelMetricPoint(platform: .youtube, label: "Subscribers Lost", day: dm.addDays(today, -2), value: 1, kind: "daily", fetchedAt: f.clock.now),
      ChannelMetricPoint(platform: .tiktok, label: "Views", day: today, value: 5546, kind: "total", fetchedAt: f.clock.now),
    ])
    let r = try AnalyticsReport.build(store: f.store, range: .d7, now: f.clock.now)
    #expect(r.kpis.first { $0.id == .followers }?.value == 7)
    #expect(r.channels.contains { $0.platform == .tiktok && $0.kind == "total" && $0.headline == 5546 })
    #expect(r.availability.first { $0.platform == .x }?.postMetrics.isEmpty == true)
    // Same day again: the later pull wins.
    try f.store.saveChannelMetrics([ChannelMetricPoint(platform: .tiktok, label: "Views", day: today, value: 6000, kind: "total", fetchedAt: f.clock.now)])
    #expect(try f.store.channelMetrics(platform: .tiktok).map(\.value) == [6000])
  }

  // MARK: Review fixes

  @Test func anUnreadableAnswerOrA5xxNeverLoopsOrSkipsAges() throws {
    let rig = try Rig(1, platforms: [.tiktok])
    rig.settle()
    rig.f.setTime("2026-11-02", "19:30")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.tick()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    rig.fake.analyticsBody = Data(#"{"something":"new"}"#.utf8)
    rig.f.clock.advance(13 * 3600); rig.tick()
    let n = rig.fake.calls("GET analytics/post").count
    #expect(n == 1)
    for _ in 0..<12 { rig.f.clock.advance(300); rig.tick() }  // an hour of sweeps: not asked again
    #expect(rig.fake.calls("GET analytics/post").count == n)
    #expect(try rig.store.snapshotsByPost(includeEmpty: true)[tt.id] == nil)
    // A 5xx: nothing stored and the post keeps its ages (no empty backoff), asked again later.
    rig.fake.analyticsBody = nil
    rig.f.clock.advance(86400)
    rig.fake.failNext["GET analytics/post"] = [502]
    rig.tick()
    #expect(try rig.store.snapshotsByPost(includeEmpty: true)[tt.id] == nil)
    rig.f.clock.advance(3700); rig.tick()
    #expect(try rig.store.snapshots(postId: tt.id).map(\.source) == ["postiz"])
  }

  @Test func refreshWaitsForPostingAndKeepsItsCap() throws {
    let rig = try Rig(3)
    rig.settle()
    // A post being replaced: Refresh waits.
    var j = try #require(try rig.store.openPostizJobs().first)
    let phase = j.phase
    j.phase = .deleting
    try rig.store.save(j)
    #expect(try rig.service.analytics(force: true, limit: 12) == PostizService.waitingForPosting)
    j.phase = phase
    try rig.store.save(j)
    rig.f.setTime("2026-11-04", "20:00")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.tick(2)
    rig.f.clock.advance(3 * 86400)
    let before = rig.fake.calls("GET analytics").count
    _ = try rig.service.analytics(force: true, limit: 12)
    let made = rig.fake.calls("GET analytics").count - before
    #expect(made > 0 && made <= 12)
  }

  @Test func missedCountsOnlySlotsThatNeverWentOut() throws {
    let f = try Fixture.engine(3)
    try f.updateSettings { $0.postsPerDay = 1; $0.enabledPlatforms = [.tiktok] }
    let at = f.clock.now.addingTimeInterval(-2 * 86400)
    func post(_ id: String, _ v: String, _ s: PostState, attempt: Int = 1) throws {
      var p = try posted(f, id, v, .tiktok, at)
      p.state = s
      p.attemptNo = attempt
      if !s.wentOut { p.postedAt = nil }
      try f.store.save(p)
    }
    try post("a", "clip-0", .failed)  // failed, nothing after: missed
    try post("b", "clip-1", .overdue)  // a day went by unposted: missed
    try post("c", "clip-2", .failed)  // failed, then went out on a retry: not missed
    try post("c2", "clip-2", .posted, attempt: 2)
    let r = try AnalyticsReport.build(store: f.store, range: .d7, now: f.clock.now)
    #expect(r.consistency.missedInRange == 2)
  }

  @Test func averagesAreAveragedAndTheTileOpensOnWatchTime() throws {
    let yt = AnalyticsReport.ChannelTrend(platform: .youtube, label: "Average View Duration", key: .avgViewSeconds, kind: "daily",
                                          points: [.init(date: "a", value: 10), .init(date: "b", value: 20)])
    #expect(yt.headline == 15 && yt.isAverage)
    let mins = AnalyticsReport.ChannelTrend(platform: .youtube, label: "Estimated Minutes Watched", key: .watchMinutes, kind: "daily", points: [])
    #expect(mins.priority < yt.priority)
  }
}