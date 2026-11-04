import Foundation

/// The Postiz publisher's brain (docs/postiz.md §5): the engine's `publish` and `sync` steps, the daily analytics
/// pull, and the helpers `djq postiz …`, Settings and Doctor use. DJ Queue decides what posts and when; Postiz only
/// delivers. Every call is budgeted (`PostizBudget`), every lifecycle change is a `postiz_jobs` row, and Manual stays
/// the fallback for every post.
///
/// Safety rules it keeps:
/// - at most one open job per platform post (claimed in a transaction; a unique index backs it up);
/// - a replaced or cancelled job is deleted in Postiz first — nothing new is created for that post until the DELETE
///   returned OK or 404 (the open job blocks it);
/// - a job Postiz reports PUBLISHED is never deleted or sent again;
/// - an ERROR mentioning copyright is `copyright_blocked` and never retried by itself.
public final class PostizService: @unchecked Sendable {
  public let store: Store
  public let keyStore: PostizKeyStore
  let transport: PostizTransport
  /// Delivers a notification once per key; returns true when delivered. The engine routes this through its notifier.
  public var notify: (AppNotification) -> Bool

  /// A create isn't made for a slot sooner than this (a past slot goes out as now + 3 min).
  public static let leadTime: TimeInterval = 180
  /// A `creating` job older than this without a Postiz id is checked against Postiz by the sync step.
  public static let staleCreate: TimeInterval = 600

  public init(store: Store, transport: PostizTransport? = nil, keyStore: PostizKeyStore? = nil) {
    self.store = store
    self.transport = transport ?? URLSessionPostizTransport(tempDir: store.paths.work)
    self.keyStore = keyStore ?? KeychainPostizKeyStore()
    notify = { n in
      guard (try? store.markNotified(n.key)) == true else { return false }
      try? store.logEvent("notify", "\(n.title) — \(n.body)", videoId: n.videoId, postId: n.postId)
      return true
    }
  }

  var now: Date { store.clock.now }

  // MARK: Key (Settings → Publishing)

  /// Whether a key is saved (never its value).
  public func hasKey() -> Bool { keyStore.hasKey() }

  /// Saves the key in the Keychain and clears a "key invalid" flag.
  public func saveKey(_ key: String) throws {
    try keyStore.save(key)
    try store.clearPostizKeyInvalid()
    try store.logEvent("postiz", "Postiz API key saved")
  }

  public func deleteKey() throws {
    try keyStore.delete()
    try store.logEvent("postiz", "Postiz API key removed")
  }

  // MARK: Calls

  /// A client whose key is read from the Keychain once (on first use) for this client's lifetime.
  func client(_ settings: Settings) -> PostizClient {
    final class KeyBox: @unchecked Sendable { var key: String? }
    let box = KeyBox()
    let ks = keyStore
    return PostizClient(transport: transport, base: settings.publishing.apiBase) {
      if let k = box.key { return k }
      guard let k = try ks.read(), !k.isEmpty else { throw PostizError.noKey }
      box.key = k
      return k
    }
  }

  /// One budgeted call: takes a slot of the shared hourly budget, then maps 429 (pause 15 min) and 401 (key invalid,
  /// notify once); any success clears the key-invalid flag.
  func call<T>(_ kind: PostizCallKind, _ settings: Settings, _ body: () throws -> T) throws -> T {
    // A refused key isn't retried by every tick (only the hourly probe and an explicit check may call).
    if kind != .check, let inv = try store.postizKeyInvalid() { throw PostizError.unauthorized(inv.message) }
    guard try store.takePostizCall(kind, limit: settings.publishing.hourlyBudget) else { throw PostizError.overBudget }
    do {
      let r = try body()
      if try store.postizKeyInvalid() != nil {
        try store.clearPostizKeyInvalid()
        try store.logEvent("postiz", "Postiz accepts the API key again")
      }
      return r
    } catch let e as PostizError {
      switch e {
      case .rateLimited:
        try store.pausePostiz()
        try store.logEvent("postiz", "Postiz rate limit (429): no calls for 15 min")
      case .unauthorized(let m):
        if try store.setPostizKeyInvalid(m) {
          try store.logEvent("postiz", "Postiz refused the API key\(m.isEmpty ? "" : ": \(m)") — posts go to Today until it's saved again")
          _ = notify(AppNotification(key: "postiz.keyInvalid:\(Int(now.timeIntervalSince1970))", title: "Postiz refused the API key",
                                     body: "Posts set to Postiz go to Today until you save the key again in Settings → Publishing.",
                                     critical: true, actions: [.open]))
        }
      default: break
      }
      throw e
    }
  }

  /// True for errors that mean "stop calling Postiz this tick".
  static func stops(_ e: Error) -> Bool {
    guard let p = e as? PostizError else { return false }
    switch p {
    case .unauthorized, .rateLimited, .overBudget, .noKey, .network: return true
    default: return false
    }
  }

  // MARK: Queries the engine uses

  public func router(_ settings: Settings? = nil) throws -> PostizRouter {
    try PostizRouter.current(store: store, keyStore: keyStore, settings: settings)
  }

  /// The post has an open Postiz job (Postiz holds it, or a create/delete is in progress).
  public func hasLiveJob(postId: String) throws -> Bool { try store.livePostizJob(postId: postId) != nil }

  /// The post goes out through Postiz: it has an open job, or its platform routes to Postiz and nothing ended Postiz
  /// delivery for it (a rejected create, a vanished post…). Such a post gets no manual "due" notification.
  public func deliversThroughPostiz(_ p: PlatformPost, router: PostizRouter) throws -> Bool {
    if try hasLiveJob(postId: p.id) { return true }
    guard router.route(p.platform).isPostiz, !p.state.isTerminal else { return false }
    return try store.finalPostizJob(postId: p.id) == nil
  }

  /// nil when calls can be made; otherwise why not (no key / key refused). Asks the Keychain only for presence.
  func keyProblem() throws -> PostizFallbackReason? {
    if try store.postizKeyInvalid() != nil { return .keyInvalid }
    return keyStore.hasKey() ? nil : .noKey
  }

  // MARK: Publish step

  static let openStates: Set<PostState> = [.planned, .rendering, .rendered, .due]

  /// Why an open job must go (nil = keep it). `replaced` means a new job follows once the delete succeeded.
  func unwanted(_ j: PostizJob, settings: Settings, router: PostizRouter) throws -> (reason: String, close: PostizCloseReason)? {
    guard let p = try store.post(id: j.postId) else { return ("post removed from the plan", .cancelled) }
    if p.state == .posted { return ("marked posted by hand", .cancelled) }
    if p.state.isTerminal { return ("post \(p.state.displayName.lowercased())", .cancelled) }
    if settings.paused { return ("posting paused", .cancelled) }
    if !settings.enabledPlatforms.contains(p.platform) { return ("\(p.platform.displayName) turned off", .cancelled) }
    if settings.pausedPlatforms.contains(p.platform) { return ("\(p.platform.displayName) paused", .cancelled) }
    if settings.publishing.publisher(for: p.platform) != .postiz { return ("\(p.platform.displayName) switched to Manual", .cancelled) }
    if case .postiz(let id, _) = router.route(p.platform), id != j.integrationId { return ("Postiz channel changed", .replaced) }
    if p.renderId == nil || p.renderId != j.renderId { return ("render changed", .replaced) }
    if p.scheduledAt != j.scheduledAt { return ("moved to \(Sched.shortTime(p.scheduledAt, settings))", .replaced) }
    if p.state == .overdue { return ("post overdue", .cancelled) }
    guard case .postiz(let id, let provider) = router.route(p.platform),
          let spec = try? PostizPayload.spec(store: store, post: p, settings: settings, integrationId: id, provider: provider) else {
      return nil  // can't judge now (key/channel problem, render file busy): leave Postiz's copy alone
    }
    if spec.contentHash != j.contentHash { return ("caption, title or settings changed", .replaced) }
    return nil
  }

  /// The engine's `publish` step: reconcile every open job, then submit every Postiz-routed post that is due for
  /// submission (approved, render attached, slot within the render horizon, no job for its current content).
  public func publish() throws -> String {
    let settings = try store.settings()
    let open = try store.openPostizJobs()
    guard !settings.publishing.postizPlatforms.isEmpty || !open.isEmpty else { return "off" }
    let router = try router(settings)
    var deleted = 0, created = 0, rejected = 0, waiting = 0, failed = 0
    var stopped: String?
    if let k = try keyProblem() { stopped = k.message }

    // 1. Jobs that must go (deletes first: highest priority).
    for var j in open where j.phase == .live || j.phase == .deleting {
      if j.remoteState == "PUBLISHED" { continue }  // the sync step records it; never deleted
      if j.phase == .live {
        guard let (why, close) = try unwanted(j, settings: settings, router: router) else { continue }
        j.phase = .deleting
        j.deleteReason = "\(close.rawValue): \(why)"
        try store.save(j)
      }
      guard stopped == nil else { waiting += 1; continue }
      // Near or past its slot Postiz may have published it since the last look: read the states first (the sync
      // step right after this one), delete next tick — a PUBLISHED post is never deleted.
      if j.postizId != nil, j.remoteDate <= now.addingTimeInterval(300), (j.syncedAt ?? .distantPast) < now.addingTimeInterval(-90) {
        try store.setKV(Self.syncNowKey, true)
        waiting += 1
        continue
      }
      do {
        try deleteRemote(&j, settings)
        deleted += 1
      } catch {
        failed += 1
        if Self.stops(error) { stopped = "\(error)" }
      }
    }

    // 2. Creates, soonest slot first.
    if stopped == nil {
      let horizon = now.addingTimeInterval(Double(settings.renderHorizonDays) * 86400)
      let candidates = try store.posts(where: "state IN ('planned','rendering','rendered','due') AND render_id IS NOT NULL AND scheduled_at<=?",
                                       [horizon])
      for p in candidates {
        guard case .postiz(let integration, let provider) = router.route(p.platform),
              !settings.paused, !settings.pausedPlatforms.contains(p.platform),
              try store.livePostizJob(postId: p.id) == nil, try store.finalPostizJob(postId: p.id) == nil else { continue }
        if let s = stopped { _ = s; waiting += 1; continue }
        do {
          switch try submit(p, integrationId: integration, provider: provider, settings: settings) {
          case .created: created += 1
          case .rejected: rejected += 1
          case .skipped: break
          }
        } catch {
          failed += 1
          if Self.stops(error) { stopped = "\(error)" }
        }
      }
    }
    var parts: [String] = []
    if created > 0 { parts.append("scheduled \(created)") }
    if deleted > 0 { parts.append("removed \(deleted)") }
    if rejected > 0 { parts.append("refused \(rejected) → Today") }
    if failed > 0 { parts.append("failed \(failed)") }
    if waiting > 0 { parts.append("waiting \(waiting)") }
    if let s = stopped { parts.append("paused: \(s)") }
    return parts.isEmpty ? "up to date (\(open.count) in Postiz)" : parts.joined(separator: " · ")
  }

  /// DELETE in Postiz, then close the job (404 = already gone = done). On failure the job stays `deleting`, which
  /// blocks any new create for the post.
  func deleteRemote(_ j: inout PostizJob, _ settings: Settings) throws {
    let close: PostizCloseReason = (j.deleteReason ?? "").hasPrefix(PostizCloseReason.replaced.rawValue) ? .replaced : .cancelled
    let why = j.deleteReason.map { String($0.drop { $0 != ":" }.dropFirst().drop { $0 == " " }) } ?? ""
    if let id = j.postizId {
      do {
        try call(.delete, settings) { try client(settings).deletePost(id) }
      } catch PostizError.notFound {
        // already gone
      } catch {
        j.attempts += 1
        j.lastError = "\(error)"
        try store.save(j)
        try store.logEvent("postiz", "Couldn't remove the \(j.platform.displayName) post from Postiz (\(why)): \(error) — retrying; nothing new is sent meanwhile",
                           videoId: j.videoId, postId: j.postId)
        throw error
      }
    }
    try store.closePostizJob(id: j.id, reason: close, note: why)
    if close == .cancelled, var p = try store.post(id: j.postId), !p.state.isTerminal, p.publisher == "postiz" {
      p.publisher = "manual"
      try store.save(p, note: "removed from Postiz: \(why)")
    }
    try store.logEvent("postiz", "Removed from Postiz (\(why))", videoId: j.videoId, postId: j.postId)
  }

  enum SubmitOutcome { case created, rejected, skipped }

  /// Upload (reusing the render's media) and create the scheduled post. A refusal (400/413) closes the job as
  /// rejected and the post falls back to Today with the reason.
  func submit(_ p: PlatformPost, integrationId: String, provider: String, settings: Settings) throws -> SubmitOutcome {
    let spec: PostizPostSpec
    do {
      spec = try PostizPayload.spec(store: store, post: p, settings: settings, integrationId: integrationId, provider: provider)
    } catch {
      return .skipped  // e.g. the render file isn't there yet
    }
    let cachedVideo = try store.postizMedia(renderId: spec.renderId, kind: "video")
    let cachedCover = spec.uploadsCover ? try store.postizMedia(renderId: spec.renderId, kind: "cover") : nil
    let needed = 1 + (cachedVideo == nil ? 1 : 0) + (spec.uploadsCover && cachedCover == nil ? 1 : 0)
    let budget = try store.postizBudget()
    guard !budget.isPaused(now: now),
          budget.remaining(now: now, limit: settings.publishing.hourlyBudget) - PostizCallKind.create.reserve >= needed else {
      throw PostizError.overBudget
    }
    let remoteDate = max(p.scheduledAt, now.addingTimeInterval(Self.leadTime))
    var job = PostizJob(postId: p.id, videoId: p.videoId, platform: p.platform, integrationId: integrationId,
                        renderId: spec.renderId, contentHash: spec.contentHash, scheduledAt: p.scheduledAt, remoteDate: remoteDate,
                        testMode: spec.testMode, postType: spec.type, createdAt: now, updatedAt: now)
    guard try store.claimPostizJob(job) else { return .skipped }  // another process got there first
    let c = client(settings)
    var sentCreate = false
    do {
      let video = try cachedVideo.map { PostizMedia(id: $0.mediaId, path: $0.mediaPath) } ?? upload(spec.renderPath, "video", spec.renderId, c, settings)
      job.mediaId = video.id
      job.mediaPath = video.path
      var cover: PostizMedia?
      if spec.uploadsCover, let cp = spec.coverPath {
        cover = try cachedCover.map { PostizMedia(id: $0.mediaId, path: $0.mediaPath) } ?? upload(cp, "cover", spec.renderId, c, settings)
        job.coverMediaId = cover?.id
        job.coverMediaPath = cover?.path
      }
      try store.save(job)
      sentCreate = true
      let created = try call(.create, settings) { try c.createPost(spec.body(date: remoteDate, video: video, cover: cover)) }
      job.postizId = created[0].postId
      job.phase = .live
      job.remoteState = spec.type == "draft" ? "DRAFT" : "QUEUE"
      job.submittedAt = now
      try store.save(job)
      var post = try store.post(id: p.id) ?? p
      post.publisher = "postiz"
      post.externalId = nil
      try store.save(post, note: spec.type == "draft" ? "draft in Postiz" : "scheduled in Postiz for \(Sched.shortTime(remoteDate, settings))")
      try store.logEvent("postiz", "\(p.platform.displayName): \(spec.type == "draft" ? "draft saved" : "scheduled") in Postiz for \(Sched.shortTime(remoteDate, settings))\(spec.testMode ? " (test run)" : "")",
                         videoId: p.videoId, postId: p.id)
      return .created
    } catch let e as PostizError {
      switch e {
      case .validation(let m), .server(400, let m):
        try reject(job, p, m, settings)
        return .rejected
      case .payloadTooLarge:
        try reject(job, p, "the video is too large for Postiz", settings)
        return .rejected
      case .network, .server:
        if sentCreate {
          // The create may have landed: the sync step adopts it or releases the claim.
          job.lastError = "\(e)"
          try store.save(job)
        } else {
          try store.closePostizJob(id: job.id, reason: .interrupted, note: "\(e)")
        }
        throw e
      default:
        // 401 / 429 / budget: the create was refused before Postiz made anything.
        try store.closePostizJob(id: job.id, reason: .interrupted, note: "\(e)")
        throw e
      }
    } catch {
      try store.closePostizJob(id: job.id, reason: .interrupted, note: "\(error)")
      throw error
    }
  }

  func upload(_ path: String, _ kind: String, _ renderId: String, _ c: PostizClient, _ settings: Settings) throws -> PostizMedia {
    let url = URL(fileURLWithPath: path)
    let mime = kind == "cover" ? (url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg") : "video/mp4"
    var m = try call(.create, settings) { try c.upload(file: url, mimeType: mime) }
    if m.status == "processing" {
      // Short wait for processing media (each check is a budgeted call; give up after three).
      for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 2)
        let s = try call(.create, settings) { try c.mediaStatus(m.id) }
        if s != "processing" { m.status = s; break }
      }
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
    try store.save(PostizMediaRecord(renderId: renderId, kind: kind, mediaId: m.id, mediaPath: m.path, fileSize: size, uploadedAt: now))
    return m
  }

  /// Postiz refused the post: close the job (final), the post goes to Today with the reason, notify.
  func reject(_ job: PostizJob, _ p: PlatformPost, _ message: String, _ settings: Settings) throws {
    try store.closePostizJob(id: job.id, reason: .rejected, note: message)
    if var post = try store.post(id: p.id) {
      post.publisher = "manual"
      try store.save(post, note: "Postiz refused it — post by hand: \(message)")
    }
    let reason = PostizFallbackReason.createRejected(message)
    try store.logEvent("postiz", "\(p.platform.displayName): \(reason.message) — it's on Today to post by hand", videoId: p.videoId, postId: p.id)
    let tag = try store.video(id: p.videoId)?.tag ?? p.videoId
    _ = notify(AppNotification(key: "postiz.rejected:\(job.id)", title: "Postiz refused \(p.platform.displayName) · \(tag)",
                               body: "\(message). It's on Today to post by hand.", critical: false, actions: [.open],
                               postId: p.id, videoId: p.videoId))
  }

  // MARK: Sync step

  public static let syncKey = "postiz.lastSync"
  /// Set by the publish step when a delete waits for fresh states.
  static let syncNowKey = "postiz.syncNow"
  static let channelsKey = "postiz.lastChannels"
  static let probeKey = "postiz.lastProbe"

  /// Minutes between syncs: 10 while a job is within six hours of its slot, waiting for a result, or a create is
  /// unconfirmed; otherwise 60.
  func syncInterval(_ jobs: [PostizJob]) -> TimeInterval {
    let hot = jobs.contains { j in
      j.phase == .creating || j.remoteDate <= now || abs(j.remoteDate.timeIntervalSince(now)) <= 6 * 3600
    }
    return hot ? 600 : 3600
  }

  /// The engine's `sync` step (docs/postiz.md §5): one `GET /posts` over the window of open jobs, mapped onto the
  /// posts; then the hourly key probe / channel refresh and the daily analytics pull when budget allows.
  public func sync(force: Bool = false) throws -> String {
    let settings = try store.settings()
    let all = try store.openPostizJobs()
    guard !settings.publishing.postizPlatforms.isEmpty || !all.isEmpty else { return "off" }
    let jobs = all  // deleting jobs too: their state decides whether the delete may go (never a published one)
    var parts: [String] = []
    if try store.postizKeyInvalid() != nil {
      parts.append(try probeKey(settings))
    } else if !settings.publishing.postizPlatforms.isEmpty {
      if let s = try refreshChannelsIfDue(settings) { parts.append(s) }
    }
    if !jobs.isEmpty, let k = try keyProblem() {
      parts.append("waiting: \(k.message)")
    } else if !jobs.isEmpty {
      let last: Date? = try store.kv(Self.syncKey)
      let asked: Bool = try store.kv(Self.syncNowKey) ?? false
      if asked { try store.db.run("DELETE FROM kv WHERE key=?", [Self.syncNowKey]) }
      if !force, !asked, let last, now.timeIntervalSince(last) < syncInterval(jobs) {
        parts.append("next check in \(Int((syncInterval(jobs) - now.timeIntervalSince(last)) / 60) + 1) min")
      } else {
        parts.append(try syncJobs(jobs, settings))
      }
    }
    if try keyProblem() == nil, let a = try? analytics(settings), !a.isEmpty { parts.append(a) }
    return parts.isEmpty ? (settings.publishing.postizPlatforms.isEmpty ? "off" : "nothing in Postiz") : parts.joined(separator: " · ")
  }

  func probeKey(_ settings: Settings) throws -> String {
    let last: Date? = try store.kv(Self.probeKey)
    if let last, now.timeIntervalSince(last) < 3600 { return "key refused — waiting" }
    try store.setKV(Self.probeKey, now)
    do {
      _ = try call(.check, settings) { try client(settings).isConnected() }
      return "key accepted again"
    } catch {
      return "key still refused"
    }
  }

  @discardableResult
  func refreshChannelsIfDue(_ settings: Settings) throws -> String? {
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    if let cache, now.timeIntervalSince(cache.fetchedAt) < 6 * 3600 { return nil }
    guard keyStore.hasKey() else { return nil }
    do {
      _ = try channels(refresh: true, settings: settings)
      return "channels refreshed"
    } catch {
      return nil
    }
  }

  func syncJobs(_ jobs: [PostizJob], _ settings: Settings) throws -> String {
    let dates = jobs.map(\.remoteDate)
    let start = dates.min()!.addingTimeInterval(-86400), end = dates.max()!.addingTimeInterval(86400)
    let remote: [PostizRemotePost]
    do {
      remote = try call(.sync, settings) { try client(settings).posts(from: start, to: end) }
    } catch {
      return "check failed: \(error)"
    }
    try store.setKV(Self.syncKey, now)
    let byId = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let claimed = Set(try store.postizJobs(where: "postiz_id IS NOT NULL AND kind='post'").compactMap(\.postizId))
    var n: [String: Int] = [:]
    for var j in jobs {
      if j.phase == .creating {
        guard j.postizId == nil, now.timeIntervalSince(j.updatedAt) >= Self.staleCreate else { continue }
        if let r = remote.first(where: { r in
          !claimed.contains(r.id) && r.integrationId == j.integrationId
            && abs((r.publishDate ?? .distantPast).timeIntervalSince(j.remoteDate)) < 2
        }) {
          j.postizId = r.id
          j.postizGroup = r.group
          j.phase = .live
          j.remoteState = r.state
          j.submittedAt = j.submittedAt ?? now
          try store.save(j)
          try store.logEvent("postiz", "Confirmed an interrupted \(j.platform.displayName) create in Postiz", videoId: j.videoId, postId: j.postId)
          n["adopted", default: 0] += 1
        } else {
          try store.closePostizJob(id: j.id, reason: .interrupted, note: "create never reached Postiz")
          n["retry", default: 0] += 1
        }
        continue
      }
      guard let pid = j.postizId else { continue }
      guard let r = byId[pid] else {
        if j.phase == .deleting {
          // Already gone from Postiz: the delete is done.
          let close: PostizCloseReason = (j.deleteReason ?? "").hasPrefix(PostizCloseReason.replaced.rawValue) ? .replaced : .cancelled
          try store.closePostizJob(id: j.id, reason: close, note: "already gone from Postiz")
          n["removed", default: 0] += 1
          continue
        }
        // Allow a couple of minutes for a fresh post to show up in the list.
        guard now.timeIntervalSince(j.submittedAt ?? j.createdAt) > 120 else { continue }
        try vanished(j)
        n["vanished", default: 0] += 1
        continue
      }
      j.remoteState = r.state
      j.remoteError = r.error
      j.postizGroup = r.group ?? j.postizGroup
      j.syncedAt = now
      try store.save(j)
      switch r.state {
      case "PUBLISHED":
        try published(j, r, settings)
        n["posted", default: 0] += 1
      case "ERROR":
        try errored(j, r)
        n["failed", default: 0] += 1
      case "QUEUE" where j.phase == .deleting:
        n["removing", default: 0] += 1
      case "QUEUE":
        if now.timeIntervalSince(j.remoteDate) > 3600 {
          let tag = try j.videoId.flatMap { try store.video(id: $0)?.tag } ?? ""
          _ = notify(AppNotification(key: "postiz.stuck:\(j.id)", title: "\(j.platform.displayName) · \(tag) · still waiting in Postiz",
                                     body: "It was due \(Sched.shortTime(j.remoteDate, settings)). Check the Postiz calendar.",
                                     critical: false, actions: [.open], postId: j.postId, videoId: j.videoId))
          n["stuck", default: 0] += 1
        } else {
          n["scheduled", default: 0] += 1
        }
      default:
        n[r.state.lowercased(), default: 0] += 1
      }
    }
    return "checked \(jobs.count)" + n.keys.sorted().map { " · \($0) \(n[$0]!)" }.joined()
  }

  func published(_ j: PostizJob, _ r: PostizRemotePost, _ settings: Settings) throws {
    var j = j
    j.releaseURL = r.releaseURL
    j.releaseId = r.releaseId
    try store.save(j)
    if j.testMode && j.platform == .tiktok {
      // UPLOAD: nothing is public yet; it sits in the TikTok inbox.
      try store.closePostizJob(id: j.id, reason: .inbox)
      if var p = try store.post(id: j.postId), !p.state.isTerminal {
        p.publisher = "manual"
        try store.save(p, note: "in the TikTok inbox (test run)")
      }
      try store.logEvent("postiz", "TikTok test run: in your TikTok inbox — finish it in the app, then Mark posted with the link",
                         videoId: j.videoId, postId: j.postId)
      _ = notify(AppNotification(key: "postiz.inbox:\(j.id)", title: "TikTok · in your inbox",
                                 body: "Finish it in the TikTok app, then Mark posted with the link.", actions: [.markPosted, .open],
                                 postId: j.postId, videoId: j.videoId))
      return
    }
    let missing = r.releaseId == nil || r.releaseId == "missing" || (r.releaseURL ?? "").isEmpty
    if try store.post(id: j.postId) != nil {
      try PostActions(store: store).recordPublished(postId: j.postId, url: missing ? nil : r.releaseURL,
                                                    externalId: r.releaseId == "missing" ? nil : r.releaseId,
                                                    at: r.publishDate ?? now, note: "published by Postiz")
    } else {
      try store.logEvent("postiz", "\(j.platform.displayName) published by Postiz although the post had left the plan: \(r.releaseURL ?? "no link")",
                         videoId: j.videoId)
      _ = notify(AppNotification(key: "postiz.orphan:\(j.id)", title: "\(j.platform.displayName) posted by Postiz",
                                 body: "It had already left DJ Queue's plan. \(r.releaseURL ?? "")", critical: true, actions: [.open],
                                 videoId: j.videoId))
    }
    try store.closePostizJob(id: j.id, reason: .published)
  }

  /// Words that make a Postiz error a copyright problem (loud, never retried by itself).
  public static func isCopyright(_ message: String) -> Bool {
    let m = message.lowercased()
    return ["copyright", "rights", "music", "audio", "claim"].contains { m.contains($0) }
  }

  func errored(_ j: PostizJob, _ r: PostizRemotePost) throws {
    let msg = (r.error?.isEmpty == false ? r.error! : "Postiz reported an error (no details)")
    let copyright = Self.isCopyright(msg)
    if let p = try store.post(id: j.postId), !p.state.isTerminal {
      try PostActions(store: store).reportProblem(postId: p.id, type: copyright ? .copyrightBlocked : .uploadFailed,
                                                  message: msg, raw: "postiz:\(r.id)")
    }
    try store.closePostizJob(id: j.id, reason: copyright ? .copyright : .error, note: msg)
    try store.logEvent("postiz", "\(j.platform.displayName) failed in Postiz: \(msg)", videoId: j.videoId, postId: j.postId)
  }

  func vanished(_ j: PostizJob) throws {
    try store.closePostizJob(id: j.id, reason: .vanished, note: "not in Postiz any more")
    if var p = try store.post(id: j.postId), !p.state.isTerminal {
      p.publisher = "manual"
      try store.save(p, note: "deleted in Postiz — back to manual")
    }
    try store.logEvent("postiz", "\(j.platform.displayName): \(PostizFallbackReason.vanished.message) — it's on Today to post by hand",
                       videoId: j.videoId, postId: j.postId)
    let tag = try j.videoId.flatMap { try store.video(id: $0)?.tag } ?? ""
    _ = notify(AppNotification(key: "postiz.vanished:\(j.id)", title: "\(j.platform.displayName) · \(tag) · deleted in Postiz",
                               body: "DJ Queue won't send it again. It's on Today to post by hand.", critical: true,
                               actions: [.open], postId: j.postId, videoId: j.videoId))
  }

  // MARK: Analytics (F3)

  public static let analyticsKey = "postiz.lastAnalytics"

  /// Once a day: views/likes for posts Postiz published in the last 30 days, into `PlatformPost.metrics`.
  /// Lowest priority; stops when the budget leaves no room.
  @discardableResult
  public func analytics(_ settings: Settings? = nil, force: Bool = false) throws -> String {
    let settings = try settings ?? store.settings()
    let last: Date? = try store.kv(Self.analyticsKey)
    if !force, let last, now.timeIntervalSince(last) < 86400 { return "" }
    let since = now.addingTimeInterval(-30 * 86400)
    let jobs = try store.postizJobs(where: "close_reason='published' AND postiz_id IS NOT NULL AND closed_at>=? AND kind='post'", [since])
    guard !jobs.isEmpty else { return "" }
    var n = 0
    for j in jobs {
      guard try store.post(id: j.postId) != nil, let pid = j.postizId else { continue }
      let data: Data
      do {
        data = try call(.analytics, settings) { try client(settings).analytics(pid, days: 7) }
      } catch {
        if Self.stops(error) { return n > 0 ? "metrics \(n) (more later)" : "" }
        continue
      }
      if let m = PostizAnalytics.parse(data) {
        try PostActions(store: store).setMetrics(postId: j.postId, m)
        n += 1
      } else if PostizAnalytics.isUnknownShape(data), try store.markNotified("postiz.analyticsShape") {
        Log.shared.warn("postiz analytics: unknown response shape for one post; metrics left empty")
      }
    }
    try store.setKV(Self.analyticsKey, now)
    return n > 0 ? "metrics \(n)" : ""
  }

  // MARK: CLI / Settings helpers

  /// Postiz channels (`GET /integrations`), cached in kv. `refresh: false` returns the cache when there is one.
  @discardableResult
  public func channels(refresh: Bool = true, settings: Settings? = nil) throws -> [PostizIntegration] {
    let settings = try settings ?? store.settings()
    if !refresh, let c: PostizChannelCache = try store.kv(PostizChannelCache.kvKey) { return c.integrations }
    let list = try call(.sync, settings) { try client(settings).integrations() }
    try store.setKV(PostizChannelCache.kvKey, PostizChannelCache(fetchedAt: now, integrations: list))
    return list
  }

  /// `GET /is-connected` (one budgeted call).
  public func checkConnection() throws -> Bool {
    let settings = try store.settings()
    return try call(.check, settings) { try client(settings).isConnected() }
  }

  /// Everything `djq postiz status` and Settings → Publishing show. No network unless `check`.
  public func status(check: Bool = false) throws -> PostizStatus {
    let settings = try store.settings()
    let router = try router(settings)
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    let open = try store.openPostizJobs()
    var connected: Bool?
    var checkError: String?
    if check {
      do { connected = try checkConnection() } catch { connected = false; checkError = "\(error)" }
    }
    let budget = try store.postizBudget()
    let platforms = Platform.allCases.sorted().map { p -> PostizStatus.PlatformRow in
      let route = router.route(p)
      let id = settings.publishing.channels[p]
      return PostizStatus.PlatformRow(
        platform: p, publisher: settings.publishing.publisher(for: p), channelId: id,
        channelName: cache?.integrations.first { $0.id == id }?.name,
        route: route.isPostiz ? "postiz" : (route == .manual ? "manual" : "fallback"),
        fallback: route.fallbackReason?.message, fallbackCode: route.fallbackReason?.code,
        openJobs: open.filter { $0.platform == p }.count)
    }
    return PostizStatus(
      hasKey: router.hasKey || keyStore.hasKey(), keyInvalid: try store.postizKeyInvalid()?.message, connected: connected,
      checkError: checkError, testMode: settings.publishing.testMode, apiBase: settings.publishing.apiBase, platforms: platforms,
      budgetUsed: budget.used(now: now), budgetLimit: settings.publishing.hourlyBudget,
      pausedUntil: budget.isPaused(now: now) ? budget.pausedUntil : nil, openJobs: open.count,
      stuck: try stuckJobs().map(\.id), linkMissing: try linkMissingPosts().map(\.id),
      lastSync: try store.kv(Self.syncKey), channelsFetchedAt: cache?.fetchedAt)
  }

  /// Open jobs Postiz still holds as QUEUE more than an hour after their slot.
  public func stuckJobs() throws -> [PostizJob] {
    try store.openPostizJobs().filter { $0.phase == .live && $0.remoteState == "QUEUE" && now.timeIntervalSince($0.remoteDate) > 3600 }
  }

  /// Posts Postiz published without a usable link (release id "missing").
  public func linkMissingPosts() throws -> [PlatformPost] {
    try store.postizJobs(where: "close_reason='published' AND kind='post'").compactMap { j in
      guard let p = try store.post(id: j.postId), p.state == .posted, p.url == nil else { return nil }
      return p
    }
  }

  /// `GET /posts/{id}/missing`: the platform's recent posts to pick the right one from.
  public func linkCandidates(postId: String) throws -> [(id: String, url: String)] {
    guard let j = try store.postizJobs(postId: postId).last(where: { $0.postizId != nil }), let pid = j.postizId else {
      throw EngineError("No Postiz post for \(postId)")
    }
    let settings = try store.settings()
    return try call(.sync, settings) { try client(settings).missing(pid) }
  }

  /// `PUT /posts/{id}/release-id`, then records the link on the post.
  public func link(postId: String, releaseId: String, url: String) throws {
    guard let j = try store.postizJobs(postId: postId).last(where: { $0.postizId != nil }), let pid = j.postizId else {
      throw EngineError("No Postiz post for \(postId)")
    }
    guard let p = try store.post(id: postId) else { throw EngineError("No post \(postId)") }
    try PostActions.validate(url: url, for: p.platform)
    let settings = try store.settings()
    try call(.sync, settings) { try client(settings).setReleaseId(pid, releaseId: releaseId) }
    var jj = j
    jj.releaseId = releaseId
    jj.releaseURL = url
    try store.save(jj)
    try PostActions(store: store).recordPublished(postId: postId, url: url, externalId: releaseId, at: p.postedAt ?? now,
                                                  note: "link set")
  }

  /// Test mode: release a Postiz draft so it publishes at its time (`PUT /posts/{id}/status`).
  public func releaseDraft(postId: String) throws {
    guard var j = try store.livePostizJob(postId: postId), let pid = j.postizId, j.remoteState == "DRAFT" else {
      throw EngineError("This post isn't a draft in Postiz")
    }
    let settings = try store.settings()
    try call(.create, settings) { try client(settings).setStatus(pid, schedule: true) }
    j.remoteState = "QUEUE"
    try store.save(j)
    try store.logEvent("postiz", "Draft released in Postiz", videoId: j.videoId, postId: postId)
  }

  // MARK: Test run (`djq postiz test <video> [--draft]`)

  /// Builds the six payloads for a clip without scheduling anything. `draft: false` is a dry run: the JSON comes
  /// back with placeholders for media and the key redacted (it is never in a body anyway). `draft: true` uploads the
  /// render and creates a Postiz **draft** for every platform with a channel (nothing reaches a platform).
  public func testPost(videoId: String, draft: Bool) throws -> PostizTestRun {
    let settings = try store.settings()
    guard let v = try store.video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard let r = try store.renders(where: "deleted_at IS NULL AND status='done' AND video_id=? AND version_no=1", [videoId])
      .last(where: { $0.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }) else {
      throw EngineError("\(v.tag) has no finished render — run `djq render \(videoId)` first")
    }
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    let date = now.addingTimeInterval(86400)
    var out = PostizTestRun(videoId: videoId, renderId: r.id, draft: draft, platforms: [])
    let c = client(settings)
    var video: PostizMedia?
    for p in Platform.allCases.sorted() {
      let id = settings.publishing.channels[p]
      let provider = cache?.integrations.first { $0.id == id }?.identifier ?? PostizPlatforms.provider(p)
      let post = PlatformPost(id: "test-\(p.rawValue)", videoId: videoId, platform: p, versionNo: 1, attemptNo: 0, kind: .regular,
                              planSlotId: nil, scheduledAt: date, renderId: r.id, state: .rendered, publisher: "postiz",
                              externalId: nil, url: nil, postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil,
                              resolution: nil, metrics: nil, createdAt: now, updatedAt: now)
      var spec = try PostizPayload.spec(store: store, post: post, settings: settings, integrationId: id ?? "<pick a channel>",
                                        provider: provider)
      if draft { spec.type = "draft" }
      var row = PostizTestRun.Row(platform: p, channelId: id, body: "", postizId: nil, skipped: nil)
      if !draft {
        row.body = Self.pretty(spec.body(date: date, video: PostizMedia(id: "<uploaded media id>", path: "<uploaded media path>"),
                                         cover: spec.uploadsCover ? PostizMedia(id: "<uploaded cover id>", path: "<uploaded cover path>") : nil))
        if id == nil { row.skipped = "no Postiz channel picked" }
        out.platforms.append(row)
        continue
      }
      guard id != nil else { row.skipped = "no Postiz channel picked"; out.platforms.append(row); continue }
      if video == nil {
        video = try store.postizMedia(renderId: r.id, kind: "video").map { PostizMedia(id: $0.mediaId, path: $0.mediaPath) }
          ?? upload(spec.renderPath, "video", r.id, c, settings)
      }
      var cover: PostizMedia?
      if spec.uploadsCover, let cp = spec.coverPath {
        cover = try store.postizMedia(renderId: r.id, kind: "cover").map { PostizMedia(id: $0.mediaId, path: $0.mediaPath) }
          ?? upload(cp, "cover", r.id, c, settings)
      }
      let body = spec.body(date: date, video: video!, cover: cover)
      row.body = Self.pretty(body)
      do {
        let created = try call(.create, settings) { try c.createPost(body) }
        row.postizId = created.first?.postId
        let job = PostizJob(postId: "test:\(videoId):\(p.rawValue)", kind: "test", videoId: videoId, platform: p,
                            integrationId: id!, phase: .closed, postizId: row.postizId, mediaId: video?.id, mediaPath: video?.path,
                            coverMediaId: cover?.id, coverMediaPath: cover?.path, renderId: r.id, contentHash: spec.contentHash,
                            scheduledAt: date, remoteDate: date, testMode: true, postType: "draft", remoteState: "DRAFT",
                            submittedAt: now, closedAt: now, closeReason: .testDraft, createdAt: now, updatedAt: now)
        try store.save(job)
        try store.logEvent("postiz", "Test draft for \(p.displayName) saved in Postiz", videoId: videoId)
      } catch {
        if Self.stops(error) { throw error }
        row.skipped = "\(error)"
      }
      out.platforms.append(row)
    }
    return out
  }

  static func pretty(_ d: Data) -> String {
    guard let o = try? JSONSerialization.jsonObject(with: d),
          let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
      return String(decoding: d, as: UTF8.self)
    }
    return String(decoding: p, as: UTF8.self)
  }
}

/// `djq postiz test` result.
public struct PostizTestRun: Codable, Sendable {
  public struct Row: Codable, Sendable {
    public var platform: Platform
    public var channelId: String?
    /// The request body (pretty JSON). The key is never in it; it travels only in the Authorization header.
    public var body: String
    public var postizId: String?
    public var skipped: String?
  }
  public var videoId: String
  public var renderId: String
  public var draft: Bool
  public var platforms: [Row]
  /// What the request headers look like (the key redacted).
  public var headers: [String: String] = ["Authorization": "<redacted>", "Content-Type": "application/json"]
}

/// `djq postiz status` / Settings → Publishing summary. Never holds the key.
public struct PostizStatus: Codable, Sendable {
  public struct PlatformRow: Codable, Sendable {
    public var platform: Platform
    public var publisher: PublisherKind
    public var channelId: String?
    public var channelName: String?
    /// "manual" | "postiz" | "fallback".
    public var route: String
    public var fallback: String?
    public var fallbackCode: String?
    public var openJobs: Int
  }
  public var hasKey: Bool
  public var keyInvalid: String?
  /// nil = not checked.
  public var connected: Bool?
  public var checkError: String?
  public var testMode: Bool
  public var apiBase: String
  public var platforms: [PlatformRow]
  public var budgetUsed: Int
  public var budgetLimit: Int
  public var pausedUntil: Date?
  public var openJobs: Int
  public var stuck: [String]
  public var linkMissing: [String]
  public var lastSync: Date?
  public var channelsFetchedAt: Date?
}

/// Defensive parsing of `GET /analytics/post/{id}`: a list of `{label, data: [{total, date}]}` series. Unknown shapes
/// give nil (nothing is stored).
public enum PostizAnalytics {
  public static func parse(_ d: Data) -> PostMetrics? {
    guard let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
    func value(_ match: [String]) -> Int? {
      for s in list {
        guard let label = (s["label"] as? String)?.lowercased(), match.contains(where: { label.contains($0) }),
              let data = s["data"] as? [[String: Any]] else { continue }
        let nums = data.compactMap { e -> Int? in
          if let n = e["total"] as? NSNumber { return n.intValue }
          if let t = e["total"] as? String { return Int(t) ?? Double(t).map { Int($0) } }
          return nil
        }
        guard !nums.isEmpty else { continue }
        // Cumulative series (never decreasing) → the last value; daily counts → their sum.
        return zip(nums, nums.dropFirst()).allSatisfy { $0 <= $1 } && nums.count > 1 && nums.first! > 0
          ? nums.last! : nums.reduce(0, +)
      }
      return nil
    }
    let views = value(["view", "impression", "play"])
    let likes = value(["like", "reaction", "favorite"])
    guard views != nil || likes != nil else { return nil }
    return PostMetrics(views: views, likes: likes)
  }

  /// True when the body isn't `{missing: true}` and still couldn't be read (logged once).
  public static func isUnknownShape(_ d: Data) -> Bool {
    if let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["missing"] as? Bool == true { return false }
    return parse(d) == nil
  }
}
