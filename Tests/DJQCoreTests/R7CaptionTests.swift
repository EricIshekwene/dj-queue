import Foundation
import Testing
@testable import DJQCore

/// Round 7: Eric's own hashtag groups (none by default), WYSIWYG captions, YouTube title templates, issue → section.
@Suite struct R7CaptionTests {
  // MARK: Schema 6 migration

  /// A file database as rounds 1–6 left it: the six built-in groups, defaults amapiano + dj, written captions without
  /// {hashtags}, one clip with planned posts.
  func legacyDatabase() throws -> (Fixture, String) {
    let f = try Fixture()
    try FileManager.default.createDirectory(at: f.paths.appSupport, withIntermediateDirectories: true)
    let file = f.paths.appSupport.appendingPathComponent("queue.sqlite").path
    let s = try Store(paths: f.paths, clock: f.clock, path: file)
    try Intake(store: s).run()
    for g in Defaults.legacyHashtagSets { try s.save(g) }
    try s.save(HashtagSet(id: "mine", name: "Mine", category: "Mine", tags: ["#mine"], sort: 0))
    var st = Settings()
    st.defaults.hashtagSetIds = Defaults.legacyDefaultHashtagSetIds
    try s.save(st)
    // clip-0: posts planned; v1 written caption without {hashtags}; v2 chooses its own groups.
    var a1 = Version(number: 1); a1.text = "Yayo x Johnny"; a1.caption = "Written by Eric  "
    var a2 = Version(number: 2); a2.hashtagSetIds = ["amapiano-sa", "mine"]; a2.extraHashtags = ["#extra", "#logdrum"]
    try s.save(a1, videoId: "clip-0"); try s.save(a2, videoId: "clip-0")
    // clip-2: posted; follows the default groups and template; a per-platform caption for X.
    var c1 = Version(number: 1); c1.platformCaptions = [.x: "own X caption"]
    try s.save(c1, videoId: "clip-2")
    // clip-1: no posts; built-in + own group; whitespace-only caption (= no caption).
    var b1 = Version(number: 1); b1.hashtagSetIds = ["afrobeats", "mine"]; b1.caption = "\t"
    try s.save(b1, videoId: "clip-1")
    // clip-3: no posts; a written caption with {hashtags}.
    var d1 = Version(number: 1); d1.caption = "{hashtags} first"
    try s.save(d1, videoId: "clip-3")
    let now = f.clock.now.timeIntervalSince1970
    for (i, (vid, state, ver)) in [("clip-0", "planned", 1), ("clip-0", "rendered", 2), ("clip-2", "posted", 1),
                                   ("clip-1", "skipped", 1), ("clip-3", "copyright_muted", 1)].enumerated() {
      try s.db.run("""
        INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
        VALUES(?,?,?,?,1,'regular',?,?,'manual',?,?)
        """, ["p\(i)", vid, Platform.allCases[i % Platform.allCases.count].rawValue, ver, now, state, now, now])
    }
    for v in try s.videos() { try s.refreshState(videoId: v.id) }
    try s.db.exec("PRAGMA user_version = 5")
    return (f, file)
  }

  struct Out: Equatable { var captions: [String]; var tags: [String]; var title: String }

  func outputs(_ s: Store, _ vid: String, legacy: Bool, settings: Settings? = nil, sets: [HashtagSet]? = nil) throws -> [Out] {
    let st = try settings ?? s.settings(), gs = try sets ?? s.hashtagSets(), tpl = try s.captionTemplates()
    let v = try #require(try s.video(id: vid))
    let vs = try s.versions(videoId: vid)
    return Set(vs.map(\.number) + [1]).sorted().map { n in
      let r = VersionResolver.resolve(vs.isEmpty ? [Version(number: 1)] : vs, number: n, settings: st, video: v)
      let caps = Platform.allCases.map { p in
        legacy ? HashtagGroupsMigration.legacyCaption(p, r, v, "2026-10-23 – Afroween Jazz Piano", gs, tpl, st)
          : Captions.caption(for: p, version: r, video: v, sessionName: "2026-10-23 – Afroween Jazz Piano", sets: gs,
                             templates: tpl, settings: st)
      }
      return Out(captions: caps, tags: Captions.hashtags(r, sets: gs), title: Captions.youtubeTitle(r, video: v, settings: st))
    }
  }

  @Test func migrationKeepsPostClipsByteIdenticalAndDropsBuiltIns() throws {
    let (f2, file2) = try legacyDatabase()
    var beforeOut: [String: [Out]] = [:]
    let raw = try SQLite(path: file2)
    let beforeRows = try raw.query("SELECT id, score, title, state FROM videos ORDER BY id").map {
      "\($0.string("id")!)|\($0.int("score") ?? -1)|\($0.string("title") ?? "")|\($0.string("state")!)"
    }
    for vid in ["clip-0", "clip-1", "clip-2", "clip-3"] { beforeOut[vid] = try legacyOutputs(raw, vid) }
    // Migrate (open with this build).
    let s = try Store(paths: f2.paths, clock: f2.clock, path: file2)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == 6)
    // Clips with posts in flight or posted: byte-identical captions on every platform, same YouTube tags and title.
    for vid in ["clip-0", "clip-2", "clip-3"] {
      #expect(try outputs(s, vid, legacy: false) == beforeOut[vid], "\(vid)")
    }
    let a2 = try #require(try s.versions(videoId: "clip-0").first { $0.number == 2 })
    #expect(a2.hashtagSetIds == [] && a2.extraHashtags == ["#amapianosa", "#yanos", "#logdrum", "#privateschoolpiano", "#mine", "#extra"])
    // Other clips lose only the built-in groups; Eric's own stay.
    let b1 = try #require(try s.versions(videoId: "clip-1").first)
    #expect(b1.hashtagSetIds == ["mine"] && b1.caption == "\t")
    #expect(try outputs(s, "clip-1", legacy: false).first?.tags == ["#mine"])
    // clip-3 went out (copyright muted, review L2): frozen too, so its {hashtags} caption keeps the default tags.
    #expect(try outputs(s, "clip-3", legacy: false) == beforeOut["clip-3"])
    #expect(try outputs(s, "clip-3", legacy: false).first?.captions.first?.hasSuffix(" first") == true)
    #expect(try s.hashtagSets().map(\.id) == ["mine"])
    #expect(try s.settings().defaults.hashtagSetIds.isEmpty)
    // Counts, scores, titles, states unchanged.
    #expect(try s.db.query("SELECT id, score, title, state FROM videos ORDER BY id").map {
      "\($0.string("id")!)|\($0.int("score") ?? -1)|\($0.string("title") ?? "")|\($0.string("state")!)"
    } == beforeRows)
    // One journaled batch; undo restores the groups, the defaults and the versions (outputs as before).
    let b = BulkActions(store: s)
    let batch = try #require(try b.batches().first { $0.action == "hashtag-groups-migration" })
    let u = try b.undo(batch.id)
    #expect(u.skipped.isEmpty)
    #expect(Set(try s.hashtagSets().map(\.id)) == Set(Defaults.legacyHashtagSets.map(\.id) + ["mine"]))
    #expect(try s.settings().defaults.hashtagSetIds == Defaults.legacyDefaultHashtagSetIds)
    for vid in ["clip-0", "clip-1", "clip-2", "clip-3"] {
      #expect(try outputs(s, vid, legacy: false) == beforeOut[vid], "undo \(vid)")
    }
    #expect(beforeOut["clip-0"]?.first?.captions.first?.hasSuffix("#amapiano #amapianomix #afrohouse #djlovd #dj #djlife #djmix #transition") == true)
    let backups = try FileManager.default.contentsOfDirectory(atPath: f2.paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema6-") })
  }

  /// Old-rule outputs read straight from a schema-5 file (no migration).
  func legacyOutputs(_ db: SQLite, _ vid: String) throws -> [Out] {
    let settingsJSON = try db.one("SELECT json FROM kv WHERE key='settings'")?.string("json") ?? "{}"
    var st = Store.decodeSettings(settingsJSON)
    if st.defaults.hashtagSetIds.isEmpty { st.defaults.hashtagSetIds = Defaults.legacyDefaultHashtagSetIds }
    let sets = try db.query("SELECT * FROM hashtag_sets ORDER BY category, sort, name").map {
      HashtagSet(id: $0.string("id")!, name: $0.string("name")!, category: $0.string("category")!,
                 tags: $0.json("tags") ?? [], sort: $0.int("sort") ?? 0)
    }
    let tpl = try db.query("SELECT * FROM caption_templates ORDER BY sort, name").map {
      CaptionTemplate(id: $0.string("id")!, name: $0.string("name")!, template: $0.string("template")!, sort: $0.int("sort") ?? 0)
    }
    let vs = try db.query("SELECT json FROM versions WHERE video_id=? ORDER BY number", [vid]).map {
      try JSONCoding.decoder.decode(Version.self, from: Data($0.string("json")!.utf8))
    }
    let row = try #require(try db.one("SELECT * FROM videos WHERE id=?", [vid]))
    let v = Store.video(row)
    return Set(vs.map(\.number) + [1]).sorted().map { n in
      let r = VersionResolver.resolve(vs.isEmpty ? [Version(number: 1)] : vs, number: n, settings: st, video: v)
      let caps = Platform.allCases.map {
        HashtagGroupsMigration.legacyCaption($0, r, v, "2026-10-23 – Afroween Jazz Piano", sets, tpl, st)
      }
      return Out(captions: caps, tags: Captions.hashtags(r, sets: sets), title: Captions.youtubeTitle(r, video: v, settings: st))
    }
  }

  @Test func newDatabaseHasNoGroupsAndNoDefaultHashtags() throws {
    let f = try Fixture()
    try f.intake()
    #expect(try f.store.hashtagSets().isEmpty)
    #expect(try f.store.settings().defaults.hashtagSetIds.isEmpty)
    #expect(try BulkActions(store: f.store).batches().isEmpty)
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.hashtags(r, sets: try f.store.hashtagSets()).isEmpty)
  }

  // MARK: WYSIWYG captions

  @Test func writtenCaptionIsLiteral() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.save(HashtagSet(id: "g", name: "G", category: "G", tags: ["#a", "#b"], sort: 0))
    let v = try #require(try f.store.video(id: "clip-0"))
    var ver = Version(number: 1); ver.caption = "Just this"; ver.hashtagSetIds = ["g"]
    let r = VersionResolver.resolve([ver], number: 1, settings: Settings(), video: v)
    let c = Captions.caption(for: .tiktok, version: r, video: v, sessionName: "s", sets: try f.store.hashtagSets(),
                             templates: Defaults.captionTemplates, settings: Settings())
    #expect(c == "Just this")  // nothing appended (round 7)
    ver.caption = "Line\n{hashtags}"
    let r2 = VersionResolver.resolve([ver], number: 1, settings: Settings(), video: v)
    #expect(Captions.caption(for: .tiktok, version: r2, video: v, sessionName: "s", sets: try f.store.hashtagSets(),
                             templates: Defaults.captionTemplates, settings: Settings()) == "Line\n#a #b")
  }

  @Test func replaceHashtagsInPlace() {
    let t = "Hook line\n\nFull set on YouTube\n#a #b #c"
    #expect(Captions.replaceHashtags(in: t, old: ["#a", "#b", "#c"], new: ["#a", "#b", "#c", "#d"]) == "Hook line\n\nFull set on YouTube\n#a #b #c #d")
    #expect(Captions.replaceHashtags(in: t, old: ["#a", "#b", "#c"], new: ["#c"]) == "Hook line\n\nFull set on YouTube\n#c")
    #expect(Captions.replaceHashtags(in: t, old: ["#a", "#b", "#c"], new: []) == "Hook line\n\nFull set on YouTube")
    // No duplicates: a tag Eric typed elsewhere isn't added again.
    #expect(Captions.replaceHashtags(in: "Love #d here\n#a", old: ["#a"], new: ["#a", "#d"]) == "Love #d here\n#a")
    // Hand-edited order: token by token; new ones go to the last hashtag line.
    #expect(Captions.replaceHashtags(in: "Text\n#c #a", old: ["#a", "#c"], new: ["#a", "#e"]) == "Text\n#a #e")
    // Nothing yet: a new line at the end.
    #expect(Captions.replaceHashtags(in: "Text", old: [], new: ["#x", "#y"]) == "Text\n#x #y")
    // Whole tags only: #amapiano never matches inside #amapianomix.
    #expect(Captions.replaceHashtags(in: "T #amapianomix #amapiano", old: ["#amapiano", "#zz"], new: ["#zz"]) == "T #amapianomix\n#zz")
    // Case and order of the rest of the text are kept.
    #expect(Captions.replaceHashtags(in: "A\n#One #two\nB", old: ["#one", "#two"], new: ["#two"]) == "A\n#two\nB")
  }

  @Test func bulkHashtagChangeRetagsWrittenCaption() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.save(HashtagSet(id: "g", name: "G", category: "G", tags: ["#g1", "#g2"], sort: 0))
    var ver = Version(number: 1); ver.caption = "Mine\n#old"; ver.extraHashtags = ["#old"]
    try f.store.save(ver, videoId: "clip-0")
    let b = BulkActions(store: f.store)
    try b.setHashtagSets(["clip-0"], ["g"])
    #expect(try f.store.versions(videoId: "clip-0").first?.caption == "Mine\n#g1 #g2 #old")
    try b.setExtraHashtags(["clip-0"], [])
    #expect(try f.store.versions(videoId: "clip-0").first?.caption == "Mine\n#g1 #g2")
  }

  @Test func withoutHashtagsOnALiteralCaption() throws {
    let f = try Fixture()
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-0"))
    var ver = Version(number: 1); ver.caption = "Body text\n#a #b"; ver.extraHashtags = ["#a", "#b"]
    let r = VersionResolver.resolve([ver], number: 1, settings: Settings(), video: v)
    #expect(Captions.withoutHashtags(for: .x, version: r, video: v, sessionName: "s", templates: Defaults.captionTemplates,
                                     settings: Settings()) == "Body text")
  }

  /// Review M1: "Drop hashtags" also drops hashtags typed by hand, and "has hashtags to drop" reads the caption text.
  @Test func dropHashtagsIncludesTypedTags() throws {
    let f = try Fixture()
    try f.intake()
    var e = Edit(); e.crop = CropRect(x: 0, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    let v = try #require(try f.store.video(id: "clip-0"))
    let long = String(repeating: "That log drum switch gets me every time. ", count: 7)
    // Typed tags only, no groups.
    var ver = Version(number: 1); ver.text = "T"; ver.caption = long + "\n#amapiano #piano #mine"
    try f.store.save(ver, videoId: "clip-0")
    var r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.withoutHashtags(for: .x, version: r, video: v, sessionName: "s", templates: Defaults.captionTemplates,
                                     settings: Settings()) == long.trimmingCharacters(in: .whitespaces))
    let issue = try #require(try Validation.issues(video: v, store: f.store).first { $0.kind == .captionTooLong && $0.platform == .x })
    #expect(issue.countWithoutHashtags == long.trimmingCharacters(in: .whitespaces).count)
    // A group plus a typed #mine: both go.
    try f.store.save(HashtagSet(id: "g", name: "Piano", category: "G", tags: ["#amapiano", "#piano"], sort: 0))
    ver.hashtagSetIds = ["g"]
    try f.store.save(ver, videoId: "clip-0")
    r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    let bare = Captions.withoutHashtags(for: .x, version: r, video: v, sessionName: "s", templates: Defaults.captionTemplates,
                                        settings: Settings(), sets: try f.store.hashtagSets())
    #expect(!bare.contains("#") && bare == long.trimmingCharacters(in: .whitespaces))
    try BulkActions(store: f.store).dropHashtags(["clip-0"], platform: .x)
    #expect(try f.store.versions(videoId: "clip-0").first?.platformCaptions?[.x] == bare)
    // A template caption with a hashtag typed into the template counts too.
    #expect(Captions.stripTags("Hook\n\n#a #b") == "Hook")
  }

  /// Review L1: removing a tags-only last line leaves no trailing newline.
  @Test func removingTheLastTagLineLeavesNoTrailingNewline() {
    #expect(Captions.replaceHashtags(in: "Line one\n\n#amapiano #piano", old: ["#amapiano", "#piano"], new: []) == "Line one")
    #expect(Captions.replaceHashtags(in: "Line one\n#a\n", old: ["#a"], new: []) == "Line one")
    #expect(Captions.replaceHashtags(in: "A\n#a\nB", old: ["#a"], new: []) == "A\nB")
  }

  /// Review C7: help, usage and unknown commands never open (or create, or migrate) a database.
  @Test func djqHelpNeverOpensTheDatabase() throws {
    guard let bin = R6PostizCLITests.binary else { Issue.record("djq isn't built"); return }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("djq-help-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for args in [[], ["--help"], ["help"], ["-h"], ["postiz", "--help"], ["postiz"], ["postiz", "help"], ["caption", "--help"],
                 ["bulk", "--help"], ["hashtag-groups", "-h"], ["no-such-command"]] {
      let p = Process()
      p.executableURL = bin
      p.arguments = args
      var env = ProcessInfo.processInfo.environment
      env["DJQ_HOME"] = home.path
      env["DJQ_ROOT"] = home.appendingPathComponent("DJ Video").path
      env["DJQ_POSTIZ_OFFLINE"] = "1"; env["DJQ_NO_SIGNAL"] = "1"
      p.environment = env
      p.standardOutput = Pipe(); p.standardError = Pipe()
      try p.run(); p.waitUntilExit()
      #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("support/queue.sqlite").path), "djq \(args)")
    }
  }

  // MARK: YouTube title templates

  @Test func youtubeTitleTemplatesPickAndTypedTitleWins() throws {
    let f = try Fixture()
    try f.intake()
    var s = try f.store.settings()
    #expect(s.youtubeTitleTemplates.map(\.template) == ["{text} | DJ Lovd"])
    s.youtubeTitleTemplates.append(TitleTemplate(id: "live", name: "Live", template: "{text} (live) | DJ Lovd"))
    try f.store.save(s)
    let v = try #require(try f.store.video(id: "clip-0"))
    var ver = Version(number: 1); ver.text = "Yayo x Johnny"
    try f.store.save(ver, videoId: "clip-0")
    let b = BulkActions(store: f.store)
    try b.setYouTubeTitleTemplate(["clip-0"], "live")
    var r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.youtubeTitle(r, video: v, settings: try f.store.settings()) == "Yayo x Johnny (live) | DJ Lovd")
    #expect(!r.isDefault("youtubeTitleTemplateId"))
    // A typed title stays as typed whatever the template.
    ver = try #require(try f.store.versions(videoId: "clip-0").first); ver.youtubeTitle = "My own"
    try f.store.save(ver, videoId: "clip-0")
    r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.youtubeTitle(r, video: v, settings: try f.store.settings()) == "My own")
    // A deleted template falls back to the default one.
    s = try f.store.settings(); s.youtubeTitleTemplates.removeAll { $0.id == "live" }; try f.store.save(s)
    ver.youtubeTitle = nil; try f.store.save(ver, videoId: "clip-0")
    r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.youtubeTitle(r, video: v, settings: try f.store.settings()) == "Yayo x Johnny | DJ Lovd")
    #expect(throws: EngineError.self) { try b.setYouTubeTitleTemplate(["clip-0"], "nope") }
  }

  @Test func oldSettingsRowSeedsTheTitleTemplateList() throws {
    let s = Store.decodeSettings(#"{"defaults":{"youtubeTitleTemplate":"DJ Lovd — {text}"}}"#)
    #expect(s.youtubeTitleTemplates.count == 1 && s.youtubeTitleTemplates[0].template == "DJ Lovd — {text}")
    #expect(s.youtubeTitleTemplate(id: nil) == "DJ Lovd — {text}")
    // Saving keeps the legacy field in step with the default template (older builds and rollbacks read it).
    let f = try Fixture()
    var st = Settings()
    st.youtubeTitleTemplates = [TitleTemplate(id: "text-djlovd", name: "x", template: "{text} · DJ Lovd")]
    try f.store.save(st)
    #expect(try f.store.settings().defaults.youtubeTitleTemplate == "{text} · DJ Lovd")
  }

  // MARK: djq

  @Test func djqHashtagGroupsTitleTemplatesAndYouTubeTitle() throws {
    let env = try R6PostizCLITests.Env(clips: 1)
    #expect(try env.djq("hashtag-groups").out.contains("no hashtag groups yet"))
    let add = try env.djq("hashtag-groups", "add", "Piano", "#amapiano piano")
    #expect(add.status == 0, "\(add.err)")
    #expect(try env.store.hashtagSets().map(\.tags) == [["#amapiano", "#piano"]])
    let gid = try #require(try env.store.hashtagSets().first?.id)
    #expect(try env.djq("bulk", "hashtags", gid, "--ids", "clip-0").status == 0)
    var r = try #require(try env.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(Captions.hashtags(r, sets: try env.store.hashtagSets()) == ["#amapiano", "#piano"])
    #expect(try env.djq("title-templates", "add", "Live", "{text} (live) | DJ Lovd").status == 0)
    #expect(try env.djq("youtube-title", "clip-0", "--template", "Live").out.contains("Text clip-0 (live) | DJ Lovd"))
    #expect(try env.djq("youtube-title", "clip-0", "My typed title").out.contains("My typed title"))
    r = try #require(try env.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(r.youtubeTitle == "My typed title")
    // Deleting a group is one undoable batch.
    let del = try env.djq("hashtag-groups", "delete", "Piano")
    #expect(del.status == 0)
    #expect(try env.store.hashtagSets().isEmpty)
    let batch = try #require(del.out.components(separatedBy: "djq bulk undo ").last?.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(try env.djq("bulk", "undo", batch).status == 0)
    #expect(try env.store.hashtagSets().map(\.name) == ["Piano"])
    #expect(try env.djq("title-templates", "delete", "text-djlovd").status != 0)  // the default can't go
  }

  // MARK: C1 — issue → editor section

  @Test func everyIssueKindMapsDeliberately() {
    for k in ValidationIssue.Kind.allCases {
      let s = k.editorSection
      switch k {
      case .noCrop: #expect(s == .frame)
      case .noText: #expect(s == .text)
      case .noTitle: #expect(s == .title)
      case .tooLong, .tooLarge: #expect(s == .platforms)
      case .noCaption, .captionTooLong, .titleTooLong: #expect(s == .caption)
      case .missingFile, .corrupt, .heldInEdit: #expect(s == nil)
      }
    }
  }
}
