import Foundation

/// The Analytics screen's period (round 39).
public enum AnalyticsRange: String, Codable, Sendable, CaseIterable, Identifiable {
  case d7 = "7d", d30 = "30d", d90 = "90d", all
  public var id: String { rawValue }
  public var days: Int? {
    switch self {
    case .d7: 7
    case .d30: 30
    case .d90: 90
    case .all: nil
    }
  }
  public var label: String {
    switch self {
    case .d7: "7D"
    case .d30: "30D"
    case .d90: "90D"
    case .all: "All"
    }
  }
  public var longLabel: String {
    switch self {
    case .d7: "Last 7 days"
    case .d30: "Last 30 days"
    case .d90: "Last 90 days"
    case .all: "All time"
    }
  }
}

/// Everything the Analytics screen and `djq analytics --json` show, computed from DJ Queue's own records (posts,
/// versions, schedule) and the snapshots Postiz pulls left behind. Pure: `AnalyticsReport.build`. No guessing beyond
/// one documented estimate: between two snapshots views are spread evenly, and before a post's first snapshot they
/// follow a front-loaded curve (most short-form views come early). Charts that use it say so.
public struct AnalyticsReport: Codable, Sendable {
  public var generatedAt: Date
  public var range: AnalyticsRange
  public var platforms: [Platform]
  public var startDay: String
  public var endDay: String
  /// "day" or "week".
  public var bucket: String
  public var tracking: Tracking
  public var kpis: [KPI]
  public var timeline: [Bucket]
  public var consistency: Consistency
  public var curves: Curves
  public var repostCompare: [RepostCompare]
  public var versions: [GroupStat]
  public var weekdays: [GroupStat]
  public var topClips: [ClipStat]
  public var channels: [ChannelTrend]
  public var availability: [AvailabilityRow]

  public struct Tracking: Codable, Sendable {
    public var snapshots: Int
    public var firstSnapshot: Date?
    public var lastSnapshot: Date?
    public var postsPublished: Int
    public var postsWithNumbers: Int
    public var lastChannelPull: Date?
  }

  public enum KPIId: String, Codable, Sendable, CaseIterable { case views, likes, engagement, followers, posts, viewsPerPost }

  public struct KPI: Codable, Sendable, Identifiable {
    public var id: KPIId
    public var title: String
    public var value: Double?
    public var previous: Double?
    /// "count" or "percent" (value is 0…100).
    public var unit: String
    public var spark: [Double]
    public var note: String?
    public var change: Double? {
      guard let value, let previous else { return nil }
      if unit == "percent" { return value - previous }
      guard previous > 0 else { return nil }
      return (value - previous) / previous * 100
    }
  }

  /// One day (or week) of the timeline, per platform.
  public struct Bucket: Codable, Sendable, Identifiable {
    public var start: String
    /// Keyed by `Platform.rawValue` (plain JSON objects in `djq analytics --json`).
    public var views: [String: Double]
    public var likes: [String: Double]
    public var interactions: [String: Double]
    public var posts: [String: Int]
    public var followers: [String: Double]
    /// Median views (latest) of the posts published in this bucket.
    public var viewsPerPost: Double?
    public var id: String { start }
    public var totalViews: Double { views.values.reduce(0, +) }
    public var totalLikes: Double { likes.values.reduce(0, +) }
    public var totalPosts: Int { posts.values.reduce(0, +) }
    public var totalFollowers: Double { followers.values.reduce(0, +) }
    public var engagement: Double? {
      let v = totalViews
      return v > 0 ? interactions.values.reduce(0, +) / v * 100 : nil
    }
  }

  public struct Consistency: Codable, Sendable {
    public var days: [DayCell]
    public var weeks: [WeekStat]
    public var currentStreak: Int
    public var longestStreak: Int
    /// Days in the range with at least one post / days in the range (that have passed).
    public var activeDays: Int
    public var rangeDays: Int
    /// Days that met the target (posts per day × platforms), out of days since the first post.
    public var daysOnTarget: Int
    public var daysTracked: Int
    public var targetPerDay: Int
    public var missedInRange: Int
  }

  public struct DayCell: Codable, Sendable, Identifiable {
    public var day: String
    public var posts: Int
    public var missed: Int
    public var planned: Int
    public var isFuture: Bool
    public var id: String { day }
  }

  public struct WeekStat: Codable, Sendable, Identifiable {
    public var weekStart: String
    public var posts: Int
    public var target: Int
    public var views: Double
    public var id: String { weekStart }
  }

  public struct Curves: Codable, Sendable {
    /// Days after posting the curves are sampled at.
    public var ages: [Double]
    public var medians: [MedianCurve]
    public var posts: [PostCurve]
  }

  public struct MedianCurve: Codable, Sendable, Identifiable {
    public var platform: Platform
    /// (age, median views, posts at that age)
    public var points: [CurvePoint]
    public var id: String { platform.rawValue }
  }

  public struct CurvePoint: Codable, Sendable, Hashable {
    public var age: Double
    public var views: Double
    public var n: Int
  }

  public struct PostCurve: Codable, Sendable, Identifiable {
    public var postId: String
    public var videoId: String
    public var platform: Platform
    public var title: String
    public var postedAt: Date
    public var points: [CurvePoint]
    public var id: String { postId }
  }

  public struct RepostCompare: Codable, Sendable, Identifiable {
    public var platform: Platform
    public var first: GroupStat
    public var repost: GroupStat
    public var id: String { platform.rawValue }
  }

  /// A median of "views after 7 days" over a group of posts.
  public struct GroupStat: Codable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var median: Double?
    public var posts: Int
    public var id: String { key }
  }

  public struct ClipStat: Codable, Sendable, Identifiable {
    public var videoId: String
    public var title: String
    public var posts: Int
    /// Views gained in the range (all its posts on the chosen platforms).
    public var views: Double
    public var likes: Double
    /// All-time totals (latest snapshots).
    public var totalViews: Double
    public var engagement: Double?
    public var bestPlatform: Platform?
    /// Cumulative views per timeline bucket.
    public var spark: [Double]
    public var id: String { videoId }
  }

  public struct ChannelTrend: Codable, Sendable, Identifiable {
    public var platform: Platform
    public var label: String
    public var key: MetricKey?
    /// "daily" (the platform's own number per day) or "total" (one "as of" number per day DJ Queue asked).
    public var kind: String
    public var points: [AnalyticsSeries.Point]
    public var id: String { "\(platform.rawValue)·\(label)" }
    /// Sum for daily counts, the average for daily averages (view duration, view %), latest for totals.
    public var headline: Double? {
      if kind != "daily" { return points.last?.value }
      if isAverage { return points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count) }
      return points.map(\.value).reduce(0, +)
    }
    public var isAverage: Bool { key == .avgViewSeconds || key == .avgViewPercent }
    /// Which series a platform's tile opens on (views first, then watch time, impressions, reach …).
    public var priority: Int {
      switch key {
      case .views?: 0
      case .watchMinutes?: 1
      case .impressions?: 2
      case .reach?: 3
      case .followersGained?: 4
      case .likes?: 5
      default: isAverage ? 9 : 6
      }
    }
  }

  public struct AvailabilityRow: Codable, Sendable, Identifiable {
    public var platform: Platform
    public var postMetrics: [String]
    public var channelDaily: [String]
    public var channelTotals: [String]
    public var followers: String?
    public var note: String
    /// Labels seen in this database (beyond the table checked on 2026-11-19).
    public var seen: [String]
    public var id: String { platform.rawValue }
  }
}

// MARK: - What each platform gives (checked against Eric's channels through Postiz on 2026-11-19)

public enum AnalyticsAvailability {
  public static let checkedOn = "2026-11-19"

  public static func base(_ p: Platform) -> AnalyticsReport.AvailabilityRow {
    switch p {
    case .tiktok:
      return .init(platform: p, postMetrics: ["Views", "Likes", "Comments", "Shares"], channelDaily: [],
                   channelTotals: ["Views", "Recent Likes", "Recent Comments", "Recent Shares"], followers: nil,
                   note: "Account numbers come only as one total, so DJ Queue keeps one a day to draw the trend. No follower count.", seen: [])
    case .instagram:
      return .init(platform: p, postMetrics: ["Views", "Reach", "Likes", "Comments", "Shares", "Saves"], channelDaily: ["Reach"],
                   channelTotals: ["Views", "Likes", "Comments", "Shares", "Saves", "Replies"], followers: nil,
                   note: "Reach comes per day; the rest as 30-day totals. No follower count.", seen: [])
    case .facebook:
      return .init(platform: p, postMetrics: ["Plays", "Reactions", "Engagement"],
                   channelDaily: ["Page Impressions", "Media views", "Posts Engagement", "Page followers"], channelTotals: [],
                   followers: "New Page followers per day",
                   note: "Richest daily data. Post comments and shares aren't given.", seen: [])
    case .youtube:
      return .init(platform: p, postMetrics: ["Views", "Likes", "Comments", "Favorites"],
                   channelDaily: ["Estimated Minutes Watched", "Average View Duration", "Average View Percentage",
                                  "Subscribers Gained", "Subscribers Lost", "Likes"], channelTotals: [],
                   followers: "Subscribers gained and lost per day",
                   note: "Watch time and retention per day; channel views per day aren't given (post views are).", seen: [])
    case .threads:
      return .init(platform: p, postMetrics: ["Views", "Likes", "Replies", "Reposts", "Quotes"], channelDaily: ["Views"],
                   channelTotals: ["Likes", "Replies", "Reposts", "Quotes"], followers: nil,
                   note: "Views per day; the rest as 30-day totals. No follower count.", seen: [])
    case .x:
      return .init(platform: p, postMetrics: [], channelDaily: [], channelTotals: [], followers: nil,
                   note: "Postiz returns no analytics for X (post or account). Posts are still counted for consistency; X is asked again monthly in case that changes.",
                   seen: [])
    }
  }
}

// MARK: - Build

extension AnalyticsReport {
  /// Ages (days after posting) for the curves.
  public static let curveAges: [Double] = [0, 0.5, 1, 2, 3, 5, 7, 10, 14, 21, 30, 45, 60, 90]
  /// The age the comparisons use ("views after 7 days").
  public static let compareAge: Double = 7
  /// Time constant of the front-loaded estimate before a post's first snapshot (days).
  static let tau: Double = 1.5

  /// A post's cumulative views or likes over time from its snapshots (see the type's comment for the estimate).
  struct Cumulative {
    let postedAt: Date
    let pts: [(t: Date, v: Double)]
    var lastAt: Date? { pts.last?.t }

    /// `knownAt`: only the snapshots taken by then (the previous period "as it was known", so both periods are
    /// measured with the same lag behind their last day).
    init(postedAt: Date, snapshots: [PostSnapshot], knownAt: Date? = nil, metric: (PostSnapshot) -> Double?) {
      self.postedAt = postedAt
      var out: [(Date, Double)] = []
      var top = 0.0
      for s in snapshots.sorted(by: { $0.takenAt < $1.takenAt }) {
        guard let v = metric(s), s.takenAt > postedAt, s.takenAt <= (knownAt ?? .distantFuture) else { continue }
        top = max(top, v)
        out.append((s.takenAt, top))
      }
      pts = out
    }

    func at(_ t: Date) -> Double {
      guard let first = pts.first, t > postedAt else { return 0 }
      if t >= pts.last!.t { return pts.last!.v }
      if t <= first.t {
        let a = t.timeIntervalSince(postedAt) / 86400, b = first.t.timeIntervalSince(postedAt) / 86400
        let shape = (1 - exp(-a / AnalyticsReport.tau)) / max(1e-9, 1 - exp(-b / AnalyticsReport.tau))
        return first.v * min(1, max(0, shape))
      }
      for (p, q) in zip(pts, pts.dropFirst()) where t >= p.t && t <= q.t {
        let f = q.t.timeIntervalSince(p.t) > 0 ? t.timeIntervalSince(p.t) / q.t.timeIntervalSince(p.t) : 1
        return p.v + (q.v - p.v) * f
      }
      return pts.last!.v
    }
  }

  static func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  }

  /// Builds the report. `platforms` empty = every platform.
  public static func build(store: Store, range: AnalyticsRange, platforms: Set<Platform> = [], now: Date) throws -> AnalyticsReport {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let included = Platform.allCases.filter { platforms.isEmpty || platforms.contains($0) }
    let allPosts = try store.posts().filter { included.contains($0.platform) }
    let posted = allPosts.filter { $0.state.wentOut && $0.postedAt != nil }
    let snaps = try store.snapshotsByPost()
    let videos = Dictionary(uniqueKeysWithValues: try store.videos().map { ($0.id, $0) })
    let channelPts = try store.channelMetrics().filter { included.contains($0.platform) }

    // Range (local days, inclusive).
    let today = dm.key(now)
    let firstPost = posted.compactMap(\.postedAt).min()
    let startDay: String = {
      if let d = range.days { return dm.addDays(today, -(d - 1)) }
      return firstPost.map { dm.key($0) } ?? dm.addDays(today, -29)
    }()
    let spanDays = dm.days(from: startDay, to: today) + 1
    let weekly = spanDays > 92
    let bucketStarts: [String] = {
      if !weekly { return (0..<spanDays).map { dm.addDays(startDay, $0) } }
      var out: [String] = []
      var w = dm.weekStart(of: dm.date(startDay))
      while w <= today { out.append(w); w = dm.addDays(w, 7) }
      return out
    }()
    func bucketOf(_ day: String) -> String? {
      guard day >= startDay, day <= today else { return nil }
      return weekly ? dm.weekStart(of: dm.date(day)) : day
    }
    func bucketEnd(_ start: String) -> Date {
      let end = weekly ? dm.addDays(start, 7) : dm.addDays(start, 1)
      return min(now, dm.date(end))
    }
    func bucketBegin(_ start: String) -> Date { max(dm.date(start), dm.date(startDay)) }

    // Per-post cumulative curves.
    var viewsCum: [String: Cumulative] = [:], likesCum: [String: Cumulative] = [:], interCum: [String: Cumulative] = [:]
    for p in posted {
      guard let at = p.postedAt, let s = snaps[p.id], !s.isEmpty else { continue }
      let v = Cumulative(postedAt: at, snapshots: s, metric: { $0.views })
      if !v.pts.isEmpty { viewsCum[p.id] = v }
      let l = Cumulative(postedAt: at, snapshots: s, metric: { $0.likes })
      if !l.pts.isEmpty { likesCum[p.id] = l }
      let i = Cumulative(postedAt: at, snapshots: s, metric: { $0.interactions })
      if !i.pts.isEmpty { interCum[p.id] = i }
    }
    func latest(_ c: [String: Cumulative], _ id: String) -> Double? { c[id]?.pts.last?.v }

    // Timeline.
    var buckets: [String: Bucket] = Dictionary(uniqueKeysWithValues: bucketStarts.map {
      ($0, Bucket(start: $0, views: [:], likes: [:], interactions: [:], posts: [:], followers: [:], viewsPerPost: nil))
    })
    for b in bucketStarts {
      let a = bucketBegin(b), e = bucketEnd(b)
      guard e > a else { continue }
      for p in posted {
        if let c = viewsCum[p.id] { buckets[b]!.views[p.platform.rawValue, default: 0] += max(0, c.at(e) - c.at(a)) }
        if let c = likesCum[p.id] { buckets[b]!.likes[p.platform.rawValue, default: 0] += max(0, c.at(e) - c.at(a)) }
        if let c = interCum[p.id] { buckets[b]!.interactions[p.platform.rawValue, default: 0] += max(0, c.at(e) - c.at(a)) }
      }
    }
    var publishedIn: [String: [String]] = [:]  // bucket → post ids
    for p in posted {
      guard let b = bucketOf(dm.key(p.postedAt!)) else { continue }
      buckets[b]?.posts[p.platform.rawValue, default: 0] += 1
      publishedIn[b, default: []].append(p.id)
    }
    /// Views in a post's first day (posts at least a day old with a pull that far): the same age for every post, so
    /// newer posts aren't compared with older ones that had longer to grow.
    func firstDay(_ c: [String: Cumulative], _ id: String) -> Double? {
      guard let cum = c[id], let last = cum.lastAt, last.timeIntervalSince(cum.postedAt) >= 0.9 * 86400 else { return nil }
      return cum.at(cum.postedAt.addingTimeInterval(86400))
    }
    for (b, ids) in publishedIn {
      buckets[b]?.viewsPerPost = median(ids.compactMap { firstDay(viewsCum, $0) })
    }
    for c in channelPts where c.kind == "daily" {
      guard let k = c.key, k == .followersGained || k == .followersLost, let b = bucketOf(c.day) else { continue }
      buckets[b]?.followers[c.platform.rawValue, default: 0] += k == .followersGained ? c.value : -c.value
    }
    let timeline = bucketStarts.compactMap { buckets[$0] }

    // KPIs (with the same-length period before for the change).
    let rangeStart = dm.date(startDay)
    let prevStart = range.days.map { rangeStart.addingTimeInterval(-Double($0) * 86400) }
    func gained(_ c: [String: Cumulative], from a: Date, to e: Date) -> Double {
      posted.reduce(0) { s, p in s + (c[p.id].map { max(0, $0.at(e) - $0.at(a)) } ?? 0) }
    }
    func published(from a: Date, to e: Date) -> [PlatformPost] { posted.filter { $0.postedAt! >= a && $0.postedAt! < e } }
    func engagement(_ ps: [PlatformPost]) -> Double? {
      var v = 0.0, i = 0.0
      for p in ps { if let vv = latest(viewsCum, p.id), vv > 0, let ii = latest(interCum, p.id) { v += vv; i += ii } }
      return v > 0 ? i / v * 100 : nil
    }
    func perPost(_ ps: [PlatformPost], _ c: [String: Cumulative]) -> Double? { median(ps.compactMap { firstDay(c, $0.id) }) }
    func followers(from a: String, to e: String) -> Double? {
      let pts = channelPts.filter { $0.kind == "daily" && $0.day >= a && $0.day <= e && ($0.key == .followersGained || $0.key == .followersLost) }
      return pts.isEmpty ? nil : pts.reduce(0) { $0 + ($1.key == .followersGained ? $1.value : -$1.value) }
    }
    let inRange = published(from: rangeStart, to: now.addingTimeInterval(1))
    // The period before, the same length as the part of this period that has passed, as it was known at its end.
    let prevEnd = prevStart.map { $0.addingTimeInterval(now.timeIntervalSince(rangeStart)) }
    let inPrev = prevStart.flatMap { a in prevEnd.map { published(from: a, to: $0) } }
    var viewsPrev: [String: Cumulative] = [:], likesPrev: [String: Cumulative] = [:]
    if let prevEnd {
      for p in posted where p.postedAt! < prevEnd {
        guard let s = snaps[p.id] else { continue }
        let v = Cumulative(postedAt: p.postedAt!, snapshots: s, knownAt: prevEnd, metric: { $0.views })
        if !v.pts.isEmpty { viewsPrev[p.id] = v }
        let l = Cumulative(postedAt: p.postedAt!, snapshots: s, knownAt: prevEnd, metric: { $0.likes })
        if !l.pts.isEmpty { likesPrev[p.id] = l }
      }
    }
    let prevDayA = range.days.map { dm.addDays(startDay, -$0) }
    let followerPlatforms = Set(channelPts.filter { $0.key == .followersGained }.map(\.platform)).sorted().map(\.displayName)
    let kpis: [KPI] = [
      KPI(id: .views, title: "Views", value: gained(viewsCum, from: rangeStart, to: now),
          previous: prevStart.flatMap { a in prevEnd.map { gained(viewsPrev, from: a, to: $0) } }, unit: "count", spark: timeline.map(\.totalViews),
          note: "Gained in the period on every post"),
      KPI(id: .likes, title: "Likes", value: gained(likesCum, from: rangeStart, to: now),
          previous: prevStart.flatMap { a in prevEnd.map { gained(likesPrev, from: a, to: $0) } }, unit: "count", spark: timeline.map(\.totalLikes),
          note: "Gained in the period (reactions on Facebook)"),
      KPI(id: .engagement, title: "Engagement", value: engagement(inRange), previous: inPrev.flatMap(engagement), unit: "percent",
          spark: timeline.map { $0.engagement ?? 0 }, note: "Likes, comments, shares and saves per view, posts from the period"),
      KPI(id: .followers, title: "Followers", value: followers(from: startDay, to: today),
          previous: prevDayA.flatMap { followers(from: $0, to: dm.addDays(startDay, -1)) }, unit: "count",
          spark: timeline.map(\.totalFollowers),
          note: followerPlatforms.isEmpty ? "No platform here gives followers through Postiz"
            : "Net new, \(followerPlatforms.joined(separator: " + ")) only (the others don't give it)"),
      KPI(id: .posts, title: "Posts", value: Double(inRange.count), previous: inPrev.map { Double($0.count) }, unit: "count",
          spark: timeline.map { Double($0.totalPosts) }, note: "Posts that went out"),
      KPI(id: .viewsPerPost, title: "Views / post", value: perPost(inRange, viewsCum), previous: inPrev.flatMap { perPost($0, viewsPrev) },
          unit: "count", spark: timeline.map { $0.viewsPerPost ?? 0 }, note: "Median views in a post's first day, posts from the period"),
    ]

    // Consistency.
    let target = settings.postsPerDay * settings.activePlatforms.filter { included.contains($0) }.count
    let heatWeeks = min(52, max(26, (spanDays + 6) / 7))
    let heatStart = dm.addDays(dm.weekStart(of: now), -7 * (heatWeeks - 1))
    var postedByDay: [String: Int] = [:], missedByDay: [String: Int] = [:], plannedByDay: [String: Int] = [:]
    for p in posted { postedByDay[dm.key(p.postedAt!), default: 0] += 1 }
    // Missed = a failed or overdue post whose slot never went out and has no retry coming (a retried failure that
    // later posted isn't a miss; a platform Eric skipped isn't either).
    func unitKey(_ p: PlatformPost) -> String { "\(p.videoId)|\(p.platform.rawValue)|\(p.versionNo)|\(p.postNo)" }
    let settled = Set(allPosts.filter { $0.state.wentOut || (!$0.state.isTerminal && $0.state != .overdue) }.map(unitKey))
    for p in allPosts where !p.state.wentOut {
      let d = dm.key(p.scheduledAt)
      if [.failed, .overdue].contains(p.state) && p.scheduledAt < now && !settled.contains(unitKey(p)) { missedByDay[d, default: 0] += 1 }
      else if p.scheduledAt >= now, !p.state.isTerminal { plannedByDay[d, default: 0] += 1 }
    }
    let cells = (0..<(heatWeeks * 7)).map { i -> DayCell in
      let d = dm.addDays(heatStart, i)
      return DayCell(day: d, posts: postedByDay[d] ?? 0, missed: missedByDay[d] ?? 0, planned: plannedByDay[d] ?? 0, isFuture: d > today)
    }
    var current = 0, longest = 0, run = 0
    if let f = firstPost {
      var d = dm.key(f)
      while d <= today {
        if (postedByDay[d] ?? 0) > 0 { run += 1; longest = max(longest, run) } else if d != today { run = 0 }
        d = dm.addDays(d, 1)
      }
      current = run
    }
    let rangeDaysList = (0..<spanDays).map { dm.addDays(startDay, $0) }
    let activeDays = rangeDaysList.filter { (postedByDay[$0] ?? 0) > 0 }.count
    var onTarget = 0, tracked = 0
    if let f = firstPost {
      var d = dm.key(f)
      while d < today {
        tracked += 1
        if target > 0, (postedByDay[d] ?? 0) >= target { onTarget += 1 }
        d = dm.addDays(d, 1)
      }
    }
    let weekStarts: [String] = {
      var out: [String] = []
      var w = dm.weekStart(of: dm.date(range.days == nil ? startDay : dm.addDays(today, -7 * max(8, (spanDays + 6) / 7) + 1)))
      while w <= today { out.append(w); w = dm.addDays(w, 7) }
      return out
    }()
    let weeks = weekStarts.map { w -> WeekStat in
      let days = dm.weekDays(w)
      let a = dm.date(w), e = min(now, dm.date(dm.addDays(w, 7)))
      return WeekStat(weekStart: w, posts: days.reduce(0) { $0 + (postedByDay[$1] ?? 0) }, target: target * 7,
                      views: e > a ? gained(viewsCum, from: a, to: e) : 0)
    }
    let consistency = Consistency(days: cells, weeks: weeks, currentStreak: current, longestStreak: longest, activeDays: activeDays,
                                  rangeDays: spanDays, daysOnTarget: onTarget, daysTracked: tracked, targetPerDay: target,
                                  missedInRange: rangeDaysList.reduce(0) { $0 + (missedByDay[$1] ?? 0) })

    // Curves: per post up to its last snapshot; medians per platform.
    let curvePosts = posted.filter { p in viewsCum[p.id] != nil && (range.days == nil || p.postedAt! >= rangeStart.addingTimeInterval(-90 * 86400)) }
    var postCurves: [PostCurve] = []
    for p in curvePosts {
      let c = viewsCum[p.id]!
      let maxAge = c.lastAt!.timeIntervalSince(p.postedAt!) / 86400
      let pts = curveAges.filter { $0 <= maxAge + 0.01 }.map { CurvePoint(age: $0, views: c.at(p.postedAt!.addingTimeInterval($0 * 86400)), n: 1) }
      postCurves.append(PostCurve(postId: p.id, videoId: p.videoId, platform: p.platform, title: videos[p.videoId]?.displayName ?? p.videoId,
                                  postedAt: p.postedAt!, points: pts))
    }
    let medians: [MedianCurve] = included.compactMap { pl in
      let cs = postCurves.filter { $0.platform == pl }
      // Older ages only have older posts behind them; views never go down, so the median never does either.
      var top = 0.0
      let pts = curveAges.compactMap { a -> CurvePoint? in
        let vs = cs.compactMap { c in c.points.first { $0.age == a }?.views }
        return median(vs).map { top = max(top, $0); return CurvePoint(age: a, views: top, n: vs.count) }
      }
      return pts.count > 1 ? MedianCurve(platform: pl, points: pts) : nil
    }
    postCurves.sort { $0.postedAt > $1.postedAt }
    let curves = Curves(ages: curveAges, medians: medians, posts: Array(postCurves.prefix(300)))

    // Comparisons: views after 7 days, posts old enough (with a snapshot at least that old).
    func at7(_ p: PlatformPost) -> Double? {
      guard let c = viewsCum[p.id], let at = p.postedAt, c.lastAt!.timeIntervalSince(at) >= (compareAge - 0.5) * 86400 else { return nil }
      return c.at(at.addingTimeInterval(compareAge * 86400))
    }
    func isRepost(_ p: PlatformPost) -> Bool { p.kind == .repost || p.postNo > 1 }
    let comparePosts = posted.filter { range.days == nil || $0.postedAt! >= rangeStart.addingTimeInterval(-60 * 86400) }
    let repostCompare = included.compactMap { pl -> RepostCompare? in
      let ps = comparePosts.filter { $0.platform == pl }
      let f = ps.filter { !isRepost($0) }.compactMap(at7), r = ps.filter(isRepost).compactMap(at7)
      guard !f.isEmpty || !r.isEmpty else { return nil }
      return RepostCompare(platform: pl, first: GroupStat(key: "first", label: "First post", median: median(f), posts: f.count),
                           repost: GroupStat(key: "repost", label: "Repost", median: median(r), posts: r.count))
    }
    let versions = Set(comparePosts.map(\.versionNo)).sorted().compactMap { n -> GroupStat? in
      let vs = comparePosts.filter { $0.versionNo == n }.compactMap(at7)
      return vs.isEmpty ? nil : GroupStat(key: "v\(n)", label: "v\(n)", median: median(vs), posts: vs.count)
    }
    let weekdayNames = dm.calendar.shortWeekdaySymbols
    let weekdays = (0..<7).map { i -> GroupStat in
      let wd = (dm.calendar.firstWeekday - 1 + i) % 7 + 1
      let vs = comparePosts.filter { dm.calendar.component(.weekday, from: $0.postedAt!) == wd }.compactMap(at7)
      return GroupStat(key: "\(wd)", label: weekdayNames[wd - 1], median: median(vs), posts: vs.count)
    }

    // Top clips.
    let byVideo = Dictionary(grouping: posted, by: \.videoId)
    var clips: [ClipStat] = []
    for (vid, ps) in byVideo {
      let views = ps.reduce(0.0) { s, p in s + (viewsCum[p.id].map { max(0, $0.at(now) - $0.at(rangeStart)) } ?? 0) }
      let likes = ps.reduce(0.0) { s, p in s + (likesCum[p.id].map { max(0, $0.at(now) - $0.at(rangeStart)) } ?? 0) }
      let total = ps.reduce(0.0) { $0 + (latest(viewsCum, $1.id) ?? 0) }
      guard total > 0 else { continue }
      var byPl: [Platform: Double] = [:]
      for p in ps { byPl[p.platform, default: 0] += latest(viewsCum, p.id) ?? 0 }
      let inter = ps.reduce(0.0) { $0 + (latest(viewsCum, $1.id) != nil ? (latest(interCum, $1.id) ?? 0) : 0) }
      let spark = timeline.map { b in ps.reduce(0.0) { s, p in s + (viewsCum[p.id]?.at(bucketEnd(b.start)) ?? 0) } }
      clips.append(ClipStat(videoId: vid, title: videos[vid]?.displayName ?? vid, posts: ps.filter { $0.postedAt! >= rangeStart }.count,
                            views: views, likes: likes, totalViews: total, engagement: total > 0 ? inter / total * 100 : nil,
                            bestPlatform: byPl.filter { $0.value > 0 }.max { $0.value < $1.value }?.key, spark: spark))
    }
    clips.sort { $0.views != $1.views ? $0.views > $1.views : $0.totalViews > $1.totalViews }

    // Channel trends.
    let channelLabels = Dictionary(grouping: channelPts) { "\($0.platform.rawValue)\u{1}\($0.label)" }
    var channels: [ChannelTrend] = channelLabels.values.compactMap { pts in
      guard let f = pts.first else { return nil }
      let kind = pts.contains { $0.kind == "daily" } ? "daily" : "total"
      let inR = pts.filter { $0.kind == kind && $0.day >= startDay && $0.day <= today }.sorted { $0.day < $1.day }
        .map { AnalyticsSeries.Point(date: $0.day, value: $0.value) }
      return ChannelTrend(platform: f.platform, label: f.label, key: f.key, kind: kind, points: inR)
    }
    channels.sort { $0.platform != $1.platform ? Platform.allCases.firstIndex(of: $0.platform)! < Platform.allCases.firstIndex(of: $1.platform)!
      : ($0.kind != $1.kind ? $0.kind == "daily" : $0.label < $1.label) }

    // Availability: the checked table plus labels seen in this database.
    var seenLabels: [Platform: Set<String>] = [:]
    for p in posted { for s in snaps[p.id] ?? [] where s.source == "postiz" { seenLabels[p.platform, default: []].formUnion(s.values.keys) } }
    for c in channelPts { seenLabels[c.platform, default: []].insert(c.label) }
    let availability = Platform.allCases.map { p -> AvailabilityRow in
      var r = AnalyticsAvailability.base(p)
      r.seen = (seenLabels[p] ?? []).map { MetricKey(rawValue: $0)?.displayName ?? $0 }.sorted()
      return r
    }

    let stats = try store.snapshotStats()
    let pulls: [String: Date] = try store.kv(PostizService.channelAnalyticsKey) ?? [:]
    let tracking = Tracking(snapshots: stats.count, firstSnapshot: stats.first, lastSnapshot: stats.last, postsPublished: posted.count,
                            postsWithNumbers: viewsCum.count, lastChannelPull: pulls.values.max())
    return AnalyticsReport(generatedAt: now, range: range, platforms: included, startDay: startDay, endDay: today,
                           bucket: weekly ? "week" : "day", tracking: tracking, kpis: kpis, timeline: timeline,
                           consistency: consistency, curves: curves, repostCompare: repostCompare, versions: versions,
                           weekdays: weekdays, topClips: Array(clips.prefix(25)), channels: channels, availability: availability)
  }
}

// MARK: - One clip / one post (clip detail, inspector, `djq analytics clip|post`)

public struct ClipAnalytics: Codable, Sendable {
  public var videoId: String
  public var totalViews: Double
  public var totalLikes: Double
  public var posts: [PostLine]

  public struct PostLine: Codable, Sendable, Identifiable {
    public var postId: String
    public var platform: Platform
    public var versionNo: Int
    public var postNo: Int
    public var postedAt: Date?
    public var views: Double?
    public var likes: Double?
    public var interactions: Double?
    public var snapshots: [PostSnapshot]
    public var nextPull: Date?
    public var id: String { postId }
  }

  public static func build(store: Store, videoId: String, now: Date) throws -> ClipAnalytics {
    let posts = try store.posts(where: "video_id=?", [videoId]).filter { $0.state.wentOut }
    let snaps = try store.snapshotsByPost(videoId: videoId)
    let targets = Dictionary((try? PostizService.analyticsTargetsLight(store: store, videoId: videoId)) ?? [], uniquingKeysWith: { a, _ in a })
    var lines: [PostLine] = []
    for p in posts.sorted(by: { ($0.postedAt ?? $0.scheduledAt) < ($1.postedAt ?? $1.scheduledAt) }) {
      let all = snaps[p.id] ?? []
      let real = all.filter { !$0.isEmpty }
      let lastPull = all.filter { $0.source != "manual" }.last
      var next: Date?
      if let at = targets[p.id] {
        next = AnalyticsSchedule.next(postedAt: at, last: lastPull?.takenAt, lastWasEmpty: lastPull?.source == "empty", now: now)
      }
      let l = real.last
      lines.append(PostLine(postId: p.id, platform: p.platform, versionNo: p.versionNo, postNo: p.postNo, postedAt: p.postedAt,
                            views: l?.views ?? p.metrics?.views.map(Double.init), likes: l?.likes ?? p.metrics?.likes.map(Double.init),
                            interactions: l?.interactions, snapshots: real, nextPull: next))
    }
    return ClipAnalytics(videoId: videoId, totalViews: lines.compactMap(\.views).reduce(0, +), totalLikes: lines.compactMap(\.likes).reduce(0, +),
                         posts: lines)
  }

  /// Latest views per clip, every clip (Library's "Most views" sort and the views badges). One query.
  public static func viewsByVideo(store: Store) throws -> [String: Double] {
    var out: [String: Double] = [:]
    for r in try store.db.query("""
      SELECT s.video_id AS v, SUM(s.views) AS n FROM post_metric_snapshots s JOIN (SELECT post_id, MAX(taken_at) AS t
      FROM post_metric_snapshots WHERE views IS NOT NULL GROUP BY post_id) m ON m.post_id=s.post_id AND m.t=s.taken_at GROUP BY s.video_id
      """) {
      if let v = r.string("v") { out[v] = r.double("n") ?? 0 }
    }
    // Posts with typed-in numbers from before round 39 (no snapshot) still count.
    for p in try store.posts(where: "metrics IS NOT NULL AND id NOT IN (SELECT post_id FROM post_metric_snapshots)") {
      if let v = p.metrics?.views { out[p.videoId, default: 0] += Double(v) }
    }
    return out
  }
}

extension PostizService {
  /// Post id → posted time for a clip's published Postiz posts (no service needed: the schedule only needs dates).
  static func analyticsTargetsLight(store: Store, videoId: String) throws -> [(String, Date)] {
    try store.postizJobs(where: "close_reason='published' AND postiz_id IS NOT NULL AND kind='post' AND video_id=?", [videoId])
      .compactMap { j in
        guard let p = try store.post(id: j.postId) else { return nil }
        return (j.postId, p.postedAt ?? j.closedAt ?? j.remoteDate)
      }
  }
}
