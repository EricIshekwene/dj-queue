import CryptoKit
import Foundation
@testable import DJQCore

/// Renders nothing real: writes a small placeholder mp4 + cover into the session's Ready to Post/Shortform.
final class FakeRenderer: RenderService, @unchecked Sendable {
  let store: Store
  private let lock = NSLock()
  private(set) var renderCount = 0
  var failNext = false
  var failVideos: Set<String> = []
  private(set) var attempts: [String] = []

  init(store: Store) { self.store = store }

  func editHash(videoId: String, versionNo: Int, platform: Platform?) throws -> String {
    let e = try store.edit(videoId: videoId)
    let v = try store.resolvedVersion(videoId: videoId, number: versionNo)
    let s = JSONCoding.string(e) + JSONCoding.string(v) + (try scope(videoId: videoId, platform: platform))
    return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func scope(videoId: String, platform: Platform?) throws -> String {
    guard let p = platform, try store.edit(videoId: videoId).platformTrims[p] != nil else { return "all" }
    return p.rawValue
  }

  func currentRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render? {
    let h = try editHash(videoId: videoId, versionNo: versionNo, platform: platform)
    let sc = try scope(videoId: videoId, platform: platform)
    return try store.renders(where: "deleted_at IS NULL AND status='done' AND video_id=? AND version_no=? AND edit_hash=? AND scope=?",
                             [videoId, versionNo, h, sc]).last
  }

  func ensureRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render {
    if let r = try currentRender(videoId: videoId, versionNo: versionNo, platform: platform) { return r }
    attempts.append(videoId)
    if failNext { failNext = false; throw EngineError("fake ffmpeg failure") }
    if failVideos.contains(videoId) { throw EngineError("fake ffmpeg failure for \(videoId)") }
    let v = try store.video(id: videoId)!
    let folder = URL(fileURLWithPath: try store.session(id: v.sessionId)!.folder).appendingPathComponent("Ready to Post/Shortform")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let sc = try scope(videoId: videoId, platform: platform)
    let name = "\(v.name) – v\(versionNo)\(sc == "all" ? "" : " – \(sc)")"
    let out = folder.appendingPathComponent(name + ".mp4"), cover = folder.appendingPathComponent(name + ".jpg")
    try Data("render".utf8).write(to: out)
    try Data("cover".utf8).write(to: cover)
    let r = Render(id: newId(), videoId: videoId, versionNo: versionNo,
                   editHash: try editHash(videoId: videoId, versionNo: versionNo, platform: platform), scope: sc,
                   outputPath: out.path, coverPath: cover.path, loudness: nil, duration: v.duration, size: 6,
                   status: .done, error: nil, createdAt: store.clock.now, deletedAt: nil)
    try store.save(r)
    lock.withLock { renderCount += 1 }
    return r
  }

  private(set) var lastKeep: Set<String>?

  func deleteRenders(except keep: Set<String>) throws {
    lastKeep = keep
    for r in try store.renders() where !keep.contains(r.id) { try store.markRenderDeleted(id: r.id) }
  }
}

extension Fixture {
  /// `n` clips of 20 s, 21 s, … with tags "song<i> x mix<i>"; intake done.
  static func engine(_ n: Int = 8, ready: Int? = nil, scores: [Int]? = nil) throws -> Fixture {
    let clips = (0..<n).map { (tag: "song\($0) x mix\($0)", duration: 20.0 + Double($0)) }
    let f = try Fixture(clips: clips)
    try f.intake()
    for i in 0..<(ready ?? n) { try f.makeReady("clip-\(i)", score: scores?[i] ?? 10 * (i + 1)) }
    return f
  }

  /// Crop + v1 text + caption template, and a score → state ready.
  func makeReady(_ id: String, score: Int?) throws {
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
    try store.save(e, videoId: id)
    var v = Version(number: 1)
    v.text = "Text \(id)"
    v.captionTemplateId = "short"
    try store.save(v, videoId: id)
    try store.setScore(id, score)
    try store.refreshState(videoId: id)
  }

  var dm: DayMath { DayMath(settings: Settings()) }
  var week: String { dm.weekStart(of: clock.now) }  // 2026-11-02

  /// "2026-11-02" + "19:00" → Date (New York).
  func at(_ day: String, _ hhmm: String) -> Date {
    let p = hhmm.split(separator: ":").map { Int($0)! }
    return dm.at(day, minutes: p[0] * 60 + p[1])
  }

  func setTime(_ day: String, _ hhmm: String) { clock.set(at(day, hhmm)) }

  func posts(_ platform: Platform? = nil) throws -> [PlatformPost] {
    try platform.map { try store.posts(where: "platform=?", [$0.rawValue]) } ?? store.posts()
  }

  func post(_ platform: Platform, day: String, video: String? = nil) throws -> PlatformPost? {
    let start = dm.date(day), end = dm.date(dm.addDays(day, 1))
    return try store.posts(where: "platform=? AND scheduled_at>=? AND scheduled_at<?", [platform.rawValue, start, end])
      .first { video == nil || $0.videoId == video }
  }

  func updateSettings(_ change: (inout Settings) -> Void) throws {
    var s = try store.settings()
    change(&s)
    try store.save(s)
  }

  /// A second (older) session with one clip.
  func addSession(_ name: String, id: String, tag: String, part: Int = 1, start: Double = 500) throws {
    let dir = paths.sessions.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    let file = "Clips/\(name) – \(tag).mp4"
    var d = Data("FAKE-MP4-\(id)-".utf8)
    d.append(Data(repeating: 7, count: 1024))
    try d.write(to: dir.appendingPathComponent(file))
    let entry: [String: Any] = ["id": id, "name": "\(name) – \(tag)", "tags": [tag], "type": "short-form", "content-type": "dj vid",
                                "file": file, "session": name, "part": part, "start": start, "end": start + 22, "duration": 22.0]
    try JSONSerialization.data(withJSONObject: ["session": name, "videos": [entry]]).write(to: dir.appendingPathComponent("videos.json"))
  }

  static let postURLs: [Platform: String] = [
    .tiktok: "https://www.tiktok.com/@dj.lovd/video/1", .instagram: "https://www.instagram.com/reel/abc/",
    .facebook: "https://www.facebook.com/reel/1", .youtube: "https://youtube.com/shorts/abc",
    .threads: "https://www.threads.net/@dj.lovd/post/abc", .x: "https://x.com/djlovdreal/status/1",
  ]
}

extension LogNotifier {
  func titles(containing s: String) -> [String] { delivered.map(\.title).filter { $0.contains(s) } }
}

extension Fixture {
  /// "Never double-post": no platform has two live (un-finished or posted) regular posts on the same day + position.
  func doublePosts() throws -> [String] {
    let positions = Dictionary(uniqueKeysWithValues: try store.planSlots().map { ($0.id, $0.position) })
    var seen: [String: String] = [:]
    var bad: [String] = []
    for p in try store.posts(where: "kind='regular'") where p.state == .posted || !p.state.isTerminal {
      let k = "\(p.platform.rawValue) \(dm.key(p.scheduledAt)) #\(positions[p.planSlotId ?? ""] ?? 0)"
      if let other = seen[k] { bad.append("\(k): \(other) + \(p.videoId)") } else { seen[k] = p.videoId }
    }
    return bad
  }

  /// Marks every post scheduled on `day` posted (clock set to that evening).
  func postAll(on day: String) throws {
    setTime(day, "20:00")
    let a = PostActions(store: store)
    for p in try posts().filter({ dm.key($0.scheduledAt) == day && !$0.state.isTerminal }) {
      try a.markPosted(postId: p.id, url: Fixture.postURLs[p.platform]!)
    }
  }
}
