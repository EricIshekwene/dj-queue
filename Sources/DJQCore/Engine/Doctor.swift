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
    check("files.relinked", relinked)
    check("files.duration", durations)
    check("plan.notReady", notReadyButPlanned)
    check("plan.gaps", planGaps)
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

  func missingFiles() throws -> [DoctorFinding] {
    let vids = try store.videos(where: "missing=1")
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
      guard let v = try store.video(id: id), !v.missing, let url = try store.fileURL(for: v) else { continue }
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
                  where_: w, fix: "Finish the edit in the app (crop, text or No text, caption), or remove/swap the slot in the Week view.")]
  }

  func planGaps() throws -> [DoctorFinding] {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let today = store.today(dm)
    let thisWeek = dm.weekStart(of: store.clock.now)
    var w: [String] = []
    for week in [thisWeek, dm.addDays(thisWeek, 7)] where try store.week(week)?.state == .approved {
      for day in dm.weekDays(week) where day >= today {
        let n = try store.planSlots(where: "date=?", [day]).count
        if n < settings.postsPerDay { w.append("\(day): \(n)/\(settings.postsPerDay) posts") }
      }
    }
    guard !w.isEmpty else { return [] }
    return [.init(id: "plan.gaps", severity: .warning, title: "Gaps in the approved week", detail: "Days with fewer posts than posts/day.",
                  where_: w, fix: "Pin a clip from the Queue to the day (Week view, or `djq pin <video-id> <YYYY-MM-DD>`), or Rebuild week and approve again.")]
  }

  func runway() throws -> [DoctorFinding] {
    let s = try store.settings()
    let r = try Queue(store: store).runway()
    var out: [DoctorFinding] = []
    if r.approvedDays < s.approvedRunwayAlertDays {
      out.append(.init(id: "runway.approved", severity: .warning, title: "Approved runway \(r.approvedDays) day(s)", detail: "Below the \(s.approvedRunwayAlertDays)-day threshold.",
                       where_: [], fix: "Approve next week (`djq week --approve <monday>`), after checking the proposal."))
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
      if let path = r?.outputPath, r?.deletedAt == nil, FileManager.default.fileExists(atPath: path) { continue }
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
                  fix: "In Today/notification: Post now, Shift plan (into today's slot) or Skip. If it was actually posted, `djq posted <post-id> <url>`.")]
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
                                      "postiz.channel_disabled", "postiz.stuck", "postiz.link_missing", "postiz.rate_limited",
                                      "postiz.fallback", "postiz.test_mode", "postiz.delete_pending"]

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
                       detail: "Every platform is set to Manual: posts go to Today and Eric marks them posted.", where_: [],
                       fix: "Nothing to do. To publish through Postiz, Eric adds the key and picks channels in Settings → Publishing."))
      return out
    }

    let hasKey = postizKeyStore.hasKey()
    var liveError: String?
    if postizLive, hasKey {
      let live = PostizService(store: store, transport: postizTransport, keyStore: postizKeyStore)
      do { _ = try live.channels(refresh: true, settings: settings) } catch PostizError.unauthorized {
        // The service set the "key refused" flag; reported below.
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
                       detail: "\(names) \(used.count == 1 ? "is" : "are") set to Postiz but no API key is saved, so their posts go to Today (posted by hand).",
                       where_: used.map(\.rawValue),
                       fix: "Eric adds the Postiz API key in Settings → Publishing (agents never handle the key)."))
    } else if let liveError {
      out.append(.init(id: "postiz.not_connected", severity: .warning, title: "Postiz didn't answer the live check",
                       detail: liveError, where_: [pub.apiBase],
                       fix: "Check the network and Postiz's status, then `djq doctor --live` again. Posts Postiz already holds still go out."))
    }

    if let invalid {
      out.append(.init(id: "postiz.key_invalid", severity: .error, title: "Postiz refused the API key",
                       detail: "Since \(Sched.shortTime(invalid.at, settings)): \(invalid.message.isEmpty ? "401" : invalid.message). Posts set to Postiz go to Today; DJ Queue re-checks the key hourly.",
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
                         + (urgent ? ". Posts in the next 48 h go to Today." : ". Their posts go to Today until a channel is picked."),
                       where_: unmapped.map(\.0.rawValue),
                       fix: "`djq postiz map --dry-run` shows the auto-mapping by provider; Eric runs `djq postiz map` (or picks the channel in Settings → Publishing)."))
    }

    let disabled = used.compactMap { p -> (Platform, String)? in
      guard let id = pub.channels[p], let c = cache?.integrations.first(where: { $0.id == id }), c.disabled else { return nil }
      return (p, c.name)
    }
    if !disabled.isEmpty {
      out.append(.init(id: "postiz.channel_disabled", severity: .error, title: "Postiz channel disabled or expired",
                       detail: disabled.map { "\($0.0.displayName): \($0.1)" }.joined(separator: " · ") + ". Its posts go to Today until it's reconnected.",
                       where_: disabled.map(\.0.rawValue),
                       fix: "Eric reconnects the channel in Postiz (Postiz → the channel → Reconnect); then `djq postiz channels` refreshes the list."))
    }

    let stuck = try svc.stuckJobs()
    if !stuck.isEmpty {
      out.append(.init(id: "postiz.stuck", severity: .error, title: "\(stuck.count) Postiz post\(s(stuck.count)) still waiting an hour after the slot",
                       detail: stuck.map { "\($0.platform.displayName) · \(tag($0.videoId ?? "")) · slot \(Sched.shortTime($0.remoteDate, settings))" }.joined(separator: " · ")
                         + ". Postiz still reports them QUEUE.",
                       where_: stuck.map(\.postId),
                       fix: "`djq postiz sync` reads the states again. Then check the Postiz calendar: if Postiz can't post it, delete it there (DJ Queue then puts it on Today). Never post it by hand while Postiz still holds it (double post)."))
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
    if budget.isPaused(now: now) || usedCalls >= pub.hourlyBudget {
      out.append(.init(id: "postiz.rate_limited", severity: .info,
                       title: budget.isPaused(now: now) ? "Postiz calls paused after a rate limit" : "Postiz call budget used up this hour",
                       detail: (budget.isPaused(now: now) ? "Postiz answered 429; no calls until \(Sched.shortTime(budget.pausedUntil!, settings)). " : "")
                         + "\(usedCalls)/\(pub.hourlyBudget) calls in the last hour.",
                       where_: [], fix: "Nothing to do: calls resume by themselves (deletes first, then the soonest creates)."))
    }

    // Posts set to Postiz that Postiz won't deliver: they go to Today.
    let upcoming = try store.posts(where: "scheduled_at<=? AND state IN ('planned','rendering','rendered','due','overdue')",
                                   [now.addingTimeInterval(7 * 86400)]).filter { used.contains($0.platform) }
    let fallen = try upcoming.compactMap { p -> String? in
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
      return "post \(String(p.id.prefix(8))) · \(p.platform.displayName) · \(tag(p.videoId)) · \(Sched.shortTime(p.scheduledAt, settings)): \(why)"
    }
    if !fallen.isEmpty {
      out.append(.init(id: "postiz.fallback", severity: .warning, title: "\(fallen.count) post\(s(fallen.count)) fell back to Manual",
                       detail: "Set to Postiz, but these go to Today to post by hand (next 7 days).", where_: fallen,
                       fix: "Fix the reason (key or channel: see the other postiz findings) and the next tick submits them. A refused, deleted or inbox post stays manual: post it from Today and `djq posted <post> <url>`; `djq reset <post>` lets Postiz try a refused or deleted one again (Eric's call)."))
    }

    let pending = open.filter { $0.phase == .deleting && $0.attempts >= 3 }
    if !pending.isEmpty {
      out.append(.init(id: "postiz.delete_pending", severity: .warning, title: "Couldn't remove \(pending.count) post\(s(pending.count)) from Postiz",
                       detail: pending.map { "\($0.platform.displayName) · \(tag($0.videoId ?? "")): \($0.lastError ?? "error")" }.joined(separator: " · "),
                       where_: pending.map(\.postId),
                       fix: "DJ Queue keeps retrying and creates nothing new for these meanwhile. If one must not post, Eric deletes it in the Postiz calendar."))
    }
    return out
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
