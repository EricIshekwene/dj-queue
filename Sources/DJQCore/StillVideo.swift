import CoreGraphics
import Foundation
import ImageIO

/// Photo with audio (round 23, DECISIONS-R23.md). One photo and an audio file become a real video file once, and the
/// item is then an ordinary clip: `Video.still` says what it was made from, `photos` is nil, `file` is the made video.
///
/// Files live in the Photos folder: `Stills/<video id>/video.mp4` and DJ Queue's own copy of the audio,
/// `Stills/<video id>/audio.<ext>`. A later Change audio writes `video-2.mp4` / `audio-2.<ext>` beside them, so the
/// undo of a change only has to point the row back at files that are still there. The files Eric picked are only read.
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
  /// Why bulk crop leaves it alone: its picture is a photo of any shape, so one framing can't fit a selection.
  public static let bulkCropReason = "a photo with audio is cropped in the editor"
  /// The issue for a YouTube post with nothing to name it (D10).
  public static let youtubeTitleIssue = "Add a title: YouTube would name it after the file"

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

  /// Journal actions, for `djq bulk undo` and the app's ⌘Z.
  public static let addAction = "photo-audio-add", changeAction = "photo-audio-change", removeAction = "photo-audio-remove"
  static let actions: Set<String> = [addAction, changeAction, removeAction]

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
    let source: URL
    let encoded: URL
    let duration: Double
    let folder: URL
    init(source: URL, encoded: URL, duration: Double, folder: URL) {
      self.source = source; self.encoded = encoded; self.duration = duration; self.folder = folder
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
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
        throw EngineError("\(audio.lastPathComponent) can't be read as audio: \(r.stderrTail)")
      }
      let d = try encodedSeconds(out)
      try Self.checkLength(d, audio)
      progress?(1)
      return Prepared(source: audio, encoded: out, duration: d, folder: folder)
    } catch {
      try? fm.removeItem(at: folder)
      throw error
    }
  }

  private func encodedSeconds(_ url: URL) throws -> Double {
    guard let ffprobe else { throw EngineError(Self.noFFmpeg) }
    let r = try Proc.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path], timeout: 60)
    guard r.status == 0, let d = Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 else {
      throw EngineError("the audio came out unreadable: \(r.stderrTail)")
    }
    return d
  }

  // MARK: Making the file

  /// Makes `Stills/<video id>/video.mp4` (the photo held for exactly the audio's length) and DJ Queue's copy of the
  /// audio beside it. Blocking; call it off the main thread. Both picked files are only read. Everything is written
  /// under a temporary name and moved into place at the end, so a run that fails leaves nothing behind.
  @discardableResult
  public func make(photo: URL, audio: URL, videoId: String, progress: (@Sendable (Double) -> Void)? = nil) throws -> Made {
    let prepared = try prepare(audio) { p in progress?(p * 0.8) }
    return try make(photo: photo, prepared: prepared, videoId: videoId) { p in progress?(0.8 + p * 0.2) }
  }

  /// The picture half: a few seconds of the photo encoded once, repeated under the prepared audio without encoding
  /// again, so twenty minutes take as long as twenty seconds.
  func make(photo: URL, prepared: Prepared, videoId: String, progress: (@Sendable (Double) -> Void)? = nil) throws -> Made {
    guard let ffmpeg else { throw EngineError(Self.noFFmpeg) }
    guard fm.fileExists(atPath: photo.path), let size = PhotoRenderer.pixelSize(of: photo) else {
      throw EngineError("\(photo.lastPathComponent) can't be read as a photo")
    }
    let frame = Self.frameSize(width: size.width, height: size.height)
    let d = prepared.duration
    let work = store.paths.work.appendingPathComponent("still-\(UUID().uuidString)")
    let dir = stillsDir(videoId)
    let hadDir = fm.fileExists(atPath: dir.path)
    let names = try nextNames(videoId, audioExtension: prepared.source.pathExtension.lowercased())
    let tmpVideo = dir.appendingPathComponent(".\(UUID().uuidString).mp4"), tmpAudio = dir.appendingPathComponent(".\(UUID().uuidString).audio")
    var placed: [URL] = []
    do {
      try fm.createDirectory(at: work, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: work) }
      // 1. The photo upright, at the frame's size, as plain sRGB pixels.
      let png = work.appendingPathComponent("photo.png")
      try Self.writeFrame(photo, width: frame.width, height: frame.height, to: png)
      progress?(0.2)
      // 2. One keyframe interval of it: a picture and then frames that say "the same again".
      let n = min(Self.fps * Self.keyframeSeconds, max(1, Int((d * Double(Self.fps)).rounded(.up))))
      let seg = work.appendingPathComponent("segment.mp4")
      let colour = ["-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]
      func segment(_ codec: [String]) throws -> Proc.Result {
        try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-framerate", String(Self.fps), "-i", png.path,
                              "-vf", "loop=loop=\(n - 1):size=1:start=0,scale=in_range=pc:out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1,"
                                + "setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709",  // a PNG says sRGB; the file says BT.709, as every clip does
                              "-frames:v", String(n)] + codec + ["-g", String(n), "-bf", "0"] + colour
                              + ["-video_track_timescale", "30000", "-an", "-map_metadata", "-1", seg.path], timeout: 180)
      }
      // The keyframe at quantiser 18 (about 48 dB on a 4K photo); every frame after it at 38, which leaves nothing to
      // code, so each is a few hundred bytes of "skip". x264's own rate control spends as much again on those frames.
      var r = try segment(["-c:v", "libx264", "-preset", "veryfast", "-qp", "38", "-i_qfactor", "0.1", "-keyint_min", String(n),
                           "-sc_threshold", "0", "-profile:v", "high"])
      if r.status != 0 {  // an ffmpeg built without x264: the Mac's own encoder
        r = try segment(["-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "40000k", "-allow_sw", "1"])
      }
      guard r.status == 0, fm.fileExists(atPath: seg.path) else { throw EngineError("couldn't make the video: \(r.stderrTail)") }
      progress?(0.6)
      // 3. That interval again and again under the audio, copied, cut at the audio's end.
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let m = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-stream_loop", "-1", "-i", seg.path, "-i", prepared.encoded.path,
                                    "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-t", String(format: "%.6f", d),
                                    "-map_metadata", "-1", "-movflags", "+faststart", "-f", "mp4", tmpVideo.path], timeout: 300)
      guard m.status == 0, fm.fileExists(atPath: tmpVideo.path) else { throw EngineError("couldn't make the video: \(m.stderrTail)") }
      let probe = try Media.probe(tmpVideo)
      var problems: [String] = []
      if probe.videoCodec != "h264" { problems.append("codec \(probe.videoCodec)") }
      if probe.width != frame.width || probe.height != frame.height { problems.append("size \(probe.width)×\(probe.height)") }
      if !probe.hasAudio { problems.append("no audio") }
      if abs(probe.duration - d) > 0.05 { problems.append(String(format: "length %.3f s, audio %.3f s", probe.duration, d)) }
      if abs(probe.fps - Double(Self.fps)) > 0.01 { problems.append(String(format: "%.2f fps", probe.fps)) }
      guard problems.isEmpty else { throw EngineError("the video came out wrong (\(problems.joined(separator: ", ")))") }
      progress?(0.9)
      // 4. DJ Queue's own copy of the audio (the file itself, never a link to it), then both into place.
      try placeHook?()
      try fm.copyItem(at: prepared.source.resolvingSymlinksInPath(), to: tmpAudio)
      try fm.moveItem(at: tmpAudio, to: names.audio)
      placed.append(names.audio)
      try fm.moveItem(at: tmpVideo, to: names.video)
      placed.append(names.video)
      progress?(1)
      return Made(video: names.video, audio: names.audio, duration: probe.duration, width: frame.width, height: frame.height)
    } catch {
      for u in [tmpVideo, tmpAudio] + placed { try? fm.removeItem(at: u) }
      if !hadDir { try? fm.removeItem(at: dir) }
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

  /// The next free pair of names in the item's folder: `video.mp4` and `audio.<ext>` the first time, then `video-2.mp4`
  /// and `audio-2.<ext>`. A name is never used twice, so a journal entry's files are still the ones it names.
  func nextNames(_ videoId: String, audioExtension ext: String) throws -> (video: URL, audio: URL) {
    let dir = stillsDir(videoId)
    let used = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { f -> Int? in
      let base = (f as NSString).deletingPathExtension
      guard base.hasPrefix("video") || base.hasPrefix("audio") else { return nil }
      let tail = base.dropFirst(5)
      return tail.isEmpty ? 1 : Int(tail.dropFirst())
    }
    let n = (used.max() ?? 0) + 1
    let suffix = n == 1 ? "" : "-\(n)"
    return (dir.appendingPathComponent("video\(suffix).mp4"), dir.appendingPathComponent("audio\(suffix).\(ext.isEmpty ? "audio" : ext)"))
  }

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
  /// groups, texts and looks. Its per-photo crop, photo shape and forced YouTube skip go, each text shows for the whole
  /// clip, and it has no confirmed crop. Blocking (it makes the file); nothing is sent to the Queue. One journal entry,
  /// so `djq bulk undo` and ⌘Z bring the photo post back exactly.
  @discardableResult
  public func addAudio(to videoId: String, audio: URL, journal: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    let prepared = try prepare(audio) { p in progress?(p * 0.8) }
    return try addAudio(to: videoId, prepared: prepared, journal: journal) { p in progress?(0.8 + p * 0.2) }
  }

  func addAudio(to videoId: String, prepared: Prepared, journal: Bool, progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    let v = try item(videoId)
    guard v.isPhoto else { throw EngineError(v.isStill ? "\(v.displayName) already has audio" : "\(v.displayName) isn't a photo post") }
    if let why = try blocker(v) { throw EngineError(why) }
    guard let photo = v.photos?.first else { throw EngineError("Add a photo first") }
    let made = try make(photo: try photoFile(photo, of: v), prepared: prepared, videoId: videoId, progress: progress)
    do {
      let batch = try write(Self.addAction, videoId, journal: journal) {
        // The row may have changed while the file was being made.
        let cur = try self.item(videoId)
        guard cur.photos == [photo] else { throw EngineError("\(cur.displayName) changed while its video was being made") }
        if let why = try self.blocker(cur) { throw EngineError(why) }
        try self.point(videoId, at: made, still: StillSource(photo: photo, audio: Self.relative(videoId, made.audio.lastPathComponent),
                                                            audioName: prepared.source.lastPathComponent, audioDuration: made.duration))
        var e = try self.store.edit(videoId: videoId)
        e.photoCrops = [:]
        e.aspectOverride = nil
        e.crop = nil
        e.trimIn = nil; e.trimOut = nil; e.platformTrims = [:]; e.coverTime = nil
        for p in Platform.allCases where !p.supportsPhotos { e.skippedPlatforms.remove(p) }  // the skip a photo post is given
        try self.store.save(e, videoId: videoId, remembersCrop: false)
        try self.clearTextWindows(videoId)
        try self.store.refreshState(videoId: videoId)
        try self.store.logEvent("photo", "Added audio to \(cur.name): now a video (\(prepared.source.lastPathComponent), \(Validation.fmt(made.duration)))",
                                videoId: videoId)
      }
      return Change(video: try item(videoId), batchId: batch)
    } catch {
      discard(made, videoId)
      throw error
    }
  }

  /// Makes the video again with another audio file. The edit stays; a trim, per-platform trim or cover time past the new
  /// length is cleared. One journal entry.
  @discardableResult
  public func changeAudio(videoId: String, audio: URL, journal: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) throws -> Change {
    let v = try item(videoId)
    guard let still = v.still else { throw EngineError("\(v.displayName) has no audio to change") }
    if let why = try blocker(v) { throw EngineError(why) }
    let prepared = try prepare(audio) { p in progress?(p * 0.8) }
    let made = try make(photo: try photoFile(still.photo, of: v), prepared: prepared, videoId: videoId) { p in progress?(0.8 + p * 0.2) }
    do {
      let batch = try write(Self.changeAction, videoId, journal: journal) {
        let cur = try self.item(videoId)
        guard cur.still == still else { throw EngineError("\(cur.displayName) changed while its video was being made") }
        if let why = try self.blocker(cur) { throw EngineError(why) }
        try self.point(videoId, at: made, still: StillSource(photo: still.photo, audio: Self.relative(videoId, made.audio.lastPathComponent),
                                                            audioName: prepared.source.lastPathComponent, audioDuration: made.duration))
        var e = try self.store.edit(videoId: videoId)
        let o = e
        let end = made.duration + 0.05
        if (e.trimIn ?? 0) >= made.duration || (e.trimOut ?? 0) > end { e.trimIn = nil; e.trimOut = nil }
        e.platformTrims = e.platformTrims.filter { $0.value.start < made.duration && $0.value.end <= end }
        if let c = e.coverTime, c > made.duration { e.coverTime = nil }
        if e != o { try self.store.save(e, videoId: videoId, remembersCrop: false) }
        try self.store.refreshState(videoId: videoId)
        try self.store.logEvent("photo", "Changed the audio of \(cur.name) (\(prepared.source.lastPathComponent), \(Validation.fmt(made.duration)))",
                                videoId: videoId)
      }
      return Change(video: try item(videoId), batchId: batch)
    } catch {
      discard(made, videoId)
      throw error
    }
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
  /// skipped with the reason. Nothing is journaled (an import isn't) and nothing is sent to the Queue.
  @discardableResult
  public func add(photos: [URL], audio: URL, title: String? = nil, titleSource: String = "app",
                  progress: (@Sendable (Double) -> Void)? = nil) throws -> AddResult {
    let good = photos.filter { PhotoImport.refusal($0) == nil }
    var skipped = photos.compactMap { u in PhotoImport.refusal(u).map { PhotoImport.Skipped(file: u.path, reason: $0) } }
    guard !good.isEmpty else {
      _ = try Self.audioSeconds(audio, ffmpeg: ffmpeg, ffprobe: ffprobe)  // still say what's wrong with the audio
      return AddResult(videos: [], skipped: skipped)
    }
    let share = 0.6  // of the bar: reading the audio; the rest is a slice per photo
    let prepared = try prepare(audio) { p in progress?(p * share) }
    var out: [Video] = []
    let importer = PhotoImport(store: store)
    for (i, photo) in good.enumerated() {
      let r = try importer.add(files: [photo], mode: .separate, title: title, titleSource: titleSource)
      skipped += r.skipped
      guard let post = r.posts.first else { continue }
      do {
        let n = Double(good.count)
        out.append(try addAudio(to: post.id, prepared: prepared, journal: false) { p in progress?(share + (1 - share) * (Double(i) + p) / n) }.video)
      } catch {
        skipped.append(PhotoImport.Skipped(file: photo.path, reason: "added as a photo post; the video couldn't be made: \(error)"))
      }
    }
    progress?(1)
    return AddResult(videos: out, skipped: skipped)
  }

  // MARK: Files

  /// Intake's check for made videos: one whose video file is gone is `missing`, like a clip whose file is gone, and
  /// comes back when the file does. Returns the names that just went missing.
  @discardableResult
  public func checkFiles() throws -> [String] {
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
  /// every version shows all the way through until Eric times it.
  private func clearTextWindows(_ videoId: String) throws {
    for var ver in try store.versions(videoId: videoId) {
      let o = ver
      ver.textStart = nil
      ver.textEnd = nil
      ver.moreText = ver.moreText?.map { l in
        var l = l
        l.start = nil; l.end = nil
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

  /// Why the undo of an audio change is refused, force or not (D9): the item has a day or a post since.
  func stillUndoLock(_ action: String, _ id: String) throws -> String? {
    guard StillVideo.actions.contains(action) else { return nil }
    if try store.db.one("SELECT 1 AS x FROM plan_slots WHERE video_id=?", [id]) != nil
        || store.db.one("SELECT 1 AS x FROM platform_posts WHERE video_id=?", [id]) != nil {
      return "It's scheduled or posted now: \(StillVideo.lockedReason.prefix(1).lowercased() + StillVideo.lockedReason.dropFirst())"
    }
    return nil
  }
}
