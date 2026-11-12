import Foundation
import Testing
@testable import DJQCore

/// Round 27 (Eric, 2026-11-12): a new version is a complete copy of the one it came from, then its own. No edit to one
/// version ever changes another, and existing versions were separated without changing what any of them shows.
@Suite struct R27VersionCopyTests {
  private func layer(_ text: String, id: String, start: Double? = nil, end: Double? = nil) -> TextLayer {
    TextLayer(id: id, text: text, style: .outline, size: 70, posX: 0.5, posY: 0.3, start: start, end: end)
  }

  private func shows(_ f: Fixture, _ id: String, _ n: Int) throws -> ResolvedVersion { try shows(f.store, id, n) }

  private func shows(_ s: Store, _ id: String, _ n: Int) throws -> ResolvedVersion {
    VersionCopy.face(try #require(try s.resolvedVersion(videoId: id, number: n)))
  }

  /// Saves a version exactly as given, the way data from before round 27 is stored (no `standalone`).
  private func legacy(_ s: Store, _ v: Version, _ id: String) throws {
    try s.db.run("INSERT OR REPLACE INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,?)",
                       [id, v.number, JSONCoding.string(v), 1_700_000_000.0])
  }

  /// Eric's case: a text that runs the whole clip in v1 ran only a short window in the copy, because the copy's empty
  /// end fell through to v2's end.
  @Test func aWholeClipTextStaysWholeInTheCopy() throws {
    var v1 = Version(number: 1)
    v1.text = "Whole clip"
    v1.textStart = 0  // an end of nil = to the end of the clip
    v1.moreText = [layer("Also whole", id: "w")]
    var v2 = Version(number: 2)
    v2.textStart = 0
    v2.textEnd = 2
    v2.standalone = true
    let copy = VersionCopy.duplicate([v1, v2], source: 1, as: 3, settings: Settings())
    let r = VersionResolver.resolve([v1, v2, copy], number: 3, settings: Settings())
    #expect(r.textStart == 0 && r.textEnd == nil)
    #expect(r.moreText.map(\.text) == ["Also whole"] && r.moreText.first?.end == nil)
    #expect(VersionCopy.face(r).text == VersionCopy.face(VersionResolver.resolve([v1], number: 1, settings: Settings())).text)
  }

  @Test func aCopyIsCompleteAndThenIndependentBothWays() throws {
    let f = try Fixture.engine(1)
    var v1 = Version(number: 1)
    v1.text = "Hook"
    v1.style = .outline
    v1.textStart = 1
    v1.textEnd = 6
    v1.moreText = [layer("Second", id: "s1", start: 0, end: 4)]
    v1.textLook = TextLook(color: "#FF0000")
    v1.caption = "Caption one"
    v1.extraHashtags = ["#one"]
    v1.platformCaptions = [.tiktok: "TikTok own"]
    v1.youtubeTitle = "YT one"
    v1.repostReady = true
    try f.store.save(v1, videoId: "clip-0")
    let before = try shows(f, "clip-0", 1)

    let copy = VersionCopy.duplicate(try f.store.versions(videoId: "clip-0"), source: 1, as: 2, settings: try f.store.settings())
    try f.store.save(copy, videoId: "clip-0")
    var shown2 = try shows(f, "clip-0", 2)
    shown2.number = 1
    #expect(shown2 == before, "the copy shows everything v1 shows")
    let raw2 = try #require(try f.store.versions(videoId: "clip-0").first { $0.number == 2 })
    #expect(raw2.standalone == true && raw2.repostReady == nil && raw2.captionsOwn == nil)
    #expect(raw2.moreText?.map(\.id) != ["s1"], "copied texts get their own ids")

    // Editing v1 never reaches v2.
    let v2Before = try shows(f, "clip-0", 2)
    var e1 = try #require(try f.store.versions(videoId: "clip-0").first { $0.number == 1 })
    e1.text = "Changed"; e1.style = .box; e1.textEnd = 9; e1.caption = "Changed caption"; e1.extraHashtags = ["#two"]
    e1.moreText = [layer("Second changed", id: "s1", start: 2, end: 3)]; e1.textLook = TextLook(color: "#00FF00")
    e1.platformCaptions = nil; e1.youtubeTitle = nil
    try f.store.save(e1, videoId: "clip-0")
    #expect(try shows(f, "clip-0", 2) == v2Before)
    // And editing v2 never reaches v1.
    let v1Now = try shows(f, "clip-0", 1)
    var e2 = try #require(try f.store.versions(videoId: "clip-0").first { $0.number == 2 })
    e2.text = "Only v2"; e2.caption = "Only v2 caption"; e2.moreText = []
    try f.store.save(e2, videoId: "clip-0")
    #expect(try shows(f, "clip-0", 1) == v1Now)
  }

  @Test func whatTheSourceLeavesOnTheDefaultsStaysOnTheDefaults() throws {
    let v1 = Version(number: 1)
    let copy = VersionCopy.duplicate([v1], source: 1, as: 2, settings: Settings())
    #expect(copy.style == nil && copy.size == nil && copy.caption == nil && copy.textStart == nil && copy.moreText == nil)
    let r = VersionResolver.resolve([v1, copy], number: 2, settings: Settings())
    #expect(r.isDefault("style") && r.isDefault("caption") && r.inherited.isEmpty)
  }

  /// A path that writes a v2+ without the flag (an old journal, an older `djq` call) still gets a version that stands
  /// alone, holding what it showed.
  @Test func savingAVersionWithoutTheFlagSeparatesIt() throws {
    let f = try Fixture.engine(1)
    var v1 = Version(number: 1)
    v1.text = "Base"
    v1.caption = "Base caption"
    v1.style = .outline
    try f.store.save(v1, videoId: "clip-0")
    var v2 = Version(number: 2)
    v2.text = "Second"
    try f.store.save(v2, videoId: "clip-0")
    let raw = try #require(try f.store.versions(videoId: "clip-0").first { $0.number == 2 })
    #expect(raw.standalone == true && raw.caption == "Base caption" && raw.style == .outline && raw.text == "Second")
    v1.caption = "New base"
    try f.store.save(v1, videoId: "clip-0")
    #expect(try f.store.resolvedVersion(videoId: "clip-0", number: 2)?.caption == "Base caption")
  }

  @Test func bulkCaptionsOnV1LeaveStandaloneVersionsUntouched() throws {
    let f = try Fixture.engine(1)
    try f.store.save(CaptionTemplate(id: "plain", name: "Plain", template: "Plain {text}", sort: 9))
    let copy = VersionCopy.duplicate(try f.store.versions(videoId: "clip-0"), source: 1, as: 2, settings: try f.store.settings())
    try f.store.save(copy, videoId: "clip-0")
    let raw = try f.store.versions(videoId: "clip-0").first { $0.number == 2 }
    try BulkActions(store: f.store).setCaptionTemplate(["clip-0"], "plain")
    #expect(try f.store.versions(videoId: "clip-0").first { $0.number == 2 } == raw)
    #expect(try f.store.resolvedVersion(videoId: "clip-0", number: 2)?.captionTemplateId == "short")
  }

  // MARK: Schema 11

  @Test func schema11SeparatesOldVersionsWithoutChangingWhatTheyShow() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-r27-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                      logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let file = paths.appSupport.appendingPathComponent("queue.sqlite")
    var shownBefore: [Int: ResolvedVersion] = [:]
    var hashesBefore: [Int: String] = [:]
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      try s.save(Video(id: "a", sessionId: "s", name: "a", tags: ["a"], type: .short, contentType: "dj vid", kind: .djVid,
                       file: "a.mp4", fingerprint: "fp", fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27, start: 0,
                       end: 30, grace: 3, audio: nil, part: 1, score: 40, state: .needsEdit, excluded: false, missing: false,
                       inManifest: true, notes: "", alreadyPostedOn: [], longformURL: nil,
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                       title: "Title a"))
      var e = Edit()
      e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
      try s.save(e, videoId: "a")
      var v1 = Version(number: 1)
      v1.text = "One"
      v1.style = .outline
      v1.textStart = 0
      v1.moreText = [layer("Extra", id: "x1")]
      v1.textLook = TextLook(color: "#FF0000")
      v1.caption = "Cap one"
      v1.captionTemplateId = "short"
      try legacy(s, v1, "a")
      var v2 = Version(number: 2)
      v2.text = "Two"
      v2.textEnd = 5
      try legacy(s, v2, "a")
      try legacy(s, Version(number: 3), "a")  // followed v2 (and v1) entirely
      for n in 1...3 {
        shownBefore[n] = try shows(s, "a", n)
        hashesBefore[n] = try Renderer(store: s).editHash(videoId: "a", versionNo: n, platform: nil)
      }
      try s.db.exec("PRAGMA user_version = 10")
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == 11)
    let raw = try s.versions(videoId: "a")
    #expect(raw.filter { $0.number > 1 }.allSatisfy { $0.standalone == true })
    #expect(raw.first { $0.number == 1 }?.standalone == nil)
    for n in 1...3 {
      #expect(try shows(s, "a", n) == shownBefore[n], "v\(n) shows what it showed")
      #expect(try Renderer(store: s).editHash(videoId: "a", versionNo: n, platform: nil) == hashesBefore[n], "v\(n) needs no new render")
    }
    // Only the JSON changed: no preview redraw.
    #expect(try s.db.query("SELECT updated_at FROM versions WHERE video_id='a'").allSatisfy { $0.double("updated_at") == 1_700_000_000 })
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.filter { $0.hasPrefix("queue-before-schema11-") }.count == 1)
    // From now on v1 edits stay on v1.
    var e1 = try #require(raw.first { $0.number == 1 })
    e1.style = .box; e1.caption = "New cap"; e1.moreText = []
    try s.save(e1, videoId: "a")
    #expect(try shows(s, "a", 2) == shownBefore[2] && shows(s, "a", 3) == shownBefore[3])
    // One journaled batch, which undoes.
    let batch = try #require(try BulkActions(store: s).batches().first { $0.action == VersionSeparationMigration.action })
    try s.save(try #require(raw.first { $0.number == 1 }), videoId: "a")
    #expect(try BulkActions(store: s).undo(batch.id, force: true).changed == ["a"])
    #expect(try s.versions(videoId: "a").first { $0.number == 3 }?.standalone == nil)
    // Opening it again changes nothing and takes no second backup.
    _ = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    let again = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(again.filter { $0.hasPrefix("queue-before-schema11-") }.count == 1)
  }

  @Test func aClipWhoseVersionsWouldChangeIsLeftAsItWas() {
    // Separation that can't keep a version's face is refused (the migration then skips the clip).
    var v1 = Version(number: 1)
    v1.text = "One"
    let v2 = Version(number: 2)
    #expect(VersionCopy.separated([v1, v2], settings: Settings()) != nil)
    #expect(VersionCopy.separated([v1], settings: Settings()) == [])
  }
}

/// Runs only with `DJQ_R27_DB=<a copy of a real backup>`: schema 11 on that copy leaves every version of every clip
/// showing exactly what it showed, and every v2+ stands alone afterwards. The copy is migrated in place.
@Suite struct R27RealCopyTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_R27_DB"] != nil))
  func migratingACopyOfTheRealDatabaseChangesNothingShown() throws {
    let path = try #require(ProcessInfo.processInfo.environment["DJQ_R27_DB"])
    // Before: the stored versions exactly as they are, read without opening a Store (which would migrate).
    let raw = try SQLite(path: path)
    #expect(try raw.one("PRAGMA user_version")?.int("user_version") == 10)
    var before: [String: [Version]] = [:]
    for r in try raw.query("SELECT video_id, json FROM versions ORDER BY video_id, number") {
      let v = try JSONCoding.decoder.decode(Version.self, from: Data(try #require(r.string("json")).utf8))
      before[try #require(r.string("video_id")), default: []].append(v)
    }
    let updatedBefore = try raw.query("SELECT video_id||'#'||number AS k, updated_at FROM versions").map { "\($0.string("k") ?? "")=\($0.double("updated_at") ?? -1)" }.sorted()
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("home")
    let paths = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                      logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    let s = try Store(paths: paths, clock: SystemClock(), path: path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == 11)
    let settings = try s.settings()
    var versionsChecked = 0, multi = 0
    for (id, vs) in before {
      let video = try s.video(id: id)
      let after = try s.versions(videoId: id)
      if vs.contains(where: { $0.number > 1 }) { multi += 1 }
      for n in Set(vs.map(\.number)).union([1]) {
        let a = VersionCopy.face(VersionResolver.resolve(vs, number: n, settings: settings, video: video))
        let b = VersionCopy.face(VersionResolver.resolve(after, number: n, settings: settings, video: video))
        #expect(a == b, "\(id) v\(n) shows what it showed")
        versionsChecked += 1
      }
      #expect(after.filter { $0.number > 1 }.allSatisfy { $0.standalone == true }, "\(id): every v2+ stands alone")
      #expect(after.map(\.repostReady) == vs.map(\.repostReady), "\(id): Ready to repost marks unchanged")
    }
    let updatedAfter = try s.db.query("SELECT video_id||'#'||number AS k, updated_at FROM versions").map { "\($0.string("k") ?? "")=\($0.double("updated_at") ?? -1)" }.sorted()
    #expect(updatedAfter == updatedBefore, "no version's updated_at moved")
    print("r27-real-copy: \(versionsChecked) versions on \(before.count) clips checked, \(multi) clips with v2+")
  }
}
