import Foundation

// Round 39 (Analytics). What Postiz returns and how DJ Queue keeps it over time (DECISIONS-R39.md, docs/analytics.md).
//
// Postiz's post analytics are lifetime totals "as of now" (one data point dated today), and some channel metrics are
// the same. So the only way to see a trend is to keep a dated copy each time we ask: `post_metric_snapshots` holds one
// row per post per pull, `channel_metrics` one row per channel metric per day.

/// The metrics DJ Queue compares across platforms. Each Postiz label maps onto one (or none: it's kept raw).
public enum MetricKey: String, Codable, Sendable, CaseIterable, Hashable {
  case views, likes, comments, shares, saves, reach, quotes, engagement
  case impressions, watchMinutes, avgViewSeconds, avgViewPercent, followersGained, followersLost

  public var displayName: String {
    switch self {
    case .views: "Views"
    case .likes: "Likes"
    case .comments: "Comments"
    case .shares: "Shares"
    case .saves: "Saves"
    case .reach: "Reach"
    case .quotes: "Quotes"
    case .engagement: "Engagement"
    case .impressions: "Impressions"
    case .watchMinutes: "Minutes watched"
    case .avgViewSeconds: "Avg view (s)"
    case .avgViewPercent: "Avg view %"
    case .followersGained: "Followers gained"
    case .followersLost: "Followers lost"
    }
  }

  /// Postiz's label (any case) → key. Post and channel labels differ per platform; see docs/analytics.md.
  public static func from(label: String) -> MetricKey? {
    let l = label.lowercased().trimmingCharacters(in: .whitespaces)
    switch l {
    case "views", "plays", "video views", "media views", "recent views": return .views
    case "likes", "reactions", "recent likes": return .likes
    case "comments", "replies", "recent comments": return .comments
    case "shares", "reposts", "recent shares": return .shares
    case "saves", "favorites": return .saves
    case "reach": return .reach
    case "quotes": return .quotes
    case "engagement", "posts engagement": return .engagement
    case "impressions", "page impressions": return .impressions
    case "estimated minutes watched": return .watchMinutes
    case "average view duration": return .avgViewSeconds
    case "average view percentage": return .avgViewPercent
    case "page followers", "subscribers gained", "followers", "new followers": return .followersGained
    case "subscribers lost": return .followersLost
    default: return nil
    }
  }
}

/// One series from Postiz: `{label, data: [{total, date}]}`.
public struct AnalyticsSeries: Codable, Sendable, Hashable {
  public var label: String
  public var points: [Point]
  public struct Point: Codable, Sendable, Hashable {
    public var date: String
    public var value: Double
    public init(date: String, value: Double) { self.date = date; self.value = value }
  }
  public init(label: String, points: [Point]) { self.label = label; self.points = points }

  public var key: MetricKey? { MetricKey.from(label: label) }

  /// One point = a total for the asked period (Postiz's "as of now"); more = one value per day.
  public var isDaily: Bool { points.count > 1 }

  /// The series as one number: a cumulative run (never falling, starting above 0) gives its last value; daily counts
  /// give their sum. Same rule as round 6's `PostizAnalytics.parse`.
  public var total: Double? {
    let nums = points.map(\.value)
    guard let last = nums.last else { return nil }
    if nums.count > 1, nums.first! > 0, zip(nums, nums.dropFirst()).allSatisfy({ $0 <= $1 }) { return last }
    return nums.reduce(0, +)
  }
}

public enum AnalyticsParse {
  /// Reads Postiz's analytics body: a bare list, `{analytics: [...]}` or `{output: {analytics: [...]}}`. nil when the
  /// shape is unknown; an empty list when the platform returned nothing (X today) or the post is `{missing: true}`.
  public static func series(_ d: Data) -> [AnalyticsSeries]? {
    guard let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return nil }
    var list: [[String: Any]]?
    if let a = o as? [[String: Any]] { list = a }
    else if let m = o as? [String: Any] {
      if m["missing"] as? Bool == true { return [] }
      if let a = m["analytics"] as? [[String: Any]] { list = a }
      else if let out = m["output"] as? [String: Any], let a = out["analytics"] as? [[String: Any]] { list = a }
    } else if let a = o as? [Any], a.isEmpty { return [] }
    guard let list else { return nil }
    return list.compactMap { s in
      guard let label = s["label"] as? String, let data = s["data"] as? [[String: Any]] else { return nil }
      let pts = data.compactMap { e -> AnalyticsSeries.Point? in
        let v: Double? = (e["total"] as? NSNumber)?.doubleValue ?? (e["total"] as? String).flatMap { Double($0) }
        guard let v, v.isFinite else { return nil }
        return AnalyticsSeries.Point(date: e["date"] as? String ?? "", value: v)
      }
      return AnalyticsSeries(label: label, points: pts)
    }
  }
}

/// A post's numbers at one moment. `values` keeps every label Postiz sent (raw); the typed accessors read the keys.
public struct PostSnapshot: Codable, Sendable, Hashable {
  public var postId: String
  public var takenAt: Date
  /// "postiz" (pulled), "manual" (typed in Calendar / Posts) or "empty" (Postiz answered with nothing: counted for
  /// the pull schedule, left out of every chart).
  public var source: String
  public var values: [String: Double]

  public init(postId: String, takenAt: Date, source: String, values: [String: Double]) {
    self.postId = postId; self.takenAt = takenAt; self.source = source; self.values = values
  }

  public var isEmpty: Bool { values.isEmpty }

  public func value(_ k: MetricKey) -> Double? {
    if let v = values[k.rawValue] { return v }
    // Several raw labels can map onto one key (Instagram sends Views and Reach; TikTok "Recent Likes"): sum them.
    let hits = values.compactMap { MetricKey.from(label: $0.key) == k ? $0.value : nil }
    return hits.isEmpty ? nil : hits.reduce(0, +)
  }

  public var views: Double? { value(.views) }
  public var likes: Double? { value(.likes) }
  /// Likes + comments + shares + saves (whatever the platform sends).
  public var interactions: Double? {
    let parts = [MetricKey.likes, .comments, .shares, .saves, .quotes].compactMap { value($0) }
    return parts.isEmpty ? nil : parts.reduce(0, +)
  }

  /// From Postiz series: each series' `total`, keyed by its normalised key when it has one (raw label otherwise).
  public static func values(from series: [AnalyticsSeries]) -> [String: Double] {
    var out: [String: Double] = [:]
    for s in series {
      guard let t = s.total else { continue }
      let k = s.key?.rawValue ?? s.label
      out[k] = (out[k] ?? 0) + t
    }
    return out
  }
}

/// One channel (account) metric on one day. `daily`: the platform's own value for that day (Facebook impressions,
/// Instagram reach, YouTube minutes…). `total`: a running total Postiz only gives "as of now" (TikTok views, Instagram
/// likes over the asked window): DJ Queue stores one per day it asks, which is how its history builds up.
public struct ChannelMetricPoint: Codable, Sendable, Hashable {
  public var platform: Platform
  public var label: String
  public var day: String
  public var value: Double
  public var kind: String  // daily | total
  public var fetchedAt: Date
  public init(platform: Platform, label: String, day: String, value: Double, kind: String, fetchedAt: Date) {
    self.platform = platform; self.label = label; self.day = day; self.value = value; self.kind = kind; self.fetchedAt = fetchedAt
  }
  public var key: MetricKey? { MetricKey.from(label: label) }
}
