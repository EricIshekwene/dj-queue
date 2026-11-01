import DJQCore
import Foundation

// djq — command-line access to the DJ Queue database (same SQLite file as the app; posts ChangeSignal after writes).
// Env: DJQ_ROOT (the "DJ Video" folder), DJQ_HOME (app support + logs) for dev copies and tests.

RenderServices.factory = { Renderer(store: $0) }

let usage = """
usage: djq <command> [args]

  status                              runway, today, problems, engine
  queue [--platform P]                ready backlog in posting order
  today                               today's posts
  posts [--problems]                  upcoming/recent posts (or unresolved problems)
  week [--propose|--approve|--rebuild] [YYYY-MM-DD]
  pin <video> <YYYY-MM-DD> | post-today <video> | skip-next <video> | push <YYYY-MM-DD> <days>
  remove-slot <slot> | swap <slot> <slot> | move <slot> <YYYY-MM-DD>
  posted <post> <url>                 mark posted (URL host must match the platform)
  problem <post> <type> <message>     type: \(ErrorType.allCases.map(\.rawValue).joined(separator: "|"))
  fixed <post> | reset <post> | skip <post> | post-now <post> | shift-plan <post>
  copyright <post> reupload [N]|skip|accept
  repost <video> <platform> | longform-posted <video> <url>
  score <video> <0-100|clear> | exclude <video> | include <video>
  pause [platform] | resume [platform]
  intake | tick [--force] | doctor [--json] | health [--days N]
  prefill "<tag>" [--kind talking]
  render <video> [--version N] [--platform P]
  agent install [--app PATH] [--load] [--force] | agent uninstall [--unload] | agent status

Ids can be shortened to a unique prefix. Platforms: \(Platform.allCases.map(\.rawValue).joined(separator: " "))
"""

struct CLIError: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}

final class PrintNotifier: Notifier, @unchecked Sendable {
  func deliver(_ n: AppNotification) { print("  notify  \(n.title) — \(n.body)") }
}

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
  if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
  return false
}
func option(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let v = args[i + 1]
  args.removeSubrange(i...(i + 1))
  return v
}
func arg(_ i: Int, _ what: String) throws -> String {
  guard i < args.count else { throw CLIError("missing \(what)\n\n\(usage)") }
  return args[i]
}

/// Strict YYYY-MM-DD (a real calendar day), else a readable error.
func dateArg(_ i: Int, _ what: String = "date (YYYY-MM-DD)") throws -> String {
  let raw = try arg(i, what)
  return try validDate(raw)
}
func validDate(_ raw: String) throws -> String {
  let bad = CLIError("\(raw) isn't a date — use YYYY-MM-DD, e.g. 2026-11-02")
  guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw bad }
  let p = raw.split(separator: "-").compactMap { Int($0) }
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "UTC")!
  guard (1...12).contains(p[1]), (1...31).contains(p[2]),
        let d = c.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
        c.component(.day, from: d) == p[2] else { throw bad }
  return raw
}
func intArg(_ raw: String, _ what: String, _ range: ClosedRange<Int>) throws -> Int {
  guard let n = Int(raw), range.contains(n) else { throw CLIError("\(what) must be a whole number \(range.lowerBound)–\(range.upperBound) (got \(raw))") }
  return n
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func short(_ id: String) -> String { String(id.prefix(8)) }

let iso: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  return f
}()
func fmt(_ d: Date, _ s: Settings, _ format: String = "EEE d MMM HH:mm") -> String {
  iso.timeZone = s.tz
  iso.dateFormat = format
  return iso.string(from: d)
}

func resolveVideo(_ store: Store, _ prefix: String) throws -> Video {
  let m = try store.videos(where: "id LIKE ?", [prefix + "%"])
  guard m.count == 1 else { throw CLIError(m.isEmpty ? "no video \(prefix)" : "\(prefix) matches \(m.count) videos — use more characters") }
  return m[0]
}
func resolvePost(_ store: Store, _ prefix: String) throws -> PlatformPost {
  let m = try store.posts(where: "id LIKE ?", [prefix + "%"])
  guard m.count == 1 else { throw CLIError(m.isEmpty ? "no post \(prefix)" : "\(prefix) matches \(m.count) posts — use more characters") }
  return m[0]
}
func resolveSlot(_ store: Store, _ prefix: String) throws -> PlanSlot {
  let m = try store.planSlots(where: "id LIKE ?", [prefix + "%"])
  guard m.count == 1 else { throw CLIError(m.isEmpty ? "no slot \(prefix)" : "\(prefix) matches \(m.count) slots") }
  return m[0]
}
func platform(_ s: String) throws -> Platform {
  let l = s.lowercased()
  if let p = Platform(rawValue: l) ?? Platform.allCases.first(where: { $0.displayName.lowercased() == l || $0.shortName.lowercased() == l }) {
    return p
  }
  throw CLIError("unknown platform \(s) (\(Platform.allCases.map(\.rawValue).joined(separator: " ")))")
}

func tagOf(_ store: Store, _ videoId: String) -> String { (try? store.video(id: videoId))?.tag ?? short(videoId) }

func printPosts(_ store: Store, _ posts: [PlatformPost], _ s: Settings) {
  if posts.isEmpty { print("  (none)"); return }
  for p in posts {
    var line = "  \(short(p.id))  \(fmt(p.scheduledAt, s))  \(pad(p.platform.displayName, 14)) \(pad(p.state.displayName, 10)) \(tagOf(store, p.videoId)) v\(p.versionNo)"
    if p.attemptNo > 1 || p.kind != .regular { line += "  [\(p.kind.rawValue) #\(p.attemptNo)]" }
    if let e = p.errorMessage, p.state.isProblem { line += "  — \(e)" }
    if let u = p.url { line += "  \(u)" }
    print(line)
  }
}

func printWeek(_ store: Store, _ week: String) throws {
  let planner = Planner(store: store)
  let s = try store.settings()
  let dm = DayMath(settings: s)
  let w = try planner.week(week)
  print("Week of \(week) · \(w.state.rawValue)\(w.approvedAt.map { " \(fmt($0, s))" } ?? "")")
  let slots = try planner.slots(week: week)
  for day in dm.weekDays(week) {
    let ds = slots.filter { $0.date == day }
    let label = fmt(dm.date(day), s, "EEE yyyy-MM-dd")
    if ds.isEmpty { print("  \(label)  —"); continue }
    for sl in ds {
      let v = try store.video(id: sl.videoId)
      let posts = try store.posts(where: "plan_slot_id=?", [sl.id])
      let states = posts.sorted { $0.platform < $1.platform }.map { p -> String in
        let other = p.videoId != sl.videoId ? "(\(tagOf(store, p.videoId)))" : ""
        return "\(p.platform.shortName) \(p.state.rawValue)\(other)"
      }.joined(separator: " · ")
      let score = v?.score.map { String($0) } ?? "–"
      print("  \(label)  \(short(sl.id))  \(pad((v?.tag ?? sl.videoId) + " (\(score))", 34))\(sl.pinned ? " pinned" : "")\(states.isEmpty ? "" : "  " + states)")
    }
  }
}

func run() throws -> Int32 {
  guard let cmd = args.first else { print(usage); return 0 }
  args.removeFirst()
  if ["help", "-h", "--help"].contains(cmd) { print(usage); return 0 }
  let paths = Paths.standard
  Log.shared.configure(paths)
  if cmd == "prefill" {
    let kindRaw = option("--kind")
    guard kindRaw == nil || Kind(rawValue: kindRaw!) != nil else { throw CLIError("--kind must be \"dj vid\" or talking") }
    let kind: Kind = kindRaw.flatMap { Kind(rawValue: $0) } ?? .djVid
    let tag = try arg(0, "tag")
    let rules = PrefillRules.load(paths)
    print(Prefill.text(tag: tag, kind: kind, rules: rules))
    print("\n(rules: \(paths.prefillRules.path))")
    return 0
  }
  let store = try Store(paths: paths)
  let settings = try store.settings()
  let dm = DayMath(settings: settings)
  let actions = PostActions(store: store)
  let planner = Planner(store: store)
  let queue = Queue(store: store)
  let writes: Set<String> = ["week", "pin", "post-today", "skip-next", "push", "remove-slot", "swap", "move", "posted", "problem",
                             "fixed", "reset", "skip", "post-now", "shift-plan", "copyright", "repost", "longform-posted",
                             "score", "exclude", "include", "pause", "resume", "intake", "tick", "render"]
  var wrote = writes.contains(cmd) && (cmd != "week" || args.contains { $0.hasPrefix("--") })
  defer { if wrote { ChangeSignal.post() } }

  switch cmd {
  case "status":
    let now = store.clock.now
    let rw = try queue.runway()
    let today = try actions.dueToday(now: now)
    let problems = try actions.problems()
    print("DJ Queue · \(fmt(now, settings, "EEE d MMM yyyy HH:mm")) (\(settings.timeZone))")
    print("Runway     approved \(rw.approvedDays) d · ready \(rw.readyDays) d · total \(rw.totalDays) d")
    print("Queue      \(try queue.ordered().count) ready · \(try queue.toScore().count) to score · \(try queue.needsEdit().count) need edit")
    let byState = Dictionary(grouping: today, by: \.state).map { "\($0.value.count) \($0.key.displayName.lowercased())" }.sorted()
    print("Today      \(today.count) post\(today.count == 1 ? "" : "s")\(byState.isEmpty ? "" : " (" + byState.joined(separator: ", ") + ")")")
    print("Problems   \(problems.count)")
    let hb = try store.lastHeartbeat()
    let paused = settings.paused ? "ALL" : (settings.pausedPlatforms.isEmpty ? "no" : settings.pausedPlatforms.map(\.displayName).sorted().joined(separator: ", "))
    print("Engine     \(hb.map { "last heartbeat \(Int(now.timeIntervalSince($0.at) / 60)) min ago" } ?? "never ran") · paused: \(paused)")
    print("Platforms  \(settings.activePlatforms.map { "\($0.shortName) \(fmt(dm.at(dm.key(now), minutes: settings.slot(for: $0)), settings, "HH:mm"))" }.joined(separator: " · "))")

  case "queue":
    let p = try option("--platform").map(platform)
    let list = try queue.ordered(platform: p)
    print("Queue\(p.map { " · \($0.displayName)" } ?? "") · \(settings.sortDirection(for: p).displayName) · ties: older session first")
    if list.isEmpty { print("  (empty — score videos and finish their edits)") }
    for (i, v) in list.enumerated() {
      print("  \(pad(String(i + 1), 3)) \(short(v.id))  \(pad(String(v.score ?? 0), 4))\(pad(v.tag, 36)) part \(v.part ?? 0) @ \(Int(v.start ?? 0))s")
    }
    let ts = try queue.toScore().count, ne = try queue.needsEdit().count
    print("  to score \(ts) · need edit \(ne)")

  case "today":
    print("Today · \(fmt(store.clock.now, settings, "EEE d MMM"))")
    printPosts(store, try actions.dueToday(now: store.clock.now), settings)

  case "posts":
    if flag("--problems") {
      print("Problems")
      printPosts(store, try actions.problems(), settings)
    } else {
      let since = dm.date(dm.addDays(dm.key(store.clock.now), -7))
      print("Posts (from 7 days ago)")
      printPosts(store, try store.posts(where: "scheduled_at>=?", [since]), settings)
    }

  case "week":
    let propose = flag("--propose"), approve = flag("--approve"), rebuild = flag("--rebuild")
    let week = try args.first.map { dm.weekStart(of: dm.date(try validDate($0))) } ?? dm.weekStart(of: store.clock.now)
    if propose { try planner.proposeWeek(week); wrote = true }
    if rebuild { try planner.rebuildWeek(week); wrote = true }
    if approve { try planner.approveWeek(week); wrote = true }
    try printWeek(store, week)

  case "pin":
    let v = try resolveVideo(store, try arg(0, "video id"))
    try planner.pin(videoId: v.id, date: try dateArg(1))
    wrote = true
    print("pinned \(v.tag) to \(args[1])")
  case "post-today":
    let v = try resolveVideo(store, try arg(0, "video id"))
    try planner.postToday(videoId: v.id)
    wrote = true
    print("\(v.tag) posts today; the rest of the plan moved a day")
  case "skip-next":
    let v = try resolveVideo(store, try arg(0, "video id"))
    try planner.skipNext(videoId: v.id)
    wrote = true
    print("skipped \(v.tag) once")
  case "push":
    let date = try dateArg(0)
    let n = try intArg(try arg(1, "days"), "days", 1...60)
    try planner.pushPlan(from: date, days: n)
    wrote = true
    print("pushed the plan from \(date) by \(n) day(s)")
  case "remove-slot":
    try planner.remove(slotId: try resolveSlot(store, try arg(0, "slot id")).id)
    wrote = true
    print("removed")
  case "swap":
    try planner.swap(try resolveSlot(store, try arg(0, "slot id")).id, try resolveSlot(store, try arg(1, "slot id")).id)
    wrote = true
    print("swapped")
  case "move":
    try planner.move(slotId: try resolveSlot(store, try arg(0, "slot id")).id, to: try dateArg(1))
    wrote = true
    print("moved")

  case "posted":
    let p = try resolvePost(store, try arg(0, "post id"))
    try actions.markPosted(postId: p.id, url: try arg(1, "url"))
    wrote = true
    print("posted \(p.platform.displayName) · \(tagOf(store, p.videoId))")
  case "problem":
    let p = try resolvePost(store, try arg(0, "post id"))
    guard let t = ErrorType(rawValue: try arg(1, "type")) else { throw CLIError("type: \(ErrorType.allCases.map(\.rawValue).joined(separator: "|"))") }
    try actions.reportProblem(postId: p.id, type: t, message: args.dropFirst(2).joined(separator: " "))
    wrote = true
    print("\(p.platform.displayName) → \(t.postState.displayName)\(t.postState.isCopyright ? " (never retried automatically — djq copyright \(short(p.id)) reupload|skip|accept)" : "")")
  case "fixed":
    let p = try resolvePost(store, try arg(0, "post id"))
    let n = try actions.fixed(postId: p.id)
    wrote = true
    print("re-queued \(p.platform.displayName) attempt \(n.attemptNo) · \(fmt(n.scheduledAt, settings))")
  case "reset":
    let p = try resolvePost(store, try arg(0, "post id"))
    try actions.reset(postId: p.id)
    wrote = true
    print("reset \(short(p.id))")
  case "skip":
    let p = try resolvePost(store, try arg(0, "post id"))
    try actions.skip(postId: p.id)
    wrote = true
    print("skipped \(short(p.id))")
  case "post-now":
    let p = try resolvePost(store, try arg(0, "post id"))
    try actions.postNow(postId: p.id)
    wrote = true
    print("\(p.platform.displayName) is due now")
  case "shift-plan":
    let p = try resolvePost(store, try arg(0, "post id"))
    try actions.shiftPlan(postId: p.id)
    wrote = true
    let n = try store.post(id: p.id)!
    print("\(p.platform.displayName) → \(fmt(n.scheduledAt, settings))")
  case "copyright":
    let p = try resolvePost(store, try arg(0, "post id"))
    let r: CopyrightResolution
    switch try arg(1, "reupload|skip|accept") {
    case "reupload": r = .reuploadAnyway(versionNo: args.count > 2 ? try intArg(args[2], "version", 1...99) : nil)
    case "skip": r = .skipPlatform
    case "accept": r = .accept
    default: throw CLIError("copyright <post> reupload [N]|skip|accept")
    }
    try actions.resolveCopyright(postId: p.id, r)
    wrote = true
    print("done")
  case "repost":
    let v = try resolveVideo(store, try arg(0, "video id"))
    let n = try actions.repost(videoId: v.id, platform: try platform(try arg(1, "platform")))
    wrote = true
    print("repost v\(n.versionNo) on \(n.platform.displayName) · \(fmt(n.scheduledAt, settings))")
  case "longform-posted":
    let v = try resolveVideo(store, try arg(0, "video id"))
    try actions.markLongformPosted(videoId: v.id, url: try arg(1, "url"))
    wrote = true
    print("long-form posted; file moved to Posted/Longform")

  case "score":
    let v = try resolveVideo(store, try arg(0, "video id"))
    let raw = try arg(1, "score")
    let score: Int? = raw == "clear" ? nil : try intArg(raw, "score", 0...100)
    try store.setScore(v.id, score)
    try store.refreshState(videoId: v.id)
    wrote = true
    print("\(v.tag) → \(score.map(String.init) ?? "unscored")")
  case "exclude", "include":
    let v = try resolveVideo(store, try arg(0, "video id"))
    try store.setExcluded(v.id, cmd == "exclude")
    wrote = true
    print("\(v.tag) \(cmd)d")
  case "pause", "resume":
    var s = settings
    if let a = args.first {
      let p = try platform(a)
      if cmd == "pause" { s.pausedPlatforms.insert(p) } else { s.pausedPlatforms.remove(p) }
    } else {
      s.paused = cmd == "pause"
    }
    try store.save(s)
    wrote = true
    print(s.paused ? "all posting paused" : "paused platforms: \(s.pausedPlatforms.isEmpty ? "none" : s.pausedPlatforms.map(\.displayName).sorted().joined(separator: ", "))")

  case "intake":
    let r = try Intake(store: store).run()
    wrote = true
    print("sessions \(r.sessionsSeen) · new \(r.newVideos.count) · updated \(r.updated) · missing \(r.missing.count) · relinked \(r.relinked.count) · untracked \(r.untracked.count) · parse errors \(r.parseErrors.count) · duplicate ids \(r.duplicateIds.count)")
    for x in r.relinked { print("  relinked  \(x)") }
    for x in r.missing { print("  missing   \(x)") }
    for x in r.parseErrors { print("  parse     \(x)") }
    let vids = try store.videos()
    print("videos: \(vids.filter { $0.type == .short }.count) short-form · \(vids.filter { $0.type == .long }.count) long-form")

  case "tick":
    // One engine per database: if DJ Queue (or another djq) holds the engine lock, ask it to tick instead.
    let force = flag("--force")
    let lock = EngineLock.acquire(paths)
    if lock == nil && !force {
      ChangeSignal.post()
      wrote = false
      print("Engine is running in DJ Queue; asked it to tick")
      return 0
    }
    defer { lock?.release() }
    let engine = Engine(store: store, renderer: RenderServices.make(store), publisher: nil, notifier: PrintNotifier())
    let r = engine.tick(reason: "cli")
    wrote = true
    for k in TickReport.order { if let v = r.steps[k] { print("  \(pad(k, 10)) \(v)") } }
    if !r.errors.isEmpty { return 1 }

  case "doctor":
    let json = flag("--json")
    let r = Doctor(store: store).run()
    if json {
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      e.dateEncodingStrategy = .iso8601
      print(String(decoding: try e.encode(r), as: UTF8.self))
    } else {
      print(Doctor.markdown(r))
    }
    return r.findings.contains { $0.severity == .error } ? 2 : 0

  case "health":
    let days = try option("--days").map { try intArg($0, "--days", 1...365) } ?? 7
    let since = store.clock.now.addingTimeInterval(-Double(days) * 86400)
    let periods = try Health.awakePeriods(store: store, since: since)
    print("Mac awake (last \(days) days)")
    if periods.isEmpty { print("  (no heartbeats)") }
    for p in periods { print("  \(fmt(p.start, settings)) → \(fmt(p.end, settings))  \(Int(p.duration / 60)) min") }
    let missed = try Health.missedSlots(store: store, since: since)
    print("Missed slots \(missed.count)")
    printPosts(store, missed, settings)

  case "render":
    let v = try resolveVideo(store, try arg(0, "video id"))
    let version = try option("--version").map { try intArg($0, "--version", 1...99) } ?? 1
    let p = try option("--platform").map(platform)
    guard let renderer = RenderServices.make(store) else {
      throw CLIError("the renderer isn't linked into this build yet (RenderServices.factory is unset)")
    }
    let r = try renderer.ensureRender(videoId: v.id, versionNo: version, platform: p)
    wrote = true
    print("render \(short(r.id)) \(r.status.rawValue) · \(r.outputPath ?? "-")")

  case "agent":
    switch try arg(0, "install|uninstall|status") {
    case "install":
      let app = option("--app") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DJ Queue.app").path
      // LaunchAgent.install refuses dev environments (DJQ_HOME/DJQ_ROOT) and apps outside ~/Applications.
      let load = flag("--load")
      if !flag("--force"), !FileManager.default.fileExists(atPath: app) {
        throw CLIError("\(app) doesn't exist — build/install the app first (or pass --force)")
      }
      try LaunchAgent.install(appPath: app, paths: paths, load: load)
      print("wrote \(paths.agentPlist.path)\(load ? " and loaded it" : " (not loaded — add --load)")")
    case "uninstall":
      try LaunchAgent.uninstall(paths: paths, unload: flag("--unload"))
      print("removed \(paths.agentPlist.path)")
    case "status":
      print("plist   \(LaunchAgent.isInstalled(paths: paths) ? "present" : "missing") · \(paths.agentPlist.path)")
      print("loaded  \(LaunchAgent.isLoaded() ? "yes" : "no")")
      if let hb = try store.lastHeartbeat() { print("last heartbeat \(fmt(hb.at, settings)) (\(hb.kind.rawValue))") }
    default: throw CLIError("agent install|uninstall|status")
    }

  default:
    throw CLIError("unknown command \(cmd)\n\n\(usage)")
  }
  return 0
}

do {
  exit(try run())
} catch {
  FileHandle.standardError.write(Data("djq: \(error)\n".utf8))
  exit(1)
}
