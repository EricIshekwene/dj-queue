import Foundation
import Testing
@testable import DJQCore

/// Round 23 addendum (D12): a made video shows the whole photo by default, in a 9:16 frame over a blurred copy of
/// itself, and its crop is the whole frame. "Fill the frame" is the other way: the photo's own shape, Eric's crop.
@Suite(.enabled(if: Tone.haveTools, "ffmpeg and ffprobe aren't installed")) struct R23WholePhotoTests {
  func shade(_ c: PhotoImages.RGB) -> PhotoImages.RGB { PhotoImages.bitmap(PhotoImages.image(width: 2, height: 2, left: c, right: c))[0, 0] }

  @Test func layoutIsNineBySixteenWithThePhotoInsideAndNeverEnlarged() {
    func whole(_ w: Int, _ h: Int) -> [Int] {
      let l = StillVideo.layout(width: w, height: h, fit: .whole)
      return [l.frame.width, l.frame.height, l.photo.width, l.photo.height]
    }
    #expect(whole(4000, 3000) == [2160, 3840, 2160, 1620], "wide")
    #expect(whole(3000, 3000) == [2160, 3840, 2160, 2160], "square")
    #expect(whole(2000, 2500) == [1998, 3552, 1998, 2498], "4:5, a little under 2160 wide: the frame shrinks so the photo isn't enlarged")
    #expect(whole(1000, 4000) == [2160, 3840, 960, 3840], "very tall")
    #expect(whole(400, 300) == [396, 704, 396, 298], "small: its own pixels")
    #expect(whole(1080, 1920) == [1080, 1920, 1080, 1920] && whole(2160, 3840) == [2160, 3840, 2160, 3840], "9:16: the photo is the frame")
    // Review round 2, S2. Nearly 9:16: the frame is exactly 9:16 all the same. Within half a percent the photo covers
    // it; further off it sits inside, over its background.
    #expect(whole(1085, 1920) == [1080, 1920, 1080, 1920] && whole(1080, 1912) == [1080, 1920, 1080, 1920], "within half a percent: it covers the frame")
    #expect(whole(965, 1700) == [954, 1696, 954, 1680], "1 % off, where even pixels used to tip it over the renderer's limit")
    #expect(whole(5011, 8996) == [2160, 3840, 2138, 3840])
    for (w, h) in [(4000, 3000), (3000, 3000), (2000, 2500), (1000, 4000), (400, 300), (6000, 900), (233, 977), (965, 1700), (5011, 8996)] {
      let l = StillVideo.layout(width: w, height: h, fit: .whole)
      #expect(l.frame.width * 16 == l.frame.height * 9, "\(w)×\(h): exactly 9:16")
      #expect(l.frame.width % 2 == 0 && l.frame.height % 2 == 0 && l.photo.width % 2 == 0 && l.photo.height % 2 == 0)
      #expect(l.photo.width <= l.frame.width && l.photo.height <= l.frame.height && l.photo.width <= w + 1 && l.photo.height <= h + 1)
      #expect(l.frame.width <= 2160 && !l.fills)
      #expect(l.offset.x % 2 == 0 && l.offset.y % 2 == 0 && l.offset.x >= 0 && l.offset.y >= 0, "the photo starts on an even pixel")
      #expect(abs(l.offset.x * 2 + l.photo.width - l.frame.width) <= 2 && abs(l.offset.y * 2 + l.photo.height - l.frame.height) <= 2, "centred")
      // Fill the frame is the photo's own shape, as before.
      let fill = StillVideo.layout(width: w, height: h, fit: .fill)
      let own = StillVideo.frameSize(width: w, height: h)
      #expect(fill.fills && fill.frame.width == own.width && fill.frame.height == own.height)
    }
    // Every size from 200 to 9000 px high within 3 % of 9:16, and a spread of every other shape: the frame is exactly
    // 9:16 and even, its whole-frame crop is one the renderer takes, and the photo is inside it, never enlarged by
    // more than the half percent that lets a near-9:16 photo cover the frame.
    var wrong: [String] = []
    func check(_ w: Int, _ h: Int) {
      let l = StillVideo.layout(width: w, height: h, fit: .whole)
      let (fw, fh, pw, ph) = (l.frame.width, l.frame.height, l.photo.width, l.photo.height)
      let crop = CropRect(x: 0, y: 0, w: Double(fw), h: Double(fh))
      let grow = 1 + StillVideo.nearNineSixteen
      let ok = fw * 16 == fh * 9 && fw % 2 == 0 && fh % 2 == 0 && fw <= 2160 && pw % 2 == 0 && ph % 2 == 0 && pw <= fw && ph <= fh && pw >= 2 && ph >= 2
        && Media.cropProblem(crop, aspect: .r9x16, sourceWidth: fw, sourceHeight: fh) == nil
        && Double(pw) <= Double(w) * grow + 1 && Double(ph) <= Double(h) * grow + 1
        && (l.fills || pw == fw || ph == fh || abs(Double(pw) / Double(fw) - Double(ph) / Double(fh)) < 1)
        && (l.fills || pw < fw || ph < fh)
      if !ok, wrong.count < 5 { wrong.append("\(w)×\(h) → \(fw)×\(fh), photo \(pw)×\(ph)") }
    }
    var checked = 0
    for h in 200...9000 {
      let mid = Double(h) * 9 / 16
      for w in max(200, Int(mid * 0.97))...max(200, Int(mid * 1.03)) {
        check(w, h)
        checked += 1
      }
    }
    for w in stride(from: 200, through: 9000, by: 37) {
      for h in stride(from: 200, through: 9000, by: 41) {
        check(w, h)
        checked += 1
      }
    }
    #expect(wrong.isEmpty && checked > 400_000, "\(wrong)")
  }

  /// Review round 2, S2: 965×1700 is 1 % off 9:16. It used to be made at its own shape (966×1700), said "nothing to
  /// fix" and then could not be rendered. Now its frame is 9:16 and it renders.
  @Test func aPhotoNearlyNineBySixteenStillRenders() throws {
    let f = try Fixture.engine(1)
    let p = try f.singlePhoto("near", title: "Nearly", width: 965, height: 1700)
    let v = try StillVideo(store: f.store).addAudio(to: p.id, audio: f.tone(seconds: 2)).video
    #expect(v.sourceWidth == 954 && v.sourceHeight == 1696 && v.still?.fit == .whole)
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    #expect(try f.send(v.id).changed == [v.id])
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    let info = try Media.probe(out)
    #expect(r.status == .done && info.width == 1080 && info.height == 1920 && info.hasAudio)
    // The whole photo, side to side (red on the left, blue on the right), with a sliver of its background above it.
    let frame = try #require(Tone.frame(out, at: 1, in: f.dir))
    #expect(frame[20, 960].near(shade(.red), 16) && frame[1060, 960].near(shade(.blue), 16), "\(frame[20, 960]) \(frame[1060, 960])")
    // Fill the frame, the same photo: its own shape, and Eric's crop renders too.
    let q = try f.singlePhoto("near-fill", title: "Nearly too", width: 965, height: 1700)
    let fill = try StillVideo(store: f.store).addAudio(to: q.id, audio: f.tone("b.wav", seconds: 2), fit: .fill).video
    #expect(fill.sourceWidth == 966 && fill.sourceHeight == 1700)
    #expect(try f.send(fill.id).changed == [fill.id])
    #expect(try Renderer(store: f.store).ensureRender(videoId: fill.id, versionNo: 1, platform: nil).status == .done)
  }

  /// Review round 2, S3: with New clip defaults → Aspect on another shape, a whole-photo video says 9:16 itself (it is
  /// 9:16 by the way it is made), so there is nothing to fix and it renders. Fill the frame follows the defaults.
  @Test func aWholePhotoVideoIsNineBySixteenWhateverTheDefaultShape() throws {
    let f = try Fixture.engine(1)
    try f.updateSettings { $0.defaults.aspect = .r4x5 }
    let maker = StillVideo(store: f.store), bulk = BulkActions(store: f.store)
    let p = try f.singlePhoto("flyer", title: "Saturday flyer", width: 1600, height: 900)
    let v = try maker.addAudio(to: p.id, audio: f.tone(seconds: 3)).video
    func edit() throws -> Edit { try f.store.edit(videoId: v.id) }
    func resolved() throws -> ResolvedEdit { try f.store.resolvedEdit(videoId: v.id) }
    func issues() throws -> [ValidationIssue.Kind] { try Validation.issues(video: try #require(try f.store.video(id: v.id)), store: f.store).map(\.kind) }
    let frame = CropRect(x: 0, y: 0, w: 1584, h: 2816)
    #expect(try edit().aspectOverride == .r9x16 && edit().crop == frame)
    #expect(try resolved().aspect == .r9x16 && resolved().cropConfirmed && issues().isEmpty)
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let rendered = try #require(r.outputPath)
    let info = try Media.probe(URL(fileURLWithPath: rendered))
    #expect(r.status == .done && info.width == 1080 && info.height == 1920)
    // Crop → Reset (the override goes): still the whole frame, still nothing to confirm.
    var cleared = try edit()
    cleared.crop = nil
    try f.store.save(cleared, videoId: v.id)
    #expect(try resolved().cropConfirmed && resolved().crop == frame && issues().isEmpty)
    // Fill the frame follows the defaults again (4:5 here), and asks for its crop.
    let toFill = try #require(try maker.setFit(videoId: v.id, fit: .fill).batchId)
    #expect(try edit().aspectOverride == nil && edit().crop == nil && resolved().aspect == .r4x5 && issues() == [.noCrop])
    // Its undo brings the 9:16 back with the whole frame.
    #expect(try bulk.undo(toFill).changed == [v.id])
    #expect(try edit().aspectOverride == .r9x16 && resolved().cropConfirmed && issues().isEmpty)
    // Back to whole from fill, and Change audio (with and without a fit): 9:16 each time.
    _ = try maker.setFit(videoId: v.id, fit: .fill)
    _ = try maker.setFit(videoId: v.id, fit: .whole)
    #expect(try edit().aspectOverride == .r9x16 && edit().crop == frame && issues().isEmpty)
    _ = try maker.changeAudio(videoId: v.id, audio: f.tone("b.wav", seconds: 2), fit: .fill)
    #expect(try edit().aspectOverride == nil && issues() == [.noCrop])
    _ = try maker.changeAudio(videoId: v.id, audio: f.tone("c.wav", seconds: 2), fit: .whole)
    #expect(try edit().aspectOverride == .r9x16 && edit().crop == frame && issues().isEmpty)
    // The defaults' shape changed after it was made (its edit says nothing, its crop is the whole frame): the next
    // Change audio puts it right.
    var stale = try edit()
    stale.aspectOverride = nil
    try f.store.save(stale, videoId: v.id)
    #expect(try resolved().aspect == .r4x5)
    _ = try maker.changeAudio(videoId: v.id, audio: f.tone("d.wav", seconds: 2))
    #expect(try edit().aspectOverride == .r9x16 && issues().isEmpty)
    // Remove audio: a photo post has its own shape setting, so the 9:16 goes; its undo brings the video back with it.
    let removed = try #require(try maker.removeAudio(videoId: v.id).batchId)
    #expect(try edit().aspectOverride == nil && f.store.video(id: v.id)?.isPhoto == true)
    #expect(try bulk.undo(removed).changed == [v.id])
    #expect(try edit().aspectOverride == .r9x16 && issues().isEmpty)
    // With the default at 9:16 the edit says nothing, as before.
    try f.updateSettings { $0.defaults.aspect = .r9x16 }
    let q = try f.singlePhoto("second", title: "Second", width: 1600, height: 900)
    let w = try maker.addAudio(to: q.id, audio: f.tone("e.wav", seconds: 2)).video
    #expect(try f.store.edit(videoId: w.id).aspectOverride == nil && f.store.resolvedEdit(videoId: w.id).isDefault(.aspect))
  }

  /// Both fits for wide, square, 4:5, 9:16 and very tall photos. Whole: the frame is 9:16, the photo's own colours are
  /// at its middle (tolerance 12 of 255: JPEG sources), and the corners outside it are its blurred, darkened copy.
  @Test func bothFitsForEveryShape() throws {
    let f = try Fixture(clips: [], longform: false)
    let maker = StillVideo(store: f.store)
    let tone = f.tone(seconds: 1.2)
    let red = shade(.red), blue = shade(.blue)
    func dark(_ c: PhotoImages.RGB) -> PhotoImages.RGB { .init(r: c.r * 65 / 100, g: c.g * 65 / 100, b: c.b * 65 / 100) }
    for (name, w, h) in [("wide", 1600, 900), ("square", 1000, 1000), ("four-five", 800, 1000), ("nine-sixteen", 720, 1280), ("tall", 400, 1800)] {
      let photo = f.inbox.appendingPathComponent("\(name).jpg")
      PhotoImages.write(photo, width: w, height: h, left: .red, right: .blue)
      let layout = StillVideo.layout(width: w, height: h, fit: .whole)
      let made = try maker.make(photo: photo, audio: tone, videoId: "\(name)-whole", fit: .whole)
      let info = try Media.probe(made.video)
      #expect(info.width == layout.frame.width && info.height == layout.frame.height && info.width * 16 == info.height * 9, "\(name): \(info.width)×\(info.height)")
      #expect(info.hasAudio && abs(info.duration - 1.2) <= 0.05 && info.fps == 30 && made.width == info.width)
      let frame = try #require(Tone.frame(made.video, at: 0.6, in: f.dir))
      let (fw, fh, pw, ph) = (layout.frame.width, layout.frame.height, layout.photo.width, layout.photo.height)
      let (x0, y0) = (layout.offset.x, layout.offset.y)
      // The photo, whole: red at the middle of its left half, blue at the middle of its right half, right up to its edges.
      #expect(frame[x0 + pw / 4, fh / 2].near(red, 12) && frame[x0 + pw * 3 / 4, fh / 2].near(blue, 12), "\(name): \(frame[x0 + pw / 4, fh / 2])")
      #expect(frame[x0 + 6, y0 + 6].near(red, 12) && frame[x0 + pw - 7, y0 + ph - 7].near(blue, 12), "\(name): the photo's own corners")
      if !layout.fills {
        // Outside the photo: its blurred copy, darkened to 65 %, red where the photo is red and blue where it is blue.
        let corners = [frame[4, 4], frame[fw - 5, 4], frame[4, fh - 5], frame[fw - 5, fh - 5]]
        for (i, c) in corners.enumerated() {
          #expect(c.near(dark(i % 2 == 0 ? red : blue), 14), "\(name): corner \(i) is \(c), not the darkened photo \(dark(i % 2 == 0 ? red : blue))")
        }
        // The row or column just outside the photo holds the background's own colour in the file, like the ones
        // beyond it: the photo starts on an even pixel, so it shares no colour sample with the background. (Read
        // without a player's blending of neighbouring samples, which is the same for any edge in any video.)
        let raw = try #require(Tone.frame(made.video, at: 0.6, in: f.dir, stored: true))
        let outside = pw == fw
          ? [(raw[fw / 4, y0 - 1], raw[fw / 4, y0 - 6]), (raw[fw * 3 / 4, y0 + ph], raw[fw * 3 / 4, y0 + ph + 5])]
          : [(raw[x0 - 1, fh / 4], raw[x0 - 6, fh / 4]), (raw[x0 + pw, fh * 3 / 4], raw[x0 + pw + 5, fh * 3 / 4])]
        for (edge, beyond) in outside {
          #expect(edge.near(beyond, 6), "\(name): the pixel beside the photo is \(edge), the background beyond it \(beyond)")
        }
        #expect(x0 % 2 == 0 && y0 % 2 == 0)
      } else {
        #expect(name == "nine-sixteen" && pw == fw && ph == fh)
      }
      // Fill the frame: the video is the photo's own shape, all photo.
      let filled = try maker.make(photo: photo, audio: tone, videoId: "\(name)-fill", fit: .fill)
      let own = StillVideo.frameSize(width: w, height: h)
      let finfo = try Media.probe(filled.video)
      #expect(finfo.width == own.width && finfo.height == own.height, "\(name) fill: \(finfo.width)×\(finfo.height)")
      let ff = try #require(Tone.frame(filled.video, at: 0.6, in: f.dir))
      #expect(ff[3, 3].near(red, 12) && ff[own.width - 4, own.height - 4].near(blue, 12), "\(name) fill: photo to the corners")
      if layout.fills {
        #expect(frame.difference(ff) == 0, "9:16: the two ways are the same picture")
      }
    }
    #expect(f.stillLeftovers.isEmpty)
  }

  /// The photos that are easy to get wrong, as whole photos: one the camera stored on its side, one with see-through
  /// parts, and a panorama.
  @Test func aTurnedPhotoASeeThroughOneAndAPanoramaAsWholePhotos() throws {
    let f = try Fixture(clips: [], longform: false)
    let maker = StillVideo(store: f.store)
    let tone = f.tone(seconds: 1.2)
    let red = shade(.red), blue = shade(.blue)
    func dark(_ c: PhotoImages.RGB) -> PhotoImages.RGB { .init(r: c.r * 65 / 100, g: c.g * 65 / 100, b: c.b * 65 / 100) }
    // EXIF orientation 6: stored 400×300 with red on the left, seen upright as 300×400 with red on top.
    let turned = f.inbox.appendingPathComponent("turned.jpg")
    PhotoImages.write(turned, width: 400, height: 300, left: .red, right: .blue, orientation: 6)
    let a = try maker.make(photo: turned, audio: tone, videoId: "turned", fit: .whole)
    let la = StillVideo.layout(width: 300, height: 400, fit: .whole)
    #expect(a.width == 288 && a.height == 512 && la.photo.width == 288 && la.photo.height == 384 && la.offset.y == 64)
    let fa = try #require(Tone.frame(a.video, at: 0.5, in: f.dir))
    #expect(fa.width == 288 && fa.height == 512)
    #expect(fa[144, 64 + 96].near(red, 12) && fa[144, 64 + 288].near(blue, 12), "upright: red above blue, \(fa[144, 160]) \(fa[144, 352])")
    #expect(fa[144, 8].near(dark(red), 14) && fa[144, 503].near(dark(blue), 14), "its copy above and below it: \(fa[144, 8]) \(fa[144, 503])")
    // See-through on the right: drawn on white, as a photo post draws it; the background is that picture, darkened.
    let glass = f.inbox.appendingPathComponent("glass.png")
    #expect(PhotoImages.writeSeeThrough(glass, width: 400, height: 300, left: .red))
    let b = try maker.make(photo: glass, audio: tone, videoId: "glass", fit: .whole)
    let fb = try #require(Tone.frame(b.video, at: 0.5, in: f.dir))
    let lb = StillVideo.layout(width: 400, height: 300, fit: .whole)
    #expect(fb.width == 396 && fb.height == 704 && lb.offset.y == 202)
    #expect(fb[99, 352].near(red, 8) && fb[297, 352].near(.white, 4), "red, and white where it was see-through: \(fb[99, 352]) \(fb[297, 352])")
    #expect(fb[4, 4].near(dark(red), 14) && fb[391, 699].near(dark(.white), 8), "\(fb[4, 4]) \(fb[391, 699])")
    // A panorama, six times as wide as it is high: a thin band across the middle, never cut.
    let wide = f.inbox.appendingPathComponent("panorama.jpg")
    PhotoImages.write(wide, width: 1200, height: 200, left: .red, right: .blue)
    let c = try maker.make(photo: wide, audio: tone, videoId: "panorama", fit: .whole)
    let lc = StillVideo.layout(width: 1200, height: 200, fit: .whole)
    #expect(c.width == 1188 && c.height == 2112 && lc.photo.width == 1188 && lc.photo.height == 198 && lc.offset.y == 956)
    let fc = try #require(Tone.frame(c.video, at: 0.5, in: f.dir))
    #expect(fc[6, 1056].near(red, 12) && fc[1181, 1056].near(blue, 12), "edge to edge: \(fc[6, 1056]) \(fc[1181, 1056])")
    #expect(fc[300, 960].near(red, 12) && fc[300, 1150].near(red, 12) && fc[900, 1150].near(blue, 12), "the band's own rows")
    let rc = try #require(Tone.frame(c.video, at: 0.5, in: f.dir, stored: true))
    #expect(rc[300, 955].near(rc[300, 940], 6) && rc[300, 1154].near(rc[300, 1170], 6), "no fringe above or below the band: \(rc[300, 955]) \(rc[300, 1154])")
    #expect(fc[6, 6].near(dark(red), 14) && fc[1181, 2105].near(dark(blue), 14), "\(fc[6, 6]) \(fc[1181, 2105])")
    #expect(f.stillLeftovers.isEmpty)
  }

  @Test func aStillWithoutFitReadsAsFillAndIsStoredAsItWas() throws {
    let json = #"{"photo":{"id":"p1","file":"Originals/x/01-p1.jpg","width":4000,"height":3000},"audio":"Stills/x/audio.mp3","audioName":"Friday mix.mp3","audioDuration":181.5}"#
    let old = try JSONCoding.decoder.decode(StillSource.self, from: Data(json.utf8))
    #expect(old.fit == nil && old.fits == .fill && old.audioName == "Friday mix.mp3")
    #expect(!JSONCoding.string(old).contains("fit"), "a row made before D12 is written back without the key")
    var new = old
    new.fit = .whole
    #expect(JSONCoding.string(new).contains(#""fit":"whole""#) && !JSONCoding.string(new).contains("other"))
    new.other = "Stills/x/video.mp4"
    #expect(try JSONCoding.decoder.decode(StillSource.self, from: Data(JSONCoding.string(new).utf8)) == new)
    #expect(StillSource.Fit.whole.displayName == "Whole photo" && StillSource.Fit.fill.displayName == "Fill the frame")
  }

  @Test func addAudioShowsTheWholePhotoByDefaultAndItsCropNeedsNoConfirming() throws {
    let f = try Fixture.engine(1)
    let p = try f.singlePhoto("flyer", title: "Saturday flyer", width: 1600, height: 900)
    let v = try StillVideo(store: f.store).addAudio(to: p.id, audio: f.tone(seconds: 3)).video
    #expect(v.still?.fit == .whole && v.sourceWidth == 1584, "1600 wide: the nearest 9:16 frame that doesn't enlarge it: \(v.sourceWidth ?? 0)")
    let w = try #require(v.sourceWidth), h = try #require(v.sourceHeight)
    #expect(w * 16 == h * 9)
    // The crop is the whole frame, stored and confirmed: nothing to fix, and Send to Queue takes it as it is.
    let e = try f.store.edit(videoId: v.id)
    #expect(e.crop == CropRect(x: 0, y: 0, w: Double(w), h: Double(h)))
    let re = try f.store.resolvedEdit(videoId: v.id)
    #expect(re.cropConfirmed && re.aspect == .r9x16 && re.crop == e.crop)
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    #expect(try f.send(v.id).changed == [v.id])
    #expect(try f.store.video(id: v.id)?.state == .ready && f.store.edit(videoId: v.id).crop == e.crop)
    _ = try BulkActions(store: f.store).back([v.id])
    // Reset to defaults (the crop override goes): still the whole frame, still confirmed, and it still renders.
    var cleared = e
    cleared.crop = nil
    try f.store.save(cleared, videoId: v.id)
    let back = try f.store.resolvedEdit(videoId: v.id)
    #expect(back.cropConfirmed && back.crop == e.crop)
    #expect(try !Validation.issues(video: try #require(try f.store.video(id: v.id)), store: f.store).contains { $0.kind == .noCrop })
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    let info = try Media.probe(out)
    #expect(info.width == 1080 && info.height == 1920 && info.hasAudio)
    // The rendered post shows the whole photo across the middle, over its blurred copy above and below.
    let frame = try #require(Tone.frame(out, at: 1, in: f.dir))
    let source = try #require(PhotoImages.bitmap(f.inbox.appendingPathComponent("flyer-1.jpg")))
    #expect(frame[270, 960].near(source[400, 450], 16) && frame[810, 960].near(source[1200, 450], 16), "\(frame[270, 960]) \(frame[810, 960])")
    #expect(frame[20, 660].near(source[400, 450], 20) && frame[1060, 1260].near(source[1200, 450], 20), "the photo reaches both sides")
    let top = frame[270, 80]
    #expect(top.r + top.g + top.b > 60 && !top.near(source[400, 450], 30), "above the photo: the blurred copy, not black and not the photo: \(top)")
    // A photo post still has its own rules, and a Fill video still asks for the crop.
    let fill = try f.still("fill", title: "Fill")
    #expect(try Validation.issues(video: fill, store: f.store).contains { $0.kind == .noCrop })
    #expect(try !f.store.resolvedEdit(videoId: fill.id).cropConfirmed)
  }

  @Test func aFitChangeMakesTheVideoAgainFromItsOwnAudioAndUndoBringsItBack() throws {
    let f = try Fixture(clips: [], longform: false)
    let maker = StillVideo(store: f.store), bulk = BulkActions(store: f.store)
    let p = try f.singlePhoto("flyer", title: "Saturday flyer", width: 1600, height: 900)
    let tone = f.tone("Friday mix.wav", seconds: 4)
    let whole = try maker.addAudio(to: p.id, audio: tone).video
    var e = try f.store.edit(videoId: whole.id)
    e.trimIn = 0.5
    e.trimOut = 3
    e.coverTime = 1
    e.platformTrims = [.x: TrimRange(start: 0, end: 2)]
    e.skippedPlatforms = [.threads]
    try f.store.save(e, videoId: whole.id)
    var one = Version(number: 1)
    one.text = "Doors at ten"
    one.textStart = 1
    one.textEnd = 2
    one.caption = "Come through"
    try f.store.save(one, videoId: whole.id)
    let stored = try f.stored(whole.id)
    let audioBytes = try Data(contentsOf: f.paths.photos.appendingPathComponent(try #require(whole.still?.audio)))
    // The picked audio can go: the video is made again from DJ Queue's own copy.
    try FileManager.default.removeItem(at: tone)
    // Whole → Fill: the photo's own shape, no confirmed crop; everything else as it was.
    let change = try maker.setFit(videoId: whole.id, fit: .fill)
    let fill = change.video
    #expect(fill.still?.fit == .fill && fill.sourceWidth == 1600 && fill.sourceHeight == 900 && fill.file == "Stills/\(fill.id)/video-2.mp4")
    #expect(fill.still?.audio == whole.still?.audio && fill.still?.audioName == "Friday mix.wav" && fill.duration == whole.duration)
    #expect(f.stillFiles(fill.id) == ["audio.m4a", "video-2.mp4", "video.mp4"], "no second audio copy")
    #expect(try Data(contentsOf: f.paths.photos.appendingPathComponent("Stills/\(fill.id)/audio.m4a")) == audioBytes)
    let info = try Media.probe(try #require(try f.store.fileURL(for: fill)))
    #expect(info.width == 1600 && info.height == 900 && info.hasAudio && abs(info.duration - whole.duration) <= 0.05)
    var want = e
    want.crop = nil
    #expect(try f.store.edit(videoId: fill.id) == want, "the crop resets; trim, cover, per-platform trims and platforms stay")
    #expect(try f.store.versions(videoId: fill.id) == [one], "texts and captions stay")
    #expect(try Validation.issues(video: fill, store: f.store).map(\.kind) == [.noCrop])
    #expect(try bulk.batch(id: try #require(change.batchId))?.action == "photo-audio-fit")
    #expect(ClipStage.of(fill) == .edit && !fill.sentToQueue)
    // The same fit again: nothing made, nothing journaled.
    let same = try maker.setFit(videoId: fill.id, fit: .fill)
    #expect(same.batchId == nil && f.stillFiles(fill.id).count == 3)
    // Undo: the whole-photo video again, with its crop, byte for byte.
    #expect(try bulk.undo(try #require(change.batchId)).changed == [fill.id])
    #expect(try f.stored(whole.id) == stored)
    // Fill → Whole: the whole frame again, confirmed. The video it had as a whole photo is still there, so nothing
    // is made: the row goes back to that file, and flipping again goes back to the other.
    let third = try maker.setFit(videoId: whole.id, fit: .fill).video
    #expect(third.file.hasSuffix("video-3.mp4") && third.still?.other == whole.file, "after an undo the fill video is made once more")
    let flipped = try maker.setFit(videoId: whole.id, fit: .whole)
    let again = flipped.video
    #expect(again.still?.fit == .whole && again.file == whole.file && again.still?.other == third.file && again.sourceWidth == whole.sourceWidth)
    #expect(again.fingerprint == whole.fingerprint && again.fileSize == whole.fileSize && again.duration == whole.duration)
    let files = f.stillFiles(whole.id)
    #expect(files == ["audio.m4a", "video-2.mp4", "video-3.mp4", "video.mp4"])
    for fit in [StillSource.Fit.fill, .whole, .fill, .whole] {
      let v = try maker.setFit(videoId: whole.id, fit: fit).video
      #expect(v.file == (fit == .whole ? whole.file : third.file) && v.sourceWidth == (fit == .whole ? whole.sourceWidth : 1600))
    }
    #expect(f.stillFiles(whole.id) == files, "two videos for this audio, however often the fit flips")
    // The undo of a flip that made nothing is the same undo: the fill video again.
    #expect(try bulk.undo(try #require(flipped.batchId)).changed == [whole.id])
    #expect(try f.store.video(id: whole.id)?.file == third.file && f.store.video(id: whole.id)?.still?.fit == .fill)
    _ = try maker.setFit(videoId: whole.id, fit: .whole)
    // A file under that name that isn't what a new one would be (here: another shape) isn't used: the video is made.
    let fillFile = f.paths.photos.appendingPathComponent(third.file)
    try FileManager.default.removeItem(at: fillFile)
    try FileManager.default.copyItem(at: f.paths.photos.appendingPathComponent(whole.file), to: fillFile)
    let remade = try maker.setFit(videoId: whole.id, fit: .fill).video
    #expect(remade.file.hasSuffix("video-4.mp4") && remade.sourceWidth == 1600 && remade.still?.other == whole.file)
    _ = try maker.setFit(videoId: whole.id, fit: .whole)
    #expect(try f.store.video(id: whole.id)?.file == whole.file)
    #expect(try f.store.edit(videoId: again.id).crop == CropRect(x: 0, y: 0, w: Double(again.sourceWidth ?? 0), h: Double(again.sourceHeight ?? 0)))
    #expect(try Validation.issues(video: again, store: f.store).isEmpty)
    // Change audio keeps the fit; with a fit it changes both.
    let other = try maker.changeAudio(videoId: again.id, audio: f.tone("other.wav", seconds: 2)).video
    #expect(other.still?.fit == .whole && other.sourceWidth == whole.sourceWidth && other.still?.audio.hasSuffix("audio-5.m4a") == true)
    #expect(other.still?.other == nil, "the video at the other fit holds the old audio: not one to go back to")
    let both = try maker.changeAudio(videoId: again.id, audio: f.tone("third.wav", seconds: 2), fit: .fill).video
    #expect(both.still?.fit == .fill && both.sourceWidth == 1600)
    #expect(try f.store.edit(videoId: both.id).crop == nil)
    // A damaged audio copy, one cut short and none at all: the same sentence each time, in words (no tool output, no
    // folder), nothing made and nothing left behind.
    let copy = f.paths.photos.appendingPathComponent(try #require(both.still?.audio))
    let good = try Data(contentsOf: copy)
    let before = f.stillFiles(both.id)
    let unusable = "Its audio file is missing or can't be read (third.wav): choose the audio again with Change audio"
    func refused() -> String {
      do { _ = try maker.setFit(videoId: both.id, fit: .whole); return "done" } catch { return "\(error)" }
    }
    try Data("not audio at all".utf8).write(to: copy)
    #expect(refused() == unusable)
    try Data(good.prefix(good.count / 2)).write(to: copy)
    #expect(refused() == unusable)
    try FileManager.default.removeItem(at: copy)
    #expect(refused() == unusable)
    #expect(f.stillFiles(both.id) == before.filter { $0 != copy.lastPathComponent } && f.stillLeftovers.isEmpty)
    #expect(try f.store.video(id: both.id)?.still?.fit == .fill)
    // What a tool says when it stops never carries a folder into a message.
    let said = Proc.Result(status: 1, stdout: "", stderr: """
      [mov,mp4,m4a,3gp,3g2,mj2 @ 0x600] moov atom not found
      \(copy.path): Invalid data found when processing input
      /private/var/folders/zz/T/still-1/segment.mp4: No such file or directory at 16/9 or 25 kb/s
      """)
    #expect(StillVideo.words(said, [copy]) == "[mov,mp4,m4a,3gp,3g2,mj2 @ 0x600] moov atom not found | \(copy.lastPathComponent): Invalid data found when processing input"
      + " | segment.mp4: No such file or directory at 16/9 or 25 kb/s")
  }

  @Test func aFitChangeIsRefusedOnceItIsScheduledOrPosted() throws {
    let f = try Fixture.engine(1)
    let maker = StillVideo(store: f.store)
    func refused(_ body: () throws -> Void) -> String {
      do { try body(); return "done" } catch { return "\(error)" }
    }
    let v = try f.still("a", title: "A", fit: .whole)
    #expect(refused { try maker.setFit(videoId: "clip-0", fit: .whole) }.hasSuffix("has no audio: add audio first"))
    #expect(refused { try maker.setFit(videoId: try f.singlePhoto("p").id, fit: .whole) }.hasSuffix("has no audio: add audio first"))
    try f.send(v.id)
    #expect(refused { try maker.setFit(videoId: v.id, fit: .fill) } == StillVideo.lockedReason, "in the Queue")
    try Planner(store: f.store).autoSchedule()
    #expect(refused { try maker.setFit(videoId: v.id, fit: .fill) } == "Send it back to Edit first")
    var post = try #require(try f.store.posts(where: "video_id=?", [v.id]).first)
    post.state = .posted
    post.postedAt = f.clock.now
    try f.store.save(post)
    #expect(refused { try maker.setFit(videoId: v.id, fit: .fill) } == StillVideo.lockedReason)
    #expect(try f.store.video(id: v.id)?.still?.fit == .whole && f.stillFiles(v.id) == ["audio.m4a", "video.mp4"])
    // The same fit is no change, so it isn't refused either.
    #expect(refused { try maker.setFit(videoId: v.id, fit: .whole) } == "done")
    // The fit's undo is refused under a day too (the restore would change what it is).
    let w = try f.still("b", title: "B", fit: .whole)
    let batch = try #require(try maker.setFit(videoId: w.id, fit: .fill).batchId)
    var e = try f.store.edit(videoId: w.id)
    e.crop = CropRect(x: 116, y: 0, w: 168, h: 300)
    try f.store.save(e, videoId: w.id)
    try f.send(w.id)
    try Planner(store: f.store).autoSchedule()
    #expect(try BulkActions(store: f.store).undo(batch, force: true).skipped[w.id] == "It's scheduled or posted now: send it back to Edit first")
    #expect(try f.store.video(id: w.id)?.still?.fit == .fill)
  }

  @Test(.enabled(if: R6PostizCLITests.binary != nil)) func theFitFlagsThroughTheBinary() throws {
    let env = try R6PostizCLITests.Env(clips: 0)
    let files = env.f.pictures(["a.jpg", "b.jpg"], width: 800, height: 600)
    let tone = env.f.tone("Set.wav", seconds: 2)
    func still(_ o: [String: Any]) -> [String: Any]? { (o["video"] as? [String: Any] ?? o)["still"] as? [String: Any] }
    // The default is the whole photo; --fit fill asks for the other.
    let whole = try env.json("photo", "add", files[0].path, "--audio", tone.path)
    let first = try #require((whole["posts"] as? [[String: Any]])?.first)
    #expect(still(first)?["fit"] as? String == "whole" && (first["reasons"] as? [String]) == ["No title"])
    let fill = try env.json("photo", "add", files[1].path, "--audio", tone.path, "--fit", "fill", "--title", "B")
    let second = try #require((fill["posts"] as? [[String: Any]])?.first)
    #expect(still(second)?["fit"] as? String == "fill" && (second["reasons"] as? [String]) == ["No crop"])
    let id = try #require(first["id"] as? String), id2 = try #require(second["id"] as? String)
    // Only the fit: made again from its own audio.
    let refit = try env.json("photo", "audio", id, "--fit", "fill")
    #expect(refit["change"] as? String == "refitted" && refit["batchId"] is String && still(refit)?["fit"] as? String == "fill")
    #expect(try env.store.video(id: id)?.file.hasSuffix("video-2.mp4") == true && env.f.stillFiles(id) == ["audio.m4a", "video-2.mp4", "video.mp4"])
    let same = try env.json("photo", "audio", id, "--fit", "fill")
    #expect(same["change"] as? String == "unchanged" && same["batchId"] == nil)
    let words = try env.djq("photo", "audio", id2, "--fit", "whole")
    #expect(words.status == 0 && words.out.contains("now whole photo") && words.out.contains("undo: djq bulk undo"), "\(words.out)\(words.err)")
    // Audio and fit together, on a photo post and on a made video.
    let photo = try env.json("photo", "add", files[0].path)
    let pid = try #require((photo["posts"] as? [[String: Any]])?.first?["id"] as? String)
    let added = try env.json("photo", "audio", pid, tone.path, "--fit", "fill")
    #expect(added["change"] as? String == "added" && still(added)?["fit"] as? String == "fill")
    let changed = try env.json("photo", "audio", pid, tone.path, "--fit", "whole")
    #expect(changed["change"] as? String == "changed" && still(changed)?["fit"] as? String == "whole")
    // Wrong uses read as sentences.
    let bad = try env.djq("photo", "audio", id, "--fit", "stretch")
    #expect(bad.status != 0 && (bad.out + bad.err).contains("--fit takes whole or fill, not stretch"), "\(bad.out)\(bad.err)")
    let lone = try env.djq("photo", "add", files[0].path, "--fit", "fill")
    #expect(lone.status != 0 && (lone.out + lone.err).contains("--fit goes with --audio"), "\(lone.out)\(lone.err)")
    #expect(try env.djq("photo", "help").out.contains("photo audio <id> --fit whole|fill"))
  }
}
