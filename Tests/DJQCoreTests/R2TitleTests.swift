import CryptoKit
import Foundation
import Testing
@testable import DJQCore

/// Round 2 #2/#3/#9: titles and suggestions from metadata; no in-app intelligence.
@Suite struct R2TitleTests {
  @Test func intakeSeedsTitleOnlyWhenEmpty() throws {
    let f = try Fixture()
    f.entries[1]["title"] = "Yayo x Johnny"
    try f.saveManifest()
    try f.intake()
    var v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.title == "Yayo x Johnny" && v.titleSource == "manifest" && v.displayName == "Yayo x Johnny")
    // Eric changes it in the app; a changed manifest title never overwrites it.
    try f.store.setTitle("clip-0", "Yayo × Johnny (live)")
    f.entries[1]["title"] = "Something else"
    try f.saveManifest()
    try f.intake()
    v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.title == "Yayo × Johnny (live)" && v.titleSource == "app")
    // The changed manifest title is offered as a suggestion instead.
    #expect(try f.store.titleSuggestions(videoId: "clip-0").map(\.text) == ["Something else"])
    // Cleared in the app → stays cleared (tombstone); the manifest title stays a suggestion only.
    try f.store.setTitle("clip-0", nil)
    try f.intake()
    v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.title == nil && v.titleSource == Store.clearedTitleSource && v.displayName == "yayo x johnny")
    #expect(try f.store.titleSuggestions(videoId: "clip-0").first?.source == "videos.json title")
    // Clearing through bulk (and `djq title --clear`, which calls setTitle(nil)) leaves the same tombstone.
    f.entries[2]["title"] = "Poosh Five"
    try f.saveManifest()
    try f.intake()
    #expect(try f.store.video(id: "clip-1")?.title == "Poosh Five")
    try BulkActions(store: f.store).setTitle(["clip-1"], nil)
    try f.intake()
    #expect(try f.store.video(id: "clip-1")?.title == nil)
    // No title anywhere → display name is the raw tag verbatim.
    #expect(try f.store.video(id: "clip-1")?.displayName == "poosh 5")
  }

  @Test func manifestSuggestionsSyncAndAgentOnesStay() throws {
    let f = try Fixture()
    f.entries[1]["title_suggestions"] = [
      ["text": "Yayo x Johnny", "tracks": [["title": "Yayo", "artist": "A"], ["title": "Johnny"]], "confidence": 0.7, "source": "rekordbox"],
      ["text": "Yayo", "confidence": 0.2],
    ]
    f.entries[2]["title_suggestions"] = "not a list"  // malformed → ignored, manifest still imports
    try f.saveManifest()
    let rep = try f.intake()
    #expect(rep.parseErrors.isEmpty)
    var s = try f.store.titleSuggestions(videoId: "clip-0")
    #expect(s.map(\.text) == ["Yayo x Johnny", "Yayo"])
    #expect(s[0].tracks == [Track(title: "Yayo", artist: "A"), Track(title: "Johnny")] && s[0].origin == "manifest")
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Yayo x Johnny (agent)", confidence: 0.9, source: "agent")])
    // Manifest list changes → manifest-origin rows replaced; agent row kept; best first.
    f.entries[1]["title_suggestions"] = [["text": "Yayo x Jonny", "confidence": 0.5]]
    try f.saveManifest()
    try f.intake()
    s = try f.store.titleSuggestions(videoId: "clip-0")
    #expect(s.map(\.text) == ["Yayo x Johnny (agent)", "Yayo x Jonny"])
    // Intake never sets a title from suggestions.
    #expect(try f.store.video(id: "clip-0")?.title == nil)
  }

  @Test func identicalManifestSuggestionsAreNotRewritten() throws {
    let f = try Fixture()
    f.entries[1]["title_suggestions"] = [
      ["text": "A x B", "confidence": 0.5, "source": "s"],
      ["text": "  ", "confidence": 0.9],  // empty: never stored
      ["text": "A x B", "confidence": 0.5, "source": "s"],  // duplicate text+source
    ]
    try f.saveManifest()
    try f.intake()
    let first = try f.store.titleSuggestions(videoId: "clip-0")
    #expect(first.map(\.text) == ["A x B"])
    try f.intake()
    #expect(try f.store.titleSuggestions(videoId: "clip-0").map(\.id) == first.map(\.id))  // same rows, no churn
  }

  @Test func suggestionImportShapes() throws {
    let many = #"[{"video_id":"a","title_suggestions":[{"text":"A x B","tracks":[{"title":"A"}],"confidence":0.8,"source":"s"}]},{"video_id":"b","title_suggestions":[{"text":"C"}]}]"#
    let r = try SuggestionImport.parse(Data(many.utf8))
    #expect(r.map(\.videoId) == ["a", "b"] && r[0].suggestions[0].tracks == [Track(title: "A")])
    let one = #"{"title_suggestions":[{"text":"X"}]}"#
    #expect(try SuggestionImport.parse(Data(one.utf8), videoId: "z")[0].videoId == "z")
    let bare = #"[{"text":"Y","confidence":0.4}]"#
    #expect(try SuggestionImport.parse(Data(bare.utf8), videoId: "z")[0].suggestions[0].confidence == 0.4)
    #expect(throws: (any Error).self) { try SuggestionImport.parse(Data(one.utf8)) }  // no video id
    #expect(throws: (any Error).self) { try SuggestionImport.parse(Data(#"[{"video_id":"a","title_suggestions":[{"text":"x","confidence":3}]}]"#.utf8)) }
  }

  @Test func captionAndYouTubeFallbacksAreTitleThenRawTag() throws {
    let f = try Fixture()
    try f.intake()
    var v = try #require(try f.store.video(id: "clip-0"))
    let r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: Settings(), video: v)
    let c = Captions.caption(for: .tiktok, version: r, video: v, sessionName: "2026-10-23 – Afroween Jazz Piano",
                             sets: [], templates: Defaults.captionTemplates, settings: Settings())
    #expect(c.hasPrefix("yayo x johnny\n"))  // raw tag verbatim — never tidied to "Yayo x Johnny"
    #expect(Captions.youtubeTitle(r, video: v) == "yayo x johnny | DJ Lovd")
    v.title = "Yayo x Johnny"
    let r2 = VersionResolver.resolve([Version(number: 1)], number: 1, settings: Settings(), video: v)
    #expect(Captions.youtubeTitle(r2, video: v) == "Yayo x Johnny | DJ Lovd")
    var s = Settings()
    s.youtubeTitleTemplates = [TitleTemplate(id: "text-djlovd", name: "x", template: "DJ Lovd — {text}")]
    #expect(Captions.youtubeTitle(r2, video: v, settings: s) == "DJ Lovd — Yayo x Johnny")
    // Template keeps its fixed part when {text} is shortened.
    v.title = String(repeating: "Long ", count: 40)
    let r3 = VersionResolver.resolve([Version(number: 1)], number: 1, settings: Settings(), video: v)
    let t = Captions.youtubeTitle(r3, video: v)
    #expect(t.count == 100 && t.hasSuffix("… | DJ Lovd"))
  }

  @Test func perPlatformDefaultTemplate() throws {
    let f = try Fixture()
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-0"))
    var s = Settings()
    s.defaults.platformCaptionTemplates = [.x: "short"]
    s.defaults.hashtagSetIds = Defaults.legacyDefaultHashtagSetIds
    let r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v)
    let x = Captions.caption(for: .x, version: r, video: v, sessionName: "s", sets: Defaults.legacyHashtagSets,
                             templates: Defaults.captionTemplates, settings: s)
    #expect(x.hasPrefix("yayo x johnny #amapiano"))
    var ver = Version(number: 1)
    ver.captionTemplateId = "tracks"  // the clip's own choice beats the per-platform default
    let r2 = VersionResolver.resolve([ver], number: 1, settings: s, video: v)
    #expect(Captions.templateId(for: .x, version: r2, settings: s) == "tracks")
  }

  @Test func overLimitIssueCarriesNumbersForExplicitActions() throws {
    let f = try Fixture()
    try f.intake()
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    var v1 = Version(number: 1)
    v1.text = "Yayo x Johnny"
    v1.extraHashtags = (0..<45).map { "#tag\($0)" }
    try f.store.save(v1, videoId: "clip-0")
    let v = try #require(try f.store.video(id: "clip-0"))
    let issue = try #require(try Validation.issues(video: v, store: f.store).first { $0.kind == .captionTooLong && $0.platform == .x })
    #expect((issue.count ?? 0) > 280 && issue.limit == 280 && (issue.countWithoutHashtags ?? 999) <= 280)
    // The explicit action fixes it.
    let r = try BulkActions(store: f.store).dropHashtags(["clip-0"], platform: .x)
    #expect(r.changed == ["clip-0"])
    #expect(try Validation.issues(video: v, store: f.store).allSatisfy { !($0.kind == .captionTooLong && $0.platform == .x) })
  }

  @Test func prefillScriptSelfTest() throws {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("scripts/prefill_titles.py")
    guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }
    let r = try Proc.run("/usr/bin/python3", [script.path, "--self-test"], timeout: 60)
    #expect(r.status == 0, "\(r.stdout)\(r.stderr)")
    // Round trip: the script's suggestions are what intake imports.
    let f = try Fixture()
    let manifest = f.sessionDir.appendingPathComponent("videos.json")
    let out = try Proc.run("/usr/bin/python3", [script.path, manifest.path, "--in-place"], timeout: 60)
    #expect(out.status == 0, "\(out.stderr)")
    try f.intake()
    let s = try f.store.titleSuggestions(videoId: "clip-3")
    #expect(s.first?.text == "Asabone x Forgiveness" && s.first?.source == "prefill_titles.py" && s.first?.confidence == 0.3)
    #expect(try f.store.video(id: "clip-3")?.title == nil)
  }
}
