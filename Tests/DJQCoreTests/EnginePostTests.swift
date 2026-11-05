import Foundation
import Testing
@testable import DJQCore

@Suite struct EnginePostTests {
  func approved(_ n: Int = 8, scores: [Int]? = nil, change: ((inout Settings) -> Void)? = nil) throws -> Fixture {
    let f = try Fixture.engine(n, scores: scores)
    if let change { try f.updateSettings(change) }
    try Planner(store: f.store).approveWeek(f.week)
    return f
  }

  @Test func markPostedValidatesURLAndDay() throws {
    let f = try approved()
    let a = PostActions(store: f.store)
    let tt = try #require(try f.post(.tiktok, day: "2026-11-02"))
    #expect(throws: EngineError("That link is on instagram.com, not TikTok (tiktok.com)")) {
      try a.markPosted(postId: tt.id, url: "https://instagram.com/reel/x")
    }
    #expect(throws: EngineError.self) { try a.markPosted(postId: tt.id, url: "not a url") }
    #expect(throws: EngineError.self) { try a.markPosted(postId: tt.id, url: "") }
    // Early posting is allowed any time on the day (09:00, slot 19:00).
    try a.markPosted(postId: tt.id, url: "https://vm.tiktok.com/ZM123/")
    let p = try #require(try f.store.post(id: tt.id))
    #expect(p.state == .posted && p.postedAt == f.clock.now && p.url == "https://vm.tiktok.com/ZM123/")
    // …but not a future day's post.
    let tue = try #require(try f.post(.tiktok, day: "2026-11-03"))
    #expect(throws: EngineError.self) { try a.markPosted(postId: tue.id, url: Fixture.postURLs[.tiktok]!) }
    #expect(try f.store.history(postId: tt.id).map(\.toState) == ["planned", "posted"])
  }

  @Test func failedFixedRetriesNextDayStaggered() throws {
    let f = try approved()
    let a = PostActions(store: f.store)
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    try a.reportProblem(postId: fb.id, type: .uploadFailed, message: "Upload stuck at 99%")
    #expect(try f.store.post(id: fb.id)?.state == .failed)
    #expect(try a.problems().map(\.id) == [fb.id])
    let r = try a.fixed(postId: fb.id)
    #expect(r.attemptNo == 2 && r.kind == .retry && r.versionNo == 1 && r.state == .planned)
    #expect(r.scheduledAt == f.at("2026-11-03", "15:30"))  // Tuesday 12:30 + 3 h
    #expect(try a.problems().isEmpty)
    #expect(try f.store.post(id: fb.id)?.state == .failed)  // history kept, not mutated back
    #expect(throws: EngineError.self) { try a.fixed(postId: fb.id) }  // already handled
  }

  @Test func retryStaggerGoesEarlierWhenItWouldCrossMidnight() throws {
    let f = try approved { $0.slotMinutes[.tiktok] = 22 * 60 + 30 }
    let a = PostActions(store: f.store)
    let tt = try #require(try f.post(.tiktok, day: "2026-11-02"))
    try a.reportProblem(postId: tt.id, type: .format, message: "Unsupported")
    let r = try a.fixed(postId: tt.id)
    #expect(r.scheduledAt == f.at("2026-11-03", "19:30"))
  }

  @Test func copyrightNeverAutoRetriesAndResolutions() throws {
    let f = try approved()
    let a = PostActions(store: f.store)
    let n = LogNotifier()
    let e = Engine(store: f.store, renderer: nil, publisher: nil, notifier: n).planFrozen
    f.setTime("2026-11-02", "19:05")
    e.tick(reason: "t")
    let tt = try #require(try f.post(.tiktok, day: "2026-11-02"))
    try a.reportProblem(postId: tt.id, type: .copyrightBlocked, message: "Blocked: music", raw: "{\"code\":\"copyright\"}")
    #expect(throws: EngineError.self) { try a.fixed(postId: tt.id) }
    for _ in 0..<3 { f.clock.advance(86400); e.tick(reason: "t") }
    #expect(try f.posts(.tiktok).filter { $0.videoId == "clip-0" }.count == 1)  // no auto-retry
    let loud = try #require(n.delivered.first { $0.key == "problem:\(tt.id)" })
    #expect(loud.critical && loud.title == "© Blocked on TikTok")
    #expect(try a.problems().contains { $0.id == tt.id })
    #expect(try f.store.post(id: tt.id)?.rawResponse == "{\"code\":\"copyright\"}")
    // Copyright on TikTok doesn't touch Instagram.
    #expect(try f.post(.instagram, day: "2026-11-02")?.errorType == nil)

    // Re-upload anyway → new attempt next day, staggered from that day's regular TikTok post.
    try a.resolveCopyright(postId: tt.id, .reuploadAnyway(versionNo: nil))
    let today = f.dm.key(f.clock.now)
    let re = try #require(try f.posts(.tiktok).first { $0.videoId == "clip-0" && $0.attemptNo == 2 })
    #expect(re.scheduledAt == f.dm.at(f.dm.addDays(today, 1), minutes: 22 * 60))
    #expect(try f.store.post(id: tt.id)?.resolution == "reuploaded")
    #expect(throws: EngineError("Add v3 first")) { try a.resolveCopyright(postId: tt.id, .reuploadAnyway(versionNo: 3)) }
    // A second hit is just recorded.
    try a.reportProblem(postId: re.id, type: .copyrightMuted, message: "Muted")
    e.tick(reason: "t")
    #expect(try f.posts(.tiktok).filter { $0.videoId == "clip-0" }.count == 2)
    try a.resolveCopyright(postId: re.id, .accept)
    #expect(try f.store.post(id: re.id)?.resolution == "accepted")
    #expect(try f.store.post(id: re.id)?.state == .copyrightMuted)
    // Skip platform.
    let ig = try #require(try f.post(.instagram, day: "2026-11-02"))
    try a.reportProblem(postId: ig.id, type: .removed, message: "Removed")
    try a.resolveCopyright(postId: ig.id, .skipPlatform)
    #expect(try f.store.post(id: ig.id)?.state == .skipped)
    #expect(try a.problems().filter { $0.state.isCopyright }.isEmpty)
  }

  @Test func repostNeedsNextVersionAndCooldown() throws {
    let f = try approved()
    let a = PostActions(store: f.store)
    let tt = try #require(try f.post(.tiktok, day: "2026-11-02"))
    try a.markPosted(postId: tt.id, url: Fixture.postURLs[.tiktok]!)
    #expect(throws: EngineError("Add v2 first")) { try a.repost(videoId: "clip-0", platform: .tiktok) }
    var v2 = Version(number: 2)
    v2.text = "Second hook"
    try f.store.save(v2, videoId: "clip-0")
    let r = try a.repost(videoId: "clip-0", platform: .tiktok)
    #expect(r.versionNo == 2 && r.kind == .repost && r.attemptNo == 2)
    #expect(r.scheduledAt == f.at("2026-11-16", "22:00"))  // 14 days later, 3 h after the 19:00 slot
    #expect(try f.store.video(id: "clip-0")?.state != .needsEdit)
    #expect(throws: EngineError.self) { try a.repost(videoId: "clip-7", platform: .tiktok) }  // never posted there
  }

  @Test func resetAndSkip() throws {
    let f = try approved()
    let a = PostActions(store: f.store)
    let x = try #require(try f.post(.x, day: "2026-11-02"))
    try a.markPosted(postId: x.id, url: Fixture.postURLs[.x]!)
    try a.reset(postId: x.id)
    let p = try #require(try f.store.post(id: x.id))
    #expect(p.state == .planned && p.url == nil && p.postedAt == nil)
    try a.skip(postId: x.id)
    #expect(try f.store.post(id: x.id)?.state == .skipped)
    #expect(throws: EngineError.self) { try a.skip(postId: x.id) }
  }

  @Test func todayListAndMetrics() throws {
    let f = try approved()
    let a = PostActions(store: f.store)
    #expect(try a.dueToday(now: f.clock.now).count == 6)
    let fb = try #require(try f.post(.facebook, day: "2026-11-02"))
    try a.setMetrics(postId: fb.id, PostMetrics(views: 1200, likes: 80))
    #expect(try f.store.post(id: fb.id)?.metrics?.views == 1200)
  }

  @Test func longformMarkPostedMovesFile() throws {
    let f = try Fixture.engine(2)
    let a = PostActions(store: f.store)
    #expect(throws: EngineError.self) { try a.markLongformPosted(videoId: "long-0001", url: "https://tiktok.com/x") }
    try a.markLongformPosted(videoId: "long-0001", url: "https://youtu.be/abc123")
    let v = try #require(try f.store.video(id: "long-0001"))
    #expect(v.longformURL == "https://youtu.be/abc123")
    #expect(v.state == .posted)
    #expect(v.file.hasPrefix("Posted/Longform/"))
    #expect(FileManager.default.fileExists(atPath: f.sessionDir.appendingPathComponent(v.file).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sessionDir.appendingPathComponent("Ready to Post/Longform").path).isEmpty)
    try f.intake()  // intake keeps the moved path (the manifest still says Ready to Post)
    #expect(try f.store.video(id: "long-0001")?.missing == false)
    #expect(throws: EngineError.self) { try a.markLongformPosted(videoId: "clip-0", url: "https://youtu.be/x") }
  }

  @Test func manualPublisherPreparesEverything() throws {
    let f = try approved()
    let fake = FakeRenderer(store: f.store)
    let pub = ManualPublisher(store: f.store, renderer: fake)
    let yt = try #require(try f.post(.youtube, day: "2026-11-02"))
    let p = try pub.prepare(postId: yt.id)
    #expect(p.platform == .youtube)
    #expect(p.title == "Text clip-0 | DJ Lovd")
    #expect(p.caption.hasPrefix("Text clip-0"))
    #expect(FileManager.default.fileExists(atPath: p.fileURL.path))
    #expect(p.coverURL != nil)
    #expect(p.uploadURL == Platform.youtube.uploadURL)
    #expect(try pub.submit(p) == .waitingForUser)
    let x = try #require(try f.post(.x, day: "2026-11-02"))
    #expect(try pub.prepare(postId: x.id).title == nil)
    #expect(fake.renderCount == 1)  // shared render
  }
}

@Suite struct EngineDoctorTests {
  @Test func findsMissingFileAndOverduePost() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let e = Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier()).planFrozen
    e.tick(reason: "t")
    try FileManager.default.removeItem(at: f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – song7 x mix7.mp4"))
    try FileManager.default.createDirectory(at: f.sessionDir.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: f.sessionDir.appendingPathComponent("Clips/stray.mp4"))
    f.setTime("2026-11-04", "10:00")
    e.tick(reason: "t")
    let d = Doctor(store: f.store)
    d.agentLoaded = { false }
    d.probeDurations = false
    let r = d.run()
    let ids = Set(r.findings.map(\.id))
    #expect(ids.isSuperset(of: ["files.missing", "posts.overdue", "files.untracked", "engine.launchAgent", "capcut.markers"]))
    let missing = try #require(r.findings.first { $0.id == "files.missing" })
    #expect(missing.severity == .error && missing.where_.contains { $0.hasPrefix("clip-7") })
    #expect(r.findings.first { $0.id == "posts.overdue" }?.where_.count == 6)
    #expect(r.passed.contains("db"))
    #expect(r.findings.first?.severity == .error)  // errors first
    let md = Doctor.markdown(r)
    #expect(md.contains("# DJ Queue Doctor report"))
    #expect(md.contains("`files.missing`") && md.contains("fix:"))
    let json = try JSONEncoder().encode(r)
    #expect(String(decoding: json, as: UTF8.self).contains("\"where\""))
  }

  @Test func launchAgentPlistWithoutLaunchctl() throws {
    let f = try Fixture.engine(1)
    let home = f.dir.appendingPathComponent("home")
    let app = home.appendingPathComponent("Applications/Fake.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try LaunchAgent.install(appPath: app.path, paths: f.paths, load: false, environment: [:], home: home.path)
    let d = try #require(NSDictionary(contentsOf: f.paths.agentPlist))
    #expect(d["Label"] as? String == "com.djlovd.queue.engine")
    let args = try #require(d["ProgramArguments"] as? [String])
    #expect(args.last == "--agent" && args.first?.hasSuffix("Fake.app/Contents/MacOS/Fake") == true)
    #expect(d["RunAtLoad"] as? Bool == true && d["KeepAlive"] as? Bool == true)
    try LaunchAgent.uninstall(paths: f.paths)
    #expect(!LaunchAgent.isInstalled(paths: f.paths))
  }

  @Test func launchAgentRefusesDevEnvironmentAndForeignApps() throws {
    let f = try Fixture.engine(1)
    let home = f.dir.appendingPathComponent("home")
    let app = home.appendingPathComponent("Applications/DJ Queue.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    for env in [["DJQ_HOME": "/tmp/x"], ["DJQ_ROOT": "/tmp/y"]] {
      #expect(throws: EngineError.self) {
        try LaunchAgent.install(appPath: app.path, paths: f.paths, load: false, environment: env, home: home.path)
      }
    }
    for bad in ["/Applications/DJ Queue.app", f.dir.appendingPathComponent("build/DJ Queue.app").path,
                home.appendingPathComponent("Applications/../Desktop/DJ Queue.app").path] {
      #expect(throws: EngineError.self) {
        try LaunchAgent.install(appPath: bad, paths: f.paths, load: false, environment: [:], home: home.path)
      }
    }
    #expect(!LaunchAgent.isInstalled(paths: f.paths))
  }

  @Test func engineLockIsExclusive() throws {
    let f = try Fixture.engine(1)
    let a = try #require(EngineLock.acquire(f.paths))
    #expect(EngineLock.acquire(f.paths) == nil)
    #expect(EngineLock.isHeld(f.paths))
    a.release()
    #expect(!EngineLock.isHeld(f.paths))
    let b = EngineLock.acquire(f.paths)
    #expect(b != nil)
    #expect(EngineLock.url(f.paths).lastPathComponent == "engine.lock")
  }

  @Test func backupDailyKeeps14() throws {
    let f = try Fixture.engine(1)
    for i in 0..<16 {
      f.setTime(f.dm.addDays("2026-11-02", i), "09:00")
      #expect(try Backup.runIfDue(store: f.store) != nil)
      #expect(try Backup.runIfDue(store: f.store) == nil)  // once a day
    }
    let list = Backup.list(f.paths)
    #expect(list.count == 14)
    #expect(list.first?.lastPathComponent == "queue-2026-11-17.sqlite")
  }
}

@Suite struct EngineSkillTests {
  /// Milestone 6 acceptance: every Doctor finding id has a fix in the skill.
  @Test func everyDoctorIdHasAFixInTheSkill() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let doctor = try String(contentsOf: repo.appendingPathComponent("Sources/DJQCore/Engine/Doctor.swift"), encoding: .utf8)
    let skill = try String(contentsOf: repo.appendingPathComponent("skills/dj-queue-doctor/SKILL.md"), encoding: .utf8)
    let re = try NSRegularExpression(pattern: #"id: "([A-Za-z.]+)""#)
    let ids = Set(re.matches(in: doctor, range: NSRange(doctor.startIndex..., in: doctor)).map {
      String(doctor[Range($0.range(at: 1), in: doctor)!])
    })
    #expect(ids.count >= 25)
    for id in ids { #expect(skill.contains("`\(id)`"), "\(id) missing from SKILL.md") }
    #expect(skill.hasPrefix("---\nname: dj-queue-doctor\ndescription: "))
  }
}
