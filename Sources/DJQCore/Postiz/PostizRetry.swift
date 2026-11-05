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
  public static let noRetryNote = "no automatic retry for this one, mark Fixed when it's ready"

  /// Words that mean more than "not now": a policy or rights problem, an account problem or a paid limit. One of
  /// them anywhere beats a temporary word, because re-posting a flagged clip risks a strike on the account.
  static let notTemporary = #"\b(violat\w*|infring\w*|intellectual property|dmca|content[- ]?id|copy[- ]right|trademark\w*|"#
    + #"(un)?licen[sc]\w*|songs?|sounds?|soundtracks?|tracks?|lyrics|strikes?|takedowns?|taken? down|third[- ]party|polic(y|ies)|"#
    + #"guidelines?|community|terms|not allowed|\w+n't allowed|spam\w*|flagged|reject\w*|remov\w*|revok\w*|bans?|banned|suspen\w*|restrict\w*|"#
    + #"block\w*|locked|disabled|deactivat\w*|terminated|denied|forbidden|unauthori[sz]ed|upgrade\w*|plans?|subscri\w*|storage)\b"#
  /// Only an explicit quota or rate limit. A generic "try again later" or "temporarily unavailable" says nothing about
  /// the cause. Word boundaries: never "quotation", "moderate limit" or "separate limit".
  static let plainlyTemporary = #"\bquotas?\b|\brate[- ]?limit|\btoo many requests\b|\breschedule this post for a later time\b"#

  /// Only clear wording counts; an unclear message stays a normal failure. Copyright and every `notTemporary` word win.
  public static func isTemporary(_ message: String) -> Bool {
    !isVetoed(message) && message.lowercased().range(of: plainlyTemporary, options: .regularExpression) != nil
  }

  static func isVetoed(_ message: String) -> Bool {
    isCopyright(message) || message.lowercased().range(of: notTemporary, options: .regularExpression) != nil
  }

  /// This failure may retry by itself on `platform`. YouTube only for the upload quota, where no video was created:
  /// any other error may come after the video exists (a rate limit on the thumbnail step), and a retry would double-post.
  public static func retriesByItself(_ message: String, on platform: Platform) -> Bool {
    guard platform == .youtube else { return isTemporary(message) }
    let m = message.lowercased()
    guard !isVetoed(message), !m.contains("thumbnail"), !m.contains("uploaded") else { return false }  // the video may exist
    return m.contains("daily upload quota") || m.contains("defaultvideoinsertperdayperproject")
  }

  static let autoRetryPrefix = "postiz.autoRetry."

  /// The version is in the key, so a repost counts apart from the clip's regular post.
  static func autoRetryKey(_ p: PlatformPost) -> String {
    "\(autoRetryPrefix)\(p.videoId)#\(p.platform.rawValue)#v\(p.versionNo)"
  }

  func autoRetries(_ p: PlatformPost) throws -> PostizAutoRetries { try store.kv(Self.autoRetryKey(p)) ?? PostizAutoRetries() }

  /// The sentence a Postiz ERROR adds to the post's message ("" for a normal failure). It promises a retry only when
  /// nothing permanent rules one out; a reason to wait (held clip, platform off Postiz) keeps the promise.
  func retryNote(_ message: String, _ p: PlatformPost) throws -> String {
    guard Self.retriesByItself(message, on: p.platform) else { return "" }
    if try autoRetries(p).count >= Self.maxAutoRetries { return " — \(Self.retriesUsedUpNote)" }
    return " — " + (try retryRuledOut(p) ? Self.noRetryNote : Self.retriesTomorrowNote)
  }

  /// This attempt came from a test-run job, so it must not go public.
  func mustStayTestRun(_ p: PlatformPost) throws -> Bool {
    guard p.kind != .regular else { return false }
    return try autoRetries(p).testRunPosts.contains(p.id)
  }

  /// This failure can never retry by itself: skipped in the editor, or a job of the clip + platform was published or
  /// was a copyright problem, or another post of it is posted or has one. The whole clip + platform, not one lineage.
  func retryRuledOut(_ p: PlatformPost) throws -> Bool {
    if (try? store.resolvedEdit(videoId: p.videoId))?.isSkipped(p.platform) == true { return true }
    let jobs = try store.postizJobs(where: """
      video_id=? AND platform=? AND kind='post' AND (close_reason IN ('published','inbox','copyright') OR remote_state='PUBLISHED')
      """, [p.videoId, p.platform.rawValue])
    guard jobs.isEmpty else { return true }
    return try store.posts(where: "video_id=? AND platform=?", [p.videoId, p.platform.rawValue])
      .contains { $0.id != p.id && ($0.state == .posted || $0.state.isCopyright) }
  }

  /// Another job of the clip + platform is open, or another post of it is live: not while that lasts.
  func retryMustWait(_ p: PlatformPost) throws -> Bool {
    let open = try store.postizJobs(where: "video_id=? AND platform=? AND kind='post' AND closed_at IS NULL", [p.videoId, p.platform.rawValue])
    guard open.isEmpty else { return true }
    return try store.posts(where: "video_id=? AND platform=?", [p.videoId, p.platform.rawValue])
      .contains { $0.id != p.id && !$0.state.isTerminal }
  }

  /// The failed job when `p` may be retried automatically now. Waiting reasons (platform paused or on Manual, clip
  /// held, another job open) are re-read every tick; the post stays Failed for Eric meanwhile.
  func retryableJob(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> PostizJob? {
    guard p.state == .failed, p.resolution == nil, p.errorType == .uploadFailed,
          let job = try store.finalPostizJob(postId: p.id), job.closeReason == .error,
          Self.retriesByItself(job.lastError ?? "", on: p.platform),
          try autoRetries(p).count < Self.maxAutoRetries,
          Self.settingsAllow(p.platform, settings), router.route(p.platform).isPostiz,
          let v = try store.video(id: p.videoId), !v.heldInEdit,
          try !retryRuledOut(p), try !retryMustWait(p) else { return nil }
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
