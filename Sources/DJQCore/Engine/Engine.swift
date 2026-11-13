import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct TickReport: Sendable {
  public var started: Date
  public var steps: [String: String]  // step name → one-line summary (or "error: …")
  public var errors: [String]
  public init(started: Date, steps: [String: String] = [:], errors: [String] = []) {
    self.started = started; self.steps = steps; self.errors = errors
  }
  /// Step names in the order a tick runs them (for display).
  public static let order = ["intake", "stages", "plan", "missed", "due", "platform", "alerts", "retry", "render", "publish",
                              "sync", "proxies", "move", "heartbeat", "backup"]
}

/// The background engine (spec §8). One `tick` does whatever is pending; it is safe to call at any time and never
/// overlaps another tick. The app runs it on a background queue via `start()`; the CLI calls `tick` once.
///
/// Tick order: intake → stages (invalid Queue clips → Edit) → plan housekeeping → missed/overdue → due → platform checks → alerts →
/// automatic retries (a failure that waited for a pause or a held clip) → render-ahead → publish → sync → move/cleanup → heartbeat → backup. Missed runs before due so a post that is about to be shifted never gets a
/// "due" notification first; rendering (slow) runs after every notification step so it never delays one, and at
/// most one new render happens per tick (due posts first). Every step catches its own errors into the report.
public final class Engine: @unchecked Sendable {
  public let store: Store
  let renderer: RenderService?
  let publisher: Publisher?
  let notifier: Notifier
  /// Round 6: the Postiz publisher (docs/postiz.md). Built with live defaults when not passed; with every platform on
  /// Manual (the default) it reads no Keychain and makes no call.
  public let postiz: PostizService?
  lazy var planner = Planner(store: store)
  lazy var queue = Queue(store: store)
  lazy var actions = PostActions(store: store)

  private let tickLock = NSLock()
  private let stateLock = NSLock()
  private var rendering = false
  private var _lastTick: TickReport?
  private var pending = false
  private var timer: DispatchSourceTimer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private let loop = DispatchQueue(label: "com.djlovd.queue.engine", qos: .utility)

  /// Background proxy generation (round 2 #12). Created when the engine has the real `Renderer`; nil turns the
  /// "proxies" step off. The tick only ENQUEUES (background priority); encoding happens on the service's own
  /// queue and pauses while a render runs. The app can share this instance for its tiles.
  public var proxyService: ProxyService?

  /// Test seam: false leaves the plan alone (no auto-scheduling), for older tests about something else that tick with
  /// Queue clips. Always true in the app and `djq`.
  public var autoSchedules = true

  /// Called after every tick (on the engine queue when started).
  public var onTick: (@Sendable (TickReport) -> Void)?
  /// Gap between heartbeats that means the Mac was asleep or off.
  public static let sleepGap: TimeInterval = 180

  public init(store: Store, renderer: RenderService?, publisher: Publisher?, notifier: Notifier, postiz: PostizService? = nil) {
    self.store = store
    self.renderer = renderer
    self.publisher = publisher
    self.notifier = notifier
    self.postiz = postiz ?? PostizService(store: store)
    if renderer is Renderer {
      let ps = ProxyService(store: store)
      proxyService = ps
      ps.shouldPause = { [weak self] in self?.isRendering ?? false }
    }
    self.postiz?.notify = { [weak self] n in self?.notify(n) ?? false }
  }

  public private(set) var lastTick: TickReport? {
    get { stateLock.withLock { _lastTick } }
    set { stateLock.withLock { _lastTick = newValue } }
  }

  public var isRendering: Bool { stateLock.withLock { rendering } }

  // MARK: Loop

  public func start() {
    guard timer == nil else { return }
    try? store.heartbeat(.start)
    let t = DispatchSource.makeTimerSource(queue: loop)
    t.schedule(deadline: .now() + 1, repeating: 60, leeway: .seconds(5))
    t.setEventHandler { [weak self] in self?.runTick("timer") }
    t.resume()
    timer = t
    #if canImport(AppKit)
    let ws = NSWorkspace.shared.notificationCenter
    observers.append((ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
      try? self?.store.heartbeat(.wake)
      self?.requestTick("wake")
    }))
    observers.append((ws, ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
      try? self?.store.heartbeat(.sleep)
    }))
    #endif
    let dc = DistributedNotificationCenter.default()
    observers.append((dc, dc.addObserver(forName: .init(ChangeSignal.name), object: nil, queue: nil) { [weak self] _ in
      self?.requestTick("change")
    }))
  }

  public func stop() {
    timer?.cancel()
    timer = nil
    for (c, o) in observers { c.removeObserver(o) }
    observers = []
    try? store.heartbeat(.stop)
  }

  /// Queues a tick on the engine queue (coalesced: at most one waiting).
  public func requestTick(_ reason: String) {
    let go: Bool = stateLock.withLock {
      if pending { return false }
      pending = true
      return true
    }
    guard go else { return }
    loop.async { [weak self] in
      guard let self else { return }
      self.stateLock.withLock { self.pending = false }
      self.runTick(reason)
    }
  }

  private func runTick(_ reason: String) {
    let r = tick(reason: reason)
    onTick?(r)
  }

  // MARK: Tick

  @discardableResult
  public func tick(reason: String) -> TickReport {
    tickLock.lock()
    defer { tickLock.unlock() }
    let started = store.clock.now
    var r = TickReport(started: started)
    let lastBeat = try? store.lastHeartbeat()
    var ctx = TickContext()

    step("intake", &r) {
      let ir = try Intake(store: store).run()
      return "sessions \(ir.sessionsSeen) · new \(ir.newVideos.count) · missing \(ir.missing.count) · relinked \(ir.relinked.count)"
    }
    // Round 4 (S1): the Queue only holds ready clips — invalid ones move to Edit (after intake marks missing files,
    // before planning so the scheduler never picks a clip that just left the Queue).
    step("stages", &r) { try Revalidation(store: store).run().summary }
    step("plan", &r) { try planHousekeeping() }
    step("missed", &r) { try missed() }
    step("due", &r) { try due() }
    step("platform", &r) { try platformChecks() }
    step("alerts", &r) { try alerts() }
    // Round 9: the sync step makes a failure's attempt as soon as it reads it; this picks up one that waited.
    step("retry", &r) { try postiz?.retryFailures() ?? "off" }
    step("render", &r) { try renderAhead(&ctx) }
    // Round 6: submit ahead / replace / cancel in Postiz (after render-ahead attached renders), then read back states.
    step("publish", &r) { try postiz?.publish() ?? "off" }
    step("sync", &r) { try postiz?.sync() ?? "off" }
    step("proxies", &r) { try proxies(ctx) }
    step("move", &r) { try moveAndCleanup() }
    step("heartbeat", &r) { try heartbeat(started: started, last: lastBeat) }
    step("backup", &r) { try Backup.runIfDue(store: store).map { "backup \($0.lastPathComponent)" } ?? "up to date" }

    if !r.errors.isEmpty { Log.shared.warn("tick(\(reason)) errors: \(r.errors.joined(separator: " | "))") }
    lastTick = r
    return r
  }

  struct TickContext {
    var renderBudget = 1  // new renders per tick (earliest posts first, so due posts go first)
    var rendered = 0
    var rendersWaiting = 0
    var invalid: [String: String?] = [:]
  }

  private func step(_ name: String, _ r: inout TickReport, _ body: () throws -> String) {
    do {
      r.steps[name] = try body()
    } catch {
      r.steps[name] = "error: \(error)"
      r.errors.append("\(name): \(error)")
    }
  }

  // MARK: Steps

  /// Drops past draft-week days that never got posts (round 6, F5: their clips go back to the queue; pinned ones too,
  /// since a pin on a day that passed without posts can't post), then keeps every Queue clip on the calendar
  /// (`Planner.autoSchedule`).
  func planHousekeeping() throws -> String {
    let dm = try store.dayMath()
    var done: [String] = []
    let stale = try store.dropStalePastDraftSlots(today: store.today(dm))
    if !stale.isEmpty { done.append("dropped \(stale.count) past day\(stale.count == 1 ? "" : "s")") }
    if autoSchedules { done.append(try planner.autoSchedule().summary) }
    let moved = try store.moveOutOfYouTubeWindow()
    if moved > 0 { done.append("moved \(moved) out of YouTube's quiet window") }
    return done.isEmpty ? "ok" : done.joined(separator: " · ")
  }

  /// A render that failed is retried only after this long, unless its edit/version (hash) changed.
  public static let renderRetryAfter: TimeInterval = 3600

  struct RenderFailure: Codable { var hash: String; var at: Date; var error: String }

  /// Scheduled posts within the horizon get their render; a changed edit/version re-renders. A failure is recorded
  /// (render row failed, notification once a day) and never stops the loop; that render backs off for an hour.
  func renderAhead(_ ctx: inout TickContext) throws -> String {
    guard let renderer else { return "no renderer" }
    let settings = try store.settings()
    let horizon = store.clock.now.addingTimeInterval(Double(settings.renderHorizonDays) * 86400)
    var attached = 0, rendered = 0, waiting = 0, failed = 0, backedOff = 0
    let open: Set<PostState> = [.planned, .rendering, .rendered, .due]
    for listed in try store.posts(where: "state IN ('planned','rendering','rendered','due') AND scheduled_at<=?", [horizon]) {
      // A render takes minutes, and `djq` or the app can move a post meanwhile: this list is stale by the next one.
      guard var p = try store.post(id: listed.id), open.contains(p.state), let v = try store.video(id: p.videoId) else { continue }
      if let msg = try invalidReason(v, &ctx) {
        notify(AppNotification(key: "invalid:\(v.id):\(try store.today(store.dayMath()))", title: "\(v.tag) can't post",
                               body: "\(msg) — fix it in the editor or take it out of the plan.", critical: false,
                               actions: [.open], postId: p.id, videoId: v.id))
        continue
      }
      if let cur = try renderer.currentRender(videoId: p.videoId, versionNo: p.versionNo, platform: p.platform) {
        if p.renderId != cur.id || p.state == .planned || p.state == .rendering {
          p.renderId = cur.id
          if p.state != .due { p.state = .rendered }
          try store.save(p, note: "render \(cur.id.prefix(8))")
          attached += 1
        }
        continue
      }
      if p.state == .rendered {
        p.state = .planned
        p.renderId = nil
        try store.save(p, note: "edit changed — re-render")
      }
      // Back off: this exact render (same edit/version hash) failed < 1 h ago → skip without using the budget.
      let scope = try renderer.scope(videoId: p.videoId, versionNo: p.versionNo, platform: p.platform)
      let hash = try renderer.editHash(videoId: p.videoId, versionNo: p.versionNo, platform: p.platform)
      let failKey = "renderFail.\(p.videoId)#\(p.versionNo)#\(scope)"
      if let last: RenderFailure = try store.kv(failKey), last.hash == hash,
         store.clock.now.timeIntervalSince(last.at) < Self.renderRetryAfter {
        backedOff += 1
        continue
      }
      guard ctx.renderBudget > 0 else { waiting += 1; continue }
      ctx.renderBudget -= 1
      do {
        try renderPost(&p, renderer)
        rendered += 1
      } catch {
        // Record, notify once a day, and carry on with the next post (a failure doesn't use up the budget).
        ctx.renderBudget += 1
        failed += 1
        try store.setKV(failKey, RenderFailure(hash: hash, at: store.clock.now, error: "\(error)"))
        for r in try store.renders(where: "deleted_at IS NULL AND status<>'done' AND video_id=? AND version_no=? AND edit_hash=? AND scope=?",
                                   [p.videoId, p.versionNo, hash, scope]) {
          try store.setRenderStatus(id: r.id, status: .failed, error: "\(error)")
        }
        try store.logEvent("render", "Render failed: \(v.tag) v\(p.versionNo) (\(scope)): \(error)", videoId: v.id, postId: p.id)
        notify(AppNotification(key: "renderfail:\(v.id):\(p.versionNo):\(try store.today(store.dayMath()))",
                               title: "Render failed · \(v.tag)", body: "\(error)", critical: true, actions: [.open],
                               postId: p.id, videoId: v.id))
      }
    }
    ctx.rendered = rendered
    ctx.rendersWaiting = waiting
    return "rendered \(rendered) · attached \(attached) · waiting \(waiting)\(failed > 0 ? " · failed \(failed)" : "")"
      + (backedOff > 0 ? " · backing off \(backedOff)" : "")
  }

  /// Idle-time preview proxies (round 2 #12): queues missing proxies at background priority on `proxyService`
  /// (clips to score first, then needing edit, then ready/planned) and returns at once — no probing or encoding in
  /// the tick. Skipped while this tick rendered or a render waits; the service also pauses during renders.
  func proxies(_ ctx: TickContext) throws -> String {
    guard let ps = proxyService else { return "off" }
    guard ctx.rendered == 0, ctx.rendersWaiting == 0, !isRendering else { return "waiting for renders" }
    let rank: [VideoState: Int] = [.needsEdit: 1, .ready: 2, .planned: 2]
    // Photo posts have no preview video (round 21).
    let vids = try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND photos IS NULL AND state IN ('needs_edit','ready','planned')")
      .sorted { a, b in
        let ra = a.score == nil ? 0 : rank[a.state] ?? 3, rb = b.score == nil ? 0 : rank[b.state] ?? 3
        return (ra, a.part ?? 0, a.start ?? 0, a.id) < (rb, b.part ?? 0, b.start ?? 0, b.id)
      }
    for v in vids.reversed() { ps.request(v.id, priority: .background) }  // later requests sort first among equals
    return "queued \(vids.count) · pending \(ps.pendingCount)"
  }

  /// A whole local day passed (and ≥ lateGraceHours late) → overdue; that platform's remaining regular posts at the
  /// same position move later by the days missed, flowing around pinned days (a pinned video never moves), so
  /// nothing double-posts. Notifies with Post now / Shift plan / Skip.
  /// Each post is re-read inside its own BEGIN IMMEDIATE transaction, so two processes ticking can't shift twice.
  /// A post that was overdue before (reset, or shifted and missed again) goes overdue without shifting anything.
  func missed() throws -> String {
    let settings = try store.settings()
    guard !settings.paused else { return "paused" }
    let dm = DayMath(settings: settings)
    let now = store.clock.now
    let today = dm.key(now)
    var n = 0
    let router = try postiz.map { try $0.router(settings) }
    for c in try store.posts(where: "state IN ('planned','rendering','rendered','due') AND scheduled_at<?", [now]) {
      var outcome: (post: PlatformPost, days: Int)?
      try store.db.transaction {
        guard var p = try store.post(id: c.id), ["planned", "rendering", "rendered", "due"].contains(p.state.rawValue),
              !settings.pausedPlatforms.contains(p.platform), isOverdue(p, now: now, settings: settings, dm: dm) else { return }
        // Postiz holds it (posts with the Mac off): never overdue, nothing shifts. Without a job it is a manual post.
        if try postiz?.holds(p) == true { return }
        // Test-run TikTok waiting in the TikTok inbox: Eric finishes it there — never "missed".
        if try postiz?.isInTikTokInbox(p) == true { return }
        // An automatic retry is never "missed": it goes out as soon as it can, or waits for a pause to end.
        if try postiz?.isRetryAttempt(p) == true { return }
        // Round 22: its channel needs signing in again in Postiz. It waits for that and goes out by itself, never "missed".
        if let postiz, let router, try postiz.waitsForSignIn(p, router: router) { return }
        let again = try store.history(postId: p.id).contains { $0.toState == PostState.overdue.rawValue }
        let days = max(1, dm.days(from: dm.key(p.scheduledAt), to: today))
        p.state = .overdue
        try store.save(p, note: again ? "missed again (no shift)" : "missed (\(days) d)")
        var shifted = 0
        if !again && p.kind == .regular {
          let movable = try store.movablePosts(platform: p.platform, position: try store.position(of: p), after: p.scheduledAt,
                                               excluding: p.id)
          shifted = try store.reflow(movable, days: days, dm: dm, note: "plan shifted +\(days) d (missed \(p.platform.displayName) post)")
        }
        outcome = (p, shifted > 0 ? days : 0)
      }
      guard let (p, days) = outcome else { continue }
      try store.refreshState(videoId: p.videoId)
      let tag = try store.video(id: p.videoId)?.tag ?? p.videoId
      try store.logEvent("missed", "\(p.platform.displayName) missed \(Sched.shortTime(p.scheduledAt, settings)); plan +\(days) d",
                         videoId: p.videoId, postId: p.id)
      let moved = days > 0
        ? "\(p.platform.displayName)'s plan moved \(days) day\(days == 1 ? "" : "s") later so nothing double-posts."
        : "Nothing else moved."
      notify(AppNotification(
        key: "overdue:\(p.id):\(Int(p.scheduledAt.timeIntervalSince1970))", title: "\(p.platform.displayName) · \(tag) · missed",
        body: "Was due \(Sched.shortTime(p.scheduledAt, settings)). \(moved)",
        critical: false, actions: try store.hasSetTime(p) ? [.postNow, .skip] : [.postNow, .shiftPlan, .skip], postId: p.id, videoId: p.videoId))
      n += 1
    }
    return n == 0 ? "none" : "overdue \(n)"
  }

  /// Slot time reached → due (+ one notification per slot). Late but within grace (or same day) stays due.
  /// Never renders (render-ahead does that after the notification steps).
  func due() throws -> String {
    let settings = try store.settings()
    guard !settings.paused else { return "paused" }
    let dm = DayMath(settings: settings)
    let now = store.clock.now
    var n = 0
    let router = try postiz.map { try $0.router(settings) }
    for c in try store.posts(where: "state IN ('planned','rendering','rendered') AND scheduled_at<=?", [now]) {
      guard var p = try store.post(id: c.id), ["planned", "rendering", "rendered"].contains(p.state.rawValue),
            !settings.pausedPlatforms.contains(p.platform), !isOverdue(p, now: now, settings: settings, dm: dm) else { continue }
      guard let v = try store.video(id: p.videoId) else { continue }
      if let postiz, let router, try postiz.retryAttemptWaits(p, router: router) { continue }
      p.state = .due
      // Postiz delivers it (open job, or routed with its render still to come — the publish step submits it as soon
      // as the render lands): no manual "Open the Calendar" notification and no manual publisher.
      if let postiz, let router, try postiz.deliversThroughPostiz(p, router: router) {
        try store.save(p, note: "due (Postiz)")
        try store.refreshState(videoId: p.videoId)
        continue
      }
      try store.save(p, note: "due")
      if let publisher, p.renderId != nil {
        if let prepared = try? publisher.prepare(postId: p.id) { _ = try? publisher.submit(prepared) }
      }
      try store.refreshState(videoId: p.videoId)
      let late = now.timeIntervalSince(p.scheduledAt)
      let when = late >= 30 * 60 ? Sched.lateText(late) : "due now"
      let uncertain = try postiz?.uncertainOnToday(p) == true
      notify(AppNotification(
        key: "due:\(p.id):\(Int(p.scheduledAt.timeIntervalSince1970))", title: "\(p.platform.displayName) · \(v.tag) · \(when)",
        body: uncertain ? "Check the Postiz calendar first — a Postiz create for it was never confirmed. Then post it from the Calendar."
          : "Open the Calendar to copy the caption and drag the file in.",
        critical: uncertain, actions: [.markPosted, .open], postId: p.id, videoId: v.id))
      n += 1
    }
    return n == 0 ? "none" : "due \(n)"
  }

  static let platformCheckMarker = "engine:platform-check"

  /// Too long for a platform → failed (too_long), tagged as made by this check. Re-queued automatically only when
  /// this check made the failure and the length now fits, or when the edit's trim/skip for that platform changed
  /// since the failure (manual reports otherwise wait for `fixed`). Skipped in the editor → skipped.
  func platformChecks() throws -> String {
    let settings = try store.settings()
    let active = Set(settings.activePlatforms)
    var failed = 0, requeued = 0, skipped = 0
    var cache: [String: (Video, ResolvedEdit, [ValidationIssue])] = [:]
    // Round 30: per version, since a version can have its own trim (its own length).
    func info(_ id: String, _ version: Int) throws -> (Video, ResolvedEdit, [ValidationIssue])? {
      let key = "\(id)#\(version)"
      if let c = cache[key] { return c }
      guard let v = try store.video(id: id) else { return nil }
      let e = EditResolver.resolve(try store.edit(videoId: id), video: v, defaults: settings.defaults,
                                   version: store.rawVersion(videoId: id, number: version))
      let c = (v, e, Validation.platformIssues(video: v, resolved: e, settings: settings))
      cache[key] = c
      return c
    }
    for var p in try store.posts(where: "state IN ('planned','rendering','rendered','due','overdue')") {
      guard let (_, _, issues) = try info(p.videoId, p.versionNo),
            let issue = issues.first(where: { $0.kind == .tooLong && $0.platform == p.platform }) else { continue }
      p.state = .failed
      p.errorType = .tooLong
      p.errorMessage = issue.message
      p.rawResponse = Self.platformCheckMarker
      p.resolution = nil
      try store.save(p, note: "platform check: \(issue.message)")
      try PostActions.snapshotTrim(store: store, post: p)
      try store.refreshState(videoId: p.videoId)
      failed += 1
    }
    for var p in try store.posts(where: "state='failed' AND error_type='too_long' AND resolution IS NULL") {
      guard let (v, edit, issues) = try info(p.videoId, p.versionNo), active.contains(p.platform), try !store.isHeld(v) else { continue }
      // Round 31: a newer attempt of this version post, not a later version post of the clip.
      let newer = try store.posts(where: "video_id=? AND platform=? AND attempt_no>? AND version_no=? AND COALESCE(post_no,1)=?",
                                  [p.videoId, p.platform.rawValue, p.attemptNo, p.versionNo, p.postNo])
      guard newer.isEmpty else { continue }
      let snapshot: String? = try store.kv("tooLong.\(p.id)")
      let changed = snapshot != nil && snapshot != PostActions.trimSignature(edit, p.platform)
      let byCheck = p.rawResponse == Self.platformCheckMarker
      guard byCheck || changed else { continue }
      if edit.isSkipped(p.platform) {
        p.state = .skipped
        p.resolution = "skipped"
        try store.save(p, note: "platform skipped in the editor")
        try store.refreshState(videoId: p.videoId)
        skipped += 1
      } else if !issues.contains(where: { $0.kind == .tooLong && $0.platform == p.platform }) {
        try actions.fixed(postId: p.id)
        requeued += 1
      }
    }
    return "too long \(failed) · re-queued \(requeued) · skipped \(skipped)"
  }

  /// Runway alerts, loud problem notifications.
  func alerts() throws -> String {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let now = store.clock.now
    let today = dm.key(now)
    let rw = try queue.runway()
    var sent: [String] = []
    if rw.isLow(settings),
       notify(AppNotification(key: "alert.queuelow:\(today)", title: StageWording.queueLowTitle,
                              body: StageWording.queueLowBody(rw.scheduledThrough, settings: settings), actions: [.open])) {
      sent.append("queue low")
    }
    if rw.totalDays < settings.totalRunwayAlertDays,
       notify(AppNotification(key: "alert.record:\(dm.weekStart(of: now))", title: "Record a new set",
                              body: "About \(rw.totalDays) day\(rw.totalDays == 1 ? "" : "s") of videos left in total.", actions: [.open])) {
      sent.append("record")
    }
    for p in try actions.problems() where p.state != .overdue {
      let tag = try store.video(id: p.videoId)?.tag ?? p.videoId
      let title = p.state.isCopyright ? "\(p.state.displayName) on \(p.platform.displayName)" : "Failed on \(p.platform.displayName)"
      if notify(AppNotification(key: PostActions.problemKey(p.id), title: title,
                                body: "\(tag) — \(p.errorMessage ?? p.state.displayName)", critical: p.state.isCopyright,
                                actions: [.open], postId: p.id, videoId: p.videoId)) {
        sent.append("problem")
      }
    }
    return sent.isEmpty ? "none" : sent.joined(separator: ", ")
  }

  /// Renders whose posts are all terminal move to Posted/Shortform; renders nothing needs are deleted; optional
  /// cleanup of old posted renders (default keep forever, Q8). Render rows are only changed column-by-column.
  func moveAndCleanup() throws -> String {
    let settings = try store.settings()
    let fm = FileManager.default
    var moved = 0, deleted = 0, unneeded = 0, stuck = 0
    var stuckWhy: String?
    let waiting = "/Ready to Post/Shortform/"
    for r in try store.renders(where: "deleted_at IS NULL AND status='done' AND output_path IS NOT NULL") {
      // Any file still in Ready to Post (round 21: a photo post has several, and a move that failed part-way is
      // picked up again here on the next tick).
      guard let out = r.outputPath, (r.allPaths + [r.coverPath].compactMap { $0 }).contains(where: { $0.contains(waiting) }) else { continue }
      let users = try store.posts(where: "render_id=?", [r.id])
      guard !users.isEmpty, users.allSatisfy({ $0.state.isTerminal }) else { continue }
      let open = try store.posts(where: "video_id=? AND version_no=?", [r.videoId, r.versionNo]).filter { !$0.state.isTerminal }
      guard open.isEmpty else { continue }
      // Every file first (one that can't move stays where it is and is tried again), then both columns together.
      var failures: [String] = [], changed = false
      func move(_ path: String) -> String {
        guard path.contains(waiting) else { return path }
        do {
          let new = try moveToPosted(path)
          if new != path { changed = true }
          return new
        } catch {
          failures.append("\(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
          return path
        }
      }
      let newOut = move(out)
      let newCover = r.coverPath.map(move)
      let newMore = r.morePaths.map { $0.map(move) }
      if changed {
        try store.setRenderFiles(id: r.id, outputPath: newOut, coverPath: newCover, morePaths: newMore)
        try store.logEvent("move", "Moved \(URL(fileURLWithPath: out).lastPathComponent) → Posted/Shortform", videoId: r.videoId)
        moved += 1
      }
      if !failures.isEmpty {
        stuck += failures.count
        stuckWhy = stuckWhy ?? failures[0]
        Log.shared.warn("move to Posted: \(failures.joined(separator: " | "))")
      }
    }
    if case .deleteAfter(let days) = settings.cleanup {
      let cutoff = store.clock.now.addingTimeInterval(-Double(days) * 86400)
      for r in try store.renders(where: "deleted_at IS NULL AND output_path LIKE '%/Posted/Shortform/%'") {
        let users = try store.posts(where: "render_id=?", [r.id])
        guard !users.isEmpty, users.allSatisfy({ $0.state.isTerminal }),
              (users.map { $0.postedAt ?? $0.updatedAt }.max() ?? .distantFuture) < cutoff else { continue }
        for path in r.allPaths + [r.coverPath].compactMap({ $0 })
        where path.contains("/Posted/Shortform/") && store.paths.owns(URL(fileURLWithPath: path)) {
          try? fm.removeItem(atPath: path)
        }
        try store.markRenderDeleted(id: r.id)
        deleted += 1
      }
    }
    if let renderer {
      let keep = try rendersToKeep(renderer, settings: settings)
      let before = try store.renders().count
      try renderer.deleteRenders(except: keep)
      unneeded = before - (try store.renders().count)
    }
    let summary = "moved \(moved)\(deleted > 0 ? " · deleted \(deleted)" : "")\(unneeded > 0 ? " · unneeded \(unneeded)" : "")"
    // A file that couldn't move is a tick error, as it always was (`djq tick` exits 1); the other renders, the cleanup
    // and the sweep above still ran, and the file is tried again on the next tick.
    if stuck > 0 {
      throw EngineError("\(summary) · \(stuck) file\(stuck == 1 ? "" : "s") still to move to Posted (\(stuckWhy ?? "unknown"))")
    }
    return summary
  }

  /// Renders referenced by any live or posted post, current renders for scheduled posts within the horizon, renders
  /// of unresolved failed/skipped posts (≤ 7 days), failed renders not yet superseded, and anything made in the last 24 h (editor/CLI previews get a day before they're cleaned up).
  func rendersToKeep(_ renderer: RenderService, settings: Settings) throws -> Set<String> {
    var keep = Set<String>()
    for p in try store.posts(where: "render_id IS NOT NULL") where p.state == .posted || !p.state.isTerminal {
      keep.insert(p.renderId!)
    }
    let horizon = store.clock.now.addingTimeInterval(Double(settings.renderHorizonDays) * 86400)
    for p in try store.posts(where: "scheduled_at<=?", [horizon]) where !p.state.isTerminal {
      if let cur = try renderer.currentRender(videoId: p.videoId, versionNo: p.versionNo, platform: p.platform) {
        keep.insert(cur.id)
      }
    }
    // Failed/skipped/copyright posts keep their render until resolved or 7 days old (so a retry or re-upload can
    // reuse it and Eric can inspect it).
    let week = store.clock.now.addingTimeInterval(-7 * 86400)
    for p in try store.posts(where: "render_id IS NOT NULL AND resolution IS NULL AND updated_at>=?", [week])
    where p.state.isTerminal && p.state != .posted {
      keep.insert(p.renderId!)
    }
    // Failed renders stay visible to Doctor until a good render exists for the same video/version/scope.
    let done = Set(try store.renders(where: "deleted_at IS NULL AND status='done'").map { "\($0.videoId)#\($0.versionNo)#\($0.scope)" })
    for r in try store.renders(where: "deleted_at IS NULL AND status='failed'") where !done.contains("\(r.videoId)#\(r.versionNo)#\(r.scope)") {
      keep.insert(r.id)
    }
    let recent = store.clock.now.addingTimeInterval(-86400)
    for r in try store.renders() where r.createdAt >= recent { keep.insert(r.id) }
    return keep
  }

  func moveToPosted(_ path: String) throws -> String {
    let fm = FileManager.default
    let src = URL(fileURLWithPath: path)
    // Only files under this store's root are ever moved (round 21): a path a copied database names elsewhere stays put.
    guard store.paths.owns(src) else { return path }
    let session = src.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = session.appendingPathComponent("Posted/Shortform")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = PostActions.freeURL(dir.appendingPathComponent(src.lastPathComponent))
    guard fm.fileExists(atPath: src.path) else { return path }
    try fm.moveItem(at: src, to: dest)
    return dest.path
  }

  /// Records the tick; a gap > 3 min since the previous heartbeat means the Mac was asleep/off.
  func heartbeat(started: Date, last: Heartbeat?) throws -> String {
    var note = "ok"
    if let last, started.timeIntervalSince(last.at) > Self.sleepGap {
      if last.kind != .sleep && last.kind != .stop { try store.heartbeat(.sleep, at: last.at) }
      try store.heartbeat(.wake, at: started)
      note = "woke after \(Int(started.timeIntervalSince(last.at) / 60)) min"
      try store.logEvent("engine", "Mac was off/asleep \(Int(started.timeIntervalSince(last.at) / 60)) min")
    }
    try store.heartbeat(.tick)
    return note
  }

  // MARK: Helpers

  func isOverdue(_ p: PlatformPost, now: Date, settings: Settings, dm: DayMath) -> Bool {
    now.timeIntervalSince(p.scheduledAt) >= settings.lateGraceHours * 3600 && dm.key(now) > dm.key(p.scheduledAt)
  }

  /// Why a planned video can't be rendered/posted right now (nil = fine). Platform length is handled separately.
  func invalidReason(_ v: Video, _ ctx: inout TickContext) throws -> String? {
    if let c = ctx.invalid[v.id] { return c }
    var r: String?
    if v.missing { r = "File missing" } else if v.excluded { r = "Excluded" } else {
      r = try Validation.issues(video: v, store: store).first { $0.kind != .tooLong }?.message
    }
    ctx.invalid[v.id] = r
    return r
  }

  func renderPost(_ p: inout PlatformPost, _ renderer: RenderService) throws {
    let prior = p.state
    p.state = .rendering
    try store.save(p)
    stateLock.withLock { rendering = true }
    defer { stateLock.withLock { rendering = false } }
    do {
      let r = try renderer.ensureRender(videoId: p.videoId, versionNo: p.versionNo, platform: p.platform)
      // The row as it is now, render fields only: it may have moved, or gone, during the render.
      if var cur = try store.post(id: p.id), !cur.state.isTerminal {
        cur.renderId = r.id
        if cur.state == .rendering { cur.state = prior == .due ? .due : .rendered }  // a post already due stays due (the Calendar keeps it)
        try store.save(cur, note: "rendered \(r.id.prefix(8))")
        p = cur
      }
      try? store.heartbeat(.tick)
    } catch {
      if var cur = try store.post(id: p.id), !cur.state.isTerminal {
        if cur.state == .rendering { cur.state = prior == .rendering ? .planned : (prior == .rendered ? .planned : prior) }
        cur.renderId = nil
        try store.save(cur, note: "render failed: \(error)")
        p = cur
      }
      throw error
    }
  }

  /// Sends once per key (store.markNotified) through the Notifier. Returns true when delivered.
  @discardableResult
  func notify(_ n: AppNotification) -> Bool {
    guard (try? store.markNotified(n.key)) == true else { return false }
    notifier.deliver(n)
    try? store.logEvent("notify", "\(n.title) — \(n.body)", videoId: n.videoId, postId: n.postId)
    return true
  }
}
