import Foundation

/// What the automatic retries did so far for one clip + platform + version (kv `postiz.autoRetry.<clip>#<platform>#v<N>`;
/// no schema change). It outlives the posts, so the cap holds across attempts.
public struct PostizAutoRetries: Codable, Sendable, Hashable {
  public var count = 0
  /// The newest attempt an automatic retry made.
  public var lastPostId: String?
  /// Attempts made from a test-run job: they stay test runs whatever the Test run switch says now. Retry posts are
  /// never re-created under a new id (the planner only re-creates regular posts), so the id is enough.
  public var testRunPosts: [String] = []
  public init() {}
}

/// An automatic retry that hasn't finished: the attempt it made, or a failed post the next tick re-queues.
public struct PostizPendingRetry: Sendable, Hashable {
  public var post: PlatformPost
  /// 1 or 2.
  public var number: Int
  /// False: `post` is the failure itself, still to be re-queued.
  public var queued: Bool
}

/// Temporary failures retry by themselves (DECISIONS-R8.md): a Postiz ERROR that clearly says "not now" (a quota, a
/// rate limit) needs no fix from Eric. It stays Failed and loud, and the tick step `retry` then re-queues it through
/// `PostActions.fixed`, at most `maxAutoRetries` times per clip + platform + version. Everything else stays a normal
/// failure, and nothing in here ever overrides copyright, a held clip or the never-double-post rules.
extension PostizService {
  public static let maxAutoRetries = 2
  /// Added to a temporary failure's message (every screen and the alert show `errorMessage`).
  public static let retriesTomorrowNote = "retries tomorrow automatically"
  public static let retriesUsedUpNote = "automatic retries used up, mark Fixed when it's ready"

  /// Only clear wording counts; an unclear message stays a normal failure. Copyright always wins.
  public static func isTemporary(_ message: String) -> Bool {
    guard !isCopyright(message) else { return false }
    let m = message.lowercased()
    if m.range(of: #"\bquotas?\b"#, options: .regularExpression) != nil { return true }  // never "quotation"
    return ["rate limit", "rate-limit", "ratelimit", "too many requests", "try again later",
            "reschedule this post for a later time", "temporarily unavailable"].contains { m.contains($0) }
  }

  static let autoRetryPrefix = "postiz.autoRetry."

  /// The version is in the key, not the post kind: `fixed` turns a repost into a `.retry`, and the count must follow.
  static func autoRetryKey(_ p: PlatformPost) -> String {
    "\(autoRetryPrefix)\(p.videoId)#\(p.platform.rawValue)#v\(p.versionNo)"
  }

  func autoRetries(_ p: PlatformPost) throws -> PostizAutoRetries { try store.kv(Self.autoRetryKey(p)) ?? PostizAutoRetries() }

  /// The sentence a Postiz ERROR adds to the post's message ("" for a normal failure).
  func retryNote(_ message: String, _ p: PlatformPost) throws -> String {
    guard Self.isTemporary(message) else { return "" }
    return " — " + (try autoRetries(p).count < Self.maxAutoRetries ? Self.retriesTomorrowNote : Self.retriesUsedUpNote)
  }

  /// This attempt came from a test-run job, so it must not go public.
  func mustStayTestRun(_ p: PlatformPost) throws -> Bool {
    guard p.kind == .retry else { return false }
    return try autoRetries(p).testRunPosts.contains(p.id)
  }

  /// The clip + platform can't get a new attempt: a job is open, published or was a copyright problem (any kind of
  /// post), or another post is live, posted or has a copyright problem.
  func retryBlocked(_ p: PlatformPost) throws -> Bool {
    let jobs = try store.postizJobs(where: """
      video_id=? AND platform=? AND kind='post'
        AND (closed_at IS NULL OR close_reason IN ('published','inbox','copyright') OR remote_state='PUBLISHED')
      """, [p.videoId, p.platform.rawValue])
    guard jobs.isEmpty else { return true }
    return try store.posts(where: "video_id=? AND platform=?", [p.videoId, p.platform.rawValue])
      .contains { $0.id != p.id && (!$0.state.isTerminal || $0.state == .posted || $0.state.isCopyright) }
  }

  /// The failed job when `p` may be retried automatically now. Waiting reasons (platform paused or on Manual, clip
  /// held, another job open) are re-read every tick; the post stays Failed for Eric meanwhile.
  func retryableJob(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> PostizJob? {
    guard p.state == .failed, p.resolution == nil, p.errorType == .uploadFailed,
          let job = try store.finalPostizJob(postId: p.id), job.closeReason == .error,
          Self.isTemporary(job.lastError ?? ""),
          try autoRetries(p).count < Self.maxAutoRetries,
          Self.settingsAllow(p.platform, settings), router.route(p.platform).isPostiz,
          let v = try store.video(id: p.videoId), !v.heldInEdit,
          try !store.resolvedEdit(videoId: v.id).isSkipped(p.platform),
          try !retryBlocked(p) else { return nil }
    return job
  }

  static let failedFromPostiz = "state='failed' AND resolution IS NULL AND error_type=? AND raw_response LIKE 'postiz:%'"

  /// The engine's `retry` step. It runs after `alerts` and only for a failure whose alert went out: a retried post
  /// leaves `problems()`, so re-queueing first would lose the alert. Each post is re-read inside its own
  /// `BEGIN IMMEDIATE`, so two processes ticking retry once. No read of the settings or Keychain with nothing to do.
  public func retryTemporary() throws -> String {
    let failed = try store.posts(where: Self.failedFromPostiz, [ErrorType.uploadFailed.rawValue])
    guard !failed.isEmpty else { return "none" }
    let settings = try store.settings()
    let router = try router(settings)
    let actions = PostActions(store: store)
    var queued = 0
    for c in failed where try store.wasNotified(PostActions.problemKey(c.id)) {
      guard try retryableJob(c, settings: settings, router: router) != nil else { continue }  // no write lock for these
      let done: Bool = try store.db.transaction {
        guard let p = try store.post(id: c.id), let job = try retryableJob(p, settings: settings, router: router) else { return false }
        let n = try actions.fixed(postId: p.id, by: "auto-retry")
        var r = try autoRetries(p)
        r.count += 1
        r.lastPostId = n.id
        if job.testMode { r.testRunPosts.append(n.id) }
        try store.setKV(Self.autoRetryKey(p), r)
        try store.logEvent("postiz", "\(p.platform.displayName): temporary failure, automatic retry \(r.count) of \(Self.maxAutoRetries) on \(Sched.shortTime(n.scheduledAt, settings))\(job.testMode ? " (stays a test run)" : "")",
                           videoId: p.videoId, postId: n.id)
        return true
      }
      if done { queued += 1 }
    }
    return queued == 0 ? "none" : "re-queued \(queued)"
  }

  /// Retries still to come, soonest first, for Doctor and `djq postiz status`.
  public func pendingAutoRetries() throws -> [PostizPendingRetry] {
    var out: [PostizPendingRetry] = []
    let rows = try store.db.query("SELECT json FROM kv WHERE substr(key, 1, ?) = ?", [Self.autoRetryPrefix.count, Self.autoRetryPrefix])
    for row in rows {
      guard let r: PostizAutoRetries = row.json("json"), let id = r.lastPostId, let p = try store.post(id: id),
            !p.state.isTerminal else { continue }
      out.append(PostizPendingRetry(post: p, number: r.count, queued: true))
    }
    let failed = try store.posts(where: Self.failedFromPostiz, [ErrorType.uploadFailed.rawValue])
    if !failed.isEmpty {
      let settings = try store.settings()
      let router = try router(settings)
      for p in failed where try retryableJob(p, settings: settings, router: router) != nil {
        out.append(PostizPendingRetry(post: p, number: try autoRetries(p).count + 1, queued: false))
      }
    }
    return out.sorted { $0.post.scheduledAt < $1.post.scheduledAt }
  }
}
