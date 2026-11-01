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
    try store.logEvent("posted", "\(p.platform.displayName) posted: \(p.url!)", videoId: p.videoId, postId: p.id)
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
    if type == .tooLong { try Self.snapshotTrim(store: store, post: p) }
    try store.logEvent("problem", "\(p.platform.displayName): \(type.displayName) — \(message)", videoId: p.videoId, postId: p.id)
    try store.refreshState(videoId: p.videoId)
  }

  /// Copyright is never retried automatically. Re-upload → new attempt next day; skip → skipped; accept → recorded.
  public func resolveCopyright(postId: String, _ r: CopyrightResolution) throws {
    var p = try post(postId)
    guard p.state.isCopyright else { throw EngineError("This post has no copyright problem") }
    switch r {
    case .reuploadAnyway(let versionNo):
      let v = versionNo ?? p.versionNo
      if try store.resolvedVersion(videoId: p.videoId, number: v) == nil { throw EngineError("Add v\(v) first") }
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

  /// The cause of a (non-copyright) failure is fixed: new attempt on the next day's slot, ≥ 3 h from that day's
  /// regular post on the platform. A failure found before its day keeps its original time.
  @discardableResult
  public func fixed(postId: String) throws -> PlatformPost {
    var p = try post(postId)
    guard !p.state.isCopyright else {
      throw EngineError("Copyright problems are never retried automatically — choose Re-upload anyway, Skip platform or Accept")
    }
    guard p.state == .failed else { throw EngineError("Only a failed post can be marked fixed (this one is \(p.state.displayName))") }
    guard p.resolution == nil else { throw EngineError("Already handled (\(p.resolution!))") }
    let n = try newAttempt(from: p, kind: .retry, versionNo: p.versionNo, note: "fixed: \(p.errorType?.rawValue ?? "failed")")
    p.resolution = "retried"
    try store.save(p, note: "fixed → attempt \(n.attemptNo)")
    try store.refreshState(videoId: p.videoId)
    return n
  }

  /// Back to planned with the error/URL cleared (the engine makes it due again at its time).
  public func reset(postId: String) throws {
    var p = try post(postId)
    p.state = p.renderId == nil ? .planned : .rendered
    p.url = nil
    p.postedAt = nil
    p.errorType = nil
    p.errorMessage = nil
    p.rawResponse = nil
    p.resolution = nil
    try store.save(p, note: "reset")
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
    let today = store.today(dm)
    try store.db.transaction {
      if p.kind == .regular {
        let pos = try store.position(of: p)
        guard try makeRoom(platform: p.platform, position: pos, day: today, excluding: p.id, dm: dm, settings: settings) else {
          throw EngineError("\(p.platform.displayName) already posted today — use Shift plan to put this on the next free day")
        }
      }
      p.state = .due
      p.scheduledAt = now
      try store.save(p, note: "post now")
    }
    try store.refreshState(videoId: p.videoId)
  }

  /// Missed-slot action: into today's slot for the platform (or the next day it hasn't posted yet); if that slot is
  /// taken, the platform's later posts move one day. Due at the slot time.
  public func shiftPlan(postId: String) throws {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    var p = try post(postId)
    guard !p.state.isTerminal else { throw EngineError("Already \(p.state.displayName)") }
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

  /// Frees (platform, day, position) for one regular post: if an un-posted regular post sits there, that platform's
  /// un-posted regular posts at this position from `day` on move one day later. False when a posted post sits there.
  func makeRoom(platform: Platform, position: Int, day: String, excluding id: String, dm: DayMath, settings: Settings) throws -> Bool {
    let placer = try Placer(store: store, dm: dm, excluding: [id])
    guard placer.isTaken(platform, day: day, position: position) else { return true }
    let here = try store.posts(where: "platform=? AND kind='regular' AND id<>? AND scheduled_at>=? AND scheduled_at<?",
                               [platform.rawValue, id, dm.date(day), dm.date(dm.addDays(day, 1))])
    let postedHere = try here.filter { $0.state == .posted }.map { try store.position(of: $0) }
    if postedHere.contains(position) { return false }
    let later = try store.posts(where: "platform=? AND kind='regular' AND id<>? AND scheduled_at>=?",
                                [platform.rawValue, id, dm.date(day)])
      .filter { !$0.state.isTerminal && $0.state != .overdue }
    for var o in later {
      guard try store.position(of: o) == position else { continue }
      o.scheduledAt = Sched.shift(o.scheduledAt, days: 1, dm)
      if o.state == .due { o.state = o.renderId == nil ? .planned : .rendered }
      try store.save(o, note: "made room on \(day): +1 d")
    }
    return true
  }

  /// Notification action router for the app.
  public func perform(_ action: NotificationAction, postId: String) throws {
    switch action {
    case .postNow: try postNow(postId: postId)
    case .shiftPlan: try shiftPlan(postId: postId)
    case .skip: try skip(postId: postId)
    case .open, .markPosted: break  // UI: open Today / the Mark-posted sheet
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

  /// Today screen rows: everything scheduled today, plus anything still due/overdue from earlier days.
  public func dueToday(now: Date) throws -> [PlatformPost] {
    let dm = try store.dayMath()
    let day = dm.key(now)
    let start = dm.date(day), end = dm.date(dm.addDays(day, 1))
    return try store.posts(where: "(scheduled_at>=? AND scheduled_at<?) OR (scheduled_at<? AND state IN ('due','overdue'))",
                           [start, end, start])
  }

  /// Failed / copyright / overdue posts nobody has handled yet.
  public func problems() throws -> [PlatformPost] {
    try store.posts(where: "state IN ('failed','copyright_blocked','copyright_muted','removed','overdue') AND resolution IS NULL")
  }

  // MARK: Internals

  func post(_ id: String) throws -> PlatformPost {
    guard let p = try store.post(id: id) else { throw EngineError("No post \(id)") }
    return p
  }

  /// New attempt for the same platform: next day (staggered), or the original time when that is still ahead.
  func newAttempt(from p: PlatformPost, kind: PostKind, versionNo: Int, note: String) throws -> PlatformPost {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    let at: Date
    if dm.key(p.scheduledAt) > today {
      at = p.scheduledAt
    } else {
      at = try Sched.staggered(store: store, platform: p.platform, day: dm.addDays(today, 1), settings: settings, dm: dm)
    }
    let n = PlatformPost(
      id: newId(), videoId: p.videoId, platform: p.platform, versionNo: versionNo,
      attemptNo: try store.nextAttemptNo(videoId: p.videoId, platform: p.platform), kind: kind, planSlotId: p.planSlotId,
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
    let rest = try store.posts(where: "platform=? AND kind='regular' AND scheduled_at>=?", [skipped.platform.rawValue, dm.date(today)])
      .filter { !$0.state.isTerminal && $0.state != .overdue }
      .filter { (try? store.position(of: $0)) == position }
    guard let first = rest.first else { return }
    var placer = try Placer(store: store, dm: dm, excluding: Set(rest.map(\.id)))
    let free = placer.place(skipped.platform, position: position, from: today)
    let gap = dm.days(from: free, to: dm.key(first.scheduledAt))
    guard gap > 0 else { return }
    try store.db.transaction {
      for var o in rest {
        o.scheduledAt = Sched.shift(o.scheduledAt, days: -gap, dm)
        try store.save(o, note: "gap closed −\(gap) d")
      }
    }
  }

  /// Records the edit's length-related state for a platform when a too_long failure happens, so the engine only
  /// re-queues after Eric actually changes the trim/skip for it.
  static func snapshotTrim(store: Store, post p: PlatformPost) throws {
    try store.setKV("tooLong.\(p.id)", trimSignature(try store.edit(videoId: p.videoId), p.platform))
  }

  static func trimSignature(_ e: Edit, _ p: Platform) -> String {
    let t = e.platformTrims[p].map { "\($0.start)-\($0.end)" } ?? "-"
    return "\(t)|\(e.skippedPlatforms.contains(p))|\(e.trimIn ?? -1)|\(e.trimOut ?? -1)"
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
