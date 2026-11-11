import Foundation
import Testing
@testable import DJQCore

/// Round 23 (D1, D4, D5): `StillVideo.make` turns one photo and one audio file into a real video file. Real ffmpeg on
/// pictures and tones made here; off (and said so by the trait) on a Mac without ffmpeg.
@Suite(.enabled(if: Tone.haveTools, "ffmpeg and ffprobe aren't installed")) struct R23StillVideoTests {
  /// A test colour as CoreGraphics stores it in a picture (the fixture's colours go through the Mac's colour matching).
  func shade(_ c: PhotoImages.RGB) -> PhotoImages.RGB { PhotoImages.bitmap(PhotoImages.image(width: 2, height: 2, left: c, right: c))[0, 0] }

  @Test func frameSizeKeepsThePhotosShapeInsideA4KFrameAndNeverEnlarges() {
    func size(_ w: Int, _ h: Int) -> [Int] { let s = StillVideo.frameSize(width: w, height: h); return [s.width, s.height] }
    #expect(size(6000, 4000) == [3240, 2160], "wide: fitted into 3840×2160")
    #expect(size(8000, 2000) == [3840, 960])
    #expect(size(4000, 6000) == [2160, 3240], "tall: fitted into 2160×3840")
    #expect(size(1000, 4000) == [960, 3840])
    #expect(size(5000, 5000) == [2160, 2160], "square: the tall frame")
    #expect(size(3840, 2160) == [3840, 2160])
    #expect(size(400, 300) == [400, 300], "a small photo keeps its pixels")
    #expect(size(1201, 801) == [1202, 802] || size(1201, 801) == [1200, 800], "even, a pixel off at most")
    #expect(size(1201, 801).allSatisfy { $0 % 2 == 0 })
  }

  @Test func makeWritesAVideoOfThePhotoForExactlyTheAudiosLength() throws {
    let f = try Fixture(clips: [], longform: false)
    let photo = f.pictures(["flyer.jpg"])[0], audio = f.tone(seconds: 3.2)
    let before = [try #require(PhotoImport.fingerprint(photo)), try #require(PhotoImport.fingerprint(audio))]
    let seen = Seen()
    let made = try StillVideo(store: f.store).make(photo: photo, audio: audio, videoId: "post-1", fit: .fill) { seen.add($0) }
    // Where it is: DJ Queue's Photos folder, with its own copy of the audio beside it, and nothing else.
    let dir = f.paths.photos.appendingPathComponent("Stills/post-1")
    #expect(made.video.path == dir.appendingPathComponent("video.mp4").path && made.audio.path == dir.appendingPathComponent("audio.m4a").path)
    #expect(f.stillFiles("post-1") == ["audio.m4a", "video.mp4"] && f.stillLeftovers.isEmpty)
    // The copy is the AAC the video holds (not the picked file): sound only, as long as the video.
    #expect(Tone.probe(made.audio, stream: "a:0", "codec_name,sample_rate,channels") == ["aac", "48000", "2"])
    let copy = try Data(contentsOf: made.audio), picked = try Data(contentsOf: audio)
    #expect(Tone.probe(made.audio, stream: "v:0", "codec_name").isEmpty && copy != picked)
    // What it is: H.264 at the photo's size, 30 fps, AAC 48 kHz stereo, as long as the audio.
    let info = try Media.probe(made.video)
    #expect(info.videoCodec == "h264" && info.width == 400 && info.height == 300 && info.fps == 30)
    #expect(info.hasAudio && info.audioCodec == "aac")
    #expect(abs(info.duration - 3.2) <= 0.05 && abs(made.duration - 3.2) <= 0.05, "\(info.duration)")
    #expect(Tone.probe(made.video, stream: "v:0", "pix_fmt,color_range,color_space,color_transfer,color_primaries") == ["yuv420p", "tv", "bt709", "bt709", "bt709"])
    #expect(Tone.probe(made.video, stream: "a:0", "sample_rate,channels") == ["48000", "2"])
    #expect(Tone.probe(made.video, stream: "v:0", "nb_frames") == ["96"], "3.2 s at 30 fps")
    #expect(Int(Tone.probe(made.video, stream: "a:0", "bit_rate").first ?? "0") ?? 0 > 200_000, "AAC at 256 kbps")
    // The picked files were only read.
    #expect([try #require(PhotoImport.fingerprint(photo)), try #require(PhotoImport.fingerprint(audio))] == before)
    // Progress went up to the end.
    #expect(seen.values.last == 1 && seen.values == seen.values.sorted() && seen.values.count >= 4)
  }

  /// Colours: a decoded frame against the photo's own pixels. Tolerance: 6 of 255 per channel in the flat halves
  /// (measured 0 to 1: the keyframe is coded at quantiser 18 and the RGB to BT.709 conversion rounds).
  @Test func theVideosColoursAreThePhotos() throws {
    let f = try Fixture(clips: [], longform: false)
    let photo = f.inbox.appendingPathComponent("halves.png")
    PhotoImages.write(photo, width: 400, height: 300, left: .red, right: .blue, type: .png)
    let source = try #require(PhotoImages.bitmap(photo))
    let made = try StillVideo(store: f.store).make(photo: photo, audio: f.tone(seconds: 12), videoId: "c", fit: .fill)
    // At the start, in the middle of a keyframe interval, across one, and at the very end.
    for t in [0.0, 3.3, 7.4, 11.9] {
      let frame = try #require(Tone.frame(made.video, at: t, in: f.dir), "frame at \(t)")
      #expect(frame.width == 400 && frame.height == 300)
      for (x, y) in [(100, 150), (30, 20), (300, 150), (380, 280)] {
        #expect(frame[x, y].near(source[x, y], 6), "at \(t) s, pixel \(x),\(y): \(frame[x, y]) for \(source[x, y])")
      }
      #expect(frame[100, 150].near(shade(.red), 6) && frame[300, 150].near(shade(.blue), 6), "\(frame[100, 150]) \(frame[300, 150])")
      #expect(frame.difference(source) < 400 * 300 / 50, "only the seam between the halves may differ: \(frame.difference(source)) pixels")
    }
  }

  @Test func aTurnedPhotoIsUprightAndEveryShapeKeepsItsOwn() throws {
    let f = try Fixture(clips: [], longform: false)
    let maker = StillVideo(store: f.store)
    let tone = f.tone(seconds: 1.5)
    // EXIF orientation 6: stored 400×300 with red on the left, seen upright as 300×400 with red on top.
    let turned = f.inbox.appendingPathComponent("turned.jpg")
    PhotoImages.write(turned, width: 400, height: 300, left: .red, right: .blue, orientation: 6)
    let a = try maker.make(photo: turned, audio: tone, videoId: "turned", fit: .fill)
    #expect(a.width == 300 && a.height == 400)
    let frame = try #require(Tone.frame(a.video, at: 0.5, in: f.dir))
    #expect(frame.width == 300 && frame.height == 400)
    #expect(frame[150, 60].near(shade(.red), 12) && frame[150, 340].near(shade(.blue), 12), "\(frame[150, 60]) \(frame[150, 340])")
    // A wide, a tall and a square photo larger than the frame: fitted, even, their own shape.
    for (name, w, h, want) in [("wide", 4800, 2400, [3840, 1920]), ("tall", 2400, 4800, [1920, 3840]), ("square", 2600, 2600, [2160, 2160])] {
      let photo = f.inbox.appendingPathComponent("\(name).jpg")
      PhotoImages.write(photo, width: w, height: h, left: .green, right: .yellow)
      let m = try maker.make(photo: photo, audio: tone, videoId: name, fit: .fill)
      let info = try Media.probe(m.video)
      #expect(info.width == want[0] && info.height == want[1] && m.width == want[0] && m.height == want[1], "\(name): \(info.width)×\(info.height)")
      let fr = try #require(Tone.frame(m.video, at: 1, in: f.dir))
      #expect(fr[want[0] / 4, want[1] / 2].near(shade(.green), 12) && fr[want[0] * 3 / 4, want[1] / 2].near(shade(.yellow), 12),
              "\(name) \(fr[want[0] / 4, want[1] / 2]) \(fr[want[0] * 3 / 4, want[1] / 2])")
    }
    #expect(f.stillLeftovers.isEmpty)
  }

  @Test func theSoundOfAVideoFileAndOtherFormatsAreTaken() throws {
    let f = try Fixture(clips: [], longform: false)
    let photo = f.pictures(["p.jpg"])[0]
    let wav = f.tone(seconds: 2)
    let ffmpeg = try #require(Tools.ffmpeg)
    for (name, args) in [("set.mp4", ["-f", "lavfi", "-i", "color=c=gray:size=64x64:rate=30:duration=2", "-i", wav.path, "-shortest", "-pix_fmt", "yuv420p"]),
                         ("track.m4a", ["-i", wav.path, "-c:a", "aac"]), ("track.aiff", ["-i", wav.path]), ("track.flac", ["-i", wav.path]),
                         ("track.caf", ["-i", wav.path])] {
      let src = f.inbox.appendingPathComponent(name)
      let r = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y"] + args + [src.path], timeout: 60)
      try #require(r.status == 0, "\(name): \(r.stderrTail)")
      let made = try StillVideo(store: f.store).make(photo: photo, audio: src, videoId: name, fit: .fill)
      let info = try Media.probe(made.video)
      #expect(info.hasAudio && abs(info.duration - 2) <= 0.06 && info.width == 400, "\(name): \(info.duration)")
      // Whatever was picked, DJ Queue keeps the sound only: a video file's picture is never copied.
      #expect(made.audio.lastPathComponent == "audio.m4a" && Tone.probe(made.audio, stream: "v:0", "codec_name").isEmpty)
      #expect(Tone.probe(made.audio, stream: "a:0", "codec_name") == ["aac"])
      let bytes = (try FileManager.default.attributesOfItem(atPath: made.audio.path)[.size] as? Int) ?? 0
      #expect(bytes > 0 && bytes < 200_000, "2 s of AAC, not the picked file: \(bytes)")
    }
  }

  @Test func everyRefusalSaysWhyAndLeavesNothing() throws {
    let f = try Fixture(clips: [], longform: false)
    let photo = f.pictures(["p.jpg"])[0]
    let maker = StillVideo(store: f.store)
    func refused(_ audio: URL, photo p: URL? = nil, _ maker: StillVideo? = nil) -> String {
      do {
        _ = try (maker ?? StillVideo(store: f.store)).make(photo: p ?? photo, audio: audio, videoId: "no")
        return "made"
      } catch { return "\(error)" }
    }
    // Not there, a folder, not a format DJ Queue takes.
    #expect(refused(f.inbox.appendingPathComponent("gone.mp3")) == "the audio file isn't there")
    #expect(refused(f.inbox) == "it's a folder")
    let notes = f.inbox.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: notes)
    #expect(refused(notes).hasPrefix("not an audio format DJ Queue takes"))
    // Unreadable: text with an audio name.
    let fake = f.inbox.appendingPathComponent("fake.mp3")
    try Data("this is not audio".utf8).write(to: fake)
    #expect(refused(fake) == "fake.mp3 can't be read as audio")
    // No audio stream.
    let silent = f.inbox.appendingPathComponent("silent.mp4")
    try #require(Tone.silentVideo(silent))
    #expect(refused(silent) == "silent.mp4 has no sound in it")
    // Too long (20:01) and too short (half a second); 20:00 itself is taken.
    let long = Tone.wav(f.inbox.appendingPathComponent("long.wav"), seconds: 1201, rate: 8000, bits: 8)
    #expect(refused(long) == "long.wav is 20:01 long: the audio can be up to 20 minutes")
    #expect(refused(Tone.wav(f.inbox.appendingPathComponent("blip.wav"), seconds: 0.5)) == "blip.wav is under a second long")
    #expect(try StillVideo.audioSeconds(Tone.wav(f.inbox.appendingPathComponent("max.wav"), seconds: 1200, rate: 8000, bits: 8)) == 1200)
    #expect(try StillVideo.audioSeconds(f.tone("one.wav", seconds: 1)) == 1)
    // No ffmpeg.
    let bare = StillVideo(store: f.store)
    bare.ffmpeg = nil
    #expect(refused(f.tone(), bare) == "ffmpeg isn't installed, so DJ Queue can't make the video (brew install ffmpeg)")
    let blind = StillVideo(store: f.store)
    blind.ffprobe = nil
    #expect(refused(f.tone(), blind) == StillVideo.noFFmpeg)
    // A photo that can't be read.
    let broken = f.inbox.appendingPathComponent("broken.jpg")
    try Data("not a picture".utf8).write(to: broken)
    #expect(refused(f.tone(), photo: broken) == "broken.jpg can't be read as a photo")
    // A photo too small to be a video (under 200 px on its short side).
    let tiny = f.inbox.appendingPathComponent("tiny.png")
    PhotoImages.write(tiny, width: 3, height: 5, type: .png)
    #expect(refused(f.tone(), photo: tiny) == "tiny.png is too small for a video: its short side is under 200 px")
    let thin = f.inbox.appendingPathComponent("thin.jpg")
    PhotoImages.write(thin, width: 1200, height: 199)
    #expect(refused(f.tone(), photo: thin).hasSuffix("its short side is under 200 px"))
    #expect(StillVideo.sizeRefusal(width: 200, height: 4000, name: "x") == nil)
    // Nothing was written anywhere.
    #expect(!FileManager.default.fileExists(atPath: f.paths.photos.appendingPathComponent("Stills").path) || f.stillFiles("no").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.paths.photos.appendingPathComponent("Stills/no").path))
    #expect(f.stillLeftovers.isEmpty)
    _ = maker
  }

  @Test func aRunThatFailsAtTheLastStepLeavesNothingHalfMade() throws {
    let f = try Fixture(clips: [], longform: false)
    let photo = f.pictures(["p.jpg"])[0], audio = f.tone()
    let maker = StillVideo(store: f.store)
    struct Boom: Error {}
    maker.placeHook = { throw Boom() }
    #expect(throws: Boom.self) { try maker.make(photo: photo, audio: audio, videoId: "x") }
    #expect(!FileManager.default.fileExists(atPath: f.paths.photos.appendingPathComponent("Stills/x").path) && f.stillLeftovers.isEmpty)
    // A second make beside a first one that worked leaves the first exactly as it was.
    maker.placeHook = nil
    let first = try maker.make(photo: photo, audio: audio, videoId: "x")
    let bytes = try Data(contentsOf: first.video)
    maker.placeHook = { throw Boom() }
    #expect(throws: Boom.self) { try maker.make(photo: photo, audio: audio, videoId: "x") }
    let after = try Data(contentsOf: first.video)
    #expect(f.stillFiles("x") == ["audio.m4a", "video.mp4"] && after == bytes && f.stillLeftovers.isEmpty)
    // And one that works takes the next names: a file is never written over.
    maker.placeHook = nil
    let second = try maker.make(photo: photo, audio: f.tone("other.wav", seconds: 2), videoId: "x")
    #expect(second.video.lastPathComponent == "video-2.mp4" && second.audio.lastPathComponent == "audio-2.m4a")
    let still = try Data(contentsOf: first.video)
    #expect(f.stillFiles("x") == ["audio-2.m4a", "audio.m4a", "video-2.mp4", "video.mp4"] && still == bytes)
    // A folder another make is using is never taken away by one that fails (only a folder it made and left empty).
    let other = f.paths.photos.appendingPathComponent("Stills/y")
    maker.placeHook = {
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      try Data("theirs".utf8).write(to: other.appendingPathComponent("video.mp4"))
      throw Boom()
    }
    #expect(throws: Boom.self) { try maker.make(photo: photo, audio: audio, videoId: "y") }
    #expect(f.stillFiles("y") == ["video.mp4"], "the other make's file is still there")
    // Leftovers of a make that was cut short are swept once they are a day old, and nothing else is.
    maker.placeHook = nil
    let fm = FileManager.default
    let oldWork = f.paths.work.appendingPathComponent("still-old"), newWork = f.paths.work.appendingPathComponent("still-new")
    let oldTemp = f.paths.photos.appendingPathComponent("Stills/x/.old.mp4"), newTemp = f.paths.photos.appendingPathComponent("Stills/x/.new.mp4")
    for d in [oldWork, newWork] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    for u in [oldTemp, newTemp] { try Data("t".utf8).write(to: u) }
    let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
    for u in [oldWork, oldTemp] { try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: u.path) }
    maker.sweepLeftovers()
    #expect(!fm.fileExists(atPath: oldWork.path) && !fm.fileExists(atPath: oldTemp.path))
    #expect(fm.fileExists(atPath: newWork.path) && fm.fileExists(atPath: newTemp.path))
    #expect(f.stillFiles("x").filter { !$0.hasPrefix(".") } == ["audio-2.m4a", "audio.m4a", "video-2.mp4", "video.mp4"])
  }

  /// The budget: three minutes of audio on a 4K photo in under 30 seconds (measured 3 s on this Mac; 20 minutes takes
  /// 13 s, most of it reading the audio).
  @Test(.timeLimit(.minutes(2))) func threeMinutesOn4KTakesSeconds() throws {
    let f = try Fixture(clips: [], longform: false)
    let photo = f.inbox.appendingPathComponent("big.jpg")
    PhotoImages.write(photo, width: 3840, height: 2160, left: .grey, right: .green)
    let audio = f.tone("three.wav", seconds: 180)
    let started = Date()
    let made = try StillVideo(store: f.store).make(photo: photo, audio: audio, videoId: "big", fit: .fill)
    let took = Date().timeIntervalSince(started)
    let info = try Media.probe(made.video)
    #expect(took < 30, "took \(took) s")
    #expect(abs(info.duration - 180) <= 0.05 && info.width == 3840 && info.height == 2160 && info.hasAudio)
    #expect(Tone.probe(made.video, stream: "v:0", "nb_frames") == ["5400"])
    // Seeking lands on the picture anywhere, mid-interval included.
    let frame = try #require(Tone.frame(made.video, at: 133.7, in: f.dir))
    #expect(frame[900, 1000].near(shade(.grey), 12) && frame[2900, 1000].near(shade(.green), 12), "\(frame[900, 1000]) \(frame[2900, 1000])")
  }
}

/// Collects progress values from another thread.
final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var all: [Double] = []
  func add(_ v: Double) { lock.withLock { all.append(v) } }
  var values: [Double] { lock.withLock { all } }
}
