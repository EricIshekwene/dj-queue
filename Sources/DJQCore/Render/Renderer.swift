import CoreGraphics
import CryptoKit
import Foundation

public struct RenderError: Error, LocalizedError, CustomStringConvertible {
  public var message: String
  public init(_ m: String) { message = m }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Final-file renderer (spec §7): trim → crop (source px) → scale (lanczos) → TextOverlay PNG
/// (`enable=between(t,…)`) → two-pass EBU R128 loudnorm → h264_videotoolbox / AAC → +faststart,
/// validated with ffprobe; plus a cover JPG. One render per (video, version, editHash, scope).
public final class Renderer: RenderService, @unchecked Sendable {
  public let store: Store
  /// Overrides the destination folder (proofs/tests). Default: `<session>/Ready to Post/Shortform/`.
  public let outputRoot: URL?
  /// (renderId, 0…1), called from a background thread while rendering.
  public var onProgress: (@Sendable (String, Double) -> Void)?

  /// Bump when the pipeline changes in a way that changes output files (invalidates every editHash).
  public static let pipelineVersion = "render-2"

  private let renderLock = NSLock()

  public init(store: Store, outputRoot: URL? = nil) {
    self.store = store
    self.outputRoot = outputRoot
  }

  // MARK: Naming

  /// "<video name> – v<n>[ – <Platform>].mp4"
  public static func outputName(video: Video, versionNo: Int, platform: Platform?) -> String {
    let base = video.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return "\(base) – v\(versionNo)\(platform.map { " – \($0.displayName)" } ?? "").mp4"
  }

  // MARK: RenderService

  public func scope(videoId: String, platform: Platform?) throws -> String {
    let edit = try store.edit(videoId: videoId)
    if let p = platform, edit.platformTrims[p] != nil { return p.rawValue }
    return "all"
  }

  public func editHash(videoId: String, versionNo: Int, platform: Platform?) throws -> String {
    try plan(videoId: videoId, versionNo: versionNo, platform: platform).hash
  }

  public func currentRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render? {
    let p = try plan(videoId: videoId, versionNo: versionNo, platform: platform)
    return try current(p)
  }

  @discardableResult
  public func ensureRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render {
    renderLock.lock()
    defer { renderLock.unlock() }
    let p = try plan(videoId: videoId, versionNo: versionNo, platform: platform)
    if let r = try current(p) { return r }
    guard p.edit.crop != nil else {
      throw RenderError("Can't render \(p.video.name): no crop set. Set the crop in the editor first.")
    }
    let now = store.clock.now
    let existing = try store.renders(
      where: "video_id=? AND version_no=? AND edit_hash=? AND scope=? AND deleted_at IS NULL",
      [p.video.id, versionNo, p.hash, p.scope]).last
    var r = existing ?? Render(id: newId(), videoId: p.video.id, versionNo: versionNo, editHash: p.hash, scope: p.scope,
                               outputPath: nil, coverPath: nil, loudness: nil, duration: nil, size: nil,
                               status: .pending, error: nil, createdAt: now, deletedAt: nil)
    r.status = .pending; r.error = nil
    try store.save(r)
    do {
      r.status = .rendering
      try store.save(r)
      let started = Date()
      let out = try perform(p, renderId: r.id)
      r.outputPath = out.file.path
      r.coverPath = out.cover?.path
      r.loudness = out.loudness
      r.duration = out.probe.duration
      r.size = out.probe.size
      r.status = .done
      r.error = nil
      try store.save(r)
      // A re-render for the same video/version/scope writes the same file name: older rows now point
      // at a replaced file, so retire them.
      for old in try store.renders(where: "deleted_at IS NULL AND id<>? AND output_path=?", [r.id, out.file.path]) {
        var o = old
        o.deletedAt = store.clock.now
        try store.save(o)
      }
      let secs = String(format: "%.1f", Date().timeIntervalSince(started))
      try? store.logEvent("render", "Rendered \(out.file.lastPathComponent) in \(secs) s"
                          + (out.loudness.map { String(format: " (%.1f → %.1f LUFS)", $0.inputI, $0.outputI ?? .nan) } ?? ""),
                          videoId: p.video.id)
      onProgress?(r.id, 1)
      return r
    } catch {
      r.status = .failed
      r.error = "\(error)"
      try? store.save(r)
      try? store.logEvent("render_failed", "Render failed for \(p.video.name) v\(versionNo): \(error)", videoId: p.video.id)
      throw error
    }
  }

  public func deleteRenders(except keep: Set<String>) throws {
    let all = try store.renders()
    let keptPaths = Set(all.filter { keep.contains($0.id) }.flatMap { [$0.outputPath, $0.coverPath].compactMap { $0 } })
    for r in all where !keep.contains(r.id) && r.status != .rendering {
      for path in [r.outputPath, r.coverPath].compactMap({ $0 }) where !keptPaths.contains(path) {
        let url = URL(fileURLWithPath: path)
        if isAppOutput(url) { try? FileManager.default.removeItem(at: url) }
      }
      var d = r
      d.deletedAt = store.clock.now
      try store.save(d)
    }
  }

  /// Only files this app creates: `…/Ready to Post/Shortform/<file>` (or inside `outputRoot`).
  func isAppOutput(_ url: URL) -> Bool {
    let dir = url.deletingLastPathComponent()
    if dir.lastPathComponent == "Shortform", dir.deletingLastPathComponent().lastPathComponent == "Ready to Post" {
      return true
    }
    if let root = outputRoot, dir.standardizedFileURL.path == root.standardizedFileURL.path { return true }
    return false
  }

  // MARK: Loudness

  /// EBU R128 measurement (`ebur128=peak=true`): integrated LUFS, true peak dBTP, LRA LU.
  public func measureLoudness(_ url: URL) throws -> LoudnessInfo {
    try Self.measureLoudness(url)
  }

  public static func measureLoudness(_ url: URL) throws -> LoudnessInfo {
    let ffmpeg = try tool(Tools.ffmpeg, "ffmpeg")
    let r = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-i", url.path, "-map", "0:a:0",
                                  "-af", "ebur128=peak=true", "-f", "null", "-"])
    guard r.status == 0 else { throw RenderError("loudness measurement failed: \(r.stderrTail)") }
    guard let summary = r.stderr.range(of: "Summary:") else { throw RenderError("no ebur128 summary") }
    let s = String(r.stderr[summary.upperBound...])
    func value(after label: String, in text: String) -> Double? {
      guard let range = text.range(of: label) else { return nil }
      let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
      return Double(rest.split(separator: " ").first ?? "")
    }
    guard let i = value(after: "I:", in: s), let lra = value(after: "LRA:", in: s) else {
      throw RenderError("cannot parse ebur128 summary")
    }
    var tp = -Double.infinity
    if let tpr = s.range(of: "True peak:") { tp = value(after: "Peak:", in: String(s[tpr.upperBound...])) ?? tp }
    return LoudnessInfo(inputI: i, inputTP: tp, inputLRA: lra)
  }

  // MARK: Plan

  struct Plan {
    var video: Video
    var edit: Edit
    var version: ResolvedVersion
    var settings: Settings
    var scope: String
    var scopePlatform: Platform?
    var trim: TrimRange
    var maxBytes: Int64?
    var hash: String
  }

  /// Everything in the output file, canonically encoded for `editHash`.
  struct HashInput: Codable {
    struct Text: Codable {
      var text: String, style: String, size: Double, posX: Double, posY: Double, align: String
      var textStart: Double?, textEnd: Double?
    }
    var pipeline: String
    var source: String  // content fingerprint (rename-proof)
    var aspect: String
    var crop: CropRect?
    var trimStart: Double, trimEnd: Double
    var coverTime: Double?
    var coverIncludesText: Bool
    var text: Text?
    var loudnessTarget: Double, truePeak: Double, lra: Double
    var videoBitrateKbps: Int
    var maxBytes: Int64?
  }

  func plan(videoId: String, versionNo: Int, platform: Platform?) throws -> Plan {
    guard let video = try store.video(id: videoId) else { throw RenderError("Unknown video \(videoId)") }
    let settings = try store.settings()
    guard let version = try store.resolvedVersion(videoId: videoId, number: versionNo, settings: settings) else {
      throw RenderError("\(video.name) has no version \(versionNo)")
    }
    let edit = try store.edit(videoId: videoId)
    let scopePlatform = platform.flatMap { edit.platformTrims[$0] != nil ? $0 : nil }
    let scope = scopePlatform?.rawValue ?? "all"
    let trim = edit.trim(duration: video.duration, platform: scopePlatform)
    let maxBytes: Int64? = {
      func limit(_ p: Platform) -> Int64? { (settings.limits[p] ?? PlatformLimits.defaults[p])?.maxBytes }
      if let p = scopePlatform { return limit(p) }
      return settings.activePlatforms.compactMap(limit).min()
    }()
    let text: HashInput.Text? = version.hasText
      ? .init(text: version.text, style: version.style.rawValue, size: version.size, posX: version.posX,
              posY: version.posY, align: version.align.rawValue, textStart: version.textStart, textEnd: version.textEnd)
      : nil
    let input = HashInput(pipeline: Self.pipelineVersion, source: video.fingerprint ?? video.file,
                          aspect: edit.aspect.rawValue, crop: edit.crop, trimStart: trim.start, trimEnd: trim.end,
                          coverTime: edit.coverTime, coverIncludesText: edit.coverIncludesText && text != nil,
                          text: text, loudnessTarget: settings.loudnessTarget, truePeak: settings.truePeak,
                          lra: settings.lra, videoBitrateKbps: settings.videoBitrateKbps, maxBytes: maxBytes)
    let data = try JSONCoding.encoder.encode(input)
    let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    return Plan(video: video, edit: edit, version: version, settings: settings, scope: scope,
                scopePlatform: scopePlatform, trim: trim, maxBytes: maxBytes, hash: hash)
  }

  func current(_ p: Plan) throws -> Render? {
    try store.renders(where: "video_id=? AND version_no=? AND edit_hash=? AND scope=? AND status='done' AND deleted_at IS NULL",
                      [p.video.id, p.version.number, p.hash, p.scope])
      .last { r in r.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
  }

  func destinationDir(_ p: Plan) throws -> URL {
    if let outputRoot { return outputRoot }
    guard let s = try store.session(id: p.video.sessionId) else { throw RenderError("Session missing for \(p.video.name)") }
    return URL(fileURLWithPath: s.folder).appendingPathComponent("Ready to Post/Shortform")
  }

  // MARK: Pipeline

  struct Output {
    var file: URL
    var cover: URL?
    var probe: ProbeInfo
    var loudness: LoudnessInfo?
  }

  private static func tool(_ path: String?, _ name: String) throws -> String {
    guard let path else { throw RenderError("\(name) not found (expected in /opt/homebrew/bin)") }
    return path
  }

  private static func f(_ d: Double) -> String { String(format: "%.3f", d) }

  func perform(_ p: Plan, renderId: String) throws -> Output {
    let ffmpeg = try Self.tool(Tools.ffmpeg, "ffmpeg")
    guard let src = try store.fileURL(for: p.video), FileManager.default.fileExists(atPath: src.path) else {
      throw RenderError("Source file missing for \(p.video.name)")
    }
    guard let crop = p.edit.crop else { throw RenderError("No crop set for \(p.video.name)") }
    let info = try Media.probe(src)
    let start = max(0, p.trim.start)
    let end = min(p.trim.end, info.duration)
    let dur = end - start
    guard dur > 0.2 else { throw RenderError("Trim is empty (\(Self.f(start))–\(Self.f(end)) s)") }
    let (ow, oh) = p.edit.aspect.outputSize
    let rect = Media.pixelCrop(crop, sourceWidth: info.width, sourceHeight: info.height)

    let work = store.paths.work
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let overlayURL = work.appendingPathComponent("\(renderId).overlay.png")
    let tmpVideo = work.appendingPathComponent("\(renderId).mp4")
    let tmpCover = work.appendingPathComponent("\(renderId).jpg")
    defer {
      for u in [overlayURL, tmpVideo, tmpCover] { try? FileManager.default.removeItem(at: u) }
    }
    let hasText = try TextOverlay.write(for: p.version, aspect: p.edit.aspect, to: overlayURL)
    let progress = onProgress
    progress?(renderId, 0)

    // Pass 1: loudness analysis of the trimmed audio.
    var measured: [String: Double]?
    if info.hasAudio {
      let r = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-ss", Self.f(start), "-to", Self.f(end), "-i", src.path,
                                    "-map", "0:a:0", "-af", loudnormFilter(p.settings, measured: nil), "-f", "null", "-"])
      guard r.status == 0 else { throw RenderError("Loudness analysis failed: \(r.stderrTail)") }
      guard let m = Self.parseLoudnormJSON(r.stderr) else { throw RenderError("Loudness analysis returned no data") }
      // Digital silence measures -inf: keep the audio as is rather than normalising.
      if ["input_i", "input_tp", "input_lra", "input_thresh"].allSatisfy({ m[$0]?.isFinite == true }) { measured = m }
    }
    progress?(renderId, 0.05)

    // Pass 2: the render (re-encoded at a lower bitrate if it is over the platform size limit).
    let cropF = "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"
    let scaleF = "scale=\(ow):\(oh):flags=lanczos+accurate_rnd+full_chroma_int:out_color_matrix=bt709:out_range=tv"
    var videoGraph = "[0:v]\(cropF),\(scaleF),format=yuv420p,setsar=1"
    if hasText {
      let ts = max(0, p.version.textStart ?? 0)
      let te = min(dur + 1, p.version.textEnd ?? (dur + 1))
      videoGraph += "[bg];[1:v]format=rgba,scale=out_color_matrix=bt709:out_range=tv,format=yuva420p[ov];"
        + "[bg][ov]overlay=0:0:format=yuv420:eof_action=repeat:enable='between(t,\(Self.f(ts)),\(Self.f(te)))'"
    }
    videoGraph += ",format=yuv420p[v]"
    func graph(headroom: Double) -> String {
      guard info.hasAudio else { return videoGraph }
      let norm = measured.map { loudnormFilter(p.settings, measured: $0, headroom: headroom) + "," } ?? ""
      return videoGraph + ";[0:a:0]\(norm)aresample=48000[a]"
    }

    var kbps = p.settings.videoBitrateKbps
    var headroom = Self.truePeakHeadroom
    var probe: ProbeInfo
    var loudness: LoudnessInfo?
    var attempt = 0
    var hw = true
    while true {
      attempt += 1
      var args = ["-hide_banner", "-nostats", "-y"]
      if hw { args += ["-hwaccel", "videotoolbox"] }
      args += ["-ss", Self.f(start), "-to", Self.f(end), "-i", src.path]
      if hasText { args += ["-i", overlayURL.path] }
      args += ["-filter_complex", graph(headroom: headroom), "-map", "[v]"]
      if info.hasAudio { args += ["-map", "[a]"] }
      args += ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "\(kbps)k",
               "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k", "-g", "60",
               "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
               "-color_range", "tv"]
      if info.hasAudio { args += ["-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2"] }
      args += ["-map_metadata", "-1", "-map_chapters", "-1", "-movflags", "+faststart",
               "-progress", "pipe:1", tmpVideo.path]
      let lo = 0.05 + 0.85 * Double(attempt - 1) / Double(attempt), hi = 0.9
      let r = try Proc.run(ffmpeg, args) { line in
        guard let progress, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
              let us = Double(line.split(separator: "=").last ?? "") else { return }
        progress(renderId, lo + (hi - lo) * min(1, max(0, us / 1_000_000 / dur)))
      }
      if r.status != 0 {
        if hw { hw = false; attempt -= 1; continue }  // retry with software decode
        throw RenderError("ffmpeg failed: \(r.stderrTail)")
      }
      probe = try Media.probe(tmpVideo)
      try validate(probe, expected: dur, width: ow, height: oh, audio: info.hasAudio)
      if let max = p.maxBytes, probe.size > max {
        guard attempt < 4 else { throw RenderError("Render is \(probe.size) bytes, over the \(max)-byte limit") }
        let audioBytes = 256_000.0 / 8 * dur
        let budget = Double(max) * 0.92 - audioBytes
        let next = Int(budget * 8 / 1000 / dur)
        kbps = Swift.max(500, Swift.min(next, kbps * 9 / 10))
        Log.shared.info("render \(renderId): \(probe.size) B > limit \(max) B, re-encoding at \(kbps) kb/s")
        continue
      }
      if let m = measured {
        let outL = try Self.measureLoudness(tmpVideo)
        loudness = LoudnessInfo(inputI: m["input_i"] ?? .nan, inputTP: m["input_tp"] ?? .nan,
                                inputLRA: m["input_lra"] ?? .nan, outputI: outL.inputI, outputTP: outL.inputTP)
        // AAC can overshoot the limiter; if the encoded file misses the standard, retry once with more headroom.
        let missed = outL.inputTP > p.settings.truePeak + 0.1 || abs(outL.inputI - p.settings.loudnessTarget) > 0.5
        if missed, headroom < Self.truePeakHeadroom + 1, attempt < 4 {
          headroom += 1
          Log.shared.info(String(format: "render %@: output %.1f LUFS / %.1f dBTP, re-encoding with %.1f dB peak headroom",
                                 renderId, outL.inputI, outL.inputTP, headroom))
          continue
        }
      }
      break
    }
    progress?(renderId, 0.92)

    // Cover: built like the editor preview (AVFoundation frame → same pixel crop → scale → TextOverlay),
    // so it looks exactly like the frame Eric picked. ffmpeg fallback if AVFoundation can't decode.
    let coverAt = min(max(0, p.edit.coverTime ?? start), max(0, info.duration - 0.05))
    let coverOverlay = hasText && p.edit.coverIncludesText ? TextOverlay.image(for: p.version, aspect: p.edit.aspect) : nil
    var haveCover = false
    if let frame = Media.frame(src, at: coverAt, maxSize: .zero),
       let img = Media.compose(frame, crop: crop, aspect: p.edit.aspect, size: CGSize(width: ow, height: oh),
                               overlay: coverOverlay) {
      do { try Media.writeJPEG(img, to: tmpCover, quality: 0.92); haveCover = true } catch {
        Log.shared.warn("cover write failed for render \(renderId): \(error)")
      }
    }
    if !haveCover {
      var cArgs = ["-hide_banner", "-nostats", "-y", "-ss", Self.f(coverAt), "-i", src.path]
      var cGraph = "[0:v]\(cropF),scale=\(ow):\(oh):flags=lanczos+accurate_rnd+full_chroma_int,format=rgb24"
      if coverOverlay != nil {
        cArgs += ["-i", overlayURL.path]
        cGraph += "[bg];[1:v]format=rgba[ov];[bg][ov]overlay=0:0:format=rgb"
      }
      cGraph += ",format=yuvj420p[v]"
      cArgs += ["-filter_complex", cGraph, "-map", "[v]", "-frames:v", "1", "-q:v", "2", "-update", "1", tmpCover.path]
      let cr = try Proc.run(ffmpeg, cArgs)
      haveCover = cr.status == 0 && FileManager.default.fileExists(atPath: tmpCover.path)
      if !haveCover { Log.shared.warn("cover failed for render \(renderId): \(cr.stderrTail)") }
    }

    // Move into place atomically.
    let dir = try destinationDir(p)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = Self.outputName(video: p.video, versionNo: p.version.number, platform: p.scopePlatform)
    let dest = dir.appendingPathComponent(name)
    try place(tmpVideo, at: dest)
    var coverDest: URL?
    if haveCover {
      let c = dir.appendingPathComponent((name as NSString).deletingPathExtension + ".jpg")
      try place(tmpCover, at: c)
      coverDest = c
    }
    probe.size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? probe.size
    return Output(file: dest, cover: coverDest, probe: probe, loudness: loudness)
  }

  private func place(_ tmp: URL, at dest: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dest.path) {
      _ = try fm.replaceItemAt(dest, withItemAt: tmp)
    } else {
      try fm.moveItem(at: tmp, to: dest)
    }
  }

  func validate(_ p: ProbeInfo, expected dur: Double, width: Int, height: Int, audio: Bool) throws {
    var problems: [String] = []
    if p.videoCodec != "h264" { problems.append("codec \(p.videoCodec)") }
    if p.width != width || p.height != height { problems.append("size \(p.width)×\(p.height)") }
    if audio && !p.hasAudio { problems.append("no audio stream") }
    if abs(p.duration - dur) > 0.1 { problems.append(String(format: "duration %.3f s ≠ %.3f s", p.duration, dur)) }
    if p.size <= 0 { problems.append("empty file") }
    if !problems.isEmpty { throw RenderError("Render failed validation: " + problems.joined(separator: ", ")) }
  }

  /// The limiter aims this far below `Settings.truePeak`, because AAC encoding adds inter-sample peaks.
  static let truePeakHeadroom = 0.5

  func loudnormFilter(_ s: Settings, measured m: [String: Double]?, headroom: Double = Renderer.truePeakHeadroom) -> String {
    var f = "loudnorm=I=\(s.loudnessTarget):TP=\(s.truePeak - headroom):LRA=\(s.lra)"
    if let m {
      f += ":measured_I=\(m["input_i"]!):measured_TP=\(m["input_tp"]!):measured_LRA=\(m["input_lra"]!)"
        + ":measured_thresh=\(m["input_thresh"]!):offset=\(m["target_offset"] ?? 0):linear=true"
    }
    return f + ":print_format=json"
  }

  /// The JSON block loudnorm prints at the end of stderr (values are strings).
  static func parseLoudnormJSON(_ stderr: String) -> [String: Double]? {
    guard let open = stderr.range(of: "{", options: .backwards),
          let close = stderr.range(of: "}", options: .backwards), open.lowerBound < close.upperBound else { return nil }
    let json = String(stderr[open.lowerBound..<close.upperBound])
    guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
    var out: [String: Double] = [:]
    for (k, v) in obj {
      if let s = v as? String, let d = Double(s) { out[k] = d } else if let d = v as? Double { out[k] = d }
    }
    return out["input_i"] == nil ? nil : out
  }
}
