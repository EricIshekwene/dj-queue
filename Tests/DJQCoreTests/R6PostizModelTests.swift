import Foundation
import Testing
@testable import DJQCore

/// Round 6, milestone 1: settings, limits, schema v5, key store, client, router, payload, cover meaning, F5.
@Suite struct R6PostizModelTests {
  // MARK: Settings

  @Test func settingsWithoutPublishingDecodeToManualDefaults() throws {
    let f = try Fixture()
    // A pre-round-6 row: no "publishing", no "limitsRevision".
    var obj = try #require(try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(Settings())) as? [String: Any])
    obj.removeValue(forKey: "publishing")
    obj.removeValue(forKey: "limitsRevision")
    obj["postsPerDay"] = 2
    try f.store.db.run("INSERT OR REPLACE INTO kv(key,json) VALUES('settings',?)",
                       [String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)])
    let s = try f.store.settings()
    #expect(s.postsPerDay == 2)  // decoded, not fallen back to defaults
    #expect(s.publishing == PublishingSettings())
    #expect(Platform.allCases.allSatisfy { s.publishing.publisher(for: $0) == .manual })
    #expect(s.publishing.tiktok.method == .directPost && s.publishing.tiktok.duet && !s.publishing.tiktok.brandContent)
    #expect(s.publishing.youtube.visibility == .public && !s.publishing.youtube.madeForKids)
    #expect(s.publishing.instagram.postType == "post" && !s.publishing.instagram.trialReel)
    #expect(s.publishing.x.whoCanReply == .everyone && !s.publishing.testMode && s.publishing.hourlyBudget == 25)
  }

  @Test func publishingRoundTripsAndBadFieldsKeepTheirDefaults() throws {
    let f = try Fixture()
    try f.updateSettings {
      $0.postsPerDay = 2
      $0.publishing.publishers = [.tiktok: .postiz, .youtube: .postiz]
      $0.publishing.channels = [.tiktok: "ch-1"]
      $0.publishing.testMode = true
      $0.publishing.youtube.visibility = .unlisted
      $0.publishing.tiktok.method = .upload
    }
    let s = try f.store.settings()
    #expect(s.publishing.publisher(for: .tiktok) == .postiz && s.publishing.publisher(for: .x) == .manual)
    #expect(s.publishing.channels[.tiktok] == "ch-1" && s.publishing.testMode && s.publishing.youtube.visibility == .unlisted)
    #expect(s.publishing.postizPlatforms == [.youtube, .tiktok])
    // Stored JSON is readable (string keys) and never holds a key.
    let raw = try #require(try f.store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json"))
    #expect(raw.contains("\"publishers\":{\"tiktok\":\"postiz\",\"youtube\":\"postiz\"}"))
    // Hand-edited garbage in one field never sends Settings back to defaults.
    var obj = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    obj["publishing"] = ["publishers": ["tiktok": "carrier-pigeon", "x": "postiz", "nope": "postiz"], "testMode": "yes",
                         "youtube": ["visibility": "secret"], "tiktok": 42, "hourlyBudget": -3, "channels": ["x": ""]]
    try f.store.db.run("UPDATE kv SET json=? WHERE key='settings'",
                       [String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)])
    let g = try f.store.settings()
    #expect(g.postsPerDay == 2)
    #expect(g.publishing.publishers == [.x: .postiz])
    #expect(!g.publishing.testMode && g.publishing.youtube.visibility == .public && g.publishing.tiktok == TikTokOptions())
    #expect(g.publishing.hourlyBudget == PublishingSettings.minimumBudget && g.publishing.channels.isEmpty)
  }

  @Test func wrongTypedPublishingOrRevisionKeepsEveryOtherSetting() throws {
    let f = try Fixture()
    for (k, v) in [("publishing", NSNull() as Any), ("publishing", "postiz" as Any), ("publishing", [1, 2] as Any),
                   ("limitsRevision", "two" as Any), ("limitsRevision", true as Any)] {
      var obj = try #require(try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(Settings())) as? [String: Any])
      obj["postsPerDay"] = 3
      obj[k] = v
      try f.store.db.run("INSERT OR REPLACE INTO kv(key,json) VALUES('settings',?)",
                         [String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)])
      let s = try f.store.settings()
      #expect(s.postsPerDay == 3, "\(k) = \(v) reset Settings")
      #expect(s.publishing == PublishingSettings())
    }
    // http:// never carries the key; a tiny budget is raised to the minimum.
    let p = try JSONCoding.decoder.decode(PublishingSettings.self,
                                          from: Data("{\"apiBase\":\"http://postiz.example/api/public/v1\",\"hourlyBudget\":2}".utf8))
    #expect(p.apiBase == PublishingSettings.cloudAPIBase && p.hourlyBudget == PublishingSettings.minimumBudget)
  }

  // MARK: Limits

  @Test func limitsMigrateOnlyWhereTheyStillEqualTheOldDefaults() throws {
    #expect(PlatformLimits.defaults[.tiktok]?.captionLimit == 2200 && PlatformLimits.defaults[.tiktok]?.titleLimit == 90)
    #expect(PlatformLimits.defaults[.instagram]?.maxBytes == 300_000_000)
    let f = try Fixture()
    func store(_ limits: [Platform: PlatformLimits], revision: Int?) throws {
      var s = Settings()
      s.limits = limits
      var obj = try #require(try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(s)) as? [String: Any])
      if let revision { obj["limitsRevision"] = revision } else { obj.removeValue(forKey: "limitsRevision") }
      try f.store.db.run("INSERT OR REPLACE INTO kv(key,json) VALUES('settings',?)",
                         [String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)])
    }
    // Old defaults everywhere → new defaults.
    try store(PlatformLimits.revision1.merging(PlatformLimits.defaults) { a, _ in a }, revision: nil)
    var s = try f.store.settings()
    #expect(s.limits == PlatformLimits.defaults && s.limitsRevision == PlatformLimits.revision)
    // Eric's own values stay: TikTok caption 3000, Instagram 1 GB; untouched fields still move.
    var mine = PlatformLimits.revision1.merging(PlatformLimits.defaults) { a, _ in a }
    mine[.tiktok]!.captionLimit = 3000
    mine[.instagram]!.maxBytes = 1_000_000_000
    mine[.x]!.captionLimit = 4000
    try store(mine, revision: nil)
    s = try f.store.settings()
    #expect(s.limits[.tiktok]?.captionLimit == 3000 && s.limits[.tiktok]?.titleLimit == 90)
    #expect(s.limits[.instagram]?.maxBytes == 1_000_000_000 && s.limits[.x]?.captionLimit == 4000)
    // Saved once at revision 2, an explicit 4000 is Eric's choice and is never "migrated" again.
    var t = s
    t.limits[.tiktok]!.captionLimit = 4000
    try f.store.save(t)
    #expect(try f.store.settings().limits[.tiktok]?.captionLimit == 4000)
  }

  // MARK: Schema v5

  @Test func schemaV5AddsJobsAndMediaAdditively() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-v5-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                      logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let file = paths.appSupport.appendingPathComponent("queue.sqlite")
    var before: [String] = []
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      try s.save(Video(id: "a", sessionId: "s", name: "a", tags: ["a"], type: .short, contentType: "dj vid", kind: .djVid,
                       file: "a.mp4", fingerprint: nil, fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27, start: 0,
                       end: 30, grace: 3, audio: nil, part: 1, score: 42, state: .ready, excluded: false, missing: false,
                       inManifest: true, notes: "n", alreadyPostedOn: [], longformURL: nil, createdAt: Date(), updatedAt: Date(),
                       title: "T"))
      try s.db.exec("DROP TABLE postiz_jobs; DROP TABLE postiz_media; PRAGMA user_version = 4")
      before = try s.db.query("SELECT * FROM videos").map { "\($0.string("id")!)|\($0.int("score")!)|\($0.string("title")!)" }
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == 5)
    #expect(try s.db.query("SELECT * FROM videos").map { "\($0.string("id")!)|\($0.int("score")!)|\($0.string("title")!)" } == before)
    #expect(try s.openPostizJobs().isEmpty)
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema5-") })
  }

  func job(_ f: Fixture, post: String, hash: String = "h1") -> PostizJob {
    PostizJob(postId: post, videoId: "clip-0", platform: .tiktok, integrationId: "ch-tiktok", renderId: "r1", contentHash: hash,
              scheduledAt: f.clock.now, remoteDate: f.clock.now, testMode: false, postType: "schedule",
              createdAt: f.clock.now, updatedAt: f.clock.now)
  }

  @Test func oneLiveJobPerPostAndJobsOutliveTheirPost() throws {
    let f = try Fixture()
    let a = job(f, post: "post-1")
    #expect(try f.store.claimPostizJob(a))
    #expect(try !f.store.claimPostizJob(job(f, post: "post-1", hash: "h2")))  // second live job refused
    // Even a raw insert can't get past the unique index.
    #expect(throws: (any Error).self) {
      try f.store.db.run("INSERT INTO postiz_jobs(id,post_id,platform,integration_id,phase,content_hash,scheduled_at,remote_date,created_at,updated_at) VALUES('x','post-1','x','c','live','h',0,0,0,0)")
    }
    var live = try #require(try f.store.livePostizJob(postId: "post-1"))
    live.phase = .live
    live.postizId = "p9"
    try f.store.save(live)
    #expect(try f.store.postizJob(id: a.id)?.postizId == "p9")
    try f.store.closePostizJob(id: a.id, reason: .replaced)
    #expect(try f.store.livePostizJob(postId: "post-1") == nil && f.store.finalPostizJob(postId: "post-1") == nil)
    #expect(try f.store.claimPostizJob(job(f, post: "post-1", hash: "h2")))  // free again after the close
    // Final reasons block resubmission until a reset releases the releasable ones.
    let b = try #require(try f.store.livePostizJob(postId: "post-1"))
    try f.store.closePostizJob(id: b.id, reason: .error)
    #expect(try f.store.finalPostizJob(postId: "post-1")?.id == b.id)
    try f.store.releasePostizJobs(postId: "post-1")
    #expect(try f.store.finalPostizJob(postId: "post-1") == nil)
    var touched = try #require(try f.store.postizJob(id: b.id))
    touched.syncedAt = f.clock.now
    try f.store.save(touched)  // a later save never undoes the release
    #expect(try f.store.finalPostizJob(postId: "post-1") == nil)
    let c = job(f, post: "post-2")
    try f.store.claimPostizJob(c)
    try f.store.closePostizJob(id: c.id, reason: .published)
    try f.store.releasePostizJobs(postId: "post-2")
    #expect(try f.store.finalPostizJob(postId: "post-2")?.closeReason == .published)  // never released
    #expect(try f.store.setPostizKeyInvalid("401") && !f.store.setPostizKeyInvalid("401"))
    // Media cache.
    try f.store.save(PostizMediaRecord(renderId: "r1", kind: "video", mediaId: "m1", mediaPath: "/u/m1", fileSize: 6, uploadedAt: f.clock.now))
    #expect(try f.store.postizMedia(renderId: "r1", kind: "video")?.mediaId == "m1")
    #expect(try f.store.postizMedia(renderId: "r1", kind: "cover") == nil)
  }

  // MARK: Key store

  @Test func keychainStoreUsesSecurityWithTheKeyOnlyOnStdin() throws {
    var calls: [(String, [String], String?)] = []
    var stored: String?
    let ks = KeychainPostizKeyStore { tool, args, stdin in
      calls.append((tool, args, stdin.map { String(decoding: $0, as: UTF8.self) }))
      if args == ["-i"] { stored = "k"; return (0, Data()) }
      if args.first == "find-generic-password" {
        guard stored != nil else { return (44, Data()) }
        return (0, args.last == "-w" ? Data("secret-value\n".utf8) : Data("attributes".utf8))
      }
      return (0, Data())
    }
    #expect(!ks.hasKey())
    #expect(try ks.read() == nil)
    try ks.save("  abcDEF123_-.  ")
    #expect(ks.hasKey())
    #expect(try ks.read() == "secret-value")
    let save = try #require(calls.first { $0.1 == ["-i"] })
    #expect(save.0 == "/usr/bin/security")
    #expect(save.2 == "add-generic-password -U -s \"DJ Queue Postiz\" -a \"postiz\" -l \"DJ Queue Postiz\" -w \"abcDEF123_-.\"\n")
    #expect(calls.allSatisfy { !$0.1.joined().contains("abcDEF") })  // never in argv
    #expect(calls.contains { $0.1 == ["find-generic-password", "-s", "DJ Queue Postiz", "-a", "postiz"] })  // hasKey: no -w
    for bad in ["", "two words", "quo\"te", "back\\slash", "line\nbreak", "émoji"] {
      #expect(throws: PostizKeyError.self) { try ks.save(bad) }
    }
    try ks.delete()
    #expect(calls.last?.1 == ["delete-generic-password", "-s", "DJ Queue Postiz", "-a", "postiz"])
  }

  @Test func keychainKillSwitchStopsEverything() throws {
    _ = try Fixture()
    try #require(PostizLive.disabled)  // set by Fixture
    // No test ever holds a store wired to the real /usr/bin/security: a recording runner stands in, and it must
    // never run while the switch is off.
    var ran: [[String]] = []
    let ks = KeychainPostizKeyStore(runner: { _, args, _ in ran.append(args); return (0, Data("x".utf8)) }, obeysKillSwitch: true)
    #expect(try !ks.hasKey() && ks.read() == nil)
    #expect(throws: PostizKeyError.self) { try ks.save("abc") }
    #expect(throws: PostizKeyError.self) { try ks.delete() }
    #expect(ran.isEmpty)
  }

  @Test func scratchHomesStayOfflineUnlessExplicitlyLive() {
    #expect(!PostizLive.offByEnvironment([:]))  // the installed app / djq on Eric's real data
    #expect(PostizLive.offByEnvironment(["DJQ_POSTIZ_OFFLINE": "1"]))
    #expect(PostizLive.offByEnvironment(["DJQ_HOME": "/tmp/scratch"]))
    #expect(PostizLive.offByEnvironment(["DJQ_ROOT": "/tmp/dev/DJ Video"]))
    #expect(!PostizLive.offByEnvironment(["DJQ_HOME": "/tmp/scratch", "DJQ_POSTIZ_LIVE": "1"]))
    #expect(PostizLive.offByEnvironment(["DJQ_HOME": "/tmp/scratch", "DJQ_POSTIZ_LIVE": "1", "DJQ_POSTIZ_OFFLINE": "1"]))
    #expect(PostizLive.offByEnvironment(["DJQ_HOME": ""]))  // set (even empty) = scratch, as Paths reads it
  }

  @Test func keychainReadSeparatesNotFoundFromLockedOrDenied() throws {
    var status: Int32 = 44
    let ks = KeychainPostizKeyStore { _, _, _ in (status, Data()) }
    #expect(try ks.read() == nil)
    status = 36  // locked
    #expect(throws: PostizKeyError.self) { try ks.read() }
  }

  // MARK: Client

  @Test func clientSendsTheRawKeyAndMapsErrors() throws {
    _ = try Fixture()
    let fake = FakePostiz()
    let c = PostizClient(transport: fake, key: { "test-key-123" })
    #expect(try c.isConnected())
    let req = try #require(fake.requests.last)
    #expect(req.headers["Authorization"] == "test-key-123")  // no "Bearer"
    #expect(req.url.absoluteString == "https://api.postiz.com/public/v1/is-connected")
    #expect(req.redactedDescription.contains("Authorization: <redacted>") && !req.redactedDescription.contains("test-key"))
    var dumped = ""
    dump(req, to: &dumped)
    for text in ["\(req)", String(describing: req), String(reflecting: req), dumped] {
      #expect(!text.contains("test-key-123") && text.contains("<redacted>"))
    }
    #expect(try c.integrations().map(\.platform) == Platform.allCases)
    for (code, expected) in [(401, PostizError.unauthorized("injected 401")), (429, .rateLimited), (400, .validation("injected 400")),
                             (404, .notFound), (413, .payloadTooLarge), (502, .server(502, "injected 502"))] {
      fake.failNext["GET integrations"] = [code]
      #expect(throws: expected) { try c.integrations() }
    }
    let bad = PostizClient(transport: fake, key: { "wrong" })
    #expect(throws: PostizError.unauthorized("Invalid API key")) { try bad.isConnected() }
    #expect(PostizError.message(in: Data("{\"message\":[\"a\",\"b\"]}".utf8)) == "a; b")
    #expect(PostizClient.isoString(Date(timeIntervalSince1970: 1_794_268_800)) == "2026-11-10T00:00:00.000Z")
    #expect(PostizClient.uploadTimeout(bytes: 300_000_000) == 720)
  }

  @Test func multipartUploadStreamsFromATempFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-mp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appendingPathComponent("clip.mp4")
    var payload = Data(count: 3 << 20)  // 3 MB: more than one 1 MB chunk
    payload[0] = 7
    payload[payload.count - 1] = 9
    try payload.write(to: src)
    let out = try Multipart.write(file: src, fileName: "clip \"1\".mp4", mimeType: "video/mp4", fields: ["adjust": "false"],
                                  boundary: "B", in: dir)
    let d = try Data(contentsOf: out)
    let head = "--B\r\nContent-Disposition: form-data; name=\"adjust\"\r\n\r\nfalse\r\n--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip '1'.mp4\"\r\nContent-Type: video/mp4\r\n\r\n"
    #expect(d.prefix(head.utf8.count) == Data(head.utf8))
    #expect(d.count == head.utf8.count + payload.count + "\r\n--B--\r\n".utf8.count)
    #expect(d.suffix(8) == Data("\r\n--B--\r\n".utf8).suffix(8))
  }

  // MARK: Router

  @Test func routerGivesAFallbackReasonForEveryGap() throws {
    var s = Settings()
    s.publishing.publishers = [.tiktok: .postiz, .youtube: .postiz]
    let ch = [PostizIntegration(id: "ch-tt", name: "TT", identifier: "tiktok-business"),
              PostizIntegration(id: "ch-yt", name: "YT chan", identifier: "youtube", disabled: true)]
    #expect(PostizRouter(settings: s, hasKey: true, keyInvalid: false, channels: ch).route(.x) == .manual)
    #expect(PostizRouter(settings: s, hasKey: false, keyInvalid: false, channels: ch).route(.tiktok) == .fallback(.noKey))
    #expect(PostizRouter(settings: s, hasKey: true, keyInvalid: true, channels: ch).route(.tiktok) == .fallback(.keyInvalid))
    #expect(PostizRouter(settings: s, hasKey: true, keyInvalid: false, channels: ch).route(.tiktok) == .fallback(.noChannel))
    s.publishing.channels = [.tiktok: "ch-tt", .youtube: "ch-yt"]
    let r = PostizRouter(settings: s, hasKey: true, keyInvalid: false, channels: ch)
    #expect(r.route(.tiktok) == .postiz(integrationId: "ch-tt", provider: "tiktok-business"))
    #expect(r.route(.youtube) == .fallback(.channelDisabled("YT chan")))
    s.publishing.channels[.tiktok] = "gone"
    #expect(PostizRouter(settings: s, hasKey: true, keyInvalid: false, channels: ch).route(.tiktok) == .fallback(.channelMissing))
    #expect(PostizRouter(settings: s, hasKey: true, keyInvalid: false, channels: nil).route(.tiktok)
      == .postiz(integrationId: "gone", provider: "tiktok-business"))  // never listed: assumed fine
    #expect(PostizFallbackReason.createRejected("Caption too long").message == "Postiz refused this post: Caption too long")
  }

  @Test func routerOnlyAsksTheKeychainWhenAPlatformUsesPostiz() throws {
    let f = try Fixture()
    final class Counting: PostizKeyStore, @unchecked Sendable {
      var asked = 0
      func read() throws -> String? { nil }
      func save(_ key: String) throws {}
      func delete() throws {}
      func hasKey() -> Bool { asked += 1; return true }
    }
    let ks = Counting()
    _ = try PostizRouter.current(store: f.store, keyStore: ks)
    #expect(ks.asked == 0)
    try f.updateSettings { $0.publishing.publishers[.x] = .postiz }
    _ = try PostizRouter.current(store: f.store, keyStore: ks)
    #expect(ks.asked == 1)
  }

  // MARK: Payload, titles, cover

  @Test func coverMeaningPerPlatform() {
    #expect(CoverMeaning.of(.youtube).label == "Thumbnail")
    #expect(CoverMeaning.of(.instagram).label == "Cover frame" && CoverMeaning.of(.tiktok).label == "Cover frame")
    #expect([Platform.facebook, .threads, .x].allSatisfy { CoverMeaning.of($0).label == "Platform picks" })
    #expect(CoverMeaning.all.count == 6 && CoverMeaning.of(.x).detail(.x).contains("X picks"))
  }

  @Test func titlesNeverExceedTheirCapsAndSayWhenShortened() throws {
    #expect(PostizPayload.clamp(String(repeating: "a", count: 150), 100).count == 100)
    #expect(PostizPayload.clamp("short", 100) == "short")
    let f = try Fixture.engine(1)
    try f.store.setTitle("clip-0", String(repeating: "Long title ", count: 12))  // 132 chars
    var v1 = try #require(try f.store.versions(videoId: "clip-0").first)
    v1.text = String(repeating: "word ", count: 30)
    try f.store.save(v1, videoId: "clip-0")
    let v = try #require(try f.store.video(id: "clip-0"))
    let checks = try Validation.titleChecks(video: v, store: f.store)
    let yt = try #require(checks.first { $0.platform == .youtube })
    #expect(yt.title.count <= 100 && yt.isShortened && yt.message?.hasPrefix("YouTube title is ") == true)
    let tt = try #require(checks.first { $0.platform == .tiktok })
    #expect(tt.title.count == 90 && tt.isShortened && tt.limit == 90)
  }

  func renderFor(_ f: Fixture, _ id: String = "clip-0") throws -> Render {
    try FakeRenderer(store: f.store).ensureRender(videoId: id, versionNo: 1, platform: nil)
  }

  @Test func payloadPerPlatformAndTestMode() throws {
    let f = try Fixture.engine(1)
    try f.store.setTitle("clip-0", "Song A x Song B")
    try Planner(store: f.store).approveWeek(f.week)
    let r = try renderFor(f)
    var e = try f.store.edit(videoId: "clip-0")
    e.coverTime = 5.25  // trim starts at the marker (3.0)
    try f.store.save(e, videoId: "clip-0")
    func spec(_ p: Platform, _ s: Settings) throws -> PostizPostSpec {
      var post = try #require(try f.post(p, day: "2026-11-02"))
      post.renderId = r.id
      return try PostizPayload.spec(store: f.store, post: post, settings: s, integrationId: "ch-\(p.rawValue)")
    }
    var s = try f.store.settings()
    let tt = try spec(.tiktok, s)
    #expect(tt.type == "schedule" && tt.settings["content_posting_method"] == .string("DIRECT_POST"))
    #expect(tt.settings["title"] == .string("Song A x Song B") && tt.settings["autoAddMusic"] == .string("no"))
    #expect(tt.thumbnailTimestampMs == 2250 && !tt.uploadsCover)
    let yt = try spec(.youtube, s)
    #expect(yt.settings["type"] == .string("public") && yt.settings["selfDeclaredMadeForKids"] == .string("no"))
    #expect(yt.uploadsCover && yt.thumbnailTimestampMs == nil)
    if case .string(let t) = yt.settings["title"] { #expect(t.hasSuffix("| DJ Lovd") && t.count <= 100) } else { Issue.record("no title") }
    let ig = try spec(.instagram, s)
    #expect(ig.provider == "instagram-standalone" && ig.settings["post_type"] == .string("post") && ig.thumbnailTimestampMs == 2250)
    let x = try spec(.x, s)
    #expect(x.settings["who_can_reply_post"] == .string("everyone") && x.thumbnailTimestampMs == nil)
    // Body shape.
    let body = try #require(try JSONSerialization.jsonObject(with: yt.body(date: Date(timeIntervalSince1970: 1_794_268_800),
      video: PostizMedia(id: "m1", path: "/m1"), cover: PostizMedia(id: "c1", path: "/c1"))) as? [String: Any])
    #expect(body["type"] as? String == "schedule" && body["date"] as? String == "2026-11-10T00:00:00.000Z")
    #expect(body["shortLink"] as? Bool == false && (body["tags"] as? [Any])?.isEmpty == true)
    let item = try #require((body["posts"] as? [[String: Any]])?.first)
    let st = try #require(item["settings"] as? [String: Any])
    #expect(st["__type"] as? String == "youtube" && (st["thumbnail"] as? [String: String]) == ["id": "c1", "path": "/c1"])
    // Test mode: TikTok → inbox, YouTube → unlisted, others → drafts.
    s.publishing.testMode = true
    #expect(try spec(.tiktok, s).settings["content_posting_method"] == .string("UPLOAD"))
    #expect(try spec(.tiktok, s).thumbnailTimestampMs == nil && spec(.tiktok, s).type == "schedule")
    #expect(try spec(.youtube, s).settings["type"] == .string("unlisted") && spec(.youtube, s).type == "schedule")
    for p in [Platform.instagram, .facebook, .threads, .x] { #expect(try spec(p, s).type == "draft") }
    // The hash follows the content and the slot, nothing else.
    #expect(try spec(.x, s).contentHash == spec(.x, s).contentHash)
    #expect(try spec(.x, s).contentHash != x.contentHash)  // test mode changed
    var later = try #require(try f.post(.x, day: "2026-11-02"))
    later.renderId = r.id
    let h1 = try PostizPayload.spec(store: f.store, post: later, settings: s, integrationId: "ch-x").contentHash
    later.scheduledAt.addTimeInterval(86400)
    #expect(try PostizPayload.spec(store: f.store, post: later, settings: s, integrationId: "ch-x").contentHash != h1)
  }

  // MARK: F5

  /// Real-data bug: the only ready clip sat in a past draft-week day with no posts, so `Queue.ordered()` left it out
  /// and every new week proposed nothing.
  @Test func pastDraftDayNoLongerHidesItsClip() throws {
    let f = try Fixture.engine(1)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)  // Monday 2026-11-02 … Sunday 2026-11-08, draft
    let slot = try #require(try planner.slots(week: f.week).first { $0.videoId == "clip-0" })
    #expect(try Queue(store: f.store).ordered().isEmpty)  // slotted while the day is ahead
    // A week later, nobody approved it.
    f.setTime("2026-11-10", "09:00")
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-0"])  // past draft day doesn't count
    let n = LogNotifier()
    let r = Engine(store: f.store, renderer: nil, publisher: nil, notifier: n).tick(reason: "t")
    #expect(r.steps["plan"]?.contains("dropped 1 past draft day") == true)
    #expect(try f.store.planSlots(where: "id=?", [slot.id]).isEmpty)
    let next = try planner.slots(week: "2026-11-09")
    #expect(next.contains { $0.videoId == "clip-0" && $0.date >= "2026-11-10" })  // the new week proposes it
    #expect(try f.doublePosts().isEmpty)
  }

  /// Guard (a): a past day of a draft week that HAS posts (rebuilt after it posted) is never dropped, and its clip
  /// never comes back to the Queue.
  @Test func pastDraftDayWithPostsStays() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    try f.postAll(on: "2026-11-02")
    try planner.rebuildWeek(f.week)  // back to draft; Monday keeps its posted slot
    #expect(try f.store.week(f.week)?.state == .draft)
    let mon = try #require(try f.store.planSlots(where: "date='2026-11-02'").first)
    f.setTime("2026-11-04", "09:00")
    #expect(try !f.store.stalePastDraftSlots(today: "2026-11-04").contains { $0.id == mon.id })  // Tuesday's re-proposal may go
    Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier()).tick(reason: "t")
    #expect(try f.store.planSlots(where: "id=?", [mon.id]).count == 1)
    #expect(try !Queue(store: f.store).ordered().contains { $0.id == mon.videoId })
    #expect(try f.doublePosts().isEmpty)
  }

  /// Guard (b): a past slot of an APPROVED week is never dropped, even without posts.
  @Test func pastApprovedDayWithoutPostsStays() throws {
    let f = try Fixture.engine(3)
    try Planner(store: f.store).approveWeek(f.week)
    let s = PlanSlot(id: "manual-slot", date: "2026-11-02", position: 1, videoId: "clip-2", pinned: false, weekStart: f.week)
    try f.store.save(s)
    f.setTime("2026-11-04", "09:00")
    #expect(try f.store.stalePastDraftSlots(today: "2026-11-04").isEmpty)
    Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier()).tick(reason: "t")
    #expect(try f.store.planSlots(where: "id='manual-slot'").count == 1)
  }

  /// Approving mid-week (before a tick ran the plan step) drops the draft days that already passed first.
  @Test func approvingMidWeekDropsThePassedDraftDays() throws {
    let f = try Fixture.engine(4)
    let planner = Planner(store: f.store)
    try planner.proposeWeek(f.week)
    let monTue = try f.store.planSlots(where: "date IN ('2026-11-02','2026-11-03')")
    #expect(monTue.count == 2)
    f.setTime("2026-11-04", "09:00")
    try planner.approveWeek(f.week)
    #expect(try f.store.planSlots(where: "date<'2026-11-04'").isEmpty)
    let vids = Set(monTue.map(\.videoId))
    let planned = Set(try f.store.planSlots().map(\.videoId))
    // Their clips are back in play (re-planned on a future day or in the Queue), never stuck as "Scheduled".
    let queued = Set(try Queue(store: f.store).ordered().map(\.id))
    for v in vids { #expect(planned.contains(v) || queued.contains(v)) }
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func pastPinnedDraftDayIsDroppedButApprovedAndPostedDaysStay() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.pin(videoId: "clip-2", date: "2026-11-03")  // draft week, pinned
    try planner.approveWeek("2026-11-09")  // next week approved (has posts)
    f.setTime("2026-11-05", "09:00")
    let stale = try f.store.stalePastDraftSlots(today: "2026-11-05")
    #expect(stale.contains { $0.videoId == "clip-2" && $0.pinned })
    #expect(stale.allSatisfy { $0.weekStart == "2026-11-02" })
    Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier()).tick(reason: "t")
    #expect(try f.store.planSlots(where: "date<? AND week_start='2026-11-02'", ["2026-11-05"]).isEmpty)
    #expect(try !f.store.planSlots(where: "week_start='2026-11-09'").isEmpty)
    #expect(try f.store.events(videoId: "clip-2").contains { $0.message.contains("pin removed") })
  }
}

/// `DJQ_MIGRATION_BACKUP_V5=<copy of a real queue.sqlite>`: migrates a further copy to schema v5 and compares every
/// table's rows, scores, titles, edits, versions, posts and the settings row; `DJQ_MIGRATION_EVIDENCE=<file>` gets a
/// summary. The given file is checksummed before and after (never changed).
@Suite struct R6MigrationProof {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_MIGRATION_BACKUP_V5"] != nil))
  func realBackupCopyMigratesToV5Losslessly() throws {
    let env = ProcessInfo.processInfo.environment
    let src = URL(fileURLWithPath: env["DJQ_MIGRATION_BACKUP_V5"]!)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-v5-real-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                      logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    let sum = { (u: URL) in SHA256Hex.of(try Data(contentsOf: u)) }
    let before = try sum(src)
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let copy = paths.appSupport.appendingPathComponent("queue.sqlite")
    try FileManager.default.copyItem(at: src, to: copy)
    let tables = ["sessions", "videos", "edits", "versions", "hashtag_sets", "caption_templates", "weeks", "plan_slots",
                  "platform_posts", "post_history", "renders", "events", "kv", "title_suggestions", "text_suggestions", "batches"]
    func dump(_ db: SQLite) throws -> [String: [String]] {
      var out: [String: [String]] = [:]
      let have = Set(try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string("name") })
      for t in tables where have.contains(t) {
        let cols = try db.query("PRAGMA table_info(\(t))").compactMap { $0.string("name") }.sorted()
        out[t] = try db.query("SELECT * FROM \(t)").map { r in
          cols.map { c in r.string(c) ?? r.double(c).map { String($0) } ?? "∅" }.joined(separator: "|")
        }.sorted()
      }
      return out
    }
    let raw = try SQLite(path: copy.path)
    let oldVersion = try raw.one("PRAGMA user_version")?.int("user_version") ?? 0
    let old = try dump(raw)
    let store = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)
    #expect(try store.db.one("PRAGMA user_version")?.int("user_version") == 5)
    let new = try dump(store.db)
    var lines = ["schema \(oldVersion) → 5", "source sha256 \(before)"]
    for t in tables {
      #expect(new[t] == (old[t] ?? []), "table \(t) changed")
      lines.append("\(t): \(old[t]?.count ?? 0) rows → \(new[t]?.count ?? 0) rows, identical: \(new[t] == (old[t] ?? []))")
    }
    #expect(try store.openPostizJobs().isEmpty)
    let s = try store.settings()
    #expect(s.publishing == PublishingSettings() && s.publishing.postizPlatforms.isEmpty)
    lines.append("settings decode: postsPerDay \(s.postsPerDay), publishing all Manual, limits tiktok caption \(s.limits[.tiktok]?.captionLimit ?? 0) / title \(s.limits[.tiktok]?.titleLimit.map(String.init) ?? "-"), instagram \(s.limits[.instagram]?.maxBytes ?? 0) B")
    let vids = try store.videos()
    lines.append("videos \(vids.count) · scored \(vids.filter { $0.score != nil }.count) · titled \(vids.filter { $0.title != nil }.count)")
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    // One copy before the first migration step that ran (schema 4 or 5).
    let backedUp = backups.contains { $0.hasPrefix("queue-before-schema\(oldVersion + 1)-") }
    #expect(backedUp)
    _ = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)  // re-open is a no-op
    #expect(try dump(store.db) == new)
    #expect(try sum(src) == before)
    lines.append("source unchanged: \(try sum(src) == before); pre-migration backup taken: \(backedUp); re-open no-op: true")
    if let ev = env["DJQ_MIGRATION_EVIDENCE"] {
      try lines.joined(separator: "\n").appending("\n").write(toFile: ev, atomically: true, encoding: .utf8)
    }
  }
}

import CryptoKit
enum SHA256Hex {
  static func of(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
