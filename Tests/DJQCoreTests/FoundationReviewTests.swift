import Foundation
import Testing
@testable import DJQCore

/// Regression tests for the foundation milestone review (reviews/foundation.md D1–D6, R1, R3, R5).
@Suite struct FoundationReviewTests {
  func makeReady(_ f: Fixture, _ id: String, text: String = "Yayo x Johnny") throws {
    var e = Edit()
    e.crop = CropRect(x: 1300, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: id)
    var v1 = Version(number: 1)
    v1.text = text
    v1.captionTemplateId = "set-link"
    try f.store.save(v1, videoId: id)
  }

  // D1
  @Test func relinkIntoAnotherSessionResolves() throws {
    let f = try Fixture()
    let other = f.paths.sessions.appendingPathComponent("2026-11-07 – Other Set")
    try FileManager.default.createDirectory(at: other.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    try Data(#"{"session":"2026-11-07 – Other Set","videos":[]}"#.utf8).write(to: other.appendingPathComponent("videos.json"))
    try f.intake()
    let src = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – bone shaker.mp4")
    try FileManager.default.moveItem(at: src, to: other.appendingPathComponent("Clips/moved.mp4"))
    let r1 = try f.intake()
    #expect(r1.relinked.count == 1)
    let v = try #require(try f.store.video(id: "clip-2"))
    let url = try #require(try f.store.fileURL(for: v))
    #expect(FileManager.default.fileExists(atPath: url.path))
    let r2 = try f.intake()
    #expect(r2.relinked.isEmpty)
    #expect(r2.untracked.isEmpty)
  }

  @Test func missingFileComesBack() throws {
    let f = try Fixture()
    try f.intake()
    let p = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – poosh 5.mp4")
    let tmp = f.dir.appendingPathComponent("hold.mp4")
    try FileManager.default.moveItem(at: p, to: tmp)
    try f.intake()
    #expect(try f.store.video(id: "clip-1")?.missing == true)
    try FileManager.default.moveItem(at: tmp, to: p)
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-1"))
    #expect(!v.missing)
    #expect(v.state == .needsEdit)
  }

  // D2
  @Test func partialJSONKeepsDefaultsAndData() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.db.run("INSERT INTO edits(video_id,json,updated_at) VALUES(?,?,?)",
                       ["clip-0", #"{"crop":{"x":1,"y":2,"w":3,"h":4}}"#, 0.0])
    let e = try f.store.edit(videoId: "clip-0")
    #expect(e.crop == CropRect(x: 1, y: 2, w: 3, h: 4))
    #expect(e.aspectOverride == nil)  // round 2: absent = follows the default (9:16)
    #expect(try f.store.resolvedEdit(videoId: "clip-0").aspect == .r9x16)
    try f.store.setKV("settings", ["postsPerDay": 3])
    let s = try f.store.settings()
    #expect(s.postsPerDay == 3)
    #expect(s.enabledPlatforms.count == 6)
  }

  @Test func settingsRoundTrip() throws {
    let f = try Fixture()
    var s = Settings()
    s.sortOverrides = [.x: .bestFirst]
    s.slotMinutes[.tiktok] = 20 * 60
    s.cleanup = .deleteAfter(days: 30)
    try f.store.save(s)
    #expect(try f.store.settings() == s)
  }

  // prefillRulesFileNotOverwritten was removed with Prefill (round 2 #9); scripts/prefill_titles.py only reads
  // its replacements file.

  // D3
  @Test func draftWeekIsNotPlanned() throws {
    let f = try Fixture()
    try f.intake()
    try makeReady(f, "clip-0")
    try f.store.save(Week(weekStart: "2026-11-02", state: .draft, approvedAt: nil))
    try f.store.save(PlanSlot(id: "s1", date: "2026-11-03", position: 0, videoId: "clip-0", pinned: false, weekStart: "2026-11-02"))
    try f.store.refreshState(videoId: "clip-0")
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
    try f.store.save(Week(weekStart: "2026-11-02", state: .approved, approvedAt: f.clock.now))
    try f.store.refreshState(videoId: "clip-0")
    #expect(try f.store.video(id: "clip-0")?.state == .planned)
  }

  // D4
  @Test func retrySupersedesFailedRegular() throws {
    let f = try Fixture()
    try f.intake()
    try makeReady(f, "clip-0")
    var s = Settings()
    s.enabledPlatforms = [.tiktok]
    try f.store.save(s)
    let now = f.clock.now
    func post(_ id: String, _ kind: PostKind, _ attempt: Int, _ state: PostState) -> PlatformPost {
      PlatformPost(id: id, videoId: "clip-0", platform: .tiktok, versionNo: 1, attemptNo: attempt, kind: kind, planSlotId: nil,
                   scheduledAt: now, renderId: nil, state: state, publisher: "manual", externalId: nil, url: nil, postedAt: nil,
                   errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now)
    }
    try f.store.save(post("p1", .regular, 1, .failed))
    try f.store.refreshState(videoId: "clip-0")
    #expect(try f.store.video(id: "clip-0")?.state == .partial)
    try f.store.save(post("p2", .retry, 2, .posted))
    try f.store.refreshState(videoId: "clip-0")
    #expect(try f.store.video(id: "clip-0")?.state == .posted)
  }

  // D5
  @Test func noTextOnV1DoesNotHideV2Text() {
    var v1 = Version(number: 1)
    v1.noText = true
    var v2 = Version(number: 2)
    v2.text = "Wait for the drop"
    let r2 = VersionResolver.resolve([v1, v2], number: 2, settings: Settings())
    #expect(r2.hasText)
    #expect(!r2.noText)
    var v3 = Version(number: 3)
    v3.caption = "new caption"
    let r3 = VersionResolver.resolve([v1, v2, v3], number: 3, settings: Settings())
    #expect(r3.text == "Wait for the drop")
    #expect(r3.inherited.contains("text"))
    var w2 = Version(number: 2)
    w2.text = "   "
    #expect(VersionResolver.resolve([v1, w2], number: 2, settings: Settings()).noText)
  }

  // D6
  @Test func overLimitCaptionAndTitleAreIssues() throws {
    let f = try Fixture()
    try f.intake()
    try makeReady(f, "clip-0")
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
    var v1 = try #require(try f.store.versions(videoId: "clip-0").first)
    v1.caption = String(repeating: "a", count: 400)
    try f.store.save(v1, videoId: "clip-0")
    let v = try #require(try f.store.video(id: "clip-0"))
    let issues = try Validation.issues(video: v, store: f.store)
    #expect(issues.contains { $0.kind == .captionTooLong && $0.platform == .x })
    #expect(v.state == .needsEdit)
  }

  @Test func longTitleKeepsSuffix() {
    var v1 = Version(number: 1)
    v1.text = String(repeating: "Very long song name ", count: 10)
    let r = VersionResolver.resolve([v1], number: 1, settings: Settings())
    let video = CaptionTests().video()
    let t = Captions.youtubeTitle(r, video: video)
    #expect(t.count <= 100)
    #expect(t.hasSuffix(" | DJ Lovd"))
  }

  // R1
  @Test func intakeAndRefreshDoNotClobberScore() throws {
    let f = try Fixture()
    try f.intake()
    let stale = try #require(try f.store.video(id: "clip-0"))
    try f.store.setScore("clip-0", 55)
    try f.store.saveIdentity(stale)  // an intake holding an older copy of the row
    try f.store.refreshState(videoId: "clip-0")
    #expect(try f.store.video(id: "clip-0")?.score == 55)
  }

  // R3
  @Test func sizeFollowsSymlinks() throws {
    let f = try Fixture()
    let target = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – poosh 5.mp4")
    let link = f.dir.appendingPathComponent("link.mp4")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(Intake.size(link) == Intake.size(target))
  }

  // R5 / Q15. Round 2 #9 removed the rotating per-video sub-set ("autoHashtagsVaryPerVideo"): every clip uses
  // exactly the chosen/default sets.
  @Test func defaultHashtagsAreTheSameForEveryVideo() {
    #expect(Captions.hashtags(VersionResolver.resolve([Version(number: 1)], number: 1, settings: Settings()),
                              sets: Defaults.legacyHashtagSets).isEmpty)  // round 7: none by default
    var s = Settings()
    s.defaults.hashtagSetIds = Defaults.legacyDefaultHashtagSetIds
    let r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s)
    let all = Set((0..<12).map { Captions.hashtags(r, sets: Defaults.legacyHashtagSets, videoId: "video-\($0)").joined(separator: " ") })
    #expect(all.count == 1)
    #expect(Captions.hashtags(r, sets: Defaults.legacyHashtagSets)
      == ["#amapiano", "#amapianomix", "#afrohouse", "#djlovd", "#dj", "#djlife", "#djmix", "#transition"])
    #expect(r.isDefault("hashtagSetIds"))
    var chosen = Version(number: 1)
    chosen.hashtagSetIds = ["afrobeats"]
    let rc = VersionResolver.resolve([chosen], number: 1, settings: Settings())
    #expect(Captions.hashtags(rc, sets: Defaults.legacyHashtagSets, videoId: "x") == ["#afrobeats", "#afrobeatsmix", "#naija", "#djlovd"])
  }

  @Test func corruptVersionRowThrows() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.db.run("INSERT INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,?)", ["clip-0", 1, "{ nope", 0.0])
    #expect(throws: StoreError.self) { try f.store.versions(videoId: "clip-0") }
    try f.store.refreshState(videoId: "clip-0")  // must not throw
    #expect(try f.intake().newVideos.isEmpty)    // intake keeps working
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(try Validation.issues(video: v, store: f.store).contains { $0.kind == .corrupt })
  }

  @Test func talkingContentTypeMapsToKind() throws {
    let f = try Fixture()
    f.entries[1]["content-type"] = "talking"
    try f.saveManifest()
    try f.intake()
    #expect(try f.store.video(id: "clip-0")?.kind == .talking)
  }

  @Test func nestedTransactionsRollBackInner() throws {
    let f = try Fixture()
    try f.store.db.transaction {
      try f.store.setKV("a", 1)
      _ = try? f.store.db.transaction { () throws -> Void in
        try f.store.setKV("b", 2)
        throw SQLiteError(code: 1, message: "boom", sql: nil)
      }
    }
    #expect(try f.store.kv("a", as: Int.self) == 1)
    #expect(try f.store.kv("b", as: Int.self) == nil)
  }

  /// Opt-in M2 acceptance on Eric's real session (read-only): DJQ_REAL=1 scripts/test.sh
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_REAL"] == "1"))
  func realAfroweenManifest() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-real-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let paths = Paths(root: home.appendingPathComponent("Movies/DJ Video"), appSupport: tmp, logs: tmp, launchAgents: tmp)
    let store = try Store(memoryWith: paths, clock: SystemClock())
    let r = try Intake(store: store).run()
    let vids = try store.videos()
    #expect(vids.filter { $0.type == .short }.count == 62)
    #expect(vids.filter { $0.type == .long }.count == 1)
    #expect(r.missing.isEmpty && r.parseErrors.isEmpty && r.duplicateIds.isEmpty)
  }
}
