import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import DJQCore

/// Tiny real media (1920×1080 testsrc2 + 440 Hz tone at about −26 LUFS, 4 s), generated once per run.
enum TestMedia {
  static let clip: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-media-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("testsrc.mp4")
    if !FileManager.default.fileExists(atPath: url.path) {
      let r = try! Proc.run(Tools.ffmpeg!, [
        "-hide_banner", "-v", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30000/1001:duration=4",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
        "-filter_complex", "[1:a]volume=0.07,aformat=channel_layouts=stereo[a]", "-map", "0:v", "-map", "[a]",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
        url.path,
      ])
      precondition(r.status == 0, r.stderr)
    }
    return url
  }()
}

/// A fixture whose one short clip ("yayo x johnny", clip-0) is real media, with crop + v1 text set.
final class RenderFixture {
  let f: Fixture
  let renderer: Renderer
  let id = "clip-0"
  var store: Store { f.store }

  init(text: String = "Yayo x Johnny 🔥") throws {
    f = try Fixture(clips: [("yayo x johnny", 4.0)], longform: false)
    let clip = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – yayo x johnny.mp4")
    try FileManager.default.removeItem(at: clip)
    try FileManager.default.copyItem(at: TestMedia.clip, to: clip)
    try f.intake()
    renderer = Renderer(store: f.store)
    var e = Edit()
    e.crop = CropRect(x: 657, y: 0, w: 607.5, h: 1080)
    e.trimIn = 0.5
    e.trimOut = 3.5
    try store.save(e, videoId: id)
    var v = Version(number: 1)
    v.text = text
    v.caption = "caption"
    try store.save(v, videoId: id)
  }

  func edit(_ change: (inout Edit) -> Void) throws {
    var e = try store.edit(videoId: id)
    change(&e)
    try store.save(e, videoId: id)
  }

  func version(_ change: (inout Version) -> Void) throws {
    var v = try store.versions(videoId: id).first { $0.number == 1 }!
    change(&v)
    try store.save(v, videoId: id)
  }

  func hash(_ p: Platform? = nil) throws -> String { try renderer.editHash(videoId: id, versionNo: 1, platform: p) }
}

/// Mean absolute difference (0…255) between two same-size images, optionally inside a rect (top-left).
func meanAbsDiff(_ a: CGImage, _ b: CGImage, in rect: CGRect? = nil) -> Double {
  let pa = Pixels(a), pb = Pixels(b)
  let r = rect ?? CGRect(x: 0, y: 0, width: pa.w, height: pa.h)
  var sum = 0, n = 0
  for y in Int(r.minY)..<Int(r.maxY) {
    for x in Int(r.minX)..<Int(r.maxX) {
      let i = (y * pa.w + x) * 4
      sum += abs(Int(pa.data[i]) - Int(pb.data[i])) + abs(Int(pa.data[i + 1]) - Int(pb.data[i + 1]))
        + abs(Int(pa.data[i + 2]) - Int(pb.data[i + 2]))
      n += 3
    }
  }
  return n == 0 ? 0 : Double(sum) / Double(n)
}

@Suite struct RenderHashTests {
  @Test func outputNames() throws {
    let rf = try RenderFixture()
    let v = try #require(try rf.store.video(id: rf.id))
    #expect(Renderer.outputName(video: v, versionNo: 1, platform: nil) == "2026-10-23 – Afroween Jazz Piano – yayo x johnny – v1.mp4")
    #expect(Renderer.outputName(video: v, versionNo: 2, platform: .x) == "2026-10-23 – Afroween Jazz Piano – yayo x johnny – v2 – X.mp4")
  }

  @Test func hashChangesOnlyWithOutputRelevantFields() throws {
    let rf = try RenderFixture()
    let base = try rf.hash()
    #expect(try rf.hash() == base)  // stable
    #expect(try rf.hash(.tiktok) == base)  // no per-platform trim → shared render

    // Not output-relevant: caption, score, notes, skipped platforms, other platforms' captions.
    try rf.version { $0.caption = "another caption"; $0.youtubeTitle = "t" }
    try rf.store.setScore(rf.id, 80)
    try rf.store.setNotes(rf.id, "note")
    try rf.edit { $0.skippedPlatforms = [.threads] }
    #expect(try rf.hash() == base)

    try rf.version { $0.text = "Yayo x Johnny" }
    let h1 = try rf.hash()
    #expect(h1 != base)
    try rf.version { $0.posY = 0.3 }
    let h2 = try rf.hash()
    #expect(h2 != h1)
    try rf.edit { $0.crop = CropRect(x: 600, y: 0, w: 607.5, h: 1080) }
    let h3 = try rf.hash()
    #expect(h3 != h2)
    try rf.edit { $0.trimOut = 3.0 }
    let h4 = try rf.hash()
    #expect(h4 != h3)
    var s = try rf.store.settings()
    s.loudnessTarget = -16
    try rf.store.save(s)
    let h5 = try rf.hash()
    #expect(h5 != h4)

    // Per-platform trim: X gets its own scope and hash; the shared render is unchanged.
    try rf.edit { $0.platformTrims[.x] = TrimRange(start: 1, end: 2.5) }
    #expect(try rf.renderer.scope(videoId: rf.id, platform: .x) == "x")
    #expect(try rf.renderer.scope(videoId: rf.id, platform: .tiktok) == "all")
    #expect(try rf.renderer.scope(videoId: rf.id, platform: nil) == "all")
    #expect(try rf.hash(.x) != h5)
    #expect(try rf.hash() == h5)
  }

  @Test func noTextIgnoresTextFields() throws {
    let rf = try RenderFixture()
    try rf.version { $0.noText = true }
    let a = try rf.hash()
    try rf.version { $0.text = "changed"; $0.posY = 0.2 }
    #expect(try rf.hash() == a)
  }

  @Test func refusesWithoutCrop() throws {
    let rf = try RenderFixture()
    try rf.edit { $0.crop = nil }
    #expect(throws: RenderError.self) { try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil) }
    #expect(try rf.store.renders().isEmpty)
  }
}

@Suite struct RenderPipelineTests {
  @Test func probeAndFrame() throws {
    let p = try Media.probe(TestMedia.clip)
    #expect(p.width == 1920 && p.height == 1080 && p.hasAudio && p.videoCodec == "h264")
    #expect(abs(p.duration - 4) < 0.1 && abs(p.fps - 29.97) < 0.01)
    let img = try #require(Media.frame(TestMedia.clip, at: 1.0, maxSize: .zero))
    #expect(img.width == 1920 && img.height == 1080)
    let small = try #require(Media.frame(TestMedia.clip, at: 1.0, maxSize: CGSize(width: 480, height: 480)))
    #expect(small.width == 480)
  }

  @Test func thumbnailIsCachedAndKeyedByCrop() throws {
    let rf = try RenderFixture()
    let v = try #require(try rf.store.video(id: rf.id))
    let a = try #require(Media.thumbnail(store: rf.store, video: v))
    #expect(a.path.hasPrefix(rf.store.paths.thumbs.path))
    let img = try #require(loadImage(a))
    #expect(img.height == 320 && img.width == 180)
    #expect(Media.thumbnail(store: rf.store, video: v) == a)  // cached
    try rf.edit { $0.crop = CropRect(x: 0, y: 0, w: 607.5, h: 1080) }
    #expect(Media.thumbnail(store: rf.store, video: v) != a)
    #expect(Media.thumbnail(store: rf.store, video: v, at: 2) != a)
  }

  @Test func pixelCropIsEvenAndClamped() {
    let r = Media.pixelCrop(CropRect(x: 3001, y: -5, w: 1215.3, h: 2160), sourceWidth: 3840, sourceHeight: 2160)
    #expect(Int(r.width) % 2 == 0 && Int(r.minX) % 2 == 0 && r.maxX <= 3840 && r.minY == 0 && r.height == 2160)
  }

  /// End to end: render, validate, reuse, re-render after an edit, preview ≈ export.
  @Test func ensureRenderLifecycle() throws {
    let rf = try RenderFixture()
    let progress = ProgressLog()
    rf.renderer.onProgress = { id, p in progress.add(p) }
    let r = try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil)
    #expect(r.status == .done && r.scope == "all")
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    #expect(out.lastPathComponent == "2026-10-23 – Afroween Jazz Piano – yayo x johnny – v1.mp4")
    #expect(out.deletingLastPathComponent().path.hasSuffix("Ready to Post/Shortform"))
    let p = try Media.probe(out)
    #expect(p.videoCodec == "h264" && p.width == 1080 && p.height == 1920 && p.hasAudio && p.audioCodec == "aac")
    #expect(abs(p.duration - 3.0) <= 0.1)
    #expect(abs(p.fps - 29.97) < 0.01)
    let cover = URL(fileURLWithPath: try #require(r.coverPath))
    #expect(cover.lastPathComponent == "2026-10-23 – Afroween Jazz Piano – yayo x johnny – v1.jpg")
    let coverImg = try #require(loadImage(cover))
    #expect(coverImg.width == 1080 && coverImg.height == 1920)
    #expect(progress.values.last == 1 && progress.values.count > 2)
    // Work files cleaned up.
    #expect(try FileManager.default.contentsOfDirectory(atPath: rf.store.paths.work.path).isEmpty)

    // Loudness: −14 LUFS target, source was quieter.
    let l = try #require(r.loudness)
    #expect(l.inputI < -20)
    let measured = try rf.renderer.measureLoudness(out)
    #expect(abs(measured.inputI - -14) <= 0.7)
    #expect(measured.inputTP <= -0.9)

    // Preview (source frame → crop → scale → overlay) ≈ export frame, especially in the text box.
    let rv = try #require(try rf.store.resolvedVersion(videoId: rf.id, number: 1))
    let t = 1.5 + 0.5 / 29.97
    let src = try #require(Media.frame(TestMedia.clip, at: 0.5 + t, maxSize: .zero))
    let preview = try #require(Media.compose(src, crop: try rf.store.edit(videoId: rf.id).crop, aspect: .r9x16,
                                             size: CGSize(width: 1080, height: 1920),
                                             overlay: TextOverlay.image(for: rv, aspect: .r9x16)))
    let export = try #require(Media.frame(out, at: t, maxSize: .zero))
    let box = try #require(TextOverlay.textBounds(for: rv, aspect: .r9x16))
    #expect(meanAbsDiff(preview, export, in: box) < 6)
    #expect(meanAbsDiff(preview, export) < 12)

    // Second call reuses the file.
    let mtime = try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date
    let again = try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil)
    #expect(again.id == r.id)
    #expect(try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date == mtime)
    #expect(try rf.renderer.currentRender(videoId: rf.id, versionNo: 1, platform: .tiktok)?.id == r.id)

    // An edit makes the current render stale; ensureRender re-renders and retires the old row.
    try rf.version { $0.text = "New text" }
    #expect(try rf.renderer.currentRender(videoId: rf.id, versionNo: 1, platform: nil) == nil)
    let r2 = try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil)
    #expect(r2.id != r.id && r2.editHash != r.editHash && r2.outputPath == r.outputPath)
    #expect(try rf.store.render(id: r.id)?.deletedAt != nil)

    // Deleting renders removes their files.
    try rf.renderer.deleteRenders(except: [])
    #expect(!FileManager.default.fileExists(atPath: out.path))
    #expect(!FileManager.default.fileExists(atPath: cover.path))
    #expect(try rf.store.renders().isEmpty)
  }

  @Test func perPlatformTrimMakesItsOwnRender() throws {
    let rf = try RenderFixture()
    try rf.edit { $0.platformTrims[.x] = TrimRange(start: 1.0, end: 3.0) }
    let r = try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: .x)
    #expect(r.scope == "x")
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    #expect(out.lastPathComponent.hasSuffix(" – v1 – X.mp4"))
    #expect(abs(try Media.probe(out).duration - 2.0) <= 0.1)
  }

  @Test func overSizeLimitReEncodesSmaller() throws {
    let rf = try RenderFixture()
    var s = try rf.store.settings()
    for p in Platform.allCases { s.limits[p]?.maxBytes = 1_500_000 }
    try rf.store.save(s)
    let root = rf.f.dir.appendingPathComponent("out")
    let renderer = Renderer(store: rf.store, outputRoot: root)
    let r = try renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil)
    #expect(r.outputPath?.hasPrefix(root.path) == true)
    #expect(try #require(r.size) <= 1_500_000)
    #expect(abs(try Media.probe(URL(fileURLWithPath: r.outputPath!)).duration - 3.0) <= 0.1)
  }

  @Test func textTimingOnlyShowsTextInsideTheWindow() throws {
    let rf = try RenderFixture()
    try rf.version { $0.textStart = 1.5; $0.textEnd = 3.0 }
    let r = try rf.renderer.ensureRender(videoId: rf.id, versionNo: 1, platform: nil)
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    let rv = try #require(try rf.store.resolvedVersion(videoId: rf.id, number: 1))
    let box = try #require(TextOverlay.textBounds(for: rv, aspect: .r9x16))
    let px = { (t: Double) -> (UInt8, UInt8, UInt8, UInt8) in
      Pixels(Media.frame(out, at: t, maxSize: .zero)!).at(Int(box.minX) + 6, Int(box.midY))
    }
    let before = px(0.5), during = px(2.0)
    #expect(during.0 > 235 && during.1 > 235 && during.2 > 235)  // white box
    #expect(!(before.0 > 235 && before.1 > 235 && before.2 > 235))
  }
}

final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var v: [Double] = []
  func add(_ x: Double) { lock.withLock { v.append(x) } }
  var values: [Double] { lock.withLock { v } }
}

func loadImage(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  // Decode now: the file may be deleted right after (lazy decoding would then fail).
  return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}
