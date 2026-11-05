import Foundation

/// What the automatic retries did so far for one clip + platform + version (kv `postiz.autoRetry.<clip>#<platform>#v<N>`;
/// no schema change). It outlives the posts, so the cap holds across attempts. Fields added after v0.8 are optional, so
/// a row written by an older build still decodes.
public struct PostizAutoRetries: Codable, Sendable, Hashable {
  public var count = 0
  /// The newest attempt an automatic retry made.
  public var lastPostId: String?
  /// Attempts made from a test-run job: they stay test runs whatever the Test run switch says now. Retry posts are
  /// never re-created under a new id (the planner only re-creates regular posts), so the id is enough.
  public var testRunPosts: [String] = []
  /// The failed post whose retry is coming. It counts only while that post is Failed and unhandled.
  public var failedPostId: String?
  /// When the failure happened (the time Postiz was to send it), not when the Mac noticed.
  public var failedAt: Date?
  /// When the retry is due, from `failedAt`. It may be in the past: the Mac slept through it, or posting was paused.
  public var nextRetryAt: Date?
  /// The clip went back to Edit and took its attempt with it: the try wasn't used, so the next attempt doesn't count.
  public var tryUnused: Bool?
  public init() {}
}

/// An automatic retry still to come, for every screen, Doctor and `djq postiz status`.
public struct PostizPendingRetry: Sendable, Hashable {
  public var post: PlatformPost
  /// 1…`maxAutoRetries`.
  public var number: Int
  /// False: `post` is the failure itself, its attempt still to be made.
  public var queued: Bool
  /// nil: it waits for `waiting`, or goes out as soon as nothing is in its way.
  public var at: Date?
  /// "when posting resumes": what it waits for. Resuming is all it takes.
  public var waiting: String?
  /// It waits for a setting Eric may not change back soon (the platform is on Manual or off, no usable channel or key).
  public var offPostiz = false
  /// "Retrying Thu 8:00 am (try 2 of 5)".
  public var text: String
}

/// When a failed post goes out again (DECISIONS-R9.md). Pure, so every time can be tested with a clock.
public enum PostizRetrySchedule {
  /// "Morning" in Settings' time zone, and the hour a YouTube quota retry aims for.
  public static let morningHour = 8
  /// "Next morning" is never sooner than this after the failure.
  public static let morningGap: TimeInterval = 3600

  /// Retry `number` (1…5) of a failure at `failedAt`: +1 h, +6 h, next morning, +1 day, +1 day (a calendar day, the same
  /// clock time across a DST change). YouTube only retries its upload quota, so it always skips to the next reset.
  public static func next(after failedAt: Date, retry number: Int, platform: Platform, settings: Settings) -> Date {
    if platform == .youtube { return youTubeQuota(after: failedAt).retry }
    let dm = DayMath(settings: settings)
    switch number {
    case 1: return failedAt.addingTimeInterval(3600)
    case 2: return failedAt.addingTimeInterval(6 * 3600)
    case 3:
      let soonest = failedAt.addingTimeInterval(morningGap)
      let day = dm.key(soonest)
      let morning = dm.at(day, minutes: morningHour * 60)
      return morning >= soonest ? morning : dm.at(dm.addDays(day, 1), minutes: morningHour * 60)
    default: return Sched.shift(failedAt, days: 1, dm)
    }
  }

  /// YouTube's quota resets at midnight Pacific. The retry goes at 8:00 am New York on the day of the first reset after
  /// the failure, whatever Settings' time zone says: a failure at 7:00 am New York is after that day's reset, so it
  /// waits for the next one.
  public static func youTubeQuota(after failedAt: Date) -> (reset: Date, retry: Date) {
    var pacific = Calendar(identifier: .gregorian)
    pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let reset = pacific.nextDate(after: failedAt, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
      ?? failedAt.addingTimeInterval(86400)
    var day = newYork.dateComponents([.year, .month, .day], from: reset)
    day.hour = morningHour
    return (reset, newYork.date(from: day) ?? reset)
  }
}

extension Store {
  func autoRetries(_ p: PlatformPost) throws -> PostizAutoRetries {
    try kv(PostizService.autoRetryKey(p)) ?? PostizAutoRetries()
  }

  /// A failure with a retry coming is no Problem: no alert, no badge, nothing for Eric to do.
  func retryIsComing(_ p: PlatformPost) throws -> Bool {
    guard p.state == .failed, p.resolution == nil else { return false }
    return try autoRetries(p).failedPostId == p.id
  }

  /// The clip goes back to Edit, which removes every live post of it: each automatic attempt becomes its failure's
  /// waiting retry again, so "Send to Queue" brings it back once. Nothing was sent, so the try stays unused.
  func takeBackAutoRetries(videoId: String) throws {
    for a in try posts(where: "video_id=? AND kind<>'regular'", [videoId]) where !a.state.isTerminal {
      var r = try autoRetries(a)
      guard r.lastPostId == a.id, try finalPostizJob(postId: a.id) == nil else { continue }
      let failures = try posts(where: "video_id=? AND platform=? AND version_no=? AND state='failed' AND resolution='retried' AND attempt_no<?",
                               [videoId, a.platform.rawValue, a.versionNo, a.attemptNo])
      guard var f = failures.max(by: { $0.attemptNo < $1.attemptNo }) else { continue }
      f.resolution = nil
      try save(f, note: "retry waits: sent back to Edit")
      r.failedPostId = f.id
      r.nextRetryAt = a.scheduledAt
      r.tryUnused = true
      try setKV(PostizService.autoRetryKey(a), r)
    }
  }
}

/// Failed posts retry by themselves (DECISIONS-R9.md): a Postiz ERROR retries unless something says a retry can't help,
/// so Eric never audits it. Every retryable failure gets a stored next-retry time from when it happened, and the new
/// attempt goes to Postiz ahead of that time, so it goes out with the Mac off. If the Mac slept through the time, the
/// publish step's past-slot rule sends it right away. Copyright, vetoed failures and used-up retries stay loud, and
/// nothing in here ever overrides copyright, a held clip, a pause or the never-double-post rules.
extension PostizService {
  public static let maxAutoRetries = 5
  /// Added to a failure's message (the inspector and the alert show `errorMessage`).
  public static let retryingNote = "retrying automatically"
  public static let retriesUsedUpNote = "automatic retries used up, mark Fixed when it's ready"
  public static let noRetryNote = "no automatic retry for this one, mark Fixed when it's ready"
  /// Any YouTube error but the upload quota may come after the video exists, and a retry would double-post.
  public static let youTubeStaysNote = "no automatic retry: YouTube may already have the video, so check the channel, then mark Fixed"

  /// Words that mean more than "not now": a policy or rights problem, an account problem or a paid limit.
  static let notTemporary = #"\b(violat\w*|infring\w*|intellectual property|dmca|content[- ]?id|copy[- ]right|trademark\w*|"#
    + #"(un)?licen[sc]\w*|songs?|sounds?|soundtracks?|tracks?|lyrics|strikes?|takedowns?|taken? down|third[- ]party|polic(y|ies)|"#
    + #"guidelines?|community|terms|not allowed|\w+n't allowed|spam\w*|flagged|reject\w*|remov\w*|revok\w*|bans?|banned|suspen\w*|restrict\w*|"#
    + #"block\w*|locked|disabled|deactivat\w*|terminated|denied|forbidden|unauthori[sz]ed|upgrade\w*|plans?|subscri\w*|storage)\b"#
  /// Failures the same post would hit again: too long, too large, its format, its fields, the channel's sign-in, or a
  /// platform that says it already has the post.
  static let cantBeFixedByARetry = #"\b(too (long|short|large|big|small)|(longer|shorter|larger|bigger|smaller) than|size|duration|length|"#
    + #"format\w*|codecs?|aspect ratio|resolution|frame rate|bitrate|unsupported|not supported|hashtags?|"#
    + #"validat\w*|invalid\w*|not a valid|malformed|bad (request|body)|missing|required|must (be|have|not|contain)|"#
    + #"duplicate\w*|already (posted|published|uploaded|exists?)|"#
    + #"auth\w*|oauth\w*|tokens?|expired|credentials?|permissions?|scopes?|log ?in|sign ?in|re-?connect\w*|re-?link\w*|disconnected|not connected|sessions?)\b"#

  /// Copyright, or a veto word anywhere in the message. Platforms write codes too ("duration_check_failed").
  static func isVetoed(_ message: String) -> Bool {
    let m = message.lowercased().replacingOccurrences(of: "_", with: " ")
    return isCopyright(message) || m.range(of: notTemporary, options: .regularExpression) != nil
      || m.range(of: cantBeFixedByARetry, options: .regularExpression) != nil
  }

  /// This failure may retry by itself on `platform`: anything not vetoed, an unknown or empty error too. On YouTube only
  /// the upload quota, where no video was created: any other error may come after the video exists (a rate limit on the
  /// thumbnail step), and a retry would double-post.
  public static func retriesByItself(_ message: String, on platform: Platform) -> Bool {
    guard !isVetoed(message) else { return false }
    guard platform == .youtube else { return true }
    let m = message.lowercased()
    guard !m.contains("thumbnail"), !m.contains("uploaded") else { return false }  // the video may exist
    return m.contains("daily upload quota") || m.contains("defaultvideoinsertperdayperproject")
  }

  static let autoRetryPrefix = "postiz.autoRetry."

  /// The version is in the key, so a repost counts apart from the clip's regular post.
  static func autoRetryKey(_ p: PlatformPost) -> String {
    "\(autoRetryPrefix)\(p.videoId)#\(p.platform.rawValue)#v\(p.versionNo)"
  }

  func autoRetries(_ p: PlatformPost) throws -> PostizAutoRetries { try store.autoRetries(p) }

  /// Tries used up. `tryUnused`: the last attempt went back with its clip, so that one can still go.
  static func usedUp(_ r: PostizAutoRetries) -> Bool { r.count >= maxAutoRetries && r.tryUnused != true }

  /// The failure's retry can come: not vetoed, tries left, nothing permanent rules it out. Reasons to wait keep it.
  func retryPromised(_ message: String, _ p: PlatformPost) throws -> Bool {
    guard Self.retriesByItself(message, on: p.platform) else { return false }
    return try !Self.usedUp(autoRetries(p)) && !retryRuledOut(p)
  }

  /// The sentence a Postiz ERROR adds to the post's message.
  func retryNote(_ message: String, _ p: PlatformPost) throws -> String {
    guard Self.retriesByItself(message, on: p.platform) else {
      return p.platform == .youtube && !Self.isVetoed(message) ? " — \(Self.youTubeStaysNote)" : ""
    }
    if try Self.usedUp(autoRetries(p)) { return " — \(Self.retriesUsedUpNote)" }
    return " — " + (try retryRuledOut(p) ? Self.noRetryNote : Self.retryingNote)
  }

  /// Stores the next-retry time, from when the failure happened.
  func recordFailure(_ p: PlatformPost, at failedAt: Date) throws {
    var r = try autoRetries(p)
    r.failedPostId = p.id
    r.failedAt = failedAt
    r.tryUnused = nil
    r.nextRetryAt = PostizRetrySchedule.next(after: failedAt, retry: r.count + 1, platform: p.platform, settings: try store.settings())
    try store.setKV(Self.autoRetryKey(p), r)
  }

  /// This attempt came from a test-run job, so it must not go public.
  func mustStayTestRun(_ p: PlatformPost) throws -> Bool {
    guard p.kind != .regular else { return false }
    return try autoRetries(p).testRunPosts.contains(p.id)
  }

  /// `p` is an automatic retry still on its way to Postiz or waiting there: it never goes overdue and never lands on
  /// Today by itself. A 400 on create, or a copy deleted in Postiz, hands it to Today as usual.
  public func isRetryAttempt(_ p: PlatformPost) throws -> Bool {
    guard p.kind != .regular, !p.state.isTerminal, try autoRetries(p).lastPostId == p.id else { return false }
    return try store.finalPostizJob(postId: p.id) == nil && !handedToToday(p)
  }

  /// The attempt can't go to Postiz now, so it isn't due for Eric either: it waits for the platform to come back.
  func retryAttemptWaits(_ p: PlatformPost, router: PostizRouter) throws -> Bool {
    guard try isRetryAttempt(p) else { return false }
    return !Self.settingsAllow(p.platform, router.settings) || !router.route(p.platform).isPostiz
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

  /// What `p`'s retry waits for, in words, and whether that's a setting rather than a pause. nil: nothing does.
  func retryWaitReason(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> (text: String, offPostiz: Bool)? {
    let name = p.platform.displayName
    if settings.paused { return ("when posting resumes", false) }
    if settings.pausedPlatforms.contains(p.platform) { return ("when \(name) resumes", false) }
    if try store.video(id: p.videoId)?.heldInEdit == true { return ("when it's back in the Queue", false) }
    if !settings.enabledPlatforms.contains(p.platform) { return ("when \(name) is back on", true) }
    if settings.publishing.publisher(for: p.platform) != .postiz { return ("when \(name) is back on Postiz", true) }
    return router.route(p.platform).isPostiz ? nil : ("when Postiz can take \(name) again", true)
  }

  enum RetryDecision: Equatable {
    /// Not an automatic retry's business.
    case nothing
    /// It waits; the next tick looks again.
    case wait
    case go
    /// A retry was promised and now can't come: the post goes back to Eric with this note.
    case giveUp(String)
  }

  /// Read-only, every tick. Reasons to wait (paused, platform off Postiz, clip held, another job open) are re-read each
  /// time, so a retry runs once when they clear.
  func retryDecision(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> RetryDecision {
    guard p.state == .failed, p.resolution == nil, p.errorType == .uploadFailed,
          let job = try store.finalPostizJob(postId: p.id), job.closeReason == .error,
          Self.retriesByItself(job.lastError ?? "", on: p.platform) else { return .nothing }
    let promised = try store.retryIsComing(p)
    if try Self.usedUp(autoRetries(p)) { return promised ? .giveUp(Self.retriesUsedUpNote) : .nothing }
    if try retryRuledOut(p) { return promised ? .giveUp(Self.noRetryNote) : .nothing }
    if try retryWaitReason(p, settings: settings, router: router) != nil || retryMustWait(p) { return .wait }
    return .go
  }

  static let failedFromPostiz = "state='failed' AND resolution IS NULL AND error_type=? AND raw_response LIKE 'postiz:%'"

  /// The soonest a create can use: now + the lead time, on a whole minute (`remoteDate`).
  var soonestRetry: Date {
    Date(timeIntervalSince1970: (now.addingTimeInterval(Self.leadTime).timeIntervalSince1970 / 60).rounded(.up) * 60)
  }

  /// When a retry due at `due` goes out: not in the past, and never within the stagger gap of another post on the
  /// platform. A YouTube quota retry moves earlier rather than later, down to the reset, because the day's quota goes.
  func retryTime(due: Date, failedAt: Date?, _ p: PlatformPost, settings: Settings) throws -> Date {
    let soonest = soonestRetry
    guard due > soonest else {
      return try Sched.retrySlot(store: store, platform: p.platform, target: soonest, settings: settings, excluding: [p.id])
    }
    let reset = p.platform == .youtube ? failedAt.map { PostizRetrySchedule.youTubeQuota(after: $0).reset } : nil
    return try Sched.retrySlot(store: store, platform: p.platform, target: due, earliest: reset.map { max($0, soonest) },
                               settings: settings, excluding: [p.id])
  }

  /// One failure, inside its own transaction: the note, the stored time, the new attempt. Returns true when it made one.
  func retryOne(_ id: String, settings: Settings, router: PostizRouter) throws -> Bool {
    guard var p = try store.post(id: id) else { return false }
    let decision = try retryDecision(p, settings: settings, router: router)
    if case .giveUp(let note) = decision {
      var r = try autoRetries(p)
      r.failedPostId = nil
      try store.setKV(Self.autoRetryKey(p), r)
      if let job = try store.finalPostizJob(postId: p.id) {
        p.errorMessage = (job.lastError ?? p.errorMessage ?? "") + " — \(note)"
        try store.save(p, note: "no automatic retry after all: \(note)")
      }
      return false
    }
    guard decision == .go || decision == .wait, let job = try store.finalPostizJob(postId: p.id) else { return false }
    if try !store.retryIsComing(p) {  // failed before this build, or under an older one
      try recordFailure(p, at: min(job.remoteDate, job.closedAt ?? now))
    }
    guard decision == .go else { return false }
    var r = try autoRetries(p)
    let at = try retryTime(due: r.nextRetryAt ?? now, failedAt: r.failedAt, p, settings: settings)
    let n = try PostActions(store: store).fixed(postId: p.id, by: "auto-retry", at: at)
    if r.tryUnused != true { r.count += 1 }
    r.tryUnused = nil
    r.failedPostId = nil
    r.lastPostId = n.id
    if job.testMode { r.testRunPosts.append(n.id) }
    try store.setKV(Self.autoRetryKey(p), r)
    try store.logEvent("postiz", "\(p.platform.displayName): failed, automatic retry \(r.count) of \(Self.maxAutoRetries) on \(Sched.shortTime(n.scheduledAt, settings))\(job.testMode ? " (stays a test run)" : "")",
                       videoId: p.videoId, postId: n.id)
    return true
  }

  /// The engine's `retry` step: a failure that waited, or one an older build left. A failure the sync step just read has
  /// its attempt already. Each post is re-read inside its own `BEGIN IMMEDIATE`, so two processes ticking retry once. No
  /// read of the settings or Keychain with nothing to do, and no write lock for a post that only waits.
  public func retryFailures() throws -> String {
    let failed = try store.posts(where: Self.failedFromPostiz, [ErrorType.uploadFailed.rawValue])
    guard !failed.isEmpty else { return "none" }
    let settings = try store.settings()
    let router = try router(settings)
    var queued = 0
    for c in failed {
      let d = try retryDecision(c, settings: settings, router: router)
      if try d == .nothing || (d == .wait && store.retryIsComing(c)) { continue }
      if try store.db.transaction({ try retryOne(c.id, settings: settings, router: router) }) { queued += 1 }
    }
    return queued == 0 ? "none" : "scheduled \(queued)"
  }

  /// A retry attempt whose time passed while it couldn't be sent (the Mac slept, posting was paused): it goes out now,
  /// past the gap from the platform's other posts.
  func retimeRetry(_ p: PlatformPost, settings: Settings) throws -> PlatformPost {
    guard p.scheduledAt < now.addingTimeInterval(Self.leadTime), try isRetryAttempt(p) else { return p }
    var q = p
    q.scheduledAt = try Sched.retrySlot(store: store, platform: p.platform, target: soonestRetry, settings: settings, excluding: [p.id])
    if q.state == .due { q.state = q.renderId == nil ? .planned : .rendered }
    try store.save(q, note: "retry time passed → \(Sched.shortTime(q.scheduledAt, settings))")
    return q
  }

  /// The retry behind `p`, for every screen: an attempt on its way, a failure whose attempt is still to come. nil for
  /// anything else, and for a failure whose attempt exists (`retryDisplay` shows that attempt's line on it).
  func pendingRetry(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> PostizPendingRetry? {
    let r = try autoRetries(p)
    if try isRetryAttempt(p) {
      let job = try store.livePostizJob(postId: p.id)
      let wait = job == nil ? try retryWaitReason(p, settings: settings, router: router) : nil
      return Self.pending(p, number: max(1, r.count), queued: true, at: job?.remoteDate ?? p.scheduledAt, wait: wait, settings: settings, now: now)
    }
    guard try store.retryIsComing(p) else { return nil }
    return Self.pending(p, number: r.count + (r.tryUnused == true ? 0 : 1), queued: false, at: r.nextRetryAt,
                        wait: try retryWaitReason(p, settings: settings, router: router), settings: settings, now: now)
  }

  static func pending(_ p: PlatformPost, number: Int, queued: Bool, at: Date?, wait: (text: String, offPostiz: Bool)?,
                      settings: Settings, now: Date) -> PostizPendingRetry {
    let tries = "(try \(number) of \(maxAutoRetries))"
    let text: String
    if let wait { text = "Retrying \(wait.text) \(tries)" }
    else if let at, at > now { text = "Retrying \(Sched.retryDay(at, settings)) \(tries)" }
    else { text = "Retrying now \(tries)" }
    return PostizPendingRetry(post: p, number: number, queued: queued, at: wait == nil ? at : nil, waiting: wait?.text,
                              offPostiz: wait?.offPostiz ?? false, text: text)
  }

  /// `.retrying` when a retry is coming for `p`. `base` is what Postiz is doing with it otherwise: a retry Postiz is
  /// sending, posted or holds as a draft says so itself.
  func retryDisplay(_ p: PlatformPost, base: PostizDisplayState?, router: PostizRouter) throws -> PostizDisplayState? {
    guard p.kind != .regular || p.state == .failed else { return nil }
    switch base {
    case nil, .queued?, .sending?, .scheduled?, .failed?, .fellBack?: break
    default: return nil
    }
    if let r = try pendingRetry(p, settings: router.settings, router: router) { return .retrying(r.text) }
    // A failure whose attempt is out: it says what the attempt says, or Today would still read Failed.
    guard p.state == .failed, p.resolution == "retried", let id = try autoRetries(p).lastPostId, id != p.id,
          let a = try store.post(id: id), a.attemptNo > p.attemptNo,
          let r = try pendingRetry(a, settings: router.settings, router: router) else { return nil }
    return .retrying(r.text)
  }

  /// Retries still to come, soonest first, for Doctor and `djq postiz status`.
  public func pendingAutoRetries() throws -> [PostizPendingRetry] {
    let rows = try store.db.query("SELECT json FROM kv WHERE substr(key, 1, ?) = ?", [Self.autoRetryPrefix.count, Self.autoRetryPrefix])
    guard !rows.isEmpty else { return [] }
    let settings = try store.settings()
    let router = try router(settings)
    var out: [PostizPendingRetry] = []
    for row in rows {
      guard let r: PostizAutoRetries = row.json("json") else { continue }
      for id in [r.lastPostId, r.failedPostId].compactMap({ $0 }) {
        if let p = try store.post(id: id), let pending = try pendingRetry(p, settings: settings, router: router) { out.append(pending) }
      }
    }
    return out.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
  }
}
