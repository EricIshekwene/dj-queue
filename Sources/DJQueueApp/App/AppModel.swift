import AppKit
import DJQCore
import Observation
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
  case queue, week, today, library, posts, health
  var id: String { rawValue }

  var title: String {
    switch self {
    case .queue: "Queue"
    case .week: "Week"
    case .today: "Today"
    case .library: "Library"
    case .posts: "Posts"
    case .health: "Health"
    }
  }

  var symbol: String {
    switch self {
    case .queue: "list.number"
    case .week: "calendar"
    case .today: "checklist"
    case .library: "photo.on.rectangle.angled"
    case .posts: "paperplane"
    case .health: "stethoscope"
    }
  }

  var key: KeyEquivalent {
    switch self {
    case .queue: "1"
    case .week: "2"
    case .today: "3"
    case .library: "4"
    case .posts: "5"
    case .health: "6"
    }
  }
}

enum QueueTab: String, CaseIterable, Identifiable {
  case ready, toScore, needsEdit, excluded
  var id: String { rawValue }
  var title: String {
    switch self {
    case .ready: "Ready"
    case .toScore: "To score"
    case .needsEdit: "Needs edit"
    case .excluded: "Excluded"
    }
  }
}

enum PostsFilter: String, CaseIterable, Identifiable {
  case all, problems, posted, failed, copyright
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "All"
    case .problems: "Attention"
    case .posted: "Posted"
    case .failed: "Failed"
    case .copyright: "©"
    }
  }
}

struct EditorRequest: Equatable {
  var videoId: String
  var videoIds: [String]
  var fixPostId: String?
}

struct Toast: Equatable, Identifiable {
  let id = UUID()
  var text: String
  var isError = false
}

/// One source of UI truth: loads from Store, refreshes on ChangeSignal + a 5 s timer, and runs every action.
@MainActor
@Observable
final class AppModel {
  let store: Store
  let queue: Queue
  let planner: Planner
  let postActions: PostActions
  let renderer: Renderer
  let publisher: ManualPublisher
  var engine: Engine?
  /// False when another process already holds the engine lock.
  var engineInProcess = false

  // MARK: Data
  var settings = AppSettings()
  var sessions: [Session] = []
  var videos: [Video] = []
  var videoById: [String: Video] = [:]
  var sessionById: [String: Session] = [:]
  var ordered: [Video] = []
  var toScore: [Video] = []
  var needsEdit: [Video] = []
  var excluded: [Video] = []
  var upcomingSlots: [PlanSlot] = []
  var nextSlotByVideo: [String: PlanSlot] = [:]
  var weekStates: [String: WeekState] = [:]
  var posts: [PlatformPost] = []
  var postsByVideo: [String: [PlatformPost]] = [:]
  var postsBySlot: [String: [PlatformPost]] = [:]
  var problems: [PlatformPost] = []
  var dueToday: [PlatformPost] = []
  var runway = Runway(approvedDays: 0, readyDays: 0, totalDays: 0)
  var lastHeartbeat: Heartbeat?
  var versionCounts: [String: Int] = [:]
  var relinked: Set<String> = []
  var keptRemoved: Set<String> = []
  var renderQueue = 0
  var now = Date()
  var loadError: String?
  var doctorReport: DoctorReport?
  var doctorRunning = false
  var prefillRules = PrefillRules()
  private var prepared: [String: PreparedPost] = [:]

  // MARK: UI state
  var screen: Screen = .queue
  var queueTab: QueueTab = .ready
  var queueSelection: Set<String> = []
  var librarySelection: Set<String> = []
  var librarySession: String? = nil
  var postsSelection: String? = nil
  var postsFilter: PostsFilter = .all
  var weekStart: String = ""
  var editor: EditorRequest?
  var scoreMode = false
  var showPalette = false
  var showShortcuts = false
  var showInspector = true
  var weekBacklogExpanded = false
  var libraryGrid = false
  var previewVideo: Video?
  var markPostedTarget: PlatformPost?
  var reportTarget: PlatformPost?
  var longformTarget: Video?
  var confirmPause = false
  var toast: Toast?
  var highlightPostId: String?
  var dismissedWarnings: [String: Date] = [:]
  var recentCommands: [String] = []
  /// Snapshot mode freezes `now` and skips timers.
  var frozen = false

  init(store: Store) {
    self.store = store
    queue = Queue(store: store)
    planner = Planner(store: store)
    postActions = PostActions(store: store)
    renderer = Renderer(store: store)
    publisher = ManualPublisher(store: store, renderer: renderer)
    ThumbCache.shared.store = store
    if let d = UserDefaults.standard.dictionary(forKey: "djq.dismissedWarnings") as? [String: Date] { dismissedWarnings = d }
    recentCommands = UserDefaults.standard.stringArray(forKey: "djq.recentCommands") ?? []
    refresh()
    weekStart = planner.weekStart(for: now)
  }

  var dm: DayMath { DayMath(settings: settings) }
  var tz: TimeZone { settings.tz }
  var todayKey: String { dm.key(now) }

  // MARK: Refresh

  func refresh() {
    if !frozen { now = store.clock.now }
    do {
      settings = try store.settings()
      sessions = try store.sessions()
      sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
      videos = try store.videos()
      videoById = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
      ordered = try queue.ordered()
      toScore = try queue.toScore()
      needsEdit = try queue.needsEdit()
      excluded = videos.filter { $0.excluded && $0.type == .short }
      upcomingSlots = try store.planSlots(where: "date>=?", [todayKey])
      var next: [String: PlanSlot] = [:]
      for s in upcomingSlots where next[s.videoId] == nil { next[s.videoId] = s }
      nextSlotByVideo = next
      weekStates = Dictionary(uniqueKeysWithValues: try store.db.query("SELECT week_start, state FROM weeks").compactMap { r in
        r.string("week_start").map { ($0, WeekState(rawValue: r.string("state") ?? "") ?? .draft) }
      })
      posts = try store.posts()
      postsByVideo = Dictionary(grouping: posts, by: \.videoId)
      postsBySlot = Dictionary(grouping: posts.filter { $0.planSlotId != nil }, by: { $0.planSlotId! })
      problems = try postActions.problems()
      dueToday = try postActions.dueToday(now: now)
      runway = try queue.runway()
      lastHeartbeat = try store.lastHeartbeat()
      versionCounts = Dictionary(uniqueKeysWithValues: try store.db.query("SELECT video_id, COUNT(*) AS n FROM versions GROUP BY video_id")
        .compactMap { r in r.string("video_id").map { ($0, r.int("n") ?? 0) } })
      relinked = Set(try store.db.query("SELECT DISTINCT video_id FROM events WHERE kind='relink' AND video_id IS NOT NULL")
        .compactMap { $0.string("video_id") })
      keptRemoved = Set((try store.kv("ui.keptRemoved", as: [String].self)) ?? [])
      renderQueue = try store.renders(where: "status IN ('pending','rendering') AND deleted_at IS NULL").count
      prefillRules = PrefillRules.load(store.paths)
      loadError = nil
    } catch {
      loadError = "\(error)"
    }
  }

  // MARK: Derived

  func title(_ v: Video) -> String {
    if v.type == .long { return "\(Captions.setName(sessionName(v))) · Part \(v.part ?? 1)" }
    let t = Captions.oneLine(Prefill.text(tag: v.tag, kind: .djVid, rules: prefillRules))
    return t.isEmpty ? v.tag : t
  }

  func sessionName(_ v: Video) -> String { sessionById[v.sessionId]?.name ?? "" }
  func setName(_ v: Video) -> String { Captions.setName(sessionName(v)) }
  func video(_ id: String) -> Video? { videoById[id] }
  func versions(_ v: Video) -> Int { max(1, versionCounts[v.id] ?? 0) }

  var engineRunning: Bool {
    guard let h = lastHeartbeat else { return false }
    return h.kind != .stop && now.timeIntervalSince(h.at) < 180
  }

  var unscoredCount: Int { toScore.count }

  /// Latest attempt per platform for a video.
  func latestPosts(_ videoId: String) -> [Platform: PlatformPost] {
    Dictionary(grouping: postsByVideo[videoId] ?? [], by: \.platform).compactMapValues { $0.max { $0.attemptNo < $1.attemptNo } }
  }

  /// Q.S3.b: grey off / outline not planned / blue planned / green posted / red failed or ©.
  func dot(_ videoId: String, _ p: Platform) -> (tint: Color, filled: Bool, label: String) {
    if !settings.enabledPlatforms.contains(p) { return (Color.secondary.opacity(0.4), true, "Off") }
    guard let post = latestPosts(videoId)[p] else { return (Color.secondary, false, "Not planned") }
    return (post.state.tint, true, post.state.displayName)
  }

  func nextDateLabel(_ v: Video) -> String? {
    guard let s = nextSlotByVideo[v.id] else { return nil }
    if s.date == todayKey { return "Today" }
    if s.date == dm.addDays(todayKey, 1) { return "Tomorrow" }
    return Fmt.day(dm.date(s.date), tz: tz, style: "EEE d MMM")
  }

  var nextPost: PlatformPost? {
    posts.filter { !$0.state.isTerminal && $0.scheduledAt > now }.min { $0.scheduledAt < $1.scheduledAt }
  }

  var postedTodayCount: Int { dueToday.filter { $0.state == .posted && dm.key($0.scheduledAt) == todayKey }.count }
  var todayTotal: Int { dueToday.filter { dm.key($0.scheduledAt) == todayKey && $0.state != .skipped }.count }
  var dueNow: [PlatformPost] { dueToday.filter { $0.state == .due || $0.state == .overdue || ($0.state.isTerminal == false && $0.scheduledAt <= now) } }
  var dueBadge: Int { dueToday.filter { !$0.state.isTerminal }.count }

  func runwayTint(_ days: Int, threshold: Int) -> Color {
    days >= threshold * 2 ? DS.Status.posted : (days >= threshold ? .orange : .red)
  }

  var problemSummary: (title: String, detail: String) {
    let n = problems.count
    let parts = problems.prefix(3).map { p in
      "\(p.platform.displayName) \(p.state == .copyrightBlocked || p.state == .copyrightMuted ? "© \(p.state == .copyrightMuted ? "muted" : "blocked")" : p.state.displayName.lowercased())"
    }
    return ("\(n) post\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention", parts.joined(separator: " · ") + (n > 3 ? " · …" : ""))
  }

  struct Warning: Identifiable { let id: String; let text: String; let action: String?; let run: (() -> Void)? }

  var warnings: [Warning] {
    var w: [Warning] = []
    if !engineRunning {
      w.append(.init(id: "engine", text: "Engine not running — posts won't be prepared", action: engineInProcess ? nil : "Open Health",
                     run: { [weak self] in self?.screen = .health }))
    }
    if runway.approvedDays < settings.approvedRunwayAlertDays {
      w.append(.init(id: "approve", text: "Approved runway \(runway.approvedDays)d — approve next week", action: "Open Week",
                     run: { [weak self] in self?.goToNextWeek() }))
    }
    if runway.totalDays < settings.totalRunwayAlertDays {
      w.append(.init(id: "record", text: "Total runway \(runway.totalDays)d — record a new set", action: nil, run: nil))
    }
    return w.filter { d in dismissedWarnings[d.id].map { now.timeIntervalSince($0) > 86400 } ?? true }
  }

  func dismissWarning(_ id: String) {
    dismissedWarnings[id] = now
    UserDefaults.standard.set(dismissedWarnings, forKey: "djq.dismissedWarnings")
  }

  func goToNextWeek() {
    weekStart = dm.addDays(planner.weekStart(for: now), 7)
    screen = .week
  }

  // MARK: Action plumbing

  func perform(_ label: String? = nil, _ body: () throws -> Void) {
    do {
      try body()
      ChangeSignal.post()
      refresh()
      if let label { show(label) }
    } catch {
      refresh()
      show(error.localizedDescription, error: true)
    }
  }

  func show(_ text: String, error: Bool = false) {
    let t = Toast(text: text, isError: error)
    toast = t
    if frozen { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 4 : 2)) { [weak self] in
      if self?.toast?.id == t.id { self?.toast = nil }
    }
  }

  func noteCommand(_ id: String) {
    recentCommands.removeAll { $0 == id }
    recentCommands.insert(id, at: 0)
    recentCommands = Array(recentCommands.prefix(5))
    UserDefaults.standard.set(recentCommands, forKey: "djq.recentCommands")
  }

  // MARK: Video actions

  func setScore(_ ids: some Collection<String>, _ score: Int?) {
    perform(ids.count > 1 ? "Scored \(ids.count)" : nil) { for id in ids { try store.setScore(id, score.map { min(100, max(0, $0)) }) } }
  }

  func setKind(_ ids: some Collection<String>, _ kind: Kind) {
    perform { for id in ids { try store.setKind(id, kind) } }
  }

  func setExcluded(_ ids: some Collection<String>, _ ex: Bool) {
    perform(ex ? "Excluded \(ids.count)" : "Included \(ids.count)") { for id in ids { try store.setExcluded(id, ex) } }
  }

  func setNotes(_ id: String, _ notes: String) { perform { try store.setNotes(id, notes) } }

  func keepRemoved(_ id: String) {
    perform("Kept") {
      var k = keptRemoved
      k.insert(id)
      try store.setKV("ui.keptRemoved", Array(k).sorted())
    }
  }

  func pin(_ videoId: String, date: Date) {
    let key = dm.key(date)
    perform("Pinned to \(Fmt.day(dm.date(key), tz: tz))") { try planner.pin(videoId: videoId, date: key) }
  }

  func pin(_ videoId: String, dayKey: String) { perform("Pinned") { try planner.pin(videoId: videoId, date: dayKey) } }
  func postToday(_ videoId: String) { perform("Posting today") { try planner.postToday(videoId: videoId) } }
  func skipNext(_ videoId: String) { perform("Skipped next slot") { try planner.skipNext(videoId: videoId) } }
  func removeSlot(_ slotId: String) { perform("Removed from week") { try planner.remove(slotId: slotId) } }
  func swap(_ a: String, _ b: String) { perform("Swapped") { try planner.swap(a, b) } }
  func move(_ slotId: String, to day: String) { perform("Moved") { try planner.move(slotId: slotId, to: day) } }
  func approveWeek(_ ws: String) { perform("Week approved") { try planner.approveWeek(ws) } }
  func rebuildWeek(_ ws: String) { perform("Week rebuilt") { try planner.rebuildWeek(ws) } }
  func proposeWeek(_ ws: String) { perform("Week proposed") { _ = try planner.proposeWeek(ws) } }
  func pushPlan(days: Int = 1) { perform("Plan pushed by \(days) day") { try planner.pushPlan(from: todayKey, days: days) } }

  /// Q.S5 "Add to week": each video goes to the next open day from today.
  func addToWeek(_ ids: [String]) {
    perform("Added \(ids.count) to the plan") {
      var day = todayKey
      for id in ids {
        while try !store.planSlots(where: "date=?", [day]).isEmpty { day = dm.addDays(day, 1) }
        try planner.pin(videoId: id, date: day)
      }
    }
  }

  func repost(_ videoId: String, _ p: Platform) { perform("Repost queued on \(p.displayName)") { try postActions.repost(videoId: videoId, platform: p) } }

  func duplicateVersion(_ videoId: String) {
    perform("Version duplicated") {
      let vs = try store.versions(videoId: videoId)
      var v = vs.last ?? Version(number: 1)
      v.number = (vs.map(\.number).max() ?? 0) + 1
      try store.save(v, videoId: videoId)
    }
  }

  func reRender(_ videoId: String) {
    let r = renderer
    show("Rendering…")
    Task.detached {
      let msg: String
      do { _ = try r.ensureRender(videoId: videoId, versionNo: 1, platform: nil); msg = "Render ready" } catch { msg = error.localizedDescription }
      await MainActor.run { self.show(msg); self.refresh() }
    }
  }

  // MARK: Post actions

  func markPosted(_ post: PlatformPost, url: String, at: Date) {
    perform("Marked posted") { try postActions.markPosted(postId: post.id, url: url, at: at) }
  }

  func reportProblem(_ post: PlatformPost, type: ErrorType, message: String, raw: String?) {
    perform("Problem recorded") { try postActions.reportProblem(postId: post.id, type: type, message: message, raw: raw) }
  }

  func resolve(_ post: PlatformPost, _ r: CopyrightResolution) { perform("Resolved") { try postActions.resolveCopyright(postId: post.id, r) } }
  func fixed(_ postId: String) { perform("Re-queued for the next day") { try postActions.fixed(postId: postId) } }
  func reset(_ post: PlatformPost) { perform("Post reset") { try postActions.reset(postId: post.id) } }
  func skip(_ post: PlatformPost) { perform("\(post.platform.displayName) skipped") { try postActions.skip(postId: post.id) } }
  func setMetrics(_ post: PlatformPost, views: Int?, likes: Int?) {
    perform("Metrics saved") { try postActions.setMetrics(postId: post.id, PostMetrics(views: views, likes: likes, at: now)) }
  }

  func markLongformPosted(_ v: Video, url: String) {
    perform("Long-form marked posted") { try postActions.markLongformPosted(videoId: v.id, url: url) }
  }

  // MARK: Settings

  func update(_ change: (inout AppSettings) -> Void) {
    var s = settings
    change(&s)
    perform { try store.save(s) }
  }

  func setPaused(_ paused: Bool) { update { $0.paused = paused } }
  func setPlatformPaused(_ p: Platform, _ paused: Bool) {
    update { if paused { $0.pausedPlatforms.insert(p) } else { $0.pausedPlatforms.remove(p) } }
  }

  // MARK: Manual publisher (Today)

  func preparedPost(_ id: String) -> PreparedPost? { prepared[id] }

  func prepare(_ post: PlatformPost) async -> PreparedPost? {
    if let p = prepared[post.id] { return p }
    let pub = publisher
    let id = post.id
    let result = await Task.detached { () -> Result<PreparedPost, Error> in
      do { return .success(try pub.prepare(postId: id)) } catch { return .failure(error) }
    }.value
    switch result {
    case .success(let p): prepared[id] = p; return p
    case .failure(let e): show(e.localizedDescription, error: true); return nil
    }
  }

  func copyCaption(_ post: PlatformPost) {
    Task { if let p = await prepare(post) { copy(p.caption); show("\(post.platform.shortName) caption copied") } }
  }

  func copyTitle(_ post: PlatformPost) {
    Task { if let p = await prepare(post), let t = p.title { copy(t); show("Title copied") } }
  }

  func openUploadPage(_ post: PlatformPost) { NSWorkspace.shared.open(post.platform.uploadURL) }

  func revealFile(_ post: PlatformPost) {
    Task { if let p = await prepare(post) { NSWorkspace.shared.activateFileViewerSelecting([p.fileURL]) } }
  }

  func copyFile(_ post: PlatformPost) {
    Task {
      if let p = await prepare(post) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([p.fileURL as NSURL])
        show("File copied")
      }
    }
  }

  func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
  }

  // MARK: Navigation

  func openEditor(_ videoId: String, in ids: [String]? = nil, fixPostId: String? = nil) {
    editor = EditorRequest(videoId: videoId, videoIds: ids ?? [videoId], fixPostId: fixPostId)
  }

  func closeEditor() {
    let fix = editor?.fixPostId
    editor = nil
    if let fix { fixed(fix) } else { refresh() }
  }

  func reviewProblems() {
    postsFilter = .problems
    screen = .posts
  }

  var selectedVideoIds: [String] {
    switch screen {
    case .library: Array(librarySelection)
    default: Array(queueSelection)
    }
  }

  var focusedVideo: Video? { selectedVideoIds.count == 1 ? video(selectedVideoIds[0]) : nil }

  // MARK: Engine + health

  func runTick() {
    guard let engine else { show("Engine runs in another process", error: true); return }
    show("Running engine tick…")
    nonisolated(unsafe) let e = engine
    DispatchQueue.global().async {
      let r = e.tick(reason: "manual")
      DispatchQueue.main.async {
        self.refresh()
        self.show(r.errors.isEmpty ? "Tick done" : r.errors.joined(separator: "; "), error: !r.errors.isEmpty)
      }
    }
  }

  func runDoctor() {
    doctorRunning = true
    let s = store
    Task.detached {
      let r = Doctor(store: s).run()
      await MainActor.run {
        self.doctorReport = r
        self.doctorRunning = false
      }
    }
  }

  func copyDoctorReport() {
    if let r = doctorReport { copy(Doctor.markdown(r)); show("Report copied") }
  }

  func openLog() { NSWorkspace.shared.open(store.paths.engineLog) }
}
