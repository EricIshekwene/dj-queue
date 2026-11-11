import Foundation

/// What the automatic retries did so far for one clip + platform + version (kv `postiz.autoRetry.<clip>#<platform>#v<N>`;
/// no schema change). It outlives the posts, so the count and the backoff carry across attempts. There is no cap any
/// more (round 22): a retryable failure re-queues until the post goes out. Fields added after v0.8 are optional, so a
/// row written by an older build still decodes.
public struct PostizAutoRetries: Codable, Sendable, Hashable {
  /// Automatic attempts made so far (it picks the backoff step; nothing stops at any number).
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
  /// Ticks the attempt has spent a day late with nothing stopping it, and still unsent (`maxUnsentTicks`).
  public var unsentTicks: Int?
  /// Round 22: the error the retries keep failing with, and since when it has been that same error (`keepsFailing`).
  public var failingWith: String?
  public var failingSince: Date?
  public init() {}
}

/// Round 22: a retry that has failed with the same error for a week. It keeps retrying; Eric sees one calm item.
public struct PostizKeepsFailing: Sendable, Hashable, Identifiable {
  public var platform: Platform
  /// The attempt or failure that carries the retry now.
  public var postId: String
  public var videoId: String
  public var since: Date
  public var reason: String
  public var id: String { "\(videoId)#\(platform.rawValue)" }
  /// "Keeps failing on TikTok".
  public var title: String { "Keeps failing on \(platform.displayName)" }
  /// "Keeps failing on TikTok: <reason>".
  public var summary: String { "\(title): \(reason)" }
}

/// An automatic retry still to come, for every screen, Doctor and `djq postiz status`.
public struct PostizPendingRetry: Sendable, Hashable {
  public var post: PlatformPost
  /// Which automatic retry this is (1 is the first after the failure). Status and Doctor only: the screens never show it.
  public var number: Int
  /// False: `post` is the failure itself, its attempt still to be made.
  public var queued: Bool
  /// nil: it waits for `waiting`, or goes out as soon as nothing is in its way.
  public var at: Date?
  /// "when posting resumes": what it waits for. Resuming is all it takes.
  public var waiting: String?
  /// It waits for a setting Eric may not change back soon (the platform is on Manual or off, no usable channel or key).
  public var offPostiz = false
  /// It waits for its channel to be signed in again in Postiz (one item per platform says so, not this post).
  public var signIn = false
  /// "Retrying Thu 8:00 am", or "Retrying when posting resumes".
  public var text: String
  /// What the chip says: the same with a time, "Retry waits" or "Waits for sign-in" when it waits (`text` is then the
  /// line under it). Never a try count or the error: the chip is a calm status, the error is behind Details.
  public var badge: String
}

extension PostizPendingRetry {
  var display: PostizDisplayState { .retrying(badge, line: waiting == nil ? nil : text) }
}

/// When a failed post goes out again (DECISIONS-R9.md, DECISIONS-R22.md). Pure, so every time can be tested with a clock.
public enum PostizRetrySchedule {
  /// A retry on a slot is never sooner than this after the failure.
  public static let slotGap: TimeInterval = 3600
  /// A YouTube quota retry is never sooner than this after the quota's reset (the quiet window's moved time).
  public static let resetGap: TimeInterval = 30 * 60

  /// Retry `number` (1, 2, 3, … with no end) of a failure at `failedAt`: +1 h, +6 h, then the platform's next Settings slot
  /// time at least an hour after the failure, every day until it goes. A YouTube upload-quota failure always waits for
  /// the quota (`youTubeQuota`); a YouTube failure that retries for another reason (its media) backs off like the rest.
  public static func next(after failedAt: Date, retry number: Int, platform: Platform, settings: Settings,
                          quota: Bool = true) -> Date {
    if platform == .youtube && quota { return youTubeQuota(after: failedAt, settings: settings).retry }
    switch number {
    case 1: return failedAt.addingTimeInterval(3600)
    case 2: return failedAt.addingTimeInterval(6 * 3600)
    default: return slot(platform, notBefore: failedAt.addingTimeInterval(slotGap), settings: settings)
    }
  }

  /// The platform's first regular slot time (position 0, out of YouTube's quiet window) at or after `t`. The day before
  /// counts too: a late slot with an offset can land after midnight.
  public static func slot(_ p: Platform, notBefore t: Date, settings: Settings) -> Date {
    let dm = DayMath(settings: settings)
    var day = dm.addDays(dm.key(t), -1)
    for _ in 0..<5 {
      let at = settings.slotTime(p, date: day, position: 0, dm)
      if at >= t { return at }
      day = dm.addDays(day, 1)
    }
    return t
  }

  /// Postiz's YouTube quota resets at midnight Pacific (`YouTubeWindow`). The retry goes at the next YouTube slot time
  /// from Settings that is at least 30 minutes after the first reset following the failure and an hour after the
  /// failure. `reset` is that Pacific midnight.
  public static func youTubeQuota(after failedAt: Date, settings: Settings) -> (reset: Date, retry: Date) {
    let reset = YouTubeWindow.nextReset(after: failedAt)
    let soonest = max(reset.addingTimeInterval(resetGap), failedAt.addingTimeInterval(slotGap))
    return (reset, slot(.youtube, notBefore: soonest, settings: settings))
  }
}

extension Store {
  func autoRetries(_ p: PlatformPost) throws -> PostizAutoRetries {
    try kv(PostizService.autoRetryKey(p)) ?? PostizAutoRetries()
  }

  /// A failure with a retry coming is no Problem: no alert, no badge, nothing for Eric to do. The kv row alone isn't
  /// enough: after a reset the same post can fail for another reason, and that one must be loud. So the failure itself
  /// has to be the kind that retries. A failure an older build gave up on after five tries (its message ends in that
  /// build's "used up" note) has a retry coming too: there is no cap any more, so the retry step picks it up.
  func retryIsComing(_ p: PlatformPost) throws -> Bool {
    guard p.state == .failed, p.resolution == nil, p.errorType == .uploadFailed,
          let job = try finalPostizJob(postId: p.id), job.closeReason == .error else { return false }
    let r = try autoRetries(p)
    guard r.failedPostId == p.id || (r.failedPostId == nil && PostizService.endsInLegacyCapNote(p.errorMessage)) else { return false }
    return PostizService.retriesByItself(job.lastError ?? "", on: p.platform)
  }

  /// `p`'s failure no longer has a retry coming.
  func clearRetryPromise(_ p: PlatformPost) throws {
    var r = try autoRetries(p)
    guard r.failedPostId == p.id else { return }
    r.failedPostId = nil
    try setKV(PostizService.autoRetryKey(p), r)
  }

  /// Eric removed the day: its automatic attempts go with it, as a regular post of that day does. The publish step
  /// deletes them from Postiz.
  func dropAutoRetries(slot s: PlanSlot) throws {
    for a in try slotPosts(s.id) where a.kind != .regular && !a.state.isTerminal {
      if try autoRetries(a).lastPostId == a.id { try deletePost(a.id) }
    }
    try dropWaitingRetries(videoId: s.videoId)
  }

  /// Eric took the clip out of the plan: a failure of it that still waits for its retry stops waiting.
  func dropWaitingRetries(videoId: String) throws {
    for var f in try posts(where: "video_id=? AND state='failed' AND resolution IS NULL", [videoId]) where try retryIsComing(f) {
      try clearRetryPromise(f)
      f.resolution = "unscheduled"
      try save(f, note: "no automatic retry: taken out of the plan")
    }
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

/// What a Postiz ERROR means for the post (round 22). One reading for the engine, every screen, Doctor and `djq`.
public enum PostizFailureKind: String, Sendable, Hashable {
  /// Temporary: it retries by itself on the backoff.
  case retries
  /// Postiz couldn't fetch the post's media (expired, not found): it retries with the media uploaded again.
  case media
  /// The channel's sign-in (token, session, reconnect): its posts wait for the channel and go out once it works.
  case signIn
  /// Loud, never retried by itself.
  case copyright
  /// A retry can't help (policy, size, format, too long), or YouTube may already have the video: it's Eric's.
  case stays
}

/// Failed posts retry by themselves (DECISIONS-R9.md, DECISIONS-R22.md): a Postiz ERROR retries unless something says a
/// retry can't help, so Eric never audits it, and there is no cap: it re-queues until it goes out. Every retryable failure
/// gets a stored next-retry time from when it happened, and the new attempt goes to Postiz ahead of that time, so it goes
/// out with the Mac off. If the Mac slept through the time, the publish step's past-slot rule sends it right away.
/// Copyright and vetoed failures stay loud; a channel whose sign-in broke is one item per platform, and its posts wait.
/// Nothing in here ever overrides copyright, a held clip, a pause or the never-double-post rules.
extension PostizService {
  /// Added to a failure's message (the inspector shows `errorMessage` behind Details).
  public static let retryingNote = "retrying automatically"
  public static let signInNote = "waits for the channel to be reconnected in Postiz"
  public static let noRetryNote = "no automatic retry for this one, mark Fixed when it's ready"
  /// Any YouTube error but the upload quota (or its media) may come after the video exists, and a retry would double-post.
  public static let youTubeStaysNote = "no automatic retry: YouTube may already have the video, so check the channel, then mark Fixed"
  /// What builds before round 22 added when five tries were used up. Only read: such a failure re-queues by itself now.
  static let legacyCapNote = " — automatic retries used up, mark Fixed when it's ready"

  static func endsInLegacyCapNote(_ message: String?) -> Bool { message?.hasSuffix(legacyCapNote) == true }

  /// Words that mean more than "not now": a policy or rights problem, an account problem or a paid limit.
  static let notTemporary = #"\b(violat\w*|infring\w*|intellectual property|dmca|content[- ]?id|copy[- ]right|trademark\w*|"#
    + #"abus\w*|disallow\w*|prohibit\w*|not permitted|nud\w*|sexual\w*|adult|hate|harass\w*|violen\w*|sensitive|inappropriate|harmful|unsafe|"#
    + #"private|privacy|unaudited|(un)?verif\w*|ownership|active user|(in)?eligible|insufficient|credits?|in your (country|region)|"#
    + #"(un)?licen[sc]\w*|songs?|sounds?|soundtracks?|tracks?|lyrics|strikes?|takedowns?|taken? down|third[- ]party|polic(y|ies)|"#
    + #"guidelines?|community|terms|not allowed|\w+n't allowed|spam\w*|flagged|reject\w*|remov\w*|revok\w*|bans?|banned|suspen\w*|restrict\w*|"#
    + #"block\w*|locked|disabled|deactivat\w*|terminated|denied|forbidden|unauthori[sz]ed|upgrade\w*|plans?|subscri\w*|storage)\b"#
  /// Failures the same post would hit again: too long, too large, its format, its fields or the channel's sign-in.
  /// "Exceeds" counts for a size, never for "rate limit exceeded" or "exceeds the quota".
  static let cantBeFixedByARetry = #"\b(too (long|short|large|big|small)|longer|shorter|larger|bigger|smaller|sizes?|duration|length|"#
    + #"maximum|minimum|max|over the limit|\d+ ?(kb|mb|gb)|400|401|403|413|415|422|"#
    + #"format\w*|codecs?|aspect ratio|resolution|frame rate|bitrate|unsupported|not supported|hashtags?|mismatch|"#
    + #"validat\w*|invalid\w*|not a valid|malformed|bad (request|body)|missing|required|must (be|have|not|contain)|"#
    + #"(re|un)?-?auth\w*|oauth\w*|tokens?|expired|credentials?|permissions?|scopes?|log[- ]?in|sign[- ]?in|refresh\w*|"#
    + #"re ?connect\w*|re ?link\w*|disconnected|not connected|sessions?)\b|\bexceeds\b(?!\s+(the |your )?(rate|quota|daily|request|api))|"#
    + #"\b(file|video|media|image|post|caption|text|title|upload)s? exceeded\b"#
  /// The platform says it has the post, or may. A retry here is a double post, so this one is broad on purpose: any
  /// "already", and any "published", "posted" or "live", even in "couldn't be posted". A false veto costs one Fixed.
  static let alreadyThere = #"\b(already|duplicate\w*|identical|repeat\w*|published|posted|live|permalink\w*|"#
    + #"(been|was|were) (uploaded|shared)|(uploaded|shared) (before|earlier|previously)|(created|uploaded),? but|"#
    + #"same (post|content|video|media|status|tweet))\b"#
  /// A policy, rights or paid-plan word: then neither a media nor a sign-in reading may turn the failure into a wait.
  static let policyWords = #"\b(violat\w*|infring\w*|intellectual property|dmca|content[- ]?id|trademark\w*|abus\w*|disallow\w*|"#
    + #"prohibit\w*|not permitted|nud\w*|sexual\w*|adult|hate|harass\w*|violen\w*|sensitive|inappropriate|harmful|unsafe|"#
    + #"(un)?licen[sc]\w*|songs?|sounds?|soundtracks?|lyrics|strikes?|takedowns?|taken? down|third[- ]party|polic(y|ies)|"#
    + #"guidelines?|community|terms|spam\w*|flagged|bans?|banned|suspen\w*|restrict\w*|locked|deactivat\w*|terminated|"#
    + #"insufficient|credits?|upgrade\w*|subscri\w*|in your (country|region))\b"#
  /// Round 22: Postiz couldn't get the media (its link expired, the file is gone). Both a media word and a "gone" word.
  /// "Invalid" or "unavailable" alone is no "gone" word (an invalid file is a format problem): only an invalid url or link.
  static let mediaWords = #"\b(media|file|files|url|urls|uploads?|uploaded|uploading|downloads?|downloaded|downloading|fetch\w*|attachments?)\b"#
  static let mediaGone = #"\b(expired|not found|404|no longer (exists|available)|invalid (media |file |upload )?(url|link)|(url|link) (is )?invalid|"#
    + #"could ?n[o']?t be (retrieved|fetched|found|downloaded|accessed)|"#
    + #"(could ?n[o']?t|can ?n[o']?t|unable to|failed to) (retrieve|fetch|download|access|pull|get))\b"#
  /// On YouTube only Postiz failing to fetch the source media counts, never a step that may come after the upload.
  static let youTubeMediaWords = #"\b(media|file|files|url|urls)\b"#
  static let youTubeAfterUpload = #"\b((upload|processing|video|its) status|status of the (video|upload)|(get|check|poll\w*|read) (the )?status|"#
    + #"processing|response|video ?id|after (the )?upload|uploaded|insert\w*|publish\w*|thumbnails?|playlist\w*)\b"#
  /// Round 22: what the same post would hit again whatever its media: size, length, format, type. Read before the media
  /// and sign-in readings, so "invalid file format" or "file exceeds 4GB" never retries.
  static let sizeOrFormat = #"\b(too (long|short|large|big|small)|longer|shorter|larger|bigger|smaller|sizes?|duration|length|"#
    + #"maximum|minimum|max|over the limit|\d+ ?(kb|mb|gb|tb)|413|415|422|format\w*|codecs?|aspect ratio|resolution|"#
    + #"frame rate|bitrate|unsupported|not supported|hashtags?|mismatch|(file|media|mime|content|video|image) ?types?)\b|"#
    + #"\bexceeds\b(?!\s+(the |your )?(rate|quota|daily|request|api))|\b(file|video|media|image|post|caption|text|title|upload)s? exceeded\b"#
  /// Round 22: the channel's sign-in, read narrowly: a token, OAuth, re-authorizing, reconnecting, an expired login, a
  /// channel Postiz disabled. Never a bare "permission", "refresh", "session" or "disabled" ("comments are disabled").
  static let signInWords = #"\b((access|refresh|auth|bearer|oauth) ?tokens?|tokens? (has |is |was )?(expired|invalid|revoked|missing)|"#
    + #"invalid (grant|token)|oauth\w*|re ?auth(enticat|oriz|oris)\w*|unauthenticated|not authenticated|unauthori[sz]ed|401|"#
    + #"re ?connect\w*|re ?link\w*|disconnected|not connected|logged out|signed out|"#
    + #"(log ?in|sign ?in|session|credentials?) (has |is )?(expired|required|invalid|revoked)|(log|sign) ?in again|"#
    + #"(need|needs|have|has) to (log|sign) ?in|scopes? not authori[sz]ed|refresh ?needed|channel (is |was )?disabled)\b"#
  /// On YouTube these may come after the video exists (the thumbnail step, "we uploaded your video but …").
  static let youTubeMayExist = #"\b(thumbnails?|uploaded (your |the )?video|video (was |has been )?uploaded)\b"#

  /// Platforms write codes too ("duration_check_failed", "file-too-large", "FileSizeExceeded"), so those read as words.
  static func normalized(_ message: String) -> String {
    message.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
      .lowercased().replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression)
  }

  /// Copyright, or a veto word anywhere in the message.
  static func isVetoed(_ message: String) -> Bool {
    let m = normalized(message)
    return isCopyright(message) || [notTemporary, cantBeFixedByARetry, alreadyThere].contains {
      m.range(of: $0, options: .regularExpression) != nil
    }
  }

  /// Postiz couldn't fetch the post's media: expired, not found, a 404. A sign-in word ("token expired") or a size or
  /// format word rules it out.
  public static func isMediaProblem(_ message: String) -> Bool {
    let m = normalized(message)
    func has(_ re: String) -> Bool { m.range(of: re, options: .regularExpression) != nil }
    return has(mediaWords) && has(mediaGone) && !has(signInWords) && !has(sizeOrFormat)
  }

  /// On YouTube: only Postiz failing to fetch the source media (no video was made), never a status, processing or
  /// response step that may come after the upload.
  static func isYouTubeSourceMediaProblem(_ message: String) -> Bool {
    let m = normalized(message)
    func has(_ re: String) -> Bool { m.range(of: re, options: .regularExpression) != nil }
    return isMediaProblem(message) && has(youTubeMediaWords) && !has(youTubeAfterUpload) && !has(youTubeMayExist)
  }

  /// The channel's sign-in broke: auth, a token, a session, reconnect, an expired login.
  public static func isSignInProblem(_ message: String) -> Bool {
    let m = normalized(message)
    return m.range(of: signInWords, options: .regularExpression) != nil && !isMediaProblem(message)
  }

  /// YouTube's daily upload quota, where no video was created.
  static func isYouTubeQuota(_ message: String) -> Bool {
    let m = message.lowercased()
    return m.contains("daily upload quota") || m.contains("defaultvideoinsertperdayperproject")
  }

  /// The one reading of a Postiz ERROR (round 22). The order matters: copyright first, then anything that says the
  /// platform may have it, then media and sign-in (unless a policy word is there too), then the old veto, then YouTube's
  /// rule (only the upload quota retries; any other error may come after the video exists).
  public static func classify(_ message: String, on platform: Platform) -> PostizFailureKind {
    if isCopyright(message) { return .copyright }
    let m = normalized(message)
    func has(_ re: String) -> Bool { m.range(of: re, options: .regularExpression) != nil }
    if has(alreadyThere) || has(sizeOrFormat) { return .stays }
    let policy = has(policyWords)
    let mayExist = platform == .youtube && (has(youTubeMayExist) || has(youTubeAfterUpload))
    if !policy, platform == .youtube ? isYouTubeSourceMediaProblem(message) : isMediaProblem(message) { return .media }
    if !policy, !mayExist, isSignInProblem(message) { return .signIn }
    if isVetoed(message) { return .stays }
    guard platform == .youtube else { return .retries }
    let low = message.lowercased()
    guard !low.contains("thumbnail"), !low.contains("uploaded") else { return .stays }  // the video may exist
    return isYouTubeQuota(message) ? .retries : .stays
  }

  /// This failure may retry by itself on `platform`: anything not vetoed, an unknown or empty error too, a media
  /// problem anywhere, and a sign-in problem once the channel works again. On YouTube otherwise only the upload quota.
  public static func retriesByItself(_ message: String, on platform: Platform) -> Bool {
    [.retries, .media, .signIn].contains(classify(message, on: platform))
  }

  static let autoRetryPrefix = "postiz.autoRetry."

  /// The version is in the key, so a repost counts apart from the clip's regular post.
  static func autoRetryKey(_ p: PlatformPost) -> String {
    "\(autoRetryPrefix)\(p.videoId)#\(p.platform.rawValue)#v\(p.versionNo)"
  }

  func autoRetries(_ p: PlatformPost) throws -> PostizAutoRetries { try store.autoRetries(p) }

  /// The failure's retry can come: it retries by itself and nothing permanent rules it out. Reasons to wait keep it.
  func retryPromised(_ message: String, _ p: PlatformPost) throws -> Bool {
    guard Self.retriesByItself(message, on: p.platform) else { return false }
    return try !retryRuledOut(p)
  }

  /// The sentence a Postiz ERROR adds to the post's message.
  func retryNote(_ message: String, _ p: PlatformPost) throws -> String {
    switch Self.classify(message, on: p.platform) {
    case .copyright: return ""
    case .stays: return p.platform == .youtube && !Self.isVetoed(message) ? " — \(Self.youTubeStaysNote)" : ""
    case .signIn: return " — " + (try retryRuledOut(p) ? Self.noRetryNote : Self.signInNote)
    case .retries, .media: return " — " + (try retryRuledOut(p) ? Self.noRetryNote : Self.retryingNote)
    }
  }

  /// Stores the next-retry time, from when the failure happened.
  func recordFailure(_ p: PlatformPost, at failedAt: Date, message: String) throws {
    var r = try autoRetries(p)
    r.failedPostId = p.id
    r.failedAt = failedAt
    r.tryUnused = nil
    r.unsentTicks = nil
    r.nextRetryAt = PostizRetrySchedule.next(after: failedAt, retry: r.count + 1, platform: p.platform, settings: try store.settings(),
                                             quota: Self.isYouTubeQuota(message))
    if r.failingWith.map(Self.normalized) != Self.normalized(message) || r.failingSince == nil {
      r.failingWith = message
      r.failingSince = failedAt
    }
    try store.setKV(Self.autoRetryKey(p), r)
  }

  /// This attempt came from a test-run job, so it must not go public.
  func mustStayTestRun(_ p: PlatformPost) throws -> Bool {
    guard p.kind != .regular else { return false }
    return try autoRetries(p).testRunPosts.contains(p.id)
  }

  /// `p` is the newest automatic attempt of its clip + platform + version (sent or not).
  func isAutoAttempt(_ p: PlatformPost) throws -> Bool {
    try p.kind != .regular && autoRetries(p).lastPostId == p.id
  }

  /// `p` is an automatic retry still on its way to Postiz or waiting there: it never goes overdue and never lands on
  /// Today by itself. A 400 on create, or a copy deleted in Postiz, hands it to Today as usual.
  public func isRetryAttempt(_ p: PlatformPost) throws -> Bool {
    guard !p.state.isTerminal, try isAutoAttempt(p) else { return false }
    return try store.finalPostizJob(postId: p.id) == nil && !handedToToday(p)
  }

  /// The attempt can't go to Postiz now, so it isn't due for Eric either: it waits for the platform to come back.
  func retryAttemptWaits(_ p: PlatformPost, router: PostizRouter) throws -> Bool {
    guard try isRetryAttempt(p) else { return false }
    return try !Self.settingsAllow(p.platform, router.settings) || !router.route(p.platform).isPostiz || signInDown(p.platform, router: router)
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

  /// What a retry waits for: a sentence ("when posting resumes"), whether it's a setting rather than a pause, and
  /// whether it's the channel's sign-in.
  struct RetryWait: Equatable {
    var text: String
    var offPostiz = false
    var signIn = false
  }

  /// What `p`'s retry waits for. nil: nothing does.
  func retryWaitReason(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> RetryWait? {
    let name = p.platform.displayName
    if settings.paused { return .init(text: "when posting resumes") }
    if settings.pausedPlatforms.contains(p.platform) { return .init(text: "when \(name) resumes") }
    if try store.video(id: p.videoId)?.heldInEdit == true { return .init(text: "when it's back in the Queue") }
    if !settings.enabledPlatforms.contains(p.platform) { return .init(text: "when \(name) is back on", offPostiz: true) }
    if settings.publishing.publisher(for: p.platform) != .postiz { return .init(text: "when \(name) is back on Postiz", offPostiz: true) }
    if !router.route(p.platform).isPostiz { return .init(text: "when \(name) is back on Postiz", offPostiz: true) }
    if try signInDown(p.platform, router: router) { return .init(text: "once \(name) is reconnected in Postiz", signIn: true) }
    return nil
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

  /// Read-only, every tick. Reasons to wait (paused, platform off Postiz, clip held, another job open, the channel's
  /// sign-in) are re-read each time, so a retry runs once when they clear. No number of tries ever stops it.
  func retryDecision(_ p: PlatformPost, settings: Settings, router: PostizRouter) throws -> RetryDecision {
    guard p.state == .failed, p.resolution == nil, p.errorType == .uploadFailed,
          let job = try store.finalPostizJob(postId: p.id), job.closeReason == .error,
          Self.retriesByItself(job.lastError ?? "", on: p.platform) else { return .nothing }
    let promised = try store.retryIsComing(p)
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
  /// platform. A YouTube quota retry moves earlier rather than later, down to 30 minutes after the reset, because the
  /// day's quota goes fast.
  func retryTime(due: Date, failedAt: Date?, _ p: PlatformPost, settings: Settings, quota: Bool) throws -> Date {
    let soonest = soonestRetry
    guard due > soonest else {
      return try Sched.retrySlot(store: store, platform: p.platform, target: soonest, settings: settings, excluding: [p.id])
    }
    let earliest: Date? = p.platform == .youtube && quota ? failedAt.map {
      max(PostizRetrySchedule.youTubeQuota(after: $0, settings: settings).reset.addingTimeInterval(PostizRetrySchedule.resetGap),
          $0.addingTimeInterval(PostizRetrySchedule.slotGap))
    } : nil
    return try Sched.retrySlot(store: store, platform: p.platform, target: due, earliest: earliest.map { max($0, soonest) },
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
      try store.refreshState(videoId: p.videoId)  // the clip counted this post as still going
      return false
    }
    guard decision == .go || decision == .wait, let job = try store.finalPostizJob(postId: p.id) else { return false }
    let message = job.lastError ?? ""
    if try autoRetries(p).failedPostId != p.id {  // failed before this build, under an older one, or one that gave up at five
      try recordFailure(p, at: min(job.remoteDate, job.closedAt ?? now), message: message)
      // Its time passed long ago: the platform's next slot (YouTube's after the next reset for the quota), staggered
      // below like any retry, so failures an older build left don't all go out at once.
      var r = try autoRetries(p)
      if let due = r.nextRetryAt, due < now {
        r.nextRetryAt = p.platform == .youtube && Self.isYouTubeQuota(message)
          ? PostizRetrySchedule.youTubeQuota(after: now, settings: settings).retry
          : PostizRetrySchedule.slot(p.platform, notBefore: now.addingTimeInterval(PostizRetrySchedule.slotGap), settings: settings)
        try store.setKV(Self.autoRetryKey(p), r)
      }
    }
    guard decision == .go else { return false }
    if Self.endsInLegacyCapNote(p.errorMessage), let m = p.errorMessage {
      p.errorMessage = String(m.dropLast(Self.legacyCapNote.count)) + " — \(Self.retryingNote)"
      try store.save(p, note: "retrying again: there is no limit on automatic retries any more")
    }
    var r = try autoRetries(p)
    let at = try retryTime(due: r.nextRetryAt ?? now, failedAt: r.failedAt, p, settings: settings, quota: Self.isYouTubeQuota(message))
    let n = try PostActions(store: store).fixed(postId: p.id, by: "auto-retry", at: at)
    if r.tryUnused != true { r.count += 1 }
    r.tryUnused = nil
    r.unsentTicks = nil
    r.failedPostId = nil
    r.lastPostId = n.id
    if job.testMode { r.testRunPosts.append(n.id) }
    try store.setKV(Self.autoRetryKey(p), r)
    try store.logEvent("postiz", "\(p.platform.displayName): failed, automatic retry \(r.count) on \(Sched.shortTime(n.scheduledAt, settings))\(job.testMode ? " (stays a test run)" : "")",
                       videoId: p.videoId, postId: n.id)
    return true
  }

  /// A day past its time, a retry stops being quiet.
  public static let stuckAfter: TimeInterval = 86400
  /// Round 22: failing with the same error this long, a retry keeps going but shows one calm item.
  public static let keepsFailingAfter: TimeInterval = 7 * 86400

  /// Retries that have failed with the same error (not YouTube's quota) for `keepsFailingAfter`: one item each for Eric,
  /// "Keeps failing on TikTok: <reason>". They keep retrying.
  public func keepsFailing() throws -> [PostizKeepsFailing] {
    guard try !openRetryRecords().isEmpty else { return [] }
    let settings = try store.settings()
    return try keepsFailing(settings: settings, router: router(settings))
  }

  func keepsFailing(settings: Settings, router: PostizRouter) throws -> [PostizKeepsFailing] {
    var seen = Set<String>(), out: [PostizKeepsFailing] = []
    for retry in try pendingAutoRetries(settings: settings, router: router) {
      let p = retry.post
      guard seen.insert(Self.autoRetryKey(p)).inserted else { continue }
      let r = try autoRetries(p)
      guard let why = r.failingWith, let since = r.failingSince, !Self.isYouTubeQuota(why),
            now.timeIntervalSince(since) >= Self.keepsFailingAfter else { continue }
      out.append(PostizKeepsFailing(platform: p.platform, postId: p.id, videoId: p.videoId, since: since,
                                    reason: why.components(separatedBy: " — ").first ?? why))
    }
    return out
  }
  /// A day late with nothing stopping it, an attempt gets this many more ticks (about an hour awake) before it's handed
  /// to Eric. Wall time alone can't tell: a Mac that slept three days wakes with every attempt "a day late".
  public static let maxUnsentTicks = 60

  /// Retries with something still to come (no read of the settings or Keychain for these).
  func openRetryRecords() throws -> [PostizAutoRetries] {
    let rows = try store.db.query("SELECT json FROM kv WHERE substr(key, 1, ?) = ?", [Self.autoRetryPrefix.count, Self.autoRetryPrefix])
    return try rows.compactMap { row -> PostizAutoRetries? in
      guard let r: PostizAutoRetries = row.json("json") else { return nil }
      if let id = r.lastPostId, let a = try store.post(id: id), !a.state.isTerminal { return r }
      if let id = r.failedPostId, let f = try store.post(id: id), f.state == .failed, f.resolution == nil { return r }
      return nil
    }
  }

  /// Nothing sits silently, and nothing shouts. A retry that has waited a day on a pause or a setting says so once,
  /// calmly, and keeps waiting; one waiting for its channel's sign-in says nothing here (the platform's one sign-in item
  /// does). An attempt nothing stops that still can't reach Postiz after a day (the clip went invalid, Postiz won't take
  /// it) goes to the Calendar as a normal post: it stops being a retry, so it can go overdue.
  func watchStuckRetries(settings: Settings, router: PostizRouter) throws {
    for item in try keepsFailing(settings: settings, router: router) {
      let tag = try store.video(id: item.videoId)?.tag ?? item.videoId
      _ = notify(AppNotification(key: "postiz.keepsFailing:\(item.videoId)#\(item.platform.rawValue):\(Int(item.since.timeIntervalSince1970))",
                                 title: item.title, body: "\(tag): \(item.reason). It keeps retrying by itself.", critical: false,
                                 actions: [.open], postId: item.postId, videoId: item.videoId))
    }
    for retry in try pendingAutoRetries(settings: settings, router: router) {
      let p = retry.post
      let due = try autoRetries(p).nextRetryAt ?? p.scheduledAt
      guard now.timeIntervalSince(due) >= Self.stuckAfter else { continue }
      if retry.waiting != nil {
        if retry.signIn { continue }
        let tag = try store.video(id: p.videoId)?.tag ?? p.videoId
        _ = notify(AppNotification(key: "postiz.retryWaits:\(p.id)", title: "\(p.platform.displayName) · \(tag) · waiting to post",
                                   body: "\(retry.text). Nothing is lost: it goes out by itself then.", critical: false,
                                   actions: [.open], postId: p.id, videoId: p.videoId))
      } else if retry.queued, try store.livePostizJob(postId: p.id) == nil {
        try store.db.transaction {
          var r = try autoRetries(p)
          guard r.lastPostId == p.id, var a = try store.post(id: p.id), !a.state.isTerminal else { return }
          r.unsentTicks = (r.unsentTicks ?? 0) + 1
          if r.unsentTicks! >= Self.maxUnsentTicks {
            r.lastPostId = nil
            r.unsentTicks = nil
            a.errorMessage = "This retry couldn't reach Postiz for a day, so it's on the Calendar to post by hand"
            try store.save(a, note: "automatic retry handed over: unsent a day after its time")
            try store.logEvent("postiz", "\(p.platform.displayName): \(a.errorMessage!)", videoId: p.videoId, postId: p.id)
          }
          try store.setKV(Self.autoRetryKey(p), r)
        }
      }
    }
  }

  /// The engine's `retry` step: a failure that waited, or one an older build left. A failure the sync step just read has
  /// its attempt already. Each post is re-read inside its own `BEGIN IMMEDIATE`, so two processes ticking retry once. No
  /// read of the settings or Keychain with nothing to do, and no write lock for a post that only waits.
  public func retryFailures() throws -> String {
    let failed = try store.posts(where: Self.failedFromPostiz, [ErrorType.uploadFailed.rawValue])
    guard try !failed.isEmpty || !openRetryRecords().isEmpty else { return "none" }
    let settings = try store.settings()
    let router = try router(settings)
    try reconcileSignIn(router)
    var queued = 0
    for c in failed {
      let d = try retryDecision(c, settings: settings, router: router)
      if try d == .nothing || (d == .wait && store.retryIsComing(c)) { continue }
      if try store.db.transaction({ try retryOne(c.id, settings: settings, router: router) }) { queued += 1 }
    }
    try watchStuckRetries(settings: settings, router: router)
    return queued == 0 ? "none" : "scheduled \(queued)"
  }

  /// A retry attempt whose time passed while it couldn't be sent (the Mac slept, posting was paused): it goes out now,
  /// past the gap from the platform's other posts. `p` comes from a list read before the publish loop, whose uploads take
  /// minutes, so it's read again here: nil when Eric marked it posted, skipped or removed it meanwhile. A stale copy
  /// must never be saved over that, or sent.
  func retimeRetry(_ p: PlatformPost, settings: Settings) throws -> PlatformPost? {
    guard p.kind != .regular else { return p }
    return try store.db.transaction {
      guard var q = try store.post(id: p.id), Self.openStates.contains(q.state), try store.livePostizJob(postId: p.id) == nil else { return nil }
      guard q.scheduledAt < now.addingTimeInterval(Self.leadTime), try isRetryAttempt(q) else { return q }
      q.scheduledAt = try Sched.retrySlot(store: store, platform: p.platform, target: soonestRetry, settings: settings, excluding: [p.id])
      if q.state == .due { q.state = q.renderId == nil ? .planned : .rendered }
      try store.save(q, note: "retry time passed → \(Sched.shortTime(q.scheduledAt, settings))")
      return q
    }
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
    let wait = try retryWaitReason(p, settings: settings, router: router)
      ?? (retryMustWait(p) ? RetryWait(text: "when its other post is done") : nil)
    return Self.pending(p, number: r.count + (r.tryUnused == true ? 0 : 1), queued: false, at: r.nextRetryAt, wait: wait,
                        settings: settings, now: now)
  }

  static func pending(_ p: PlatformPost, number: Int, queued: Bool, at: Date?, wait: RetryWait?,
                      settings: Settings, now: Date) -> PostizPendingRetry {
    let text: String
    if let wait { text = "Retrying \(wait.text)" }
    else if let at, at > now { text = "Retrying \(Sched.retryDay(at, settings))" }
    else { text = "Retrying now" }
    let badge = wait.map { $0.signIn ? signInBadge : "Retry waits" } ?? text
    return PostizPendingRetry(post: p, number: number, queued: queued, at: wait == nil ? at : nil, waiting: wait?.text,
                              offPostiz: wait?.offPostiz ?? false, signIn: wait?.signIn ?? false, text: text, badge: badge)
  }

  /// The chip on a post that waits for its channel's sign-in (a failure, its attempt, or a post not sent yet).
  public static let signInBadge = "Waits for sign-in"

  /// `.retrying` when a retry is coming for `p`. `base` is what Postiz is doing with it otherwise: a retry Postiz is
  /// sending, posted or holds as a draft says so itself.
  func retryDisplay(_ p: PlatformPost, base: PostizDisplayState?, router: PostizRouter) throws -> PostizDisplayState? {
    guard p.kind != .regular || p.state == .failed else { return nil }
    switch base {
    case nil, .queued?, .sending?, .scheduled?, .failed?, .fellBack?: break
    default: return nil
    }
    if let r = try pendingRetry(p, settings: router.settings, router: router) { return r.display }
    // A failure whose attempt is out: it says what the attempt says, or Today would still read Failed.
    guard p.state == .failed, p.resolution == "retried", let id = try autoRetries(p).lastPostId, id != p.id,
          let a = try store.post(id: id), a.attemptNo > p.attemptNo,
          let r = try pendingRetry(a, settings: router.settings, router: router) else { return nil }
    return r.display
  }

  /// Retries still to come, soonest first, for Doctor and `djq postiz status`.
  public func pendingAutoRetries() throws -> [PostizPendingRetry] {
    guard try !openRetryRecords().isEmpty else { return [] }
    let settings = try store.settings()
    return try pendingAutoRetries(settings: settings, router: try router(settings))
  }

  func pendingAutoRetries(settings: Settings, router: PostizRouter) throws -> [PostizPendingRetry] {
    var out: [PostizPendingRetry] = []
    for r in try openRetryRecords() {
      for id in Set([r.lastPostId, r.failedPostId].compactMap({ $0 })) {
        if let p = try store.post(id: id), let pending = try pendingRetry(p, settings: settings, router: router) { out.append(pending) }
      }
    }
    return out.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
  }
}
