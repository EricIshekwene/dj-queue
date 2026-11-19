import DJQCore
import Foundation

/// Round 39: twelve weeks of made-up posting history with numbers, for the Analytics shots only (its own copy of the
/// sample database, so no other shot changes). Fixed, deterministic numbers: nothing comes from a real account.
extension SampleData {
  static func seedAnalytics(store: Store, now: Date) throws {
    let st = try store.settings()
    let dm = DayMath(settings: st)
    let today = dm.key(now)
    let weekStart = dm.weekStart(of: now)
    let shorts = try store.videos(where: "type='short-form' AND excluded=0").sorted { $0.id < $1.id }
    guard shorts.count >= 20 else { return }
    let base: [Platform: Double] = [.tiktok: 900, .instagram: 260, .facebook: 420, .youtube: 160, .threads: 12, .x: 0]
    let likeRate: [Platform: Double] = [.tiktok: 0.07, .instagram: 0.05, .facebook: 0.012, .youtube: 0.03, .threads: 0.04, .x: 0]
    let start = dm.addDays(today, -84)
    var day = start
    var i = 0
    var firstPostOf: [String: String] = [:]  // clip → day of its first post
    while day < weekStart {
      let h = stableHash(day)
      // A few quiet days early on, then steadier posting (the consistency story).
      let quiet = (i < 28 && h % 4 == 0) || (i >= 28 && i < 56 && h % 9 == 0) || (i >= 56 && h % 23 == 0)
      if !quiet {
        // Every fourth day reposts a clip from three weeks back.
        let repostOf = i >= 21 && i % 4 == 0 ? dm.addDays(day, -21) : nil
        let clip: Video
        var postNo = 1
        if let r = repostOf, let back = firstPostOf.first(where: { $0.value == r })?.key, let v = shorts.first(where: { $0.id == back }) {
          clip = v
          postNo = 2
        } else {
          clip = shorts[i % shorts.count]
          firstPostOf[clip.id] = firstPostOf[clip.id] ?? day
        }
        let quality = 0.55 + Double(stableHash(clip.id) % 100) / 70  // 0.55…1.97: some clips just do better
        let trend = 0.75 + Double(i) / 84 * 0.6  // the account grows as posting gets steadier
        for p in st.activePlatforms {
          let at = dm.at(day, minutes: st.slot(for: p))
          let missed = h % 31 == Platform.allCases.firstIndex(of: p)!
          var post = PlatformPost(id: "sample-a-\(day)-\(p.rawValue)", videoId: clip.id, platform: p, versionNo: postNo == 2 && h % 2 == 0 ? 2 : 1,
                                  attemptNo: 1, kind: .regular, planSlotId: nil, scheduledAt: at, renderId: nil,
                                  state: missed ? .failed : .posted, publisher: "postiz", externalId: nil, url: nil,
                                  postedAt: missed ? nil : at, errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil,
                                  metrics: nil, createdAt: at, updatedAt: at)
          post.postNo = postNo
          try store.save(post)
          guard !missed else { continue }
          var lastViews = 0.0, lastLikes = 0.0
          defer {
            if lastViews > 0 { post.metrics = PostMetrics(views: Int(lastViews), likes: Int(lastLikes), at: now); try? store.save(post) }
          }
          let final = (base[p] ?? 0) * quality * trend * (postNo == 2 ? 0.62 : 1) * (0.8 + Double((h >> 3) % 40) / 100)
          for m in AnalyticsSchedule.milestones {
            let t = at.addingTimeInterval(m * 86400)
            guard t <= now else { break }
            if p == .x {
              try store.addSnapshot(PostSnapshot(postId: post.id, takenAt: t, source: "empty", values: [:]), post: post)
              break
            }
            let g = 1 - exp(-m / 1.6) * 0.92
            let views = (final * g).rounded()
            let likes = (views * (likeRate[p] ?? 0)).rounded()
            lastViews = views; lastLikes = likes
            try store.addSnapshot(PostSnapshot(postId: post.id, takenAt: t, source: "postiz",
                                               values: ["views": views, "likes": likes, "comments": (likes / 14).rounded(),
                                                        "shares": (likes / 9).rounded()]), post: post)
          }
        }
      }
      day = dm.addDays(day, 1)
      i += 1
    }

    // The accounts' own numbers.
    var pts: [ChannelMetricPoint] = []
    for k in 0..<90 {
      let d = dm.addDays(today, -89 + k)
      let h = Double(stableHash(d) % 100) / 100
      let g = 0.6 + Double(k) / 90
      pts.append(.init(platform: .facebook, label: "Page Impressions", day: d, value: (480 * g + 420 * h).rounded(), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .facebook, label: "Media views", day: d, value: (540 * g + 460 * h).rounded(), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .facebook, label: "Page followers", day: d, value: (h * 4 * g).rounded(), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .instagram, label: "Reach", day: d, value: (150 * g + 120 * h).rounded(), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .threads, label: "Views", day: d, value: (h * 4).rounded(), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .youtube, label: "Estimated Minutes Watched", day: d, value: (40 * g + 90 * h).rounded(), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .youtube, label: "Subscribers Gained", day: d, value: (h * 3).rounded(.down), kind: "daily", fetchedAt: now))
      pts.append(.init(platform: .youtube, label: "Subscribers Lost", day: d, value: h > 0.9 ? 1 : 0, kind: "daily", fetchedAt: now))
      if k >= 60 {  // TikTok: one running total a day since DJ Queue started asking
        pts.append(.init(platform: .tiktok, label: "Views", day: d, value: (3800 + Double(k - 60) * 95 + 60 * h).rounded(), kind: "total", fetchedAt: now))
        pts.append(.init(platform: .tiktok, label: "Recent Likes", day: d, value: (240 + Double(k - 60) * 6).rounded(), kind: "total", fetchedAt: now))
      }
    }
    try store.saveChannelMetrics(pts)
    try store.setKV(PostizService.channelAnalyticsKey, Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0.rawValue, now.addingTimeInterval(-3 * 3600)) }))
  }
}
