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
  public static let order = ["intake", "plan", "missed", "due", "platform", "alerts", "render", "proxies", "move", "heartbeat",
                              "backup"]
}

/// The background engine (spec §8). One `tick` does whatever is pending; it is safe to call at any time and never
/// overlaps another tick. The app runs it on a background queue via `start()`; the CLI calls `tick` once.
///
/// Tick order: intake → plan housekeeping → missed/overdue → due → platform checks → alerts → render-ahead →
/// move/cleanup → heartbeat → backup. Missed runs before due so a post that is about to be shifted never gets a
/// "due" notification first; rendering (slow) runs after every notification step so it never delays one, and at
/// most one new render happens per tick (due posts first). Every step catches its own errors into the report.
public final class Engine: @unchecked Sendable {
  public let store: Store
  let renderer: RenderService?
  let publisher: Publisher?
  let notifier: Notifier
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

  /// Called after every tick (on the engine queue when started).
  public var onTick: (@Sendable (TickReport) -> Void)?
  /// Gap between heartbeats that means the Mac was asleep or off.
  public static let sleepGap: TimeInterval = 180

  public init(store: Store, renderer: RenderService?, publisher: Publisher?, notifier: Notifier) {
    self.store = store
    self.renderer = renderer
    self.publisher = publisher
    self.notifier = notifier
    if renderer is Renderer {
      let ps = ProxyService(store: store)
      proxyService = ps
      ps.shouldPause = { [weak self] in self?.isRendering ?? false }
    }
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
    step("plan", &r) { try planHousekeeping() }
    step("missed", &r) { try missed() }
    step("due", &r) { try due() }
    step("platform", &r) { try platformChecks() }
    step("alerts", &r) { try alerts() }
    step("render", &r) { try renderAhead(&ctx) }
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

  /// Proposes the current and next week once (when they have never been proposed and the queue has videos).
  func planHousekeeping() throws -> String {
    let dm = try store.dayMath()
    let thisWeek = dm.weekStart(of: store.clock.now)
    var done: [String] = []
    for w in [thisWeek, dm.addDays(thisWeek, 7)] where try store.week(w) == nil {
      guard try !queue.ordered().isEmpty else { break }
      try planner.proposeWeek(w)
      done.append(w)
    }
    return done.isEmpty ? "ok" : "proposed \(done.joined(separator: ", "))"
  }

  /// A render that failed is retried only after this long, unless its edit/version (hash) changed.
  public static let renderRetryAfter: TimeInterval = 3600

  struct RenderFailure: Codable { var hash: String; var at: Date; var error: String }

  /// Approved posts within the horizon get their render; a changed edit/version re-renders. A failure is recorded
  /// (render row failed, notification once a day) and never stops the loop; that render backs off for an hour.
  func renderAhead(_ ctx: inout TickContext) throws -> String {
    guard let renderer else { return "no renderer" }
    let settings = try store.settings()
    let horizon = store.clock.now.addingTimeInterval(Double(settings.renderHorizonDays) * 86400)
    var attached = 0, rendered = 0, waiting = 0, failed = 0, backedOff = 0
    for var p in try store.posts(where: "state IN ('planned','rendering','rendered','due') AND scheduled_at<=?", [horizon]) {
      guard let v = try store.video(id: p.videoId) else { continue }
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
      let scope = try renderer.scope(videoId: p.videoId, platform: p.platform)
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
    let vids = try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND state IN ('needs_edit','ready','planned')")
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
    for c in try store.posts(where: "state IN ('planned','rendering','rendered','due') AND scheduled_at<?", [now]) {
      var outcome: (post: PlatformPost, days: Int)?
      try store.db.transaction {
        guard var p = try store.post(id: c.id), ["planned", "rendering", "rendered", "due"].contains(p.state.rawValue),
              !settings.pausedPlatforms.contains(p.platform), isOverdue(p, now: now, settings: settings, dm: dm) else { return }
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
        critical: false, actions: [.postNow, .shiftPlan, .skip], postId: p.id, videoId: p.videoId))
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
    for c in try store.posts(where: "state IN ('planned','rendering','rendered') AND scheduled_at<=?", [now]) {
      guard var p = try store.post(id: c.id), ["planned", "rendering", "rendered"].contains(p.state.rawValue),
            !settings.pausedPlatforms.contains(p.platform), !isOverdue(p, now: now, settings: settings, dm: dm) else { continue }
      guard let v = try store.video(id: p.videoId) else { continue }
      p.state = .due
      try store.save(p, note: "due")
      // TODO(phase 2, Postiz): a post that turns due before its render exists never reaches the publisher here
      // (render-ahead attaches the render later in this tick or the next). PostizPublisher must be submitted from
      // render-ahead too — or better, as soon as an approved post has its render — not only at due time.
      if let publisher, p.renderId != nil {
        if let prepared = try? publisher.prepare(postId: p.id) { _ = try? publisher.submit(prepared) }
      }
      try store.refreshState(videoId: p.videoId)
      let late = now.timeIntervalSince(p.scheduledAt)
      let when = late >= 30 * 60 ? Sched.lateText(late) : "due now"
      notify(AppNotification(
        key: "due:\(p.id):\(Int(p.scheduledAt.timeIntervalSince1970))", title: "\(p.platform.displayName) · \(v.tag) · \(when)",
        body: "Open Today to copy the caption and drag the file in.", actions: [.markPosted, .open], postId: p.id, videoId: v.id))
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
    func info(_ id: String) throws -> (Video, ResolvedEdit, [ValidationIssue])? {
      if let c = cache[id] { return c }
      guard let v = try store.video(id: id) else { return nil }
      let e = EditResolver.resolve(try store.edit(videoId: id), video: v, defaults: settings.defaults)
      let c = (v, e, Validation.platformIssues(video: v, resolved: e, settings: settings))
      cache[id] = c
      return c
    }
    for var p in try store.posts(where: "state IN ('planned','rendering','rendered','due','overdue')") {
      guard let (_, _, issues) = try info(p.videoId),
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
      guard let (_, edit, issues) = try info(p.videoId), active.contains(p.platform) else { continue }
      let newer = try store.posts(where: "video_id=? AND platform=? AND attempt_no>?", [p.videoId, p.platform.rawValue, p.attemptNo])
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

  /// Runway alerts, Sunday approval reminder, loud problem notifications.
  func alerts() throws -> String {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let now = store.clock.now
    let today = dm.key(now)
    let rw = try queue.runway()
    var sent: [String] = []
    if rw.approvedDays < settings.approvedRunwayAlertDays,
       notify(AppNotification(key: "alert.approve:\(today)", title: "Approve next week",
                              body: "Only \(rw.approvedDays) approved day\(rw.approvedDays == 1 ? "" : "s") left.", actions: [.open])) {
      sent.append("approve")
    }
    if rw.totalDays < settings.totalRunwayAlertDays,
       notify(AppNotification(key: "alert.record:\(dm.weekStart(of: now))", title: "Record a new set",
                              body: "About \(rw.totalDays) day\(rw.totalDays == 1 ? "" : "s") of videos left in total.", actions: [.open])) {
      sent.append("record")
    }
    let comps = dm.calendar.dateComponents([.weekday, .hour, .minute], from: now)
    let nextWeek = dm.addDays(dm.weekStart(of: now), 7)
    if comps.weekday == settings.approvalReminderWeekday,
       (comps.hour ?? 0) * 60 + (comps.minute ?? 0) >= settings.approvalReminderMinutes,
       try store.week(nextWeek)?.state != .approved,
       notify(AppNotification(key: "alert.weekly:\(nextWeek)", title: "Approve next week",
                              body: "The week of \(nextWeek) isn't approved yet.", actions: [.open])) {
      sent.append("weekly")
    }
    for p in try actions.problems() where p.state != .overdue {
      let tag = try store.video(id: p.videoId)?.tag ?? p.videoId
      let title = p.state.isCopyright ? "\(p.state.displayName) on \(p.platform.displayName)" : "Failed on \(p.platform.displayName)"
      if notify(AppNotification(key: "problem:\(p.id)", title: title,
                                body: "\(tag) — \(p.errorMessage ?? p.state.displayName)", critical: p.state.isCopyright,
                                actions: [.open], postId: p.id, videoId: p.videoId)) {
        sent.append("problem")
      }
    }
    _ = today
    return sent.isEmpty ? "none" : sent.joined(separator: ", ")
  }

  /// Renders whose posts are all terminal move to Posted/Shortform; renders nothing needs are deleted; optional
  /// cleanup of old posted renders (default keep forever, Q8). Render rows are only changed column-by-column.
  func moveAndCleanup() throws -> String {
    let settings = try store.settings()
    let fm = FileManager.default
    var moved = 0, deleted = 0, unneeded = 0
    for r in try store.renders(where: "deleted_at IS NULL AND status='done' AND output_path IS NOT NULL") {
      guard let out = r.outputPath, out.contains("/Ready to Post/Shortform/") else { continue }
      let users = try store.posts(where: "render_id=?", [r.id])
      guard !users.isEmpty, users.allSatisfy({ $0.state.isTerminal }) else { continue }
      let open = try store.posts(where: "video_id=? AND version_no=?", [r.videoId, r.versionNo]).filter { !$0.state.isTerminal }
      guard open.isEmpty else { continue }
      let newOut = try moveToPosted(out)
      var newCover = r.coverPath
      if let c = r.coverPath, c.contains("/Ready to Post/Shortform/") { newCover = try moveToPosted(c) }
      try store.setRenderOutput(id: r.id, outputPath: newOut, coverPath: newCover)
      try store.logEvent("move", "Moved \(URL(fileURLWithPath: out).lastPathComponent) → Posted/Shortform", videoId: r.videoId)
      moved += 1
    }
    if case .deleteAfter(let days) = settings.cleanup {
      let cutoff = store.clock.now.addingTimeInterval(-Double(days) * 86400)
      for r in try store.renders(where: "deleted_at IS NULL AND output_path LIKE '%/Posted/Shortform/%'") {
        let users = try store.posts(where: "render_id=?", [r.id])
        guard !users.isEmpty, users.allSatisfy({ $0.state.isTerminal }),
              (users.map { $0.postedAt ?? $0.updatedAt }.max() ?? .distantFuture) < cutoff else { continue }
        for path in [r.outputPath, r.coverPath].compactMap({ $0 }) where path.contains("/Posted/Shortform/") {
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
    return "moved \(moved)\(deleted > 0 ? " · deleted \(deleted)" : "")\(unneeded > 0 ? " · unneeded \(unneeded)" : "")"
  }

  /// Renders referenced by any live or posted post, current renders for approved posts within the horizon, renders
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
      p.renderId = r.id
      p.state = .rendered
      try store.save(p, note: "rendered \(r.id.prefix(8))")
      try? store.heartbeat(.tick)
    } catch {
      p.state = prior == .rendering ? .planned : (prior == .rendered ? .planned : prior)
      p.renderId = nil
      try store.save(p, note: "render failed: \(error)")
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
