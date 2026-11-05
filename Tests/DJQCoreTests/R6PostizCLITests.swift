import Foundation
import Testing
@testable import DJQCore

/// Round 6 (P7): `djq postiz …` end to end — the built `djq` binary against a throwaway file database, with
/// `DJQ_POSTIZ_OFFLINE=1` (no Postiz call, no Keychain). The channel list is seeded in the cache, as a live
/// `djq postiz channels` would leave it.
@Suite(.serialized) struct R6PostizCLITests {
  final class Marker {}

  /// The `djq` built next to this test bundle (works with `--scratch-path` too), else the repo's `.build/debug/djq`.
  static var binary: URL? {
    let candidates = [
      Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("djq"),
      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/djq"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  final class Env {
    let f: Fixture
    let store: Store

    /// `clips` ready clips in a file database at the fixture's DJQ_HOME, the given Postiz channels in the cache.
    init(clips: Int = 2, channels: [PostizIntegration] = Env.djChannels) throws {
      let clipList = (0..<clips).map { (tag: "song\($0) x mix\($0)", duration: 20.0 + Double($0)) }
      f = try Fixture(clips: clipList)
      try f.paths.ensure()
      store = try Store(paths: f.paths)
      _ = try Intake(store: store).run()
      for i in 0..<clips {
        var e = Edit()
        e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
        try store.save(e, videoId: "clip-\(i)")
        var v = Version(number: 1)
        v.text = "Text clip-\(i)"
        v.captionTemplateId = "short"
        try store.save(v, videoId: "clip-\(i)")
        try store.setScore("clip-\(i)", 50)
        try store.setSentToQueue("clip-\(i)", true)
      }
      try store.setKV(PostizChannelCache.kvKey, PostizChannelCache(fetchedAt: Date(), integrations: channels))
    }

    static let djChannels: [PostizIntegration] = [
      .init(id: "cid-ig", name: "DJ Lovd IG", identifier: "instagram-standalone"),
      .init(id: "cid-igfb", name: "Other IG via FB", identifier: "instagram"),
      .init(id: "cid-tt", name: "DJ Lovd TikTok", identifier: "tiktok-business"),
      .init(id: "cid-th", name: "dj.lovd Threads", identifier: "threads"),
      .init(id: "cid-fb", name: "Dj lovd", identifier: "facebook"),
      .init(id: "cid-x", name: "djlovdreal", identifier: "x"),
      .init(id: "cid-yt", name: "DJ Lovd YT", identifier: "youtube"),
      .init(id: "cid-li", name: "Some LinkedIn", identifier: "linkedin"),
    ]

    struct Result { var status: Int32; var out: String; var err: String }

    @discardableResult
    func djq(_ args: String...) throws -> Result { try djq(args: args) }

    func json(_ args: String...) throws -> [String: Any] {
      let r = try djq(args: args + ["--json"])
      return try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any], "\(r.out)\(r.err)")
    }

    func djq(args: [String]) throws -> Result {
      guard let bin = R6PostizCLITests.binary else { throw EngineError("djq isn't built (swift build)") }
      let p = Process()
      p.executableURL = bin
      p.arguments = args
      var env = ProcessInfo.processInfo.environment
      env["DJQ_ROOT"] = f.paths.root.path
      env["DJQ_HOME"] = f.dir.path
      env["DJQ_POSTIZ_OFFLINE"] = "1"
      env["DJQ_NO_SIGNAL"] = "1"  // never make the installed DJ Queue reload or tick
      p.environment = env
      let o = Pipe(), e = Pipe()
      p.standardOutput = o
      p.standardError = e
      try p.run()
      let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      return Result(status: p.terminationStatus, out: String(decoding: od, as: UTF8.self), err: String(decoding: ed, as: UTF8.self))
    }

    var publishing: PublishingSettings { get throws { try store.settings().publishing } }
  }

  @Test func binaryIsBuilt() {
    #expect(Self.binary != nil, "build djq first (swift build); these tests run the real CLI")
  }

  @Test func autoMapPicksTheSixDJChannelsByProviderAndDryRunChangesNothing() throws {
    let env = try Env()
    let dry = try env.djq("postiz", "map", "--dry-run")
    #expect(dry.status == 0 && dry.out.contains("[dry run] would change"), "\(dry.out)\(dry.err)")
    #expect(dry.out.contains("Instagram") && dry.out.contains("DJ Lovd IG (instagram-standalone)"))
    #expect(!dry.out.contains("cid-"), "channel ids are shown only with --ids")
    #expect(try env.publishing.channels.isEmpty)
    // Mapping alone never sends anything (every platform is still Manual): no --yes needed.
    let r = try env.djq("postiz", "map")
    #expect(r.status == 0 && r.out.contains("undo: djq bulk undo"), "\(r.out)\(r.err)")
    #expect(try env.publishing.channels == [.instagram: "cid-ig", .tiktok: "cid-tt", .threads: "cid-th", .facebook: "cid-fb",
                                            .x: "cid-x", .youtube: "cid-yt"])
    #expect(try env.publishing.postizPlatforms.isEmpty)
    // Running it again changes nothing; --ids shows the ids.
    #expect(try env.djq("postiz", "map").out.contains("nothing to change"))
    #expect(try env.djq("postiz", "channels", "--cached", "--ids").out.contains("id cid-tt"))
    // Undo puts Settings back.
    let batch = try #require(r.out.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
    #expect(try env.djq("bulk", "undo", batch).status == 0)
    #expect(try env.publishing.channels.isEmpty)
  }

  @Test func autoMapLeavesAmbiguousOrMissingProvidersForEric() throws {
    var chans = Env.djChannels.filter { $0.identifier != "instagram-standalone" }
    chans.append(.init(id: "cid-tt2", name: "Coach TikTok", identifier: "tiktok-business"))
    let env = try Env(channels: chans)
    let out = try env.json("postiz", "map")
    let notes = try #require(out["notes"] as? [String])
    #expect(notes.contains { $0.contains("TikTok: 2 tiktok-business channels") })
    #expect(notes.contains { $0.contains("Instagram: no instagram-standalone channel") && $0.contains("Other IG via FB") })
    let ch = try env.publishing.channels
    #expect(ch[.tiktok] == nil && ch[.instagram] == nil && ch[.youtube] == "cid-yt")
    // Picking by name works; a channel of another platform is refused.
    #expect(try env.djq("postiz", "map", "tiktok", "DJ Lovd TikTok").status == 0)
    #expect(try env.publishing.channels[.tiktok] == "cid-tt")
    let wrong = try env.djq("postiz", "map", "instagram", "djlovdreal")
    #expect(wrong.status == 1 && wrong.err.contains("not for Instagram") && wrong.err.contains("nothing changed"))
    #expect(try env.publishing.channels[.instagram] == nil)
    #expect(try env.djq("postiz", "map", "youtube", "--clear").status == 0)
    #expect(try env.publishing.channels[.youtube] == nil)
  }

  @Test func goingLiveNeedsYesAndTestRunDoesNot() throws {
    let env = try Env()
    try env.djq("postiz", "map")
    // Postiz with channels and test run off would schedule real posts: refused without --yes.
    let refused = try env.djq("postiz", "publisher", "all", "postiz")
    #expect(refused.status == 1 && refused.out.contains("not changed (needs --yes)") && refused.out.contains("Eric's call"))
    #expect(try env.publishing.postizPlatforms.isEmpty)
    let j = try env.json("postiz", "publisher", "all", "postiz", "--dry-run")
    #expect(j["needsYes"] as? Bool == true && (j["goesLive"] as? [String])?.count == 6 && j["applied"] as? Bool == false)
    // Test run first: then switching to Postiz only makes drafts / inbox / unlisted.
    #expect(try env.djq("postiz", "test-mode", "on").status == 0)
    let on = try env.djq("postiz", "publisher", "all", "postiz")
    #expect(on.status == 0 && on.out.contains("TikTok") && on.out.contains("Manual → Postiz"), "\(on.out)\(on.err)")
    #expect(try env.publishing.postizPlatforms.count == 6 && env.publishing.testMode)
    // Turning test run off is the real switch.
    #expect(try env.djq("postiz", "test-mode", "off").status == 1)
    #expect(try env.publishing.testMode)
    #expect(try env.djq("postiz", "test-mode", "off", "--yes").status == 0)
    #expect(try !env.publishing.testMode)
    // Back to Manual never needs --yes.
    #expect(try env.djq("postiz", "publisher", "x", "manual").status == 0)
    #expect(try env.publishing.publisher(for: .x) == .manual)
    // Every settings change is in the journal and logged.
    #expect(try BulkActions(store: env.store).batches().filter { $0.action.hasPrefix("postiz") }.count == 5)
    #expect(try env.store.events(limit: 50).contains { $0.message.contains("Settings → Publishing changed from djq") })
  }

  /// Review M1: undoing a settings batch must not switch real Postiz posting back on without Eric's --yes.
  @Test func bulkUndoThatGoesLiveNeedsYes() throws {
    let env = try Env()
    // Waiting posts: a scheduled week (core's undoWouldGoLive counts only platforms with posts to send).
    let planner = Planner(store: env.store)
    let dm = DayMath(settings: try env.store.settings())
    let week = dm.addDays(dm.weekStart(of: Date()), 7)
    try planner.proposeWeek(week)
    try planner.approveWeek(week)
    #expect(try !env.store.posts(where: "state='planned'").isEmpty)
    try env.djq("postiz", "map")
    #expect(try env.djq("postiz", "publisher", "all", "postiz", "--yes").status == 0)
    let manual = try env.json("postiz", "publisher", "all", "manual")
    let batch = try #require(manual["batchId"] as? String)
    #expect(try env.publishing.postizPlatforms.isEmpty)
    let refused = try env.djq("bulk", "undo", batch)
    #expect(refused.status == 2 && refused.out.contains("would schedule real posts") && refused.out.contains("--yes"), "\(refused.out)\(refused.err)")
    #expect(try env.publishing.postizPlatforms.isEmpty)
    #expect(try BulkActions(store: env.store).batches().first { $0.id == batch }?.undoneAt == nil)
    let dry = try env.djq("bulk", "undo", batch, "--dry-run")
    #expect(dry.status == 0 && dry.out.contains("[dry run]") && dry.out.contains("would schedule real posts"))
    #expect(try env.publishing.postizPlatforms.isEmpty)
    #expect(try env.djq("bulk", "undo", batch, "--yes").status == 0)
    #expect(try env.publishing.postizPlatforms.count == 6)
    // test-mode on needs no --yes, but undoing it turns the test run off: refused too.
    let on = try env.json("postiz", "test-mode", "on")
    let tb = try #require(on["batchId"] as? String)
    #expect(try env.djq("bulk", "undo", tb).status == 2)
    #expect(try env.publishing.testMode)
    // An undo that doesn't go live needs nothing (map while every platform is Manual).
    let quiet = try Env()
    let m = try quiet.json("postiz", "map")
    #expect(try quiet.djq("bulk", "undo", try #require(m["batchId"] as? String)).status == 0)
  }

  /// An unconfirmed create: Eric's answer is recorded offline; plain resolve needs Postiz (none here) and never guesses.
  @Test func resolveRecordsEricsAnswerOffline() throws {
    let env = try Env()
    let planner = Planner(store: env.store)
    let dm = DayMath(settings: try env.store.settings())
    let week = dm.addDays(dm.weekStart(of: Date()), 7)
    try planner.proposeWeek(week)
    try planner.approveWeek(week)
    let posts = try env.store.posts(where: "state='planned'")
    let (a, b) = (try #require(posts.first), try #require(posts.last))
    #expect(a.id != b.id)
    for p in [a, b] {
      let j = PostizJob(postId: p.id, videoId: p.videoId, platform: p.platform, integrationId: "cid-x", phase: .creating,
                        renderId: nil, contentHash: "h", scheduledAt: p.scheduledAt, remoteDate: p.scheduledAt, testMode: false,
                        postType: "schedule", remoteState: PostizJob.unconfirmed, createdAt: Date(), updatedAt: Date())
      #expect(try env.store.claimPostizJob(j))
    }
    #expect(try env.djq("postiz", "resolve", a.id, "--in-postiz", "--not-in-postiz").status == 1)
    // Plain resolve needs a live look (no key here): it fails and settles nothing.
    let plain = try env.djq("postiz", "resolve", a.id)
    #expect(plain.status != 0)
    #expect(try env.store.livePostizJob(postId: a.id)?.isUnconfirmed == true)
    let no = try env.json("postiz", "resolve", a.id, "--not-in-postiz")
    #expect((no["result"] as? String)?.contains("the Calendar") == true)
    #expect(try env.store.livePostizJob(postId: a.id) == nil && env.store.post(id: a.id)?.publisher == "manual")
    let yes = try env.djq("postiz", "resolve", b.id, "--in-postiz")
    #expect(yes.status == 0 && yes.out.contains("recorded posted"), "\(yes.out)\(yes.err)")
    #expect(try env.store.post(id: b.id)?.state == .posted)
    // Nothing left to resolve.
    #expect(try env.djq("postiz", "resolve", b.id, "--in-postiz").status == 1)
    #expect(try env.store.postizBudget().calls.isEmpty)
  }

  @Test func testRunSaysWhatReachesYouTubeAndTikTok() throws {
    let env = try Env()
    try env.djq("postiz", "map")
    try env.djq("postiz", "test-mode", "on")
    let r = try env.djq("postiz", "publisher", "all", "postiz")
    #expect(r.status == 0 && r.out.contains("uploaded to the channel as unlisted") && r.out.contains("TikTok app inbox"))
    #expect(!(try env.djq("postiz", "publisher", "x", "manual")).out.contains("unlisted"))
  }

  @Test func statusJSONIsNotReadyWithoutAKeyAndHidesIds() throws {
    let env = try Env()
    try env.djq("postiz", "map")
    let r = try env.djq("postiz", "status", "--json")
    #expect(r.status == 2)
    let o = try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
    #expect(o["state"] as? String == "no_key" && o["ready"] as? Bool == false && o["hasKey"] as? Bool == false)
    let rows = try #require(o["platforms"] as? [[String: Any]])
    #expect(rows.count == 6)
    let tt = try #require(rows.first { $0["platform"] as? String == "tiktok" })
    #expect((tt["channel"] as? [String: Any])?["name"] as? String == "DJ Lovd TikTok")
    #expect((tt["channel"] as? [String: Any])?["provider"] as? String == "tiktok-business")
    #expect(tt["route"] as? String == "manual" && tt["publisher"] as? String == "manual")
    #expect(!r.out.contains("cid-"))
    #expect(try env.djq("postiz", "status", "--json", "--ids").out.contains("cid-tt"))
    let text = try env.djq("postiz", "status")
    #expect(text.status == 2 && text.out.contains("Not ready:") && text.out.contains("no Postiz API key saved"))
    #expect(text.out.contains("DJ Lovd TikTok (tiktok-business)"))
    // Without a key no budget slot is spent.
    #expect(try env.store.postizBudget().calls.isEmpty)
  }

  @Test func testNeverSchedulesRealPosts() throws {
    let env = try Env()
    let none = try env.djq("postiz", "test", "clip-0")
    #expect(none.status == 1 && none.err.contains("--dry-run") && none.err.contains("--draft"))
    let yes = try env.djq("postiz", "test", "clip-0", "--yes")
    #expect(yes.status == 1 && yes.err.contains("never schedules real posts"))
    let noRender = try env.djq("postiz", "test", "clip-0", "--dry-run")
    #expect(noRender.status == 1 && noRender.err.contains("no finished render"))
  }

  @Test func dryRunPrintsSixBodiesWithIdsAndKeyRedacted() throws {
    let env = try Env()
    try env.djq("postiz", "map")
    _ = try FakeRenderer(store: env.store).ensureRender(videoId: "clip-0", versionNo: 1, platform: nil)
    let o = try env.json("postiz", "test", "clip-0", "--dry-run")
    let rows = try #require(o["platforms"] as? [[String: Any]])
    #expect(rows.count == 6)
    #expect((o["headers"] as? [String: String])?["Authorization"] == "<redacted>")
    let all = rows.compactMap { $0["body"] as? String }.joined()
    #expect(!all.contains("cid-") && all.contains("<channel id>") && all.contains("<uploaded media id>"))
    #expect(all.contains("tiktok-business") && all.contains("\"schedule\""))
    // A dry run writes nothing.
    #expect(try env.store.postizJobs().isEmpty)
    let text = try env.djq("postiz", "test", "clip-0", "--dry-run")
    #expect(text.status == 0 && text.out.contains("Dry run (no call)") && text.out.contains("── TikTok → DJ Lovd TikTok (tiktok-business)"))
    // --draft needs Postiz (offline here): it fails without creating anything.
    let draft = try env.djq("postiz", "test", "clip-0", "--draft")
    #expect(draft.status == 1)
    #expect(try env.store.postizJobs().isEmpty)
  }

  @Test func doctorJSONCarriesThePostizChecks() throws {
    let env = try Env()
    try env.djq("postiz", "map")
    try env.djq("postiz", "test-mode", "on")
    try env.djq("postiz", "publisher", "tiktok", "postiz")
    try env.store.setPostizKeyInvalid("Invalid API key")
    let r = try env.djq("doctor", "--json")
    #expect(r.status == 2, "key_invalid is an error")
    let o = try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
    let ids = Set((o["findings"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    #expect(ids.isSuperset(of: ["postiz.key_invalid", "postiz.test_mode", "postiz.not_connected"]), "\(ids)")
  }

  @Test func syncAsksTheRunningEngineInsteadOfRacingIt() throws {
    let env = try Env()
    let lock = try #require(EngineLock.acquire(env.f.paths))
    defer { lock.release() }
    let r = try env.djq("postiz", "sync")
    #expect(r.status == 0 && r.out.contains("asked it to sync now"))
    #expect(try env.store.kv("postiz.syncNow", as: Bool.self) == true)
  }
}
