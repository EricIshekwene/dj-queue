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
  /// A photo post answers with its first photo's size and is never probed (round 21).
  public static func sourceSize(store: Store, video: Video) -> CGSize? {
    if let photos = video.photos { return photos.first.map { CGSize(width: $0.width, height: $0.height) } }
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
    guard !video.isPhoto, let u = try? proxyURL(store: store, video: video, range: range), FileManager.default.fileExists(atPath: u.path)
    else { return nil }
    return u
  }

  /// A photo post has nothing to play: lists and the editor show `PhotoRenderer.preview` / `Media.thumbnail` instead.
  static let noProxyForPhotos = "Photo posts have no preview video"

  /// Longest one ffmpeg proxy encode may run (per attempt) before it is stopped.
  public static let proxyTimeout: TimeInterval = 120

  /// A small H.264 preview (540 px wide, e.g. 540×960) of the clip with its crop (confirmed, else the default
  /// anchor — centre unless Settings say otherwise), cached in `<app support>/proxies/`. Blocking; call off the
  /// main thread (`ProxyService` does). Older proxies of the same clip and range are removed.
  ///
  /// Cross-process safe: a per-clip+range `flock` (`proxies/<id>-<range>.lock`, released by the kernel if the
  /// process dies) means the app and the engine/CLI never encode the same proxy at once — the second one waits,
  /// then returns the finished file.
  @discardableResult
  public static func ensureProxy(store: Store, video: Video, range: ProxyRange = .trim,
                                 timeout: TimeInterval = proxyTimeout) throws -> URL {
    let fm = FileManager.default
    guard !video.isPhoto else { throw MediaError(noProxyForPhotos) }
    let url = try proxyURL(store: store, video: video, range: range)
    if fm.fileExists(atPath: url.path) { return url }
    try fm.createDirectory(at: store.paths.proxies, withIntermediateDirectories: true)
    let lockPath = store.paths.proxies.appendingPathComponent(".\(video.id)-\(range.rawValue).lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw MediaError("Can't open proxy lock (errno \(errno))") }
    defer { flock(fd, LOCK_UN); close(fd) }
    let deadline = Date().addingTimeInterval(2 * timeout + 30)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR else { throw MediaError("Can't lock proxy (errno \(errno))") }
      guard Date() < deadline else { throw MediaError("Timed out waiting for another process's proxy of \(video.name)") }
      Thread.sleep(forTimeInterval: 0.2)
    }
    // Another process may have finished it while we waited.
    let url2 = try proxyURL(store: store, video: (try? store.video(id: video.id)) ?? video, range: range)
    if fm.fileExists(atPath: url2.path) { return url2 }
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
    var r = try Proc.run(ffmpeg, args(hw: true), timeout: timeout)
    if r.status != 0 { r = try Proc.run(ffmpeg, args(hw: false), timeout: timeout) }
    guard r.status == 0, fm.fileExists(atPath: tmp.path) else { throw MediaError("proxy failed for \(video.name): \(r.stderrTail)") }
    // Keep one proxy per clip and range.
    let prefix = "\(video.id)-\(range.rawValue)-"
    for f in (try? fm.contentsOfDirectory(atPath: store.paths.proxies.path)) ?? [] where f.hasPrefix(prefix) && f.hasSuffix(".mp4") {
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

/// Background proxy generation (UI tiles and the engine): ONE serial worker queue of its own, visible items first,
/// background items paused while `shouldPause()` (the engine sets it to "a render is running"). `request` only
/// queues (never probes or encodes on the caller's thread); `completion` runs on the worker.
///
/// A background job that fails records `proxyFail.<video id>` = the proxy's cache name, so background requests
/// skip that clip until its crop/trim/file changes; visible requests always try.
public final class ProxyService: @unchecked Sendable {
  public typealias Completion = @Sendable (Result<URL, Error>) -> Void

  struct Job { var videoId: String; var range: ProxyRange; var priority: ProxyPriority; var seq: Int; var completions: [Completion] }

  let store: Store
  private let lock = NSLock()
  private var jobs: [String: Job] = [:]
  /// Requests that arrived while the same clip+range was encoding: they run after it (S6 review M1), because the
  /// running encode read its crop/trim before the request and may hand back an older-geometry proxy.
  private var followUps: [String: Job] = [:]
  private var running: String?
  private var draining = false
  private var seq = 0
  private var stopped = false
  private let worker = DispatchQueue(label: "com.djlovd.queue.proxies", qos: .utility)
  /// The generator (tests replace it). Default: `Media.ensureProxy` (per-proxy flock + ffmpeg timeout).
  public var make: @Sendable (Store, Video, ProxyRange) throws -> URL = { try Media.ensureProxy(store: $0, video: $1, range: $2) }
  /// Background jobs wait while this returns true (checked between jobs).
  public var shouldPause: @Sendable () -> Bool = { false }

  public init(store: Store) { self.store = store }

  private func key(_ id: String, _ r: ProxyRange) -> String { "\(id)|\(r.rawValue)" }

  /// The cached proxy, if any (never generates; may probe the source once if its size isn't cached yet).
  public func cachedProxy(videoId: String, range: ProxyRange = .trim) -> URL? {
    guard let v = try? store.video(id: videoId) else { return nil }
    return Media.cachedProxy(store: store, video: v, range: range)
  }

  /// Queues a proxy (raising its priority if already queued). Returns immediately.
  public func request(_ videoId: String, priority: ProxyPriority = .visible, range: ProxyRange = .trim,
                      completion: Completion? = nil) {
    let k = key(videoId, range)
    lock.withLock {
      guard !stopped else { return }
      seq += 1
      if k == running {
        var j = followUps[k] ?? Job(videoId: videoId, range: range, priority: priority, seq: seq, completions: [])
        j.priority = max(j.priority, priority)
        if priority == .visible { j.seq = seq }
        if let c = completion { j.completions.append(c) }
        followUps[k] = j
      } else if var j = jobs[k] {
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
  public func cancelAll() { lock.withLock { jobs = jobs.filter { $0.key == running }; followUps = [:] } }

  public func stop() { lock.withLock { stopped = true; jobs = jobs.filter { $0.key == running }; followUps = [:] } }

  public var pendingCount: Int { lock.withLock { jobs.count + followUps.count } }
  public var isBusy: Bool { lock.withLock { running != nil } }

  static func failKey(_ id: String) -> String { "proxyFail.\(id)" }

  private func pump() {
    let go: Bool = lock.withLock {
      if draining { return false }
      draining = true
      return true
    }
    if go { worker.async { [weak self] in self?.drain() } }
  }

  private func drain() {
    while true {
      let next: (String, Job)? = lock.withLock {
        guard !stopped else { draining = false; return nil }
        let paused = shouldPause()
        let candidates = jobs.filter { !paused || $0.value.priority == .visible }
        guard let best = candidates.max(by: { ($0.value.priority, $0.value.seq) < ($1.value.priority, $1.value.seq) }) else {
          if jobs.isEmpty { draining = false }
          return nil
        }
        running = best.key
        return (best.key, best.value)
      }
      guard let (k, job) = next else {
        // Only paused background work left: look again shortly.
        if lock.withLock({ draining }) { Thread.sleep(forTimeInterval: 1); continue }
        return
      }
      let result: Result<URL, Error>
      do {
        guard let v = try store.video(id: job.videoId) else { throw MediaError("No video \(job.videoId)") }
        if v.isPhoto {
          result = .failure(MediaError(Media.noProxyForPhotos))  // no encode, and no failure recorded against the post
        } else if let u = Media.cachedProxy(store: store, video: v, range: job.range) {
          result = .success(u)
        } else if job.priority == .background, let name = try? Media.proxyURL(store: store, video: v, range: job.range).lastPathComponent,
                  let last: String = try store.kv(Self.failKey(v.id)), last == name {
          result = .failure(MediaError("proxy for \(v.id) failed before; not retried until its crop/trim/file changes"))
        } else {
          do {
            result = .success(try make(store, v, job.range))
          } catch {
            if let name = try? Media.proxyURL(store: store, video: v, range: job.range).lastPathComponent {
              try? store.setKV(Self.failKey(v.id), name)
            }
            Log.shared.warn("proxy \(job.videoId): \(error)")
            throw error
          }
        }
      } catch {
        result = .failure(error)
      }
      let completions: [Completion] = lock.withLock {
        running = nil
        let done = jobs.removeValue(forKey: k)?.completions ?? job.completions
        if let next = followUps.removeValue(forKey: k), !stopped { jobs[k] = next }  // runs next (re-reads the edit)
        return done
      }
      for c in completions { c(result) }
    }
  }
}
