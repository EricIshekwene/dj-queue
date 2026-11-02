import CoreGraphics
import CryptoKit
import Foundation

/// What a proxy covers: the resolved trim (what will be posted) or the whole clip file.
public enum ProxyRange: String, Codable, Sendable, CaseIterable { case trim, wholeFile }

/// Proxy generation priority: visible tiles first, then background prefetch.
public enum ProxyPriority: Int, Comparable, Sendable {
  case background = 0, visible = 1
  public static func < (a: ProxyPriority, b: ProxyPriority) -> Bool { a.rawValue < b.rawValue }
}

extension Media {
  /// Proxy width; height follows the clip's aspect (540×960 for 9:16).
  public static let proxyWidth = 540

  /// The source picture size (cached on the video row after the first probe).
  public static func sourceSize(store: Store, video: Video) -> CGSize? {
    if let w = video.sourceWidth, let h = video.sourceHeight, w > 0, h > 0 { return CGSize(width: w, height: h) }
    guard let url = try? store.fileURL(for: video), FileManager.default.fileExists(atPath: url.path),
          let info = try? probe(url), info.width > 0, info.height > 0 else { return nil }
    try? store.setSourceSize(video.id, width: info.width, height: info.height)
    return CGSize(width: info.width, height: info.height)
  }

  /// Cache file for a clip's proxy (whether or not it exists yet). The key covers video, source fingerprint,
  /// crop (confirmed, or the default anchor), aspect and range — a changed crop/trim makes a new proxy.
  public static func proxyURL(store: Store, video: Video, range: ProxyRange = .trim) throws -> URL {
    let (crop, aspect, trim) = try proxyGeometry(store: store, video: video, range: range)
    let key = [video.id, video.fingerprint ?? video.file, crop.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "centre",
               aspect.rawValue, range.rawValue, String(format: "%.3f-%.3f", trim.start, trim.end)].joined(separator: "|")
    let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return store.paths.proxies.appendingPathComponent("\(video.id)-\(range.rawValue)-\(hash).mp4")
  }

  /// The cached proxy if it exists (never generates).
  public static func cachedProxy(store: Store, video: Video, range: ProxyRange = .trim) -> URL? {
    guard let u = try? proxyURL(store: store, video: video, range: range), FileManager.default.fileExists(atPath: u.path)
    else { return nil }
    return u
  }

  /// A small H.264 preview (540 px wide, e.g. 540×960) of the clip with its crop (confirmed, else the default
  /// anchor — centre unless Settings say otherwise), cached in `<app support>/proxies/`. Blocking; call off the
  /// main thread (`ProxyService` does). Older proxies of the same clip and range are removed.
  @discardableResult
  public static func ensureProxy(store: Store, video: Video, range: ProxyRange = .trim) throws -> URL {
    let fm = FileManager.default
    let url = try proxyURL(store: store, video: video, range: range)
    if fm.fileExists(atPath: url.path) { return url }
    guard let ffmpeg = Tools.ffmpeg else { throw MediaError("ffmpeg not found (install with Homebrew)") }
    guard let src = try store.fileURL(for: video), fm.fileExists(atPath: src.path) else {
      throw MediaError("Source file missing for \(video.name)")
    }
    let info = try probe(src)
    if video.sourceWidth == nil { try? store.setSourceSize(video.id, width: info.width, height: info.height) }
    var v = video
    v.sourceWidth = info.width; v.sourceHeight = info.height
    let (cropOpt, aspect, trim) = try proxyGeometry(store: store, video: v, range: range)
    let crop = cropOpt ?? centredCrop(aspect: aspect, sourceWidth: info.width, sourceHeight: info.height)
    let rect = pixelCrop(crop, sourceWidth: info.width, sourceHeight: info.height)
    let w = proxyWidth
    let h = Int((Double(w) / aspect.ratio / 2).rounded()) * 2
    let start = max(0, trim.start), end = min(trim.end > 0 ? trim.end : info.duration, info.duration)
    guard end - start > 0.05 else { throw MediaError("Empty range for \(video.name)'s proxy") }
    try fm.createDirectory(at: store.paths.proxies, withIntermediateDirectories: true)
    let tmp = store.paths.proxies.appendingPathComponent(".\(UUID().uuidString).mp4")
    defer { try? fm.removeItem(at: tmp) }
    let vf = "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY)),scale=\(w):\(h):flags=bicubic,format=yuv420p,setsar=1"
    func args(hw: Bool) -> [String] {
      var a = ["-hide_banner", "-nostats", "-y", "-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end),
               "-i", src.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", vf]
      a += hw ? ["-c:v", "h264_videotoolbox", "-b:v", "1500k"] : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "26"]
      a += ["-g", "30", "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-map_metadata", "-1", "-movflags", "+faststart", tmp.path]
      return a
    }
    var r = try Proc.run(ffmpeg, args(hw: true), timeout: max(120, 4 * (end - start)))
    if r.status != 0 { r = try Proc.run(ffmpeg, args(hw: false), timeout: max(120, 8 * (end - start))) }
    guard r.status == 0, fm.fileExists(atPath: tmp.path) else { throw MediaError("proxy failed for \(video.name): \(r.stderrTail)") }
    // Keep one proxy per clip and range.
    let prefix = "\(video.id)-\(range.rawValue)-"
    for f in (try? fm.contentsOfDirectory(atPath: store.paths.proxies.path)) ?? [] where f.hasPrefix(prefix) {
      try? fm.removeItem(at: store.paths.proxies.appendingPathComponent(f))
    }
    try fm.moveItem(at: tmp, to: url)
    return url
  }

  static func proxyGeometry(store: Store, video: Video, range: ProxyRange) throws -> (CropRect?, Aspect, TrimRange) {
    // The default crop needs the source size: use the cached one, else probe once (then it is cached).
    let re = try store.resolvedEdit(videoId: video.id, sourceSize: sourceSize(store: store, video: video))
    let trim = range == .trim ? re.trim() : TrimRange(start: 0, end: video.duration)
    return (re.crop, re.aspect, trim)
  }
}

/// Background proxy generation for the UI (and anything else): one serial worker, visible items first.
/// `request` is cheap to call repeatedly (a queued or cached item is not queued twice); `completion` runs on the
/// worker thread.
public final class ProxyService: @unchecked Sendable {
  public typealias Completion = @Sendable (Result<URL, Error>) -> Void

  struct Job { var videoId: String; var range: ProxyRange; var priority: ProxyPriority; var seq: Int; var completions: [Completion] }

  let store: Store
  private let lock = NSLock()
  private var jobs: [String: Job] = [:]
  private var running: String?
  private var seq = 0
  private var stopped = false
  private let worker = DispatchQueue(label: "com.djlovd.queue.proxies", qos: .utility)
  /// The generator (tests replace it). Default: `Media.ensureProxy`.
  public var make: @Sendable (Store, Video, ProxyRange) throws -> URL = { try Media.ensureProxy(store: $0, video: $1, range: $2) }

  public init(store: Store) { self.store = store }

  private func key(_ id: String, _ r: ProxyRange) -> String { "\(id)|\(r.rawValue)" }

  /// The cached proxy, if any (non-blocking, never generates).
  public func cachedProxy(videoId: String, range: ProxyRange = .trim) -> URL? {
    guard let v = try? store.video(id: videoId) else { return nil }
    return Media.cachedProxy(store: store, video: v, range: range)
  }

  /// Queues a proxy (raising its priority if already queued). Cached proxies complete immediately.
  public func request(_ videoId: String, priority: ProxyPriority = .visible, range: ProxyRange = .trim,
                      completion: Completion? = nil) {
    if let u = cachedProxy(videoId: videoId, range: range) { completion?(.success(u)); return }
    let k = key(videoId, range)
    lock.withLock {
      guard !stopped else { return }
      seq += 1
      if var j = jobs[k] {
        j.priority = max(j.priority, priority)
        if priority == .visible { j.seq = seq }  // most recently shown first
        if let c = completion { j.completions.append(c) }
        jobs[k] = j
      } else {
        jobs[k] = Job(videoId: videoId, range: range, priority: priority, seq: seq, completions: completion.map { [$0] } ?? [])
      }
    }
    pump()
  }

  /// Marks these clips as the visible ones: they move to the front; other queued visible items drop to background.
  public func setVisible(_ ids: [String], range: ProxyRange = .trim) {
    lock.withLock {
      for (k, var j) in jobs where j.priority == .visible && !ids.contains(j.videoId) { j.priority = .background; jobs[k] = j }
    }
    for id in ids.reversed() { request(id, priority: .visible, range: range) }
  }

  /// Drops queued (not running) jobs.
  public func cancelAll() { lock.withLock { jobs = jobs.filter { $0.key == running } } }

  public func stop() { lock.withLock { stopped = true; jobs = jobs.filter { $0.key == running } } }

  public var pendingCount: Int { lock.withLock { jobs.count } }

  private func pump() {
    worker.async { [weak self] in self?.drain() }
  }

  private func drain() {
    while true {
      let next: (String, Job)? = lock.withLock {
        guard running == nil, !stopped,
              let best = jobs.max(by: { ($0.value.priority, $0.value.seq) < ($1.value.priority, $1.value.seq) }) else { return nil }
        running = best.key
        return (best.key, best.value)
      }
      guard let (k, job) = next else { return }
      let result: Result<URL, Error>
      do {
        guard let v = try store.video(id: job.videoId) else { throw MediaError("No video \(job.videoId)") }
        result = .success(try make(store, v, job.range))
      } catch {
        result = .failure(error)
        Log.shared.warn("proxy \(job.videoId): \(error)")
      }
      let completions: [Completion] = lock.withLock {
        running = nil
        return jobs.removeValue(forKey: k)?.completions ?? job.completions
      }
      for c in completions { c(result) }
    }
  }
}
