import Foundation

/// Posts → one card per (clip, scheduled day) (round 3 F4). The six platform posts of a slot share a card;
/// a retry or repost on another day forms its own card, one on the same day folds into that day's card.
public struct PostGroup: Identifiable, Sendable, Hashable {
  public var videoId: String
  /// YYYY-MM-DD of the posts' scheduled time (local day).
  public var day: String
  /// In time order (each platform's own slot time), then platform order, then attempt.
  public var posts: [PlatformPost]
  public var id: String { "\(videoId)|\(day)" }

  public var first: Date { posts.map(\.scheduledAt).min() ?? .distantPast }
  public var last: Date { posts.map(\.scheduledAt).max() ?? .distantPast }
  /// Retries and reposts folded into the card.
  public var extras: [PlatformPost] { posts.filter { $0.kind != .regular } }
  public var summary: String { PostGrouping.summary(posts) }
}

public enum PostGrouping {
  /// Groups `posts` by (video, `day(scheduledAt)`), keeping the order in which each group first appears in `posts`
  /// (so a list sorted for a tab stays sorted by its first post).
  public static func group(_ posts: [PlatformPost], day: (Date) -> String) -> [PostGroup] {
    var order: [String] = []
    var byKey: [String: PostGroup] = [:]
    for p in posts {
      let d = day(p.scheduledAt)
      let k = "\(p.videoId)|\(d)"
      if byKey[k] == nil {
        order.append(k)
        byKey[k] = PostGroup(videoId: p.videoId, day: d, posts: [])
      }
      byKey[k]!.posts.append(p)
    }
    let rank = Dictionary(uniqueKeysWithValues: Platform.allCases.enumerated().map { ($1, $0) })
    return order.map { k in
      var g = byKey[k]!
      g.posts.sort { a, b in
        (a.scheduledAt, rank[a.platform] ?? 0, a.attemptNo) < (b.scheduledAt, rank[b.platform] ?? 0, b.attemptNo)
      }
      return g
    }
  }

  /// One status word per post, as the Posts pills say it.
  public static func bucket(_ p: PlatformPost, retrying: Set<String> = []) -> String {
    if retrying.contains(p.id) { return "retrying" }
    return switch p.state {
    case .planned: "planned"
    case .rendering: "rendering"
    case .rendered: "rendered"
    case .due: "due now"
    case .overdue: "missed"
    case .posted: "posted"
    case .failed: p.resolution == nil ? "failed" : "retried"
    case .copyrightBlocked, .copyrightMuted, .removed: p.resolution == nil ? "copyright" : "handled"
    case .skipped: "skipped"
    }
  }

  /// "6 platforms · all rendered" / "4 posted · 1 failed · 1 due now", plus " · 1 retry" / " · 1 repost" for extras.
  /// `retrying`: posts with an automatic retry coming, which aren't failed for anyone reading the card.
  public static func summary(_ posts: [PlatformPost], retrying: Set<String> = []) -> String {
    guard !posts.isEmpty else { return "No posts" }
    let order = ["posted", "failed", "copyright", "missed", "due now", "retrying", "rendered", "rendering", "planned", "retried",
                 "handled", "skipped"]
    var counts: [String: Int] = [:]
    for p in posts { counts[bucket(p, retrying: retrying), default: 0] += 1 }
    let platforms = Set(posts.map(\.platform)).count
    var out: String
    if counts.count == 1, let only = counts.keys.first {
      out = platforms == 1 ? "1 platform · \(only)" : "\(platforms) platforms · all \(only)"
    } else {
      out = order.compactMap { b in counts[b].map { "\($0) \(b)" } }.joined(separator: " · ")
    }
    let retries = posts.filter { $0.kind == .retry }.count, reposts = posts.filter { $0.kind == .repost }.count
    if retries > 0 { out += " · \(retries) retr\(retries == 1 ? "y" : "ies")" }
    if reposts > 0 { out += " · \(reposts) repost\(reposts == 1 ? "" : "s")" }
    return out
  }
}
