import AppKit
import DJQCore
import Observation
import SwiftUI

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

/// One source of UI truth: loads from Store, refreshes on ChangeSignal + a 5 s timer, and runs every action.
///
/// Round-2 screen contract (fan-out leaves build on this; extend with `extension AppModel` in your own files):
/// - Lists: `scoreList`, `editList`, `queueList`, `libraryAll` + per-video caches `suggestionsByVideo`,
///   `issuesByVideo`, `needsTitleHelp` (all loaded off-main on every refresh).
/// - `dsClip(_:for:)` maps a Video to the DS card model (AppModel+Clips.swift).
/// - `viewMode(_:)` / `setViewMode(_:for:)`, `playback` / `setPlayback(_:)`, `requestProxies(_:)`
///   (AppModel+Playback.swift).
/// - Selection per screen: `selection`, `select(_:modifiers:ordered:screen:)`, `selectAll`, `clearSelection`
///   (AppModel+Selection.swift).
/// - Bulk: `requestBulk(_:)` (confirmation sheet + undo toast), `undoLast()`, `copyAgentPrompt(_:)`
///   (AppModel+Bulk.swift).
/// - Toasts: `show(_:error:)` or `show(_: DSToastModel)`.
@MainActor
@Observable
final class AppModel {
  let store: Store
  let queue: Queue
  let planner: Planner
  let postActions: PostActions
  let renderer: Renderer
  let publisher: ManualPublisher
  /// Postiz key, check and draft release (fake in snapshots and `DJQ_FAKE_POSTIZ=1` dev runs).
  let postizBridge: PostizBridge
  /// What the app shows about Postiz (connection, channels, the job behind each post).
  var postiz = PostizUI()
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
  /// Planned clips per week start (⌘K week rows).
  var weekClips: [String: Int] = [:]
  /// ⌘K: clips, posts, weeks, sessions, settings and Health, folded off the main actor in `load`.
  var searchIndex = SearchIndex()
  /// Moves when `searchIndex` does: results on screen are worked out again.
  var searchGeneration = 0
  var posts: [PlatformPost] = []
  var postsByVideo: [String: [PlatformPost]] = [:]
  var postsBySlot: [String: [PlatformPost]] = [:]
  /// Posts by id (a palette row looks its post up on every keystroke).
  var postById: [String: PlatformPost] = [:]
  var problems: [PlatformPost] = []
  var dueToday: [PlatformPost] = []
  var runway = Runway(approvedDays: 0, readyDays: 0, totalDays: 0)
  var lastHeartbeat: Heartbeat?
  var versionCounts: [String: Int] = [:]
  var relinked: Set<String> = []
  var keptRemoved: Set<String> = []
  var renderQueue = 0
  var activeRenders: [Render] = []
  var now = Date()
  var loadError: String?
  var doctorReport: DoctorReport?
  var doctorRunning = false
  /// Queue screen: upcoming planned clips in date order, then the ready unplanned backlog (`ordered`).
  var queueList: [Video] = []
  /// Title suggestions per short clip, best first (metadata only — never generated in the app).
  var suggestionsByVideo: [String: [TitleSuggestion]] = [:]
  /// Needs-edit clips with a chosen cover frame (Edit's "Cover" badge).
  var coverIds: Set<String> = []
  /// Caption templates and hashtag sets (Edit's bulk/context menus).
  var captionTemplates: [CaptionTemplate] = []
  var hashtagSets: [HashtagSet] = []
  /// What keeps a clip from being ready / postable (Validation.issues) for every clip in `editList` and `queueList`.
  var issuesByVideo: [String: [ValidationIssue]] = [:]
  /// Short clips with no title and no confident suggestion (AgentPrompts.needsTitleHelp) → "Ask an agent".
  var needsTitleHelp: Set<String> = []
  private var prepared: [String: PreparedPost] = [:]
  private var preparedStamp: [String: String] = [:]
  private var refreshing = false
  private var refreshAgain = false
  var lastRefresh = Date.distantPast
  /// The Calendar's loaded range, indexed by day (`CalendarData`, loaded off-main with every refresh).
  var calendarData = CalendarData()
  /// Queue clips with no day that can still get one (`Planner.schedulable`), in Queue order.
  var schedulable: [Video] = []
  var popoverVisible = false
  /// False until the first background load lands (skeleton rows).
  var loaded = false
  /// renderId → 0…1 from Renderer.onProgress (this process's engine only).
  var renderProgress: [String: Double] = [:]
  var markPostedDraftURL: String?
  var offerLaunchAgent = false
  /// ⌘K "Set score…" sheet (CommandPalette.swift).
  var scorePrompt: Video?
  /// Last LaunchAgent install failure, shown in Settings → Engine.
  var agentError: String?
  /// ⌘K "Pin to date…" sheet (CommandPalette.swift).
  var pinPrompt: Video?

  // MARK: UI state
  var screen: Screen = .score
  var postsSelection: String? = nil
  /// Post the Posts list scrolls to once it's on screen (⌘K; consumed once).
  var postsScrollTarget: String? = nil
  var postsFilter: PostsFilter = .all
  /// Calendar view (remembered through `setCalendarMode`, default Week).
  var calendarMode: CalendarViewMode = .week { didSet { if oldValue != calendarMode { calendarViewChanged() } } }
  /// The day the Calendar is anchored on; "" = today, following the clock.
  var calendarAnchor = "" { didSet { if oldValue != calendarAnchor { calendarViewChanged() } } }
  /// Platform filter (remembered through `setCalendarPlatform`); read `calendarFilter`.
  var calendarPlatform: Platform?
  /// "Move to…" from a Calendar menu: the clips the pin dialog is open for.
  var calendarPinTarget: [String]?
  var editor: EditorRequest? {
    didSet { if editor == nil, let old = oldValue { editorDidClose(old) } }
  }
  /// The open editor session's journal entry: every clip it can reach is snapshotted at open, and the whole session
  /// becomes ONE app-level undo ("Edits to <clip>") when the editor closes (F8; in-editor ⌘Z is field-level).
  var editorSession: BulkActions.OpenEntry?
  /// Batches split off the open editor's session: its unsaved view of the clip sits on top of them.
  var openEditorBatches: Set<String> = []
  /// Undos run one at a time, in the order asked (rapid ⌘Z⌘Z).
  @ObservationIgnored lazy var undoRunner = UndoRunner(bulk: bulk)
  var showPalette = false
  /// In-window Settings modal (DESIGN-v2 §6.9), opened by the sidebar row, ⌘, and `WindowManager.showSettings`.
  var showSettings = false {
    // ⌘, while the palette is open: Settings opens under it and takes keyboard focus, so the palette goes.
    didSet { if showSettings, !oldValue, showPalette { closePalette() } }
  }
  /// Section the Settings modal shows (the Settings leaf owns the `SettingsSection` enum).
  var settingsSection: SettingsSection = .general
  /// Sidebar collapsed to icons by the user (it also collapses automatically under 1200 pt).
  var sidebarCollapsed = false
  var showShortcuts = false
  var showInspector = true
  var libraryGrid = false
  /// Quick-look sheet (Shared/ClipPreviewSheet.swift).
  var previewVideo: Video?
  var markPostedTarget: PlatformPost?
  var reportTarget: PlatformPost?
  var longformTarget: Video?
  var confirmPause = false
  /// The one toast (`.dsToast`). Set through `show(_:)`.
  var toast: DSToastModel?
  var highlightPostId: String?
  var dismissedWarnings: [String: Date] = [:]
  var recentCommands: [String] = []
  /// Snapshot mode freezes `now` and skips timers.
  var frozen = false

  // MARK: Round-2 contract state (see the extensions in App/)

  /// Remembered view mode per screen (UserDefaults `djq.viewMode.<screen>`). Read with `viewMode(_:)`.
  var viewModes: [Screen: DSViewMode] = [:]
  /// Autoplay preferences (UserDefaults `djq.playback`). Change ONLY with `setPlayback(_:)` / `playbackBinding`
  /// (they persist and drop stale proxy URLs).
  var playback = PlaybackPrefs()
  /// The one background proxy generator (stopped on quit).
  let proxies: ProxyService
  /// Proxy file per clip id for the current `playback.loop` range (filled by `requestProxies`).
  var proxyURLs: [String: URL] = [:]
  @ObservationIgnored var proxyPending: Set<String> = []
  /// Decoded covers by ThumbCache key (filled by `requestPoster`).
  var posters: [String: NSImage] = [:]
  @ObservationIgnored var posterPending: Set<String> = []

  // MARK: Previews (round 4 S6 — AppModel+Previews.swift)

  /// Edit/version times + defaults generation from the last refresh; `previewStamp` reads it.
  var previewTable = PreviewStampTable()
  /// All-versions stamp per clip (change detection in `apply`).
  @ObservationIgnored var previewAllStamps: [String: String] = [:]
  /// When the stamps were last set from the database (an older background load doesn't roll them back).
  @ObservationIgnored var previewStampsAt = Date.distantPast
  /// Clips whose edit changed and whose new proxy is still being made ("Updating preview").
  var previewUpdating: Set<String> = []
  /// Overlay timing per "id|vN" (with the stamp it was resolved at).
  var previewInfo: [String: PreviewInfo] = [:]
  @ObservationIgnored var previewInfoPending: Set<String> = []
  /// Post id → `posters` key of its current render's cover.
  var renderCoverKeys: [String: String] = [:]
  /// Clips recently shown / recently played (bounded): `previewChanged` re-requests these.
  @ObservationIgnored var recentPreviewIds: [String] = []
  @ObservationIgnored var recentProxyIds: [String] = []
  /// "id|generation" of clips whose landed proxy was stale and were asked for once more (no retry loops).
  @ObservationIgnored var proxyRetried: Set<String> = []
  /// When an evicted overlay was last reloaded, per overlay key (no reload storms when many are on screen).
  @ObservationIgnored var overlayReloadedAt: [String: Date] = [:]
  /// Selected clip ids per screen (#11). Use `select`, `toggleSelection`, `selectAll`, `clearSelection`.
  var selection: [Screen: Set<String>] = [:]
  /// Last plain/⌘-clicked id per screen (⇧-click range anchor).
  var selectionAnchor: [Screen: String] = [:]
  /// Ordered ids each screen currently shows (ClipCollection registers them; ⌘A selects these).
  var visibleIds: [Screen: [String]] = [:]
  /// Bulk actions with batch journal + undo (posts ChangeSignal itself).
  let bulk: BulkActions
  /// Bulk confirmation sheet currently shown (AppModel+Bulk.swift).
  var pendingBulk: PendingBulk?
  /// Clips the last bulk edit touched, per screen: they stay selected when a filter stops showing them.
  var bulkEdited: [Screen: Set<String>] = [:]
  /// The clips the Crop dialog is open for (nil = closed).
  var cropDialogIds: [String]?
  /// The clips the Caption dialog is open for (nil = closed).
  var captionDialogIds: [String]?
  /// Its Save as template form is open: Esc and a click outside go back to the dialog, so the picks survive.
  var captionDialogFormOpen = false

  func dismissCaptionDialog() {
    if captionDialogFormOpen { captionDialogFormOpen = false } else { captionDialogIds = nil }
  }
  /// ⌘Z order: every undoable action's journal batch, most recent last (UndoHistory, round 3 F8).
  var undoHistory = UndoHistory() {
    didSet {
      // A new action was journaled while the editor is open: the session starts after it (review r4 M1).
      if let s = editorSession, let top = undoHistory.top?.batchId, !oldValue.entries.contains(where: { $0.batchId == top }) {
        editorSession = (try? bulk.rebase(s, onto: top)) ?? s
      }
    }
  }
  /// The batch the next ⌘Z undoes. Setting pushes onto the history (label from `undoLabel`).
  var lastBatchId: String? {
    get { undoHistory.top?.batchId }
    set { if let b = newValue { undoHistory.push(b, label: "Change") } }
  }
  /// A destructive or plan-wide action waiting for "Are you sure?" (hosted by MainWindowView).
  var pendingConfirm: ConfirmRequest?

  /// True while rendering `--snapshot` (no UserDefaults reads/writes, no proxy generation).
  static let isSnapshotRun: Bool = { if case .snapshot = LaunchMode.current { return true } else { return false } }()

  init(store: Store) {
    self.store = store
    queue = Queue(store: store)
    planner = Planner(store: store)
    postActions = PostActions(store: store)
    renderer = Renderer(store: store)
    publisher = ManualPublisher(store: store, renderer: renderer)
    postizBridge = PostizBridge(store: store, keyStore: PostizEnvironment.keyStore(), transport: PostizEnvironment.transport(store))
    proxies = ProxyService(store: store)
    bulk = BulkActions(store: store)
    bulk.postsChangeSignal = true
    ThumbCache.shared.store = store
    if !Self.isSnapshotRun {
      if let d = UserDefaults.standard.dictionary(forKey: "djq.dismissedWarnings") as? [String: Date] { dismissedWarnings = d }
      recentCommands = UserDefaults.standard.stringArray(forKey: "djq.recentCommands") ?? []
      loadPersistedPrefs()
    }
    renderer.onProgress = { [weak self] id, f in
      Task { @MainActor in self?.renderProgress[id] = f < 1 ? f : nil }
    }
    // First load off-main; views show skeleton rows until it lands. Snapshot runs load synchronously themselves
    // (a late async load would land mid-shot).
    if !Self.isSnapshotRun { refresh() }
  }

  /// Progress of the render a post is waiting for (nil when not rendering here).
  func renderFraction(_ p: PlatformPost) -> Double? {
    guard p.state == .rendering else { return nil }
    let r: Render? = activeRenders.first { $0.videoId == p.videoId && $0.versionNo == p.versionNo }
    guard let r else { return nil }
    return renderProgress[r.id]
  }

  /// "Rendering 42% · 3 queued" for the menu bar and Health.
  var renderLine: String? {
    guard renderQueue > 0 else { return nil }
    let total = max(renderBatchTotal, renderQueue)
    let n = total - renderQueue + 1
    return "rendering \(n)/\(total)\(renderProgress.values.max().map { " · \(Int($0 * 100))%" } ?? "")"
  }

  /// Size of the current render batch (resets when the queue empties), for "rendering 2/7".
  private var renderBatchTotal = 0

  /// T.S4: Re-upload anyway on the same version, an existing later version, or a new one (opens the editor).
  func reupload(_ post: PlatformPost, version: Int?, newVersion: Bool = false) {
    if newVersion {
      var made = 0
      guard undoable("Re-upload as a new version", "reupload-new-version", ids: [post.videoId], plan: true, {
        let vs = try store.versions(videoId: post.videoId)
        var v = vs.last ?? Version(number: 1)
        v.number = (vs.map(\.number).max() ?? 0) + 1
        made = v.number
        try store.save(v, videoId: post.videoId)
        try postActions.resolveCopyright(postId: post.id, .reuploadAnyway(versionNo: made))
      }) else { return }
      show("Re-uploading as v\(made) — edit it now")
      openEditor(post.videoId)
    } else {
      undoable("Re-upload queued\(version.map { " (v\($0))" } ?? "")", "reupload", ids: [post.videoId], plan: true) {
        try postActions.resolveCopyright(postId: post.id, .reuploadAnyway(versionNo: version))
      }
    }
  }

  var dm: DayMath { DayMath(settings: settings) }
  var tz: TimeZone { settings.tz }
  var todayKey: String { dm.key(now) }

  // MARK: Refresh

  /// Everything the UI reads from the database, loaded off the main thread.
  struct Loaded: @unchecked Sendable {
    var settings = AppSettings()
    var sessions: [Session] = []
    var videos: [Video] = []
    var ordered: [Video] = []
    var toScore: [Video] = []
    var needsEdit: [Video] = []
    var upcomingSlots: [PlanSlot] = []
    var posts: [PlatformPost] = []
    var problems: [PlatformPost] = []
    var dueToday: [PlatformPost] = []
    var runway = Runway(approvedDays: 0, readyDays: 0, totalDays: 0)
    var lastHeartbeat: Heartbeat?
    var versionCounts: [String: Int] = [:]
    var relinked: Set<String> = []
    var keptRemoved: Set<String> = []
    var renderQueue = 0
    var activeRenders: [Render] = []
    var suggestions: [String: [TitleSuggestion]] = [:]
    var issues: [String: [ValidationIssue]] = [:]
    var needsTitleHelp: Set<String> = []
    var previewTable = PreviewStampTable()
    var previewStamps: [String: String] = [:]
    var previewAllStamps: [String: String] = [:]
    var startedAt = Date()
    var covers: Set<String> = []
    var captionTemplates: [CaptionTemplate] = []
    var hashtagSets: [HashtagSet] = []
    var calendar = CalendarData()
    var schedulable: [Video] = []
    var weekClips: [String: Int] = [:]
    var searchIndex = SearchIndex()
    var postiz = PostizLoaded()
    var error: String?
  }

  nonisolated static func load(store: Store, queue: Queue, postActions: PostActions, now: Date, calendar: CalendarRange,
                               awakeFrom: String?, postiz: PostizService, hasKey: Bool?) -> Loaded {
    var l = Loaded()
    l.startedAt = Date()
    do {
      l.settings = try store.settings()
      let dm = DayMath(settings: l.settings)
      l.sessions = try store.sessions()
      l.videos = try store.videos()
      l.ordered = try queue.ordered()
      l.toScore = try queue.toScore()
      l.needsEdit = try queue.needsEdit()
      l.upcomingSlots = try store.planSlots(where: "date>=?", [dm.key(now)])
      l.posts = try store.posts()
      // Newest problem first (the API orders by scheduled time).
      l.problems = try postActions.problems().sorted { $0.updatedAt > $1.updatedAt }
      l.dueToday = try postActions.dueToday(now: now)
      l.runway = try queue.runway()
      l.lastHeartbeat = try store.lastHeartbeat()
      l.versionCounts = Dictionary(uniqueKeysWithValues: try store.db.query("SELECT video_id, COUNT(*) AS n FROM versions GROUP BY video_id")
        .compactMap { r in r.string("video_id").map { ($0, r.int("n") ?? 0) } })
      l.relinked = Set(try store.db.query("SELECT DISTINCT video_id FROM events WHERE kind='relink' AND video_id IS NOT NULL")
        .compactMap { $0.string("video_id") })
      l.keptRemoved = Set((try store.kv("ui.keptRemoved", as: [String].self)) ?? [])
      l.renderQueue = try store.renders(where: "status IN ('pending','rendering') AND deleted_at IS NULL").count
      l.activeRenders = try store.renders(where: "status='rendering' AND deleted_at IS NULL")
      // Per-clip caches for the round-2 screens (suggestions for every active short; issues for Edit + Queue).
      for v in l.videos where v.type == .short && !v.excluded {
        let s = try store.titleSuggestions(videoId: v.id)
        if !s.isEmpty { l.suggestions[v.id] = s }
        if AgentPrompts.needsTitleHelp(v, suggestions: s) && !v.missing { l.needsTitleHelp.insert(v.id) }
      }
      let plannedIds = Set(l.upcomingSlots.map(\.videoId))
      for v in l.videos where v.type == .short && (plannedIds.contains(v.id) || l.needsEdit.contains { $0.id == v.id }
                                                   || l.ordered.contains { $0.id == v.id }) {
        l.issues[v.id] = (try? Validation.issues(video: v, store: store)) ?? []
      }
      // Edit's "Cover" badge and bulk menus (read here, off the main actor, not per refresh in the view).
      for v in l.needsEdit where (try? store.edit(videoId: v.id))?.coverTime != nil { l.covers.insert(v.id) }
      l.captionTemplates = try store.captionTemplates()
      l.hashtagSets = try store.hashtagSets()
      // ⌘K: read and folded here so a keystroke never touches the database.
      l.weekClips = Dictionary(uniqueKeysWithValues: try store.db.query("SELECT week_start, COUNT(DISTINCT video_id) AS n FROM plan_slots GROUP BY week_start")
        .compactMap { r in r.string("week_start").map { ($0, r.int("n") ?? 0) } })
      l.searchIndex = SearchCorpus.index(SearchInput(
        settings: l.settings, sessions: l.sessions, videos: l.videos, posts: l.posts, weekStates: [:], weekClips: l.weekClips,
        clipText: try store.searchClipText(videos: l.videos, settings: l.settings, sets: l.hashtagSets),
        hashtagSets: l.hashtagSets, captionTemplates: l.captionTemplates, now: now))
      // S6 preview stamps: edit + text versions + New-clip defaults + clip row, per clip.
      l.previewTable = try store.previewStampTable()
      for v in l.videos {
        l.previewStamps[v.id] = l.previewTable.stamp(for: v, version: 1)
        l.previewAllStamps[v.id] = l.previewTable.stamp(for: v, version: .max)
      }
      l.calendar = try CalendarData.load(store: store, posts: l.posts, range: calendar, awakeFrom: awakeFrom, dm: dm)
      l.schedulable = try Planner(store: store).schedulable(l.settings)
      l.postiz = try PostizLoaded.load(store: store, now: now, service: postiz, hasKey: hasKey, posts: l.posts)
    } catch {
      l.error = "\(error)"
    }
    return l
  }

  private func apply(_ l: Loaded) {
    if let e = l.error { loadError = e; return }
    settings = l.settings
    sessions = l.sessions
    sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    videos = l.videos
    videoById = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
    ordered = l.ordered
    suggestionsByVideo = l.suggestions
    issuesByVideo = l.issues
    needsTitleHelp = l.needsTitleHelp
    coverIds = l.covers
    captionTemplates = l.captionTemplates
    hashtagSets = l.hashtagSets
    weekClips = l.weekClips
    searchIndex = l.searchIndex
    searchGeneration &+= 1
    var seenPlanned = Set<String>()
    let planned = l.upcomingSlots.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
      .compactMap { s -> Video? in seenPlanned.insert(s.videoId).inserted ? videoById[s.videoId] : nil }
      .filter { $0.type == .short && !$0.excluded }
    queueList = planned + l.ordered.filter { !seenPlanned.contains($0.id) }
    toScore = l.toScore
    needsEdit = l.needsEdit
    pruneSelection()
    excluded = videos.filter { $0.excluded && $0.type == .short }
    upcomingSlots = l.upcomingSlots
    var next: [String: PlanSlot] = [:]
    for s in upcomingSlots where next[s.videoId] == nil { next[s.videoId] = s }
    nextSlotByVideo = next
    // Drop prepared files/captions whose post changed (new render, version, state, fix, edit).
    let byId = Dictionary(uniqueKeysWithValues: l.posts.map { ($0.id, $0) })
    for (id, stamp) in preparedStamp where byId[id].map(Self.prepStamp) != stamp {
      prepared[id] = nil
      preparedStamp[id] = nil
    }
    posts = l.posts
    postById = byId
    postsByVideo = Dictionary(grouping: posts, by: \.videoId)
    postsBySlot = Dictionary(grouping: posts.filter { $0.planSlotId != nil }, by: { $0.planSlotId! })
    problems = l.problems
    dueToday = l.dueToday
    runway = l.runway
    lastHeartbeat = l.lastHeartbeat
    versionCounts = l.versionCounts
    relinked = l.relinked
    keptRemoved = l.keptRemoved
    renderBatchTotal = l.renderQueue == 0 ? 0 : max(renderBatchTotal, l.renderQueue)
    renderQueue = l.renderQueue
    activeRenders = l.activeRenders
    renderProgress = renderProgress.filter { id, _ in l.activeRenders.contains { $0.id == id } }
    loaded = true
    calendarData = l.calendar
    schedulable = l.schedulable
    // Week start or today moved under the load: fetch again rather than wait for the timer.
    if !frozen && !(calendarData.range?.covers(calendarVisible) ?? false) { refresh() }
    postiz.apply(l.postiz)
    // A Postiz create DJ Queue couldn't confirm (Doctor postiz.create_unknown) needs Eric: it's a problem too.
    let unconfirmed = l.posts.filter { postiz.states[$0.id] == .unconfirmed && !problems.contains($0) }
    if !unconfirmed.isEmpty { problems = unconfirmed + problems }
    // The key's presence decides fallbacks on every screen: look it up once a platform uses Postiz.
    if postiz.hasKey == nil && !settings.publishing.postizPlatforms.isEmpty { loadPostizKey() }
    applyPreviewStamps(l)
    lastRefresh = Date()
    loadError = nil
  }

  /// S6: new stamps → `previewChanged` for every clip whose preview changed (djq/agent edits, bulk actions, Score
  /// quick edits, defaults changes all land here within one refresh). The first load only records them.
  private func applyPreviewStamps(_ l: Loaded) {
    guard l.startedAt >= previewStampsAt else { return }  // older than stamps set since (editor close)
    let first = previewAllStamps.isEmpty
    let changed = first ? [] : Set(l.previewAllStamps.compactMap { id, s in
      previewAllStamps[id].map { $0 == s ? nil : id } ?? nil
    })
    if previewTable != l.previewTable { previewTable = l.previewTable }
    previewAllStamps = l.previewAllStamps
    previewStampsAt = l.startedAt
    ThumbStamps.shared.update(l.previewStamps)
    previewChanged(changed)
  }

  /// Synchronous reload (launch, snapshot mode).
  func refreshNow() {
    if !frozen { now = store.clock.now }
    apply(Self.load(store: store, queue: queue, postActions: postActions, now: now, calendar: calendarVisible.padded(dm: dm),
                    awakeFrom: calendarAwakeFrom, postiz: postizBridge.service, hasKey: postiz.hasKey))
  }

  /// Coalesced background reload; the result is applied on the main actor.
  func refresh() {
    if frozen { refreshNow(); return }
    if refreshing { refreshAgain = true; return }
    refreshing = true
    now = store.clock.now
    let (s, q, pa, n, r, af) = (store, queue, postActions, now, calendarVisible.padded(dm: dm), calendarAwakeFrom)
    let (svc, key) = (postizBridge.service, postiz.hasKey)
    Task.detached(priority: .userInitiated) {
      let l = AppModel.load(store: s, queue: q, postActions: pa, now: n, calendar: r, awakeFrom: af, postiz: svc, hasKey: key)
      await MainActor.run {
        self.apply(l)
        self.refreshing = false
        if self.refreshAgain { self.refreshAgain = false; self.refresh() }
      }
    }
  }

  /// The Calendar moved: load what it now shows. Stepping within the padded range keeps the data on screen while this
  /// runs; a snapshot only reloads when it has to.
  private func calendarViewChanged() {
    if !frozen || !(calendarData.range?.covers(calendarVisible) ?? false) || calendarData.awakeFrom != calendarAwakeFrom { refresh() }
  }

  /// Timer entry: every 5 s while a window or the menu-bar popover is visible, otherwise every 30 s (menu-bar badge).
  func timerRefresh(visible: Bool) {
    if visible || Date().timeIntervalSince(lastRefresh) >= 30 { refresh() }
  }

  nonisolated static func prepStamp(_ p: PlatformPost) -> String {
    "\(p.renderId ?? "-")|\(p.versionNo)|\(p.state.rawValue)|\(p.updatedAt.timeIntervalSince1970)"
  }

  // MARK: Derived

  /// What every screen shows for a clip: `Video.displayName` (Title, else the raw tag verbatim). Long-form parts
  /// without a Title read "Set · Part N" from the session name (data, not a guess).
  func displayName(_ v: Video) -> String {
    if v.type == .long && v.titleText == nil { return "\(Captions.setName(sessionName(v))) · Part \(v.part ?? 1)" }
    return v.displayName
  }

  func sessionName(_ v: Video) -> String { sessionById[v.sessionId]?.name ?? "" }
  func setName(_ v: Video) -> String { Captions.setName(sessionName(v)) }
  func video(_ id: String) -> Video? { videoById[id] }
  func versions(_ v: Video) -> Int { max(1, versionCounts[v.id] ?? 0) }

  var engineRunning: Bool {
    guard let h = lastHeartbeat else { return false }
    return h.kind != .stop && now.timeIntervalSince(h.at) < 180
  }

  // MARK: Screen lists (round 2)

  /// Score screen: short clips with no score (not excluded/missing), session order.
  var scoreList: [Video] { toScore }
  /// Edit screen: scored clips that aren't ready yet.
  var editList: [Video] { needsEdit }
  /// Library: every video in every state.
  var libraryAll: [Video] { videos }

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
    posts.filter { !$0.state.isTerminal && $0.scheduledAt > now && postizState($0)?.isHeld != true }.min { $0.scheduledAt < $1.scheduledAt }
  }

  /// Today's posts Postiz handles (held or done by it; the inbox and fallbacks are manual tasks), in time order.
  var postizToday: [PlatformPost] {
    dueTodayShown.filter { p in
      switch postizState(p) {
      case nil, .fellBack?, .inbox?: false
      default: dm.key(p.scheduledAt) == todayKey
      }
    }.sorted { $0.scheduledAt < $1.scheduledAt }
  }

  var postedTodayCount: Int { dueToday.filter { $0.state == .posted && dm.key($0.scheduledAt) == todayKey }.count }
  var todayTotal: Int { dueTodayShown.filter { dm.key($0.scheduledAt) == todayKey && $0.state != .skipped }.count }
  /// Manual tasks only: a post Postiz delivers is never "due" for Eric.
  var dueNow: [PlatformPost] {
    dueToday.filter { ($0.state == .due || $0.state == .overdue || ($0.state.isTerminal == false && $0.scheduledAt <= now)) && postizState($0)?.isHeld != true }
  }
  var dueBadge: Int { dueToday.filter { !$0.state.isTerminal && postizState($0)?.isHeld != true }.count }

  func runwayTint(_ days: Int, threshold: Int) -> Color {
    days >= threshold * 2 ? DS.Status.posted : (days >= threshold ? .orange : .red)
  }

  var problemSummary: (title: String, detail: String) {
    let n = problems.count
    let parts = problems.prefix(3).map { p in
      postizState(p) == .unconfirmed ? "\(p.platform.displayName) unconfirmed in Postiz" : "\(p.platform.displayName) \(p.state == .copyrightBlocked || p.state == .copyrightMuted ? "© \(p.state == .copyrightMuted ? "muted" : "blocked")" : p.state.displayName.lowercased())"
    }
    return ("\(n) post\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention", parts.joined(separator: " · ") + (n > 3 ? " · …" : ""))
  }

  func dismissWarning(_ id: String) {
    dismissedWarnings[id] = now
    if !Self.isSnapshotRun { UserDefaults.standard.set(dismissedWarnings, forKey: "djq.dismissedWarnings") }
  }

  // MARK: Action plumbing

  /// Runs a write, signals other processes, reloads. Errors (e.g. the engine refusing "Post now" because the
  /// platform already posted or a pinned video holds today's slot) show as a readable red toast.
  @discardableResult
  func perform(_ label: String? = nil, _ body: () throws -> Void) -> Bool {
    do {
      try body()
      ChangeSignal.post()
      refresh()
      if let label { show(label) }
      return true
    } catch {
      refresh()
      show(error.localizedDescription, error: true)
      return false
    }
  }

  /// Runs a data-changing action as one journaled, undoable step (BulkActions.record): the toast says `label` with
  /// Undo, and ⌘Z undoes it (always the most recent action). `ids` = clips it may touch; `plan` = it may change
  /// slots, weeks or posts; `settings` = it changes Settings. Nothing changed → plain `label` toast, no Undo.
  @discardableResult
  func undoable(_ label: String, _ action: String, ids: [String] = [], plan: Bool = false, settings: Bool = false,
                renders: Bool = false, hashtagGroups: Bool = false, _ body: () throws -> Void) -> Bool {
    journaled(label) {
      try bulk.record(action, ids: ids, plan: plan, settings: settings, renders: renders, hashtagGroups: hashtagGroups, body)
    }
  }

  /// `undoable`'s steps around any journaled write.
  @discardableResult
  func journaled(_ label: String, _ write: () throws -> BulkResult) -> Bool {
    splitEditorSession()
    do {
      didJournal(try write(), label: label)
      return true
    } catch {
      refresh()
      show(error.localizedDescription, error: true)
      return false
    }
  }

  /// A journaled write landed: into the history (which moves an open editor session past it), with Undo on the toast.
  func didJournal(_ r: BulkResult, label: String) {
    ChangeSignal.post()
    refresh()
    if let b = r.batchId {
      undoHistory.push(b, label: label)
      show(DSToastModel(message: label, tone: .neutral, actionTitle: "Undo", action: { [weak self] in self?.undo(batch: b) },
                        duration: 6))
    } else {
      show(label)
    }
  }

  /// A group edit made by the editor, which wrote it itself so it could see which clips were frozen.
  func groupEdited(_ r: BulkResult, message: String) { didJournal(r, label: message) }

  /// Asks before a destructive or plan-wide action (in-window dialog; Cancel is the default).
  func confirm(_ r: ConfirmRequest) { pendingConfirm = r }

  /// An in-window overlay is over the editor: ⌘Z is the app's, not the hidden clip's.
  var overlayCoversEditor: Bool {
    editor != nil && (showSettings || showPalette || showShortcuts || pendingConfirm != nil || pendingBulk != nil || captionDialogIds != nil || cropDialogIds != nil || previewVideo != nil)
  }

  /// Deletes a hashtag group after asking (Settings and the editor), through the core path: clips with scheduled or posted
  /// posts keep their tags. Undoable: the group, its place in the default groups and those clips come back.
  func confirmDeleteGroup(_ s: HashtagSet, undoHint: String, then done: @escaping () -> Void = {}) {
    let reach = (try? HashtagGroups.impact(of: s.id, store: store))?.deleteSummary ?? "Clips with scheduled or posted posts keep these tags."
    let name = HashtagGroups.label(s)
    let holds = s.tags.isEmpty ? "“\(name)” has no hashtags." : "“\(name)” holds \(s.tags.joined(separator: " "))."
    confirm(ConfirmRequest(
      title: "Delete “\(name)”?",
      message: "\(holds) \(reach) \(undoHint)",
      verb: "Delete group", icon: "trash", destructive: true) { [self] in
        if journaled("Hashtag group “\(name)” deleted", { try HashtagGroups.delete(s, store: store, bulk: bulk).result }) {
          done()
        }
      })
  }

  /// Saves a group edited in Settings through the core path. A cleared name keeps the stored one, so clearing it and
  /// changing nothing else saves nothing; a group deleted while the save waited stays deleted.
  func saveGroupEdit(_ s: HashtagSet) {
    guard let old = (try? store.hashtagSets())?.first(where: { $0.id == s.id }) else { return }
    let group = HashtagGroups.keepingName(s, old: old)
    guard group != old else { return }
    journaled("Hashtag group “\(HashtagGroups.label(group))” saved") { try HashtagGroups.update(group, store: store, bulk: bulk).result }
  }

  /// Deletes a caption template after asking (Settings and the editor), through the core path: clips with scheduled or posted
  /// posts keep their captions, others that chose it go back to the default. Undoable.
  func confirmDeleteTemplate(_ t: CaptionTemplate, undoHint: String, then done: @escaping () -> Void = {}) {
    if let why = CaptionTemplates.blocker(of: t.id, settings: settings) { return show(why, error: true) }
    let reach = (try? CaptionTemplates.impact(of: t.id, store: store))?.templateDeleteSummary ?? "Clips with scheduled or posted posts keep their captions."
    confirm(ConfirmRequest(
      title: "Delete “\(t.name)”?", message: "\(reach) \(undoHint)", verb: "Delete template", icon: "trash", destructive: true) { [self] in
        if held("Template “\(t.name)” deleted", { try CaptionTemplates.delete(t, store: store, bulk: bulk) }) {
          done()
        }
      })
  }

  /// Saves a caption template edited in Settings through the core path. A blank name or text waits for more typing; a name
  /// another template has isn't saved, and says so.
  func saveTemplateEdit(_ t: CaptionTemplate) {
    guard let all = try? store.captionTemplates(), let old = all.first(where: { $0.id == t.id }), old != t else { return }
    switch CaptionTemplates.problem(name: t.name, template: t.template, existing: all, editing: t.id) {
    case .duplicateName(let n)?: show("A template called “\(n)” already exists", error: true)
    case .noName?, .noText?: break
    case nil: held("Template “\(t.name)” saved") { try CaptionTemplates.update(t, store: store, bulk: bulk) }
    }
  }

  /// Adds a caption template from Settings through the core path, journaled.
  func addTemplate(_ t: CaptionTemplate) -> Bool {
    journaled("Template “\(t.name)” added") { try CaptionTemplates.create(t, store: store, bulk: bulk).result }
  }

  /// A journaled write that can hold clips with posts: `journaled`, and the toast says how many.
  @discardableResult
  func held(_ label: String, _ write: () throws -> HashtagGroups.Change) -> Bool {
    splitEditorSession()
    do {
      let change = try write()
      didJournal(change.result, label: label + change.keptNote)
      return true
    } catch {
      refresh()
      show(error.localizedDescription, error: true)
      return false
    }
  }

  /// Saves New clip defaults (Save and Reset) through the core path.
  func saveDefaults(_ defaults: NewClipDefaults, label: String) -> Bool {
    held(label) { try CaptionTemplates.saveDefaults(defaults, store: store, bulk: bulk) }
  }

  /// Saves a platform's hashtag cap from Settings through the core path.
  func saveHashtagCap(_ cap: Int?, for p: Platform) {
    guard (try? store.settings())?.limits[p]?.maxHashtags != cap else { return }
    held(cap.map { "\(p.displayName) keeps \($0) hashtag\($0 == 1 ? "" : "s")" } ?? "\(p.displayName) has no hashtag cap") {
      try CaptionTemplates.setHashtagCap(cap, for: p, store: store, bulk: bulk)
    }
  }

  func moveGroup(_ s: HashtagSet, by: Int) -> Bool {
    held("Hashtag group “\(HashtagGroups.label(s))” moved") { try HashtagGroups.move(s.id, by: by, store: store, bulk: bulk) }
  }

  /// Saves the link line from Settings through the core path.
  func saveCaptionLink(_ link: String) {
    guard (try? store.settings())?.captionLink != link else { return }
    held("Link line saved") { try CaptionTemplates.setLink(link, store: store, bulk: bulk) }
  }

  /// Saves a group added in Settings, the first time Eric changes it.
  func saveNewGroup(_ s: HashtagSet) -> Bool {
    journaled("Hashtag group “\(s.name)” saved") { try HashtagGroups.create(s, store: store, bulk: bulk).result }
  }

  /// One-line toast. Errors use the danger tone and stay 6 s (others 3 s); snapshot mode keeps it on screen.
  func show(_ text: String, error: Bool = false) {
    show(DSToastModel(message: text, tone: error ? .danger : .neutral, duration: error ? 6 : 3))
  }

  /// Any toast (e.g. with an Undo action). `.dsToast` in MainWindowView hosts it and auto-dismisses it.
  func show(_ t: DSToastModel) {
    var t = t
    if frozen { t.duration = nil }
    toast = t
  }

  func noteCommand(_ id: String) {
    recentCommands.removeAll { $0 == id }
    recentCommands.insert(id, at: 0)
    recentCommands = Array(recentCommands.prefix(5))
    if !Self.isSnapshotRun { UserDefaults.standard.set(recentCommands, forKey: "djq.recentCommands") }
  }

  // MARK: Digit scoring (Queue + Library)

  private var digitBuffer = ""
  private var digitTargets: [String] = []
  private var digitCommit: DispatchWorkItem?

  /// Digits typed on selected rows set the score once: "7" waits briefly for a second digit, "72" commits at once,
  /// "10" waits for a possible "100". One write per typed number.
  func typeDigit(_ c: String, ids: Set<String>) {
    guard !ids.isEmpty, c.count == 1, c.first!.isNumber else { return }
    digitCommit?.cancel()
    if Array(ids) != digitTargets { digitBuffer = "" }
    digitTargets = Array(ids)
    digitBuffer += c
    let done = digitBuffer.count >= 3 || (digitBuffer.count == 2 && digitBuffer != "10")
    show("Score \(digitBuffer)\(done ? "" : "…")")
    let commit = DispatchWorkItem { [weak self] in
      guard let self, let n = Int(self.digitBuffer), n <= 100 else { self?.digitBuffer = ""; return }
      self.digitBuffer = ""
      self.setScore(self.digitTargets, n)
    }
    digitCommit = commit
    if done { commit.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: commit) }
  }

  // MARK: Video actions

  func setScore(_ ids: some Collection<String>, _ score: Int?) {
    let label = score.map { "Score \(min(100, max(0, $0)))" } ?? "Score cleared"
    undoable(ids.count > 1 ? "\(label) for \(ids.count) clips" : label, "score", ids: Array(ids)) {
      for id in ids { try store.setScore(id, score.map { min(100, max(0, $0)) }) }
    }
  }

  func setKind(_ ids: some Collection<String>, _ kind: Kind) {
    undoable("Kind set to \(kind.displayName)\(ids.count > 1 ? " for \(ids.count) clips" : "")", "kind", ids: Array(ids)) {
      for id in ids { try store.setKind(id, kind) }
    }
  }

  func setExcluded(_ ids: some Collection<String>, _ ex: Bool) {
    let n = ids.count == 1 ? "" : " \(ids.count) clips"
    undoable(ex ? "Excluded\(n)" : "Included\(n)", ex ? "exclude" : "include", ids: Array(ids), plan: true) {
      for id in ids { try store.setExcluded(id, ex) }
    }
  }

  func setNotes(_ id: String, _ notes: String) { perform { try store.setNotes(id, notes) } }

  func keepRemoved(_ id: String) {
    perform("Kept") {
      var k = keptRemoved
      k.insert(id)
      try store.setKV("ui.keptRemoved", Array(k).sorted())
    }
  }

  func pin(_ videoId: String, date: Date) { pin(videoId, dayKey: dm.key(date)) }
  func pin(_ videoId: String, dayKey: String) { pinAsking(videoId, to: dayKey, done: "Pinned") }
  func skipNext(_ videoId: String) {
    undoable("Swapped with the next open slot", "skip-next", ids: [videoId], plan: true) { try planner.skipNext(videoId: videoId) }
  }
  func swap(_ a: String, _ b: String) { undoable("Swapped days", "swap", plan: true) { try planner.swap(a, b) } }

  /// The upcoming planned slot before/after this video's next slot (Move up / down in ⌘K).
  func neighbourSlot(_ videoId: String, _ d: Int) -> PlanSlot? {
    guard let s = nextSlotByVideo[videoId], let i = upcomingSlots.firstIndex(where: { $0.id == s.id }) else { return nil }
    let j = i + d
    return upcomingSlots.indices.contains(j) ? upcomingSlots[j] : nil
  }

  /// Planned videos move by swapping days with the neighbouring slot (Planner.swap).
  func moveVideo(_ videoId: String, by d: Int) {
    guard let s = nextSlotByVideo[videoId], let n = neighbourSlot(videoId, d) else { return }
    swap(s.id, n.id)
  }

  func repost(_ videoId: String, _ p: Platform) {
    undoable("Repost queued on \(p.displayName)", "repost", ids: [videoId], plan: true) { _ = try postActions.repost(videoId: videoId, platform: p) }
  }

  /// nil when a repost is possible; otherwise why not (the API needs the next version to exist).
  func repostBlocker(_ videoId: String, _ p: Platform) -> String? {
    if let why = heldReason(videoId) { return why }
    let used = (postsByVideo[videoId] ?? []).filter { $0.platform == p }
    guard let maxUsed = used.map(\.versionNo).max() else { return "Not posted on \(p.displayName) yet" }
    return (versionCounts[videoId] ?? 1) > maxUsed ? nil : "Add v\(maxUsed + 1) first (Duplicate version)"
  }

  func duplicateVersion(_ videoId: String) {
    undoable("New version added", "duplicate-version", ids: [videoId]) {
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
    undoable("\(post.platform.displayName) marked posted", "mark-posted", ids: [post.videoId], plan: true) {
      try postActions.markPosted(postId: post.id, url: url, at: at)
    }
  }

  func reportProblem(_ post: PlatformPost, type: ErrorType, message: String, raw: String?) {
    undoable("Problem recorded", "report-problem", ids: [post.videoId], plan: true) {
      try postActions.reportProblem(postId: post.id, type: type, message: message, raw: raw)
    }
  }

  func resolve(_ post: PlatformPost, _ r: CopyrightResolution) {
    undoable("Resolved", "resolve", ids: [post.videoId], plan: true) { try postActions.resolveCopyright(postId: post.id, r) }
  }
  func fixed(_ postId: String) {
    let vid = posts.first { $0.id == postId }?.videoId
    undoable("Re-queued for the next day", "fixed", ids: vid.map { [$0] } ?? [], plan: true) { _ = try postActions.fixed(postId: postId) }
  }
  func reset(_ post: PlatformPost) {
    undoable("\(post.platform.displayName) post reset", "reset-post", ids: [post.videoId], plan: true) { try postActions.reset(postId: post.id) }
  }
  func skip(_ post: PlatformPost) {
    if post.state.isCopyright { resolve(post, .skipPlatform); return }
    undoable("\(post.platform.displayName) skipped", "skip-post", ids: [post.videoId], plan: true) { try postActions.skip(postId: post.id) }
  }
  func postNow(_ post: PlatformPost) {
    let ok = undoable("\(post.platform.displayName) is due now", "post-now", ids: [post.videoId], plan: true) { try postActions.postNow(postId: post.id) }
    guard ok else { return }
    highlightPostId = post.id
    openCalendarDay()
  }

  func shiftPlan(_ post: PlatformPost) {
    undoable("Moved to the next free \(post.platform.displayName) slot", "shift-plan", ids: [post.videoId], plan: true) {
      try postActions.shiftPlan(postId: post.id)
    }
  }

  /// `PostActions.heldReason` when the clip was sent back to Edit (nothing of it may post), else nil.
  func heldReason(_ videoId: String) -> String? { video(videoId)?.heldInEdit == true ? PostActions.heldReason : nil }

  /// What the real PostActions allow (skip refuses terminal posts; reset of a past post would make it miss again).
  func canSkip(_ p: PlatformPost) -> Bool { !p.state.isTerminal || (p.state.isCopyright && p.resolution == nil) }
  func canReset(_ p: PlatformPost) -> Bool {
    heldReason(p.videoId) == nil && p.scheduledAt > now && p.state != .planned && p.state != .rendering
  }
  func isResolved(_ p: PlatformPost) -> Bool { p.resolution != nil }
  func setMetrics(_ post: PlatformPost, views: Int?, likes: Int?) {
    undoable("Metrics saved", "metrics", ids: [post.videoId], plan: true) {
      try postActions.setMetrics(postId: post.id, PostMetrics(views: views, likes: likes, at: now))
    }
  }

  func markLongformPosted(_ v: Video, url: String) {
    perform("Long-form marked posted") { try postActions.markLongformPosted(videoId: v.id, url: url) }
  }

  // MARK: Settings

  /// Immediate settings change, undoable (toast `label` · Undo, ⌘Z).
  func update(_ label: String = "Setting saved", _ change: (inout AppSettings) -> Void) {
    var s = settings
    change(&s)
    guard s != settings else { return }
    undoable(label, "settings", settings: true) { try store.save(s) }
  }

  func setPaused(_ paused: Bool) { update(paused ? "Posting paused" : "Posting resumed") { $0.paused = paused } }
  func setPlatformPaused(_ p: Platform, _ paused: Bool) {
    update("\(p.displayName) \(paused ? "paused" : "resumed")") { if paused { $0.pausedPlatforms.insert(p) } else { $0.pausedPlatforms.remove(p) } }
  }

  // MARK: Manual publisher (Calendar → Day)

  /// A post whose render exists: the file can be dragged out without rendering on display.
  func isRenderable(_ p: PlatformPost) -> Bool {
    p.renderId != nil && !p.state.isTerminal && (p.state == .rendered || p.state == .due || p.state == .overdue)
  }

  func preparedPost(_ id: String) -> PreparedPost? { prepared[id] }

  /// Only for posts whose render already exists (no ffmpeg on display).
  func prepareIfRendered(_ post: PlatformPost) async {
    guard isRenderable(post), prepared[post.id] == nil else { return }
    _ = await prepare(post, quiet: true)
  }

  /// On demand (copy/reveal file): may render, always off the main thread.
  func prepare(_ post: PlatformPost, quiet: Bool = false) async -> PreparedPost? {
    if let p = prepared[post.id] { return p }
    if !quiet && !isRenderable(post) { show("Rendering \(post.platform.shortName)…") }
    let pub = publisher
    let id = post.id
    let result = await Task.detached { () -> Result<PreparedPost, Error> in
      do { return .success(try pub.prepare(postId: id)) } catch { return .failure(error) }
    }.value
    switch result {
    case .success(let p):
      prepared[id] = p
      preparedStamp[id] = Self.prepStamp(post)
      return p
    case .failure(let e):
      if !quiet { show(e.localizedDescription, error: true) }
      return nil
    }
  }

  /// Caption and title don't need a render.
  func captionAndTitle(_ post: PlatformPost) async -> (String, String?)? {
    if let p = prepared[post.id] { return (p.caption, p.title) }
    let s = store
    let r = await Task.detached { () -> Result<(String, String?), Error> in
      do {
        guard let v = try s.video(id: post.videoId) else { throw EditorlessError("Video not found") }
        let st = try s.settings()
        guard let rv = try s.resolvedVersion(videoId: v.id, number: post.versionNo, settings: st) else {
          throw EditorlessError("\(v.tag) has no v\(post.versionNo)")
        }
        let c = Captions.caption(for: post.platform, version: rv, video: v, sessionName: try s.session(id: v.sessionId)?.name ?? "",
                                 sets: try s.hashtagSets(), templates: try s.captionTemplates(), settings: st)
        let t = post.platform == .youtube ? Captions.youtubeTitle(rv, video: v, settings: st) : nil
        return .success((c, t))
      } catch { return .failure(error) }
    }.value
    switch r {
    case .success(let x): return x
    case .failure(let e): show(e.localizedDescription, error: true); return nil
    }
  }

  func copyCaption(_ post: PlatformPost) {
    Task { if let (c, _) = await captionAndTitle(post) { copy(c); show("\(post.platform.shortName) caption copied") } }
  }

  func copyTitle(_ post: PlatformPost) {
    Task { if let (_, t) = await captionAndTitle(post), let t { copy(t); show("Title copied") } }
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

  func openEditor(_ videoId: String, in ids: [String]? = nil, fixPostId: String? = nil, trimPlatform: Platform? = nil) {
    let all = ids ?? [videoId]
    if editorSession == nil { editorSession = try? bulk.begin("editor", ids: all.contains(videoId) ? all : [videoId] + all) }
    editor = EditorRequest(videoId: videoId, videoIds: all, fixPostId: fixPostId, trimPlatform: trimPlatform)
  }

  /// A journaled action (or an undo) is about to run while the editor is open: close the session so far as its own
  /// entry and start a new one, so the history reads Edits₁ → the action → Edits₂ and ⌘Z unwinds them in order
  /// (review r4 M1: folding the action into one session entry made its own undo skip the clip).
  func splitEditorSession() {
    guard let e = editorSession else { return }
    EditorModel.flushLiveAndWait()
    do {
      let (r, next) = try bulk.split(e)
      if let b = r.batchId {
        let name = r.changed.count == 1 ? video(r.changed[0]).map(displayName) ?? "1 clip" : "\(r.changed.count) clips"
        undoHistory.push(b, label: "Edits to \(name)")
        openEditorBatches.insert(b)
      }
      editorSession = next
    } catch {
      Log.shared.error("editor session split failed: \(error)")
    }
  }

  /// After the editor's last writes land: journal the session (nothing changed → no entry).
  private func finishEditorSession() {
    guard let e = editorSession else { return }
    editorSession = nil
    openEditorBatches = []
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      EditorModel.waitForSaves()
      do {
        let r = try self.bulk.commit(e)
        guard let b = r.batchId else { return }
        let name = r.changed.count == 1 ? self.video(r.changed[0]).map(self.displayName) ?? "1 clip" : "\(r.changed.count) clips"
        self.undoHistory.push(b, label: "Edits to \(name)")
        if self.toast == nil {
          self.show(DSToastModel(message: "Edits to \(name) saved", tone: .neutral, actionTitle: "Undo",
                                 action: { [weak self] in self?.undo(batch: b) }, duration: 6))
        }
      } catch {
        Log.shared.error("editor session journal failed: \(error)")
      }
    }
  }

  /// Done in the editor. Leaving any other way (sidebar, ⌘-number, ⌘K, a stage move) sets `editor = nil` directly;
  /// both run `editorDidClose`, so previews refresh the same way on every path (S6).
  func closeEditor() {
    let fix = editor?.fixPostId
    editor = nil
    if let fix { fixed(fix) }
  }

  /// Every editor exit: land the editor's pending saves, then re-stamp its clips so changed covers/proxies are
  /// dropped and re-requested at once (never an old crop or text), journal the session and reload.
  private func editorDidClose(_ old: EditorRequest) {
    if !frozen { EditorModel.flushLiveAndWait() }
    prepared = [:]
    preparedStamp = [:]
    refreshPreviewStamps(old.videoIds)
    finishEditorSession()
    refresh()
  }

  func reviewProblems() {
    postsFilter = .problems
    screen = .posts
  }

  /// Selected ids on the current screen, in display order (⌘K, ⌘E, context menus).
  var selectedVideoIds: [String] { selectedIds(screen) }


  // MARK: Engine + health

  /// Ticks the in-process engine; otherwise asks the owning process (its engine ticks on ChangeSignal).
  func runTick() {
    guard let engine, engineInProcess else {
      ChangeSignal.post()
      show("Asked the background engine to tick")
      return
    }
    show("Running engine tick…")
    let e = engine
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

struct EditorlessError: LocalizedError {
  let message: String
  init(_ m: String) { message = m }
  var errorDescription: String? { message }
}
