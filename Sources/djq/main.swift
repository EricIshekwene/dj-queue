import DJQCore
import Foundation

// djq — command-line access to the DJ Queue database (same SQLite file as the app; posts ChangeSignal after writes).
// Env: DJQ_ROOT (the "DJ Video" folder), DJQ_HOME (app support + logs) for dev copies and tests.

RenderServices.factory = { Renderer(store: $0) }

let usage = """
usage: djq <command> [args]

  status                              runway, today, problems, engine
  queue [--platform P]                the Queue (nothing missing, not scheduled yet) in posting order
  today                               today's posts
  posts [--problems] [--json]         upcoming/recent posts (or unresolved problems)
  week [--propose|--approve|--rebuild] [--json] [YYYY-MM-DD]
  videos [--stage S] [--state S] [--json]   clips (stage: score edit queue scheduled posted; state: a stored state, unscored, scored, needs-edit, all)
  video <video> [--json]              one clip: title, suggestions, edit (+resolved), versions, captions, posts
  defaults [--json]                   new clip defaults (Settings → New clip defaults)

  title <video> "<title>" | --clear   set Eric's title (agents: prefer suggest)
  suggest [<video>] --file <json>     add title and/or on-video text suggestions
                                      (array of {video_id, title_suggestions, text_suggestions} for many)
  text <video> "<text>" | --none | --default [--version N]
  caption <video> "<caption>" | --default [--platform P] [--version N]
  kind <video> "dj vid"|talking
  bulk <action> [args] (--ids a,b,c | --filter F) [--dry-run] [--json]
       actions: make-ready | apply-defaults [--sections frame,trim,text,cover,caption,platforms] | score <n|clear>
       | score-adjust <±n> | kind <k> | exclude | include | caption-template <id|default> | hashtags <a,b|default>
       | extra-hashtags "<#a #b>"|default | drop-hashtags <P> | skip-platform <P> | unskip-platform <P>
       | accept-title | title-raw-tag | title "<t>"|--clear | add-to-week <YYYY-MM-DD> | pin-consecutive <YYYY-MM-DD>
       | post-today | re-render | unqueue | requeue
  bulk undo <batch> [--force] | bulk batches [--json]
  agent-prompt titles [--ids a,b | --needs-title] [--out FILE]
  stage <video…> [back|forward] [--dry-run] [--json]   a clip's stage (Score→Edit→Queue→Scheduled→Posted), or move it one stage
  unqueue <video…> [--dry-run] [--json]   Back to Edit (held there); its unposted slots/posts are removed
  requeue <video…> [--dry-run] [--json]   Send to Queue again (Queue if nothing is missing, else stays in Edit)
  pin <video> <YYYY-MM-DD> | post-today <video> | skip-next <video> | push <YYYY-MM-DD> <days>
  remove-slot <slot> | swap <slot> <slot> | move <slot> <YYYY-MM-DD>
  posted <post> <url>                 mark posted (URL host must match the platform)
  problem <post> <type> <message>     type: \(ErrorType.allCases.map(\.rawValue).joined(separator: "|"))
  fixed <post> | reset <post> | skip <post> | post-now <post> | shift-plan <post>
  copyright <post> reupload [N]|skip|accept
  repost <video> <platform> | longform-posted <video> <url>
  score <video> <0-100|clear> | exclude <video> | include <video>
  pause [platform] | resume [platform]
  intake | tick [--force] | doctor [--json] [--live] | health [--days N]
  render <video> [--version N] [--platform P]
  agent install [--app PATH] [--load] [--force] | agent uninstall [--unload] | agent status
  autoupdate on|off|status|run|rollback|log   install commits to main automatically (djq autoupdate help)

  postiz status [--offline] [--ids] [--json]   Postiz connection, budget, test run, channel + route per platform
                                      (exit 0 = connected with all six channels mapped, 2 = not ready)
  postiz channels [--cached] [--refresh] [--ids] [--json]   live channel list + caption limit per channel
  postiz map [--dry-run] [--yes] | map <platform> <channel>|--clear   auto-map the six DJ channels by provider
  postiz publisher <platform|all> manual|postiz [--dry-run] [--yes] | postiz test-mode on|off [--dry-run] [--yes]
  postiz test <video> --dry-run|--draft   the six payloads (no call) or Postiz drafts only; never real posts
  postiz link <post> [<url>|<release-id>] | postiz release <post> --yes | postiz sync [--force]
                                      (djq postiz help for details; settings changes are undoable with bulk undo)

Ids can be shortened to a unique prefix. Platforms: \(Platform.allCases.map(\.rawValue).joined(separator: " "))
Title formatting from tags lives upstream: scripts/prefill_titles.py (docs/metadata.md).
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
  if cmd == "autoupdate" { return try AutoUpdateCommand.run(args, paths: paths) }
  if cmd == "prefill" {
    throw CLIError("prefill moved out of the app (round 2): run scripts/prefill_titles.py --tag \"<tag>\" or on a videos.json")
  }
  let store = try Store(paths: paths)
  let settings = try store.settings()
  let dm = DayMath(settings: settings)
  let actions = PostActions(store: store)
  let planner = Planner(store: store)
  let queue = Queue(store: store)
  let writes: Set<String> = ["week", "pin", "post-today", "skip-next", "push", "remove-slot", "swap", "move", "posted", "problem",
                             "fixed", "reset", "skip", "post-now", "shift-plan", "copyright", "repost", "longform-posted",
                             "score", "exclude", "include", "pause", "resume", "intake", "tick", "render",
                             "title", "suggest", "text", "caption", "kind", "bulk", "unqueue", "requeue", "stage"]
  var wrote = writes.contains(cmd) && (cmd != "week" || args.contains { $0.hasPrefix("--") && $0 != "--json" })
    && !(cmd == "bulk" && (args.contains("--dry-run") || args.first == "batches"))
    && !((cmd == "unqueue" || cmd == "requeue" || cmd == "stage") && args.contains("--dry-run"))
    && !(cmd == "stage" && !args.contains("back") && !args.contains("forward"))
  defer {
    if wrote {
      // Round 4 (S1): after any write, invalid Queue clips move to Edit (and valid Edit clips return) before the app
      // and engine hear about it.
      Revalidation.afterWrite(store: store, command: cmd)
      ChangeSignal.post()
    }
  }

  switch cmd {
  case "status":
    let now = store.clock.now
    let rw = try queue.runway()
    let today = try actions.dueToday(now: now)
    let problems = try actions.problems()
    print("DJ Queue · \(fmt(now, settings, "EEE d MMM yyyy HH:mm")) (\(settings.timeZone))")
    print("Runway     approved \(rw.approvedDays) d · queue \(rw.readyDays) d · total \(rw.totalDays) d")
    print("Stages     Score \(try queue.toScore().count) · Edit \(try queue.needsEdit().count) · Queue \(try queue.ordered().count) (not scheduled)")
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
    if list.isEmpty { print("  (empty — score clips and finish them in Edit)") }
    for (i, v) in list.enumerated() {
      print("  \(pad(String(i + 1), 3)) \(short(v.id))  \(pad(String(v.score ?? 0), 4))\(pad(v.tag, 36)) part \(v.part ?? 0) @ \(Int(v.start ?? 0))s")
    }
    let ts = try queue.toScore().count, ne = try queue.needsEdit().count
    print("  in Score \(ts) · in Edit \(ne)")

  case "today":
    print("Today · \(fmt(store.clock.now, settings, "EEE d MMM"))")
    printPosts(store, try actions.dueToday(now: store.clock.now), settings)

  case "posts":
    if flag("--json") {
      let since = dm.date(dm.addDays(dm.key(store.clock.now), -7))
      let problems = flag("--problems")
      try printJSON(try AgentAPI.posts(store: store, problems: problems, since: problems ? nil : since))
      return 0
    }
    if flag("--problems") {
      print("Problems")
      printPosts(store, try actions.problems(), settings)
    } else {
      let since = dm.date(dm.addDays(dm.key(store.clock.now), -7))
      print("Posts (from 7 days ago)")
      printPosts(store, try store.posts(where: "scheduled_at>=?", [since]), settings)
    }

  case "week":
    let propose = flag("--propose"), approve = flag("--approve"), rebuild = flag("--rebuild"), json = flag("--json")
    let week = try args.first.map { dm.weekStart(of: dm.date(try validDate($0))) } ?? dm.weekStart(of: store.clock.now)
    if propose { try planner.proposeWeek(week); wrote = true }
    if rebuild { try planner.rebuildWeek(week); wrote = true }
    if approve { try planner.approveWeek(week); wrote = true }
    if json { try printJSON(try AgentAPI.week(week, store: store)) } else { try printWeek(store, week) }

  case "videos":
    let state = option("--state")
    let stage = try option("--stage").map { raw -> ClipStage in
      guard let st = ClipStage(rawValue: raw.lowercased()) else {
        throw CLIError("--stage must be one of \(ClipStage.allCases.map(\.rawValue).joined(separator: ", "))")
      }
      return st
    }
    let list = try AgentAPI.videos(store: store, filter: state, stage: stage)
    if flag("--json") { try printJSON(list); return 0 }
    for v in list {
      print("  \(short(v.id))  \(pad(stageLabel(v), 11)) \(pad(v.score.map(String.init) ?? "–", 4))\(v.display_name)"
            + (v.title == nil ? "" : "  (tag: \(v.raw_tag))") + (v.suggestion_count > 0 ? "  [\(v.suggestion_count) suggestion(s)]" : "")
            + (v.reasons.isEmpty ? "" : "  — " + v.reasons.joined(separator: " · ")))
    }
    print("  \(list.count) clip(s)")

  case "video":
    let v = try resolveVideo(store, try arg(0, "video id"))
    let d = try AgentAPI.video(v.id, store: store)
    if flag("--json") { try printJSON(d); return 0 }
    print("\(d.video.display_name)  [\(v.id)]")
    print("  tag \(d.video.raw_tag) · \(d.video.kind) · \(stageLabel(d.video)) · score \(d.video.score.map(String.init) ?? "–")")
    print("  title \(d.video.title.map { "\"\($0)\" (\(d.video.title_source ?? "?"))" } ?? "none")")
    for s in d.title_suggestions {
      print("  suggestion \"\(Captions.oneLine(s.text))\" \(s.confidence.map { String(format: "%.2f", $0) } ?? "?") \(s.source) [\(s.origin)]")
    }
    for s in d.text_suggestions {
      print("  text suggestion \"\(s.text.replacingOccurrences(of: "\n", with: " / "))\" \(s.confidence.map { String(format: "%.2f", $0) } ?? "?") \(s.source) [\(s.origin)]")
    }
    let re = d.resolved_edit
    print("  trim \(EditorLogic.time(re.trimIn, tenths: true))–\(EditorLogic.time(re.trimOut, tenths: true))\(re.isDefault(.trimIn) && re.isDefault(.trimOut) ? " (default)" : "") · aspect \(re.aspect.rawValue) · crop \(re.cropConfirmed ? "confirmed" : "not confirmed")")
    if let r = d.resolved_v1 { print("  text \(r.noText ? "(no text)" : "\"\(Captions.oneLine(r.text))\"")\(r.isDefault("text") ? " (default)" : "")") }
    for i in d.issues { print("  issue  \(i.message)") }

  case "defaults":
    if flag("--json") { try printJSON(settings.defaults); return 0 }
    print(String(decoding: try AgentAPI.encoder.encode(settings.defaults), as: UTF8.self))

  case "title":
    let v = try resolveVideo(store, try arg(0, "video id"))
    if flag("--clear") {
      try store.setTitle(v.id, nil, source: "agent")
      print("\(v.tag): title cleared")
    } else {
      let t = try arg(1, "title (or --clear)")
      try store.setTitle(v.id, t, source: "agent")
      print("\(v.tag) → \"\(t)\"")
    }
    wrote = true

  case "suggest":
    guard let file = option("--file") else { throw CLIError("suggest needs --file <json>") }
    let vid = try args.first.map { try resolveVideo(store, $0).id }
    let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: file))
    let entries = try SuggestionImport.parse(data, videoId: vid)
    var n = 0, nt = 0
    try store.db.transaction {
      for e in entries {
        let id = try resolveVideo(store, e.videoId).id
        n += try store.addSuggestions(videoId: id, e.suggestions, origin: "agent")
        nt += try store.addSuggestions(videoId: id, e.textSuggestions, origin: "agent", kind: .text)
      }
    }
    wrote = n + nt > 0
    print("added \(n) title suggestion(s) and \(nt) text suggestion(s) for \(entries.count) clip(s)")

  case "text":
    let v = try resolveVideo(store, try arg(0, "video id"))
    let n = try option("--version").map { try intArg($0, "--version", 1...99) } ?? 1
    var ver = try store.versions(videoId: v.id).first { $0.number == n } ?? Version(number: n)
    let existing = Set(try store.versions(videoId: v.id).map(\.number))
    if n > 1, !existing.contains(n), !existing.contains(n - 1) { throw CLIError("v\(n - 1) doesn't exist yet") }
    if flag("--none") { ver.noText = true; ver.text = nil }
    else if flag("--default") { ver.noText = nil; ver.text = nil }
    else { ver.text = try arg(1, "text (or --none / --default)"); ver.noText = false }
    try store.save(ver, videoId: v.id)
    wrote = true
    print("\(v.tag) v\(n) text → \(ver.noText == true ? "No text" : ver.text.map { "\"\($0)\"" } ?? "default")")

  case "caption":
    let v = try resolveVideo(store, try arg(0, "video id"))
    let n = try option("--version").map { try intArg($0, "--version", 1...99) } ?? 1
    let p = try option("--platform").map(platform)
    var ver = try store.versions(videoId: v.id).first { $0.number == n } ?? Version(number: n)
    let value: String? = flag("--default") ? nil : try arg(1, "caption (or --default)")
    if let p {
      var pc = ver.platformCaptions ?? [:]
      pc[p] = value
      ver.platformCaptions = pc.isEmpty ? nil : pc
    } else {
      ver.caption = value
    }
    try store.save(ver, videoId: v.id)
    wrote = true
    print("\(v.tag) v\(n) caption\(p.map { " for \($0.displayName)" } ?? "") → \(value == nil ? "default" : "set")")

  case "kind":
    let v = try resolveVideo(store, try arg(0, "video id"))
    guard let k = Kind(rawValue: try arg(1, "kind")) ?? Kind.allCases.first(where: { $0.displayName.lowercased() == args[1].lowercased() }) else {
      throw CLIError("kind must be \"dj vid\" or talking")
    }
    try store.setKind(v.id, k)
    wrote = true
    print("\(v.tag) → \(k.displayName)")

  case "bulk":
    return try runBulk(store, &wrote)

  case "agent-prompt":
    guard try arg(0, "titles") == "titles" else { throw CLIError("agent-prompt titles [--ids a,b | --needs-title] [--out FILE]") }
    let out = option("--out")
    let ids: [String]
    if let raw = option("--ids") {
      ids = try raw.split(separator: ",").map { try resolveVideo(store, String($0)).id }
    } else {
      _ = flag("--needs-title")
      ids = try AgentPrompts.clipsNeedingTitleHelp(store: store)
      if ids.isEmpty { print("No clips need title help (every clip has a title or a confident suggestion)."); return 0 }
    }
    let md = try AgentPrompts.titles(for: ids, store: store)
    if let out {
      try md.write(toFile: out, atomically: true, encoding: .utf8)
      print("wrote \(out) (\(ids.count) clip(s))")
    } else {
      print(md)
    }

  case "stage":
    let json = flag("--json"), dry = flag("--dry-run")
    var dir: StageDirection?
    if let last = args.last, let d = StageDirection(rawValue: last) { dir = d; args.removeLast() }
    guard !args.isEmpty else { throw CLIError("stage <video…> [back|forward] [--dry-run] [--json]") }
    let ids = try args.flatMap { $0.split(separator: ",") }.map { try resolveVideo(store, String($0).trimmingCharacters(in: .whitespaces)).id }
    let bulk = BulkActions(store: store)
    guard let dir else {
      // back/forward: "→ <stage>" or why not (unchanged keys); round 4 adds the control labels (the app's words),
      // the blockers on their own and, for Edit clips, the reason chips.
      struct StageOut: Encodable {
        var id: String; var display_name: String; var stage: String?; var back: String?; var forward: String?
        var back_title: String?; var forward_title: String?; var back_blocked: String?; var forward_blocked: String?
        var reasons: [String]
      }
      let rows = try ids.compactMap { try store.video(id: $0) }.map { v -> StageOut in
        let st = ClipStage.of(v)
        let bb = try bulk.blocker(v, .back), fb = try bulk.blocker(v, .forward)
        let reasons = st == .edit
          ? try Validation.issues(video: v, store: store).sorted { $0.kind.chipOrder < $1.kind.chipOrder }.map(\.chipText) : []
        return StageOut(id: v.id, display_name: v.displayName, stage: st?.rawValue,
                        back: bb ?? st?.backTarget.map { "→ \($0.displayName)" },
                        forward: fb ?? st?.forwardTarget.map { "→ \($0.displayName)" },
                        back_title: st?.backTitle, forward_title: st?.forwardTitle, back_blocked: bb, forward_blocked: fb,
                        reasons: reasons)
      }
      if json { try printJSON(rows); return 0 }
      for o in rows {
        let back = o.back_blocked.map { "can't go back: \($0)" } ?? o.back_title ?? "—"
        let fwd = o.forward_blocked.map { "can't go forward: \($0)" } ?? o.forward_title ?? "—"
        print("  \(short(o.id))  \(pad(o.display_name, 30)) \(pad(o.stage.flatMap(ClipStage.init(rawValue:))?.displayName ?? "—", 10))  ‹ \(back)  ·  \(fwd) ›"
              + (o.reasons.isEmpty ? "" : "\n      why in Edit: " + o.reasons.joined(separator: " · ")))
      }
      return 0
    }
    let r = dir == .back ? try bulk.back(ids, dryRun: dry) : try bulk.forward(ids, dryRun: dry)
    wrote = !dry && !r.changed.isEmpty
    if json { try printJSON(r); return 0 }
    printBulk(r)
    for (id, m) in (r.moves ?? [:]).sorted(by: { $0.key < $1.key }) {
      print("  \(short(id))  \(tagOf(store, id)): \(StageWording.moveText(m.from, m.to)) · \(m.note)")
    }

  case "unqueue", "requeue":
    let json = flag("--json"), dry = flag("--dry-run")
    guard !args.isEmpty else { throw CLIError("\(cmd) <video…> [--dry-run] [--json]") }
    let ids = try args.flatMap { $0.split(separator: ",") }.map { try resolveVideo(store, String($0).trimmingCharacters(in: .whitespaces)).id }
    let bulk = BulkActions(store: store)
    let r = cmd == "unqueue" ? try bulk.removeFromQueue(ids, dryRun: dry) : try bulk.sendToQueue(ids, dryRun: dry)
    wrote = !dry && !r.changed.isEmpty
    if json { try printJSON(r); return 0 }
    printBulk(r)
    for (id, items) in (r.unplanned ?? [:]).sorted(by: { $0.key < $1.key }) {
      let days = items.map { i in
        fmt(dm.date(i.date), settings, "EEE d MMM") + (i.platforms.isEmpty ? " · proposed" : " · \(i.platforms.count) platform\(i.platforms.count == 1 ? "" : "s")")
          + (i.pinned ? " · pinned" : "")
      }
      print("  \(short(id))  \(tagOf(store, id)): \(r.dryRun ? "would remove" : "removed") \(days.joined(separator: ", "))")
    }

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
    let d = Doctor(store: store)
    // --live: one budgeted Postiz call (refreshes the channel list and the key state) before the postiz checks.
    d.postizLive = flag("--live")
    let r = d.run()
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

  case "postiz":
    return try PostizCommand.run(store, &wrote)

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

/// "Edit" / "Queue" / … (the stage name), else "Long-form" / "Excluded" / "File missing" — never "ready"/"needs edit".
func stageLabel(_ v: AgentAPI.VideoSummary) -> String {
  if let st = v.stage.flatMap(ClipStage.init(rawValue:)) { return st.displayName }
  if v.type == VideoType.long.rawValue { return v.state == VideoState.posted.rawValue ? "Long · posted" : "Long-form" }
  if v.excluded { return "Excluded" }
  return v.missing ? "File missing" : "—"
}

/// Prints JSON; an encoding failure throws (→ "djq: …" on stderr, exit 1), never a silent `null`.
func printJSON<T: Encodable>(_ v: T) throws {
  print(String(decoding: try AgentAPI.encoder.encode(v), as: UTF8.self))
}

func runBulk(_ store: Store, _ wrote: inout Bool) throws -> Int32 {
  let bulk = BulkActions(store: store)
  let json = flag("--json"), dry = flag("--dry-run"), force = flag("--force")
  let action = try arg(0, "bulk action")
  args.removeFirst()
  if action == "batches" {
    let list = try bulk.batches()
    if json { try printJSON(list); return 0 }
    for b in list {
      print("  \(short(b.id))  \(fmt(b.createdAt, try store.settings()))  \(pad(b.action, 16)) \(b.summary)\(b.undoneAt != nil ? "  (undone)" : "")")
    }
    return 0
  }
  if action == "undo" {
    let raw = try arg(0, "batch id")
    let m = try bulk.batches(limit: 1000).filter { $0.id.hasPrefix(raw) }
    guard m.count == 1 else { throw CLIError(m.isEmpty ? "no batch \(raw)" : "\(raw) matches \(m.count) batches") }
    let r = try bulk.undo(m[0].id, force: force, dryRun: dry)
    wrote = !dry && !r.changed.isEmpty
    if json { try printJSON(r) } else { printBulk(r) }
    return 0
  }
  let ids: [String]
  if let raw = option("--ids") {
    ids = try raw.split(separator: ",").map { try resolveVideo(store, String($0).trimmingCharacters(in: .whitespaces)).id }
  } else if let f = option("--filter") {
    ids = try bulk.ids(filter: f)
  } else {
    throw CLIError("bulk \(action) needs --ids a,b,c or --filter <state>")
  }
  func p() throws -> Platform { try platform(try arg(0, "platform")) }
  let r: BulkResult
  switch action {
  case "make-ready": r = try bulk.makeReadyWithDefaults(ids, dryRun: dry)
  case "apply-defaults":
    let secs = try option("--sections").map { raw in
      try Set(raw.split(separator: ",").map { s -> BulkSection in
        guard let x = BulkSection(rawValue: String(s)) else { throw CLIError("unknown section \(s) (\(BulkSection.allCases.map(\.rawValue).joined(separator: ",")))") }
        return x
      })
    } ?? Set(BulkSection.allCases)
    r = try bulk.applyDefaults(ids, sections: secs, dryRun: dry)
  case "score":
    let raw = try arg(0, "score")
    r = try bulk.setScore(ids, raw == "clear" ? nil : try intArg(raw, "score", 0...100), dryRun: dry)
  case "score-adjust": r = try bulk.adjustScore(ids, by: try intArg(try arg(0, "delta"), "delta", -100...100), dryRun: dry)
  case "kind":
    guard let k = Kind(rawValue: try arg(0, "kind")) else { throw CLIError("kind must be \"dj vid\" or talking") }
    r = try bulk.setKind(ids, k, dryRun: dry)
  case "exclude", "include": r = try bulk.setExcluded(ids, action == "exclude", dryRun: dry)
  case "caption-template":
    let t = try arg(0, "template id|default")
    r = try bulk.setCaptionTemplate(ids, t == "default" ? nil : t, dryRun: dry)
  case "hashtags":
    let t = try arg(0, "set ids|default")
    r = try bulk.setHashtagSets(ids, t == "default" ? nil : t.split(separator: ",").map(String.init), dryRun: dry)
  case "extra-hashtags":
    let t = try arg(0, "\"#a #b\"|default")
    r = try bulk.setExtraHashtags(ids, t == "default" ? nil : t.split(separator: " ").map(String.init), dryRun: dry)
  case "drop-hashtags": r = try bulk.dropHashtags(ids, platform: try p(), dryRun: dry)
  case "skip-platform", "unskip-platform": r = try bulk.setPlatform(ids, try p(), skipped: action == "skip-platform", dryRun: dry)
  case "accept-title": r = try bulk.acceptTopTitleSuggestion(ids, dryRun: dry)
  case "title-raw-tag": r = try bulk.useRawTagAsTitle(ids, dryRun: dry)
  case "title": r = try bulk.setTitle(ids, flag("--clear") ? nil : try arg(0, "title"), dryRun: dry)
  case "add-to-week": r = try bulk.addToWeek(ids, week: try dateArg(0), dryRun: dry)
  case "pin-consecutive": r = try bulk.pinConsecutive(ids, from: try dateArg(0), dryRun: dry)
  case "post-today": r = try bulk.postToday(ids, dryRun: dry)
  case "re-render": r = try bulk.reRender(ids, dryRun: dry)
  case "unqueue": r = try bulk.removeFromQueue(ids, dryRun: dry)
  case "requeue": r = try bulk.sendToQueue(ids, dryRun: dry)
  default: throw CLIError("unknown bulk action \(action)\n\n\(usage)")
  }
  wrote = !dry && !r.changed.isEmpty
  if json { try printJSON(r) } else { printBulk(r) }
  return 0
}

func printBulk(_ r: BulkResult) {
  print("\(r.dryRun ? "[dry run] " : "")\(r.summary)\(r.batchId.map { " · batch \(short($0)) (undo: djq bulk undo \(short($0)))" } ?? "")")
  if let o = r.outlook { print("  after: \(o.summary)") }
  for (id, why) in r.skipped.sorted(by: { $0.key < $1.key }) { print("  skipped \(short(id))  \(why)") }
  for (id, issues) in r.remainingIssues.sorted(by: { $0.key < $1.key }) where !issues.isEmpty {
    print("  \(short(id)) still: \(issues.map(\.message).joined(separator: "; "))")
  }
}

do {
  exit(try run())
} catch {
  FileHandle.standardError.write(Data("djq: \(error)\n".utf8))
  exit(1)
}
