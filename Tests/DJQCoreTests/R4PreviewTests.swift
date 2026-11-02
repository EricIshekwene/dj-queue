import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 4 S6: lists show the edited clip — preview stamps, the cover-with-text key, the list composite vs the
/// renderer's cover, and the overlay cache cap.
@Suite struct R4PreviewTests {
  private func stamp(_ s: Store, _ id: String, version: Int = 1) throws -> String {
    let v = try #require(try s.video(id: id))
    return try s.previewStampTable().stamp(for: v, version: version)
  }

  @Test func stampMovesWithEditVersionTextAndDefaults() throws {
    let f = try Fixture()
    _ = try f.intake()
    let s = f.store, id = "clip-0", other = "clip-1"
    let a = try stamp(s, id), o = try stamp(s, other)
    #expect(try stamp(s, id) == a)  // stable

    f.clock.advance(1)
    var e = try s.edit(videoId: id)
    e.crop = CropRect(x: 10, y: 0, w: 607.5, h: 1080)
    try s.save(e, videoId: id)
    let b = try stamp(s, id)
    #expect(b != a)
    #expect(try stamp(s, other) == o)  // only the edited clip moves

    f.clock.advance(1)
    var v1 = Version(number: 1)
    v1.text = "New text"
    try s.save(v1, videoId: id)
    let c = try stamp(s, id)
    #expect(c != b)

    // A later version moves its own stamp (and "all versions"), not version 1's.
    f.clock.advance(1)
    var v2 = Version(number: 2)
    v2.text = "Second"
    try s.save(v2, videoId: id)
    #expect(try stamp(s, id) == c)
    #expect(try stamp(s, id, version: 2) != c)
    let all = try stamp(s, id, version: .max)
    f.clock.advance(1)
    v2.text = "Second, edited"
    try s.save(v2, videoId: id)
    #expect(try stamp(s, id, version: .max) != all)

    // New-clip defaults move every clip; other settings don't.
    var st = try s.settings()
    st.postsPerDay += 1
    try s.save(st)
    #expect(try stamp(s, id) == c && stamp(s, other) == o)
    st.defaults.textSize += 4
    try s.save(st)
    #expect(try stamp(s, id) != c)
    #expect(try stamp(s, other) != o)
  }

  @Test func defaultsGenerationIsDeterministic() {
    var d = NewClipDefaults()
    let a = PreviewKeys.defaultsGeneration(d, lastCrop: nil)
    #expect(PreviewKeys.defaultsGeneration(d, lastCrop: nil) == a)
    #expect(PreviewKeys.defaultsGeneration(d, lastCrop: CGPoint(x: 0.5, y: 0.5)) != a)
    d.coverIncludesText.toggle()
    #expect(PreviewKeys.defaultsGeneration(d, lastCrop: nil) != a)
  }

  @Test func textWindowFollowsTheRendererRule() throws {
    let rf = try RenderFixture()
    var rv = try #require(try rf.store.resolvedVersion(videoId: rf.id, number: 1))
    rv.textStart = 0.5; rv.textEnd = 2
    #expect(PreviewKeys.textWindow(rv, trimDuration: 3) == 0.5...2)
    rv.textStart = 2; rv.textEnd = 1  // inverted → whole clip
    #expect(PreviewKeys.textWindow(rv, trimDuration: 3) == 0...4)
    rv.textStart = nil; rv.textEnd = nil
    #expect(PreviewKeys.textWindow(rv, trimDuration: 3) == 0...4)
    rv.noText = true
    #expect(PreviewKeys.textWindow(rv, trimDuration: 3) == nil)
    #expect(PreviewKeys.textKey(rv, aspect: .r9x16) == "none")
  }

  @Test func thumbnailKeyCoversTextAndCoverIncludesText() throws {
    let rf = try RenderFixture()
    let v = try #require(try rf.store.video(id: rf.id))
    let proxy = try Media.proxyURL(store: rf.store, video: v)
    let a = try #require(Media.thumbnail(store: rf.store, video: v))
    try rf.version { $0.text = "Different words" }
    let b = try #require(Media.thumbnail(store: rf.store, video: v))
    #expect(b != a)
    #expect(!FileManager.default.fileExists(atPath: a.path))  // older cover of the same slot pruned (review L9)
    let withText = try #require(loadImage(b))
    // A text change never changes the proxy (no re-encode): its cache name is the same.
    #expect(try Media.proxyURL(store: rf.store, video: v) == proxy)
    try rf.edit { $0.coverIncludesTextOverride = false }
    let c = try #require(Media.thumbnail(store: rf.store, video: v))
    #expect(c != b)
    let without = try #require(loadImage(c))
    // Cover without text: the text no longer changes the cover.
    try rf.version { $0.text = "Yet another line" }
    #expect(Media.thumbnail(store: rf.store, video: v) == c)
    // The cover with text differs from the cover without it.
    let textDiff = meanDiff(withText, without)
    #expect(textDiff > 0.002, "cover with text vs without: \(textDiff)")
  }

  /// Acceptance 6: the list composite (cover + overlay at list size) matches the renderer's cover.
  @Test func listCoverMatchesRendererCover() throws {
    let rf = try RenderFixture()
    let r = try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil)
    let coverPath = try #require(r.coverPath)
    let rendered = try #require(loadImage(URL(fileURLWithPath: coverPath)))
    let v = try #require(try rf.store.video(id: rf.id))
    let listURL = try #require(Media.thumbnail(store: rf.store, video: v))
    let list = try #require(loadImage(listURL))
    #expect(list.width == 180 && list.height == 320)
    let small = try #require(scale(rendered, width: list.width, height: list.height))
    let d = meanDiff(list, small)
    #expect(d < 0.012, "list cover differs from the renderer's cover by \(d)")
    // Sanity: the same comparison against the cover without text is clearly worse (the text is really there).
    try rf.edit { $0.coverIncludesTextOverride = false }
    let plainURL = try #require(Media.thumbnail(store: rf.store, video: v))
    let plain = try #require(loadImage(plainURL))
    let plainDiff = meanDiff(plain, small)
    print("R4 pixel check: list vs render cover \(d), without text \(plainDiff)")
    #expect(plainDiff > d * 1.5)
  }

  /// Acceptance 7: a 200-clip grid's overlays never exceed the cache cap.
  @Test func overlayCacheStaysUnderItsCap() throws {
    let cap = 64 << 20
    let cache = CostCappedCache<String, CGImage>(costLimit: cap)
    let rf = try RenderFixture()
    var rv = try #require(try rf.store.resolvedVersion(videoId: rf.id, number: 1))
    for i in 0..<200 {
      rv.text = "Clip \(i) — some words"
      let img = try #require(TextOverlay.image(for: rv, aspect: .r9x16, maxWidth: 540))
      #expect(img.width == 540 && img.height == 960)
      cache.set(img, for: PreviewKeys.textKey(rv, aspect: .r9x16), cost: img.bytesPerRow * img.height)
      #expect(cache.totalCostNow <= cap)
    }
    #expect(cache.count >= 20 && cache.count <= 32)
    // Least recently used goes first: a key read just now survives the next insert.
    rv.text = "Clip 199 — some words"
    let recent = PreviewKeys.textKey(rv, aspect: .r9x16)
    #expect(cache.value(recent) != nil)
    let big = try #require(TextOverlay.image(for: rv, aspect: .r9x16, maxWidth: 540))
    for i in 0..<40 { cache.set(big, for: "filler-\(i)", cost: 1 << 20); _ = cache.value(recent) }
    #expect(cache.value(recent) != nil && cache.totalCostNow <= cap)
  }

  @Test func scaledOverlayKeepsAspectAndPixels() throws {
    let rf = try RenderFixture()
    let rv = try #require(try rf.store.resolvedVersion(videoId: rf.id, number: 1))
    let full = try #require(TextOverlay.image(for: rv, aspect: .r9x16))
    let small = try #require(TextOverlay.image(for: rv, aspect: .r9x16, maxWidth: 540))
    #expect(small.width == 540 && small.height == 960)
    let down = try #require(scale(full, width: 540, height: 960))
    #expect(meanDiff(down, small) < 0.005)
  }
}

// MARK: - Pixel helpers

/// RGBA8 pixels of `img` drawn into a w×h sRGB canvas.
private func pixels(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  buf.withUnsafeMutableBytes { p in
    let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  return buf
}

private func scale(_ img: CGImage, width: Int, height: Int) -> CGImage? {
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  ctx.interpolationQuality = .high
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
  return ctx.makeImage()
}

/// Mean absolute difference of the colour channels, 0…1, at `a`'s size.
private func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
  let w = a.width, h = a.height
  let pa = pixels(a, w, h), pb = pixels(b, w, h)
  var sum = 0
  for i in stride(from: 0, to: pa.count, by: 4) {
    sum += abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
  }
  return Double(sum) / Double(w * h * 3 * 255)
}
