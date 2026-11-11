import Foundation

/// Everything Eric (or an agent) does to a platform post (spec §8–§10). A fix, re-upload or repost always creates
/// a new attempt; history is never rewritten (post_history logs every state change).
///
/// Missed-slot actions (offered on the "missed" notification of an overdue post):
/// - **Post now** (`postNow`): the post becomes due right now; the plan stays as the engine shifted it.
/// - **Shift plan** (`shiftPlan`): the post goes into today's slot for its platform (or the next free day); if that
///   slot is taken, the platform's remaining plan moves one more day later. It becomes due at the slot time.
/// - **Skip** (`skip`): the post is skipped; the gap the engine opened is closed by pulling that platform's
///   remaining plan back so its next post fills today's slot.
public final class PostActions: @unchecked Sendable {
  let store: Store

  public init(store: Store) { self.store = store }

  var now: Date { store.clock.now }

  // MARK: Mark posted / problems

  public func markPosted(postId: String, url: String, at: Date? = nil) throws {
    var p = try post(postId)
    let wasFailed = p.state == .failed
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    try Self.validate(url: url, for: p.platform)
    if p.state != .posted {
      let today = store.today(dm)
      let day = dm.key(p.scheduledAt)
      if !settings.allowEarlyPosting, p.scheduledAt > now {
        throw EngineError("Not due yet — \(p.platform.displayName) is planned for \(Sched.shortTime(p.scheduledAt, settings))")
      }
      if day > today {
        throw EngineError("This post is planned for \(Sched.shortTime(p.scheduledAt, settings)). Use Post today to move it first.")
      }
    }
    p.state = .posted
    p.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    p.postedAt = at ?? now
    try store.save(p, note: "marked posted")
    // Posted by hand from a failed row: its retry must not go out too (the publish step deletes it from Postiz).
    if wasFailed {
      for var a in try store.posts(where: "video_id=? AND platform=? AND version_no=? AND attempt_no>?",
                                   [p.videoId, p.platform.rawValue, p.versionNo, p.attemptNo]) where !a.state.isTerminal {
        a.state = .skipped
        try store.save(a, note: "attempt \(p.attemptNo) was marked posted")
      }
    }
    try store.logEvent("posted", "\(p.platform.displayName) posted: \(p.url!)", videoId: p.videoId, postId: p.id)
    try store.refreshState(videoId: p.videoId)
  }

  /// A publisher (Postiz) reports the post live: posted with its link and platform id, through the same history and
  /// state refresh as Mark posted, but without the "not due yet" checks (the publisher is the authority on when it
  /// went out). A link on the wrong host is kept out of `url` (Doctor reports the post as missing its link).
  public func recordPublished(postId: String, url: String?, externalId: String?, at: Date, note: String) throws {
    var p = try post(postId)
    let clean = url?.trimmingCharacters(in: .whitespacesAndNewlines)
    let valid = clean.flatMap { (try? Self.validate(url: $0, for: p.platform)) != nil ? $0 : nil }
    p.state = .posted
    p.url = valid ?? p.url
    p.externalId = externalId ?? p.externalId
    p.postedAt = at
    p.errorType = nil
    p.errorMessage = nil
    if valid == nil, let clean, !clean.isEmpty { p.rawResponse = "release url: \(clean)" }
    try store.save(p, note: note)
    try store.logEvent("posted", "\(p.platform.displayName) posted: \(p.url ?? "link missing")", videoId: p.videoId, postId: p.id)
    try store.refreshState(videoId: p.videoId)
  }

  /// The URL must parse and its host must be (a subdomain of) one of the platform's hosts.
  public static func validate(url: String, for platform: Platform) throws {
    let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { throw EngineError("Paste the post's URL") }
    guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = u.host?.lowercased() else {
      throw EngineError("That isn't a link — paste the post's URL (https://…)")
    }
    let ok = platform.urlHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    if !ok {
      throw EngineError("That link is on \(host), not \(platform.displayName) (\(platform.urlHosts.joined(separator: " / ")))")
    }
  }

  public func reportProblem(postId: String, type: ErrorType, message: String, raw: String? = nil) throws {
    var p = try post(postId)
    p.state = type.postState
    p.errorType = type
    p.errorMessage = message
    p.rawResponse = raw
    p.resolution = nil
    try store.save(p, note: "\(type.rawValue): \(message)")
    try store.clearRetryPromise(p)  // a new report is a new failure: `errored` promises again if this one retries
    if type == .tooLong { try Self.snapshotTrim(store: store, post: p) }
    try store.logEvent("problem", "\(p.platform.displayName): \(type.displayName) — \(message)", videoId: p.videoId, postId: p.id)
    try store.refreshState(videoId: p.videoId)
  }

  /// A clip sent back to Edit ("Remove from queue") never posts: every action that would make one of its posts
  /// live again (fix/retry, re-upload, post now, shift plan, reset, repost) is refused with this reason.
  public static let heldReason = "Sent back to Edit — send it to the queue first"

  func ensureNotHeld(_ videoId: String) throws {
    if try store.video(id: videoId)?.heldInEdit == true { throw EngineError(Self.heldReason) }
  }

  /// Copyright is never retried automatically. Re-upload → new attempt next day; skip → skipped; accept → recorded.
  public func resolveCopyright(postId: String, _ r: CopyrightResolution) throws {
    var p = try post(postId)
    guard p.state.isCopyright else { throw EngineError("This post has no copyright problem") }
    switch r {
    case .reuploadAnyway(let versionNo):
      try ensureNotHeld(p.videoId)
      let v = versionNo ?? p.versionNo
      if try store.resolvedVersion(videoId: p.videoId, number: v) == nil { throw EngineError("Add v\(v) first") }
      guard try !versionIsOut(v, of: p) else {
        throw EngineError("v\(v) is already posted or on its way on \(p.platform.displayName) — pick another version")
      }
      let n = try newAttempt(from: p, kind: .retry, versionNo: v, note: "re-upload after \(p.state.rawValue)")
      p.resolution = "reuploaded"
      try store.save(p, note: "re-upload → attempt \(n.attemptNo)")
    case .skipPlatform:
      p.resolution = "skipped"
      p.state = .skipped
      try store.save(p, note: "copyright: skip this platform")
    case .accept:
      p.resolution = "accepted"
      try store.save(p, note: "copyright: accepted")
    }
    try store.refreshState(videoId: p.videoId)
  }

  /// Another post of this version on the platform is posted, still live, or was published by Postiz (even if not synced).
  func versionIsOut(_ v: Int, of p: PlatformPost) throws -> Bool {
    try store.posts(where: "video_id=? AND platform=? AND version_no=? AND id<>?", [p.videoId, p.platform.rawValue, v, p.id]).contains { o in
      if o.state == .posted || !o.state.isTerminal { return true }
      return try store.postizJobs(postId: o.id).contains { [.published, .inbox].contains($0.closeReason) || $0.remoteState == "PUBLISHED" }
    }
  }

  /// The cause of a (non-copyright) failure is fixed: new attempt on the next day's slot, ≥ 3 h from that day's
  /// regular post on the platform. A failure found before its day keeps its original time. Runs in one transaction,
  /// so Eric's Fixed and an automatic retry (`by: "auto-retry"`, the word in the post's history, with its own time `at`)
  /// make one attempt.
  @discardableResult
  public func fixed(postId: String, by who: String = "fixed", at: Date? = nil) throws -> PlatformPost {
    try store.db.transaction {
      var p = try post(postId)
      try ensureNotHeld(p.videoId)
      guard !p.state.isCopyright else {
        throw EngineError("Copyright problems are never retried automatically — choose Re-upload anyway, Skip platform or Accept")
      }
      guard p.state == .failed else { throw EngineError("Only a failed post can be marked fixed (this one is \(p.state.displayName))") }
      guard p.resolution == nil else { throw EngineError("Already handled (\(p.resolution!))") }
      let n = try newAttempt(from: p, kind: .retry, versionNo: p.versionNo, note: "\(who): \(p.errorType?.rawValue ?? "failed")", at: at)
      p.resolution = "retried"
      try store.save(p, note: "\(who) → attempt \(n.attemptNo)")
      try store.refreshState(videoId: p.videoId)
      return n
    }
  }

  /// Back to planned with the error/URL cleared (the engine makes it due again at its time).
  public func reset(postId: String) throws {
    var p = try post(postId)
    try ensureNotHeld(p.videoId)
    p.state = p.renderId == nil ? .planned : .rendered
    p.url = nil
    p.postedAt = nil
    p.errorType = nil
    p.errorMessage = nil
    p.rawResponse = nil
    p.resolution = nil
    try store.save(p, note: "reset")
    try store.releasePostizJobs(postId: p.id)  // a reset post may go through Postiz again (never a published one)
    try store.clearRetryPromise(p)
    try store.clearNotified(Self.problemKey(p.id))  // a later failure of this post gets its own alert
    try store.refreshState(videoId: p.videoId)
  }

  public func skip(postId: String) throws {
    var p = try post(postId)
    guard !p.state.isTerminal else { throw EngineError("Already \(p.state.displayName)") }
    let wasOverdue = p.state == .overdue
    p.state = .skipped
    try store.save(p, note: "skipped")
    if wasOverdue { try closeGap(after: p) }
    try store.refreshState(videoId: p.videoId)
  }

  /// Missed-slot action: due right now (on today's slot for its platform; the platform's later posts move a day
  /// if today's slot was taken). Refused when that platform already posted today.
  public func postNow(postId: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    var p = try post(postId)
    guard !p.state.isTerminal else { throw EngineError("Already \(p.state.displayName)") }
    try ensureNotHeld(p.videoId)
    let today = store.today(dm)
    try store.db.transaction {
      if p.kind == .regular {
        let pos = try store.position(of: p)
        guard try makeRoom(platform: p.platform, position: pos, day: today, excluding: p.id, dm: dm, settings: settings) else {
          throw EngineError("\(p.platform.displayName) already has a posted or pinned post today — use Shift plan to put this on the next free day")
        }
      }
      p.state = .due
      p.scheduledAt = now
      // Round 22 (R7): a platform set to Postiz sends it through Postiz at the soonest time (now + the lead time); only a
      // Manual platform hands it to the Calendar to post by hand. The note says which (`PostizService.handedToToday`).
      try store.save(p, note: try postNowGoesThroughPostiz(p) ? Self.postNowPostizNote : "post now")
    }
    try store.refreshState(videoId: p.videoId)
  }

  /// The history note of a Post now that goes through Postiz (round 22). It isn't a hand-over to the Calendar, and it
  /// lifts an earlier one: Eric asked for it to go out now, through Postiz.
  public static let postNowPostizNote = "post now (Postiz)"

  /// Whether Post now on `p` sends it through Postiz (a platform set to Postiz, and Postiz hasn't finished with this post:
  /// no refusal, deletion or publish of it or its lineage) or hands it to Eric.
  public func postNowGoesThroughPostiz(_ p: PlatformPost) throws -> Bool {
    guard PostizService.settingsAllow(p.platform, try store.settings()) else { return false }
    return try store.finalPostizJob(postId: p.id) == nil && store.publishedPostizJob(lineage: PostizJob.lineage(p)) == nil
  }

  /// Missed-slot action: into today's slot for the platform (or the next day it hasn't posted yet); if that slot is
  /// taken, the platform's later posts move one day. Due at the slot time.
  public func shiftPlan(postId: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    var p = try post(postId)
    guard !p.state.isTerminal else { throw EngineError("Already \(p.state.displayName)") }
    try ensureNotHeld(p.videoId)
    // Round 21: a set-time post has no slot to shift into (position 100 and up is no slot time).
    if try store.hasSetTime(p) { throw EngineError(StageWording.setTimeNoShift) }
    let position = try store.position(of: p)
    var day = store.today(dm)
    try store.db.transaction {
      if p.kind == .regular {
        while try !makeRoom(platform: p.platform, position: position, day: day, excluding: p.id, dm: dm, settings: settings) {
          day = dm.addDays(day, 1)
        }
        p.scheduledAt = Sched.slotTime(settings, dm, date: day, position: position, platform: p.platform)
      } else {
        p.scheduledAt = try Sched.staggered(store: store, platform: p.platform, day: day, settings: settings, dm: dm, excluding: [p.id])
      }
      p.state = p.scheduledAt <= now ? .due : (p.renderId == nil ? .planned : .rendered)
      try store.save(p, note: "shift plan → \(day)")
    }
    try store.refreshState(videoId: p.videoId)
  }

  /// Frees (platform, day, position) for one regular post: un-posted, unpinned regular posts of that platform at this
  /// position from `day` on move later, flowing around pinned/posted days. False when a posted or pinned post
  /// holds that day (a pinned video never moves).
  func makeRoom(platform: Platform, position: Int, day: String, excluding id: String, dm: DayMath, settings: Settings) throws -> Bool {
    let placer = try Placer(store: store, dm: dm, excluding: [id])
    guard placer.isTaken(platform, day: day, position: position) else { return true }
    let movable = try store.movablePosts(platform: platform, position: position, after: dm.date(day), inclusive: true, excluding: id)
    guard try movable.contains(where: { try store.planDay(of: $0, dm: dm) == day }) else { return false }  // posted/pinned holds it
    try store.reflow(movable, days: 0, reserve: [day], dm: dm, note: "made room on \(day)")
    return true
  }

  /// Notification action router for the app.
  public func perform(_ action: NotificationAction, postId: String) throws {
    switch action {
    case .postNow: try postNow(postId: postId)
    case .shiftPlan: try shiftPlan(postId: postId)
    case .skip: try skip(postId: postId)
    case .open, .markPosted: break  // UI: open the Calendar / the Mark-posted sheet
    }
  }

  // MARK: Reposts, metrics, long-form

  /// Next version on a platform, ≥ cooldown days after the platform's last post of the video, staggered.
  @discardableResult
  public func repost(videoId: String, platform: Platform) throws -> PlatformPost {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    guard let v = try store.video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("Long-form is never reposted") }
    if v.heldInEdit { throw EngineError(Self.heldReason) }
    let prior = try store.posts(where: "video_id=? AND platform=?", [videoId, platform.rawValue])
    guard let last = prior.max(by: { ($0.postedAt ?? $0.scheduledAt) < ($1.postedAt ?? $1.scheduledAt) }) else {
      throw EngineError("\(v.tag) hasn't been on \(platform.displayName) yet — plan it instead")
    }
    let next = (prior.map(\.versionNo).max() ?? 1) + 1
    guard try store.versions(videoId: videoId).contains(where: { $0.number == next }) else { throw EngineError("Add v\(next) first") }
    let lastDay = dm.key(last.postedAt ?? last.scheduledAt)
    let day = max(dm.addDays(store.today(dm), 1), dm.addDays(lastDay, settings.repostCooldownDays))
    let at = try Sched.staggered(store: store, platform: platform, day: day, settings: settings, dm: dm)
    let p = PlatformPost(
      id: newId(), videoId: videoId, platform: platform, versionNo: next,
      attemptNo: try store.nextAttemptNo(videoId: videoId, platform: platform), kind: .repost, planSlotId: nil,
      scheduledAt: at, renderId: nil, state: .planned, publisher: last.publisher, externalId: nil, url: nil, postedAt: nil,
      errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now)
    try store.save(p, note: "repost v\(next)")
    try store.logEvent("repost", "Repost v\(next) on \(platform.displayName) \(Sched.shortTime(at, settings))", videoId: videoId, postId: p.id)
    return p
  }

  public func setMetrics(postId: String, _ m: PostMetrics) throws {
    var p = try post(postId)
    var m = m
    if m.at == nil { m.at = now }
    p.metrics = m
    try store.save(p)
  }

  /// Records the YouTube URL and moves the file Ready to Post/Longform → Posted/Longform.
  public func markLongformPosted(videoId: String, url: String) throws {
    guard var v = try store.video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .long else { throw EngineError("\(v.name) is short-form — mark its platform posts instead") }
    try Self.validate(url: url, for: .youtube)
    guard let s = try store.session(id: v.sessionId) else { throw EngineError("Session missing for \(v.name)") }
    let base = URL(fileURLWithPath: s.folder).standardizedFileURL
    let src = base.appendingPathComponent(v.file).standardizedFileURL  // the link itself is moved, never its target
    let fm = FileManager.default
    let readyDir = base.appendingPathComponent("Ready to Post/Longform").path + "/"
    if !v.file.hasPrefix("/"), !v.file.split(separator: "/").contains(".."), src.path.hasPrefix(readyDir),
       src.deletingLastPathComponent().path + "/" == readyDir {
      let destDir = base.appendingPathComponent("Posted/Longform")
      try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
      let realBase = base.resolvingSymlinksInPath().path
      guard destDir.resolvingSymlinksInPath().path == realBase + "/Posted/Longform" else {
        throw EngineError("Posted/Longform in \(s.name) points outside the session folder — not moving anything")
      }
      let dest = Self.freeURL(destDir.appendingPathComponent(src.lastPathComponent))
      guard fm.fileExists(atPath: src.path) || (try? fm.destinationOfSymbolicLink(atPath: src.path)) != nil else {
        throw EngineError("Long-form file not found at \(src.path)")
      }
      try fm.moveItem(at: src, to: dest)
      v.file = "Posted/Longform/" + dest.lastPathComponent
      try store.logEvent("longform", "Moved \(src.lastPathComponent) → Posted/Longform", videoId: v.id)
    }
    let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
    try store.saveIdentity(v)  // file path only changes here; app-owned fields are untouched
    try store.setLongformURL(v.id, clean)
    try store.logEvent("posted", "Long-form posted: \(clean)", videoId: v.id)
  }

  // MARK: Lists

  /// Calendar rows: everything scheduled today, plus anything still due/overdue from earlier days.
  public func dueToday(now: Date) throws -> [PlatformPost] {
    let dm = try store.dayMath()
    let day = dm.key(now)
    let start = dm.date(day), end = dm.date(dm.addDays(day, 1))
    return try store.posts(where: "(scheduled_at>=? AND scheduled_at<?) OR (scheduled_at<? AND state IN ('due','overdue'))",
                           [start, end, start])
  }

  /// The once-only key of a post's "Failed on …" alert.
  public static func problemKey(_ postId: String) -> String { "problem:\(postId)" }

  /// Failed / copyright / overdue posts nobody has handled yet. A failure with an automatic retry coming isn't one.
  public func problems() throws -> [PlatformPost] {
    try store.posts(where: "state IN ('failed','copyright_blocked','copyright_muted','removed','overdue') AND resolution IS NULL")
      .filter { try !store.retryIsComing($0) }
  }

  // MARK: Internals

  func post(_ id: String) throws -> PlatformPost {
    guard let p = try store.post(id: id) else { throw EngineError("No post \(id)") }
    return p
  }

  /// New attempt for the same platform: at `time` when the caller has one (an automatic retry), else next day
  /// (staggered), or the original time when that is still ahead. An attempt at a repost stays a repost: as a `.retry` it
  /// would join the clip's main lineage, and Postiz having published the original would record this attempt as posted
  /// with the original's link, never sending it.
  func newAttempt(from p: PlatformPost, kind: PostKind, versionNo: Int, note: String, at time: Date? = nil) throws -> PlatformPost {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    let at: Date
    if let time {
      at = time
    } else if dm.key(p.scheduledAt) > today {
      at = YouTubeWindow.clear(p.scheduledAt, p.platform)
    } else {
      at = try Sched.staggered(store: store, platform: p.platform, day: dm.addDays(today, 1), settings: settings, dm: dm)
    }
    let n = PlatformPost(
      id: newId(), videoId: p.videoId, platform: p.platform, versionNo: versionNo,
      attemptNo: try store.nextAttemptNo(videoId: p.videoId, platform: p.platform), kind: p.kind == .repost ? .repost : kind,
      planSlotId: p.planSlotId,
      scheduledAt: at, renderId: nil, state: .planned, publisher: p.publisher, externalId: nil, url: nil, postedAt: nil,
      errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now)
    try store.save(n, note: note)
    try store.logEvent("retry", "\(p.platform.displayName) attempt \(n.attemptNo) \(Sched.shortTime(at, settings))", videoId: p.videoId, postId: n.id)
    return n
  }

  /// After skipping an overdue regular post: pull that platform's remaining regular posts at the same position back
  /// so the next one fills the first free day from today. Retries/reposts keep their cooldown/stagger.
  func closeGap(after skipped: PlatformPost) throws {
    guard skipped.kind == .regular else { return }
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    let position = try store.position(of: skipped)
    let rest = try store.movablePosts(platform: skipped.platform, position: position, after: dm.date(today), inclusive: true,
                                      excluding: skipped.id).filter { try store.planDay(of: $0, dm: dm) >= today }
    guard let first = rest.first else { return }
    var placer = try Placer(store: store, dm: dm, excluding: Set(rest.map(\.id)))
    let free = placer.place(skipped.platform, position: position, from: today)
    let gap = dm.days(from: free, to: try store.planDay(of: first, dm: dm))
    guard gap > 0 else { return }
    _ = try store.db.transaction { try store.reflow(rest, days: -gap, dm: dm, note: "gap closed −\(gap) d") }
  }

  /// Records the edit's length-related state for a platform when a too_long failure happens, so the engine only
  /// re-queues after Eric actually changes the trim/skip for it.
  static func snapshotTrim(store: Store, post p: PlatformPost) throws {
    try store.setKV("tooLong.\(p.id)", trimSignature(try store.resolvedEdit(videoId: p.videoId), p.platform))
  }

  /// What a platform's length depends on (resolved: the markers default counts).
  static func trimSignature(_ e: ResolvedEdit, _ p: Platform) -> String {
    let t = e.platformTrims[p].map { "\($0.start)-\($0.end)" } ?? "-"
    return "\(t)|\(e.isSkipped(p))|\(e.trimIn)|\(e.trimOut)"
  }

  static func freeURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return url }
    let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent, dir = url.deletingLastPathComponent()
    for i in 2... {
      let c = dir.appendingPathComponent("\(stem) (\(i))").appendingPathExtension(ext)
      if !fm.fileExists(atPath: c.path) { return c }
    }
    return url
  }
}
