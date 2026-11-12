import CoreGraphics
import Foundation
import ImageIO

/// Photo with audio (round 23, DECISIONS-R23.md). One photo and an audio file become a real video file once, and the
/// item is then an ordinary clip: `Video.still` says what it was made from, `photos` is nil, `file` is the made video.
///
/// Files live in the Photos folder: `Stills/<video id>/video.mp4` and DJ Queue's own copy of the audio,
/// `Stills/<video id>/audio.m4a` (the AAC the video holds: the picked file is never copied, so the sound of a video
/// costs no more than a song). A later Change audio writes `video-2.mp4` / `audio-2.m4a` beside them and a fit change
/// `video-3.mp4`, so the undo of a change only has to point the row back at files that are still there. A fit change
/// back goes to the video already made from this audio (`StillSource.other`): two videos per audio, however often the
/// fit flips. The files Eric picked are only read.
///
/// D12: the photo sits in the video one of two ways (`StillSource.Fit`). `whole` (the default) makes a 9:16 video with
/// the whole photo centred over a blurred, darkened copy of itself; its crop is the whole frame. `fill` makes the video
/// at the photo's own shape and Eric picks the 9:16 crop.
///
/// A made video differs from a clip in four ways, and nowhere else: it needs no score (`Video.needsNoScore`), it starts
/// with no text and `{set}`/`{tag}` are empty, cards mark it "Photo + audio", and a YouTube post needs a title.
public final class StillVideo: @unchecked Sendable {
  // MARK: Words and rules

  /// What a card and the editor say where a clip says "DJ vid" or "Talking" (D8).
  public static let label = "Photo + audio"
  /// What the photo editor's Audio row says under "Add audio…".
  public static let addHint = "Turns this photo into a video"
  /// Why a carousel can't take audio (D3).
  public static let carouselReason = "Audio goes on a post with one photo"
  /// Why audio can't be added, changed or removed once the item has a day or posted (D9).
  public static let lockedReason = "Send it back to Edit first"
  /// Why Back from Edit doesn't apply (D6).
  public static let noScoreStage = "A photo with audio has no Score stage"
  /// What an undo says for an item it leaves alone because the restore would change what the item is under a day or
  /// a post (`BulkActions.stillUndoLock`), and whether a skip's reason is that one.
  public static let undoLockReason = "It's scheduled or posted now: send it back to Edit first"
  public static func isUndoLock(_ reason: String) -> Bool { reason == undoLockReason }
  /// Why bulk crop leaves it alone: its picture is a photo of any shape, so one framing can't fit a selection.
  public static let bulkCropReason = "a photo with audio is cropped in the editor"
  /// The issue for a YouTube post with nothing to name it (D10).
  public static let youtubeTitleIssue = "Add a title: YouTube needs a name for this video"
  /// D12: what the fit control says under itself.
  public static func fitHint(_ fit: StillSource.Fit) -> String {
    fit == .whole ? "The whole photo, over a blurred copy of itself" : "The photo fills the frame. You pick the crop"
  }

  /// Longest and shortest audio a video is made from (D4).
  public static let maxAudioSeconds: Double = 20 * 60
  public static let minAudioSeconds: Double = 1

  /// File extensions the audio picker takes (lowercased): audio files, and the sound of a video file.
  public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "mp4", "mov", "m4v"]

  /// The made video: 30 fps H.264 (D5), one keyframe every `keyframeSeconds`.
  public static let fps = 30
  /// A still needs one real picture per keyframe and nothing between them, so the gap sets both the file's size and
  /// how far a seek has to decode. Five seconds keeps a 3-minute 4K video near 25 MB (audio included) and an exact frame under half a second.
  public static let keyframeSeconds = 5
  /// The frame a photo is fitted into: 3840×2160 for a wide photo, 2160×3840 for a tall or square one. Never enlarged.
  public static let longSide = 3840, shortSide = 2160
  /// The smallest photo a video is made from, on its short side: under it the picture is a smudge at 1080 wide.
  public static let minPhotoSide = 200

  /// Journal actions, for `djq bulk undo` and the app's ⌘Z.
  public static let addAction = "photo-audio-add", changeAction = "photo-audio-change", removeAction = "photo-audio-remove"
  public static let fitAction = "photo-audio-fit"
  /// `action` is one of the four above.
  public static func isAudioAction(_ action: String) -> Bool { [addAction, changeAction, removeAction, fitAction].contains(action) }

  /// Why a photo of this size can't be a video (nil = it can).
  public static func sizeRefusal(width: Int, height: Int, name: String) -> String? {
    min(width, height) < minPhotoSide ? "\(name) is too small for a video: its short side is under \(minPhotoSide) px" : nil
  }

  /// Where the photo goes in the made video. `frame` is the video's pixel size; `photo` is the photo's size inside it
  /// (the same as the frame when it fills it).
  public struct Layout: Sendable, Equatable {
    public var frame: (width: Int, height: Int)
    public var photo: (width: Int, height: Int)
    /// The photo covers the whole frame: no background is drawn.
    public var fills: Bool { frame.width == photo.width && frame.height == photo.height }
    /// Where the photo's top left corner goes: centred, on an even pixel. A 4:2:0 file keeps one colour sample for
    /// two rows, so a photo that started on an odd row would tint the background row next to it.
    public var offset: (x: Int, y: Int) { ((frame.width - photo.width) / 4 * 2, (frame.height - photo.height) / 4 * 2) }
    public static func == (a: Layout, b: Layout) -> Bool {
      a.frame.width == b.frame.width && a.frame.height == b.frame.height && a.photo.width == b.photo.width && a.photo.height == b.photo.height
    }
  }

  /// D12. `fill`: the frame is the photo's own shape (`frameSize`). `whole`: a frame that is exactly 9:16 (so its
  /// whole-frame crop always renders), 2160×3840 or smaller so the photo is never enlarged, with the photo fitted
  /// inside. A photo that is 9:16 already, or within `nearNineSixteen` of it once fitted, covers the frame: no
  /// background, and at most half a percent of stretch, which is less than the renderer allows a crop.
  public static func layout(width: Int, height: Int, fit: StillSource.Fit) -> Layout {
    let own = frameSize(width: width, height: height)
    guard fit == .whole else { return Layout(frame: own, photo: own) }
    // The widest 9:16 frame that doesn't enlarge the photo. A multiple of 18 wide is exactly 9:16 with even sides.
    let widest = min(Double(shortSide), max(Double(width), Double(height) * 9 / 16))
    let w = max(36, Int(widest / 18) * 18), h = w / 9 * 16
    let k = min(Double(w) / Double(width), Double(h) / Double(height))
    func even(_ v: Double, _ most: Int) -> Int { min(most, max(2, Int((v / 2).rounded()) * 2)) }
    let near = Double(width) * k >= Double(w) * (1 - nearNineSixteen) && Double(height) * k >= Double(h) * (1 - nearNineSixteen)
    return Layout(frame: (w, h), photo: near ? (w, h) : (even(Double(width) * k, w), even(Double(height) * k, h)))
  }

  /// How far from the 9:16 frame a fitted photo may be and still cover it (review round 2, S2). The renderer takes a
  /// crop within 1 % of its shape (`Media.cropProblem`); this is inside that.
  public static let nearNineSixteen = 0.005

  /// The made video's pixel size for an upright photo of `width`×`height`: its own shape, fitted into the frame, even.
  public static func frameSize(width: Int, height: Int) -> (width: Int, height: Int) {
    let wide = width > height
    let boxW = Double(wide ? longSide : shortSide), boxH = Double(wide ? shortSide : longSide)
    let k = min(1, boxW / Double(max(1, width)), boxH / Double(max(1, height)))
    func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
    return (even(Double(width) * k), even(Double(height) * k))
  }

  // MARK: Results

  /// What `addAudio`, `changeAudio` and `removeAudio` did.
  public struct Change: Sendable {
    /// The item afterwards.
    public var video: Video
    /// The journal entry (nil: not journaled).
    public var batchId: String?
  }

  /// What `add(photos:audio:)` made.
  public struct AddResult: Sendable {
    /// The made videos, in the order of the photos.
    public var videos: [Video]
    public var skipped: [PhotoImport.Skipped]
    /// The picked photos nothing was made from because adding them failed (also in `skipped`, with the reason): the
    /// ones worth trying again. A photo that was refused, or added as a photo post, isn't one.
    public var failed: [URL] = []
  }

  /// A made video and DJ Queue's copy of its audio, in place.
  public struct Made: Sendable {
    public var video: URL
    public var audio: URL
    public var duration: Double
    public var width: Int
    public var height: Int
  }

  /// An audio file read once and ready to go under any number of photos (AAC 256 kbps, 48 kHz, stereo).
  final class Prepared {
    /// The picked file's name.
    let name: String
    let encoded: URL
    let duration: Double
    /// The work folder that holds `encoded`, removed with this. nil: `encoded` is an item's own audio copy, already in
    /// place (a fit change), which stays.
    let folder: URL?
    /// A prepared audio this one reads from, kept alive with it.
    let keeping: Prepared?
    init(name: String, encoded: URL, duration: Double, folder: URL?, keeping: Prepared? = nil) {
      self.name = name; self.encoded = encoded; self.duration = duration; self.folder = folder; self.keeping = keeping
    }
    deinit { if let folder { try? FileManager.default.removeItem(at: folder) } }
  }

  let store: Store
  let fm = FileManager.default
  /// Test seams: the tools (nil = not installed), and a step that can fail just before the files are moved into place.
  var ffmpeg: String? = Tools.ffmpeg
  var ffprobe: String? = Tools.ffprobe
  var placeHook: (() throws -> Void)?

  public init(store: Store) { self.store = store }

  // MARK: Audio

  /// Why a file can't be the audio, before anything is read (nil = it may be): gone, a folder, or not a format DJ Queue takes.
  public static func refusal(audio url: URL) -> String? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "the audio file isn't there" }
    if isDir.boolValue { return "it's a folder" }
    guard audioExtensions.contains(url.pathExtension.lowercased()) else {
      return "not an audio format DJ Queue takes (MP3, M4A, WAV, AIFF, FLAC, CAF, or the sound of an MP4 or MOV)"
    }
    return nil
  }

  /// The length of a file's first audio stream, in seconds, as its header says. Throws the reason it can't be used:
  /// no ffmpeg, unreadable, no sound, too long or too short.
  public static func audioSeconds(_ url: URL) throws -> Double { try audioSeconds(url, ffmpeg: Tools.ffmpeg, ffprobe: Tools.ffprobe) }

  static func audioSeconds(_ url: URL, ffmpeg: String?, ffprobe: String?) throws -> Double {
    if let why = refusal(audio: url) { throw EngineError(why) }
    guard ffmpeg != nil, let ffprobe else { throw EngineError(noFFmpeg) }
    let r = try Proc.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-select_streams", "a:0",
                                   url.path], timeout: 60)
    guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else {
      throw EngineError("\(url.lastPathComponent) can't be read as audio")
    }
    guard let stream = (obj["streams"] as? [[String: Any]])?.first else { throw EngineError("\(url.lastPathComponent) has no sound in it") }
    func num(_ any: Any?) -> Double? { (any as? Double) ?? (any as? String).flatMap(Double.init) }
    guard let d = num((obj["format"] as? [String: Any])?["duration"]) ?? num(stream["duration"]), d.isFinite, d > 0 else {
      throw EngineError("\(url.lastPathComponent) can't be read as audio")
    }
    try checkLength(d, url)
    return d
  }

  static let noFFmpeg = "ffmpeg isn't installed, so DJ Queue can't make the video (brew install ffmpeg)"

  static func checkLength(_ d: Double, _ url: URL) throws {
    // Half a second of grace: a "20:00" track is rarely exactly 1,200 seconds.
    if d > maxAudioSeconds + 0.5 {
      throw EngineError("\(url.lastPathComponent) is \(Validation.fmt(d)) long: the audio can be up to \(Int(maxAudioSeconds / 60)) minutes")
    }
    if d < minAudioSeconds { throw EngineError("\(url.lastPathComponent) is under a second long") }
  }

  /// Reads the audio once: encodes its first audio stream to AAC in the work folder and measures what came out, which
  /// is the video's exact length (a header's length can be an estimate). `progress` runs 0…1.
  func prepare(_ audio: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> Prepared {
    let estimate = try Self.audioSeconds(audio, ffmpeg: ffmpeg, ffprobe: ffprobe)
    guard let ffmpeg else { throw EngineError(Self.noFFmpeg) }
    let folder = store.paths.work.appendingPathComponent("still-\(UUID().uuidString)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let out = folder.appendingPathComponent("audio.m4a")
    do {
      let r = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-i", audio.resolvingSymlinksInPath().path, "-map", "0:a:0", "-vn", "-sn", "-dn",
                                    "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-map_metadata", "-1",
                                    "-progress", "pipe:1", out.path], timeout: max(120, estimate)) { line in
        guard let progress, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
              let us = Double(line.split(separator: "=").last ?? "") else { return }
        progress(min(1, max(0, us / 1_000_000 / estimate)))
      }
      guard r.status == 0, fm.fileExists(atPath: out.path) else {
        throw EngineError("\(audio.lastPathComponent) can't be read as audio: \(Self.words(r, [audio.resolvingSymlinksInPath(), audio, out]))")
      }
      let d = try encodedSeconds(out)
      try Self.checkLength(d, audio)
      progress?(1)
      return Prepared(name: audio.lastPathComponent, encoded: out, duration: d, folder: folder)
    } catch {
      try? fm.removeItem(at: folder)
      throw error
    }
  }

  /// What a tool said when it stopped, for an error Eric reads: its last lines with the folders taken off every path
  /// (`files` are the ones it was given; a name says which file, and where it is kept belongs in no toast or log).
  static func words(_ r: Proc.Result, _ files: [URL] = []) -> String {
    var text = r.stderrTail
    for f in files.sorted(by: { $0.path.count > $1.path.count }) { text = text.replacingOccurrences(of: f.path, with: f.lastPathComponent) }
    return text.replacingOccurrences(of: #"(?<![\w.~])~?/(?:[^/\s'":|]+/)+"#, with: "", options: .regularExpression)
  }

  private func encodedSeconds(_ url: URL) throws -> Double {
    guard let ffprobe else { throw EngineError(Self.noFFmpeg) }
    let r = try Proc.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path], timeout: 60)
    guard r.status == 0, let d = Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 else {
      throw EngineError("the audio came out unreadable: \(Self.words(r, [url]))")
    }
    return d
  }

  // MARK: Making the file

  /// Makes `Stills/<video id>/video.mp4` (the photo held for exactly the audio's length) and DJ Queue's copy of the
  /// audio beside it (`audio.m4a`, the AAC the video holds). Blocking; call it off the main thread. Both picked files
  /// are only read. Everything is written under a temporary name and moved into place at the end, so a run that fails
  /// leaves nothing behind.
  @discardableResult
  public func make(photo: URL, audio: URL, videoId: String, fit: StillSource.Fit = .whole,
                   progress: (@Sendable (Double) -> Void)? = nil) throws -> Made {
    let prepared = try prepare(audio) { p in progress?(p * 0.8) }
    return try make(photo: photo, prepared: prepared, videoId: videoId, fit: fit) { p in progress?(0.8 + p * 0.2) }
  }

  /// The picture half: a few seconds of the photo encoded once, repeated under the prepared audio without encoding
  /// again, so twenty minutes take as long as twenty seconds.
  func make(photo: URL, prepared: Prepared, videoId: String, fit: StillSource.Fit, progress: (@Sendable (Double) -> Void)? = nil) throws -> Made {
    guard let ffmpeg else { throw EngineError(Self.noFFmpeg) }
    guard fm.fileExists(atPath: photo.path), let size = PhotoRenderer.pixelSize(of: photo) else {
      throw EngineError("\(photo.lastPathComponent) can't be read as a photo")
    }
    if let why = Self.sizeRefusal(width: size.width, height: size.height, name: photo.lastPathComponent) { throw EngineError(why) }
    let layout = Self.layout(width: size.width, height: size.height, fit: fit)
    let frame = layout.frame
    let d = prepared.duration
    let work = store.paths.work.appendingPathComponent("still-\(UUID().uuidString)")
    let dir = stillsDir(videoId)
    let hadDir = fm.fileExists(atPath: dir.path)
    let names = nextNames(videoId)
    // An item's own audio copy is already in place (a fit change): only the video is new.
    let audioInPlace = prepared.folder == nil
    let tmpVideo = dir.appendingPathComponent(".\(UUID().uuidString).mp4"), tmpAudio = dir.appendingPathComponent(".\(UUID().uuidString).m4a")
    var placed: [URL] = []
    do {
      try fm.createDirectory(at: work, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: work) }
      // 1. The photo upright, at its size in the frame, as plain sRGB pixels.
      let png = work.appendingPathComponent("photo.png")
      try Self.writeFrame(photo, width: layout.photo.width, height: layout.photo.height, to: png)
      progress?(0.2)
      // 2. One keyframe interval of it: a picture and then frames that say "the same again".
      let n = min(Self.fps * Self.keyframeSeconds, max(1, Int((d * Double(Self.fps)).rounded(.up))))
      let seg = work.appendingPathComponent("segment.mp4")
      let colour = ["-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]
      // D12, the whole photo: behind it, the same photo enlarged to cover the frame, blurred and darkened by a third
      // (drawn once, before the frame is repeated), so there are no black bars. The blur follows the frame's size.
      let sigma = String(format: "%.1f", 40 * Double(frame.width) / Double(Self.shortSide))
      let picture = layout.fills ? "[0:v]"
        : "[0:v]format=gbrp,split[a][b];[a]scale=\(frame.width):\(frame.height):force_original_aspect_ratio=increase:flags=bicubic,"
          + "crop=\(frame.width):\(frame.height),gblur=sigma=\(sigma),colorchannelmixer=rr=0.65:gg=0.65:bb=0.65[bg];"
          + "[bg][b]overlay=\(layout.offset.x):\(layout.offset.y):format=gbrp,"
      // (A PNG says sRGB; the file says BT.709, as every clip does.)
      let graph = picture + "loop=loop=\(n - 1):size=1:start=0,scale=in_range=pc:out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1,"
        + "setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]"
      func segment(_ codec: [String]) throws -> Proc.Result {
        try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-framerate", String(Self.fps), "-i", png.path,
                              "-filter_complex", graph, "-map", "[v]", "-frames:v", String(n)] + codec + ["-g", String(n), "-bf", "0"] + colour
                              + ["-video_track_timescale", "30000", "-an", "-map_metadata", "-1", seg.path], timeout: 180)
      }
      // The keyframe at quantiser 18 (about 48 dB on a 4K photo); every frame after it at 38, which leaves nothing to
      // code, so each is a few hundred bytes of "skip". x264's own rate control spends as much again on those frames.
      var r = try segment(["-c:v", "libx264", "-preset", "veryfast", "-qp", "38", "-i_qfactor", "0.1", "-keyint_min", String(n),
                           "-sc_threshold", "0", "-profile:v", "high"])
      if r.status != 0 {  // an ffmpeg built without x264: the Mac's own encoder
        r = try segment(["-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "40000k", "-allow_sw", "1"])
      }
      guard r.status == 0, fm.fileExists(atPath: seg.path) else { throw EngineError("couldn't make the video: \(Self.words(r, [png, seg]))") }
      progress?(0.6)
      // 3. That interval again and again under the audio, copied, cut at the audio's end.
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let m = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-stream_loop", "-1", "-i", seg.path, "-i", prepared.encoded.path,
                                    "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-t", String(format: "%.6f", d),
                                    "-map_metadata", "-1", "-movflags", "+faststart", "-f", "mp4", tmpVideo.path], timeout: 300)
      guard m.status == 0, fm.fileExists(atPath: tmpVideo.path) else { throw EngineError("couldn't make the video: \(Self.words(m, [seg, prepared.encoded, tmpVideo]))") }
      guard let probe = try? Media.probe(tmpVideo) else { throw EngineError("the video came out unreadable") }
      var problems: [String] = []
      if probe.videoCodec != "h264" { problems.append("codec \(probe.videoCodec)") }
      if probe.width != frame.width || probe.height != frame.height { problems.append("size \(probe.width)×\(probe.height)") }
      if !probe.hasAudio { problems.append("no audio") }
      if abs(probe.duration - d) > 0.05 { problems.append(String(format: "length %.3f s, audio %.3f s", probe.duration, d)) }
      if abs(probe.fps - Double(Self.fps)) > 0.01 { problems.append(String(format: "%.2f fps", probe.fps)) }
      guard problems.isEmpty else { throw EngineError("the video came out wrong (\(problems.joined(separator: ", ")))") }
      progress?(0.9)
      // 4. DJ Queue's own copy of the audio: the AAC that is in the video (not the picked file, which may be a whole
      // video with its picture). Then both into place.
      try placeHook?()
      var audio = prepared.encoded
      if !audioInPlace {
        try fm.copyItem(at: prepared.encoded, to: tmpAudio)
        try fm.moveItem(at: tmpAudio, to: names.audio)
        placed.append(names.audio)
        audio = names.audio
      }
      try fm.moveItem(at: tmpVideo, to: names.video)
      placed.append(names.video)
      progress?(1)
      return Made(video: names.video, audio: audio, duration: probe.duration, width: frame.width, height: frame.height)
    } catch {
      for u in [tmpVideo, tmpAudio] + placed { try? fm.removeItem(at: u) }
      // Only a folder this run made and left empty: another process may have just put its own files in it.
      if !hadDir, ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: dir) }
      throw error
    }
  }

  /// The photo upright (EXIF orientation applied), scaled to `width`×`height`, on white where it is see-through (as a
  /// photo post draws it), written as an sRGB PNG.
  static func writeFrame(_ photo: URL, width: Int, height: Int, to url: URL) throws {
    guard let img = PhotoRenderer.load(photo, maxPixel: max(width, height) + 2),
          let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw EngineError("\(photo.lastPathComponent) can't be read as a photo")
    }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(rect)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: rect)
    guard let out = ctx.makeImage() else { throw EngineError("\(photo.lastPathComponent) can't be read as a photo") }
    try Media.writePNG(out, to: url)
  }

  /// A made video's preview proxy without decoding it: its first frame through `filter` (the proxy's crop and scale),
  /// encoded once as two seconds of video and repeated under the audio of `start`…`end`, copied. A second for any
  /// length, where decoding twenty minutes of 4K takes two minutes on every core. False = it didn't work, and the
  /// caller makes the proxy the way it does for any clip.
  static func proxy(ffmpeg: String, source: URL, filter: String, start: Double, end: Double, to out: URL, timeout: TimeInterval) -> Bool {
    let fm = FileManager.default
    let seg = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).seg.mp4")
    defer { try? fm.removeItem(at: seg) }
    let d = end - start
    let n = min(fps * 2, max(1, Int((d * Double(fps)).rounded(.up))))
    guard let a = try? Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-i", source.path,
                                         "-vf", "select=eq(n\\,0),\(filter),loop=loop=\(n - 1):size=1:start=0,setpts=N/(\(fps)*TB)",
                                         "-r", String(fps), "-frames:v", String(n), "-an", "-c:v", "libx264", "-preset", "veryfast",
                                         "-qp", "44", "-i_qfactor", "0.1", "-g", String(n), "-keyint_min", String(n), "-sc_threshold", "0",
                                         "-bf", "0", "-video_track_timescale", "30000", "-map_metadata", "-1", seg.path], timeout: timeout),
          a.status == 0, fm.fileExists(atPath: seg.path) else { return false }
    let len = String(format: "%.3f", d)
    guard let b = try? Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-stream_loop", "-1", "-i", seg.path,
                                         "-ss", String(format: "%.3f", start), "-t", len, "-i", source.path,
                                         "-map", "0:v:0", "-map", "1:a:0?", "-c", "copy", "-t", len, "-map_metadata", "-1",
                                         "-movflags", "+faststart", "-f", "mp4", out.path], timeout: timeout),
          b.status == 0, fm.fileExists(atPath: out.path) else {
      try? fm.removeItem(at: out)
      return false
    }
    return true
  }

  func stillsDir(_ videoId: String) -> URL { store.paths.photos.appendingPathComponent("Stills/\(videoId)") }

  static func relative(_ videoId: String, _ name: String) -> String { "Stills/\(videoId)/\(name)" }

  /// The next free pair of names in the item's folder: `video.mp4` and `audio.m4a` the first time, then `video-2.mp4`
  /// and `audio-2.m4a`. A name is never used twice, so a journal entry's files are still the ones it names.
  func nextNames(_ videoId: String) -> (video: URL, audio: URL) {
    let dir = stillsDir(videoId)
    let used = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { f -> Int? in
      let base = (f as NSString).deletingPathExtension
      guard base.hasPrefix("video") || base.hasPrefix("audio") else { return nil }
      let tail = base.dropFirst(5)
      return tail.isEmpty ? 1 : Int(tail.dropFirst())
    }
    let n = (used.max() ?? 0) + 1
    let suffix = n == 1 ? "" : "-\(n)"
    return (dir.appendingPathComponent("video\(suffix).mp4"), dir.appendingPathComponent("audio\(suffix).m4a"))
  }

  /// An item's own audio copy, ready to go under its photo again (a fit change): the AAC is copied into the new video,
  /// never encoded again. A copy from before the copy was the AAC (the picked file itself) is read like a picked file.
  func prepared(from still: StillSource) throws -> Prepared {
    let url = store.paths.photos.appendingPathComponent(still.audio)
    // Gone, damaged or unreadable: the same thing to Eric, and the same way out.
    let unusable = EngineError(Self.audioCopyUnusable(still.audioName))
    guard fm.fileExists(atPath: url.path) else { throw unusable }
    guard url.pathExtension.lowercased() == "m4a" else {
      guard let p = try? prepare(url) else { throw unusable }
      return Prepared(name: still.audioName, encoded: p.encoded, duration: p.duration, folder: nil, keeping: p)
    }
    guard let d = try? encodedSeconds(url), abs(d - still.audioDuration) <= 0.05 else { throw unusable }
    return Prepared(name: still.audioName, encoded: url, duration: d, folder: nil)
  }

  /// What a fit change says when DJ Queue's own copy of the audio is gone or can't be read.
  static func audioCopyUnusable(_ name: String) -> String { "Its audio file is missing or can't be read (\(name)): choose the audio again with Change audio" }

  // MARK: Add, change, remove

  /// Why audio can't be added to, changed on or removed from `v` right now (nil = it can). D3 and D9: one photo, and
  /// only while the item is in Edit with no day and no post.
  public func blocker(_ v: Video) throws -> String? {
    guard v.isPhoto || v.isStill else { return "\(v.displayName) isn't a photo post" }
    if v.isCarousel { return Self.carouselReason }
    if v.isPhoto, v.photoCount == 0 { return "Add a photo first" }
    if v.excluded { return "It's excluded: include it first" }
    if try store.db.one("SELECT 1 AS x FROM plan_slots WHERE video_id=?", [v.id]) != nil { return Self.lockedReason }
    if try store.db.one("SELECT 1 AS x FROM platform_posts WHERE video_id=?", [v.id]) != nil { return Self.lockedReason }
    if ClipStage.of(v) != .edit { return Self.lockedReason }
    return nil
  }

  /// Turns a photo post with one photo into a video with this audio, in place (D2): same id, title, caption, hashtag
  /// groups, texts and looks. Its per-photo crop, photo shape and forced YouTube skip go, and each text shows for the
  /// whole clip. `fit` (D12): `whole` shows the whole photo and its crop is the whole frame; `fill` has no confirmed
  /// crop. Blocking (it makes the file); nothing is sent to the Queue. One journal entry, so `djq bulk undo` and ⌘Z
  /// bring the photo post back exactly.
  @discardableResult
  public func addAudio(to videoId: String, audio: URL, fit: StillSource.Fit = .whole, journal: Bool = true,
                       progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    try checkAdd(videoId)  // before the audio is read: a refusal shouldn't take as long as the work
    let prepared = try prepare(audio) { p in progress?(p * 0.8) }
    return try addAudio(to: videoId, prepared: prepared, fit: fit, journal: journal) { p in progress?(0.8 + p * 0.2) }
  }

  /// The post `addAudio` would convert, or the reason it can't.
  @discardableResult
  private func checkAdd(_ videoId: String) throws -> (Video, PhotoItem) {
    let v = try item(videoId)
    guard v.isPhoto else { throw EngineError(v.isStill ? "\(v.displayName) already has audio" : "\(v.displayName) isn't a photo post") }
    if let why = try blocker(v) { throw EngineError(why) }
    guard let photo = v.photos?.first else { throw EngineError("Add a photo first") }
    if let why = Self.sizeRefusal(width: photo.width, height: photo.height, name: v.displayName) { throw EngineError(why) }
    return (v, photo)
  }

  func addAudio(to videoId: String, prepared: Prepared, fit: StillSource.Fit, journal: Bool,
                progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    let (v, photo) = try checkAdd(videoId)
    let made = try make(photo: try photoFile(photo, of: v), prepared: prepared, videoId: videoId, fit: fit, progress: progress)
    do {
      let batch = try write(Self.addAction, videoId, journal: journal) {
        // The row may have changed while the file was being made.
        let cur = try self.item(videoId)
        guard cur.photos == [photo] else { throw EngineError("\(cur.displayName) changed while its video was being made") }
        if let why = try self.blocker(cur) { throw EngineError(why) }
        try self.point(videoId, at: made, still: StillSource(photo: photo, audio: Self.relative(videoId, made.audio.lastPathComponent),
                                                            audioName: prepared.name, audioDuration: made.duration, fit: fit))
        var e = try self.store.edit(videoId: videoId)
        e.photoCrops = [:]
        e.aspectOverride = try self.aspect(for: fit)
        e.crop = Self.crop(made, fit: fit)
        e.trimIn = nil; e.trimOut = nil; e.platformTrims = [:]; e.coverTime = nil
        for p in Platform.allCases where !p.supportsPhotos { e.skippedPlatforms.remove(p) }  // the skip a photo post is given
        try self.store.save(e, videoId: videoId, remembersCrop: false)
        try self.clearTextWindows(videoId)
        try self.store.refreshState(videoId: videoId)
        try self.store.logEvent("photo", "Added audio to \(cur.name): now a video (\(prepared.name), \(Validation.fmt(made.duration)))",
                                videoId: videoId)
      }
      return Change(video: try item(videoId), batchId: batch)
    } catch {
      discard(made, videoId)
      throw error
    }
  }

  /// The crop a made video starts with: the whole frame for `whole` (it is 9:16 already), none to confirm for `fill`.
  static func crop(_ made: Made, fit: StillSource.Fit) -> CropRect? {
    fit == .whole ? CropRect(x: 0, y: 0, w: Double(made.width), h: Double(made.height)) : nil
  }

  /// The shape a made video's edit says for itself (review round 2, S3). A whole-photo video is 9:16 by the way it is
  /// made, so where New clip defaults ask for another shape it says 9:16 itself, or its whole-frame crop could never
  /// be rendered. Nothing otherwise: `fill` follows the defaults like any clip.
  func aspect(for fit: StillSource.Fit) throws -> Aspect? {
    guard fit == .whole else { return nil }
    return try store.settings().defaults.aspect == .r9x16 ? nil : .r9x16
  }

  /// Makes the video again with another audio file, at the same fit (or `fit`, which also resets the crop as a fit
  /// change does). The edit stays; a trim, per-platform trim, cover time or text window past the new length is cleared
  /// or cut to it. One journal entry.
  @discardableResult
  public func changeAudio(videoId: String, audio: URL, fit: StillSource.Fit? = nil, journal: Bool = true,
                          progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    let v = try item(videoId)
    guard let still = v.still else { throw EngineError("\(v.displayName) has no audio to change") }
    if let why = try blocker(v) { throw EngineError(why) }
    let newFit = fit ?? still.fits
    let prepared = try prepare(audio) { p in progress?(p * 0.8) }
    let made = try make(photo: try photoFile(still.photo, of: v), prepared: prepared, videoId: videoId, fit: newFit) { p in progress?(0.8 + p * 0.2) }
    do {
      let batch = try write(Self.changeAction, videoId, journal: journal) {
        let cur = try self.item(videoId)
        guard cur.still == still else { throw EngineError("\(cur.displayName) changed while its video was being made") }
        if let why = try self.blocker(cur) { throw EngineError(why) }
        // (No `other`: the video at the other fit holds the old audio.)
        try self.point(videoId, at: made, still: StillSource(photo: still.photo, audio: Self.relative(videoId, made.audio.lastPathComponent),
                                                            audioName: prepared.name, audioDuration: made.duration,
                                                            fit: fit ?? still.fit))
        var e = try self.store.edit(videoId: videoId)
        let o = e
        let end = made.duration + 0.05
        if (e.trimIn ?? 0) >= made.duration || (e.trimOut ?? 0) > end { e.trimIn = nil; e.trimOut = nil }
        e.platformTrims = e.platformTrims.filter { $0.value.start < made.duration && $0.value.end <= end }
        if let c = e.coverTime, c > made.duration { e.coverTime = nil }
        let whole = Self.crop(made, fit: .whole)
        if newFit != still.fits {
          e.crop = Self.crop(made, fit: newFit)
          e.aspectOverride = try self.aspect(for: newFit)
        } else if newFit == .whole, e.aspectOverride == nil, e.crop == nil || e.crop == whole {
          e.aspectOverride = try self.aspect(for: .whole)  // the defaults' shape changed since it was made
        }
        if e != o { try self.store.save(e, videoId: videoId, remembersCrop: false) }
        try self.fitTextWindows(videoId, to: made.duration)
        try self.store.refreshState(videoId: videoId)
        try self.store.logEvent("photo", "Changed the audio of \(cur.name) (\(prepared.name), \(Validation.fmt(made.duration)))",
                                videoId: videoId)
      }
      return Change(video: try item(videoId), batchId: batch)
    } catch {
      discard(made, videoId)
      throw error
    }
  }

  /// D12: changes how the photo sits in the video. The video is made again from the item's own audio copy (a stream
  /// copy: nothing is encoded twice), or, when this audio was already made at this fit, the row goes back to that file
  /// (`StillSource.other`), so flipping back and forth leaves two videos per audio and no more. The crop resets: the
  /// whole frame for `whole`, none to confirm for `fill`. Trim, texts, cover time, captions and platforms stay (same
  /// audio, same length). Same rules as Change audio (`blocker`). One journal entry. Nothing changes when the item
  /// already has this fit (`batchId` nil).
  @discardableResult
  public func setFit(videoId: String, fit: StillSource.Fit, journal: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    let v = try item(videoId)
    guard let still = v.still else { throw EngineError("\(v.displayName) has no audio: add audio first") }
    guard still.fits != fit else { return Change(video: v, batchId: nil) }
    if let why = try blocker(v) { throw EngineError(why) }
    let photo = try photoFile(still.photo, of: v)
    let kept = madeBefore(still, photo: photo, fit: fit)
    let made: Made
    if let kept {
      made = kept
      progress?(1)
    } else {
      let prepared = try prepared(from: still)
      do {
        made = try make(photo: photo, prepared: prepared, videoId: videoId, fit: fit, progress: progress)
      } catch {
        // An audio copy whose header reads and whose sound doesn't: the same words as a copy that is gone.
        if !audioPlays(prepared.encoded) { throw EngineError(Self.audioCopyUnusable(still.audioName)) }
        throw error
      }
    }
    do {
      let batch = try write(Self.fitAction, videoId, journal: journal) {
        let cur = try self.item(videoId)
        guard cur.still == still else { throw EngineError("\(cur.displayName) changed while its video was being made") }
        if let why = try self.blocker(cur) { throw EngineError(why) }
        var next = still
        next.fit = fit
        next.other = cur.file  // the video at the fit it had: the next change back finds it
        try self.point(videoId, at: made, still: next)
        var e = try self.store.edit(videoId: videoId)
        e.crop = Self.crop(made, fit: fit)
        e.aspectOverride = try self.aspect(for: fit)
        try self.store.save(e, videoId: videoId, remembersCrop: false)
        try self.store.refreshState(videoId: videoId)
        try self.store.logEvent("photo", "\(cur.name): \(fit == .whole ? "shows the whole photo" : "fills the frame")", videoId: videoId)
      }
      return Change(video: try item(videoId), batchId: batch)
    } catch {
      // Only a video this call made: the audio copy is the item's own, and a video from before stays.
      if kept == nil { try? fm.removeItem(at: made.video) }
      throw error
    }
  }

  /// The video made before from this audio at `fit` (`StillSource.other`), when it is still there and is what a new
  /// one would be: this frame, this length, H.264 with sound.
  private func madeBefore(_ still: StillSource, photo: URL, fit: StillSource.Fit) -> Made? {
    guard let other = still.other, let size = PhotoRenderer.pixelSize(of: photo) else { return nil }
    let url = store.paths.photos.appendingPathComponent(other)
    let frame = Self.layout(width: size.width, height: size.height, fit: fit).frame
    guard fm.fileExists(atPath: url.path), let info = try? Media.probe(url), info.videoCodec == "h264", info.hasAudio,
          info.width == frame.width, info.height == frame.height, abs(info.duration - still.audioDuration) <= 0.05 else { return nil }
    return Made(video: url, audio: store.paths.photos.appendingPathComponent(still.audio), duration: info.duration, width: frame.width,
                height: frame.height)
  }

  /// The file's sound decodes from start to end.
  private func audioPlays(_ url: URL) -> Bool {
    guard let ffmpeg, let r = try? Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-v", "error", "-xerror", "-i", url.path, "-map", "0:a:0", "-f", "null", "-"],
                                            timeout: 300) else { return false }
    return r.status == 0 && r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Back to a photo post with its one photo (D9): the default photo shape, the centred crop, YouTube off again, and
  /// texts on the photo. The made files stay where they are, so undo only has to point the row back. One journal entry.
  @discardableResult
  public func removeAudio(videoId: String, journal: Bool = true) throws -> Change {
    let v = try item(videoId)
    guard let still = v.still else { throw EngineError("\(v.displayName) has no audio to remove") }
    if let why = try blocker(v) { throw EngineError(why) }
    _ = try photoFile(still.photo, of: v)
    let batch = try write(Self.removeAction, videoId, journal: journal) {
      // The row may have changed since the check above (another process).
      let cur = try self.item(videoId)
      guard cur.still == still else { throw EngineError("\(cur.displayName) changed just now: try again") }
      if let why = try self.blocker(cur) { throw EngineError(why) }
      try self.store.db.run("""
        UPDATE videos SET still=NULL, duration=0, start=NULL, "end"=NULL, missing=0, updated_at=? WHERE id=?
        """, [self.store.clock.now, videoId])
      try self.store.writePhotos([still.photo], videoId: videoId)
      var e = try self.store.edit(videoId: videoId)
      e.crop = nil
      e.aspectOverride = nil
      e.photoCrops = [:]
      e.trimIn = nil; e.trimOut = nil; e.platformTrims = [:]; e.coverTime = nil
      try self.store.save(e, videoId: videoId, remembersCrop: false)  // a photo post's edit is stored with YouTube off
      try self.clearTextWindows(videoId)
      try self.store.refreshState(videoId: videoId)
      try self.store.logEvent("photo", "Removed the audio from \(v.name): a photo post again", videoId: videoId)
    }
    return Change(video: try item(videoId), batchId: batch)
  }

  /// Photos with audio in one go (the import sheet and `djq photo add --audio`): one made video per photo, each the
  /// same as importing the photo and then adding the audio. The audio is read once. A photo that can't be used is
  /// skipped with the reason, and one whose import fails is also in `failed` (the rest are still made: it never throws
  /// once the audio is read). Nothing is journaled (an import isn't) and nothing is sent to the Queue.
  @discardableResult
  public func add(photos: [URL], audio: URL, title: String? = nil, titleSource: String = "app", fit: StillSource.Fit = .whole,
                  progress: (@Sendable (Double) -> Void)? = nil) throws -> AddResult {
    var skipped: [PhotoImport.Skipped] = []
    let good = photos.filter { u in
      let why = PhotoImport.refusal(u)
        ?? PhotoRenderer.pixelSize(of: u).flatMap { Self.sizeRefusal(width: $0.width, height: $0.height, name: u.lastPathComponent) }
      if let why { skipped.append(PhotoImport.Skipped(file: u.path, reason: why)) }
      return why == nil
    }
    guard !good.isEmpty else {
      _ = try Self.audioSeconds(audio, ffmpeg: ffmpeg, ffprobe: ffprobe)  // still say what's wrong with the audio
      return AddResult(videos: [], skipped: skipped)
    }
    let share = 0.6  // of the bar: reading the audio; the rest is a slice per photo
    let prepared = try prepare(audio) { p in progress?(p * share) }
    var out: [Video] = [], failed: [URL] = []
    let importer = PhotoImport(store: store)
    for (i, photo) in good.enumerated() {
      let post: Video
      do {
        let r = try importer.add(files: [photo], mode: .separate, title: title, titleSource: titleSource)
        skipped += r.skipped
        guard let p = r.posts.first else { continue }
        post = p
      } catch {
        skipped.append(PhotoImport.Skipped(file: photo.path, reason: "couldn't add it: \(error)"))
        failed.append(photo)
        continue
      }
      do {
        let n = Double(good.count)
        out.append(try addAudio(to: post.id, prepared: prepared, fit: fit, journal: false) { p in progress?(share + (1 - share) * (Double(i) + p) / n) }.video)
      } catch {
        skipped.append(PhotoImport.Skipped(file: photo.path, reason: "added as a photo post; the video couldn't be made: \(error)"))
      }
    }
    progress?(1)
    return AddResult(videos: out, skipped: skipped, failed: failed)
  }

  // MARK: Files

  /// Intake's check for made videos: one whose video file is gone is `missing`, like a clip whose file is gone, and
  /// comes back when the file does. Returns the names that just went missing.
  @discardableResult
  public func checkFiles() throws -> [String] {
    sweepLeftovers()
    var gone: [String] = []
    for v in try store.videos(where: "still IS NOT NULL") {
      let missing = !fm.fileExists(atPath: store.paths.photos.appendingPathComponent(v.file).path)
      guard missing != v.missing else { continue }
      try store.db.run("UPDATE videos SET missing=?, updated_at=? WHERE id=?", [missing, store.clock.now, v.id])
      try store.refreshState(videoId: v.id)
      if missing {
        gone.append(v.name)
        try store.logEvent("missing", "Video file missing: \(v.name)", videoId: v.id)
      } else {
        try store.logEvent("relink", "Video file is back: \(v.name)", videoId: v.id)
      }
    }
    return gone
  }

  /// A make that was cut short (a crash, a quit) leaves its work folder and a temporary file beside the videos. Those
  /// older than a day go: only `work/still-*` and dot-files in `Photos/Stills/<id>/`, both of which only a make writes.
  func sweepLeftovers(olderThan age: TimeInterval = 86_400, now: Date = Date()) {
    func old(_ u: URL) -> Bool {
      guard let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return false }
      return now.timeIntervalSince(m) > age
    }
    for name in (try? fm.contentsOfDirectory(atPath: store.paths.work.path)) ?? [] where name.hasPrefix("still-") {
      let u = store.paths.work.appendingPathComponent(name)
      if old(u) { try? fm.removeItem(at: u) }
    }
    let stills = store.paths.photos.appendingPathComponent("Stills")
    for id in (try? fm.contentsOfDirectory(atPath: stills.path)) ?? [] {
      let dir = stills.appendingPathComponent(id)
      for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
      where name.hasPrefix(".") && (name.hasSuffix(".mp4") || name.hasSuffix(".m4a") || name.hasSuffix(".audio")) {
        let u = dir.appendingPathComponent(name)
        if old(u) { try? fm.removeItem(at: u) }
      }
    }
  }

  // MARK: Internals

  private func item(_ id: String) throws -> Video {
    guard let v = try store.video(id: id) else { throw EngineError("No post \(id)") }
    return v
  }

  private func photoFile(_ photo: PhotoItem, of v: Video) throws -> URL {
    let url = try store.photoURL(photo, of: v)
    guard fm.fileExists(atPath: url.path), PhotoRenderer.pixelSize(of: url) != nil else {
      throw EngineError("Its photo file is missing (\(URL(fileURLWithPath: photo.file).lastPathComponent))")
    }
    return url
  }

  /// One change to the row, its edit and its versions: in one journal entry, or one plain transaction.
  private func write(_ action: String, _ videoId: String, journal: Bool, _ body: () throws -> Void) throws -> String? {
    if journal { return try BulkActions(store: store).record(action, ids: [videoId]) { try body() }.batchId }
    try store.db.transaction { try body() }
    return nil
  }

  /// Makes the row a video of `made`: no photos, the made file, its length, size and fingerprint.
  private func point(_ videoId: String, at made: Made, still: StillSource) throws {
    let file = Self.relative(videoId, made.video.lastPathComponent)
    try store.db.run("""
      UPDATE videos SET photos=NULL, still=?, file=?, fingerprint=?, file_size=?, duration=?, start=0, "end"=?,
        source_width=?, source_height=?, missing=0, updated_at=? WHERE id=?
      """, [JSONCoding.string(still), file, Intake.fingerprint(made.video, duration: made.duration), Intake.size(made.video),
            made.duration, made.duration, made.width, made.height, store.clock.now, videoId])
  }

  /// A text's window means photos on a photo post and seconds on a video, so neither survives the change: every text of
  /// every version shows all the way through until Eric times it. A countdown (round 26) needs time, so on the way back
  /// to a photo it becomes a plain text showing its first number, the one a photo of it would show.
  private func clearTextWindows(_ videoId: String) throws {
    for var ver in try store.versions(videoId: videoId) {
      let o = ver
      ver.textStart = nil
      ver.textEnd = nil
      ver.moreText = ver.moreText?.map { l in
        var l = l
        l.start = nil; l.end = nil
        if let n = l.countdown { l.text = l.countdownText(n); l.countdown = nil }
        return l
      }
      if ver != o { try store.save(ver, videoId: videoId) }
    }
  }

  /// After Change audio: a text window past the new length would never show. One that starts past it shows for the
  /// whole clip again; one that only ends past it runs to the end (the same idea as a trim that no longer fits).
  private func fitTextWindows(_ videoId: String, to duration: Double) throws {
    func fit(_ start: Double?, _ end: Double?) -> (Double?, Double?) {
      if let s = start, s >= duration { return (nil, nil) }
      if let e = end, e > duration + 0.05 { return (start, nil) }
      return (start, end)
    }
    for var ver in try store.versions(videoId: videoId) {
      let o = ver
      (ver.textStart, ver.textEnd) = fit(ver.textStart, ver.textEnd)
      ver.moreText = ver.moreText?.map { l in
        var l = l
        (l.start, l.end) = fit(l.start, l.end)
        return l
      }
      if ver != o { try store.save(ver, videoId: videoId) }
    }
  }

  /// Takes back files nothing points at (the row wasn't written).
  private func discard(_ made: Made, _ videoId: String) {
    try? fm.removeItem(at: made.video)
    try? fm.removeItem(at: made.audio)
    let dir = stillsDir(videoId)
    if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
  }
}

extension BulkActions {
  /// A made video's media as the journal keeps it (`ClipSnap.still`): what it was made from and the file the row
  /// points at. Only a row with `still` has one, so every other clip's snapshot is what it always was.
  struct StillSnap: Codable, Equatable {
    var still: StillSource
    var file: String
    var fingerprint: String?
    var fileSize: Int64?
    var duration: Double
    var sourceWidth: Int?
    var sourceHeight: Int?
  }

  func stillSnapshot(_ id: String) throws -> String? {
    guard let v = try store.video(id: id), let still = v.still else { return nil }
    return JSONCoding.string(StillSnap(still: still, file: v.file, fingerprint: v.fingerprint, fileSize: v.fileSize, duration: v.duration,
                                       sourceWidth: v.sourceWidth, sourceHeight: v.sourceHeight))
  }

  /// Undo's half of a photo ⇄ video change. A snapshot of a made video points the row back at that file; a snapshot of
  /// a photo post (its photos are restored by the caller) takes the made video off the row.
  func restoreStill(_ c: ClipSnap) throws {
    if let json = c.still, let s = try? JSONCoding.decoder.decode(StillSnap.self, from: Data(json.utf8)) {
      try store.db.run("""
        UPDATE videos SET photos=NULL, still=?, file=?, fingerprint=?, file_size=?, duration=?, start=0, "end"=?,
          source_width=?, source_height=?, updated_at=? WHERE id=?
        """, [JSONCoding.string(s.still), s.file, s.fingerprint, s.fileSize, s.duration, s.duration, s.sourceWidth, s.sourceHeight,
              store.clock.now, c.id])
    } else if c.photos != nil {
      try store.db.run("""
        UPDATE videos SET still=NULL, duration=0, start=NULL, "end"=NULL, updated_at=? WHERE id=? AND still IS NOT NULL
        """, [store.clock.now, c.id])
    }
  }

  /// Why a restore is refused, force or not (D9): it would change what the item is (photo post ⇄ video, another
  /// audio, another fit) while the item has a day or a post. Decided from what the restore would do, not from the
  /// batch's name: a forced undo of an older Edits or title batch carries the old media in its snapshot too.
  func stillUndoLock(restoring b: ClipSnap, current cur: ClipSnap) throws -> String? {
    // (`other`, the file a fit change can go back to, is no part of what the item is.)
    func media(_ json: String?) -> StillSnap? {
      guard let json, var s = try? JSONCoding.decoder.decode(StillSnap.self, from: Data(json.utf8)) else { return nil }
      s.still.other = nil
      return s
    }
    guard media(b.still) != media(cur.still) || (b.still == nil) != (cur.still == nil) || (b.photos == nil) != (cur.photos == nil) else { return nil }
    if try store.db.one("SELECT 1 AS x FROM plan_slots WHERE video_id=?", [b.id]) != nil
        || store.db.one("SELECT 1 AS x FROM platform_posts WHERE video_id=?", [b.id]) != nil {
      return StillVideo.undoLockReason
    }
    return nil
  }
}
