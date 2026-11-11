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
    #expect(whole(1085, 1920) == [1086, 1920, 1086, 1920], "within 1 % of 9:16: the same as Fill the frame (even pixels)")
    for (w, h) in [(4000, 3000), (3000, 3000), (2000, 2500), (1000, 4000), (400, 300), (6000, 900), (233, 977)] {
      let l = StillVideo.layout(width: w, height: h, fit: .whole)
      #expect(l.frame.width * 16 == l.frame.height * 9, "\(w)×\(h): exactly 9:16")
      #expect(l.frame.width % 2 == 0 && l.frame.height % 2 == 0 && l.photo.width % 2 == 0 && l.photo.height % 2 == 0)
      #expect(l.photo.width <= l.frame.width && l.photo.height <= l.frame.height && l.photo.width <= w + 1 && l.photo.height <= h + 1)
      #expect(l.frame.width <= 2160 && !l.fills)
      // Fill the frame is the photo's own shape, as before.
      let fill = StillVideo.layout(width: w, height: h, fit: .fill)
      let own = StillVideo.frameSize(width: w, height: h)
      #expect(fill.fills && fill.frame.width == own.width && fill.frame.height == own.height)
    }
  }

  /// Both fits for wide, square, 4:5, 9:16 and very tall photos. Whole: the frame is 9:16, the photo's own colours are
  /// at its middle (tolerance 12 of 255: JPEG sources), and the corners outside it are its blurred, darkened copy.
  @Test func bothFitsForEveryShape() throws {
    let f = try Fixture(clips: [], longform: false)
    let maker = StillVideo(store: f.store)
    let tone = f.tone(seconds: 1.2)
    let red = shade(.red), blue = shade(.blue)
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
      let (x0, y0) = ((fw - pw) / 2, (fh - ph) / 2)
      // The photo, whole: red at the middle of its left half, blue at the middle of its right half, right up to its edges.
      #expect(frame[x0 + pw / 4, fh / 2].near(red, 12) && frame[x0 + pw * 3 / 4, fh / 2].near(blue, 12), "\(name): \(frame[x0 + pw / 4, fh / 2])")
      #expect(frame[x0 + 6, y0 + 6].near(red, 12) && frame[x0 + pw - 7, y0 + ph - 7].near(blue, 12), "\(name): the photo's own corners")
      if !layout.fills {
        // Outside the photo: its blurred, darkened copy. Not black, not the photo's full colour.
        let corners = [frame[4, 4], frame[fw - 5, 4], frame[4, fh - 5], frame[fw - 5, fh - 5]]
        for c in corners {
          #expect(c.r + c.g + c.b > 60, "\(name): a corner is black: \(c)")
          #expect(c.r < red.r - 40 && c.b < blue.b - 40, "\(name): a corner is as bright as the photo: \(c)")
        }
        #expect(corners[0].r > corners[0].b && corners[1].b > corners[1].r, "\(name): the copy has the photo's colours where the photo has them")
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

  @Test func aStillWithoutFitReadsAsFillAndIsStoredAsItWas() throws {
    let json = #"{"photo":{"id":"p1","file":"Originals/x/01-p1.jpg","width":4000,"height":3000},"audio":"Stills/x/audio.mp3","audioName":"Friday mix.mp3","audioDuration":181.5}"#
    let old = try JSONCoding.decoder.decode(StillSource.self, from: Data(json.utf8))
    #expect(old.fit == nil && old.fits == .fill && old.audioName == "Friday mix.mp3")
    #expect(!JSONCoding.string(old).contains("fit"), "a row made before D12 is written back without the key")
    var new = old
    new.fit = .whole
    #expect(JSONCoding.string(new).contains(#""fit":"whole""#))
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
    // Fill → Whole: the whole frame again, confirmed.
    _ = try maker.setFit(videoId: whole.id, fit: .fill)
    let again = try maker.setFit(videoId: whole.id, fit: .whole).video
    #expect(again.still?.fit == .whole && again.file.hasSuffix("video-4.mp4") && again.sourceWidth == whole.sourceWidth)
    #expect(try f.store.edit(videoId: again.id).crop == CropRect(x: 0, y: 0, w: Double(again.sourceWidth ?? 0), h: Double(again.sourceHeight ?? 0)))
    #expect(try Validation.issues(video: again, store: f.store).isEmpty)
    // Change audio keeps the fit; with a fit it changes both.
    let other = try maker.changeAudio(videoId: again.id, audio: f.tone("other.wav", seconds: 2)).video
    #expect(other.still?.fit == .whole && other.sourceWidth == whole.sourceWidth && other.still?.audio.hasSuffix("audio-5.m4a") == true)
    let both = try maker.changeAudio(videoId: again.id, audio: f.tone("third.wav", seconds: 2), fit: .fill).video
    #expect(both.still?.fit == .fill && both.sourceWidth == 1600)
    #expect(try f.store.edit(videoId: both.id).crop == nil)
    // No audio copy: it says what to do instead of failing halfway.
    try FileManager.default.removeItem(at: f.paths.photos.appendingPathComponent(try #require(both.still?.audio)))
    #expect(throws: EngineError.self) { try maker.setFit(videoId: both.id, fit: .whole) }
    do { _ = try maker.setFit(videoId: both.id, fit: .whole) } catch {
      #expect("\(error)" == "Its audio file is missing (third.wav): choose the audio again with Change audio")
    }
    #expect(f.stillLeftovers.isEmpty)
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
