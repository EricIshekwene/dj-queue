import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import Testing
@testable import DJQCore

private func extra(_ text: String, id: String? = nil, start: Double? = nil, end: Double? = nil, look: TextLook? = nil,
                   posY: Double = 0.7) -> TextLayer {
  TextLayer(id: id ?? TextLayer.newId(), text: text, posY: posY, start: start, end: end, look: look)
}

private func version(_ n: Int, _ change: (inout Version) -> Void = { _ in }) -> Version {
  var v = Version(number: n)
  change(&v)
  return v
}

private func resolve(_ vs: [Version], _ n: Int? = nil, video: Video? = nil) -> ResolvedVersion {
  VersionResolver.resolve(vs, number: n ?? vs.last!.number, settings: Settings(), video: video)
}

/// S1-R3: a clip with no extras and no look must not re-render, and its overlay and preview stamp stay the same.
@Suite struct R16GoldenTests {
  /// Values printed by the build before round 16 (base 23a9d22) for this exact fixture. Fake clip bytes, so they depend
  /// on nothing but the hash input. A `pipelineVersion` bump changes them on purpose.
  @Test func editHashesMatchTheBuildBeforeThisChange() throws {
    let f = try Fixture(clips: [("yayo x johnny", 4.0)], longform: false)
    try f.intake()
    let id = "clip-0", renderer = Renderer(store: f.store)
    var e = Edit()
    e.crop = CropRect(x: 657, y: 0, w: 607.5, h: 1080); e.trimIn = 0.5; e.trimOut = 3.5; e.coverTime = 1
    try f.store.save(e, videoId: id)
    var v = Version(number: 1)
    v.text = "Yayo x Johnny 🔥"; v.caption = "caption"; v.textStart = 1; v.textEnd = 2; v.style = .outline
    try f.store.save(v, videoId: id)
    #expect(try renderer.editHash(videoId: id, versionNo: 1, platform: nil) == "0389f4221b834481")
    e.platformTrims = [.x: TrimRange(start: 1, end: 2)]
    try f.store.save(e, videoId: id)
    #expect(try renderer.editHash(videoId: id, versionNo: 1, platform: .x) == "93596be90cde2ca5")

    // Neither an empty list, a blank extra nor a look that changes nothing is a change.
    v.moreText = []; v.textLook = TextLook(font: .standard, opacity: 1, tracking: 0)
    try f.store.save(v, videoId: id)
    #expect(try renderer.editHash(videoId: id, versionNo: 1, platform: .x) == "93596be90cde2ca5")
    v.moreText = [extra("   ")]
    try f.store.save(v, videoId: id)
    #expect(try renderer.editHash(videoId: id, versionNo: 1, platform: .x) == "93596be90cde2ca5")

    // "No text" hides everything: extras stored or not, it's the old no-text hash.
    v.moreText = nil; v.textLook = nil; v.noText = true; v.text = nil
    try f.store.save(v, videoId: id)
    #expect(try renderer.editHash(videoId: id, versionNo: 1, platform: nil) == "550e70c2944d415a")
    v.moreText = [extra("Hidden")]; v.textLook = TextLook(color: "#FF0000")
    try f.store.save(v, videoId: id)
    #expect(try renderer.editHash(videoId: id, versionNo: 1, platform: nil) == "550e70c2944d415a")
  }

  @Test func extrasAndLooksDoChangeTheHash() throws {
    let rf = try RenderFixture()
    let base = try rf.hash()
    try rf.version { $0.textLook = TextLook(color: "#FF0000") }
    let look = try rf.hash()
    #expect(look != base)
    try rf.version { $0.textLook = TextLook(color: "#ff0000") }
    #expect(try rf.hash() == look)  // the same colour written differently
    try rf.version { $0.textLook = nil; $0.moreText = [extra("Two", id: "a", start: 1)] }
    let more = try rf.hash()
    #expect(more != base)
    try rf.version { $0.moreText = [extra("Two", id: "b", start: 1)] }
    #expect(try rf.hash() == more)  // an id isn't output
    try rf.version { $0.moreText = [extra("Two", id: "a", start: 2)] }
    #expect(try rf.hash() != more)
  }

  /// The same PNG bytes as before round 16. System fonts can change with macOS, so this runs only on the build that
  /// recorded them; `lossless.txt` holds the comparison over every real clip.
  @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersionString == "Version 27.2 (Build 26B123)"))
  func overlayBytesMatchTheBuildBeforeThisChange() throws {
    func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    let golden: [TextStyle: String] = [
      .box: "c152e28f08670192fff356afbc7b69f521893751c75e898a850810df8d60fa08",
      .outline: "0c66b2f5c33bca2ddc2082f0113bde3e469658e80abac96a6de0ecfd8b90d7cd",
      .shadow: "4724a936b1e38cc80fa4cb1f2de51e7bcb44bbe36692f2a828f34d11f83d821e",
    ]
    for (style, want) in golden {
      let png = try #require(TextOverlay.png(for: resolved("Song One\nx\nSong Two 🔥", style: style), aspect: .r9x16))
      #expect(sha(png) == want, "\(style)")
    }
  }

  @Test func nilLookPNGIsIdenticalThroughEveryDoor() throws {
    for style in TextStyle.allCases {
      let v = resolved("Song One\nx\nSong Two 🔥", style: style)
      let old = try #require(TextOverlay.png(for: v, aspect: .r9x16))
      #expect(TextOverlay.png(for: v.firstLayer, aspect: .r9x16) == old)
      var l = v.firstLayer
      l.look = TextLook()
      #expect(TextOverlay.png(for: l, aspect: .r9x16) == old)
      l.look = TextLook(font: .standard, opacity: 1, tracking: 0)
      #expect(TextOverlay.png(for: l, aspect: .r9x16) == old)
      let one = try #require(TextOverlay.image(for: [v.firstLayer], aspect: .r9x16))
      #expect(TextOverlay.pngData(one) == old)
      #expect(TextOverlay.textBounds(for: v.firstLayer, aspect: .r9x16) == TextOverlay.textBounds(for: v, aspect: .r9x16))
    }
  }

  @Test func textKeyIsUnchangedWithoutExtrasOrLook() throws {
    #expect(PreviewKeys.textKey(resolved("Song One"), aspect: .r9x16) == "3bb2381fcfd691c8")  // from the build before
    let v = resolved("Song One")
    #expect(PreviewKeys.layerKey(v.firstLayer, aspect: .r9x16) == PreviewKeys.textKey(v, aspect: .r9x16))
    #expect(PreviewKeys.coverKey([v.firstLayer], aspect: .r9x16) == PreviewKeys.textKey(v, aspect: .r9x16))
    #expect(PreviewKeys.textKey(resolved(noText: true), aspect: .r9x16) == "none")
    #expect(PreviewKeys.coverKey([], aspect: .r9x16) == "none")

    var more = v
    more.moreText = [extra("Two", id: "a", start: 1)]
    let k1 = PreviewKeys.textKey(more, aspect: .r9x16)
    #expect(k1 != PreviewKeys.textKey(v, aspect: .r9x16))
    more.moreText = [extra("Two", id: "a", start: 2)]
    #expect(PreviewKeys.textKey(more, aspect: .r9x16) != k1)  // windows decide what shows when
    var looked = v
    looked.textLook = TextLook(color: "#00FF00")
    #expect(PreviewKeys.textKey(looked, aspect: .r9x16) != PreviewKeys.textKey(v, aspect: .r9x16))
    #expect(PreviewKeys.layerKey(looked.firstLayer, aspect: .r9x16) != PreviewKeys.layerKey(v.firstLayer, aspect: .r9x16))
    // A layer's pixels don't depend on its window.
    var a = extra("Two", id: "x", start: 1), b = a
    b.start = 2
    #expect(PreviewKeys.layerKey(a, aspect: .r9x16) == PreviewKeys.layerKey(b, aspect: .r9x16))
    a.posY = 0.1
    #expect(PreviewKeys.layerKey(a, aspect: .r9x16) != PreviewKeys.layerKey(b, aspect: .r9x16))
  }

  @Test func storedAndResolvedJSONOnlyGrowWhenUsed() throws {
    let plain = resolved("Song")
    let json = String(decoding: try JSONCoding.encoder.encode(plain), as: UTF8.self)
    #expect(!json.contains("moreText") && !json.contains("textLook"))
    #expect(!plain.defaulted.contains("moreText") && !plain.defaulted.contains("textLook"))
    let stored = String(decoding: try JSONCoding.encoder.encode(version(1) { $0.text = "Song" }), as: UTF8.self)
    #expect(stored == #"{"number":1,"text":"Song"}"#)
    let raw = try JSONCoding.decoder.decode(Version.self, from: Data(stored.utf8))
    #expect(raw.moreText == nil && raw.textLook == nil)

    var used = plain
    used.moreText = [extra("Two", id: "a")]
    used.textLook = TextLook(accent: "#112233")
    let back = try JSONCoding.decoder.decode(ResolvedVersion.self, from: JSONCoding.encoder.encode(used))
    #expect(back == used)
    let lookJSON = String(decoding: try JSONCoding.encoder.encode(TextLook(color: "#000000")), as: UTF8.self)
    #expect(lookJSON == ##"{"color":"#000000"}"##)
  }

  @Test func futureValuesNeverLoseAVersion() throws {
    let json = ##"{"number":1,"moreText":[{"id":"a","text":"Hi","style":"neon","look":{"font":"papyrus","color":"#123456"}}],"textLook":{"font":"papyrus"}}"##
    let v = try JSONCoding.decoder.decode(Version.self, from: Data(json.utf8))
    let l = try #require(v.moreText?.first)
    #expect(l.id == "a" && l.text == "Hi" && l.style == .box && l.look?.font == nil && l.look?.color == "#123456")
    #expect(v.textLook == TextLook())
  }
}

@Suite struct R16ResolverTests {
  @Test func moreTextCarriesForwardAsAWholeList() {
    let a = extra("A", id: "a"), b = extra("B", id: "b")
    let v1 = version(1) { $0.moreText = [a, b] }
    let r1 = resolve([v1])
    #expect(r1.moreText.map(\.id) == ["a", "b"] && !r1.inherited.contains("moreText"))
    let r2 = resolve([v1, version(2)])  // nil inherits the whole list
    #expect(r2.moreText.map(\.id) == ["a", "b"] && r2.inherited.contains("moreText"))
    let r3 = resolve([v1, version(2) { $0.moreText = [] }])  // [] = explicitly none
    #expect(r3.moreText.isEmpty)
    let r4 = resolve([v1, version(2) { $0.moreText = [] }, version(3)])
    #expect(r4.moreText.isEmpty)
    let r5 = resolve([v1, version(2) { $0.moreText = [b] }, version(3)])
    #expect(r5.moreText.map(\.id) == ["b"])
  }

  @Test func lookCarriesForwardAndAnEmptyLookResets() {
    let v1 = version(1) { $0.textLook = TextLook(color: "#ff0000") }
    #expect(resolve([v1]).textLook?.color == "#FF0000")  // normalised
    #expect(resolve([v1, version(2)]).textLook?.color == "#FF0000")
    #expect(resolve([v1, version(2) { $0.textLook = TextLook() }]).textLook == nil)
    #expect(resolve([version(1) { $0.textLook = TextLook(opacity: 1) }]).textLook == nil)
  }

  @Test func layersFollowTheRules() {
    var v = version(1) { $0.text = "First"; $0.moreText = [extra("Two", id: "a"), extra(" \n ", id: "b"), extra("Three", id: "c")] }
    var r = resolve([v])
    #expect(r.layers.map(\.id) == [TextLayer.firstId, "a", "c"])  // first text first, empties skipped
    #expect(r.allLayers.count == 4 && r.hasDrawnText && r.hasText)

    v.noText = true  // hides all, keeps extras stored
    r = resolve([v])
    #expect(r.layers.isEmpty && !r.hasDrawnText && r.moreText.count == 3)
    v.noText = false  // off restores them
    r = resolve([v])
    #expect(r.layers.count == 3)

    v.text = nil  // first text empty: the extras still draw, but hasText still means the first text
    r = resolve([v])
    #expect(r.layers.map(\.id) == ["a", "c"] && r.hasDrawnText && !r.hasText)
  }

  @Test func capIsThirtyTwoTextsWithTheFirst() {  // round 26: was 12
    #expect(TextLayers.maxCount == 32)
    var v = version(1) { $0.text = "First"; $0.moreText = (0..<30).map { extra("T\($0)") } }
    var r = resolve([v])
    #expect(TextLayers.canAdd(r))
    let added = TextLayers.adding(extra("Thirty-two"), to: v, resolved: r)
    #expect(added?.moreText?.count == 31)
    v = added!
    r = resolve([v])
    #expect(r.allLayers.count == 32 && !TextLayers.canAdd(r))
    #expect(TextLayers.adding(extra("Too many"), to: v, resolved: r) == nil)
  }

  @Test func addressingByNumberOrId() {
    let r = resolve([version(1) { $0.text = "First"; $0.moreText = [extra("A", id: "abc")] }])
    #expect(TextLayers.layer("1", in: r)?.id == TextLayer.firstId)
    #expect(TextLayers.layer("first", in: r)?.text == "First")
    #expect(TextLayers.layer("2", in: r)?.id == "abc")
    #expect(TextLayers.layer("abc", in: r)?.text == "A")
    #expect(TextLayers.layer("3", in: r) == nil && TextLayers.layer("0", in: r) == nil && TextLayers.layer("zzz", in: r) == nil)
  }

  @Test func anAllDigitIdIsAnId() {
    let r = resolve([version(1) { $0.text = "First"; $0.moreText = [extra("A", id: "12345678"), extra("B", id: "2")] }])
    #expect(TextLayers.layer("12345678", in: r)?.text == "A")
    #expect(TextLayers.layer("2", in: r)?.text == "B")  // the id wins over number 2
    #expect(TextLayers.layer("3", in: r)?.text == "B")
  }

  @Test func movingOneEndOfADefaultWindowKeepsTheOther() throws {
    var s = Settings()
    s.defaults.textTiming = .firstSeconds
    let raw = version(1) { $0.text = "First" }
    let r = VersionResolver.resolve([raw], number: 1, settings: s)
    #expect(r.textStart == 0 && r.textEnd == 3)
    let moved = TextLayers.updating(TextLayer.firstId, in: raw, resolved: r) { $0.start = 1 }
    let after = VersionResolver.resolve([moved], number: 1, settings: s)
    #expect(after.textStart == 1 && after.textEnd == 3)
    #expect(PreviewKeys.textWindow(after, trimDuration: 10) == 1...3)
    // Nothing timed changed: the window keeps following the default.
    let other = TextLayers.updating(TextLayer.firstId, in: raw, resolved: r) { $0.posY = 0.2 }
    #expect(other.textStart == nil && other.textEnd == nil)
  }

  @Test func updatingTheFirstTextWritesOnlyWhatChanged() {
    let v = Video.sample(title: "A Title")
    let raw = version(1)
    let r = resolve([raw], video: v)
    #expect(r.text == "A Title" && r.isDefault("text"))
    let moved = TextLayers.updating(TextLayer.firstId, in: raw, resolved: r) { $0.posY = 0.2; $0.look = TextLook(color: "#FF0000") }
    #expect(moved.posY == 0.2 && moved.textLook?.color == "#FF0000")
    #expect(moved.text == nil && moved.noText == nil && moved.style == nil && moved.size == nil)  // Title-follow survives
    #expect(resolve([moved], video: v).text == "A Title")
    let reset = TextLayers.updating(TextLayer.firstId, in: moved, resolved: resolve([moved], video: v)) { $0.look = nil }
    #expect(reset.textLook == TextLook())  // explicit, so it doesn't inherit a look from an earlier version
    let worded = TextLayers.updating(TextLayer.firstId, in: raw, resolved: r) { $0.text = "Typed" }
    #expect(worded.text == "Typed" && worded.noText == false)
  }

  @Test func updatingAnExtraWritesTheWholeListIntoThisVersion() {
    let v1 = version(1) { $0.moreText = [extra("A", id: "a"), extra("B", id: "b")] }
    let v2 = version(2)
    let chain = [v1, v2]
    let out = TextLayers.updating("b", in: v2, resolved: resolve(chain)) { $0.text = "Bee" }
    #expect(out.moreText?.map(\.text) == ["A", "Bee"])
    #expect(resolve([v1]).moreText[1].text == "B")  // v1 keeps its own
    #expect(TextLayers.updating("nope", in: v2, resolved: resolve(chain)) { $0.text = "X" } == v2)
  }

  @Test func removingTheFirstTextPromotesTheNext() throws {
    let look = TextLook(color: "#00FF00")
    let next = TextLayer(id: "a", text: "Next", style: .outline, size: 80, posX: 0.3, posY: 0.2, align: .left, start: 1, end: 2, look: look)
    let raw = version(1) { $0.text = "First"; $0.textLook = TextLook(color: "#FF0000"); $0.textStart = 3; $0.moreText = [next, extra("Last", id: "b")] }
    let r = resolve([raw])
    let out = try #require(TextLayers.removing(TextLayer.firstId, from: raw, resolved: r))
    let after = resolve([out])
    #expect(after.text == "Next" && after.style == .outline && after.size == 80 && after.posX == 0.3 && after.posY == 0.2)
    #expect(after.align == .left && after.textStart == 1 && after.textEnd == 2 && after.textLook == look)
    #expect(after.moreText.map(\.id) == ["b"])
    #expect(after.layers.map(\.id) == [TextLayer.firstId, "b"])

    // Nothing to promote: the only text stays ("No text" is for that).
    let only = version(1) { $0.text = "Only" }
    #expect(TextLayers.removing(TextLayer.firstId, from: only, resolved: resolve([only])) == nil)
    let blanks = version(1) { $0.text = "Only"; $0.moreText = [extra("  ")] }
    #expect(TextLayers.promotingNext(blanks, resolved: resolve([blanks])) == nil)
    // A blank extra is skipped, not promoted, and the look reset is explicit.
    let skips = version(1) { $0.textLook = TextLook(color: "#FF0000"); $0.moreText = [extra(" ", id: "x"), extra("Real", id: "y")] }
    let s = try #require(TextLayers.promotingNext(skips, resolved: resolve([skips])))
    #expect(s.text == "Real" && s.moreText?.map(\.id) == ["x"] && resolve([s]).textLook == nil)
  }

  @Test func promotionKeepsWholeClipAndNoText() throws {
    // v1 has a window; v2's promoted text has none, so it must not pick up v1's timing or the default.
    let v1 = version(1) { $0.text = "First"; $0.textStart = 1; $0.textEnd = 2 }
    let v2 = version(2) { $0.moreText = [extra("Whole clip", id: "a")] }
    let r = resolve([v1, v2])
    let out = try #require(TextLayers.promotingNext(v2, resolved: r))
    let after = resolve([v1, out])
    let w = try #require(PreviewKeys.textWindow(after, trimDuration: 10))
    #expect(w == 0...11)

    var s = Settings()
    s.defaults.textTiming = .firstSeconds
    let one = version(1) { $0.moreText = [extra("Whole clip", id: "a")] }
    let promoted = try #require(TextLayers.promotingNext(one, resolved: VersionResolver.resolve([one], number: 1, settings: s)))
    let w2 = try #require(PreviewKeys.textWindow(VersionResolver.resolve([promoted], number: 1, settings: s), trimDuration: 10))
    #expect(w2 == 0...11)

    let hidden = version(1) { $0.text = "First"; $0.noText = true; $0.moreText = [extra("Next", id: "a")] }
    let p = try #require(TextLayers.promotingNext(hidden, resolved: resolve([hidden])))
    #expect(resolve([p]).noText && resolve([p]).text == "Next" && resolve([p]).layers.isEmpty)
  }

  @Test func promotionKeepsALateStart() throws {
    let v1 = version(1) { $0.text = "First"; $0.textStart = 1; $0.textEnd = 2; $0.moreText = [extra("Late", id: "a", start: 3)] }
    let out = try #require(TextLayers.promotingNext(v1, resolved: resolve([v1])))
    #expect(PreviewKeys.textWindow(resolve([out]), trimDuration: 10) == 3...11)

    var s = Settings()
    s.defaults.textTiming = .firstSeconds  // resolves to an end too
    let one = version(1) { $0.moreText = [extra("Late", id: "a", start: 4)] }
    let p = try #require(TextLayers.promotingNext(one, resolved: VersionResolver.resolve([one], number: 1, settings: s)))
    #expect(PreviewKeys.textWindow(VersionResolver.resolve([p], number: 1, settings: s), trimDuration: 10) == 4...11)
  }

  @Test func aTrimCommitAfterPromotionKeepsTheWindow() throws {
    let v1 = version(1) { $0.text = "First"; $0.textStart = 1; $0.textEnd = 2 }
    let v2 = version(2) { $0.moreText = [extra("Whole clip", id: "a"), extra("Late", id: "b", start: 3)] }
    let whole = try #require(TextLayers.promotingNext(v2, resolved: resolve([v1, v2])))
    let w = EditorLogic.afterTrimCommit(textStart: whole.textStart, textEnd: whole.textEnd, cover: nil, trim: TrimRange(start: 2, end: 10))
    #expect(w.textStart == 0 && w.textEnd == 8)  // the whole trim, not a 0.3 s flash

    let v3 = version(3) { $0.moreText = [extra("Late", id: "b", start: 3)] }
    let late = try #require(TextLayers.promotingNext(v3, resolved: resolve([v1, v3])))
    let l = EditorLogic.afterTrimCommit(textStart: late.textStart, textEnd: late.textEnd, cover: nil, trim: TrimRange(start: 2, end: 10))
    #expect(l.textStart == 3 && l.textEnd == 8)
  }

  @Test func removingAnExtraIsExplicitInThisVersion() throws {
    let v1 = version(1) { $0.moreText = [extra("A", id: "a")] }
    let v2 = version(2)
    let out = try #require(TextLayers.removing("a", from: v2, resolved: resolve([v1, v2])))
    #expect(out.moreText == [])
    #expect(resolve([v1, out]).moreText.isEmpty && resolve([v1]).moreText.count == 1)
    #expect(TextLayers.removing("nope", from: v2, resolved: resolve([v1, v2])) == nil)
  }

  @Test func newVersionCopyKeepsWhatTheSourceShows() {
    let v1 = version(1) { $0.textLook = TextLook(color: "#FF0000"); $0.moreText = [extra("A", id: "a")] }
    let v2 = version(2) { $0.textLook = TextLook(color: "#00FF00"); $0.moreText = [] }
    let v3 = VersionCopy.duplicate([v1, v2], source: 1, as: 3, settings: Settings())
    let r3 = resolve([v1, v2, v3])
    #expect(r3.textLook?.color == "#FF0000" && r3.moreText.map(\.text) == ["A"] && r3.moreText.map(\.id) != ["a"])
    let v4 = VersionCopy.duplicate([v1, v2, v3], source: 2, as: 4, settings: Settings())
    let r4 = resolve([v1, v2, v3, v4])
    #expect(r4.textLook?.color == "#00FF00" && r4.moreText.isEmpty)
    let plain = VersionCopy.duplicate([version(1)], source: 1, as: 5, settings: Settings())
    #expect(resolve([v1, plain]).textLook == nil)
  }
}

@Suite struct R16WindowTests {
  @Test func extrasFollowSR5() {
    let r = resolve([version(1) {
      $0.text = "First"
      $0.moreText = [extra("whole", id: "whole"), extra("mid", id: "mid", start: 1, end: 2), extra("late", id: "late", start: 5),
                     extra("inverted", id: "inv", start: 3, end: 2), extra("over", id: "over", start: 2, end: 99),
                     extra("before", id: "neg", start: -4, end: 1), extra("blank ", id: "same", start: 2, end: 2)]
    }])
    let w = PreviewKeys.layerWindows(r, trimDuration: 4)
    #expect(w.map(\.layer.id) == [TextLayer.firstId, "whole", "mid", "over", "neg"])
    #expect(w.first { $0.layer.id == "mid" }?.window == 1...2)
    #expect(w.first { $0.layer.id == "whole" }?.window == 0...5)
    #expect(w.first { $0.layer.id == "over" }?.window == 2...5)  // end clamped
    #expect(w.first { $0.layer.id == "neg" }?.window == 0...1)
    // A shorter per-platform trim drops what starts past it.
    #expect(PreviewKeys.layerWindows(r, trimDuration: 1).map(\.layer.id) == [TextLayer.firstId, "whole", "neg"])
    #expect(PreviewKeys.layerWindows(r, trimDuration: 0).isEmpty && PreviewKeys.layerWindows(nil, trimDuration: 4).isEmpty)
  }

  @Test func firstTextWindowIsUnchanged() {
    // Inverted or past the trim = whole clip, where an extra would vanish.
    for (s, e) in [(3.0, 1.0), (9.0, 12.0)] {
      let r = resolve([version(1) { $0.text = "First"; $0.textStart = s; $0.textEnd = e }])
      #expect(PreviewKeys.layerWindows(r, trimDuration: 4).map(\.window) == [0...5])
      #expect(PreviewKeys.textWindow(r, trimDuration: 4) == 0...5)
    }
    let timed = resolve([version(1) { $0.text = "First"; $0.textStart = 1; $0.textEnd = 2 }])
    #expect(PreviewKeys.layerWindows(timed, trimDuration: 4).map(\.window) == [1...2])
  }

  @Test func coverShowsWhatIsOnScreenElseTheFirstText() {
    let r = resolve([version(1) {
      $0.text = "First"; $0.textStart = 0; $0.textEnd = 1
      $0.moreText = [extra("A", id: "a", start: 0.5, end: 2), extra("B", id: "b", start: 3)]
    }])
    func ids(_ t: Double, _ v: ResolvedVersion) -> [String] { PreviewKeys.coverLayers(v, offset: t, trimDuration: 4).map(\.id) }
    #expect(ids(0.75, r) == [TextLayer.firstId, "a"])
    #expect(ids(1.5, r) == ["a"])
    #expect(ids(2.5, r) == [TextLayer.firstId])  // nothing shows: the first text
    #expect(ids(3.5, r) == ["b"])
    #expect(ids(-1, r) == [TextLayer.firstId])  // a cover before the trim
    // One text: always on the cover, whatever its window, as before.
    let one = resolve([version(1) { $0.text = "Only"; $0.textStart = 1; $0.textEnd = 2 }])
    #expect(ids(3, one) == [TextLayer.firstId] && ids(1.5, one) == [TextLayer.firstId])
    let empty = resolve([version(1) { $0.moreText = [extra("A", id: "a", start: 1, end: 2)] }])
    #expect(ids(3, empty).isEmpty && ids(1.5, empty) == ["a"])
    let hidden = resolve([version(1) { $0.text = "Only"; $0.noText = true }])
    #expect(ids(1, hidden).isEmpty && PreviewKeys.coverLayers(nil, offset: 0, trimDuration: 4).isEmpty)
  }

  @Test func trimCommitClampsALayerLikeTheFirstText() {
    var l = extra("A", start: 8, end: 12)
    l = EditorLogic.clampLayer(l, trimDuration: 5)
    #expect(l.start == 4.7 && l.end == 5)
    let open = EditorLogic.clampLayer(extra("A", start: 1), trimDuration: 5)
    #expect(open.start == 1 && open.end == nil)  // nil stays nil
    let whole = EditorLogic.clampLayer(extra("A"), trimDuration: 5)
    #expect(whole.start == nil && whole.end == nil)
  }

  @Test func trimCommitLeavesAnInvertedExtraAlone() {
    let r = resolve([version(1) { $0.moreText = [extra("Hidden", id: "a", start: 5, end: 3)] }])
    let l = r.moreText[0]
    #expect(EditorLogic.clampLayer(l, trimDuration: 10) == l)
    #expect(EditorLogic.clampLayer(l, trimDuration: 2) == l)
    let noStart = extra("Hidden", end: 0)
    #expect(EditorLogic.clampLayer(noStart, trimDuration: 10) == noStart)
    #expect(PreviewKeys.layerWindows(r, trimDuration: 10).allSatisfy { $0.layer.id != "a" })  // still not drawn
  }

  @Test func overlayGraphForOneTextIsTheGraphEveryRenderUsed() {
    #expect(Renderer.overlayGraph([]) == "")
    #expect(Renderer.overlayGraph([1...2.5]) == "[bg];[1:v]format=rgba,scale=out_color_matrix=bt709:out_range=tv,format=yuva420p[ov];"
      + "[bg][ov]overlay=0:0:format=yuv420:eof_action=repeat:enable='between(t,1.000,2.500)'")
    let g = Renderer.overlayGraph([0...1, 1...2, 2...3])
    #expect(g.contains("[1:v]") && g.contains("[2:v]") && g.contains("[3:v]") && g.contains("[bg][ov]overlay") && g.contains("[o0][ov1]overlay"))
    #expect(g.contains("[o1][ov2]overlay") && g.hasSuffix("enable='between(t,2.000,3.000)'"))
  }
}

/// The look goes through the same drawing path: colours, font, spacing and opacity change the pixels they should.
@Suite struct R16LookTests {
  func layer(_ text: String = "HHHH", style: TextStyle = .box, size: Double = 120, look: TextLook?) -> TextLayer {
    TextLayer(text: text, style: style, size: size, look: look)
  }

  func count(_ px: Pixels, in b: CGRect, _ match: ((UInt8, UInt8, UInt8, UInt8)) -> Bool) -> Int {
    var n = 0
    for y in stride(from: Int(b.minY), to: Int(b.maxY), by: 2) {
      for x in stride(from: Int(b.minX), to: Int(b.maxX), by: 2) where match(px.at(x, y)) { n += 1 }
    }
    return n
  }

  @Test func hexIsNormalised() {
    #expect(TextLook.hex("#ff3b30") == "#FF3B30" && TextLook.hex("ff3b30") == "#FF3B30" && TextLook.hex("#fff") == "#FFFFFF")
    #expect(TextLook.hex("#12345") == nil && TextLook.hex("red") == nil && TextLook.hex("") == nil && TextLook.hex(nil) == nil)
    #expect(TextLook.rgb("#FF0080")?.r == 1 && TextLook.rgb("#FF0080")?.g == 0)
    #expect(TextLook(color: "not a colour").normalized == nil)
    #expect(TextLook(opacity: 0.0).normalized?.opacity == TextLook.opacityRange.lowerBound)
    #expect(TextLook(tracking: 9).normalized?.tracking == TextLook.trackingRange.upperBound)
    #expect(TextLook(font: .standard, tracking: 0).isDefault)
  }

  @Test func textColourPaintsTheGlyphsOfEveryStyle() throws {
    for style in TextStyle.allCases {
      let l = layer(style: style, look: TextLook(color: "#FF0000"))
      let b = try #require(TextOverlay.textBounds(for: l, aspect: .r9x16))
      let px = Pixels(try #require(TextOverlay.image(for: l, aspect: .r9x16)))
      let red = count(px, in: b) { $0.0 > 240 && $0.1 < 15 && $0.2 < 15 && $0.3 == 255 }
      #expect(red > 100, "\(style): \(red)")
    }
  }

  @Test func emojiKeepTheirOwnColours() throws {
    for style in TextStyle.allCases {
      var plain = layer("🔥🔥", style: style, look: nil)
      let a = try #require(TextOverlay.png(for: plain, aspect: .r9x16))
      plain.look = TextLook(color: "#00FF00")
      #expect(TextOverlay.png(for: plain, aspect: .r9x16) == a, "\(style)")
    }
  }

  @Test func accentIsTheBoxFill() throws {
    let l = layer(look: TextLook(accent: "#0000FF"))
    let b = try #require(TextOverlay.textBounds(for: l, aspect: .r9x16))
    let p = Pixels(try #require(TextOverlay.image(for: l, aspect: .r9x16))).at(Int(b.minX) + 8, Int(b.midY))
    #expect(p.0 == 0 && p.1 == 0 && p.2 == 255 && p.3 == 255)
  }

  @Test func accentIsTheOutlineColour() throws {
    let plain = layer(style: .outline, look: nil), blue = layer(style: .outline, look: TextLook(accent: "#0000FF"))
    let b = try #require(TextOverlay.textBounds(for: blue, aspect: .r9x16))
    let a = Pixels(try #require(TextOverlay.image(for: plain, aspect: .r9x16)))
    let c = Pixels(try #require(TextOverlay.image(for: blue, aspect: .r9x16)))
    #expect(count(a, in: b) { $0.2 > 240 && $0.0 < 15 && $0.3 == 255 } == 0)
    #expect(count(c, in: b) { $0.2 > 240 && $0.0 < 15 && $0.3 == 255 } > 100)
    #expect(count(c, in: b) { $0.0 > 250 && $0.1 > 250 && $0.2 > 250 } > 100)  // the glyphs stay white
  }

  @Test func accentIsTheShadowColour() throws {
    let plain = layer(style: .shadow, look: nil), red = layer(style: .shadow, look: TextLook(accent: "#FF0000"))
    let b = try #require(TextOverlay.textBounds(for: red, aspect: .r9x16))
    let a = Pixels(try #require(TextOverlay.image(for: plain, aspect: .r9x16)))
    let c = Pixels(try #require(TextOverlay.image(for: red, aspect: .r9x16)))
    // Premultiplied: a red shadow has red in it where the black one has none.
    #expect(count(a, in: b) { $0.3 > 40 && $0.3 < 200 && $0.0 > 30 && $0.1 < 5 } == 0)
    #expect(count(c, in: b) { $0.3 > 40 && $0.3 < 200 && $0.0 > 30 && $0.1 < 5 } > 50)
  }

  @Test func fontChangesTheShapeAndAMissingFontFallsBack() throws {
    let base = try #require(TextOverlay.png(for: layer(look: nil), aspect: .r9x16))
    for f in TextFont.allCases where f != .standard {
      let l = layer(look: TextLook(font: f))
      let png = try #require(TextOverlay.png(for: l, aspect: .r9x16))
      #expect(png != base, "\(f.rawValue) draws like the default: its face didn't load")
    }
    let system = TextOverlay.font(nil, size: 64, weight: .heavy)
    #expect(CTFontCopyPostScriptName(TextOverlay.font(.standard, size: 64, weight: .heavy)) == CTFontCopyPostScriptName(system))
    #expect(TextOverlay.font(named: "No Such Font", size: 64) == nil)
    #expect(String(CTFontCopyPostScriptName(TextOverlay.font(.impact, size: 64, weight: .heavy))) == "Impact")
    for f in TextFont.allCases { if let n = f.postScriptName { #expect(TextOverlay.font(named: n, size: 64) != nil, "\(n) isn't on this Mac") } }
    // An unknown stored font is the default look.
    let stored = try JSONCoding.decoder.decode(TextLook.self, from: Data(#"{"font":"papyrus"}"#.utf8))
    #expect(stored.normalized == nil)
  }

  @Test func opacityFadesTheTextAsOnePiece() throws {
    let l = layer(look: TextLook(opacity: 0.5))
    let b = try #require(TextOverlay.textBounds(for: l, aspect: .r9x16))
    let px = Pixels(try #require(TextOverlay.image(for: l, aspect: .r9x16)))
    let box = px.at(Int(b.minX) + 8, Int(b.midY))
    #expect(abs(Int(box.3) - 128) <= 2)
    // The glyph on the box doesn't let the box show through: everything inside the block is the same strength.
    #expect(count(px, in: b.insetBy(dx: 24, dy: 24)) { abs(Int($0.3) - 128) > 3 && $0.3 > 0 } == 0)
    #expect(TextOverlay.textBounds(for: layer(look: nil), aspect: .r9x16) == b)
  }

  @Test func trackingSpreadsTheLetters() throws {
    let plain = try #require(TextOverlay.textBounds(for: layer(look: nil), aspect: .r9x16))
    let wide = try #require(TextOverlay.textBounds(for: layer(look: TextLook(tracking: 0.2)), aspect: .r9x16))
    let tight = try #require(TextOverlay.textBounds(for: layer(look: TextLook(tracking: -0.05)), aspect: .r9x16))
    // Four letters have three gaps once the air after the last one is left out.
    #expect(abs((wide.width - plain.width) - 3 * 0.2 * 120) <= 2)
    #expect(tight.width < plain.width)
    #expect(TextOverlay.png(for: layer(look: TextLook(tracking: 0.2)), aspect: .r9x16) != TextOverlay.png(for: layer(look: nil), aspect: .r9x16))
  }

  /// Looks composited on a mid-grey frame for eyeballing (DJQ_SAMPLES=<dir>).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_SAMPLES"] != nil))
  func writeLookSamples() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJQ_SAMPLES"]!)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let (w, h) = (1080 * 3, 1920)
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.4, blue: 0.45, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let fonts = TextFont.allCases
    for (i, f) in fonts.enumerated() {
      let col = i % 3, row = i / 3
      let styles = TextStyle.allCases
      let l = TextLayer(text: "\(f.displayName) 🔥", style: styles[i % 3], size: 76, posY: 0.1 + Double(row) * 0.18,
                        look: TextLook(color: i % 2 == 0 ? "#FFCC00" : nil, accent: i % 3 == 0 ? "#AF52DE" : "#FF3B30", font: f,
                                       opacity: i % 4 == 3 ? 0.6 : nil, tracking: i % 5 == 4 ? 0.12 : nil))
      ctx.draw(try #require(TextOverlay.image(for: l, aspect: .r9x16)), in: CGRect(x: col * 1080, y: 0, width: 1080, height: 1920))
    }
    try Media.writePNG(try #require(ctx.makeImage()), to: dir.appendingPathComponent("r16-looks.png"))
  }

  @Test func stackedImagePutsLaterTextsOnTop() throws {
    let under = TextLayer(text: "HHHH", size: 120, look: TextLook(accent: "#FF0000"))
    let over = TextLayer(text: "HHHH", size: 120, look: TextLook(accent: "#0000FF"))
    let b = try #require(TextOverlay.textBounds(for: over, aspect: .r9x16))
    let p = Pixels(try #require(TextOverlay.image(for: [under, over], aspect: .r9x16))).at(Int(b.minX) + 8, Int(b.midY))
    #expect(p.2 == 255 && p.0 == 0)
    #expect(TextOverlay.image(for: [TextLayer(text: "  ")], aspect: .r9x16) == nil)
    #expect(TextOverlay.image(for: [TextLayer](), aspect: .r9x16) == nil)
  }
}

/// Validation, bulk and stages against a real store.
@Suite struct R16StoreTests {
  func ready(_ f: Fixture, id: String = "clip-0") throws {
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: id)
    try f.store.setScore(id, 50)
  }

  @Test func healthAsksWhetherAnythingShows() throws {
    let f = try Fixture(clips: [("song", 20)], longform: false)
    try f.intake()
    try ready(f)
    func noText() throws -> Bool {
      try Validation.issues(video: try #require(try f.store.video(id: "clip-0")), store: f.store).contains { $0.kind == .noText }
    }
    #expect(try noText())  // no title, no text
    try f.store.save(version(1) { $0.moreText = [extra("Timed", id: "a", start: 1, end: 2)] }, videoId: "clip-0")
    #expect(try !noText())  // first text empty, an extra draws
    try f.store.save(version(1) { $0.moreText = [extra("   ", id: "a")] }, videoId: "clip-0")
    #expect(try noText())  // an empty extra isn't text
    try f.store.save(version(1) { $0.noText = true; $0.moreText = [extra("Hidden", id: "a")] }, videoId: "clip-0")
    #expect(try !noText())  // "No text" is a decision
    let r = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(Captions.textValue(r, video: v) == v.tag)  // `{text}` and titles read the first text
  }

  @Test func applyDefaultsClearsTextsAndLookAndUndoRestoresThem() throws {
    let f = try Fixture(clips: [("song", 20)], longform: false)
    try f.intake()
    try ready(f)
    let saved = version(1) {
      $0.text = "Typed"; $0.textLook = TextLook(color: "#FF0000", font: .futura)
      $0.moreText = [extra("A", id: "a", start: 1, end: 2, look: TextLook(opacity: 0.5)), extra("B", id: "b", start: 3)]
      $0.caption = "kept"
    }
    try f.store.save(saved, videoId: "clip-0")
    let bulk = BulkActions(store: f.store)
    let other = try bulk.applyDefaults(["clip-0"], sections: [.caption])
    let afterCaption = try #require(try f.store.versions(videoId: "clip-0").first)
    #expect(afterCaption.moreText?.count == 2 && afterCaption.textLook != nil && afterCaption.caption == nil)  // other sections keep them
    try bulk.undo(try #require(other.batchId))

    let r = try bulk.applyDefaults(["clip-0"], sections: [.text])
    let cleared = try #require(try f.store.versions(videoId: "clip-0").first)
    #expect(cleared.moreText == nil && cleared.textLook == nil && cleared.text == nil && cleared.caption == "kept")
    #expect(try f.store.resolvedVersion(videoId: "clip-0", number: 1)?.layers.isEmpty == true)
    try bulk.undo(try #require(r.batchId))
    #expect(try f.store.versions(videoId: "clip-0").first == saved)
  }

  @Test func bulkCaptionTitleCropAndSendKeepThem() throws {
    let f = try Fixture(clips: [("song", 20)], longform: false)
    try f.intake()
    try ready(f)
    let saved = version(1) { $0.text = "T"; $0.textLook = TextLook(color: "#FF0000"); $0.moreText = [extra("A", id: "a")] }
    try f.store.save(saved, videoId: "clip-0")
    let bulk = BulkActions(store: f.store)
    try bulk.setCaptionTemplate(["clip-0"], "short")
    try bulk.setTitle(["clip-0"], "Title")
    try bulk.setExtraHashtags(["clip-0"], ["#a"])
    try bulk.sendToQueue(["clip-0"])
    let now = try #require(try f.store.versions(videoId: "clip-0").first)
    #expect(now.moreText == saved.moreText && now.textLook == saved.textLook && now.text == "T")
  }

  @Test func thumbnailKeyFollowsTheCoverLayers() throws {
    let rf = try RenderFixture()
    let video = try #require(try rf.store.video(id: rf.id))
    try rf.edit { $0.coverTime = 1.5 }  // 1 s into the 0.5 s trim
    let plain = try #require(Media.thumbnail(store: rf.store, video: video))
    try rf.version { $0.moreText = [extra("Off cover", id: "a", start: 2, end: 2.5)] }
    #expect(Media.thumbnail(store: rf.store, video: video) == plain)  // not at the cover frame: same cover, no new file
    try rf.version { $0.moreText = [extra("On cover", id: "a", start: 0.5, end: 2.5)] }
    let on = try #require(Media.thumbnail(store: rf.store, video: video))
    #expect(on != plain)
    try rf.version { $0.moreText = [extra("Changed", id: "a", start: 0.5, end: 2.5)] }
    #expect(Media.thumbnail(store: rf.store, video: video) != on)
  }
}

extension Video {
  static func sample(title: String?) -> Video {
    Video(id: "v", sessionId: "s", name: "n", tags: ["tag"], type: .short, contentType: "dj vid", kind: .djVid, file: "f.mp4",
          fingerprint: nil, fileSize: nil, duration: 10, markedStart: nil, markedEnd: nil, start: nil, end: nil, grace: nil,
          audio: nil, part: nil, score: nil, state: .needsEdit, excluded: false, missing: false, inManifest: true, notes: "",
          alreadyPostedOn: [], longformURL: nil, createdAt: Date(), updatedAt: Date(), title: title)
  }
}
