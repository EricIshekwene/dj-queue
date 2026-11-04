import Foundation

/// Where a Postiz job is in DJ Queue's own lifecycle (the remote state is `PostizJob.remoteState`).
public enum PostizJobPhase: String, Codable, Sendable {
  /// Claimed; the create request is in flight (or was interrupted — the sync step adopts or releases it).
  case creating
  /// Postiz holds the post.
  case live
  /// DJ Queue wants it gone; the DELETE hasn't succeeded yet. Nothing is created for the post meanwhile.
  case deleting
  /// The create was sent but its outcome is unknown and Postiz didn't show it after a sync. Never re-created blindly:
  /// it blocks its clip + platform until it is found in Postiz (adopted) or Eric confirms it isn't there
  /// (`PostizService.resolveUnknown`). Loud notice + Doctor `postiz.create_unknown`.
  case unknown
  case closed
}

/// Why a job closed. `isFinal` reasons end Postiz delivery for that platform post (it is never submitted again by
/// itself); the others leave the post free to be submitted again (e.g. after a replace or a paused platform).
public enum PostizCloseReason: String, Codable, Sendable, CaseIterable {
  /// Postiz published it (the post is recorded as posted).
  case published
  /// Test mode TikTok (UPLOAD): it is in the TikTok inbox; Eric finishes it and marks it posted.
  case inbox
  /// Postiz reported ERROR (the post is failed).
  case error
  /// Postiz reported a copyright problem (the post is copyright_blocked; never auto-retried).
  case copyright
  /// The post disappeared from Postiz (deleted there); the post falls back to Manual.
  case vanished
  /// Postiz refused the create (400); the post falls back to Manual.
  case rejected
  /// Deleted in Postiz because the DJ Queue post changed (a new job follows).
  case replaced
  /// Deleted in Postiz because the post shouldn't go out through Postiz any more (removed, paused, Manual, …).
  case cancelled
  /// A create that never confirmed and isn't in Postiz; the post may be submitted again.
  case interrupted
  /// `djq postiz test --draft` record (never synced).
  case testDraft = "test_draft"

  public var isFinal: Bool {
    switch self {
    case .published, .inbox, .error, .copyright, .vanished, .rejected, .testDraft: true
    case .replaced, .cancelled, .interrupted: false
    }
  }
}

/// One Postiz post DJ Queue made for one platform post (schema v5, `postiz_jobs`).
public struct PostizJob: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  /// `platform_posts.id` (kept after the post is deleted, so the job can still be cancelled).
  public var postId: String
  /// "post" (a platform post) or "test" (`djq postiz test --draft`).
  public var kind: String
  public var videoId: String?
  public var platform: Platform
  public var integrationId: String
  public var phase: PostizJobPhase
  public var postizId: String?
  public var postizGroup: String?
  public var mediaId: String?
  public var mediaPath: String?
  public var coverMediaId: String?
  public var coverMediaPath: String?
  public var renderId: String?
  public var contentHash: String
  /// The post's `scheduledAt` when the job was made (a moved post is replaced).
  public var scheduledAt: Date
  /// The `date` sent to Postiz (UTC; a slot already past went out as now + 3 min).
  public var remoteDate: Date
  public var testMode: Bool
  /// "schedule" or "draft".
  public var postType: String
  /// Postiz state: QUEUE, DRAFT, PUBLISHED, ERROR (nil until known).
  public var remoteState: String?
  public var remoteError: String?
  public var releaseURL: String?
  public var releaseId: String?
  public var submittedAt: Date?
  public var syncedAt: Date?
  public var closedAt: Date?
  public var closeReason: PostizCloseReason?
  /// Why a delete was requested (shown while `phase == .deleting`).
  public var deleteReason: String?
  /// Failed attempts of the current step (delete retries, …).
  public var attempts: Int
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date
  /// One clip on one platform (`PostizJob.lineage`): the never-double-post unit. Planner moves give a post a new id;
  /// the lineage stays, so a new job waits until every other job of the lineage is confirmed gone.
  public var lineage: String = ""

  public var isOpen: Bool { closedAt == nil }

  /// "video#platform#main" for regular posts and retries (one live post per clip and platform, ever), and
  /// "video#platform#v<N>" for a repost of version N.
  public static func lineage(videoId: String, platform: Platform, kind: PostKind, versionNo: Int) -> String {
    "\(videoId)#\(platform.rawValue)#\(kind == .repost ? "v\(versionNo)" : "main")"
  }
  public static func lineage(_ p: PlatformPost) -> String { lineage(videoId: p.videoId, platform: p.platform, kind: p.kind, versionNo: p.versionNo) }

  public init(id: String = newId(), postId: String, kind: String = "post", videoId: String?, platform: Platform,
              integrationId: String, phase: PostizJobPhase = .creating, postizId: String? = nil, postizGroup: String? = nil,
              mediaId: String? = nil, mediaPath: String? = nil, coverMediaId: String? = nil, coverMediaPath: String? = nil,
              renderId: String?, contentHash: String, scheduledAt: Date, remoteDate: Date, testMode: Bool, postType: String,
              remoteState: String? = nil, remoteError: String? = nil, releaseURL: String? = nil, releaseId: String? = nil,
              submittedAt: Date? = nil, syncedAt: Date? = nil, closedAt: Date? = nil, closeReason: PostizCloseReason? = nil,
              deleteReason: String? = nil, attempts: Int = 0, lastError: String? = nil, createdAt: Date, updatedAt: Date) {
    self.id = id; self.postId = postId; self.kind = kind; self.videoId = videoId; self.platform = platform
    self.integrationId = integrationId; self.phase = phase; self.postizId = postizId; self.postizGroup = postizGroup
    self.mediaId = mediaId; self.mediaPath = mediaPath; self.coverMediaId = coverMediaId; self.coverMediaPath = coverMediaPath
    self.renderId = renderId; self.contentHash = contentHash; self.scheduledAt = scheduledAt; self.remoteDate = remoteDate
    self.testMode = testMode; self.postType = postType; self.remoteState = remoteState; self.remoteError = remoteError
    self.releaseURL = releaseURL; self.releaseId = releaseId; self.submittedAt = submittedAt; self.syncedAt = syncedAt
    self.closedAt = closedAt; self.closeReason = closeReason; self.deleteReason = deleteReason; self.attempts = attempts
    self.lastError = lastError; self.createdAt = createdAt; self.updatedAt = updatedAt
  }
}

/// Media uploaded to Postiz for a render (schema v5, `postiz_media`): kind "video" or "cover".
public struct PostizMediaRecord: Codable, Sendable, Hashable {
  public var renderId: String
  public var kind: String
  public var mediaId: String
  public var mediaPath: String
  public var fileSize: Int64?
  public var uploadedAt: Date
  public init(renderId: String, kind: String, mediaId: String, mediaPath: String, fileSize: Int64?, uploadedAt: Date) {
    self.renderId = renderId; self.kind = kind; self.mediaId = mediaId; self.mediaPath = mediaPath
    self.fileSize = fileSize; self.uploadedAt = uploadedAt
  }
}

extension Store {
  static let postizSchema = """
    CREATE TABLE IF NOT EXISTS postiz_jobs(
      id TEXT PRIMARY KEY, post_id TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'post', video_id TEXT,
      platform TEXT NOT NULL, integration_id TEXT NOT NULL, phase TEXT NOT NULL,
      postiz_id TEXT, postiz_group TEXT, media_id TEXT, media_path TEXT, cover_media_id TEXT, cover_media_path TEXT,
      render_id TEXT, content_hash TEXT NOT NULL, scheduled_at REAL NOT NULL, remote_date REAL NOT NULL,
      test_mode INTEGER NOT NULL DEFAULT 0, post_type TEXT NOT NULL DEFAULT 'schedule',
      remote_state TEXT, remote_error TEXT, release_url TEXT, release_id TEXT,
      submitted_at REAL, synced_at REAL, closed_at REAL, close_reason TEXT, final INTEGER NOT NULL DEFAULT 0,
      delete_reason TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
      created_at REAL NOT NULL, updated_at REAL NOT NULL, lineage TEXT NOT NULL DEFAULT '');
    CREATE INDEX IF NOT EXISTS postiz_jobs_lineage ON postiz_jobs(lineage);
    CREATE UNIQUE INDEX IF NOT EXISTS postiz_jobs_one_live ON postiz_jobs(post_id) WHERE closed_at IS NULL AND kind='post';
    CREATE INDEX IF NOT EXISTS postiz_jobs_post ON postiz_jobs(post_id);
    CREATE INDEX IF NOT EXISTS postiz_jobs_open ON postiz_jobs(closed_at);
    CREATE TABLE IF NOT EXISTS postiz_media(render_id TEXT NOT NULL, kind TEXT NOT NULL, media_id TEXT NOT NULL,
      media_path TEXT NOT NULL, file_size INTEGER, uploaded_at REAL NOT NULL, PRIMARY KEY(render_id, kind));
    """

  // MARK: Jobs

  public func postizJobs(where clause: String = "1", _ binds: [SQLBindable?] = [], order: String = "created_at") throws -> [PostizJob] {
    try db.query("SELECT * FROM postiz_jobs WHERE \(clause) ORDER BY \(order)", binds).map(Self.postizJob)
  }

  public func postizJob(id: String) throws -> PostizJob? {
    try db.one("SELECT * FROM postiz_jobs WHERE id=?", [id]).map(Self.postizJob)
  }

  /// Jobs not closed yet (kind "post"), oldest first.
  public func openPostizJobs() throws -> [PostizJob] {
    try postizJobs(where: "closed_at IS NULL AND kind='post'")
  }

  /// The post's open job (at most one: a unique index enforces it).
  public func livePostizJob(postId: String) throws -> PostizJob? {
    try postizJobs(where: "post_id=? AND closed_at IS NULL AND kind='post'", [postId]).first
  }

  /// Every job made for a post, oldest first.
  public func postizJobs(postId: String) throws -> [PostizJob] { try postizJobs(where: "post_id=?", [postId]) }

  /// The closed job that ended Postiz delivery for this post (published, inbox, error, copyright, vanished,
  /// rejected), or nil. Such a post is never submitted again by itself.
  public func finalPostizJob(postId: String) throws -> PostizJob? {
    try postizJobs(where: "post_id=? AND closed_at IS NOT NULL AND final=1 AND kind='post'", [postId], order: "closed_at DESC").first
  }

  /// Open jobs of a clip + platform lineage (any post id).
  public func openPostizJobs(lineage: String) throws -> [PostizJob] {
    try postizJobs(where: "lineage=? AND closed_at IS NULL AND kind='post'", [lineage])
  }

  /// A job of the lineage that Postiz published (or holds as PUBLISHED): nothing is ever created for it again.
  public func publishedPostizJob(lineage: String) throws -> PostizJob? {
    try postizJobs(where: "lineage=? AND kind='post' AND (close_reason IN ('published','inbox') OR remote_state='PUBLISHED')",
                   [lineage], order: "updated_at DESC").first
  }

  /// Why the lineage can't get a new job now (nil = it can): another job is still open (not confirmed deleted), or
  /// one was published.
  public func postizLineageBlock(_ lineage: String, except postId: String? = nil) throws -> String? {
    if let p = try publishedPostizJob(lineage: lineage) { return "already published by Postiz (job \(p.id.prefix(8)))" }
    if let o = try openPostizJobs(lineage: lineage).first { return "an earlier Postiz post is still \(o.phase.rawValue)" }
    return nil
  }

  /// Inserts `job` as the post's open job. False when the post already has one, or its clip + platform lineage is
  /// blocked (another job not confirmed gone, or a published one) — checked in the same `BEGIN IMMEDIATE`, so two
  /// processes can't both pass.
  @discardableResult
  public func claimPostizJob(_ job: PostizJob) throws -> Bool {
    try db.transaction {
      if job.kind == "post", try livePostizJob(postId: job.postId) != nil { return false }
      if job.kind == "post", !job.lineage.isEmpty, try postizLineageBlock(job.lineage) != nil { return false }
      do {
        try insert(job)
        return true
      } catch let e as SQLiteError where e.message.localizedCaseInsensitiveContains("UNIQUE") {
        return false
      }
    }
  }

  /// Writes an existing job. A closed row is never reopened and keeps its first close (a stale copy from another
  /// process can't undo a delete); `final` is written only by `closePostizJob` / `releasePostizJobs`.
  public func save(_ j: PostizJob) throws {
    var j = j
    j.updatedAt = now
    if try postizJob(id: j.id) == nil { try insert(j); return }
    try db.run("""
      UPDATE postiz_jobs SET post_id=?, video_id=?, integration_id=?,
        phase=CASE WHEN closed_at IS NULL THEN ? ELSE phase END, postiz_id=COALESCE(postiz_id, ?), postiz_group=?,
        media_id=?, media_path=?, cover_media_id=?, cover_media_path=?, render_id=?, content_hash=?, scheduled_at=?,
        remote_date=?, test_mode=?, post_type=?, remote_state=?, remote_error=?, release_url=?, release_id=?,
        submitted_at=?, synced_at=?, closed_at=COALESCE(closed_at, ?), close_reason=COALESCE(close_reason, ?),
        delete_reason=?, attempts=?, last_error=?, updated_at=?, lineage=? WHERE id=?
      """, [j.postId, j.videoId, j.integrationId, j.phase.rawValue, j.postizId, j.postizGroup, j.mediaId, j.mediaPath,
            j.coverMediaId, j.coverMediaPath, j.renderId, j.contentHash, j.scheduledAt, j.remoteDate, j.testMode, j.postType,
            j.remoteState, j.remoteError, j.releaseURL, j.releaseId, j.submittedAt, j.syncedAt, j.closedAt,
            j.closeReason?.rawValue, j.deleteReason, j.attempts, j.lastError, j.updatedAt, j.lineage, j.id])
  }

  /// Closes a job (`phase` closed, `closed_at` now).
  public func closePostizJob(id: String, reason: PostizCloseReason, note: String? = nil) throws {
    guard var j = try postizJob(id: id) else { return }
    j.phase = .closed
    j.closedAt = now
    j.closeReason = reason
    if let note { j.lastError = note }
    try db.transaction {
      guard try postizJob(id: id)?.closedAt == nil else { return }  // first close wins
      try save(j)
      // `final` is written only here and by `releasePostizJobs` (a later save never undoes a release).
      try db.run("UPDATE postiz_jobs SET final=? WHERE id=?", [reason.isFinal, id])
    }
  }

  /// `PostActions.reset`: a post Eric reset may go through Postiz again — its error/rejected/vanished/interrupted
  /// jobs stop counting as final. Published, inbox and copyright jobs stay final (never double-post; copyright is
  /// never retried by itself).
  public func releasePostizJobs(postId: String) throws {
    try db.run("UPDATE postiz_jobs SET final=0, updated_at=? WHERE post_id=? AND close_reason IN ('error','rejected','vanished','interrupted')",
               [now, postId])
  }

  private func insert(_ j: PostizJob) throws {
    try db.run("""
      INSERT INTO postiz_jobs(id,post_id,kind,video_id,platform,integration_id,phase,postiz_id,postiz_group,media_id,media_path,
        cover_media_id,cover_media_path,render_id,content_hash,scheduled_at,remote_date,test_mode,post_type,remote_state,
        remote_error,release_url,release_id,submitted_at,synced_at,closed_at,close_reason,final,delete_reason,attempts,
        last_error,created_at,updated_at,lineage)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """, Self.binds(j) + [j.lineage])
  }

  static func binds(_ j: PostizJob) -> [SQLBindable?] {
    [j.id, j.postId, j.kind, j.videoId, j.platform.rawValue, j.integrationId, j.phase.rawValue, j.postizId, j.postizGroup,
     j.mediaId, j.mediaPath, j.coverMediaId, j.coverMediaPath, j.renderId, j.contentHash, j.scheduledAt, j.remoteDate,
     j.testMode, j.postType, j.remoteState, j.remoteError, j.releaseURL, j.releaseId, j.submittedAt, j.syncedAt, j.closedAt,
     j.closeReason?.rawValue, j.closeReason?.isFinal ?? false, j.deleteReason, j.attempts, j.lastError, j.createdAt, j.updatedAt]
  }

  static func postizJob(_ r: Row) -> PostizJob {
    PostizJob(id: r.string("id")!, postId: r.string("post_id")!, kind: r.string("kind") ?? "post", videoId: r.string("video_id"),
              platform: Platform(rawValue: r.string("platform") ?? "") ?? .tiktok, integrationId: r.string("integration_id") ?? "",
              phase: PostizJobPhase(rawValue: r.string("phase") ?? "") ?? .closed, postizId: r.string("postiz_id"),
              postizGroup: r.string("postiz_group"), mediaId: r.string("media_id"), mediaPath: r.string("media_path"),
              coverMediaId: r.string("cover_media_id"), coverMediaPath: r.string("cover_media_path"), renderId: r.string("render_id"),
              contentHash: r.string("content_hash") ?? "", scheduledAt: r.date("scheduled_at")!, remoteDate: r.date("remote_date")!,
              testMode: r.bool("test_mode"), postType: r.string("post_type") ?? "schedule", remoteState: r.string("remote_state"),
              remoteError: r.string("remote_error"), releaseURL: r.string("release_url"), releaseId: r.string("release_id"),
              submittedAt: r.date("submitted_at"), syncedAt: r.date("synced_at"), closedAt: r.date("closed_at"),
              closeReason: r.string("close_reason").flatMap(PostizCloseReason.init), deleteReason: r.string("delete_reason"),
              attempts: r.int("attempts") ?? 0, lastError: r.string("last_error"), createdAt: r.date("created_at")!,
              updatedAt: r.date("updated_at")!).with { $0.lineage = r.string("lineage") ?? "" }
  }

  // MARK: Media cache

  public func postizMedia(renderId: String, kind: String) throws -> PostizMediaRecord? {
    try db.one("SELECT * FROM postiz_media WHERE render_id=? AND kind=?", [renderId, kind]).map {
      PostizMediaRecord(renderId: $0.string("render_id")!, kind: $0.string("kind")!, mediaId: $0.string("media_id")!,
                        mediaPath: $0.string("media_path")!, fileSize: $0.int64("file_size"), uploadedAt: $0.date("uploaded_at")!)
    }
  }

  public func save(_ m: PostizMediaRecord) throws {
    try db.run("""
      INSERT INTO postiz_media(render_id,kind,media_id,media_path,file_size,uploaded_at) VALUES(?,?,?,?,?,?)
      ON CONFLICT(render_id,kind) DO UPDATE SET media_id=excluded.media_id, media_path=excluded.media_path,
        file_size=excluded.file_size, uploaded_at=excluded.uploaded_at
      """, [m.renderId, m.kind, m.mediaId, m.mediaPath, m.fileSize, m.uploadedAt])
  }

  public func deletePostizMedia(renderId: String) throws {
    try db.run("DELETE FROM postiz_media WHERE render_id=?", [renderId])
  }
}

extension PostizJob {
  func with(_ f: (inout PostizJob) -> Void) -> PostizJob { var c = self; f(&c); return c }
}
