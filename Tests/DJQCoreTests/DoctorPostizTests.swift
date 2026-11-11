import Foundation
import Testing
@testable import DJQCore

/// Round 6 (P7): Doctor's Postiz checks — stable ids, severities and fixes, offline by default, and a fix in the
/// dj-queue-doctor skill for every id. Everything runs against `FakePostiz` and memory key stores.
@Suite struct DoctorPostizTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  /// Counts presence checks so a test can prove the Keychain wasn't asked.
  final class CountingKeys: PostizKeyStore, @unchecked Sendable {
    var key: String?
    var hasKeyCalls = 0, reads = 0
    init(_ key: String?) { self.key = key }
    func read() throws -> String? { reads += 1; return key }
    func save(_ k: String) throws { key = k }
    func delete() throws { key = nil }
    func hasKey() -> Bool { hasKeyCalls += 1; return key != nil }
  }

  static func doctor(_ store: Store, keys: PostizKeyStore) -> Doctor {
    let d = Doctor(store: store)
    d.agentLoaded = { true }
    d.autoUpdateWatcherLoaded = { true }
    d.probeDurations = false
    d.postizKeyStore = keys
    return d
  }

  static func postiz(_ r: DoctorReport) -> [String: DoctorFinding] {
    Dictionary(r.findings.filter { $0.id.hasPrefix("postiz.") }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
  }

  @Test func everyPlatformManualIsOneInfoAndNeverAsksTheKeychain() throws {
    let f = try Fixture.engine(2)
    try Planner(store: f.store).approveWeek(f.week)
    let keys = CountingKeys(nil)
    let r = Self.doctor(f.store, keys: keys).run()
    let p = Self.postiz(r)
    #expect(Set(p.keys) == ["postiz.not_connected"])
    #expect(p["postiz.not_connected"]?.severity == .info && p["postiz.not_connected"]?.title == "Postiz not in use")
    #expect(r.passed.contains("postiz"))
    #expect(keys.hasKeyCalls == 0 && keys.reads == 0)
  }

  @Test func healthyPostizSetupIsClean() throws {
    let rig = try Rig(2)
    rig.settle()
    _ = try rig.service.channels()
    let r = Self.doctor(rig.store, keys: rig.keys).run()
    #expect(Self.postiz(r).isEmpty, "\(Self.postiz(r))")
    #expect(r.passed.contains("postiz"))
  }

  @Test func notConnectedIsAWarningWhenAPlatformUsesPostiz() throws {
    let rig = try Rig(1, platforms: [.tiktok, .x], approve: false)
    try rig.keys.delete()
    let p = Self.postiz(Self.doctor(rig.store, keys: rig.keys).run())
    let nc = try #require(p["postiz.not_connected"])
    #expect(nc.severity == .warning && nc.detail.contains("X, TikTok") && nc.where_ == ["x", "tiktok"])
    #expect(nc.fix.contains("Settings → Publishing"))
  }

  @Test func keyInvalidChannelDisabledAndRateLimit() throws {
    let rig = try Rig(1, platforms: [.instagram, .youtube], approve: false)
    rig.fake.integrations = rig.fake.integrations.map { var c = $0; c.disabled = c.platform == .youtube; return c }
    _ = try rig.service.channels()
    try rig.store.setPostizKeyInvalid("Invalid API key")
    try rig.store.pausePostiz()
    let r = Self.doctor(rig.store, keys: rig.keys).run()
    let p = Self.postiz(r)
    #expect(p["postiz.key_invalid"]?.severity == .error && p["postiz.key_invalid"]?.detail.contains("Invalid API key") == true)
    let cd = try #require(p["postiz.sign_in"])
    #expect(cd.severity == .error && cd.where_ == ["youtube"] && cd.detail.contains("DJ Lovd YouTube Shorts"))
    #expect(cd.title == "Reconnect YouTube Shorts in Postiz")
    #expect(p["postiz.rate_limited"]?.severity == .info && p["postiz.rate_limited"]?.title.contains("paused") == true)
    #expect(!r.passed.contains("postiz"))
    // Errors make `djq doctor` exit 2; the key itself never shows up.
    let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
    #expect(!json.contains("test-key-123"))
  }

  @Test func mappingMissingEscalatesWhenPostsAreDueWithin48Hours() throws {
    let later = try Rig(1, platforms: [.x], approve: false) { $0.publishing.channels[.x] = nil }
    let w = try #require(Self.postiz(Self.doctor(later.store, keys: later.keys).run())["postiz.mapping_missing"])
    #expect(w.severity == .warning && w.where_ == ["x"])
    let soon = try Rig(1, platforms: [.x]) { $0.publishing.channels[.x] = nil }
    let p = Self.postiz(Self.doctor(soon.store, keys: soon.keys).run())
    #expect(p["postiz.mapping_missing"]?.severity == .error)
    // The approved posts fall back to Today, with the reason.
    let fb = try #require(p["postiz.fallback"])
    let xPosts = try soon.f.posts(.x).map(\.id)
    #expect(fb.severity == .warning && !fb.where_.isEmpty && Set(fb.where_).isSubset(of: Set(xPosts)))
    #expect(fb.detail.contains("X · ") && fb.detail.contains("No Postiz channel picked"))
    // A mapped channel that disappeared from Postiz counts as missing too.
    let gone = try Rig(1, platforms: [.threads], approve: false)
    gone.fake.integrations.removeAll { $0.platform == .threads }
    _ = try gone.service.channels()
    #expect(Self.postiz(Self.doctor(gone.store, keys: gone.keys).run())["postiz.mapping_missing"]?.detail.contains("isn't in Postiz any more") == true)
  }

  @Test func stuckLinkMissingAndDeletePending() throws {
    let rig = try Rig(2, platforms: [.tiktok, .youtube, .x])
    rig.settle()
    rig.f.setTime("2026-11-02", "19:30")
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    rig.fake.publish(try #require(try rig.job(yt)).postizId!, url: "", releaseId: "missing")
    rig.tick()
    // TikTok (7:00 pm) is still QUEUE in Postiz more than an hour later.
    rig.f.setTime("2026-11-02", "20:30")
    let x = try #require(try rig.f.post(.x, day: "2026-11-03"))
    var xj = try #require(try rig.job(x))
    xj.phase = .deleting
    xj.attempts = 3
    xj.lastError = "server 500"
    try rig.store.save(xj)
    let before = try rig.store.db.one("SELECT total_changes() AS n")!.int("n")!
    let r = Self.doctor(rig.store, keys: rig.keys).run()
    #expect(try rig.store.db.one("SELECT total_changes() AS n")!.int("n")! == before)  // offline Doctor is read-only
    let p = Self.postiz(r)
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    let stuck = try #require(p["postiz.stuck"])
    #expect(stuck.severity == .error && stuck.where_.contains(tt.id) && stuck.fix.contains("djq postiz sync"))
    #expect(!stuck.where_.contains(yt.id))
    let lm = try #require(p["postiz.link_missing"])
    #expect(lm.severity == .warning && lm.where_ == [yt.id] && lm.fix.contains("djq postiz link"))
    let dp = try #require(p["postiz.delete_pending"])
    #expect(dp.severity == .warning && dp.where_ == [x.id] && dp.detail.contains("server 500"))
  }

  @Test func unconfirmedCreateIsAnErrorWithTheResolveFix() throws {
    let rig = try Rig(1, platforms: [.facebook])
    rig.settle()
    let fb = try #require(try rig.f.post(.facebook, day: "2026-11-02"))
    var j = try #require(try rig.job(fb))
    #expect(Self.postiz(Self.doctor(rig.store, keys: rig.keys).run())["postiz.create_unknown"] == nil)
    j.phase = .creating
    j.remoteState = PostizJob.unconfirmed
    try rig.store.save(j)
    let f = try #require(Self.postiz(Self.doctor(rig.store, keys: rig.keys).run())["postiz.create_unknown"])
    #expect(f.severity == .error && f.where_ == [fb.id] && f.fix.contains("djq postiz resolve") && f.fix.contains("Postiz calendar"))
  }

  @Test func doctorMakesNoCallUnlessLive() throws {
    let rig = try Rig(1, platforms: [.facebook], approve: false)
    let calls = rig.fake.log.count
    let d = Self.doctor(rig.store, keys: rig.keys)
    d.postizTransport = rig.fake
    _ = d.run()
    #expect(rig.fake.log.count == calls)
    // --live: one GET /integrations; a refused key is reported at once.
    rig.fake.key = "rotated"
    d.postizLive = true
    let p = Self.postiz(d.run())
    #expect(rig.fake.log.count == calls + 1 && rig.fake.log.last == "GET integrations")
    #expect(p["postiz.key_invalid"]?.severity == .error)
    // A Postiz that doesn't answer is a not_connected warning with the error.
    try rig.store.clearPostizKeyInvalid()
    rig.fake.key = "test-key-123"
    rig.fake.failNext["GET integrations"] = [503]
    let q = Self.postiz(d.run())
    #expect(q["postiz.not_connected"]?.severity == .warning && q["postiz.not_connected"]?.title.contains("didn't answer") == true)
    // A stale "key refused" flag is re-checked live (and cleared when Postiz accepts the key again).
    try rig.store.setPostizKeyInvalid("old 401")
    let r = Self.postiz(d.run())
    #expect(r["postiz.key_invalid"] == nil)
    #expect(try rig.store.postizKeyInvalid() == nil)
    #expect(rig.fake.log.suffix(2) == ["GET is-connected", "GET integrations"])
    // No budget left: no call, and it reads as a rate limit, not "didn't answer".
    let limit = try rig.store.settings().publishing.hourlyBudget
    while try rig.store.takePostizCall(.sync, limit: limit) {}
    let before = rig.fake.log.count
    let b = Self.postiz(d.run())
    #expect(rig.fake.log.count == before && b["postiz.not_connected"] == nil && b["postiz.rate_limited"]?.severity == .info)
    // Without a key there's nothing to check live.
    try rig.keys.delete()
    let n = rig.fake.log.count
    _ = d.run()
    #expect(rig.fake.log.count == n)
  }

  @Test func testModeIsVisibleUntilItsPostsAreGone() throws {
    let rig = try Rig(1, platforms: [.instagram]) { $0.publishing.testMode = true }
    rig.settle()
    var p = Self.postiz(Self.doctor(rig.store, keys: rig.keys).run())
    let tm = try #require(p["postiz.test_mode"])
    #expect(tm.severity == .info && tm.detail.contains("Test run is on") && !tm.where_.isEmpty)
    try rig.f.updateSettings { $0.publishing.testMode = false }
    p = Self.postiz(Self.doctor(rig.store, keys: rig.keys).run())
    #expect(p["postiz.test_mode"]?.title == "Test-run posts still in Postiz")
  }

  @Test func fallbackListsRefusedPostsWithPostizsReason() throws {
    let rig = try Rig(1, platforms: [.threads])
    rig.fake.failNext["POST posts"] = [400]
    rig.settle()
    let th = try #require(try rig.f.post(.threads, day: "2026-11-02"))
    #expect(try rig.store.finalPostizJob(postId: th.id)?.closeReason == .rejected)
    let fb = try #require(Self.postiz(Self.doctor(rig.store, keys: rig.keys).run())["postiz.fallback"])
    #expect(fb.where_ == [th.id] && fb.detail.contains("Postiz refused this post"))
  }

  /// Every id Doctor can report has a fix in the skill, and nothing reports an id outside the list.
  @Test func everyPostizIdHasASafeFixInTheSkill() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let skill = try String(contentsOf: repo.appendingPathComponent("skills/dj-queue-doctor/SKILL.md"), encoding: .utf8)
    for id in Doctor.postizCheckIds { #expect(skill.contains("| `\(id)` |"), "no fix row for \(id)") }
    let agent = try String(contentsOf: repo.appendingPathComponent("skills/dj-queue-agent/SKILL.md"), encoding: .utf8)
    for cmd in ["djq postiz status", "djq postiz channels", "djq postiz map", "djq postiz publisher", "djq postiz test-mode",
                "djq postiz test", "djq postiz link", "djq postiz sync"] {
      #expect(agent.contains(cmd), "agent skill doesn't document \(cmd)")
    }
    let src = try String(contentsOf: repo.appendingPathComponent("Sources/DJQCore/Engine/Doctor.swift"), encoding: .utf8)
    let used = Set(src.matches(of: #/id: "(postiz\.[a-z_]+)"/#).map { String($0.1) })
    #expect(used == Set(Doctor.postizCheckIds), "\(used.symmetricDifference(Doctor.postizCheckIds))")
  }
}
