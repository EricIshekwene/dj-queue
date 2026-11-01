import Foundation
import Testing
@testable import DJQCore

// Round 2 #9: the Prefill formatter left the app. Its cases now live in `scripts/prefill_titles.py --self-test`
// (run by MetadataTests.prefillScriptSelfTest), unchanged.

@Suite struct CaptionTests {
  func video() -> Video {
    Video(id: "v", sessionId: "s", name: "2026-10-23 – Afroween Jazz Piano – yayo x johnny", tags: ["yayo x johnny"],
          type: .short, contentType: "dj vid", kind: .djVid, file: "f.mp4", fingerprint: nil, fileSize: nil, duration: 27,
          markedStart: nil, markedEnd: nil, start: nil, end: nil, grace: nil, audio: nil, part: nil, score: nil,
          state: .needsEdit, excluded: false, missing: false, inManifest: true, notes: "", alreadyPostedOn: [],
          longformURL: nil, createdAt: Date(), updatedAt: Date())
  }

  func resolved(_ edit: (inout Version) -> Void = { _ in }) -> ResolvedVersion {
    var v = Version(number: 1)
    v.text = "Yayo x Johnny"
    edit(&v)
    return VersionResolver.resolve([v], number: 1, settings: Settings())
  }

  @Test func defaultTemplateWithAutoHashtags() {
    let c = Captions.caption(for: .tiktok, version: resolved(), video: video(), sessionName: "2026-10-23 – Afroween Jazz Piano",
                             sets: Defaults.hashtagSets, templates: Defaults.captionTemplates, settings: Settings())
    #expect(c.hasPrefix("Yayo x Johnny\n\n🎧 Afroween Jazz Piano — full set on YouTube (link in bio)\n#amapiano #amapianomix #afrohouse #djlovd #dj #djlife #djmix #transition"))
    #expect(!c.contains("➜"))
  }

  // Round 2 #9 replaced the old "xCaptionDropsHashtagsToFit": nothing is dropped silently any more. The caption
  // stays over the limit (Validation reports it) and `withoutHashtags` is the explicit "Drop hashtags for X".
  @Test func overLimitCaptionIsKeptAndWithoutHashtagsIsExplicit() {
    let r = resolved { $0.extraHashtags = (0..<40).map { "#tag\($0)" } }
    let c = Captions.caption(for: .x, version: r, video: video(), sessionName: "2026-10-23 – Afroween Jazz Piano",
                             sets: Defaults.hashtagSets, templates: Defaults.captionTemplates, settings: Settings())
    #expect(c.count > 280)
    #expect(c.contains("#tag39"))
    let bare = Captions.withoutHashtags(for: .x, version: r, video: video(), sessionName: "2026-10-23 – Afroween Jazz Piano",
                                        templates: Defaults.captionTemplates, settings: Settings())
    #expect(bare.count <= 280)
    #expect(bare.hasPrefix("Yayo x Johnny") && !bare.contains("#"))
  }

  @Test func platformOverrideWins() {
    let r = resolved { $0.platformCaptions = [.x: "custom"] }
    #expect(Captions.caption(for: .x, version: r, video: video(), sessionName: "s", sets: [], templates: [], settings: Settings()) == "custom")
  }

  @Test func multiLineTextFlattened() {
    #expect(Captions.oneLine("Mabalabala\nx\nA Collision") == "Mabalabala x A Collision")
  }

  @Test func youtubeTitle() {
    #expect(Captions.youtubeTitle(resolved(), video: video()) == "Yayo x Johnny | DJ Lovd")
  }
}

@Suite struct VersionTests {
  @Test func carryForward() {
    var v1 = Version(number: 1)
    v1.text = "Yayo x Johnny"
    v1.caption = "first"
    v1.style = .outline
    var v2 = Version(number: 2)
    v2.text = "Wait for the drop"
    v2.caption = ""
    let r = VersionResolver.resolve([v1, v2], number: 2, settings: Settings())
    #expect(r.text == "Wait for the drop")
    #expect(r.caption == "first")
    #expect(r.style == .outline)
    #expect(r.inherited.contains("caption"))
    #expect(!r.inherited.contains("text"))
  }

  @Test func defaultsFromSettings() {
    let r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: Settings())
    #expect(r.style == .box)
    #expect(r.posY == 0.5)
    #expect(r.hashtagSetIds == ["amapiano", "dj"])
  }
}

@Suite struct ValidationTests {
  @Test func readyNeedsCropTextCaptionAndLimits() throws {
    let f = try Fixture()
    try f.intake()
    let id = "clip-0"
    #expect(try f.store.video(id: id)?.state == .needsEdit)
    var e = Edit()
    e.crop = CropRect(x: 1300, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: id)
    var v1 = Version(number: 1)
    v1.text = "Yayo x Johnny"
    v1.captionTemplateId = "set-link"
    try f.store.save(v1, videoId: id)
    #expect(try f.store.video(id: id)?.state == .ready)
  }

  @Test func tooLongForXAndFacebook() throws {
    let f = try Fixture()
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-1"))  // poosh 5, 158 s
    let issues = Validation.platformIssues(video: v, edit: Edit(), settings: Settings())
    #expect(Set(issues.compactMap(\.platform)) == [.x, .facebook])
    // Round 2: the default trim is the markers (3 s in from each end) → 152 s, not the whole 158 s file.
    #expect(issues.contains { $0.message == "Too long for X (2:32 > 2:20)" && $0.count == 152 && $0.limit == 140 })
    var e = Edit()
    e.platformTrims[.x] = TrimRange(start: 0, end: 130)
    e.skippedPlatforms = [.facebook]
    #expect(Validation.platformIssues(video: v, edit: e, settings: Settings()).isEmpty)
  }
}
