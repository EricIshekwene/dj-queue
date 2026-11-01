import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ProbeInfo: Sendable, Hashable, Codable {
  public var duration: Double
  public var width: Int
  public var height: Int
  public var fps: Double
  public var hasAudio: Bool
  public var size: Int64
  public var videoCodec: String
  public var audioCodec: String?
  public init(duration: Double, width: Int, height: Int, fps: Double, hasAudio: Bool, size: Int64, videoCodec: String,
              audioCodec: String?) {
    self.duration = duration; self.width = width; self.height = height; self.fps = fps; self.hasAudio = hasAudio
    self.size = size; self.videoCodec = videoCodec; self.audioCodec = audioCodec
  }
}

public struct MediaError: Error, LocalizedError, CustomStringConvertible {
  public var message: String
  public init(_ m: String) { message = m }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Source media helpers: ffprobe, exact frames (AVFoundation) and cached thumbnails.
public enum Media {
  // MARK: Probe

  public static func probe(_ url: URL) throws -> ProbeInfo {
    guard let ffprobe = Tools.ffprobe else { throw MediaError("ffprobe not found (install with Homebrew)") }
    let r = try Proc.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path],
                         timeout: 60)
    guard r.status == 0 else { throw MediaError("ffprobe failed for \(url.lastPathComponent): \(r.stderrTail)") }
    guard let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else {
      throw MediaError("ffprobe returned no JSON for \(url.lastPathComponent)")
    }
    let streams = obj["streams"] as? [[String: Any]] ?? []
    let format = obj["format"] as? [String: Any] ?? [:]
    guard let v = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
      throw MediaError("\(url.lastPathComponent) has no video stream")
    }
    let a = streams.first { $0["codec_type"] as? String == "audio" }
    func num(_ any: Any?) -> Double? {
      if let d = any as? Double { return d }
      if let i = any as? Int { return Double(i) }
      if let s = any as? String { return Double(s) }
      return nil
    }
    func rate(_ s: Any?) -> Double {
      guard let s = s as? String else { return 0 }
      let p = s.split(separator: "/").compactMap { Double($0) }
      if p.count == 2, p[1] != 0 { return p[0] / p[1] }
      return p.first ?? 0
    }
    var fps = rate(v["avg_frame_rate"])
    if fps <= 0 || fps > 240 { fps = rate(v["r_frame_rate"]) }
    let duration = num(format["duration"]) ?? num(v["duration"]) ?? 0
    let size = Int64(num(format["size"]) ?? 0)
    return ProbeInfo(duration: duration, width: v["width"] as? Int ?? 0, height: v["height"] as? Int ?? 0,
                     fps: fps, hasAudio: a != nil, size: size, videoCodec: v["codec_name"] as? String ?? "?",
                     audioCodec: a?["codec_name"] as? String)
  }

  // MARK: Frames

  /// The exact frame at `seconds` (zero tolerance), scaled to fit `maxSize` (`.zero` = full size).
  public static func frame(_ url: URL, at seconds: Double, maxSize: CGSize) -> CGImage? {
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    gen.maximumSize = maxSize
    let box = ImageBox()
    let sem = DispatchSemaphore(value: 0)
    let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600_000)
    gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, img, _, _, _ in
      box.image = img
      sem.signal()
    }
    if sem.wait(timeout: .now() + 30) == .timedOut { gen.cancelAllCGImageGeneration(); return nil }
    return box.image
  }

  private final class ImageBox: @unchecked Sendable { var image: CGImage? }

  /// The crop rectangle in whole source pixels as the renderer uses it: even origin and size
  /// (4:2:0 chroma), clamped inside the source. The editor preview must crop with this same rect.
  public static func pixelCrop(_ c: CropRect, sourceWidth: Int, sourceHeight: Int) -> CGRect {
    func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
    var w = max(2, min(even(c.w), sourceWidth - sourceWidth % 2))
    var h = max(2, min(even(c.h), sourceHeight - sourceHeight % 2))
    w = min(w, sourceWidth); h = min(h, sourceHeight)
    let x = min(max(0, even(c.x)), (sourceWidth - w) / 2 * 2)
    let y = min(max(0, even(c.y)), (sourceHeight - h) / 2 * 2)
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// Why a crop can't be rendered as-is, or nil when it is fine: its aspect must be within 1 % of
  /// the output aspect, and it must lie inside the source (even-pixel rounding may move it ≤ 2 px).
  public static func cropProblem(_ c: CropRect, aspect: Aspect, sourceWidth: Int, sourceHeight: Int) -> String? {
    guard c.w > 0, c.h > 0 else { return "the crop is empty" }
    let r = pixelCrop(c, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let ratio = Double(r.width / r.height)
    if abs(ratio - aspect.ratio) / aspect.ratio > 0.01 {
      return String(format: "the crop is %.0f×%.0f (%.3f), which doesn't match %@ (%.3f)", r.width, r.height, ratio,
                    aspect.rawValue, aspect.ratio)
    }
    let moved = [abs(Double(r.minX) - c.x), abs(Double(r.minY) - c.y), abs(Double(r.width) - c.w),
                 abs(Double(r.height) - c.h)].max() ?? 0
    if moved > 2 {
      return String(format: "the crop (x %.0f y %.0f %.0f×%.0f) goes outside the %d×%d source", c.x, c.y, c.w, c.h,
                    sourceWidth, sourceHeight)
    }
    return nil
  }

  /// A centred crop of the given aspect (used for thumbnails before Eric sets a crop).
  public static func centredCrop(aspect: Aspect, sourceWidth: Int, sourceHeight: Int) -> CropRect {
    let sw = Double(sourceWidth), sh = Double(sourceHeight)
    var w = sh * aspect.ratio, h = sh
    if w > sw { w = sw; h = sw / aspect.ratio }
    return CropRect(x: (sw - w) / 2, y: (sh - h) / 2, w: w, h: h)
  }

  /// Crops `image` with `pixelCrop` and scales it into a `size` canvas (high-quality interpolation),
  /// optionally compositing `overlay` (already at `size`) on top. This is the editor-preview composite.
  /// `crop` is in source pixels; pass `sourceSize` when `image` is a downscaled frame (`maxSize ≠ .zero`)
  /// and the crop is scaled to the image.
  public static func compose(_ image: CGImage, crop: CropRect?, aspect: Aspect, size: CGSize,
                             overlay: CGImage? = nil, sourceSize: CGSize? = nil) -> CGImage? {
    var c = crop ?? centredCrop(aspect: aspect, sourceWidth: image.width, sourceHeight: image.height)
    if crop != nil, let src = sourceSize, src.width > 0, Double(src.width) != Double(image.width) {
      let k = Double(image.width) / Double(src.width)
      c = CropRect(x: c.x * k, y: c.y * k, w: c.w * k, h: c.h * k)
    }
    let r = pixelCrop(c, sourceWidth: image.width, sourceHeight: image.height)
    guard let cropped = image.cropping(to: r) else { return nil }
    let w = Int(size.width), h = Int(size.height)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
    if let overlay { ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    return ctx.makeImage()
  }

  // MARK: Thumbnails

  /// Cached JPG in `paths.thumbs`. Uses the edit's crop if set, else a centred crop of the edit's
  /// aspect; default time = marker in-point + 1 s. Cache key covers video id, crop, aspect, time and size.
  public static func thumbnail(store: Store, video: Video, at seconds: Double? = nil, maxHeight: Int = 320) -> URL? {
    guard let src = try? store.fileURL(for: video), FileManager.default.fileExists(atPath: src.path) else { return nil }
    let edit = (try? store.edit(videoId: video.id)) ?? Edit()
    var t = seconds ?? ((video.markerIn ?? 0) + 1)
    if video.duration > 0 { t = min(max(0, t), max(0, video.duration - 0.05)) }
    let cropKey = edit.crop.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "centre"
    let key = "\(video.id)|\(cropKey)|\(edit.aspect.rawValue)|\(String(format: "%.3f", t))|\(maxHeight)|\(video.fingerprint ?? "")"
    let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let url = store.paths.thumbs.appendingPathComponent("\(video.id)-\(hash).jpg")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    guard let frame = frame(src, at: t, maxSize: .zero) else { return nil }
    let h = maxHeight
    let w = max(2, Int((Double(h) * edit.aspect.ratio).rounded()))
    guard let img = compose(frame, crop: edit.crop, aspect: edit.aspect, size: CGSize(width: w, height: h)) else {
      return nil
    }
    do {
      try FileManager.default.createDirectory(at: store.paths.thumbs, withIntermediateDirectories: true)
      try writeJPEG(img, to: url, quality: 0.8)
      return url
    } catch {
      Log.shared.warn("thumbnail failed for \(video.id): \(error)")
      return nil
    }
  }

  public static func writeJPEG(_ img: CGImage, to url: URL, quality: Double = 0.9) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
    guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw MediaError("cannot write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw MediaError("cannot encode \(url.lastPathComponent)") }
    _ = try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
  }

  public static func writePNG(_ img: CGImage, to url: URL) throws {
    guard let d = TextOverlay.pngData(img) else { throw MediaError("cannot encode \(url.lastPathComponent)") }
    try d.write(to: url, options: .atomic)
  }
}

// MARK: - Process helper

/// Runs a tool with full path; collects stdout/stderr on dedicated reader threads (no pipe
/// deadlocks) and terminates the process if it runs longer than `timeout`.
struct Proc {
  struct Result {
    var status: Int32
    var stdout: String
    var stderr: String
    var stderrTail: String {
      let lines = stderr.split(separator: "\n").suffix(6)
      return lines.joined(separator: " | ")
    }
  }

  /// `onLine` receives stdout lines as they arrive (used for `-progress pipe:1`).
  static func run(_ path: String, _ args: [String], timeout: TimeInterval = 600,
                  onLine: ((String) -> Void)? = nil) throws -> Result {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let acc = Accum()
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    try p.run()
    let readers = DispatchGroup()
    let lineHandler = onLine.map { h in UncheckedBox(h) }
    for (handle, isOut) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
      readers.enter()
      Thread.detachNewThread {
        while true {
          let d = handle.availableData  // blocks; empty = EOF
          if d.isEmpty { break }
          if isOut { acc.addOut(d, lineHandler?.value) } else { acc.addErr(d) }
        }
        readers.leave()
      }
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      p.terminate()
      if exited.wait(timeout: .now() + 5) == .timedOut {
        kill(p.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 5)
      }
    }
    _ = readers.wait(timeout: .now() + 10)
    acc.flush(lineHandler?.value)
    if timedOut {
      throw MediaError("\(URL(fileURLWithPath: path).lastPathComponent) timed out after \(Int(timeout)) s and was stopped")
    }
    return acc.result(p.terminationStatus)
  }

  private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
  }

  private final class Accum: @unchecked Sendable {
    let lock = NSLock()
    var out = Data(), err = Data(), pending = Data()
    func addOut(_ d: Data, _ onLine: ((String) -> Void)?) {
      guard !d.isEmpty else { return }
      var lines: [String] = []
      lock.withLock {
        out.append(d)
        guard onLine != nil else { return }
        pending.append(d)
        while let i = pending.firstIndex(of: 10) {
          lines.append(String(decoding: pending[pending.startIndex..<i], as: UTF8.self))
          pending.removeSubrange(pending.startIndex...i)
        }
      }
      for l in lines { onLine?(l) }
    }
    func addErr(_ d: Data) { guard !d.isEmpty else { return }; lock.withLock { err.append(d) } }
    func flush(_ onLine: ((String) -> Void)?) {
      let rest: String? = lock.withLock {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
      }
      if let rest { onLine?(rest) }
    }
    func result(_ s: Int32) -> Result {
      lock.withLock { Result(status: s, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self)) }
    }
  }
}
