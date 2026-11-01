// TEMPORARY stand-ins for the RENDER and ENGINE agents' APIs (ARCHITECTURE.md "Contracts").
// The parent deletes this whole file at merge; the real types then come from DJQCore.
// Only the members listed in ARCHITECTURE.md are non-private here, so nothing in the app
// can depend on a stub-only member. Behaviour is deliberately simple ("good enough to click").

import AVFoundation
import AppKit
import CryptoKit
import DJQCore
import SwiftUI

// MARK: - RENDER

struct ProbeInfo: Sendable, Hashable, Codable {
  var duration: Double
  var width: Int
  var height: Int
  var fps: Double
  var hasAudio: Bool
  var size: Int64
  var videoCodec: String
  var audioCodec: String?
}

enum TextOverlay {
  static func image(for v: ResolvedVersion, aspect: Aspect) -> CGImage? { nil }
  static func png(for v: ResolvedVersion, aspect: Aspect) -> Data? { nil }
  @discardableResult static func write(for v: ResolvedVersion, aspect: Aspect, to url: URL) throws -> Bool { false }
  static func textBounds(for v: ResolvedVersion, aspect: Aspect) -> CGRect? { nil }
}

enum Media {
  static func probe(_ url: URL) throws -> ProbeInfo {
    let asset = AVURLAsset(url: url)
    return try _StubBlocking.run {
      let d = try await asset.load(.duration).seconds
      let vt = try await asset.loadTracks(withMediaType: .video).first
      let at = try await asset.loadTracks(withMediaType: .audio).first
      let size = try await vt?.load(.naturalSize) ?? .zero
      let fps = try await vt?.load(.nominalFrameRate) ?? 0
      let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
      return ProbeInfo(duration: d, width: Int(size.width), height: Int(size.height), fps: Double(fps),
                       hasAudio: at != nil, size: bytes, videoCodec: "video", audioCodec: at == nil ? nil : "audio")
    }
  }

  static func thumbnail(store: Store, video: Video, at seconds: Double? = nil, maxHeight: Int = 320) -> URL? {
    guard let src = try? store.fileURL(for: video), FileManager.default.fileExists(atPath: src.path) else { return nil }
    let edit = (try? store.edit(videoId: video.id)) ?? Edit()
    let t = seconds ?? edit.coverTime ?? edit.trimIn ?? video.markerIn ?? 0
    let key = "\(video.id)-\(Int(t * 10))-\(maxHeight)-\(edit.crop.map { "\(Int($0.x))_\(Int($0.w))" } ?? "c")"
    let out = store.paths.thumbs.appendingPathComponent("stub-\(key).jpg")
    if FileManager.default.fileExists(atPath: out.path) { return out }
    guard let full = frame(src, at: t, maxSize: CGSize(width: 1920, height: 1080)) else { return nil }
    let W = Double(full.width), H = Double(full.height)
    var rect: CGRect
    if video.type == .long {
      rect = CGRect(x: 0, y: 0, width: W, height: H)
    } else if let c = edit.crop, let p = try? probe(src), p.width > 0 {
      let s = W / Double(p.width)
      rect = CGRect(x: c.x * s, y: c.y * s, width: c.w * s, height: c.h * s)
    } else {
      let w = min(W, H * 9 / 16)
      rect = CGRect(x: (W - w) / 2, y: 0, width: w, height: H)
    }
    guard let cropped = full.cropping(to: rect.integral) else { return nil }
    let h = CGFloat(maxHeight), w = (h * CGFloat(cropped.width) / CGFloat(cropped.height)).rounded()
    guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out : nil
  }

  static func frame(_ url: URL, at seconds: Double, maxSize: CGSize) -> CGImage? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = maxSize
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    return try? _StubBlocking.run { try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image }
  }
}

final class Renderer: RenderService, @unchecked Sendable {
  private let store: Store
  init(store: Store) { self.store = store }

  static func outputName(video: Video, versionNo: Int, platform: Platform?) -> String {
    "\(video.name) – v\(versionNo)\(platform.map { " – \($0.displayName)" } ?? "").mp4"
  }

  func measureLoudness(_ url: URL) throws -> LoudnessInfo {
    throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "Loudness needs the real Renderer"])
  }

  var onProgress: (@Sendable (String, Double) -> Void)?

  func editHash(videoId: String, versionNo: Int, platform: Platform?) throws -> String {
    let e = JSONCoding.string(try store.edit(videoId: videoId))
    let v = JSONCoding.string(try store.resolvedVersion(videoId: videoId, number: versionNo))
    let s = try scope(videoId: videoId, platform: platform)
    return SHA256.hash(data: Data((e + v + s).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  func scope(videoId: String, platform: Platform?) throws -> String {
    guard let p = platform, try store.edit(videoId: videoId).platformTrims[p] != nil else { return "all" }
    return p.rawValue
  }

  func currentRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render? {
    let h = try editHash(videoId: videoId, versionNo: versionNo, platform: platform)
    return try store.renders(where: "video_id=? AND version_no=? AND edit_hash=? AND status='done' AND deleted_at IS NULL",
                             [videoId, versionNo, h]).last
  }

  /// Stub: no ffmpeg. Hands back the source clip as the "render" (not saved to the database).
  func ensureRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render {
    if let r = try currentRender(videoId: videoId, versionNo: versionNo, platform: platform) { return r }
    guard let v = try store.video(id: videoId), let url = try store.fileURL(for: v) else {
      throw NSError(domain: "stub", code: 2, userInfo: [NSLocalizedDescriptionKey: "Video not found"])
    }
    return Records.render(id: "stub-\(videoId)-\(versionNo)", videoId: videoId, versionNo: versionNo,
                  editHash: try editHash(videoId: videoId, versionNo: versionNo, platform: platform),
                  scope: try scope(videoId: videoId, platform: platform), outputPath: url.path, coverPath: nil,
                  loudness: nil, duration: v.duration, size: v.fileSize, status: .done, error: nil,
                  createdAt: store.clock.now, deletedAt: nil)
  }

  func deleteRenders(except keep: Set<String>) throws {}
}

// MARK: - ENGINE

final class Queue {
  private let store: Store
  init(store: Store) { self.store = store }

  func ordered(platform: Platform? = nil) throws -> [Video] {
    let st = try store.settings()
    let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
    let vids = try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND score IS NOT NULL AND state='ready'")
    let best = st.sortDirection(for: platform) == .bestFirst
    return vids.sorted { a, b in
      if a.score != b.score { return best ? a.score! > b.score! : a.score! < b.score! }
      let da = sessions[a.sessionId]?.date ?? "", db = sessions[b.sessionId]?.date ?? ""
      if da != db { return da < db }
      return (a.part ?? 0, a.start ?? 0) < (b.part ?? 0, b.start ?? 0)
    }
  }

  func toScore() throws -> [Video] {
    try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND score IS NULL")
      .sorted { ($0.part ?? 0, $0.start ?? 0) < ($1.part ?? 0, $1.start ?? 0) }
  }

  func needsEdit() throws -> [Video] {
    try store.videos(where: "type='short-form' AND score IS NOT NULL AND state='needs_edit'")
  }

  func runway() throws -> Runway {
    let st = try store.settings()
    let dm = DayMath(settings: st)
    let today = dm.key(store.clock.now)
    let approvedWeeks = Set(try store.db.query("SELECT week_start FROM weeks WHERE state='approved'").compactMap { $0.string("week_start") })
    let days = Set(try store.planSlots(where: "date>=?", [today]).filter { approvedWeeks.contains($0.weekStart) }.map(\.date))
    var approved = 0
    var d = today
    while days.contains(d) { approved += 1; d = dm.addDays(d, 1) }
    let ppd = max(1, st.postsPerDay)
    let ready = try ordered().count / ppd
    return Runway(approvedDays: approved, readyDays: ready, totalDays: approved + ready + (try needsEdit().count) / ppd)
  }
}

final class Planner {
  private let store: Store
  init(store: Store) { self.store = store }
  private var dm: DayMath { DayMath(settings: (try? store.settings()) ?? DJQCore.Settings()) }
  private var today: String { dm.key(store.clock.now) }

  func weekStart(for date: Date) -> String { dm.weekStart(of: date) }
  func slots(week: String) throws -> [PlanSlot] { try store.planSlots(where: "week_start=?", [week]) }

  func proposeWeek(_ week: String) throws -> [PlanSlot] {
    if try store.week(week) == nil { try store.save(Records.week(weekStart: week, state: .draft, approvedAt: nil)) }
    let ppd = max(1, try store.settings().postsPerDay)
    let planned = Set(try store.planSlots().map(\.videoId))
    var backlog = try Queue(store: store).ordered().filter { !planned.contains($0.id) }
    for day in dm.weekDays(week) where day >= today {
      let used = Set(try store.planSlots(where: "date=?", [day]).map(\.position))
      for pos in 0..<ppd where !used.contains(pos) && !backlog.isEmpty {
        let v = backlog.removeFirst()
        try store.save(Records.planSlot(id: newId(), date: day, position: pos, videoId: v.id, pinned: false, weekStart: week))
        try store.refreshState(videoId: v.id)
      }
    }
    return try slots(week: week)
  }

  func approveWeek(_ week: String) throws {
    try store.save(Records.week(weekStart: week, state: .approved, approvedAt: store.clock.now))
    for s in try slots(week: week) { try createPosts(for: s) }
  }

  func rebuildWeek(_ week: String) throws {
    for s in try slots(week: week) where !s.pinned && s.date >= today {
      let posts = try store.posts(where: "plan_slot_id=?", [s.id])
      if posts.contains(where: { $0.state == .posted }) { continue }
      for p in posts { try store.deletePost(p.id) }
      try store.deletePlanSlot(s.id)
      try store.refreshState(videoId: s.videoId)
    }
    try store.save(Records.week(weekStart: week, state: .draft, approvedAt: nil))
    _ = try proposeWeek(week)
  }

  func pushPlan(from date: String, days: Int) throws {
    for s in try store.planSlots(where: "date>=?", [date]).reversed() { try moveSlot(s, to: dm.addDays(s.date, days)) }
  }

  func pin(videoId: String, date: String) throws {
    if var s = try store.planSlots(where: "video_id=? AND date>=?", [videoId, today]).first {
      if s.date != date { try moveSlot(s, to: date) }
      s = try store.planSlots(where: "id=?", [s.id]).first ?? s
      s.pinned = true
      try store.save(s)
      return
    }
    let used = Set(try store.planSlots(where: "date=?", [date]).map(\.position))
    let pos = (0...9).first { !used.contains($0) } ?? 0
    let s = Records.planSlot(id: newId(), date: date, position: pos, videoId: videoId, pinned: true, weekStart: dm.weekStart(of: dm.date(date)))
    if try store.week(s.weekStart) == nil { try store.save(Records.week(weekStart: s.weekStart, state: .draft, approvedAt: nil)) }
    try store.save(s)
    if try store.week(s.weekStart)?.state == .approved { try createPosts(for: s) }
    try store.refreshState(videoId: videoId)
  }

  func remove(slotId: String) throws {
    guard let s = try store.planSlots(where: "id=?", [slotId]).first else { return }
    for p in try store.posts(where: "plan_slot_id=?", [slotId]) where !p.state.isTerminal { try store.deletePost(p.id) }
    try store.deletePlanSlot(slotId)
    try store.refreshState(videoId: s.videoId)
  }

  func swap(_ a: String, _ b: String) throws {
    guard let sa = try store.planSlots(where: "id=?", [a]).first, let sb = try store.planSlots(where: "id=?", [b]).first else { return }
    try store.db.transaction {
      var x = sa, y = sb
      x.position = -1 - x.position
      try store.save(x)
      y.date = sa.date; y.position = sa.position; y.weekStart = sa.weekStart
      try store.save(y)
      x.date = sb.date; x.position = sb.position; x.weekStart = sb.weekStart
      try store.save(x)
      try retime(x); try retime(y)
    }
  }

  func move(slotId: String, to date: String) throws {
    guard let s = try store.planSlots(where: "id=?", [slotId]).first else { return }
    if let other = try store.planSlots(where: "date=? AND position=?", [date, s.position]).first {
      try swap(s.id, other.id)
    } else {
      try moveSlot(s, to: date)
    }
  }

  func postToday(videoId: String) throws {
    if try !store.planSlots(where: "date=?", [today]).isEmpty { try pushPlan(from: today, days: 1) }
    try pin(videoId: videoId, date: today)
  }

  func skipNext(videoId: String) throws {
    if let s = try store.planSlots(where: "video_id=? AND date>=?", [videoId, today]).first { try remove(slotId: s.id) }
  }

  private func moveSlot(_ s: PlanSlot, to date: String) throws {
    var s = s
    let used = Set(try store.planSlots(where: "date=? AND id<>?", [date, s.id]).map(\.position))
    if used.contains(s.position) { s.position = (0...9).first { !used.contains($0) } ?? s.position }
    s.date = date
    s.weekStart = dm.weekStart(of: dm.date(date))
    try store.save(s)
    try retime(s)
  }

  private func retime(_ s: PlanSlot) throws {
    let st = try store.settings()
    for var p in try store.posts(where: "plan_slot_id=?", [s.id]) where !p.state.isTerminal {
      p.scheduledAt = dm.at(s.date, minutes: st.slot(for: p.platform) + s.position * st.secondPostOffsetMinutes)
      try store.save(p)
    }
  }

  private func createPosts(for s: PlanSlot) throws {
    let st = try store.settings()
    let existing = Set(try store.posts(where: "plan_slot_id=?", [s.id]).map(\.platform))
    let skipped = try store.edit(videoId: s.videoId).skippedPlatforms
    for p in st.activePlatforms where !existing.contains(p) && !skipped.contains(p) {
      let now = store.clock.now
      try store.save(Records.platformPost(id: newId(), videoId: s.videoId, platform: p, versionNo: 1, attemptNo: 1, kind: .regular,
                                  planSlotId: s.id, scheduledAt: dm.at(s.date, minutes: st.slot(for: p) + s.position * st.secondPostOffsetMinutes),
                                  renderId: nil, state: .planned, publisher: "manual", externalId: nil, url: nil, postedAt: nil,
                                  errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil,
                                  createdAt: now, updatedAt: now))
    }
    try store.refreshState(videoId: s.videoId)
  }
}

private struct _StubPostError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

final class PostActions {
  private let store: Store
  init(store: Store) { self.store = store }

  private func load(_ id: String) throws -> PlatformPost {
    guard let p = try store.post(id: id) else { throw _StubPostError(message: "Post not found") }
    return p
  }

  func markPosted(postId: String, url: String, at: Date? = nil) throws {
    var p = try load(postId)
    guard let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased(),
          p.platform.urlHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    else { throw _StubPostError(message: "Not a \(p.platform.displayName) link") }
    p.state = .posted; p.url = url; p.postedAt = at ?? store.clock.now
    try store.save(p, note: "marked posted")
    try store.refreshState(videoId: p.videoId)
  }

  func reportProblem(postId: String, type: ErrorType, message: String, raw: String? = nil) throws {
    var p = try load(postId)
    p.state = type.postState; p.errorType = type; p.errorMessage = message; p.rawResponse = raw; p.resolution = nil
    try store.save(p, note: message)
    try store.refreshState(videoId: p.videoId)
  }

  func resolveCopyright(postId: String, _ r: CopyrightResolution) throws {
    var p = try load(postId)
    switch r {
    case .accept: p.resolution = "accepted"
    case .skipPlatform: p.resolution = "skipped"
    case .reuploadAnyway(let v):
      p.resolution = "reuploaded"
      try newAttempt(from: p, kind: .retry, version: v ?? p.versionNo, after: 0)
    }
    try store.save(p, note: p.resolution)
    try store.refreshState(videoId: p.videoId)
  }

  func fixed(postId: String) throws {
    var p = try load(postId)
    p.resolution = "fixed"
    try store.save(p, note: "fixed")
    try newAttempt(from: p, kind: .retry, version: p.versionNo, after: 1)
  }

  func reset(postId: String) throws {
    var p = try load(postId)
    p.state = p.scheduledAt <= store.clock.now ? .due : .planned
    p.errorType = nil; p.errorMessage = nil; p.rawResponse = nil; p.resolution = nil; p.url = nil; p.postedAt = nil
    try store.save(p, note: "reset")
    try store.refreshState(videoId: p.videoId)
  }

  func skip(postId: String) throws {
    var p = try load(postId)
    if p.state.isProblem { p.resolution = "skipped" }
    p.state = .skipped
    try store.save(p, note: "skipped")
    try store.refreshState(videoId: p.videoId)
  }

  func repost(videoId: String, platform: Platform) throws {
    let prev = try store.posts(where: "video_id=? AND platform=?", [videoId, platform.rawValue])
    guard let last = prev.max(by: { $0.attemptNo < $1.attemptNo }) else { throw _StubPostError(message: "Never posted there") }
    let cooldown = try store.settings().repostCooldownDays
    try newAttempt(from: last, kind: .repost, version: (prev.map(\.versionNo).max() ?? 1) + 1, after: cooldown)
  }

  func setMetrics(postId: String, _ m: PostMetrics) throws {
    var p = try load(postId)
    p.metrics = m
    try store.save(p)
  }

  func markLongformPosted(videoId: String, url: String) throws {
    guard try store.video(id: videoId) != nil else { throw _StubPostError(message: "Video not found") }
    guard URL(string: url)?.host?.contains("youtu") == true else { throw _StubPostError(message: "Not a YouTube link") }
    try store.setLongformURL(videoId, url)
    try store.refreshState(videoId: videoId)
  }

  func dueToday(now: Date) throws -> [PlatformPost] {
    let dm = DayMath(settings: try store.settings())
    let start = dm.date(dm.key(now)), end = dm.date(dm.addDays(dm.key(now), 1))
    let today = try store.posts(where: "scheduled_at>=? AND scheduled_at<?", [start, end])
    let late = try store.posts(where: "scheduled_at<? AND state IN ('due','overdue') AND resolution IS NULL", [start])
    return (late + today).sorted { $0.scheduledAt < $1.scheduledAt }
  }

  func problems() throws -> [PlatformPost] {
    try store.posts(where: "state IN ('failed','copyright_blocked','copyright_muted','removed','overdue') AND resolution IS NULL",
                    order: "updated_at DESC")
  }

  private func newAttempt(from p: PlatformPost, kind: PostKind, version: Int, after days: Int) throws {
    let st = try store.settings()
    let dm = DayMath(settings: st)
    let day = dm.addDays(dm.key(store.clock.now), max(days, 1))
    let at = dm.at(day, minutes: st.slot(for: p.platform) + Int(st.retryStaggerHours * 60))
    let attempts = try store.posts(where: "video_id=? AND platform=?", [p.videoId, p.platform.rawValue]).map(\.attemptNo).max() ?? 1
    let now = store.clock.now
    try store.save(Records.platformPost(id: newId(), videoId: p.videoId, platform: p.platform, versionNo: version, attemptNo: attempts + 1,
                                kind: kind, planSlotId: nil, scheduledAt: at, renderId: nil, state: .planned, publisher: p.publisher,
                                externalId: nil, url: nil, postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil,
                                resolution: nil, metrics: nil, createdAt: now, updatedAt: now))
  }
}

final class ManualPublisher: Publisher, @unchecked Sendable {
  private let store: Store
  private let renderer: RenderService
  init(store: Store, renderer: RenderService) { self.store = store; self.renderer = renderer }

  var name: String { "manual" }

  func prepare(postId: String) throws -> PreparedPost {
    guard let p = try store.post(id: postId), let v = try store.video(id: p.videoId) else { throw _StubPostError(message: "Post not found") }
    let st = try store.settings()
    let r = try renderer.ensureRender(videoId: v.id, versionNo: p.versionNo, platform: p.platform)
    let rv = try store.resolvedVersion(videoId: v.id, number: p.versionNo, settings: st)
      ?? VersionResolver.resolve([Version(number: 1)], number: 1, settings: st)
    let session = try store.session(id: v.sessionId)?.name ?? ""
    let caption = Captions.caption(for: p.platform, version: rv, video: v, sessionName: session, sets: try store.hashtagSets(),
                                   templates: try store.captionTemplates(), settings: st, rules: PrefillRules.load(store.paths))
    return PreparedPost(postId: postId, platform: p.platform, fileURL: URL(fileURLWithPath: r.outputPath ?? ""),
                        coverURL: r.coverPath.map(URL.init(fileURLWithPath:)), caption: caption,
                        title: p.platform == .youtube ? Captions.youtubeTitle(rv, video: v, rules: PrefillRules.load(store.paths)) : nil, uploadURL: p.platform.uploadURL)
  }

  func submit(_ post: PreparedPost) throws -> PublishStatus { .waitingForUser }

  func status(postId: String) throws -> PublishStatus {
    guard let p = try store.post(id: postId) else { return .waitingForUser }
    if p.state == .posted, let u = p.url { return .posted(url: u, at: p.postedAt ?? p.updatedAt) }
    if let e = p.errorType { return .failed(e, p.errorMessage ?? "") }
    return .waitingForUser
  }
}

struct TickReport: Sendable {
  var started: Date
  var steps: [String: String]
  var errors: [String]
}

final class Engine {
  private let store: Store
  private let notifier: Notifier
  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private let q = DispatchQueue(label: "stub.engine")

  init(store: Store, renderer: RenderService?, publisher: Publisher?, notifier: Notifier) {
    self.store = store
    self.notifier = notifier
  }

  func tick(reason: String) -> TickReport {
    var r = TickReport(started: store.clock.now, steps: [:], errors: [])
    do {
      let i = try Intake(store: store).run()
      r.steps["intake"] = "\(i.newVideos.count) new"
      let now = store.clock.now
      let dm = DayMath(settings: try store.settings())
      var due = 0
      for var p in try store.posts(where: "state IN ('planned','rendered') AND scheduled_at<=?", [now]) {
        if dm.key(p.scheduledAt) < dm.key(now) { p.state = .overdue } else { p.state = .due; due += 1 }
        try store.save(p)
        if p.state == .due, try store.markNotified("due-\(p.id)") {
          let name = try store.video(id: p.videoId)?.tag ?? ""
          notifier.deliver(AppNotification(key: "due-\(p.id)", title: "\(p.platform.displayName) · \(name)", body: "Due now",
                                           actions: [.markPosted, .skip], postId: p.id, videoId: p.videoId))
        }
      }
      r.steps["due"] = "\(due)"
      try store.heartbeat(.tick)
    } catch {
      r.errors.append("\(error)")
    }
    lastTick = r
    return r
  }

  func start() {
    try? store.heartbeat(.start)
    q.async { _ = self.tick(reason: "start") }
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.q.async { _ = self.tick(reason: "timer") }
    }
    let ws = NSWorkspace.shared.notificationCenter
    observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
      try? self?.store.heartbeat(.wake)
      self?.q.async { _ = self?.tick(reason: "wake") }
    })
    observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
      try? self?.store.heartbeat(.sleep)
    })
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    observers = []
    try? store.heartbeat(.stop)
  }

  private(set) var lastTick: TickReport?
  var isRendering: Bool { false }
}

final class Doctor {
  private let store: Store
  init(store: Store) { self.store = store }

  func run() -> DoctorReport {
    var f: [DoctorFinding] = []
    var passed: [String] = []
    let vids = (try? store.videos()) ?? []
    let missing = vids.filter(\.missing)
    if missing.isEmpty { passed.append("files.missing") } else {
      f.append(.init(id: "files.missing", severity: .error, title: "\(missing.count) clip file(s) missing",
                     detail: "Not found at their path or by fingerprint.", where_: missing.map(\.name), fix: "Restore the file or re-export from CapCut."))
    }
    let problems = (try? PostActions(store: store).problems()) ?? []
    if problems.isEmpty { passed.append("posts.problems") } else {
      f.append(.init(id: "posts.problems", severity: .error, title: "\(problems.count) post(s) need attention",
                     detail: "Failed, copyright or overdue posts are unresolved.", where_: problems.map(\.id), fix: "Open Posts and resolve each one."))
    }
    let unscored = vids.filter { $0.type == .short && $0.score == nil && !$0.excluded }.count
    if unscored > 0 {
      f.append(.init(id: "queue.unscored", severity: .info, title: "\(unscored) video(s) not scored",
                     detail: "Unscored videos are not queued.", where_: [], fix: "Use Score mode in the Queue."))
    } else { passed.append("queue.unscored") }
    if Tools.ffmpeg == nil {
      f.append(.init(id: "tools.ffmpeg", severity: .error, title: "ffmpeg not found", detail: "Rendering needs ffmpeg.",
                     where_: [], fix: "brew install ffmpeg"))
    } else { passed.append("tools.ffmpeg") }
    if (try? store.db.integrityCheck()) == "ok" { passed.append("db.integrity") }
    return DoctorReport(generatedAt: store.clock.now, findings: f, passed: passed)
  }

  static func markdown(_ r: DoctorReport) -> String {
    var s = "# DJ Queue Doctor — \(r.generatedAt.formatted())\n\n"
    for x in r.findings {
      s += "- **\(x.severity.rawValue.uppercased())** \(x.title) — \(x.detail)\n  - where: \(x.where_.joined(separator: ", "))\n  - fix: \(x.fix)\n"
    }
    s += "\nPassed: \(r.passed.joined(separator: ", "))\n"
    return s
  }
}

enum Health {
  static func awakePeriods(store: Store, since: Date) throws -> [DateInterval] {
    var out: [DateInterval] = []
    var start: Date?
    var last: Date?
    for h in try store.heartbeats(since: since) {
      if let l = last, h.at.timeIntervalSince(l) > 180 || h.kind == .start {
        if let s = start { out.append(DateInterval(start: s, end: l)) }
        start = nil
      }
      if start == nil { start = h.at }
      last = h.at
      if h.kind == .sleep || h.kind == .stop {
        if let s = start { out.append(DateInterval(start: s, end: h.at)) }
        start = nil; last = nil
      }
    }
    if let s = start, let l = last { out.append(DateInterval(start: s, end: max(l, s))) }
    return out
  }

  static func missedSlots(store: Store, since: Date) throws -> [PlatformPost] {
    let ids = Set(try store.db.query("SELECT DISTINCT post_id FROM post_history WHERE to_state='overdue' AND at>=?", [since])
      .compactMap { $0.string("post_id") })
    return try store.posts(where: "scheduled_at>=?", [since]).filter { ids.contains($0.id) || $0.state == .overdue }
  }
}

enum Backup {
  static func runIfDue(store: Store) throws -> URL? {
    let fm = FileManager.default
    try fm.createDirectory(at: store.paths.backups, withIntermediateDirectories: true)
    let name = "queue-\(DayMath(settings: try store.settings()).key(store.clock.now)).sqlite"
    let url = store.paths.backups.appendingPathComponent(name)
    if fm.fileExists(atPath: url.path) { return nil }
    try store.db.backup(to: url.path)
    return url
  }
}

enum LaunchAgent {
  /// Stub: writes the plist only (never calls launchctl).
  static func install(appPath: String, paths: Paths) throws {
    try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["Label": "com.djlovd.queue.engine", "RunAtLoad": true, "KeepAlive": true,
                                "ProgramArguments": [appPath + "/Contents/MacOS/DJQueue", "--agent"]]
    let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try d.write(to: paths.agentPlist)
  }

  static func isLoaded() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "gui/\(getuid())/com.djlovd.queue.engine"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
  }

  static func uninstall(paths: Paths) throws {
    try? FileManager.default.removeItem(at: paths.agentPlist)
  }
}

// MARK: - UI-EDITOR

struct EditorView: View {
  let store: Store
  let videoId: String
  let videoIds: [String]
  let onDone: () -> Void

  init(store: Store, videoId: String, videoIds: [String], onDone: @escaping () -> Void) {
    self.store = store; self.videoId = videoId; self.videoIds = videoIds; self.onDone = onDone
  }

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 32)).foregroundStyle(.tertiary)
      Text((try? store.video(id: videoId))??.tag ?? videoId).font(.title2.weight(.semibold))
      Text("Editor placeholder — the UI-EDITOR agent's EditorView replaces this.").foregroundStyle(.secondary)
      Button("Done", action: onDone).keyboardShortcut(.defaultAction)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

// MARK: - helpers (private to the stubs)

private enum _StubBlocking {
  static func run<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached {
      do { result = .success(try await body()) } catch { result = .failure(error) }
      sem.signal()
    }
    sem.wait()
    return try result.get()
  }
}
