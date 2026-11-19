import DJQCore
import Foundation

/// `djq analytics` (round 39): the Analytics screen as text or JSON, one clip's or post's numbers over time, what
/// each platform gives, and a budgeted pull now. Read-only except `refresh` (Postiz analytics reads + local snapshots;
/// it never posts, schedules or changes a post).
enum AnalyticsCommand {
  static let usage = """
      analytics [--range 7d|30d|90d|all] [--platform P[,P]] [--json]   views, likes, engagement, followers, posts and
                                      consistency over time (the Analytics screen)
      analytics clip <video> [--json]   each post of a clip: views, likes and every snapshot
      analytics post <post> [--json]    one post's snapshots and when it's asked next
      analytics available [--json]      what each platform gives through Postiz, and what's been seen here
      analytics refresh [--limit N] [--channels] [--json]   pull numbers now (budgeted Postiz reads; never posts)
    """

  static func run(_ store: Store, _ settings: Settings, _ wrote: inout Bool) throws -> Int32 {
    let json = flag("--json")
    let range = try option("--range").map { r -> AnalyticsRange in
      guard let v = AnalyticsRange(rawValue: r.lowercased()) else { throw CLIError("--range is 7d, 30d, 90d or all (got \(r))") }
      return v
    } ?? .d30
    let platforms = Set(try (option("--platform") ?? "").split(separator: ",").map { try platform(String($0)) })
    let now = store.clock.now
    switch args.first {
    case nil:
      let r = try AnalyticsReport.build(store: store, range: range, platforms: platforms, now: now)
      if json { try printJSON(r); return 0 }
      printReport(r, settings)
    case "help", "-h", "--help":
      print(usage)
    case "clip":
      let v = try resolveVideo(store, try arg(1, "video"))
      let c = try ClipAnalytics.build(store: store, videoId: v.id, now: now)
      if json { try printJSON(c); return 0 }
      print("\(v.displayName) · \(n(c.totalViews)) views · \(n(c.totalLikes)) likes")
      if c.posts.isEmpty { print("  (no posts went out yet)") }
      for p in c.posts {
        print("  \(pad(p.platform.displayName, 15)) v\(p.versionNo)\(p.postNo > 1 ? " ·\(p.postNo)" : "")  \(p.postedAt.map { fmt($0, settings) } ?? "-")  "
          + "\(p.views.map(n) ?? "–") views  \(p.likes.map(n) ?? "–") likes  \(p.snapshots.count) snapshot\(p.snapshots.count == 1 ? "" : "s")"
          + (p.nextPull.map { "  next \(fmt($0, settings))" } ?? ""))
      }
    case "post":
      let id = try arg(1, "post id")
      guard let p = try store.posts().first(where: { $0.id == id || $0.id.hasPrefix(id) }) else { throw CLIError("no post \(id)") }
      let c = try ClipAnalytics.build(store: store, videoId: p.videoId, now: now)
      guard let line = c.posts.first(where: { $0.postId == p.id }) else { throw CLIError("post \(id) hasn't gone out") }
      if json { try printJSON(line); return 0 }
      print("\(p.platform.displayName) · v\(p.versionNo) · posted \(p.postedAt.map { fmt($0, settings) } ?? "-")")
      for s in line.snapshots {
        let vals = s.values.sorted { $0.key < $1.key }.map { "\(MetricKey(rawValue: $0.key)?.displayName ?? $0.key) \(n($0.value))" }
        print("  \(fmt(s.takenAt, settings))  \(pad(s.source, 6))  \(vals.joined(separator: " · "))")
      }
      if line.snapshots.isEmpty { print("  (no numbers yet)") }
      if let nx = line.nextPull { print("next pull \(fmt(nx, settings))") }
    case "available", "availability":
      let r = try AnalyticsReport.build(store: store, range: .all, platforms: [], now: now)
      if json { try printJSON(r.availability); return 0 }
      print("What Postiz gives per platform (checked \(AnalyticsAvailability.checkedOn)):")
      for a in r.availability {
        print("  \(a.platform.displayName)")
        print("    post:     \(a.postMetrics.isEmpty ? "nothing" : a.postMetrics.joined(separator: ", "))")
        print("    daily:    \(a.channelDaily.isEmpty ? "–" : a.channelDaily.joined(separator: ", "))")
        print("    totals:   \(a.channelTotals.isEmpty ? "–" : a.channelTotals.joined(separator: ", "))")
        print("    followers \(a.followers ?? "–")")
        print("    \(a.note)")
        if !a.seen.isEmpty { print("    seen here: \(a.seen.joined(separator: ", "))") }
      }
      print("From DJ Queue itself: when each post went out, platform, version, repost number, missed slots, score.")
    case "refresh":
      let limit = try option("--limit").map { try intArg($0, "--limit", 1...60) } ?? 12
      let svc = PostizService(store: store)
      let s = flag("--channels") ? (try svc.channelAnalytics(force: true, limit: min(limit, 6)).pulled.map { "channels \($0)" }.joined(separator: " · "))
        : try svc.analytics(force: true, limit: limit)
      wrote = !s.isEmpty && s != PostizService.waitingForPosting  // new numbers: the app refreshes
      if json { try printJSON(["result": s.isEmpty ? "nothing new" : s]); return 0 }
      print(s.isEmpty ? "Nothing new (nothing due, or the Postiz budget is used up for this hour)." : s)
    default:
      throw CLIError("unknown analytics command \(args[0])\n\nusage:\n\(usage)")
    }
    return 0
  }

  static func n(_ v: Double) -> String {
    if abs(v) >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    if abs(v) >= 10_000 { return String(format: "%.1fK", v / 1000) }
    return String(Int(v.rounded()))
  }

  static func printReport(_ r: AnalyticsReport, _ settings: Settings) {
    print("Analytics · \(r.range.longLabel) (\(r.startDay) → \(r.endDay)) · \(r.platforms.count == 6 ? "all platforms" : r.platforms.map(\.displayName).joined(separator: ", "))")
    for k in r.kpis {
      let v = k.value.map { k.unit == "percent" ? String(format: "%.1f%%", $0) : n($0) } ?? "–"
      let ch = k.change.map { k.unit == "percent" ? String(format: " (%+.1f pts)", $0) : String(format: " (%+.0f%%)", $0) } ?? ""
      print("  \(pad(k.title, 13)) \(pad(v, 9))\(ch)  \(k.note ?? "")")
    }
    let c = r.consistency
    print("Consistency: streak \(c.currentStreak) d (longest \(c.longestStreak)) · posted on \(c.activeDays)/\(c.rangeDays) days"
      + " · on target \(c.daysOnTarget)/\(c.daysTracked) days (\(c.targetPerDay)/day) · missed \(c.missedInRange)")
    if !r.repostCompare.isEmpty {
      print("Views after 7 days, first post vs repost (median):")
      for x in r.repostCompare {
        print("  \(pad(x.platform.displayName, 15)) first \(x.first.median.map(n) ?? "–") (\(x.first.posts))  repost \(x.repost.median.map(n) ?? "–") (\(x.repost.posts))")
      }
    }
    if !r.topClips.isEmpty {
      print("Top clips (views in the period):")
      for x in r.topClips.prefix(10) {
        print("  \(pad(n(x.views), 7)) \(pad(x.title, 40)) \(x.bestPlatform?.shortName ?? "")")
      }
    }
    let t = r.tracking
    print("Tracking: \(t.postsWithNumbers)/\(t.postsPublished) posts with numbers · \(t.snapshots) snapshots"
      + (t.lastSnapshot.map { " · last \(fmt($0, settings))" } ?? ""))
  }
}
