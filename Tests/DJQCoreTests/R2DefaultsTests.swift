import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 2 #10 / #5: new clip defaults, override semantics, markers trim.
@Suite struct R2DefaultsTests {
  func clip(_ f: Fixture, _ id: String = "clip-0") throws -> Video { try #require(try f.store.video(id: id)) }

  @Test func trimDefaultsToMarkersPlusExtra() throws {
    let f = try Fixture()
    try f.intake()
    let v = try clip(f)  // 27.1 s, markers 3 … 24.1
    var d = NewClipDefaults()
    var r = EditResolver.resolve(Edit(), video: v, defaults: d)
    #expect(abs(r.trimIn - 3) < 1e-9 && abs(r.trimOut - 24.1) < 1e-9)
    #expect(r.isDefault(.trimIn) && r.isDefault(.trimOut))
    d.extraSecondsBefore = 1; d.extraSecondsAfter = 10
    r = EditResolver.resolve(Edit(), video: v, defaults: d)
    #expect(abs(r.trimIn - 2) < 1e-9 && abs(r.trimOut - 27.1) < 1e-9)  // clamped to the file
    d.trimMode = .wholeFile
    r = EditResolver.resolve(Edit(), video: v, defaults: d)
    #expect(r.trimIn == 0 && r.trimOut == 27.1)
    // An override wins per side and is not a default.
    var e = Edit()
    e.trimOut = 10
    r = EditResolver.resolve(e, video: v, defaults: NewClipDefaults())
    #expect(r.trimIn == 3 && r.trimOut == 10 && r.isDefault(.trimIn) && !r.isDefault(.trimOut))
    // No markers → whole file.
    var nm = v
    nm.markedStart = nil; nm.markedEnd = nil
    r = EditResolver.resolve(Edit(), video: nm, defaults: NewClipDefaults())
    #expect(r.trimIn == 0 && r.trimOut == 27.1)
  }

  @Test func editHashFollowsResolvedTrim() throws {
    let f = try Fixture()
    try f.intake()
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    let r = Renderer(store: f.store)
    let h1 = try r.editHash(videoId: "clip-0", versionNo: 1, platform: nil)
    var s = try f.store.settings()
    s.defaults.extraSecondsAfter = 2
    try f.store.save(s)
    let h2 = try r.editHash(videoId: "clip-0", versionNo: 1, platform: nil)
    #expect(h1 != h2)
    // Explicitly setting the same values as the resolved trim gives the same hash (hash = output, not storage).
    e.trimIn = 3; e.trimOut = 26.1
    try f.store.save(e, videoId: "clip-0")
    #expect(try r.editHash(videoId: "clip-0", versionNo: 1, platform: nil) == h2)
  }

  @Test func cropAnchors() throws {
    let src = CGSize(width: 3840, height: 2160)
    var d = NewClipDefaults()
    let c = d.defaultCrop(source: src, aspect: .r9x16)
    #expect(c == CropRect(x: 1312, y: 0, w: 1216, h: 2160))
    d.cropAnchor = .leftThird
    #expect(d.defaultCrop(source: src, aspect: .r9x16).x == 672)  // 1280 − 608
    d.cropAnchor = .rightThird
    #expect(d.defaultCrop(source: src, aspect: .r9x16).x == 1952)
    d.cropAnchor = .lastUsed
    #expect(d.defaultCrop(source: src, aspect: .r9x16, lastUsed: CGPoint(x: 0.99, y: 0.5)).x == 2624)  // clamped right
    #expect(d.defaultCrop(source: src, aspect: .r9x16, lastUsed: nil).x == 1312)  // falls back to centre
  }

  @Test func lastUsedCropIsRecordedFromConfirmedCrops() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.setSourceSize("clip-0", width: 3840, height: 2160)
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    let p = try #require(try f.store.lastCropCentre())
    #expect(abs(Double(p.x) - 608.0 / 3840) < 1e-9)
    var s = try f.store.settings()
    s.defaults.cropAnchor = .lastUsed
    try f.store.save(s)
    let r = try f.store.resolvedEdit(videoId: "clip-2", sourceSize: CGSize(width: 3840, height: 2160))
    #expect(r.crop?.x == 0 && !r.cropConfirmed && r.isDefault(.crop))
  }

  @Test func coverFrameOptions() throws {
    let f = try Fixture()
    try f.intake()
    let v = try clip(f)
    var d = NewClipDefaults()
    d.extraSecondsBefore = 2
    #expect(EditResolver.resolve(Edit(), video: v, defaults: d).coverTime == 1)  // trim start
    d.coverFrame = .markerIn
    #expect(EditResolver.resolve(Edit(), video: v, defaults: d).coverTime == 3)
    d.coverFrame = .offsetSeconds; d.coverOffsetSeconds = 1.5
    #expect(EditResolver.resolve(Edit(), video: v, defaults: d).coverTime == 2.5)
    var e = Edit()
    e.coverTime = 7
    e.coverIncludesTextOverride = false
    let r = EditResolver.resolve(e, video: v, defaults: d)
    #expect(r.coverTime == 7 && !r.coverIncludesText && !r.isDefault(.coverTime) && !r.isDefault(.coverIncludesText))
  }

  @Test func textDefaultsAndOverrides() throws {
    let f = try Fixture()
    try f.intake()
    var v = try clip(f)
    var s = Settings()
    // Title source with no title → empty (no guessing from the tag).
    var r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v)
    #expect(r.text == "" && !r.hasText && r.isDefault("text"))
    v.title = "Yayo x Johnny"
    r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v)
    #expect(r.text == "Yayo x Johnny" && r.isDefault("text"))
    s.defaults.textSource = .rawTag
    r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v)
    #expect(r.text == "yayo x johnny")  // verbatim
    s.defaults.textSource = .empty
    #expect(VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v).text == "")
    // Talking → No text by default.
    v.kind = .talking
    s.defaults.textSource = .title
    r = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v)
    #expect(r.noText && r.isDefault("noText"))
    s.defaults.noTextForTalking = false
    #expect(VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v).text == "Yayo x Johnny")
    // Style/position/timing defaults and an override.
    s.defaults.textStyle = .outline; s.defaults.textPosY = 0.2; s.defaults.textTiming = .firstSeconds; s.defaults.textFirstSeconds = 4
    var ver = Version(number: 1)
    ver.size = 80
    r = VersionResolver.resolve([ver], number: 1, settings: s, video: v)
    #expect(r.style == .outline && r.posY == 0.2 && r.textStart == 0 && r.textEnd == 4 && r.size == 80)
    #expect(r.isDefault("style") && !r.isDefault("size"))
  }

  @Test func platformsDefaultAndPerClipOverrides() throws {
    let f = try Fixture()
    try f.intake()
    let v = try clip(f)
    var d = NewClipDefaults()
    d.platforms = Set(Platform.allCases).subtracting([.threads])
    var e = Edit()
    #expect(EditResolver.resolve(e, video: v, defaults: d).isSkipped(.threads))
    e.includedPlatforms = [.threads]
    e.skippedPlatforms = [.x]
    let r = EditResolver.resolve(e, video: v, defaults: d)
    #expect(!r.isSkipped(.threads) && r.isSkipped(.x) && !r.isDefault(.platforms))
  }

  @Test func settingsDefaultsDecodeLeniently() throws {
    let f = try Fixture()
    // Older/partial nested JSON: missing keys keep their defaults; round-1 top-level keys seed `defaults`.
    try f.store.db.run("INSERT OR REPLACE INTO kv(key,json) VALUES('settings', ?)",
                       [#"{"postsPerDay":2,"defaultStyle":"outline","defaultTextSize":80,"defaultHashtagSetIds":["afrobeats"]}"#])
    var s = try f.store.settings()
    #expect(s.postsPerDay == 2 && s.defaults.textStyle == .outline && s.defaults.textSize == 80)
    #expect(s.defaults.hashtagSetIds == ["afrobeats"] && s.defaults.trimMode == .markers)
    s.defaults.aspect = .r4x5
    try f.store.save(s)
    try f.store.db.run("UPDATE kv SET json=? WHERE key='settings'", [#"{"defaults":{"aspect":"4:5","bogus":1}}"#])
    let s2 = try f.store.settings()
    #expect(s2.defaults.aspect == .r4x5 && s2.defaults.textStyle == .box && s2.defaults.youtubeTitleTemplate == "{text} | DJ Lovd")
  }

  @Test func resetClearsOverride() {
    var e = Edit()
    e.aspectOverride = .r1x1
    e.trimIn = 2
    EditResolver.reset(&e, .aspect)
    EditResolver.reset(&e, .trimIn)
    #expect(e.isEmpty)
  }

  @Test func readinessUsesResolvedValues() throws {
    let f = try Fixture()
    try f.intake()
    let id = "clip-0"
    var e = Edit()
    e.crop = CropRect(x: 1300, y: 0, w: 1216, h: 2160)
    try f.store.save(e, videoId: id)
    // Crop confirmed but no title → text missing; caption resolves from the default template.
    let issues = try Validation.issues(video: try clip(f, id), store: f.store)
    #expect(issues.map(\.kind) == [.noText])
    try f.store.setTitle(id, "Yayo x Johnny")
    try f.store.setSentToQueue(id, true)
    #expect(try f.store.video(id: id)?.state == .ready)  // no explicit v1 needed
    // A default template that doesn't exist is an issue.
    var s = try f.store.settings()
    s.defaults.captionTemplateId = "gone"
    try f.store.save(s)
    #expect(try Validation.issues(video: try clip(f, id), store: f.store).contains { $0.kind == .noCaption })
  }
}
