import CoreGraphics
import Foundation
import ImageIO
@testable import DJQCore

/// Round 23 test audio, generated here (never a third-party track): a sine tone written as raw WAV bytes into the
/// fixture's temp folder, and real ffmpeg for everything made from it. The suites that need ffmpeg are off without it.
enum Tone {
  static var haveTools: Bool { Tools.ffmpeg != nil && Tools.ffprobe != nil }

  /// A mono sine tone as a WAV file: 16-bit at 44.1 kHz, or 8-bit at `rate` for a long file that stays small.
  @discardableResult
  static func wav(_ url: URL, seconds: Double, frequency: Double = 440, rate: Int = 44_100, bits: Int = 16) -> URL {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let n = Int((seconds * Double(rate)).rounded())
    let bytesPerSample = bits / 8
    var d = Data(capacity: 44 + n * bytesPerSample)
    func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + n * bytesPerSample)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * bytesPerSample)); le(UInt16(bytesPerSample)); le(UInt16(bits))
    d.append(contentsOf: Array("data".utf8)); le(UInt32(n * bytesPerSample))
    let step = 2 * Double.pi * frequency / Double(rate)
    if bits == 16 {
      for i in 0..<n { le(Int16((sin(Double(i) * step) * 0.4 * 32767).rounded())) }
    } else {
      for i in 0..<n { d.append(UInt8((128 + sin(Double(i) * step) * 0.4 * 127).rounded())) }
    }
    try? d.write(to: url)
    return url
  }

  /// ffprobe's answer to one `-show_entries` question about a file's stream.
  static func probe(_ url: URL, stream: String, _ entries: String) -> [String] {
    guard let ffprobe = Tools.ffprobe,
          let r = try? Proc.run(ffprobe, ["-v", "error", "-select_streams", stream, "-show_entries", "stream=\(entries)", "-of", "csv=p=0", url.path],
                                timeout: 60) else { return [] }
    return r.stdout.split(whereSeparator: { $0 == "\n" || $0 == "," }).map(String.init)
  }

  /// One frame of a video as RGB pixels: its stored values through the BT.709 limited-range matrix, with no colour
  /// management after that (the PNG it passes through is marked sRGB, so reading it changes nothing). These are the
  /// numbers the renderer works on.
  ///
  /// `stored`: every pixel takes the colour sample of its own 2×2 block, with nothing blended in from the block next
  /// to it (a player blends; the file doesn't). For "is this row's colour in the file its own".
  static func frame(_ url: URL, at seconds: Double, in dir: URL, stored: Bool = false) -> PhotoImages.Bitmap? {
    guard let ffmpeg = Tools.ffmpeg else { return nil }
    let out = dir.appendingPathComponent("frame-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: out) }
    let r = try? Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-ss", String(format: "%.3f", seconds), "-i", url.path, "-frames:v", "1",
                                   "-vf", "scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=\(stored ? "neighbor+accurate_rnd" : "accurate_rnd+full_chroma_int"),format=rgb24,"
                                     + "setparams=color_trc=iec61966-2-1:color_primaries=bt709",
                                   out.path], timeout: 60)
    guard r?.status == 0 else { return nil }
    return PhotoImages.bitmap(out)
  }

  /// A video file with a picture and no sound.
  @discardableResult
  static func silentVideo(_ url: URL) -> Bool {
    guard let ffmpeg = Tools.ffmpeg else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let r = try? Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-y", "-f", "lavfi", "-i", "color=c=gray:size=64x64:rate=30:duration=2",
                                   "-an", "-pix_fmt", "yuv420p", url.path], timeout: 60)
    return r?.status == 0
  }
}

extension PhotoImages {
  /// A PNG whose left half is `left` and whose right half is see-through.
  @discardableResult
  static func writeSeeThrough(_ url: URL, width: Int, height: Int, left: RGB) -> Bool {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: CGFloat(left.r) / 255, green: CGFloat(left.g) / 255, blue: CGFloat(left.b) / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
  }
}

extension Fixture {
  /// A tone "Eric picked", in the inbox.
  @discardableResult
  func tone(_ name: String = "tone.wav", seconds: Double = 3) -> URL { Tone.wav(inbox.appendingPathComponent(name), seconds: seconds) }

  /// A photo post with one photo.
  @discardableResult
  func singlePhoto(_ name: String = "flyer", title: String? = nil, width: Int = 400, height: Int = 300) throws -> Video {
    try photoPost(name, count: 1, title: title, width: width, height: height)
  }

  /// A video made from a fresh photo and a tone, as "Add audio" makes it. `fit` is `fill` here unless a test asks for
  /// the default (`whole`): these tests are mostly about the clip rules, where the crop is Eric's to pick.
  @discardableResult
  func still(_ name: String = "flyer", title: String? = "Saturday flyer", seconds: Double = 3, width: Int = 400, height: Int = 300,
             fit: StillSource.Fit = .fill) throws -> Video {
    let v = try singlePhoto(name, title: title, width: width, height: height)
    return try StillVideo(store: store).addAudio(to: v.id, audio: tone("\(name).wav", seconds: seconds), fit: fit).video
  }

  /// The files in an item's Stills folder, sorted.
  func stillFiles(_ id: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.photos.appendingPathComponent("Stills/\(id)").path)) ?? []).sorted()
  }

  /// Temporary folders a make leaves in the work folder (there must be none afterwards).
  var stillLeftovers: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.work.path)) ?? []).filter { $0.hasPrefix("still-") }
  }

  /// A row as it is stored, without the time it was last written: for "exactly as it was" comparisons.
  func row(_ table: String, _ key: String, _ id: String, without: Set<String> = ["updated_at"]) throws -> [String: String] {
    guard let r = try store.db.one("SELECT * FROM \(table) WHERE \(key)=?", [id]) else { return [:] }
    let cols = try store.db.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") }.filter { !without.contains($0) }
    return Dictionary(uniqueKeysWithValues: cols.map { ($0, r.string($0) ?? r.double($0).map { String($0) } ?? "-") })
  }

  /// A video's row, its edit and its versions, as stored.
  func stored(_ id: String) throws -> [String] {
    let versions = try store.db.query("SELECT number, json FROM versions WHERE video_id=? ORDER BY number", [id])
      .map { "v\($0.int("number") ?? 0) \($0.string("json") ?? "")" }
    let video = try row("videos", "id", id).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    return video + ["edit " + (try store.db.one("SELECT json FROM edits WHERE video_id=?", [id])?.string("json") ?? "-")] + versions
  }
}
