import AVFoundation
import Combine
import DJQCore
import Foundation
import SwiftUI

enum EditorTab: String, CaseIterable, Identifiable {
  case frame = "Frame", text = "Text", caption = "Caption", cover = "Cover"
  var id: String { rawValue }
}

/// Platform UI families for the safe-zone overlay (E.S6).
enum EditorSafeZone: String, CaseIterable, Identifiable {
  case tiktok = "TikTok", reels = "Reels", shorts = "Shorts"
  var id: String { rawValue }
}

/// All editor state for one video. Edits apply locally at once and are written to the Store
/// ~300 ms later on a background queue (never blocking the main thread).
@MainActor
final class EditorModel: ObservableObject {
  let store: Store
  let snapshotMode: Bool

  @Published private(set) var videoId: String
  @Published private(set) var video: Video?
  @Published private(set) var sessionName = ""
  @Published private(set) var fileURL: URL?
  @Published private(set) var fileMissing = false
  @Published private(set) var sourceSize = CGSize(width: 3840, height: 2160)
  @Published private(set) var fps = 30000.0 / 1001
  @Published var edit = Edit()
  @Published private(set) var versions: [Version] = []
  @Published var versionNo = 1
  @Published private(set) var settings = Settings()
  @Published private(set) var sets: [HashtagSet] = []
  @Published private(set) var templates: [CaptionTemplate] = []
  @Published private(set) var posts: [PlatformPost] = []
  @Published private(set) var issues: [ValidationIssue] = []
  @Published private(set) var prefill = ""
  @Published var tab: EditorTab = .frame
  @Published var safeZonesWanted = false
  @Published var safeZone: EditorSafeZone = .tiktok
  @Published private(set) var overlay: CGImage?
  @Published private(set) var saving = false
  @Published private(set) var lastSaved: Date?
  @Published var loadError: String?
  /// True when the stored edit couldn't be read: nothing is written, so a corrupt row is never overwritten.
  @Published private(set) var readOnly = false
  private(set) var rules = PrefillRules()

  let playback = EditorPlayback()
  private var pendingEdit = false
  private var pendingVersions = Set<Int>()
  private var saveTask: Task<Void, Never>?
  private var overlayTask: Task<Void, Never>?
  private var overlayKey: OverlayKey?
  private static let saveQueue = DispatchQueue(label: "com.djlovd.queue.editor.save", qos: .userInitiated)

  init(store: Store, videoId: String, snapshotMode: Bool = false) {
    self.store = store
    self.videoId = videoId
    self.snapshotMode = snapshotMode
    load(videoId)
  }

  // MARK: Loading

  func load(_ id: String) {
    flush()
    Self.saveQueue.sync {}  // the previous video's last write lands before anything is re-read
    videoId = id
    versionNo = 1
    loadError = nil
    readOnly = false
    video = nil
    edit = Edit()
    versions = []
    posts = []
    issues = []
    prefill = ""
    fileURL = nil
    do {
      settings = try store.settings()
      sets = try store.hashtagSets()
      templates = try store.captionTemplates()
      guard let v = try store.video(id: id) else {
        video = nil; loadError = "Video not found"; return
      }
      video = v
      sessionName = try store.session(id: v.sessionId)?.name ?? ""
      let url = try store.fileURL(for: v)
      fileURL = url
      fileMissing = v.missing || url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
      rules = PrefillRules.load(store.paths)
      prefill = Prefill.text(tag: v.tag, kind: v.kind, rules: rules)
      do {
        edit = try store.edit(videoId: id)
        versions = try store.versions(videoId: id)
      } catch {
        readOnly = true
        throw error
      }
      posts = try store.posts(where: "video_id=?", [id])
      issues = try Validation.issues(video: v, store: store)
    } catch {
      loadError = readOnly ? "This video's saved edit couldn't be read, so editing is off to protect it. Run Doctor."
        : "Couldn't load: \(error)"
    }
    tab = edit.crop == nil ? .frame : .text
    refreshOverlay()
    if let url = fileURL, !fileMissing {
      if snapshotMode {
        if let p = try? Media.probe(url) { apply(p) }
      } else {
        Task.detached(priority: .userInitiated) { [weak self] in
          guard let p = try? Media.probe(url) else { return }
          await self?.applyProbe(p, url: url)
        }
      }
      if snapshotMode {
        playback.loadStill(url: url, at: trim.start, maxSize: CGSize(width: 1920, height: 1080))
      } else {
        playback.load(url: url, start: trim.start)
      }
    } else {
      playback.unload()
    }
    playback.trimProvider = { [weak self] in self?.trim ?? TrimRange(start: 0, end: 0) }
  }

  private func applyProbe(_ p: ProbeInfo, url: URL) {
    if fileURL == url { apply(p) }
  }

  private func apply(_ p: ProbeInfo) {
    guard p.width > 0, p.height > 0 else { return }
    sourceSize = CGSize(width: p.width, height: p.height)
    if p.fps > 0 { fps = p.fps }
  }

  // MARK: Derived

  var duration: Double { video?.duration ?? 0 }
  var trim: TrimRange { edit.trim(duration: duration) }
  var cropIsSet: Bool { edit.crop != nil }
  /// The crop exactly as the export uses it (even pixels, `Media.pixelCrop`).
  var crop: CropRect {
    edit.crop.map { EditorGeometry.even($0, source: sourceSize) } ?? EditorGeometry.defaultCrop(source: sourceSize, aspect: edit.aspect)
  }
  var zoom: Double { EditorGeometry.zoom(of: crop, source: sourceSize, aspect: edit.aspect) }
  var upscale: Double { EditorGeometry.upscale(crop, aspect: edit.aspect) }
  var safeZonesVisible: Bool { tab == .text || safeZonesWanted }

  var resolved: ResolvedVersion {
    VersionResolver.resolve(versions.isEmpty ? [Version(number: 1)] : versions, number: versionNo, settings: settings)
  }

  var versionNumbers: [Int] {
    let n = versions.map(\.number)
    return n.isEmpty ? [1] : (n.contains(1) ? n : [1] + n).sorted()
  }

  /// The version a carried-forward field comes from ("from v1").
  func source(of field: String) -> Int? {
    guard resolved.inherited.contains(field) else { return nil }
    let r = versions.filter { $0.number < versionNo }.sorted { $0.number > $1.number }
    for v in r {
      let m = Mirror(reflecting: v)
      if let c = m.children.first(where: { $0.label == field }) {
        let inner = Mirror(reflecting: c.value)
        if inner.displayStyle == .optional, let some = inner.children.first {
          if let s = some.value as? String, s.isEmpty { continue }
          return v.number
        }
      }
    }
    return 1
  }

  var activePlatforms: [Platform] { settings.activePlatforms }
  var postingPlatforms: [Platform] { activePlatforms.filter { !edit.skippedPlatforms.contains($0) } }

  /// Hashtags for the current version (with the per-video rotating sub-set when automatic).
  var hashtags: [String] { Captions.hashtags(resolved, sets: sets, videoId: videoId) }

  /// Sets currently in use: chosen ones, or — when automatic — every set whose tags all appear.
  var setsInUse: Set<String> {
    let r = resolved
    guard r.autoHashtags else { return Set(r.hashtagSetIds) }
    let tags = Set(hashtags)
    return Set(sets.filter { s in
      r.hashtagSetIds.contains(s.id) || (!s.tags.isEmpty && s.tags.allSatisfy { tags.contains(Captions.normalizeTag($0)) })
    }.map(\.id))
  }

  func caption(for p: Platform) -> String {
    guard let v = video else { return "" }
    return Captions.caption(for: p, version: resolved, video: v, sessionName: sessionName, sets: sets,
                            templates: templates, settings: settings, rules: rules)
  }

  var youtubeTitleDefault: String {
    guard let v = video else { return "" }
    var r = resolved
    r.youtubeTitle = ""
    return Captions.youtubeTitle(r, video: v, limit: settings.limits[.youtube]?.titleLimit ?? 100, rules: rules)
  }

  /// "Posted on TT, IG" etc. for the version list.
  func usage(of number: Int) -> (posted: [Platform], planned: [Platform]) {
    let mine = posts.filter { $0.versionNo == number }
    return (mine.filter { $0.state == .posted }.map(\.platform).sorted(),
            mine.filter { !$0.state.isTerminal }.map(\.platform).sorted())
  }

  // MARK: Mutations

  /// `live: true` while a trim handle is being dragged: trim-dependent values are only re-clamped on `commitTrim()`.
  func updateEdit(live: Bool = false, _ f: (inout Edit) -> Void) {
    guard !readOnly, video != nil else { return }
    var e = edit
    f(&e)
    guard e != edit else { return }
    let oldTrim = trim
    edit = e
    pendingEdit = true
    if trim != oldTrim && !live { keepInsideTrim() }
    scheduleSave()
    refreshOverlay()
  }

  /// After a trim change: cover time stays inside the trim, and every version's text timing (relative to
  /// the trim start) stays inside the new trim length.
  /// Call when a trim drag ends.
  func commitTrim() {
    guard !readOnly, video != nil else { return }
    keepInsideTrim()
    scheduleSave()
    refreshOverlay()
  }

  private func keepInsideTrim() {
    let t = trim
    let cover = EditorGeometry.afterTrimCommit(textStart: nil, textEnd: nil, cover: edit.coverTime, trim: t).cover
    if cover != edit.coverTime { edit.coverTime = cover; pendingEdit = true }
    for i in versions.indices where versions[i].textStart != nil || versions[i].textEnd != nil {
      let (s, e) = EditorGeometry.clampTextTiming(start: versions[i].textStart, end: versions[i].textEnd, trimDuration: t.duration)
      if s != versions[i].textStart || e != versions[i].textEnd {
        versions[i].textStart = s
        versions[i].textEnd = e
        pendingVersions.insert(versions[i].number)
      }
    }
  }

  func updateVersion(_ f: (inout Version) -> Void) {
    guard !readOnly, video != nil else { return }
    var all = versions
    var inserted = false
    if !all.contains(where: { $0.number == 1 }) { all.insert(Version(number: 1), at: 0); inserted = true }
    if !all.contains(where: { $0.number == versionNo }) { all.append(Version(number: versionNo)); inserted = true }
    guard let i = all.firstIndex(where: { $0.number == versionNo }) else { return }
    var v = all[i]
    f(&v)
    guard v != all[i] || inserted else { return }
    if inserted { pendingVersions.insert(1) }
    all[i] = v
    versions = all.sorted { $0.number < $1.number }
    pendingVersions.insert(versionNo)
    scheduleSave()
    refreshOverlay()
  }

  func setCrop(_ c: CropRect) { updateEdit { $0.crop = EditorGeometry.clamp(c, source: sourceSize) } }
  func confirmCrop() { setCrop(crop) }

  func setAspect(_ a: Aspect) {
    let old = edit.aspect
    updateEdit {
      $0.aspect = a
      if let c = $0.crop { $0.crop = EditorGeometry.crop(c, aspect: a, from: old, source: sourceSize) }
    }
  }

  func setZoom(_ z: Double) { setCrop(EditorGeometry.crop(crop, zoom: z, source: sourceSize, aspect: edit.aspect)) }

  func setKind(_ k: Kind) {
    guard var v = video, v.kind != k else { return }
    v.kind = k
    video = v
    prefill = Prefill.text(tag: v.tag, kind: k, rules: rules)
    let store = store, id = videoId
    Self.saveQueue.async {
      try? store.setKind(id, k)
      ChangeSignal.post()
    }
  }

  func newVersion(copying source: Int?) {
    guard !readOnly else { return }
    flush()
    let n = (versions.map(\.number).max() ?? 1) + 1
    var v = Version(number: n)
    if let s = source, s != versions.map(\.number).max() ?? 1 {
      let r = VersionResolver.resolve(versions, number: s, settings: settings)
      v.text = r.text; v.noText = r.noText; v.style = r.style; v.size = r.size; v.posX = r.posX; v.posY = r.posY
      v.align = r.align; v.textStart = r.textStart; v.textEnd = r.textEnd; v.caption = r.caption
      v.captionTemplateId = r.captionTemplateId; v.extraHashtags = r.extraHashtags
      if !r.autoHashtags { v.hashtagSetIds = r.hashtagSetIds }
      v.youtubeTitle = r.youtubeTitle; v.platformCaptions = r.platformCaptions
    }
    if !versions.contains(where: { $0.number == 1 }) { versions.insert(Version(number: 1), at: 0); pendingVersions.insert(1) }
    versions.append(v)
    pendingVersions.insert(n)
    versionNo = n
    scheduleSave()
    refreshOverlay()
  }

  func deleteVersion(_ n: Int) {
    guard n > 1, !readOnly else { return }
    flush()
    versions.removeAll { $0.number == n }
    if versionNo == n { versionNo = versions.map(\.number).filter { $0 < n }.max() ?? 1 }
    let store = store, id = videoId
    Self.saveQueue.async {
      try? store.deleteVersion(videoId: id, number: n)
      ChangeSignal.post()
    }
    refreshOverlay()
  }

  func selectVersion(_ n: Int) {
    versionNo = n
    refreshOverlay()
  }

  /// "Trim for X": opens the per-platform trim lane, starting from the main trim cut to the platform limit.
  func addPlatformTrim(_ p: Platform) {
    let t = trim
    let lim = settings.limits[p]?.maxDuration ?? t.duration
    updateEdit { $0.platformTrims[p] = TrimRange(start: t.start, end: min(t.end, t.start + lim)) }
  }

  // MARK: Saving

  private func scheduleSave() {
    saving = true
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  /// Writes pending changes now (still off the main thread) — used before switching videos and on Done.
  func flush() {
    saveTask?.cancel()
    guard pendingEdit || !pendingVersions.isEmpty, let video else { saving = false; return }
    let store = store, id = videoId, e = pendingEdit ? edit : nil
    let vs = versions.filter { pendingVersions.contains($0.number) }
    pendingEdit = false
    pendingVersions = []
    saving = true
    Self.saveQueue.async { [weak self] in
      do {
        if let e { try store.save(e, videoId: id) }
        for v in vs { try store.save(v, videoId: id) }
        let fresh = try store.video(id: id) ?? video
        let issues = try Validation.issues(video: fresh, store: store)
        ChangeSignal.post()
        DispatchQueue.main.async {
          guard let self, self.videoId == id else { return }
          self.issues = issues
          self.saving = self.pendingEdit || !self.pendingVersions.isEmpty
          self.lastSaved = Date()
        }
      } catch {
        Log.shared.error("editor save failed: \(error)")
        DispatchQueue.main.async { self?.saving = false; self?.loadError = "Couldn't save: \(error)" }
      }
    }
  }

  /// Blocks until queued writes are done (Done / window close).
  func flushAndWait() {
    flush()
    Self.saveQueue.sync {}
  }

  // MARK: Text overlay (TextOverlay PNG drawn over the player — preview == export)

  private struct OverlayKey: Hashable { var v: ResolvedVersion; var a: Aspect }

  func refreshOverlay() {
    let key = OverlayKey(v: resolved, a: edit.aspect)
    guard key != overlayKey else { return }
    overlayKey = key
    overlayTask?.cancel()
    if snapshotMode {
      overlay = TextOverlay.image(for: key.v, aspect: key.a)
      return
    }
    overlayTask = Task.detached(priority: .userInitiated) { [weak self] in
      let img = TextOverlay.image(for: key.v, aspect: key.a)
      await self?.setOverlay(img, key: key)
    }
  }

  private func setOverlay(_ img: CGImage?, key: OverlayKey) {
    if overlayKey == key { overlay = img }
  }

  /// Text bounds in normalised output coordinates (0…1, top-left origin) for hit-testing drags.
  var textBoundsUnit: CGRect? {
    guard let b = TextOverlay.textBounds(for: resolved, aspect: edit.aspect) else { return nil }
    let o = edit.aspect.outputSize
    return CGRect(x: b.minX / CGFloat(o.w), y: b.minY / CGFloat(o.h), width: b.width / CGFloat(o.w), height: b.height / CGFloat(o.h))
  }

  /// Text visible at the playhead (text timing is relative to the trim start).
  func textVisible(at t: Double) -> Bool {
    let r = resolved
    let s = trim.start + (r.textStart ?? 0)
    let e = r.textEnd.map { trim.start + $0 } ?? trim.end
    return t >= s - 0.01 && t <= e + 0.01
  }
}

/// Player + playhead time, separate from the model so 30 Hz time updates only redraw the playhead.
@MainActor
final class EditorPlayback: ObservableObject {
  @Published private(set) var player: AVPlayer?
  @Published private(set) var time: Double = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var ready = false
  @Published private(set) var still: CGImage?
  var trimProvider: () -> TrimRange = { TrimRange(start: 0, end: 0) }
  private var observer: Any?
  private var statusObs: NSKeyValueObservation?
  private var url: URL?

  func load(url: URL, start: Double) {
    unload()
    self.url = url
    let p = AVPlayer(url: url)
    p.actionAtItemEnd = .pause
    player = p
    statusObs = p.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
      let ok = item.status == .readyToPlay
      DispatchQueue.main.async { self?.ready = ok }
    }
    observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
      MainActor.assumeIsolated { self?.tick(t.seconds) }
    }
    seek(start, exact: true)
  }

  func loadStill(url: URL, at t: Double, maxSize: CGSize) {
    self.url = url
    time = t
    still = Media.frame(url, at: t, maxSize: maxSize)
    ready = still != nil
  }

  func unload() {
    if let o = observer { player?.removeTimeObserver(o) }
    observer = nil
    statusObs = nil
    player?.pause()
    player = nil
    isPlaying = false
    ready = false
    still = nil
  }

  private func tick(_ t: Double) {
    guard t.isFinite else { return }
    time = t
    let tr = trimProvider()
    if isPlaying, tr.end > tr.start, t >= tr.end - 0.02 {
      seek(tr.start, exact: true)
      player?.play()
    }
    if isPlaying, player?.rate == 0, t < tr.end - 0.05 { isPlaying = false }
  }

  func toggle() {
    guard let p = player else { return }
    if isPlaying { p.pause(); isPlaying = false; return }
    let tr = trimProvider()
    if time < tr.start || time >= tr.end - 0.05 { seek(tr.start, exact: true) }
    p.play()
    isPlaying = true
  }

  func pause() { player?.pause(); isPlaying = false }

  func seek(_ t: Double, exact: Bool = false) {
    time = t
    if let p = player {
      let tol = exact ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 600)
      p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
    } else if let url, still != nil {
      still = Media.frame(url, at: t, maxSize: CGSize(width: 1920, height: 1080))
    }
  }

  func step(_ frames: Int, fps: Double) {
    pause()
    seek(max(0, time + Double(frames) / max(fps, 1)), exact: true)
  }
}
