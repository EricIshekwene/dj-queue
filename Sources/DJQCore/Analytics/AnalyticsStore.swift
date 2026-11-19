import Foundation

/// Round 39: where analytics history lives. Two additive tables, created idempotently on every open (the schema
/// number stays 12, so `djq autoupdate rollback` is still a plain swap: an older build just ignores them).
extension Store {
  static let analyticsSchema = """
    CREATE TABLE IF NOT EXISTS post_metric_snapshots(post_id TEXT NOT NULL, taken_at REAL NOT NULL,
      source TEXT NOT NULL, platform TEXT NOT NULL, video_id TEXT NOT NULL, values_json TEXT NOT NULL,
      views REAL, likes REAL, PRIMARY KEY(post_id, taken_at));
    CREATE INDEX IF NOT EXISTS post_metric_snapshots_video ON post_metric_snapshots(video_id);
    CREATE INDEX IF NOT EXISTS post_metric_snapshots_taken ON post_metric_snapshots(taken_at);
    CREATE INDEX IF NOT EXISTS postiz_jobs_video ON postiz_jobs(video_id);
    CREATE TABLE IF NOT EXISTS channel_metrics(platform TEXT NOT NULL, label TEXT NOT NULL, day TEXT NOT NULL,
      value REAL NOT NULL, kind TEXT NOT NULL, fetched_at REAL NOT NULL, PRIMARY KEY(platform, label, day));
    """

  func ensureAnalyticsTables() throws {
    try db.exec(Self.analyticsSchema)
    try backfillSnapshots()
  }

  static let backfillKey = "analytics.backfilled"

  /// Once: the views and likes posts already carried (round 6's daily pull, or typed in) become each post's first
  /// snapshot, at the time they were taken, so history starts from what DJ Queue already knew.
  func backfillSnapshots() throws {
    guard (try kv(Self.backfillKey, as: Bool.self)) != true else { return }
    try db.transaction {
      for p in try posts(where: "metrics IS NOT NULL AND id NOT IN (SELECT post_id FROM post_metric_snapshots)") {
        guard let m = p.metrics, m.views != nil || m.likes != nil else { continue }
        var values: [String: Double] = [:]
        if let v = m.views { values[MetricKey.views.rawValue] = Double(v) }
        if let l = m.likes { values[MetricKey.likes.rawValue] = Double(l) }
        try addSnapshot(PostSnapshot(postId: p.id, takenAt: m.at ?? p.updatedAt, source: p.publisher == "postiz" ? "postiz" : "manual",
                                     values: values), post: p)
      }
      try setKV(Self.backfillKey, true)
    }
  }

  // MARK: Post snapshots

  /// Adds one snapshot (same post and second → replaced). Also keeps `PlatformPost.metrics` (views, likes) at the
  /// newest non-empty numbers, which Calendar, Posts and `djq video` already show.
  public func addSnapshot(_ s: PostSnapshot, post: PlatformPost? = nil) throws {
    guard let p = try post ?? self.post(id: s.postId) else { return }
    try db.run("""
      INSERT INTO post_metric_snapshots(post_id,taken_at,source,platform,video_id,values_json,views,likes)
      VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(post_id,taken_at) DO UPDATE SET source=excluded.source,
      values_json=excluded.values_json, views=excluded.views, likes=excluded.likes
      """, [s.postId, s.takenAt, s.source, p.platform.rawValue, p.videoId, JSONCoding.string(s.values), s.views, s.likes])
  }

  public func snapshots(postId: String) throws -> [PostSnapshot] {
    try db.query("SELECT * FROM post_metric_snapshots WHERE post_id=? ORDER BY taken_at", [postId]).map(Self.snapshot)
  }

  /// Every snapshot, oldest first, grouped by post id (`includeEmpty`: also Postiz's empty answers).
  public func snapshotsByPost(includeEmpty: Bool = false) throws -> [String: [PostSnapshot]] {
    let rows = try db.query("SELECT * FROM post_metric_snapshots \(includeEmpty ? "" : "WHERE source<>'empty'") ORDER BY taken_at")
    return Dictionary(grouping: rows.map(Self.snapshot), by: \.postId)
  }

  /// One clip's snapshots (empty answers included), grouped by post id.
  public func snapshotsByPost(videoId: String) throws -> [String: [PostSnapshot]] {
    let rows = try db.query("SELECT * FROM post_metric_snapshots WHERE video_id=? ORDER BY taken_at", [videoId])
    return Dictionary(grouping: rows.map(Self.snapshot), by: \.postId)
  }

  /// When each post was last asked (empty answers included): what the pull schedule reads.
  public func lastSnapshotTimes() throws -> [String: Date] {
    var out: [String: Date] = [:]
    for r in try db.query("SELECT post_id, MAX(taken_at) AS t FROM post_metric_snapshots WHERE source<>'manual' GROUP BY post_id") {
      if let id = r.string("post_id"), let t = r.date("t") { out[id] = t }
    }
    return out
  }

  public func snapshotStats() throws -> (count: Int, first: Date?, last: Date?) {
    let r = try db.one("SELECT COUNT(*) AS n, MIN(taken_at) AS a, MAX(taken_at) AS b FROM post_metric_snapshots WHERE source<>'empty'")
    return (r?.int("n") ?? 0, r?.date("a"), r?.date("b"))
  }

  static func snapshot(_ r: Row) -> PostSnapshot {
    PostSnapshot(postId: r.string("post_id") ?? "", takenAt: r.date("taken_at") ?? .distantPast, source: r.string("source") ?? "postiz",
                 values: r.json("values_json") ?? [:])
  }

  // MARK: Channel metrics

  /// Upserts by (platform, label, day): a later pull of the same day wins (platforms revise recent days).
  public func saveChannelMetrics(_ pts: [ChannelMetricPoint]) throws {
    guard !pts.isEmpty else { return }
    try db.transaction {
      for p in pts {
        try db.run("""
          INSERT INTO channel_metrics(platform,label,day,value,kind,fetched_at) VALUES(?,?,?,?,?,?)
          ON CONFLICT(platform,label,day) DO UPDATE SET value=excluded.value, kind=excluded.kind, fetched_at=excluded.fetched_at
          """, [p.platform.rawValue, p.label, p.day, p.value, p.kind, p.fetchedAt])
      }
    }
  }

  public func channelMetrics(platform: Platform? = nil) throws -> [ChannelMetricPoint] {
    let rows = platform == nil
      ? try db.query("SELECT * FROM channel_metrics ORDER BY platform, label, day")
      : try db.query("SELECT * FROM channel_metrics WHERE platform=? ORDER BY label, day", [platform!.rawValue])
    return rows.compactMap { r in
      guard let p = r.string("platform").flatMap(Platform.init(rawValue:)) else { return nil }
      return ChannelMetricPoint(platform: p, label: r.string("label") ?? "", day: r.string("day") ?? "", value: r.double("value") ?? 0,
                                kind: r.string("kind") ?? "daily", fetchedAt: r.date("fetched_at") ?? .distantPast)
    }
  }
}
