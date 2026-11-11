import Foundation

/// Sanity check (spec §11). Read-only: it never changes the database or any file.
/// Every finding has a stable id; `skills/dj-queue-doctor/SKILL.md` has the safe fix for each id.
public final class Doctor: @unchecked Sendable {
  let store: Store
  /// Injectable for tests (default asks launchctl, read-only).
  public var agentLoaded: () -> Bool = { LaunchAgent.isLoaded() }
  public var autoUpdateWatcherLoaded: () -> Bool = { AutoUpdateWatcher.isLoaded() }
  /// Duration check with ffprobe (planned/next-48 h videos only). Off in tests for speed.
  public var probeDurations = true
  /// Round 6: where the Postiz checks ask "is a key saved?" (never its value). Tests inject a memory store.
  public var postizKeyStore: PostizKeyStore = KeychainPostizKeyStore()
  /// `djq doctor --live`: one budgeted `GET /integrations` before the Postiz checks (refreshes the cached channel
  /// list and the key state). Off by default: Doctor reads stored state only and makes no call.
  public var postizLive = false
  /// Transport for `postizLive` (nil = the real one). Tests pass a fake.
  public var postizTransport: PostizTransport?

  public init(store: Store) { self.store = store }

  public func run() -> DoctorReport {
    var findings: [DoctorFinding] = []
    var passed: [String] = []
    func check(_ id: String, _ body: () throws -> [DoctorFinding]) {
      do {
        let f = try body()
        if f.filter({ $0.severity != .info }).isEmpty { passed.append(id) }
        findings += f
      } catch {
        findings.append(DoctorFinding(id: id, severity: .error, title: "Check \(id) crashed", detail: "\(error)",
                                      where_: [], fix: "Run `djq doctor` again; if it repeats, send this report to an agent."))
      }
    }
    check("manifest", manifests)
    check("files.missing", missingFiles)
    check("photos.missing", missingPhotos)
    check("files.relinked", relinked)
    check("files.duration", durations)
    check("plan.notReady", notReadyButPlanned)
    check("plan.gaps", planGaps)
    check("plan.nowhereToPost", nowhereToPost)
    check("runway", runway)
    check("renders.missing", rendersMissing)
    check("renders.failed", renderFailures)
    check("posts.overdue", overdue)
    check("posts.problems", unresolved)
    check("platform.limits", platformLimits)
    check("engine", engine)
    check("db", database)
    check("disk.free", disk)
    check("tools", tools)
    check("system.timezone", timeZone)
    check("autoupdate", autoUpdate)
    check("postiz", postiz)
    check("capcut.markers") {
      [DoctorFinding(id: "capcut.markers", severity: .info, title: "CapCut markers not checked",
                     detail: "No CapCut project → videos.json mapping is recorded yet, so marker changes since export can't be compared.",
                     where_: [], fix: "Nothing to do. To check by hand: run _tools/pair_markers.py on the project and compare with videos.json marked_start/marked_end.")]
    }
    findings.sort { ($0.severity, $1.id) > ($1.severity, $0.id) }
    return DoctorReport(generatedAt: store.clock.now, findings: findings, passed: passed)
  }

  // MARK: Markdown

  public static func markdown(_ r: DoctorReport) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "America/New_York")
    let errors = r.findings.filter { $0.severity == .error }.count
    let warnings = r.findings.filter { $0.severity == .warning }.count
    let infos = r.findings.filter { $0.severity == .info }.count
    var out = "# DJ Queue Doctor report\n\n"
    out += "Generated \(f.string(from: r.generatedAt)) · **\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s"), \(infos) info**\n\n"
    out += "Fix guide: the `dj-queue-doctor` skill (`skills/dj-queue-doctor/SKILL.md`). Never touch files under a session's Video/, Audio/, Other/ or Clips/.\n\n"
    if r.findings.isEmpty { out += "All checks passed.\n\n" }
    for x in r.findings {
      out += "## [\(x.severity.rawValue.uppercased())] \(x.title)\n\n"
      out += "- id: `\(x.id)`\n"
      if !x.detail.isEmpty { out += "- what: \(x.detail)\n" }
      if !x.where_.isEmpty {
        out += "- where:\n"
        for w in x.where_.prefix(25) { out += "  - `\(w)`\n" }
        if x.where_.count > 25 { out += "  - … and \(x.where_.count - 25) more\n" }
      }
      out += "- fix: \(x.fix)\n\n"
    }
    if !r.passed.isEmpty { out += "Passed: " + r.passed.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
    return out
  }

  // MARK: Checks

  /// videos.json parse errors, duplicate ids, untracked clips (read-only re-scan).
  func manifests() throws -> [DoctorFinding] {
    let fm = FileManager.default
    let dirs = ((try? fm.contentsOfDirectory(at: store.paths.sessions, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
      .filter { !$0.lastPathComponent.hasPrefix("_") && !$0.lastPathComponent.hasPrefix(".") }
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    var parse: [String] = [], seen: [String: String] = [:], dups: [String] = [], untracked: [String] = []
    let tracked = Set(try store.videos().compactMap { try store.fileURL(for: $0)?.standardizedFileURL.path })
    for dir in dirs {
      let m = dir.appendingPathComponent("videos.json")
      guard fm.fileExists(atPath: m.path) else { continue }
      var files = Set<String>()
      do {
        let man = try JSONDecoder().decode(Intake.Manifest.self, from: Data(contentsOf: m))
        for e in man.videos {
          files.insert(dir.appendingPathComponent(e.file).standardizedFileURL.path)
          guard let id = e.id, !id.isEmpty else { parse.append("\(m.path): \"\(e.name)\" has no id"); continue }
          if let other = seen[id] { dups.append("\(id): \(other) / \(e.name)") } else { seen[id] = e.name }
        }
      } catch {
        parse.append("\(m.path): \(error)")
        continue
      }
      let clips = dir.appendingPathComponent("Clips")
      for f in (try? fm.contentsOfDirectory(atPath: clips.path)) ?? [] where f.lowercased().hasSuffix(".mp4") {
        let p = clips.appendingPathComponent(f).standardizedFileURL.path
        if !files.contains(p) && !tracked.contains(p) { untracked.append(p) }
      }
    }
    var out: [DoctorFinding] = []
    if !parse.isEmpty {
      out.append(.init(id: "manifest.parse", severity: .error, title: "videos.json can't be read", detail: "\(parse.count) problem(s); those sessions keep their last good data.",
                       where_: parse, fix: "Fix the JSON (or re-run _tools/export_clips.py for that part, which rewrites videos.json and keeps ids), then `djq intake`."))
    }
    if !dups.isEmpty {
      out.append(.init(id: "manifest.duplicateIds", severity: .error, title: "Duplicate video ids", detail: "Only the first entry with each id is used.",
                       where_: dups, fix: "Give the copy a new UUID in its videos.json (never change the id that has posts), then `djq intake`."))
    }
    if !untracked.isEmpty {
      out.append(.init(id: "files.untracked", severity: .warning, title: "Clips not in any videos.json", detail: "\(untracked.count) .mp4 file(s) in Clips/ aren't tracked.",
                       where_: untracked, fix: "Export them with _tools/export_clips.py (adds them to videos.json), or leave them — the app ignores untracked clips. Don't delete or rename them from the app."))
    }
    return out
  }

  /// Round 21: a photo post with a photo file gone from DJ Queue's Photos folder (it can't render or post).
  func missingPhotos() throws -> [DoctorFinding] {
    let importer = PhotoImport(store: store)
    var w: [String] = []
    for v in try store.videos(where: "photos IS NOT NULL") {
      for f in try importer.missingFiles(v) { w.append("\(v.id) · \(v.displayName) · \(store.paths.photos.appendingPathComponent(f).path)") }
    }
    // Round 23: a video made from a photo, whose own file (`Photos/Stills/<id>/video.mp4`) is gone.
    for v in try store.videos(where: "still IS NOT NULL") {
      let url = store.paths.photos.appendingPathComponent(v.file)
      if !FileManager.default.fileExists(atPath: url.path) { w.append("\(v.id) · \(v.displayName) · \(url.path)") }
    }
    guard !w.isEmpty else { return [] }
    return [.init(id: "photos.missing", severity: .error, title: "\(w.count) photo file(s) missing", detail: "A photo post can't render or post while one of its photos is gone, nor a photo with audio while its video file is. Records are kept.",
                  where_: w, fix: "Put the file back at that path and run `djq intake` (the post comes back by itself). If the photo is gone for good, Eric removes it from the post in the editor, or excludes the post (`djq exclude <id>`). Never edit files under Photos/Originals by hand otherwise.")]
  }

  func missingFiles() throws -> [DoctorFinding] {
    let vids = try store.videos(where: "missing=1 AND photos IS NULL AND still IS NULL")  // those two are `photos.missing`
    guard !vids.isEmpty else { return [] }
    let w = try vids.map { "\($0.id) · \($0.name) · \(try store.fileURL(for: $0)?.path ?? $0.file)\($0.inManifest ? "" : " (removed from videos.json)")" }
    return [.init(id: "files.missing", severity: .error, title: "\(vids.count) video file(s) missing", detail: "Missing videos can't render or post. Records are kept.",
                  where_: w, fix: "Put the file back (or rename it back) and run `djq intake` — intake relinks by fingerprint anywhere in the session folders. If it was deleted on purpose, exclude the video (`djq exclude <id>`).")]
  }

  func relinked() throws -> [DoctorFinding] {
    let since = store.clock.now.addingTimeInterval(-14 * 86400)
    let ev = try store.events(limit: 500).filter { $0.kind == "relink" && $0.at >= since }
    guard !ev.isEmpty else { return [] }
    return [.init(id: "files.relinked", severity: .info, title: "\(ev.count) file(s) relinked in the last 14 days",
                  detail: "Files were found again by fingerprint after a rename/move.", where_: ev.map(\.message), fix: "Nothing to do.")]
  }

  /// Duration vs ffprobe for the videos posting in the next 48 h (and today's slots) — at most 12, to stay fast.
  func durations() throws -> [DoctorFinding] {
    guard probeDurations, let ffprobe = Tools.ffprobe else { return [] }
    let now = store.clock.now
    let ids = Array(Set(try store.posts(where: "scheduled_at>=? AND scheduled_at<=?", [now.addingTimeInterval(-86400), now.addingTimeInterval(48 * 3600)])
      .filter { !$0.state.isTerminal }.map(\.videoId))).sorted().prefix(12)
    var bad: [String] = []
    for id in ids {
      // A photo post has no duration to compare (round 21): ffprobe never sees it.
      guard let v = try store.video(id: id), !v.missing, !v.isPhoto, let url = try store.fileURL(for: v) else { continue }
      let r = LaunchAgent.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
      guard let d = Double(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        bad.append("\(v.id) · \(v.name): ffprobe can't read the file")
        continue
      }
      if abs(d - v.duration) > 0.5 { bad.append("\(v.id) · \(v.name): file \(String(format: "%.1f", d)) s, videos.json \(String(format: "%.1f", v.duration)) s") }
    }
    guard !bad.isEmpty else { return [] }
    return [.init(id: "files.duration", severity: .warning, title: "Duration doesn't match videos.json", detail: "Checked the videos posting in the next 48 h.",
                  where_: bad, fix: "Re-export the clip with _tools/export_clips.py (it rewrites videos.json), then `djq intake`; re-render if a render exists.")]
  }

  func notReadyButPlanned() throws -> [DoctorFinding] {
    let dm = try store.dayMath()
    var w: [String] = []
    for s in try store.planSlots(where: "date>=?", [store.today(dm)]) {
      guard let v = try store.video(id: s.videoId) else { w.append("\(s.date) slot \(s.id): video \(s.videoId) not found"); continue }
      if let i = try Validation.issues(video: v, store: store).first(where: { $0.kind != .tooLong }) ?? (v.excluded ? ValidationIssue(kind: .missingFile, platform: nil, message: "Excluded") : nil) {
        w.append("\(s.date) · \(v.id) · \(v.tag): \(i.message)")
      }
    }
    guard !w.isEmpty else { return [] }
    return [.init(id: "plan.notReady", severity: .error, title: "Planned clips with something missing", detail: "These can't render or post on their day (they stay on their day; fix them or swap them).",
                  where_: w, fix: "Finish the edit in the app (crop, text or No text, caption), or move it on the Calendar (`djq stage <video-id> back` takes it off).")]
  }

  /// An open day with a clip waiting means the scheduler is stuck: every tick fills them. An open day with an empty
  /// Queue is normal, and so is anything while posting is paused.
  func planGaps() throws -> [DoctorFinding] {
    let settings = try store.settings()
    guard !settings.paused else { return [] }
    let dm = DayMath(settings: settings)
    let planner = Planner(store: store)
    let waiting = try planner.schedulable(settings)
    guard !waiting.isEmpty else { return [] }
    let open = try planner.openPositions(now: store.clock.now, settings: settings, dm: dm).prefix(waiting.count)
    guard !open.isEmpty else { return [] }
    var seen = Set<String>()
    let days = open.map(\.date).filter { seen.insert($0).inserted }
    let w = try days.map { "\($0): \(try store.planSlots(where: "date=? AND exact_at IS NULL", [$0]).count)/\(settings.postsPerDay) posts" }
    return [.init(id: "plan.gaps", severity: .warning, title: "Open days with clips waiting in the Queue",
                  detail: "\(waiting.count) clip\(waiting.count == 1 ? "" : "s") waiting and days still open: the scheduler should have filled them.",
                  where_: w, fix: "Check the engine is running (`djq status`), then `djq schedule --dry-run` says what it would do and why not; `djq schedule` runs it once.")]
  }

  /// A Queue clip with history or a skip on every platform never gets a day. Not a fault, but nothing else says so.
  func nowhereToPost() throws -> [DoctorFinding] {
    let settings = try store.settings()
    let waiting = Set(try Planner(store: store).schedulable(settings).map(\.id))
    let stuck = try Queue(store: store).ordered().filter { !waiting.contains($0.id) }
    guard !stuck.isEmpty else { return [] }
    return [.init(id: "plan.nowhereToPost", severity: .info, title: "\(stuck.count) Queue clip\(stuck.count == 1 ? "" : "s") with nowhere left to post",
                  detail: "Every platform is done or skipped for these, so they never get a day. They aren't counted as waiting.",
                  where_: stuck.map { "\($0.id) · \($0.tag)" }, fix: "Nothing to do. To post one again use `djq repost <video-id> <platform>`; `djq stage <video-id> back` takes it out of the Queue.")]
  }

  func runway() throws -> [DoctorFinding] {
    let s = try store.settings()
    let r = try Queue(store: store).runway()
    var out: [DoctorFinding] = []
    if r.isLow(s) {
      out.append(.init(id: "runway.queue", severity: .warning, title: StageWording.queueLowTitle,
                       detail: "\(StageWording.scheduledThrough(r.scheduledThrough, settings: s)) (\(r.approvedDays) day\(r.approvedDays == 1 ? "" : "s"), below the \(s.approvedRunwayAlertDays)-day threshold) and the Queue is about out.",
                       where_: [], fix: "Send clips to the Queue from Edit."))
    }
    if r.totalDays < s.totalRunwayAlertDays {
      out.append(.init(id: "runway.total", severity: .warning, title: "Total runway \(r.totalDays) day(s)", detail: "Below the \(s.totalRunwayAlertDays)-day threshold (Queue \(r.readyDays) d).",
                       where_: [], fix: "Score unscored clips and finish the ones in Edit; record and export a new set."))
    }
    return out
  }

  func rendersMissing() throws -> [DoctorFinding] {
    let now = store.clock.now
    var w: [String] = []
    for p in try store.posts(where: "scheduled_at<=? AND state IN ('planned','rendering','rendered','due','overdue')", [now.addingTimeInterval(48 * 3600)]) {
      let r = try p.renderId.flatMap { try store.render(id: $0) }
      if let r, r.outputPath != nil, r.deletedAt == nil, r.allPaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) { continue }
      w.append("post \(p.id) · \(p.platform.rawValue) · \(p.videoId) v\(p.versionNo) · \(r == nil ? "no render" : "render file missing")")
    }
    guard !w.isEmpty else { return [] }
    return [.init(id: "renders.missing", severity: .warning, title: "Posts in the next 48 h without a render", detail: "The engine renders ahead while the Mac is on.",
                  where_: w, fix: "Keep the Mac awake with the app running, or run `djq tick` / `djq render <video-id> --version N --platform P`.")]
  }

  func renderFailures() throws -> [DoctorFinding] {
    let failed = try store.renders(where: "deleted_at IS NULL AND status='failed'")
    let latestOK = Set(try store.renders(where: "deleted_at IS NULL AND status='done'").map { "\($0.videoId)#\($0.versionNo)#\($0.scope)" })
    let open = failed.filter { !latestOK.contains("\($0.videoId)#\($0.versionNo)#\($0.scope)") }
    guard !open.isEmpty else { return [] }
    return [.init(id: "renders.failed", severity: .error, title: "\(open.count) render(s) failed", detail: "No successful render exists for these yet.",
                  where_: open.map { "render \($0.id) · \($0.videoId) v\($0.versionNo) \($0.scope): \($0.error ?? "unknown")" },
                  fix: "Read ~/Library/Logs/DJ Queue/engine.log for the ffmpeg error, fix the edit (crop inside the frame, trim inside the file), then `djq render <video-id>`.")]
  }

  func overdue() throws -> [DoctorFinding] {
    let ps = try store.posts(where: "state='overdue'")
    guard !ps.isEmpty else { return [] }
    let s = try store.settings()
    return [.init(id: "posts.overdue", severity: .error, title: "\(ps.count) overdue post(s)", detail: "A whole day passed without posting; that platform's plan was shifted so nothing double-posts.",
                  where_: ps.map { "post \($0.id) · \($0.platform.displayName) · \($0.videoId) · was \(Sched.shortTime($0.scheduledAt, s))" },
                  fix: "On the Calendar or in the notification: Post now, Shift plan (into today's slot) or Skip. If it was actually posted, `djq posted <post-id> <url>`.")]
  }

  func unresolved() throws -> [DoctorFinding] {
    let ps = try PostActions(store: store).problems().filter { $0.state != .overdue }
    guard !ps.isEmpty else { return [] }
    let copyright = ps.filter { $0.state.isCopyright }
    let failed = ps.filter { !$0.state.isCopyright }
    var out: [DoctorFinding] = []
    if !failed.isEmpty {
      out.append(.init(id: "posts.failed", severity: .error, title: "\(failed.count) failed post(s)", detail: "Each needs its cause fixed; then the engine re-queues that platform the next day.",
                       where_: failed.map { "post \($0.id) · \($0.platform.displayName) · \($0.errorType?.rawValue ?? "?"): \($0.errorMessage ?? "")" },
                       fix: "Fix the cause (too_long: per-platform trim in the editor — re-queued automatically), then `djq fixed <post-id>`. Wrongly marked? `djq reset <post-id>`."))
    }
    if !copyright.isEmpty {
      out.append(.init(id: "posts.copyright", severity: .error, title: "\(copyright.count) copyright problem(s)", detail: "Never retried automatically.",
                       where_: copyright.map { "post \($0.id) · \($0.platform.displayName) · \($0.state.rawValue): \($0.errorMessage ?? "")" },
                       fix: "Eric decides: Re-upload anyway / Skip platform / Accept (`djq copyright <post-id> reupload [version]|skip|accept`). Don't fight it."))
    }
    return out
  }

  func platformLimits() throws -> [DoctorFinding] {
    let settings = try store.settings()
    var w: [String] = []
    for v in try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND score IS NOT NULL") {
      for i in Validation.platformIssues(video: v, edit: try store.edit(videoId: v.id), settings: settings) {
        w.append("\(v.id) · \(v.tag): \(i.message)")
      }
    }
    guard !w.isEmpty else { return [] }
    return [.init(id: "platform.limits", severity: .warning, title: "Scored videos over a platform limit", detail: "They stay out of the queue until fixed.",
                  where_: w, fix: "Editor → Trim for <platform> (per-platform trim) or skip that platform for the video. Never auto-cut.")]
  }

  func engine() throws -> [DoctorFinding] {
    var out: [DoctorFinding] = []
    let installed = LaunchAgent.isInstalled(paths: store.paths)
    let loaded = agentLoaded()
    if !installed || !loaded {
      out.append(.init(id: "engine.launchAgent", severity: .warning, title: installed ? "LaunchAgent not loaded" : "LaunchAgent not installed",
                       detail: "Without it the engine only runs while the app is open.", where_: [store.paths.agentPlist.path],
                       fix: "Eric: `djq agent install --app ~/Applications/DJ\\ Queue.app --load` (or Settings → Start at login). Agents: ask Eric first."))
    }
    if let hb = try store.lastHeartbeat() {
      let age = store.clock.now.timeIntervalSince(hb.at)
      if age > 10 * 60 {
        out.append(.init(id: "engine.heartbeat", severity: age > 86400 ? .error : .warning, title: "Last engine heartbeat \(Int(age / 60)) min ago",
                         detail: "The engine ticks every minute while the Mac is awake.", where_: [store.paths.engineLog.path],
                         fix: "Open DJ Queue (or check the LaunchAgent); `djq tick` runs one tick by hand."))
      }
    } else {
      out.append(.init(id: "engine.heartbeat", severity: .warning, title: "The engine has never run", detail: "No heartbeats recorded.",
                       where_: [], fix: "Open DJ Queue or run `djq tick`."))
    }
    return out
  }

  func database() throws -> [DoctorFinding] {
    var out: [DoctorFinding] = []
    let ic = try store.db.integrityCheck()
    if ic != "ok" {
      out.append(.init(id: "db.integrity", severity: .error, title: "Database integrity check failed", detail: ic, where_: [store.paths.database.path],
                       fix: "Quit DJ Queue, copy the newest backup from _app/backups/ over queue.sqlite (keep the broken file aside), reopen."))
    }
    let dm = try store.dayMath()
    let latest = Backup.list(store.paths).first
    let day = latest.map { String($0.deletingPathExtension().lastPathComponent.dropFirst("queue-".count)) }
    let age = day.map { dm.days(from: $0, to: store.today(dm)) } ?? 0
    if latest == nil || age > 2 {
      out.append(.init(id: "db.backup", severity: .warning, title: latest == nil ? "No database backup yet" : "Last backup \(age) days old",
                       detail: "The engine backs up daily (keeps 14).", where_: [store.paths.backups.path], fix: "Run `djq tick` (backs up if today's is missing)."))
    }
    return out
  }

  func disk() throws -> [DoctorFinding] {
    let v = try store.paths.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let free = v.volumeAvailableCapacityForImportantUsage else { return [] }
    let gb = Double(free) / 1e9
    guard gb < 50 else { return [] }
    return [.init(id: "disk.free", severity: .warning, title: String(format: "%.0f GB free", gb), detail: "Below 50 GB; renders and clips are large.",
                  where_: [store.paths.root.path], fix: "Free space (empty Trash, move old raw footage off the Mac). Posted renders are kept by default; Settings → Cleanup can delete them after N days.")]
  }

  func tools() throws -> [DoctorFinding] {
    var out: [DoctorFinding] = []
    var versions: [String] = []
    for (name, path) in [("ffmpeg", Tools.ffmpeg), ("ffprobe", Tools.ffprobe)] {
      guard let path else {
        out.append(.init(id: "tools.ffmpeg", severity: .error, title: "\(name) not found", detail: "Needed for renders and checks.",
                         where_: ["/opt/homebrew/bin/\(name)"], fix: "Eric: `brew install ffmpeg`."))
        continue
      }
      let first = LaunchAgent.run(path, ["-version"]).output.split(separator: "\n").first.map(String.init) ?? "?"
      versions.append("\(path): \(first)")
    }
    if !versions.isEmpty {
      out.append(.init(id: "tools.versions", severity: .info, title: "Tool versions", detail: "", where_: versions, fix: "Nothing to do."))
    }
    return out
  }

  func timeZone() throws -> [DoctorFinding] {
    let s = try store.settings()
    let mac = TimeZone.current.identifier
    guard mac != s.timeZone else { return [] }
    return [.init(id: "system.timezone", severity: .warning, title: "Mac time zone is \(mac)", detail: "Slots are planned in \(s.timeZone).",
                  where_: [], fix: "Nothing breaks (slots stay in \(s.timeZone)); change Settings → Time zone only if Eric moved.")]
  }
}

// MARK: Postiz (round 6, docs/postiz.md)

extension Doctor {
  /// Every id the Postiz checks can report (skills/dj-queue-doctor/SKILL.md has the safe fix for each).
  public static let postizCheckIds = ["postiz.not_connected", "postiz.key_invalid", "postiz.mapping_missing",
                                      "postiz.sign_in", "postiz.stuck", "postiz.link_missing", "postiz.rate_limited",
                                      "postiz.fallback", "postiz.test_mode", "postiz.delete_pending", "postiz.create_unknown",
                                      "postiz.auto_retry"]

  /// Doctor never reaches Postiz except in `postizLive` mode.
  final class OfflinePostiz: PostizTransport, @unchecked Sendable {
    func send(_ request: PostizHTTPRequest) throws -> PostizHTTPResponse { throw PostizError.network("Doctor is offline") }
  }

  /// The Postiz publisher's health from stored state: settings, the "key saved?" answer, the 401 flag, the budget,
  /// the cached channel list and the jobs table. While every platform is Manual and nothing is open in Postiz, the
  /// Keychain isn't asked and the only finding is the `postiz.not_connected` info.
  func postiz() throws -> [DoctorFinding] {
    let settings = try store.settings()
    let pub = settings.publishing
    let used = pub.postizPlatforms
    let open = try store.openPostizJobs()
    let now = store.clock.now
    var out: [DoctorFinding] = []
    let s = { (n: Int) in n == 1 ? "" : "s" }

    let testOpen = open.filter(\.testMode)
    if pub.testMode || !testOpen.isEmpty {
      let detail = pub.testMode
        ? "Test run is on: TikTok → the TikTok inbox, YouTube → unlisted, Instagram, Facebook, Threads and X → Postiz drafts (nothing public until released)."
          + (testOpen.isEmpty ? "" : " \(testOpen.count) test post\(s(testOpen.count)) in Postiz now.")
        : "Test run is off, but \(testOpen.count) post\(s(testOpen.count)) made during a test run \(testOpen.count == 1 ? "is" : "are") still in Postiz (they keep their Test badge)."
      out.append(.init(id: "postiz.test_mode", severity: .info, title: pub.testMode ? "Postiz test run is on" : "Test-run posts still in Postiz",
                       detail: detail, where_: testOpen.map(\.postId),
                       fix: "When the test is done, Eric turns it off in Settings → Publishing (or `djq postiz test-mode off`). Posts already made keep their badge."))
    }

    guard !used.isEmpty || !open.isEmpty else {
      out.append(.init(id: "postiz.not_connected", severity: .info, title: "Postiz not in use",
                       detail: "Every platform is set to Manual: posts go to the Calendar and Eric marks them posted.", where_: [],
                       fix: "Nothing to do. To publish through Postiz, Eric adds the key and picks channels in Settings → Publishing."))
      return out + (try autoRetryFinding())
    }

    let hasKey = postizKeyStore.hasKey()
    var liveError: String?
    if postizLive, hasKey {
      let live = PostizService(store: store, transport: postizTransport, keyStore: postizKeyStore)
      do {
        // A stored "key refused" flag blocks ordinary calls: re-check the key first (a success clears the flag).
        if try store.postizKeyInvalid() != nil { _ = try live.checkConnection() }
        _ = try live.channels(refresh: true, settings: settings)
      } catch PostizError.unauthorized {
        // The service set the "key refused" flag; reported below.
      } catch PostizError.overBudget {
        // No call was made: the rate_limited finding below says why.
      } catch {
        liveError = "\(error)"
      }
    }
    let invalid = try store.postizKeyInvalid()
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    let router = PostizRouter(settings: settings, hasKey: hasKey, keyInvalid: invalid != nil, channels: cache?.integrations)
    let svc = PostizService(store: store, transport: OfflinePostiz(), keyStore: postizKeyStore)
    let names = used.map(\.displayName).joined(separator: ", ")
    let tag = { (id: String) in (try? self.store.video(id: id))?.tag ?? String(id.prefix(8)) }

    if !hasKey && !used.isEmpty {
      out.append(.init(id: "postiz.not_connected", severity: .warning, title: "Postiz isn't connected",
                       detail: "\(names) \(used.count == 1 ? "is" : "are") set to Postiz but no API key is saved, so their posts go to the Calendar (posted by hand).",
                       where_: used.map(\.rawValue),
                       fix: "Eric adds the Postiz API key in Settings → Publishing (agents never handle the key)."))
    } else if let liveError {
      out.append(.init(id: "postiz.not_connected", severity: .warning, title: "Postiz didn't answer the live check",
                       detail: liveError, where_: [pub.apiBase],
                       fix: "Check the network and Postiz's status, then `djq doctor --live` again. Posts Postiz already holds still go out."))
    }

    if let invalid {
      out.append(.init(id: "postiz.key_invalid", severity: .error, title: "Postiz refused the API key",
                       detail: "Since \(Sched.shortTime(invalid.at, settings)): \(invalid.message.isEmpty ? "401" : invalid.message). Posts set to Postiz go to the Calendar; DJ Queue re-checks the key hourly.",
                       where_: used.map(\.rawValue),
                       fix: "Eric saves a valid key again in Settings → Publishing (Postiz → Settings → Public API). Agents never handle the key."))
    }

    // Mapping: a Postiz platform needs a channel that is still in Postiz's list.
    let unmapped = used.compactMap { p -> (Platform, String)? in
      guard let id = pub.channels[p], !id.isEmpty else { return (p, "no channel picked") }
      if let cache, !cache.integrations.contains(where: { $0.id == id }) { return (p, "the picked channel isn't in Postiz any more") }
      return nil
    }
    if !unmapped.isEmpty {
      let soon = try store.posts(where: "scheduled_at<=? AND state IN ('planned','rendering','rendered','due')", [now.addingTimeInterval(48 * 3600)])
      let urgent = unmapped.contains { u in soon.contains { $0.platform == u.0 } }
      out.append(.init(id: "postiz.mapping_missing", severity: urgent ? .error : .warning,
                       title: "No Postiz channel for \(unmapped.map(\.0.displayName).joined(separator: ", "))",
                       detail: unmapped.map { "\($0.0.displayName): \($0.1)" }.joined(separator: " · ")
                         + (urgent ? ". Posts in the next 48 h go to the Calendar." : ". Their posts go to the Calendar until a channel is picked."),
                       where_: unmapped.map(\.0.rawValue),
                       fix: "`djq postiz map --dry-run` shows the auto-mapping by provider; Eric runs `djq postiz map` (or picks the channel in Settings → Publishing)."))
    }

    // Round 22: one item per platform whose channel needs signing in again. Its posts wait (never Manual) and go out by
    // themselves once it works.
    let signIn = try svc.signInProblems(router: router)
    if !signIn.isEmpty {
      out.append(.init(id: "postiz.sign_in", severity: .error,
                       title: signIn.map(\.title).joined(separator: " · "),
                       detail: signIn.map { "\($0.platform.displayName)\($0.channelName.map { " (\($0))" } ?? ""): \($0.waitingText)\($0.message.map { " · \($0)" } ?? "")" }
                         .joined(separator: " · ") + ". " + PostizSignInProblem.howItWorks,
                       where_: signIn.map(\.platform.rawValue),
                       fix: "Eric reconnects the channel in Postiz (Postiz → the channel → Reconnect). DJ Queue reads the channel list again within 30 minutes, or tries one post every 6 hours, and the waiting posts go out. Don't mark them Fixed or post them by hand (double post)."))
    }

    let stuck = try svc.stuckJobs()
    if !stuck.isEmpty {
      out.append(.init(id: "postiz.stuck", severity: .error, title: "\(stuck.count) Postiz post\(s(stuck.count)) still waiting an hour after the slot",
                       detail: stuck.map { "\($0.platform.displayName) · \(tag($0.videoId ?? "")) · slot \(Sched.shortTime($0.remoteDate, settings))" }.joined(separator: " · ")
                         + ". Postiz still reports them QUEUE.",
                       where_: stuck.map(\.postId),
                       fix: "`djq postiz sync` reads the states again. Then check the Postiz calendar: if Postiz can't post it, delete it there (DJ Queue then puts it on the Calendar). Never post it by hand while Postiz still holds it (double post)."))
    }

    let missing = try svc.linkMissingPosts()
    if !missing.isEmpty {
      out.append(.init(id: "postiz.link_missing", severity: .warning, title: "\(missing.count) post\(s(missing.count)) published without a link",
                       detail: "Postiz published \(missing.map { "\($0.platform.displayName) · \(tag($0.videoId))" }.joined(separator: ", ")) but the platform's post id came back missing.",
                       where_: missing.map(\.id),
                       fix: "`djq postiz link <post-id>` lists the platform's recent posts; `djq postiz link <post-id> <url>` records the right one."))
    }

    let budget = try store.postizBudget()
    let usedCalls = budget.used(now: now)
    // A create leaves one slot for sync, so a live check can be refused one call before the limit.
    if budget.isPaused(now: now) || usedCalls >= pub.hourlyBudget {
      out.append(.init(id: "postiz.rate_limited", severity: .info,
                       title: budget.isPaused(now: now) ? "Postiz calls paused after a rate limit" : "Postiz call budget used up this hour",
                       detail: (budget.isPaused(now: now) ? "Postiz answered 429; no calls until \(Sched.shortTime(budget.pausedUntil!, settings)). " : "")
                         + "\(usedCalls)/\(pub.hourlyBudget) calls in the last hour.",
                       where_: [], fix: "Nothing to do: calls resume by themselves (deletes first, then the soonest creates)."))
    }

    // Posts set to Postiz that Postiz won't deliver: they go to the Calendar.
    let upcoming = try store.posts(where: "scheduled_at<=? AND state IN ('planned','rendering','rendered','due','overdue')",
                                   [now.addingTimeInterval(7 * 86400)]).filter { used.contains($0.platform) }
    let fallen = try upcoming.compactMap { p -> (id: String, line: String)? in
      guard try !svc.deliversThroughPostiz(p, router: router) else { return nil }
      let why: String
      if let j = try store.finalPostizJob(postId: p.id) {
        switch j.closeReason {
        case .rejected?: why = PostizFallbackReason.createRejected(j.lastError ?? j.remoteError ?? "no details").message
        case .vanished?: why = PostizFallbackReason.vanished.message
        case .inbox?: why = "In the TikTok inbox (test run): finish it in the app, then Mark posted with the link"
        default: why = "Postiz closed it (\(j.closeReason?.rawValue ?? "?"))"
        }
      } else {
        why = router.route(p.platform).fallbackReason?.message ?? "not in Postiz"
      }
      return (p.id, "\(p.platform.displayName) · \(tag(p.videoId)) · \(Sched.shortTime(p.scheduledAt, settings)): \(why)")
    }
    if !fallen.isEmpty {
      out.append(.init(id: "postiz.fallback", severity: .warning, title: "\(fallen.count) post\(s(fallen.count)) fell back to Manual",
                       detail: "Set to Postiz, but these go to the Calendar to post by hand (next 7 days): "
                         + fallen.map(\.line).joined(separator: " · "), where_: fallen.map(\.id),
                       fix: "Fix the reason (key or channel: see the other postiz findings) and the next tick submits them. A refused, deleted or inbox post stays manual: post it from the Calendar and `djq posted <post> <url>`; `djq reset <post>` lets Postiz try a refused or deleted one again (Eric's call)."))
    }

    let unknown = open.filter(\.isUnconfirmed)
    if !unknown.isEmpty {
      out.append(.init(id: "postiz.create_unknown", severity: .error,
                       title: "\(unknown.count) Postiz create\(s(unknown.count)) with an unknown outcome",
                       detail: unknown.map { "\($0.platform.displayName) · \(tag($0.videoId ?? "")) · slot \(Sched.shortTime($0.remoteDate, settings))" }.joined(separator: " · ")
                         + ". The request was sent but no answer came back, and the sync couldn't tell whether Postiz has it. Nothing new is sent for these until it's settled.",
                       where_: unknown.map(\.postId),
                       fix: "Eric checks the Postiz calendar for that channel and time first, then answers: `djq postiz resolve <post-id> --in-postiz` (Postiz has it: never sent again) or `--not-in-postiz` (on the Calendar to post by hand). Never guess, and never post it by hand before that (double post)."))
    }

    let pending = open.filter { $0.phase == .deleting && $0.attempts >= 3 }
    if !pending.isEmpty {
      out.append(.init(id: "postiz.delete_pending", severity: .warning, title: "Couldn't remove \(pending.count) post\(s(pending.count)) from Postiz",
                       detail: pending.map { "\($0.platform.displayName) · \(tag($0.videoId ?? "")): \($0.lastError ?? "error")" }.joined(separator: " · "),
                       where_: pending.map(\.postId),
                       fix: "DJ Queue keeps retrying and creates nothing new for these meanwhile. If one must not post, Eric deletes it in the Postiz calendar."))
    }

    out += try autoRetryFinding()
    return out
  }

  /// Checked even with every platform on Manual: that's when a retry waits for its platform to come back.
  func autoRetryFinding() throws -> [DoctorFinding] {
    let svc = PostizService(store: store, transport: OfflinePostiz(), keyStore: postizKeyStore)
    let retries = try svc.pendingAutoRetries()
    guard !retries.isEmpty else { return [] }
    let tag = { (id: String) in (try? self.store.video(id: id))?.tag ?? String(id.prefix(8)) }
    let waitingOnSettings = retries.contains(where: \.offPostiz)
    let stubborn = try svc.keepsFailing()
    let settings = try store.settings()
    return [.init(id: "postiz.auto_retry", severity: waitingOnSettings || !stubborn.isEmpty ? .warning : .info,
                  title: "\(retries.count) automatic retr\(retries.count == 1 ? "y" : "ies") pending",
                  detail: retries.map { "\($0.post.platform.displayName) · \(tag($0.post.videoId)) · \($0.text)" }.joined(separator: " · ")
                    + ". Each keeps re-queuing until it goes out (no limit)."
                    + stubborn.map { " \($0.summary) (since \(Sched.shortTime($0.since, settings)))." }.joined(),
                  where_: retries.map(\.post.id),
                  fix: waitingOnSettings
                    ? "A retry waits for its platform to be back on Postiz: Eric sets that in Settings → Publishing, or posts it by hand and marks it posted. Don't change it for Eric."
                    : !stubborn.isEmpty
                      ? "One keeps failing with the same error for a week; it keeps retrying. Tell Eric the reason: the fix may be in the clip (editor) or in Postiz. Don't mark it Fixed or post it by hand while it retries (double post)."
                      : "Nothing to do: the post goes out again by itself, at the time shown.")]
  }
}

// MARK: Postiz helpers for `djq postiz` (CLI branch; they use the service's budgeted call path)

/// Caption `maxLength` per Postiz channel (`GET /integration-settings/{id}`), kept in kv a day per channel.
public struct PostizCaptionLimits: Codable, Sendable, Hashable {
  public struct Entry: Codable, Sendable, Hashable {
    public var maxLength: Int?
    public var fetchedAt: Date
  }
  public var entries: [String: Entry] = [:]
  public init() {}
  public static let kvKey = "postiz.captionLimits"
  public static let maxAge: TimeInterval = 86400
}

extension PostizService {
  /// Caption limits for `channels` (one budgeted call per channel not checked in the last day, or every one with
  /// `refresh`). Returns the limit per channel id (nil = Postiz didn't say) and, per channel, why it couldn't be
  /// read now (budget, network, …); a stopping error (key refused, rate limit, no budget) skips the rest.
  public func captionLimits(for channels: [PostizIntegration], refresh: Bool = false) throws
    -> (limits: [String: Int?], errors: [String: String]) {
    let settings = try store.settings()
    var cache: PostizCaptionLimits = try store.kv(PostizCaptionLimits.kvKey) ?? PostizCaptionLimits()
    var limits: [String: Int?] = [:], errors: [String: String] = [:]
    var stop: String?
    var fetched = false
    for c in channels {
      if !refresh, let e = cache.entries[c.id], now.timeIntervalSince(e.fetchedAt) < PostizCaptionLimits.maxAge {
        limits[c.id] = e.maxLength
        continue
      }
      if let stop { errors[c.id] = stop; continue }
      do {
        let r = try call(.sync, settings) { try client(settings).integrationSettings(c.id) }
        cache.entries[c.id] = .init(maxLength: r.maxLength, fetchedAt: now)
        limits[c.id] = r.maxLength
        fetched = true
      } catch {
        errors[c.id] = "\(error)"
        if Self.stops(error) { stop = "not checked: \(error)" }
      }
    }
    if fetched { try store.setKV(PostizCaptionLimits.kvKey, cache) }
    return (limits, errors)
  }

  /// Asks the engine (DJ Queue's, when it holds the engine lock) to run its sync step on the next tick, whatever the
  /// interval. Post `ChangeSignal` after it so the app ticks now.
  public func requestSync() throws { try store.setKV(Self.syncNowKey, true) }
}
