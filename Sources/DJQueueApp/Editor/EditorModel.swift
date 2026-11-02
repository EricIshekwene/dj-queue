import AVFoundation
import AppKit
import Combine
import DJQCore
import Foundation
import SwiftUI

/// Inspector sections, in scroll order (the sticky mini-index jumps to them).
enum EditorSection: String, CaseIterable, Identifiable {
  case title = "Title", frame = "Frame", text = "Text", caption = "Caption", cover = "Cover", platforms = "Platforms"
  var id: String { rawValue }
}

/// What the canvas shows: the crop on the full source, the output with platform safe zones, or phone previews.
enum EditorCanvasMode: String, CaseIterable, Identifiable {
  case frame = "Frame", zones = "Zones", preview = "Preview"
  var id: String { rawValue }
}

/// The order platforms appear in everywhere in the editor (feeds first, then cards).
enum EditorPlatforms {
  static let order: [Platform] = [.tiktok, .instagram, .facebook, .youtube, .threads, .x]
}

/// A caption length problem for one platform (live, from the in-memory version).
struct EditorCaptionWarning: Identifiable, Hashable {
  var platform: Platform
  var count: Int
  var limit: Int
  /// Length without hashtags (nil when there are none to drop or the platform has its own caption).
  var countWithoutHashtags: Int?
  var over: Bool { count > limit }
  var id: Platform { platform }
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
  @Published private(set) var suggestions: [TitleSuggestion] = []
  @Published private(set) var lastCrop: CGPoint?
  @Published private(set) var overlay: CGImage?
  @Published private(set) var saving = false
  @Published private(set) var lastSaved: Date?
  @Published var loadError: String?
  /// True when the stored edit couldn't be read: nothing is written, so a corrupt row is never overwritten.
  @Published private(set) var readOnly = false

  // View state (not clip data).
  @Published var canvasMode: EditorCanvasMode {
    didSet { Self.defaults.set(canvasMode.rawValue, forKey: "editor.canvasMode") }
  }
  @Published var previewPlatform: Platform = .tiktok
  @Published var compare = false
  /// Section the inspector should scroll to (set, then cleared by the inspector).
  @Published var scrollTarget: EditorSection?
  /// Platform whose own caption field should open (Write an X caption).
  @Published var openPlatformCaption: Platform?
  @Published var toast: String?
  /// Bumped when Title should take keyboard focus (header title click).
  @Published var focusTitle = 0
  /// True while a clip's data is being read (the canvas shows a spinner, not "not found").
  @Published private(set) var loading = false
  /// Incremented per load; only the latest load's result is applied.
  private var loadToken = 0
  /// A typed Title that hasn't been committed yet (nil = not editing). Saved on ↩, blur, clip switch and Done.
  @Published var titleDraft: String?
  /// True while a trim handle is being dragged (expensive derived work waits for the drag end).
  @Published private(set) var trimDragging = false
  @Published private var zoneSelections: [String: Set<Platform>] = [:]

  let playback = EditorPlayback()
  private var pendingEdit = false
  private var pendingVersions = Set<Int>()
  private var saveTask: Task<Void, Never>?
  private var overlayTask: Task<Void, Never>?
  private var overlayKey: OverlayKey?
  private var toastTask: Task<Void, Never>?
  private static let saveQueue = DispatchQueue(label: "com.djlovd.queue.editor.save", qos: .userInitiated)

  /// Blocks until every queued editor write has landed (the app journals the session after it).
  static func waitForSaves() { saveQueue.sync {} }
  nonisolated(unsafe) static var defaults = UserDefaults.standard

  init(store: Store, videoId: String, snapshotMode: Bool = false) {
    self.store = store
    self.videoId = videoId
    self.snapshotMode = snapshotMode
    canvasMode = Self.defaults.string(forKey: "editor.canvasMode").flatMap(EditorCanvasMode.init) ?? .zones
    load(videoId)
  }

  // MARK: Loading

  /// Everything one clip needs, read off the main thread (on the save queue, so it lands after pending writes).
  private struct Loaded: @unchecked Sendable {
    var settings = Settings(), sets: [HashtagSet] = [], templates: [CaptionTemplate] = [], lastCrop: CGPoint?
    var video: Video?, sessionName = "", fileURL: URL?, fileMissing = false, suggestions: [TitleSuggestion] = []
    var edit = Edit(), versions: [Version] = [], posts: [PlatformPost] = [], issues: [ValidationIssue] = []
    var error: String?, readOnly = false
  }

  private nonisolated static func read(_ store: Store, _ id: String) -> Loaded {
    var l = Loaded()
    do {
      l.settings = try store.settings()
      l.sets = try store.hashtagSets()
      l.templates = try store.captionTemplates()
      l.lastCrop = l.settings.defaults.cropAnchor == .lastUsed ? try store.lastCropCentre() : nil
      guard let v = try store.video(id: id) else { l.error = "Clip not found"; return l }
      l.video = v
      l.sessionName = try store.session(id: v.sessionId)?.name ?? ""
      let url = try store.fileURL(for: v)
      l.fileURL = url
      l.fileMissing = v.missing || url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
      l.suggestions = (try? store.titleSuggestions(videoId: id)) ?? []
      do {
        l.edit = try store.edit(videoId: id)
        l.versions = try store.versions(videoId: id)
      } catch {
        l.readOnly = true
        throw error
      }
      l.posts = try store.posts(where: "video_id=?", [id])
      l.issues = try Validation.issues(video: v, store: store)
    } catch {
      l.error = l.readOnly ? "This clip's saved edit can't be read, so editing is off to protect it. Run Doctor."
        : "Couldn't load: \(error)"
    }
    return l
  }

  /// Switches to a clip. Pending edits (and a typed, uncommitted Title) are saved first; the store is read on the
  /// save queue — never on the main thread — except in snapshot mode, which renders synchronously.
  func load(_ id: String) {
    commitTitleDraft()  // switching clips is an explicit commit point for a typed Title
    flush()  // queued before the read below on the same serial queue
    loadToken &+= 1
    let token = loadToken
    videoId = id
    versionNo = 1
    loadError = nil
    readOnly = false
    video = nil
    edit = Edit()
    versions = []
    posts = []
    issues = []
    suggestions = []
    fileURL = nil
    openPlatformCaption = nil
    titleDraft = nil
    loading = true
    clearUndo()
    playback.unload()
    let store = store
    if snapshotMode {
      apply(Self.saveQueue.sync { Self.read(store, id) }, token: token)
    } else {
      Self.saveQueue.async { [weak self] in
        let l = Self.read(store, id)
        DispatchQueue.main.async { self?.apply(l, token: token) }
      }
    }
  }

  private func apply(_ l: Loaded, token: Int) {
    guard token == loadToken else { return }  // a newer load won (also A → B → A)
    loading = false
    settings = l.settings; sets = l.sets; templates = l.templates; lastCrop = l.lastCrop
    video = l.video; sessionName = l.sessionName; fileURL = l.fileURL; fileMissing = l.fileMissing
    suggestions = l.suggestions; edit = l.edit; versions = l.versions; posts = l.posts; issues = l.issues
    readOnly = l.readOnly; loadError = l.error
    if let v = l.video, let w = v.sourceWidth, let h = v.sourceHeight, w > 0, h > 0 { sourceSize = CGSize(width: w, height: h) }
    if !posting(previewPlatform) { previewPlatform = postingPlatforms.first ?? .tiktok }
    refreshOverlay()
    if let url = fileURL, !fileMissing {
      if snapshotMode {
        if let p = try? Media.probe(url) { apply(p) }
        playback.loadStill(url: url, at: trim.start, maxSize: CGSize(width: 1920, height: 1080))
      } else {
        Task.detached(priority: .userInitiated) { [weak self] in
          guard let p = try? Media.probe(url) else { return }
          await self?.applyProbe(p, url: url)
        }
        playback.load(url: url, start: trim.start)
      }
    }
    playback.trimProvider = { [weak self] in self?.trim ?? TrimRange(start: 0, end: 0) }
  }

  private func applyProbe(_ p: ProbeInfo, url: URL) {
    if fileURL == url { apply(p) }
  }

  private func apply(_ p: ProbeInfo) {
    guard p.width > 0, p.height > 0 else { return }
    let size = CGSize(width: p.width, height: p.height)
    if p.fps > 0 { fps = p.fps }
    guard size != sourceSize || video?.sourceWidth == nil else { return }
    sourceSize = size
    refreshOverlay()
    if video?.sourceWidth != p.width || video?.sourceHeight != p.height, !snapshotMode, !readOnly {
      let store = store, id = videoId
      Self.saveQueue.async { try? store.setSourceSize(id, width: p.width, height: p.height) }
    }
  }

  // MARK: Derived — edit

  var duration: Double { video?.duration ?? 0 }
  var defaults: NewClipDefaults { settings.defaults }

  /// The edit with the defaults applied (markers trim, default aspect/crop anchor/cover…).
  var resolvedEdit: ResolvedEdit {
    guard let v = video else {
      return ResolvedEdit(aspect: .r9x16, crop: nil, cropConfirmed: false, trimIn: 0, trimOut: 0, coverTime: 0,
                          coverIncludesText: true, platformTrims: [:], skippedPlatforms: [], defaulted: Set(EditField.allCases))
    }
    return EditResolver.resolve(edit, video: v, defaults: defaults, sourceSize: sourceSize, lastUsedCrop: lastCrop)
  }

  var aspect: Aspect { resolvedEdit.aspect }
  var trim: TrimRange { resolvedEdit.trim() }
  /// The default trim (markers ± extra seconds, or the whole file).
  var defaultTrim: TrimRange { video.map { defaults.trim(for: $0) } ?? TrimRange(start: 0, end: 0) }
  var cropIsSet: Bool { edit.crop != nil }
  /// The crop exactly as the export uses it (even pixels, `Media.pixelCrop`).
  var crop: CropRect {
    if let c = edit.crop { return EditorGeometry.even(c, source: sourceSize) }
    if let c = resolvedEdit.crop { return EditorGeometry.even(c, source: sourceSize) }
    return EditorGeometry.defaultCrop(source: sourceSize, aspect: aspect)
  }
  var zoom: Double { EditorGeometry.zoom(of: crop, source: sourceSize, aspect: aspect) }
  var upscale: Double { EditorGeometry.upscale(crop, aspect: aspect) }
  var coverTime: Double { resolvedEdit.coverTime }

  func isDefault(_ f: EditField) -> Bool { resolvedEdit.isDefault(f) }
  var trimIsDefault: Bool { isDefault(.trimIn) && isDefault(.trimOut) }

  // MARK: Derived — version

  var resolved: ResolvedVersion {
    VersionResolver.resolve(versions.isEmpty ? [Version(number: 1)] : versions, number: versionNo, settings: settings, video: video)
  }

  var versionNumbers: [Int] {
    let n = versions.map(\.number)
    return n.isEmpty ? [1] : (n.contains(1) ? n : [1] + n).sorted()
  }

  /// The version a carried-forward field comes from ("from v1"), nil when it's this version's own or a default.
  func source(of field: String) -> Int? {
    guard resolved.inherited.contains(field) else { return nil }
    let earlier = versions.filter { $0.number < versionNo }.sorted { $0.number > $1.number }
    for v in earlier {
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

  /// Field state for the "Custom ↺" tag: nil = follows the default; else whether this version can reset it.
  func versionFieldIsCustom(_ fields: [String]) -> Bool { fields.contains { !resolved.isDefault($0) } }

  // MARK: Derived — platforms

  var activePlatforms: [Platform] { EditorPlatforms.order.filter { settings.enabledPlatforms.contains($0) } }
  func posting(_ p: Platform) -> Bool { settings.enabledPlatforms.contains(p) && !resolvedEdit.isSkipped(p) }
  var postingPlatforms: [Platform] { activePlatforms.filter { posting($0) } }

  // MARK: Derived — captions

  var hashtags: [String] { Captions.hashtags(resolved, sets: sets) }

  func caption(for p: Platform) -> String {
    guard let v = video else { return "" }
    return Captions.caption(for: p, version: resolved, video: v, sessionName: sessionName, sets: sets,
                            templates: templates, settings: settings)
  }

  /// The caption most platforms share (no per-platform caption) — what the caption field shows when empty.
  var mainCaption: String {
    let base = postingPlatforms.first { resolved.platformCaptions[$0] == nil && defaults.platformCaptionTemplates[$0] == nil }
    return caption(for: base ?? postingPlatforms.first ?? .tiktok)
  }

  func captionLimit(_ p: Platform) -> Int { settings.limits[p]?.captionLimit ?? 2200 }

  /// Platforms near (≥ 90 %) or over their caption limit.
  var captionWarnings: [EditorCaptionWarning] {
    guard let v = video else { return [] }
    let r = resolved
    let tags = !hashtags.isEmpty
    return postingPlatforms.compactMap { p in
      let n = caption(for: p).count, lim = captionLimit(p)
      guard EditorGeometry.lengthLevel(count: n, limit: lim) != .ok else { return nil }
      let bare = tags && (r.platformCaptions[p] ?? "").isEmpty
        ? Captions.withoutHashtags(for: p, version: r, video: v, sessionName: sessionName, templates: templates, settings: settings).count
        : nil
      return EditorCaptionWarning(platform: p, count: n, limit: lim, countWithoutHashtags: bare)
    }
  }

  var youtubeTitleDefault: String {
    guard let v = video else { return "" }
    var r = resolved
    r.youtubeTitle = ""
    return Captions.youtubeTitle(r, video: v, settings: settings)
  }

  var youtubeTitle: String {
    guard let v = video else { return "" }
    return Captions.youtubeTitle(resolved, video: v, settings: settings)
  }

  /// "Posted on TikTok, Instagram" etc. for the version list.
  func usage(of number: Int) -> (posted: [Platform], planned: [Platform]) {
    let mine = posts.filter { $0.versionNo == number }
    return (mine.filter { $0.state == .posted }.map(\.platform).sorted(),
            mine.filter { !$0.state.isTerminal }.map(\.platform).sorted())
  }

  // MARK: Derived — title

  var title: String? { video?.titleText }
  var rawTag: String { video?.tag ?? "" }
  var needsTitleHelp: Bool { video.map { AgentPrompts.needsTitleHelp($0, suggestions: suggestions) } ?? false }

  // MARK: Live validation

  /// Store issues, with crop/text/length checks recomputed live from the in-memory edit and version.
  var liveIssues: [ValidationIssue] {
    guard let v = video else { return issues }
    let live: Set<ValidationIssue.Kind> = [.noCrop, .noText, .tooLong, .captionTooLong, .titleTooLong]
    var out = issues.filter { !live.contains($0.kind) }
    if v.type == .short {
      if edit.crop == nil { out.append(.init(kind: .noCrop, platform: nil, message: "Confirm the crop")) }
      let r = resolved
      if !r.hasText && !r.noText {
        out.append(.init(kind: .noText, platform: nil,
                         message: v.titleText == nil && r.isDefault("text") ? "Add text (no title yet)" : "Add text or choose No text"))
      }
      out += Validation.platformIssues(video: v, resolved: resolvedEdit, settings: settings)
      for w in captionWarnings where w.over {
        out.append(.init(kind: .captionTooLong, platform: w.platform,
                         message: "Caption too long for \(w.platform.displayName) (\(w.count)/\(w.limit))",
                         count: Double(w.count), limit: Double(w.limit), countWithoutHashtags: w.countWithoutHashtags))
      }
      if posting(.youtube) {
        let lim = settings.limits[.youtube]?.titleLimit ?? 100, n = youtubeTitle.count
        if n > lim {
          out.append(.init(kind: .titleTooLong, platform: .youtube, message: "YouTube title too long (\(n)/\(lim))",
                           count: Double(n), limit: Double(lim)))
        }
      }
    }
    return out
  }

  static func section(for k: ValidationIssue.Kind) -> EditorSection {
    switch k {
    case .noCrop: .frame
    case .noText: .text
    case .noTitle: .title
    case .tooLong: .platforms
    default: .caption
    }
  }

  // MARK: Safe zones (view preference, remembered per aspect)

  var zonePlatforms: Set<Platform> {
    get { zoneSelections[aspect.rawValue] ?? storedZones(aspect) }
    set {
      zoneSelections[aspect.rawValue] = newValue
      Self.defaults.set(newValue.map(\.rawValue).sorted(), forKey: "editor.safeZones.\(aspect.rawValue)")
    }
  }

  private func storedZones(_ a: Aspect) -> Set<Platform> {
    if let raw = Self.defaults.array(forKey: "editor.safeZones.\(a.rawValue)") as? [String] {
      return Set(raw.compactMap(Platform.init))
    }
    return defaults.safeZonePlatforms
  }

  // MARK: Preview

  func phoneContent(_ p: Platform) -> PhoneMockContent {
    let tracks = video?.titleTracks ?? []
    let sound = tracks.isEmpty ? "Original audio"
      : tracks.map { t in t.artist.map { "\(t.title) · \($0)" } ?? t.title }.joined(separator: " x ")
    return PhoneMockContent(platform: p, caption: caption(for: p), youtubeTitle: youtubeTitle, handle: PlatformUI.handle(p),
                            displayName: "DJ Lovd", soundLine: sound, durationText: EditorGeometry.time(trim.duration),
                            aspect: aspect)
  }

  func stepPreview(_ d: Int) {
    let list = EditorPlatforms.order
    guard let i = list.firstIndex(of: previewPlatform) else { return }
    previewPlatform = list[(i + d + list.count) % list.count]
  }

  // MARK: Mutations — edit

  /// `live: true` while a trim handle is being dragged: trim-dependent values are only re-clamped on `commitTrim()`.
  func updateEdit(live: Bool = false, _ f: (inout Edit) -> Void) {
    guard !readOnly, video != nil else { return }
    var e = edit
    f(&e)
    guard e != edit else { return }
    markUndo()
    let oldTrim = trim
    edit = e
    pendingEdit = true
    if trim != oldTrim && !live { keepInsideTrim() }
    scheduleSave()
    refreshOverlay()
  }

  func resetEdit(_ fields: EditField...) {
    updateEdit { e in for f in fields { EditResolver.reset(&e, f) } }
  }

  /// After a trim drag ends: cover time stays inside the trim, and every version's text timing (relative to
  /// the trim start) stays inside the new trim length.
  func commitTrim() {
    trimDragging = false
    guard !readOnly, video != nil else { return }
    keepInsideTrim()
    scheduleSave()
    refreshOverlay()
  }

  private func keepInsideTrim() {
    let t = trim
    if let c = edit.coverTime, c < t.start || c > t.end {
      edit.coverTime = min(max(c, t.start), max(t.start, t.end - 0.05))
      pendingEdit = true
    }
    for i in versions.indices where versions[i].textStart != nil || versions[i].textEnd != nil {
      let (s, e) = EditorGeometry.clampTextTiming(start: versions[i].textStart, end: versions[i].textEnd, trimDuration: t.duration)
      if s != versions[i].textStart || e != versions[i].textEnd {
        versions[i].textStart = s
        versions[i].textEnd = e
        pendingVersions.insert(versions[i].number)
      }
    }
  }

  /// Trim in (absolute seconds); the default value clears the override so the field reads Default again.
  func setTrimIn(_ t: Double, live: Bool = false) {
    if live && !trimDragging { trimDragging = true }
    let d = defaultTrim.start
    updateEdit(live: live) { $0.trimIn = EditorGeometry.override(max(0, t), default: d) }
  }

  func setTrimOut(_ t: Double, live: Bool = false) {
    if live && !trimDragging { trimDragging = true }
    let d = defaultTrim.end
    updateEdit(live: live) { $0.trimOut = EditorGeometry.override(min(duration, t), default: d) }
  }

  func setCrop(_ c: CropRect) { updateEdit { $0.crop = EditorGeometry.clamp(c, source: sourceSize) } }
  func confirmCrop() { setCrop(crop) }

  /// Moves the crop to the left third / centre / right third of the source (keeps zoom).
  func placeCrop(atX fx: Double) {
    let c = crop
    setCrop(CropRect(x: fx * sourceSize.width - c.w / 2, y: c.y, w: c.w, h: c.h))
  }

  func setAspect(_ a: Aspect) {
    let old = aspect
    updateEdit {
      $0.aspectOverride = a == defaults.aspect ? nil : a
      if let c = $0.crop { $0.crop = EditorGeometry.crop(c, aspect: a, from: old, source: sourceSize) }
    }
  }

  func setZoom(_ z: Double) { setCrop(EditorGeometry.crop(crop, zoom: z, source: sourceSize, aspect: aspect)) }

  func setCover(_ t: Double) {
    let tr = trim
    let c = min(max(t, tr.start), tr.end)
    updateEdit { $0.coverTime = c }
  }

  func setCoverIncludesText(_ on: Bool) {
    updateEdit { $0.coverIncludesTextOverride = on == defaults.coverIncludesText ? nil : on }
  }

  /// Turns posting on/off for one platform as an override on top of `defaults.platforms`.
  func setPosting(_ p: Platform, _ on: Bool) {
    let d = defaults
    updateEdit { EditorGeometry.setPosting(&$0, p, on, defaults: d) }
  }

  /// "Trim for X": opens the per-platform trim lane, starting from the main trim cut to the platform limit.
  func addPlatformTrim(_ p: Platform) {
    let t = trim
    let lim = settings.limits[p]?.maxDuration ?? t.duration
    updateEdit { $0.platformTrims[p] = TrimRange(start: t.start, end: min(t.end, t.start + lim)) }
  }

  func setKind(_ k: Kind) {
    guard var v = video, v.kind != k, !readOnly else { return }
    markUndo(coalesce: false)
    v.kind = k
    video = v
    refreshOverlay()
    let store = store, id = videoId
    Self.saveQueue.async {
      try? store.setKind(id, k)
      ChangeSignal.post()
    }
  }

  // MARK: Mutations — title

  /// Sets Eric's title (nil/empty clears it). The overlay text default follows it mechanically.
  func setTitle(_ t: String?, tracks: [Track]? = nil, source: String = "app") {
    guard var v = video, !readOnly else { return }
    let clean = t?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (clean?.isEmpty ?? true) ? nil : clean
    guard value != v.titleText || tracks != v.titleTracks else { return }
    markUndo(coalesce: false)
    v.title = value
    v.titleTracks = value == nil ? nil : tracks
    v.titleSource = value == nil ? nil : source
    video = v
    refreshOverlay()
    let store = store, id = videoId
    saving = true
    Self.saveQueue.async { [weak self] in
      do {
        try store.setTitle(id, value, tracks: tracks, source: source)
        let fresh = try store.video(id: id) ?? v
        let issues = try Validation.issues(video: fresh, store: store)
        ChangeSignal.post()
        DispatchQueue.main.async {
          guard let self, self.videoId == id else { return }
          self.issues = issues
          self.saving = self.pendingEdit || !self.pendingVersions.isEmpty
          self.lastSaved = Date()
        }
      } catch {
        DispatchQueue.main.async { self?.saving = false; self?.loadError = "Couldn't save the title: \(error)" }
      }
    }
  }

  /// Saves a typed Title that hasn't been committed (↩ / blur don't happen on ⌘] or Done).
  func commitTitleDraft() {
    guard let d = titleDraft else { return }
    titleDraft = nil
    let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
    if t != (title ?? "") { setTitle(t.isEmpty ? nil : t) }
  }

  func accept(_ s: TitleSuggestion) { titleDraft = nil; setTitle(s.text, tracks: s.tracks.isEmpty ? nil : s.tracks, source: "suggestion") }

  /// Copies the "Ask an agent" prompt for this clip (a deterministic template; the agent answers via `djq suggest`).
  func copyAgentPrompt() {
    do {
      let md = try AgentPrompts.titles(for: [videoId], store: store)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(md, forType: .string)
      show("Prompt copied · paste it to your agent")
    } catch {
      show("Couldn't build the prompt: \(error)")
    }
  }

  func show(_ message: String) {
    toast = message
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  // MARK: Mutations — version

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
    markUndo()
    if inserted { pendingVersions.insert(1) }
    all[i] = v
    versions = all.sorted { $0.number < $1.number }
    pendingVersions.insert(versionNo)
    scheduleSave()
    refreshOverlay()
  }

  /// What `kp` resolves to on this version if this version didn't set it (an earlier version's value or the default).
  func fallback<T>(_ kp: WritableKeyPath<Version, T?>, _ resolvedKP: KeyPath<ResolvedVersion, T>) -> T {
    var vs = versions.isEmpty ? [Version(number: 1)] : versions
    if let i = vs.firstIndex(where: { $0.number == versionNo }) { vs[i][keyPath: kp] = nil }
    return VersionResolver.resolve(vs, number: versionNo, settings: settings, video: video)[keyPath: resolvedKP]
  }

  /// Sets a version field; a value equal to what it would fall back to is stored as nil, so clicking the current
  /// default never creates a "Custom" override (#10).
  func setVersionField<T: Equatable>(_ kp: WritableKeyPath<Version, T?>, _ resolvedKP: KeyPath<ResolvedVersion, T>, _ value: T) {
    let fb = fallback(kp, resolvedKP)
    updateVersion { $0[keyPath: kp] = value == fb ? nil : value }
  }

  /// Hashtag sets: same rule, compared as a set (order follows the Settings list).
  func setHashtagSets(_ ids: [String]) {
    let fb = fallback(\.hashtagSetIds, \.hashtagSetIds)
    updateVersion { $0.hashtagSetIds = Set(ids) == Set(fb) ? nil : ids }
  }

  func setExtraHashtags(_ tags: [String]) {
    let fb = fallback(\.extraHashtags, \.extraHashtags)
    updateVersion { $0.extraHashtags = tags == fb ? nil : tags }
  }

  /// Caption template: picking the default template (or "Default") follows the default.
  func setCaptionTemplate(_ id: String?) {
    var vs = versions.isEmpty ? [Version(number: 1)] : versions
    if let i = vs.firstIndex(where: { $0.number == versionNo }) { vs[i].captionTemplateId = nil }
    let fb = VersionResolver.resolve(vs, number: versionNo, settings: settings, video: video).captionTemplateId
    let value = id.flatMap { $0.isEmpty ? nil : $0 }
    updateVersion { $0.captionTemplateId = value == fb || (fb == nil && value == defaults.captionTemplateId) ? nil : value }
  }

  /// Typed overlay text. An empty field is an explicit "empty" (it must not snap back to the Title); "Follow the
  /// Title" is the reset (`resetVersion(["text"])`).
  func setText(_ t: String) {
    updateVersion { v in
      if t.isEmpty { v.text = ""; v.noText = false } else { v.text = t; v.noText = nil }
    }
  }

  /// "No text" on/off. Off goes back to following the default text when nothing was typed (a talking clip, whose
  /// default is "No text", gets an explicit off).
  func setNoText(_ on: Bool) {
    if on { updateVersion { $0.noText = true }; return }
    updateVersion { v in
      v.noText = nil
      if (v.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { v.text = nil }
    }
    if resolved.noText { updateVersion { $0.noText = false } }
  }

  /// Clears this version's own value for the fields (they fall back to an earlier version or the defaults).
  func resetVersion(_ fields: [String]) {
    updateVersion { v in
      for f in fields {
        switch f {
        case "text": v.text = nil; v.noText = nil
        case "noText": v.noText = nil; v.text = nil
        case "style": v.style = nil
        case "size": v.size = nil
        case "posX", "posY": v.posX = nil; v.posY = nil
        case "align": v.align = nil
        case "textStart", "textEnd": v.textStart = nil; v.textEnd = nil
        case "caption": v.caption = nil
        case "captionTemplateId": v.captionTemplateId = nil
        case "hashtagSetIds": v.hashtagSetIds = nil
        case "extraHashtags": v.extraHashtags = nil
        case "youtubeTitle": v.youtubeTitle = nil
        case "platformCaptions": v.platformCaptions = nil
        default: break
        }
      }
    }
  }

  /// True when this version itself sets one of the fields (so ↺ can clear it); inherited values can't be reset here.
  func ownsField(_ fields: [String]) -> Bool {
    let own = versions.first { $0.number == versionNo }
    guard let v = own else { return false }
    return fields.contains { f in
      switch f {
      case "text", "noText": v.text != nil || v.noText != nil
      case "style": v.style != nil
      case "size": v.size != nil
      case "posX", "posY": v.posX != nil || v.posY != nil
      case "align": v.align != nil
      case "textStart", "textEnd": v.textStart != nil || v.textEnd != nil
      case "caption": v.caption != nil
      case "captionTemplateId": v.captionTemplateId != nil
      case "hashtagSetIds": v.hashtagSetIds != nil
      case "extraHashtags": v.extraHashtags != nil
      case "youtubeTitle": v.youtubeTitle != nil
      case "platformCaptions": v.platformCaptions != nil
      default: false
      }
    }
  }

  func setPlatformCaption(_ p: Platform, _ text: String?) {
    var m = resolved.platformCaptions
    m[p] = text
    updateVersion { $0.platformCaptions = m.isEmpty ? nil : m }
  }

  /// "Drop hashtags for X": writes the same caption without hashtags as X's own caption (explicit, undoable).
  func dropHashtags(_ p: Platform) {
    guard let v = video else { return }
    let bare = Captions.withoutHashtags(for: p, version: resolved, video: v, sessionName: sessionName, templates: templates,
                                        settings: settings)
    setPlatformCaption(p, bare)
    show("\(p.displayName) now has its own caption without hashtags")
  }

  /// "Write an X caption": starts X's own caption from the current one and opens it.
  func writePlatformCaption(_ p: Platform) {
    if resolved.platformCaptions[p] == nil { setPlatformCaption(p, caption(for: p)) }
    openPlatformCaption = p
    scrollTarget = .caption
  }

  func newVersion(copying source: Int?) {
    guard !readOnly else { return }
    flush()
    markUndo(coalesce: false)
    let n = (versions.map(\.number).max() ?? 1) + 1
    var v = Version(number: n)
    if let s = source, s != versions.map(\.number).max() ?? 1 {
      let r = VersionResolver.resolve(versions, number: s, settings: settings, video: video)
      if !r.isDefault("text") { v.text = r.text; v.noText = r.noText }
      if !r.isDefault("style") { v.style = r.style }
      if !r.isDefault("size") { v.size = r.size }
      if !r.isDefault("posX") { v.posX = r.posX; v.posY = r.posY }
      if !r.isDefault("align") { v.align = r.align }
      if !r.isDefault("textStart") || !r.isDefault("textEnd") { v.textStart = r.textStart; v.textEnd = r.textEnd }
      if !r.caption.isEmpty { v.caption = r.caption }
      v.captionTemplateId = r.captionTemplateId
      if !r.isDefault("extraHashtags") { v.extraHashtags = r.extraHashtags }
      if !r.isDefault("hashtagSetIds") { v.hashtagSetIds = r.hashtagSetIds }
      if !r.youtubeTitle.isEmpty { v.youtubeTitle = r.youtubeTitle }
      if !r.platformCaptions.isEmpty { v.platformCaptions = r.platformCaptions }
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
    markUndo(coalesce: false)
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

  // MARK: Undo (round 3, F8) — the editor's own history, separate from the app's ⌘Z

  /// Everything an editor change can touch. ⌘Z restores the one before the last change (and saves it).
  struct UndoState: Equatable {
    var edit: Edit
    var versions: [Version]
    var versionNo: Int
    var title: String?
    var titleTracks: [Track]?
    var titleSource: String?
    var kind: Kind?
  }

  private var undoStack: [UndoState] = []
  private var redoStack: [UndoState] = []
  private var lastUndoMark = Date.distantPast
  private var restoringUndo = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false

  private var undoState: UndoState {
    UndoState(edit: edit, versions: versions, versionNo: versionNo, title: video?.title, titleTracks: video?.titleTracks,
              titleSource: video?.titleSource, kind: video?.kind)
  }

  /// Called just BEFORE a change. Changes less than 0.8 s apart (a drag, a typed word, a slider) form one step.
  private func markUndo(coalesce: Bool = true) {
    guard !restoringUndo, !readOnly, video != nil else { return }
    let now = Date()
    defer { lastUndoMark = coalesce ? now : .distantPast }
    if coalesce && now.timeIntervalSince(lastUndoMark) < 0.8 { return }
    undoStack.append(undoState)
    if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
    redoStack.removeAll()
    canUndo = true
    canRedo = false
  }

  private func clearUndo() {
    undoStack = []
    redoStack = []
    lastUndoMark = .distantPast
    canUndo = false
    canRedo = false
  }

  func undo() {
    guard !readOnly, let s = undoStack.popLast() else { show("Nothing to undo in this clip"); return }
    redoStack.append(undoState)
    restoreUndo(s)
    show("Undone")
  }

  func redo() {
    guard !readOnly, let s = redoStack.popLast() else { show("Nothing to redo"); return }
    undoStack.append(undoState)
    restoreUndo(s)
    show("Redone")
  }

  private func restoreUndo(_ s: UndoState) {
    restoringUndo = true
    defer {
      restoringUndo = false
      lastUndoMark = .distantPast
      canUndo = !undoStack.isEmpty
      canRedo = !redoStack.isEmpty
    }
    let gone = Set(versions.map(\.number)).subtracting(s.versions.map(\.number)).filter { $0 > 1 }
    edit = s.edit
    pendingEdit = true
    versions = s.versions
    pendingVersions.formUnion(s.versions.map(\.number))
    versionNo = s.versions.contains { $0.number == s.versionNo } ? s.versionNo : 1
    if !gone.isEmpty {
      let store = store, id = videoId
      Self.saveQueue.async {
        for n in gone { try? store.deleteVersion(videoId: id, number: n) }
        ChangeSignal.post()
      }
    }
    if s.title != video?.title || s.titleTracks != video?.titleTracks { setTitle(s.title, tracks: s.titleTracks, source: s.titleSource ?? "app") }
    if let k = s.kind, k != video?.kind { setKind(k) }
    scheduleSave()
    refreshOverlay()
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
    commitTitleDraft()  // Done / ⌘↩ / closing are explicit commit points; the 300 ms autosave isn't
    flush()
    Self.saveQueue.sync {}
  }

  // MARK: Text overlay (TextOverlay PNG drawn over the player — preview == export)

  private struct OverlayKey: Hashable { var v: ResolvedVersion; var a: Aspect }

  func refreshOverlay() {
    let key = OverlayKey(v: resolved, a: aspect)
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
    guard let b = TextOverlay.textBounds(for: resolved, aspect: aspect) else { return nil }
    let o = aspect.outputSize
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

  func skip(_ seconds: Double) {
    pause()
    seek(max(0, time + seconds), exact: true)
  }
}
