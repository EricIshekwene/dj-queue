import Foundation
import Testing
@testable import DJQCore

/// Round 30 (Eric, 2026-11-12): "When I change a clip's trim while editing v3, only v3 changes. v1 and v2 keep their own
/// start and end." Each version can have its own trim; everything that renders, posts, covers or checks a version
/// uses that version's trim, and its texts count from its own start.
@Suite struct R30VersionTrimTests {
  /// clip-0 (20 s, markers 3–17) with v1, v2 and v3, each with a timed text.
  private func threeVersions() throws -> Fixture {
    let f = try Fixture.engine(1)
    for n in 1...3 {
      var v = try f.store.versions(videoId: "clip-0").first { $0.number == n } ?? Version(number: n)
      v.text = "Text v\(n)"
      v.textStart = 2
      v.textEnd = 9
      if n > 1 { v.standalone = true }
      try f.store.save(v, videoId: "clip-0")
    }
    return f
  }

  private func re(_ f: Fixture, _ n: Int) throws -> ResolvedEdit { try f.store.resolvedEdit(videoId: "clip-0", version: n) }

  @Test func aVersionTrimLeavesTheOtherVersionsAlone() throws {
    let f = try threeVersions()
    let clip = try re(f, 1).trim()
    let editBefore = try f.store.edit(videoId: "clip-0")
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    #expect(try re(f, 3).trim() == TrimRange(start: 5, end: 12))
    #expect(try re(f, 3).trimVersion == 3 && re(f, 3).hasVersionTrim)
    #expect(try re(f, 1).trim() == clip && re(f, 2).trim() == clip)
    #expect(try re(f, 1).trimVersion == nil && re(f, 2).trimVersion == nil)
    #expect(try f.store.edit(videoId: "clip-0") == editBefore, "the clip's trim is untouched")
    // v1 and v2 keep their texts exactly; nothing was clamped.
    for n in 1...2 {
      let v = try #require(try f.store.versions(videoId: "clip-0").first { $0.number == n })
      #expect(v.textStart == 2 && v.textEnd == 9 && !v.hasOwnTrim)
    }
    // A clip trim change reaches v1 and v2 only.
    try VersionTrims.setClip(store: f.store, videoId: "clip-0", start: 4, end: 15)
    #expect(try re(f, 1).trim() == TrimRange(start: 4, end: 15) && re(f, 2).trim() == TrimRange(start: 4, end: 15))
    #expect(try re(f, 3).trim() == TrimRange(start: 5, end: 12))
  }

  @Test func textTimesCountFromTheirOwnVersionsTrim() throws {
    let f = try threeVersions()
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 10, end: 14)  // 4 s
    let s = try f.store.settings()
    let r3 = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 3, settings: s))
    let r1 = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1, settings: s))
    let o3 = AgentAPI.overlays(r3, edit: try re(f, 3))
    let o1 = AgentAPI.overlays(r1, edit: try re(f, 1))
    // v3's text runs 2…4 s of its own 4 s trim (10 + 2 = 12 s into the file); v1's runs its full 2…9 s.
    #expect(o3.first?.shows_from == 2 && o3.first?.shows_to == 4)
    #expect(o3.first?.trim_in == 10 && o3.first?.own_trim == true)
    #expect(o1.first?.shows_from == 2 && o1.first?.shows_to == 9)
    #expect(o1.first?.own_trim == false)
  }

  @Test func renderPlansUseEachVersionsTrim() throws {
    let f = try threeVersions()
    let r = Renderer(store: f.store)
    let h1 = try r.plan(videoId: "clip-0", versionNo: 1, platform: nil).hash
    let h2 = try r.plan(videoId: "clip-0", versionNo: 2, platform: nil).hash
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    let p3 = try r.plan(videoId: "clip-0", versionNo: 3, platform: nil)
    #expect(p3.trim == TrimRange(start: 5, end: 12))
    #expect(try r.plan(videoId: "clip-0", versionNo: 1, platform: nil).hash == h1, "v1's render isn't touched")
    #expect(try r.plan(videoId: "clip-0", versionNo: 2, platform: nil).hash == h2, "v2's render isn't touched")
    #expect(try r.plan(videoId: "clip-0", versionNo: 1, platform: nil).trim == re(f, 1).trim())
  }

  @Test func theClipsPlatformTrimsBelongToTheClipsTrim() throws {
    let f = try threeVersions()
    var e = try f.store.edit(videoId: "clip-0")
    e.platformTrims[.x] = TrimRange(start: 4, end: 8)
    try f.store.save(e, videoId: "clip-0")
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    let r = Renderer(store: f.store)
    #expect(try r.scope(videoId: "clip-0", versionNo: 1, platform: .x) == "x")
    #expect(try r.scope(videoId: "clip-0", versionNo: 3, platform: .x) == "all")
    #expect(try re(f, 3).platformTrims.isEmpty)
    #expect(try re(f, 3).trim(platform: .x) == TrimRange(start: 5, end: 12))
    // A version's own per-platform trim is its own.
    var v3 = try #require(try f.store.versions(videoId: "clip-0").first { $0.number == 3 })
    v3.platformTrims = [.x: TrimRange(start: 6, end: 9)]
    try f.store.save(v3, videoId: "clip-0")
    #expect(try r.scope(videoId: "clip-0", versionNo: 3, platform: .x) == "x")
    #expect(try r.plan(videoId: "clip-0", versionNo: 3, platform: .x).trim == TrimRange(start: 6, end: 9))
    #expect(try r.plan(videoId: "clip-0", versionNo: 1, platform: .x).trim == TrimRange(start: 4, end: 8))
  }

  @Test func platformLengthChecksUseEachVersionsTrim() throws {
    let f = try threeVersions()
    var s = try f.store.settings()
    let clipLength = try re(f, 1).trim().duration
    s.limits[.facebook]?.maxDuration = clipLength - 4
    try f.store.save(s)
    let v = try #require(try f.store.video(id: "clip-0"))
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 9)
    let long = Validation.platformIssues(video: v, resolved: try re(f, 1), settings: s)
    let short = Validation.platformIssues(video: v, resolved: try re(f, 3), settings: s)
    #expect(long.contains { $0.kind == .tooLong && $0.platform == .facebook })
    #expect(!short.contains { $0.kind == .tooLong })
    // What a too_long failure waits on is the post's own version's trim.
    #expect(PostActions.trimSignature(try re(f, 3), .facebook) != PostActions.trimSignature(try re(f, 1), .facebook))
  }

  @Test func theCoverFollowsTheVersionsTrim() throws {
    let f = try threeVersions()
    var e = try f.store.edit(videoId: "clip-0")
    e.coverTime = 3.5
    try f.store.save(e, videoId: "clip-0")
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 8, end: 14)
    // The clip's cover (3.5 s) isn't in v3's trim: v3's cover falls back to the default rule inside its own trim.
    let c3 = try re(f, 3).coverTime
    #expect(c3 >= 8 && c3 <= 14)
    #expect(try re(f, 1).coverTime == 3.5)
    // A cover inside v3's trim is kept.
    e.coverTime = 9
    try f.store.save(e, videoId: "clip-0")
    #expect(try re(f, 3).coverTime == 9)
    // Postiz's cover time counts from the start of v3's render.
    let render = Render(id: "r", videoId: "clip-0", versionNo: 3, editHash: "h", scope: "all", outputPath: nil, coverPath: nil,
                        loudness: nil, duration: 6, size: nil, status: .done, error: nil, createdAt: Date(), deletedAt: nil)
    #expect(PostizPayload.coverMs(edit: try re(f, 3), render: render, platform: .instagram) == 1000)
  }

  /// Review: the clip's one cover must be a frame of whatever trim is resolved, the clip's own included.
  @Test func aCoverOutsideTheClipsTrimFallsBackInside() throws {
    let f = try threeVersions()
    var e = try f.store.edit(videoId: "clip-0")
    e.coverTime = 16
    try f.store.save(e, videoId: "clip-0")
    try VersionTrims.setClip(store: f.store, videoId: "clip-0", start: 4, end: 10)
    let c = try re(f, 1).coverTime
    #expect(c >= 4 && c <= 10)
  }

  /// Review: a version's per-platform trims are stored as a keyed object, so the row's JSON never changes order.
  @Test func versionPlatformTrimsStoreDeterministically() throws {
    var v = Version(number: 3)
    v.trimIn = 1; v.trimOut = 9
    v.platformTrims = [.x: TrimRange(start: 2, end: 5), .facebook: TrimRange(start: 1, end: 8), .tiktok: TrimRange(start: 1, end: 3)]
    let a = JSONCoding.string(v), b = JSONCoding.string(v)
    #expect(a == b)
    #expect(a.contains("\"trimsByPlatform\":{\"facebook\""))
    let back = try JSONCoding.decoder.decode(Version.self, from: Data(a.utf8))
    #expect(back.platformTrims?[.x] == TrimRange(start: 2, end: 5) && back == v)
  }

  @Test func djqTrimRulesAndDefaults() throws {
    let f = try threeVersions()
    let def = try re(f, 1).trim()
    #expect(throws: VersionTrims.TrimProblem.self) { try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 40) }
    #expect(throws: VersionTrims.TrimProblem.self) { try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 5.1) }
    #expect(throws: VersionTrims.TrimProblem.self) { try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 7, start: 5, end: 9) }
    // One side alone keeps the other as the version shows it.
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 2, start: 6, end: nil)
    #expect(try re(f, 2).trim() == TrimRange(start: 6, end: def.end))
    try VersionTrims.clearOwn(store: f.store, videoId: "clip-0", version: 2)
    #expect(try re(f, 2).trim() == def && !re(f, 2).hasVersionTrim)
    // The clip's trim set to the default reads as the default.
    try VersionTrims.setClip(store: f.store, videoId: "clip-0", start: def.start, end: def.end)
    #expect(try f.store.edit(videoId: "clip-0").trimIn == nil && f.store.edit(videoId: "clip-0").trimOut == nil)
    try VersionTrims.setClip(store: f.store, videoId: "clip-0", start: 4, end: nil)
    var e = try f.store.edit(videoId: "clip-0")
    #expect(e.trimIn == 4 && e.trimOut == nil)
    e.platformTrims[.x] = TrimRange(start: 4, end: 8)
    try f.store.save(e, videoId: "clip-0")
    try VersionTrims.resetClip(store: f.store, videoId: "clip-0")
    e = try f.store.edit(videoId: "clip-0")
    #expect(e.trimIn == nil && e.trimOut == nil && e.platformTrims.isEmpty)
    // `djq video --json` lists each version's trim.
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    let trims = try AgentAPI.video("clip-0", store: f.store).version_trims
    #expect(trims.map(\.version) == [1, 2, 3])
    #expect(trims.map(\.own) == [false, false, true])
    #expect(trims[2].trim_in == 5 && trims[2].trim_out == 12 && trims[0].clip_default)
  }

  @Test func aTrimChangeUndoesAsOneStep() throws {
    let f = try threeVersions()
    let bulk = BulkActions(store: f.store)
    let before = try f.store.versions(videoId: "clip-0")
    let r = try bulk.record("trim", ids: ["clip-0"]) {
      try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    }
    let id = try #require(r.batchId)
    #expect(try re(f, 3).hasVersionTrim)
    _ = try bulk.undo(id)
    #expect(try !re(f, 3).hasVersionTrim)
    #expect(try f.store.versions(videoId: "clip-0").map(\.trimIn) == before.map(\.trimIn))
  }

  @Test func aCopyOfAVersionTakesItsOwnTrim() throws {
    let f = try threeVersions()
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    let all = try f.store.versions(videoId: "clip-0")
    let s = try f.store.settings()
    let fromV3 = VersionCopy.duplicate(all, source: 3, as: 4, settings: s)
    let fromV1 = VersionCopy.duplicate(all, source: 1, as: 5, settings: s)
    #expect(fromV3.trimIn == 5 && fromV3.trimOut == 12)
    #expect(!fromV1.hasOwnTrim)
  }

  @Test func aBulkTrimResetClearsVersionTrims() throws {
    let f = try threeVersions()
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 5, end: 12)
    try BulkActions(store: f.store).applyDefaults(["clip-0"], sections: [.trim])
    #expect(try !re(f, 3).hasVersionTrim)
    #expect(try re(f, 3).trim() == re(f, 1).trim())
  }

  /// Eric's data (2026-11-05 Mix Session): a trim made for v3 on the clip. The repair moves it onto v3 and puts the
  /// clip back on the default, so v1 and v2 have their full length again and v3 shows exactly what it showed.
  @Test func movingAClipTrimOntoV3() throws {
    let f = try threeVersions()
    try VersionTrims.setClip(store: f.store, videoId: "clip-0", start: 6.2, end: 10.4)
    var e = try f.store.edit(videoId: "clip-0")
    e.platformTrims[.facebook] = TrimRange(start: 6.3, end: 10.6)
    try f.store.save(e, videoId: "clip-0")
    let r = Renderer(store: f.store)
    let v3Before = try r.plan(videoId: "clip-0", versionNo: 3, platform: nil)
    try VersionTrims.setOwn(store: f.store, videoId: "clip-0", version: 3, start: 6.2, end: 10.4)
    try VersionTrims.resetClip(store: f.store, videoId: "clip-0")
    let v3After = try r.plan(videoId: "clip-0", versionNo: 3, platform: nil)
    #expect(v3After.trim == v3Before.trim)
    #expect(v3After.hash == v3Before.hash, "v3's video is exactly what it was")
    let def = try f.store.settings().defaults.trim(for: try #require(try f.store.video(id: "clip-0")))
    #expect(try re(f, 1).trim() == def && re(f, 2).trim() == def)
    #expect(try re(f, 1).platformTrims.isEmpty)
  }
}

@Suite struct R30TimeFormatTests {
  /// `djq trim` printed 2:60.0 for 179.97 s.
  @Test func tenthsRoundBeforeTheMinute() {
    #expect(EditorLogic.time(179.97, tenths: true) == "3:00.0")
    #expect(EditorLogic.time(59.96, tenths: true) == "1:00.0")
    #expect(EditorLogic.time(23.155, tenths: true) == "0:23.2")
    #expect(EditorLogic.time(0, tenths: true) == "0:00.0")
  }
}
