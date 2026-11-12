import CoreGraphics
import CryptoKit
import Foundation

public struct RenderError: Error, LocalizedError, CustomStringConvertible {
  public var message: String
  public init(_ m: String) { message = m }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Final-file renderer (spec §7): trim → crop (source px) → scale (lanczos) → one TextOverlay PNG per text
/// (`enable=between(t,…)`, chained in list order) → two-pass EBU R128 loudnorm → h264_videotoolbox / AAC → +faststart,
/// validated with ffprobe; plus a cover JPG. One render per (video, version, editHash, scope).
///
/// Round 21: a photo post renders through `PhotoRenderer` instead (one JPEG per photo, no ffmpeg, scope always "all");
/// every `RenderService` call branches on `Video.isPhoto` first, so video plans and hashes are untouched.
public final class Renderer: RenderService, @unchecked Sendable {
  public let store: Store
  /// Overrides the destination folder (proofs/tests). Default: `<session>/Ready to Post/Shortform/`.
  public let outputRoot: URL?
  /// (renderId, 0…1), called from a background thread while rendering.
  public var onProgress: (@Sendable (String, Double) -> Void)?

  /// Bump when the pipeline changes in a way that changes output files (invalidates every editHash).
  public static let pipelineVersion = "render-3"

  private let renderLock = NSLock()

  /// Test seam: runs before photo `index` of a photo render is moved into place (a failure here is a placing failure).
  var photoPlaceHook: ((Int) throws -> Void)?

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
    if try photoPost(videoId) != nil { return "all" }  // one set of files for every platform
    let edit = try store.edit(videoId: videoId)
    if let p = platform, edit.platformTrims[p] != nil { return p.rawValue }
    return "all"
  }

  /// The video row when it is a photo post (round 21), else nil.
  func photoPost(_ videoId: String) throws -> Video? {
    guard let v = try store.video(id: videoId), v.isPhoto else { return nil }
    return v
  }

  public func editHash(videoId: String, versionNo: Int, platform: Platform?) throws -> String {
    if let v = try photoPost(videoId) { return try photoPlan(v, versionNo: versionNo).hash }
    return try plan(videoId: videoId, versionNo: versionNo, platform: platform).hash
  }

  public func currentRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render? {
    if let v = try photoPost(videoId) { return try photoCurrent(try photoPlan(v, versionNo: versionNo)) }
    let p = try plan(videoId: videoId, versionNo: versionNo, platform: platform)
    return try current(p)
  }

  @discardableResult
  public func ensureRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render {
    renderLock.lock()
    defer { renderLock.unlock() }
    if let v = try photoPost(videoId) { return try ensurePhotoRender(v, versionNo: versionNo) }
    let p = try plan(videoId: videoId, versionNo: versionNo, platform: platform)
    if let r = try current(p) { return r }
    guard p.edit.crop != nil else {
      throw RenderError("Can't render \(p.video.name): no crop set. Set the crop in the editor first.")
    }
    // A good render exists but is over this platform's (lowered) size limit: make a smaller copy for
    // this platform as its own render (scope = platform), leaving the shared one untouched.
    var target = p
    var startKbps = p.settings.videoBitrateKbps
    if let requested = p.requested, let base = try liveDone(p, scope: p.scope).first, let size = base.size,
       let limit = p.useLimit, size > limit {
      target.scope = requested.rawValue
      target.namePlatform = requested
      target.maxBytes = limit
      startKbps = Swift.max(500, Int(Double(startKbps) * Double(limit) * 0.9 / Double(size)))
      try? store.logEvent("render", "\(p.video.name) v\(p.version.number) is \(size) B, over \(requested.displayName)'s "
                          + "\(limit)-byte limit: rendering a smaller copy at \(startKbps) kb/s", videoId: p.video.id)
    }
    let deadline = Date().addingTimeInterval(waitForOtherProcess)
    while true {
      let row = try candidateRow(target)
      if try acquireLock(row.id) {
        defer { releaseLock(row.id) }
        if let r = try current(p) { return r }  // another process finished it meanwhile
        try store.resetStaleRender(id: row.id)  // we hold the kernel lock, so a "rendering" row is orphaned
        guard try store.claimRender(id: row.id) else {
          throw RenderError("Render \(row.id) is being rendered elsewhere")
        }
        return try render(target, row: row, startKbps: startKbps)
      }
      // Another process (CLI or app) is rendering this exact row: wait for it.
      if Date() > deadline { throw RenderError("Timed out waiting for another process to render \(p.video.name)") }
      Thread.sleep(forTimeInterval: 0.25)
      if let r = try current(p) { return r }
    }
  }

  /// How long `ensureRender` waits for another process that holds the same render.
  var waitForOtherProcess: TimeInterval = 30 * 60

  /// Finished, live renders for (hash, scope) whose file exists, newest first.
  func liveDone(_ p: Plan, scope: String) throws -> [Render] {
    try store.renders(where: "video_id=? AND version_no=? AND edit_hash=? AND scope=? AND status='done' AND deleted_at IS NULL",
                      [p.video.id, p.version.number, p.hash, scope])
      .filter { r in r.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
      .reversed()
  }

  /// A live, unfinished row for this key, inserting a pending one if there is none (finished rows are
  /// never re-rendered in place, so a failed re-render can't lose a good file). Concurrent inserts
  /// converge on the oldest row.
  private func candidateRow(_ p: Plan) throws -> Render {
    try candidateRow(videoId: p.video.id, versionNo: p.version.number, hash: p.hash, scope: p.scope)
  }

  func candidateRow(videoId: String, versionNo: Int, hash: String, scope: String) throws -> Render {
    if let r = try store.renderRow(videoId: videoId, versionNo: versionNo, hash: hash, scope: scope) {
      return r
    }
    let mine = Render(id: newId(), videoId: videoId, versionNo: versionNo, editHash: hash, scope: scope,
                      outputPath: nil, coverPath: nil, loudness: nil, duration: nil, size: nil, status: .pending,
                      error: nil, createdAt: store.clock.now, deletedAt: nil)
    try store.save(mine)  // insert
    let winner = try store.renderRow(videoId: videoId, versionNo: versionNo, hash: hash, scope: scope) ?? mine
    if winner.id != mine.id { try store.markRenderDeleted(id: mine.id) }
    return winner
  }

  /// Renders a claimed row (status already `rendering`) and records the result. Older rows are
  /// retired only after success.
  private func render(_ p: Plan, row: Render, startKbps: Int) throws -> Render {
    do {
      let started = Date()
      let out = try perform(p, renderId: row.id, startKbps: startKbps)
      try store.finishRender(id: row.id, outputPath: out.file.path, coverPath: out.cover?.path, loudness: out.loudness,
                             duration: out.probe.duration, size: out.probe.size)
      // Rows whose file was just replaced (same name) or that this render supersedes (same key) are retired.
      for old in try store.renders(where: """
        deleted_at IS NULL AND id<>? AND (output_path=? OR (video_id=? AND version_no=? AND edit_hash=? AND scope=?))
        """, [row.id, out.file.path, p.video.id, p.version.number, p.hash, p.scope]) {
        try store.markRenderDeleted(id: old.id)
      }
      let secs = String(format: "%.1f", Date().timeIntervalSince(started))
      try? store.logEvent("render", "Rendered \(out.file.lastPathComponent) in \(secs) s"
                          + (out.loudness.map { String(format: " (%.1f → %.1f LUFS)", $0.inputI, $0.outputI ?? .nan) } ?? ""),
                          videoId: p.video.id)
      onProgress?(row.id, 1)
      guard let r = try store.render(id: row.id) else { throw RenderError("Render \(row.id) vanished") }
      return r
    } catch {
      try? store.setRenderStatus(id: row.id, status: .failed, error: "\(error)")
      try? store.logEvent("render_failed", "Render failed for \(p.video.name) v\(p.version.number): \(error)",
                          videoId: p.video.id)
      throw error
    }
  }

  // MARK: Cross-process lock: flock on <work>/<renderId>.lock (the kernel releases it if the process dies)

  private var lockFDs: [String: Int32] = [:]  // guarded by renderLock

  private func lockURL(_ id: String) -> URL { store.paths.work.appendingPathComponent("\(id).lock") }

  /// True when this process now holds the render's lock; false when another process holds it.
  func acquireLock(_ id: String) throws -> Bool {
    try FileManager.default.createDirectory(at: store.paths.work, withIntermediateDirectories: true)
    let fd = open(lockURL(id).path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw RenderError("Can't open render lock \(id).lock (errno \(errno))") }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      lockFDs[id] = fd
      return true
    }
    let e = errno
    close(fd)
    if e == EWOULDBLOCK { return false }
    throw RenderError("Can't lock render \(id) (errno \(e))")
  }

  /// Unlocks; the file stays (unlinking a lock file others may have open would split the lock).
  func releaseLock(_ id: String) {
    guard let fd = lockFDs.removeValue(forKey: id) else { return }
    flock(fd, LOCK_UN)
    close(fd)
  }

  /// Removes a deleted render's lock file if nobody holds it (deleted rows are never claimed again).
  private func removeLockFile(_ id: String) {
    let fd = open(lockURL(id).path, O_RDWR)
    guard fd >= 0 else { return }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      unlink(lockURL(id).path)
      flock(fd, LOCK_UN)
    }
    close(fd)
  }

  public func deleteRenders(except keep: Set<String>) throws {
    renderLock.lock()
    defer { renderLock.unlock() }
    let all = try store.renders()
    // Every file of a render: a photo post's has one per photo (`morePaths`).
    func files(_ r: Render) -> [String] { r.allPaths + [r.coverPath].compactMap { $0 } }
    let keptPaths = Set(all.filter { keep.contains($0.id) || $0.status == .rendering }.flatMap(files))
    for r in all where !keep.contains(r.id) && r.status != .rendering {
      for path in files(r) where !keptPaths.contains(path) {
        let url = URL(fileURLWithPath: path)
        if isAppOutput(url) { try? FileManager.default.removeItem(at: url) }
      }
      try store.markRenderDeleted(id: r.id)
      removeLockFile(r.id)
    }
  }

  /// Only files this app creates: `…/Ready to Post/Shortform/<file>` (or inside `outputRoot`).
  /// Round 21: the folder must also be inside this store's DJ Video root. A database copied from somewhere else can
  /// name any path; a process only ever deletes under the root it was started with.
  func isAppOutput(_ url: URL) -> Bool {
    let dir = url.deletingLastPathComponent()
    if dir.lastPathComponent == "Shortform", dir.deletingLastPathComponent().lastPathComponent == "Ready to Post" {
      return store.paths.owns(url)
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
                                  "-af", "ebur128=peak=true", "-f", "null", "-"], timeout: 900)
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
    var edit: ResolvedEdit
    var version: ResolvedVersion
    var settings: Settings
    var scope: String
    var scopePlatform: Platform?
    /// The platform the caller asked for (size limits are checked against it at use time).
    var requested: Platform?
    /// Platform suffix of the output file name.
    var namePlatform: Platform?
    var trim: TrimRange
    /// Size limit for a new encode (scope platform, or the smallest among active platforms for "all").
    var maxBytes: Int64?
    /// Size limit an existing render must meet to be used for `requested` (nil = no check).
    var useLimit: Int64?
    var hash: String
  }

  /// Everything in the output file, canonically encoded for `editHash`.
  struct HashInput: Codable {
    struct Text: Codable {
      var text: String, style: String, size: Double, posX: Double, posY: Double, align: String
      var textStart: Double?, textEnd: Double?
      /// nil (and absent from the JSON) for today's look, so an existing hash can't change.
      var look: TextLook? = nil
      /// Round 26: nil (absent) for every text but a countdown, same reason.
      var countdown: Int? = nil

      init(_ l: TextLayer) {
        text = l.text; style = l.style.rawValue; size = l.size; posX = l.posX; posY = l.posY; align = l.align.rawValue
        textStart = l.start; textEnd = l.end; look = l.look?.normalized; countdown = l.countdown
      }
    }
    var pipeline: String
    var source: String  // content fingerprint (rename-proof)
    var aspect: String
    var crop: CropRect?
    var trimStart: Double, trimEnd: Double
    var coverTime: Double?
    var coverIncludesText: Bool
    var text: Text?
    /// Every drawn text after the first. nil (and absent from the JSON) when there are none, same reason as `look`.
    var moreText: [Text]? = nil
    var loudnessTarget: Double, truePeak: Double, lra: Double
    var videoBitrateKbps: Int
  }

  func plan(videoId: String, versionNo: Int, platform: Platform?) throws -> Plan {
    guard let video = try store.video(id: videoId) else { throw RenderError("Unknown video \(videoId)") }
    let settings = try store.settings()
    guard let version = try store.resolvedVersion(videoId: videoId, number: versionNo, settings: settings) else {
      throw RenderError("\(video.name) has no version \(versionNo)")
    }
    let raw = try store.edit(videoId: videoId)
    // Only a confirmed crop renders (the default anchor crop is a suggestion until Eric confirms it).
    var edit = EditResolver.resolve(raw, video: video, defaults: settings.defaults)
    if !edit.cropConfirmed { edit.crop = nil }
    let scopePlatform = platform.flatMap { edit.platformTrims[$0] != nil ? $0 : nil }
    let scope = scopePlatform?.rawValue ?? "all"
    // Resolved trim: Eric's markers (± default extra seconds) unless the clip overrides it; the hash follows it.
    let trim = edit.trim(platform: scopePlatform)
    let maxBytes: Int64? = {
      func limit(_ p: Platform) -> Int64? { (settings.limits[p] ?? PlatformLimits.defaults[p])?.maxBytes }
      if let p = scopePlatform { return limit(p) }
      return settings.activePlatforms.compactMap(limit).min()
    }()
    let text: HashInput.Text? = version.hasText ? .init(version.firstLayer) : nil
    let more = version.layers.filter { $0.id != TextLayer.firstId }.map(HashInput.Text.init)
    let input = HashInput(pipeline: Self.pipelineVersion, source: video.fingerprint ?? video.file,
                          aspect: edit.aspect.rawValue, crop: edit.crop, trimStart: trim.start, trimEnd: trim.end,
                          coverTime: edit.coverTime, coverIncludesText: edit.coverIncludesText && version.hasDrawnText,
                          text: text, moreText: more.isEmpty ? nil : more, loudnessTarget: settings.loudnessTarget,
                          truePeak: settings.truePeak, lra: settings.lra, videoBitrateKbps: settings.videoBitrateKbps)
    let data = try JSONCoding.encoder.encode(input)
    let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    return Plan(video: video, edit: edit, version: version, settings: settings, scope: scope,
                scopePlatform: scopePlatform, requested: platform, namePlatform: scopePlatform, trim: trim,
                maxBytes: maxBytes,
                useLimit: platform.flatMap { (settings.limits[$0] ?? PlatformLimits.defaults[$0])?.maxBytes }, hash: hash)
  }

  /// The render to use: the shared/scope render, or — when that is over the requested platform's size
  /// limit — that platform's smaller copy. Files that already left Ready to Post are never size-checked.
  func current(_ p: Plan) throws -> Render? {
    var rows = try liveDone(p, scope: p.scope)
    if let r = p.requested, r.rawValue != p.scope { rows += try liveDone(p, scope: r.rawValue) }
    return rows.first { r in
      guard let limit = p.useLimit, let size = r.size, size > limit else { return true }
      return !isAppOutput(URL(fileURLWithPath: r.outputPath!))
    }
  }

  func destinationDir(_ p: Plan) throws -> URL { try destinationDir(p.video) }

  func destinationDir(_ video: Video) throws -> URL {
    if let outputRoot { return outputRoot }
    guard let s = try store.session(id: video.sessionId) else { throw RenderError("Session missing for \(video.name)") }
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

  /// Appended to the picture chain: PNG input `i + 1` over it during `windows[i]`, each over the last, so overlaps stack
  /// in list order. Empty with no texts. The chain ends without an output label, and with one text this is the graph
  /// every earlier render used.
  static func overlayGraph(_ windows: [ClosedRange<Double>]) -> String {
    guard !windows.isEmpty else { return "" }
    var inputs = "", chain = "", below = "bg"
    for (i, w) in windows.enumerated() {
      let ov = i == 0 ? "ov" : "ov\(i)"
      inputs += "[\(i + 1):v]format=rgba,scale=out_color_matrix=bt709:out_range=tv,format=yuva420p[\(ov)];"
      chain += "[\(below)][\(ov)]overlay=0:0:format=yuv420:eof_action=repeat"
        + ":enable='between(t,\(f(w.lowerBound)),\(f(w.upperBound)))'"
      if i < windows.count - 1 {
        below = "o\(i)"
        chain += "[\(below)];"
      }
    }
    return "[bg];" + inputs + chain
  }

  func perform(_ p: Plan, renderId: String, startKbps: Int? = nil) throws -> Output {
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
    if let problem = Media.cropProblem(crop, aspect: p.edit.aspect, sourceWidth: info.width, sourceHeight: info.height) {
      throw RenderError("Can't render \(p.video.name): \(problem)")
    }
    let rect = Media.pixelCrop(crop, sourceWidth: info.width, sourceHeight: info.height)
    let timeout = max(120, 10 * dur)

    let work = store.paths.work
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let tmpBase = "\(renderId)-\(getpid())"  // unique per render and process
    // One PNG per text showing in this trim, stacked in list order (the one window rule, shared with every preview).
    let shown = PreviewKeys.layerWindows(p.version, trimDuration: dur)
    let overlayURLs = shown.indices.map { work.appendingPathComponent("\(tmpBase).overlay\($0).png") }
    let coverOverlayURL = work.appendingPathComponent("\(tmpBase).cover-overlay.png")
    let tmpVideo = work.appendingPathComponent("\(tmpBase).mp4")
    let tmpCover = work.appendingPathComponent("\(tmpBase).jpg")
    defer {
      for u in overlayURLs + [coverOverlayURL, tmpVideo, tmpCover] { try? FileManager.default.removeItem(at: u) }
    }
    var inputs: [URL] = [], windows: [ClosedRange<Double>] = []
    for (i, s) in shown.enumerated() where try TextOverlay.write(for: s.layer, aspect: p.edit.aspect, to: overlayURLs[i]) {
      inputs.append(overlayURLs[i])
      windows.append(s.window)
    }
    let progress = onProgress
    progress?(renderId, 0)

    // Pass 1: loudness analysis of the trimmed audio.
    var measured: [String: Double]?
    if info.hasAudio {
      let r = try Proc.run(ffmpeg, ["-hide_banner", "-nostats", "-ss", Self.f(start), "-to", Self.f(end), "-i", src.path,
                                    "-map", "0:a:0", "-af", loudnormFilter(p.settings, measured: nil), "-f", "null", "-"],
                           timeout: timeout)
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
    videoGraph += Self.overlayGraph(windows) + ",format=yuv420p[v]"
    func graph(headroom: Double) -> String {
      guard info.hasAudio else { return videoGraph }
      let norm = measured.map { loudnormFilter(p.settings, measured: $0, headroom: headroom) + "," } ?? ""
      return videoGraph + ";[0:a:0]\(norm)aresample=48000[a]"
    }

    var kbps = startKbps ?? p.settings.videoBitrateKbps
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
      for u in inputs { args += ["-i", u.path] }
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
      let r = try Proc.run(ffmpeg, args, timeout: timeout) { line in
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
    let coverAt = min(max(0, p.edit.coverTime), max(0, info.duration - 0.05))
    // The shared cover composite (S6): list covers are this same composite at list size. Its texts are the ones
    // showing at the cover frame, else the first text (S1-R6).
    let coverLayers = p.edit.coverIncludesText ? PreviewKeys.coverLayers(p.version, offset: coverAt - start, trimDuration: dur) : []
    var haveCover = false
    if let frame = Media.frame(src, at: coverAt, maxSize: .zero),
       let img = Media.coverComposite(frame, crop: crop, aspect: p.edit.aspect, size: CGSize(width: ow, height: oh),
                                      layers: coverLayers) {
      do { try Media.writeJPEG(img, to: tmpCover, quality: 0.92); haveCover = true } catch {
        Log.shared.warn("cover write failed for render \(renderId): \(error)")
      }
    }
    if !haveCover {
      var cArgs = ["-hide_banner", "-nostats", "-y", "-ss", Self.f(coverAt), "-i", src.path]
      var cGraph = "[0:v]\(cropF),scale=\(ow):\(oh):flags=lanczos+accurate_rnd+full_chroma_int,format=rgb24"
      if let stack = TextOverlay.image(for: coverLayers, aspect: p.edit.aspect) {
        try Media.writePNG(stack, to: coverOverlayURL)
        cArgs += ["-i", coverOverlayURL.path]
        cGraph += "[bg];[1:v]format=rgba[ov];[bg][ov]overlay=0:0:format=rgb"
      }
      cGraph += ",format=yuvj420p[v]"
      cArgs += ["-filter_complex", cGraph, "-map", "[v]", "-frames:v", "1", "-q:v", "2", "-update", "1", tmpCover.path]
      let cr = try Proc.run(ffmpeg, cArgs, timeout: 120)
      haveCover = cr.status == 0 && FileManager.default.fileExists(atPath: tmpCover.path)
      if !haveCover { Log.shared.warn("cover failed for render \(renderId): \(cr.stderrTail)") }
    }

    // Move into place atomically.
    let dir = try destinationDir(p)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = Self.outputName(video: p.video, versionNo: p.version.number, platform: p.namePlatform)
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

  func place(_ tmp: URL, at dest: URL) throws {
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
