import AVFoundation
import AppKit
import Combine
import DJQCore
import Foundation
import SwiftUI

/// Inspector sections, in scroll order (the sticky mini-index jumps to them).
enum EditorSection: String, CaseIterable, Identifiable {
  case title = "Title", frame = "Frame", text = "Text", caption = "Caption", cover = "Cover", platforms = "Platforms"
  /// Round 21: not an inspector section. The photos strip under the canvas, where a photo post's pictures are fixed.
  case photos = "Photos"
  var id: String { rawValue }

  /// The inspector's sections, in scroll order. A photo post has no Cover: its first photo is the cover (D15).
  static func inspector(photo: Bool) -> [EditorSection] {
    photo ? [.title, .frame, .text, .caption, .platforms] : [.title, .frame, .text, .caption, .cover, .platforms]
  }
}

/// The inspector's collapsible rows. All closed at launch; what Eric opens stays open while the app runs, across clips, so
/// the state outlives an `EditorModel` (S4-R2).
enum EditorDisclosure: Hashable {
  case frame, cover, sizeAndPosition, advanced
}

@MainActor
final class EditorDisclosures: ObservableObject {
  static let shared = EditorDisclosures()
  @Published private(set) var open: Set<EditorDisclosure> = []

  func isOpen(_ d: EditorDisclosure) -> Bool { open.contains(d) }
  func set(_ d: EditorDisclosure, _ on: Bool) { if on { open.insert(d) } else { open.remove(d) } }
  func binding(_ d: EditorDisclosure) -> Binding<Bool> { Binding(get: { self.isOpen(d) }, set: { self.set(d, $0) }) }

  /// Nothing can point at a hidden field: whatever lands on a closed section opens it first.
  func reveal(_ s: EditorSection) {
    switch s {
    case .frame: set(.frame, true)
    case .cover: set(.cover, true)
    default: break
    }
  }

  /// Back to the launch state (snapshots, scripts).
  func closeAll() { open = [] }
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

/// The Caption section's inline hashtag group form: `id` nil = a new group, else the group being edited. `name` and
/// `tags` only seed the form (it owns the text while Eric types, so keystrokes don't redraw the editor).
struct EditorGroupForm: Identifiable, Equatable {
  var editing: String?
  var name = ""
  var tags = ""
  /// What saving an edit reaches, from when the form opened.
  var impact: HashtagGroups.Impact?
  var id: String { "\(editing ?? "new")|\(name)|\(tags)" }
}

/// The caption template form, open for a new template (`editing` nil) or one being edited.
struct EditorTemplateForm: Identifiable {
  var editing: String?
  var name = ""
  var template = ""
  /// What saving an edit reaches, from when the form opened.
  var impact: HashtagGroups.Impact?
  var id: String { "\(editing ?? "new")|\(name)|\(template)" }
}

/// What the app gives the editor (nil in the snapshot harnesses, which have no `AppModel`).
struct EditorAppHooks {
  /// Asks the app to delete a template (its confirm + journaled undo, same as Settings).
  var deleteTemplate: ((CaptionTemplate) -> Void)?
  /// Asks the app to delete a group (its confirm + journaled undo, same as Settings).
  var deleteGroup: ((HashtagSet) -> Void)?
  /// Journals the editor session so far, so a group change sits after it in the history (`splitEditorSession`).
  var beforeGroupWrite: (() -> Void)?
  /// A group edit landed: into the app's history (the session moves past it) with its Undo, saying `message`.
  var afterGroupEdit: ((BulkResult, String) -> Void)?
  /// True while an overlay covers the editor.
  var isCovered: (() -> Bool)?
  /// How far ← / → jump (Settings → Playback, or the step chip beside Play). Nil = the editor keeps its own (harness).
  var arrowStep: (() -> ArrowStep)?
  var setArrowStep: ((ArrowStep) -> Void)?
  /// Round 23: the Audio row asks the app to pick a file and make the video (or take the audio off); the app reloads
  /// this editor when it lands.
  var addAudio: ((String) -> Void)?
  var changeAudio: ((String) -> Void)?
  var removeAudio: ((String) -> Void)?
  /// D12: Whole photo or Fill the frame. The app makes the video again and reloads this editor.
  var setAudioFit: ((String, StillSource.Fit) -> Void)?
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
  @Published private(set) var video: Video? { didSet { resolvedCache = nil } }
  @Published private(set) var sessionName = ""
  @Published private(set) var fileURL: URL?
  @Published private(set) var fileMissing = false
  @Published private(set) var sourceSize = CGSize(width: 3840, height: 2160)
  @Published private(set) var fps = 30000.0 / 1001
  @Published var edit = Edit()
  @Published private(set) var versions: [Version] = [] { didSet { resolvedCache = nil } }
  @Published var versionNo = 1 { didSet { resolvedCache = nil } }
  @Published private(set) var settings = Settings() { didSet { resolvedCache = nil } }
  @Published private(set) var sets: [HashtagSet] = []
  @Published private(set) var templates: [CaptionTemplate] = []
  /// The template form under the Template field (nil = closed).
  @Published var templateForm: EditorTemplateForm?
  @Published private(set) var posts: [PlatformPost] = []
  @Published private(set) var issues: [ValidationIssue] = []
  @Published private(set) var suggestions: [TitleSuggestion] = []
  /// On-video text suggestions (`text_suggestions`), best first.
  @Published private(set) var textSuggestions: [TitleSuggestion] = []
  @Published private(set) var lastCrop: CGPoint?
  /// One drawn image per text that shows on the video, in stacking order.
  @Published private(set) var textImages: [EditorTextImage] = []
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
  /// Section the inspector should scroll to (set, then cleared by the inspector). A closed section opens first.
  @Published var scrollTarget: EditorSection? {
    didSet {
      guard let s = scrollTarget else { return }
      EditorDisclosures.shared.reveal(s)
      if s == .photos { flashPhotos &+= 1 }
    }
  }
  /// Bumped when the photos strip should flash: an issue that is fixed there, not in the inspector (round 21).
  @Published private(set) var flashPhotos = 0
  /// Decoded photos, the strip's thumbnails and the composed canvas picture of a photo post (round 21).
  let photoImages = EditorPhotoImages()
  /// True while added photos are being copied in.
  @Published var photoBusy = false
  /// Photos whose file is there but can't be read as a picture (by id): the canvas says so instead of waiting.
  @Published var unreadablePhotos: Set<String> = []
  /// The photos of a photo post whose file isn't on disk (by id). The post is missing while there is one.
  @Published private(set) var missingPhotos: Set<String> = []
  /// Platform whose own caption field should open (Write an X caption).
  @Published var openPlatformCaption: Platform?
  /// The hashtag group form, when it's open.
  @Published var groupForm: EditorGroupForm?
  var appHooks = EditorAppHooks()
  var onDeleteGroup: ((HashtagSet) -> Void)? { appHooks.deleteGroup }
  var onDeleteTemplate: ((CaptionTemplate) -> Void)? { appHooks.deleteTemplate }
  var isCovered: (() -> Bool)? { appHooks.isCovered }
  /// The editor's own arrow step when no app is attached (harness runs).
  @Published private var localArrowStep = ArrowStep.standard
  /// How far ← / → and the jump buttons move the playhead (Eric's choice, shared with Settings → Playback).
  var arrowStep: ArrowStep { appHooks.arrowStep?() ?? localArrowStep }
  func setArrowStep(_ s: ArrowStep) {
    objectWillChange.send()
    if let set = appHooks.setArrowStep { set(s) } else { localArrowStep = s }
  }
  @Published var toast: String?
  /// Evidence runs: the Zones canvas shows just the output (no dimmed text, no handles), to set beside an exported frame.
  @Published var plainCanvasForScript = false
  /// Evidence runs only: brings back the faded copy of a text on a photo it isn't on, so the photo check can show that
  /// it fails on one (`DJQ_PHOTO_EDITOR_SABOTAGE=ghost`). Never set in the app.
  @Published var ghostTextForScript = false
  /// Bumped when Title should take keyboard focus (header title click).
  @Published var focusTitle = 0
  /// True while a clip's data is being read (the canvas shows a spinner, not "not found").
  @Published private(set) var loading = false
  /// Incremented per load; only the latest load's result is applied.
  private var loadToken = 0
  /// A typed Title that hasn't been committed yet (nil = not editing). Saved on ↩, blur, clip switch and Done.
  @Published var titleDraft: String?
  /// Round 23: why the Audio row's actions are off (nil = they work). Cached with the item, never read while drawing.
  @Published var audioBlocker: String?
  /// True while a trim handle is being dragged (expensive derived work waits for the drag end).
  @Published private(set) var trimDragging = false
  @Published private var zoneSelections: [String: Set<Platform>] = [:]

  let playback = EditorPlayback()
  private var pendingEdit = false
  private var pendingVersions = Set<Int>()
  /// The versions as the store last had them, so a hold landing under unsaved work can be told from that work.
  private var syncedVersions: [Version] = []
  private var saveTask: Task<Void, Never>?
  private var overlayTask: Task<Void, Never>?
  private var overlaySignature: [String]?
  private var toastTask: Task<Void, Never>?
  nonisolated(unsafe) private var groupObserver: (center: NotificationCenter, token: NSObjectProtocol)?
  static let saveQueue = DispatchQueue(label: "com.djlovd.queue.editor.save", qos: .userInitiated)

  /// Blocks until every queued editor write has landed (the app journals the session after it).
  static func waitForSaves() { saveQueue.sync {} }
  /// The editor on screen (not snapshot copies): a journaled action flushes its debounced save first (review r4 L6).
  static weak var live: EditorModel?
  /// Writes the on-screen editor's pending (debounced) changes and waits for every save to land.
  static func flushLiveAndWait() {
    live?.flush()
    waitForSaves()
  }
  nonisolated(unsafe) static var defaults = UserDefaults.standard

  init(store: Store, videoId: String, snapshotMode: Bool = false) {
    self.store = store
    self.videoId = videoId
    self.snapshotMode = snapshotMode
    canvasMode = Self.defaults.string(forKey: "editor.canvasMode").flatMap(EditorCanvasMode.init) ?? .zones
    if !snapshotMode { Self.live = self }
    load(videoId)
    // Groups changed elsewhere (Settings over the editor, `djq`, Undo on a delete toast) show up in the chips.
    if !snapshotMode {
      groupObserver = ChangeSignal.observe { [weak self] in
        MainActor.assumeIsolated { self?.reloadGroups() }
      }
    }
  }

  deinit {
    if let groupObserver { groupObserver.center.removeObserver(groupObserver.token) }
  }

  // MARK: Loading

  /// Everything one clip needs, read off the main thread (on the save queue, so it lands after pending writes).
  private struct Loaded: @unchecked Sendable {
    var settings = Settings(), sets: [HashtagSet] = [], templates: [CaptionTemplate] = [], lastCrop: CGPoint?
    var video: Video?, sessionName = "", fileURL: URL?, fileMissing = false, suggestions: [TitleSuggestion] = []
    var textSuggestions: [TitleSuggestion] = []
    var edit = Edit(), versions: [Version] = [], posts: [PlatformPost] = [], issues: [ValidationIssue] = []
    var audioBlocker: String?
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
      l.textSuggestions = (try? store.textSuggestions(videoId: id)) ?? []
      do {
        l.edit = try store.edit(videoId: id)
        l.versions = try store.versions(videoId: id)
      } catch {
        l.readOnly = true
        throw error
      }
      l.posts = try store.posts(where: "video_id=?", [id])
      l.issues = try Validation.issues(video: v, store: store)
      l.audioBlocker = Self.audioBlocker(store, v)
    } catch {
      l.error = l.readOnly ? "This \(l.video?.isPhoto == true ? "post" : "clip")'s saved edit can't be read, so editing is off to protect it. Run Doctor."
        : "Couldn't load: \(error)"
    }
    return l
  }

  /// Switches to a clip. Pending edits (and a typed, uncommitted Title) are saved first; the store is read on the
  /// save queue — never on the main thread — except in snapshot mode, which renders synchronously.
  func load(_ id: String) {
    commitCaptionDraft()
    commitTitleDraft()  // switching clips is an explicit commit point for a typed Title
    commitTimeDraft()  // and for a typed time, or it would land on the next clip when its field blurs
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
    textSuggestions = []
    fileURL = nil
    openPlatformCaption = nil
    groupForm = nil
    titleDraft = nil
    selectedTextRaw = TextLayer.firstId
    loading = true
    clearUndo()
    playback.unload()
    photoImages.reset()
    photoBusy = false
    missingPhotos = []
    unreadablePhotos = []
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
    suggestions = l.suggestions; textSuggestions = l.textSuggestions; edit = l.edit; versions = l.versions; syncedVersions = l.versions; posts = l.posts; issues = l.issues
    readOnly = l.readOnly; loadError = l.error
    audioBlocker = l.audioBlocker
    fieldRevision &+= 1
    if let v = l.video, let w = v.sourceWidth, let h = v.sourceHeight, w > 0, h > 0 { sourceSize = CGSize(width: w, height: h) }
    if !posting(previewPlatform) { previewPlatform = postingPlatforms.first ?? .tiktok }
    refreshOverlay()
    if l.video?.isPhoto == true {
      // Round 21: a photo post has no player, no proxy and nothing to probe. The canvas shows its photos, starting
      // at one whose file is gone when there is one (the post is missing until that photo is back or taken out).
      checkPhotoFiles(wasMissing: l.video?.missing == true)
      selectPhoto(photos.firstIndex { missingPhotos.contains($0.id) } ?? 0)
    } else if let url = fileURL, !fileMissing {
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

  /// The inspector's fields are off: an unreadable edit, or no clip yet. Its collapsible rows still open.
  var fieldsOff: Bool { readOnly || video == nil }

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
  var cropIsSet: Bool {
    if isPhoto { return currentPhoto.map { PhotoRules.hasOwnCrop($0, edit: edit, aspect: aspect) } ?? false }
    // What Core says (`Validation`): the edit has a crop, or the item is a whole-photo video, whose crop is its whole
    // frame with or without one stored (round 23: Crop → Reset must not bring "Confirm the crop" back).
    return resolvedEdit.cropConfirmed
  }
  /// A video made from a photo that shows the whole photo, at the 9:16 it was made in (round 23, D12).
  var isWholePhoto: Bool { video?.still?.fits == .whole && aspect == .r9x16 }
  /// The Crop field shows "Custom" and its Reset: the crop is Eric's own. A whole-photo video's whole frame is how it
  /// was made, not a change, so only a crop he zoomed or moved counts there (and Reset goes back to the whole frame).
  var cropIsCustom: Bool {
    guard isWholePhoto else { return cropIsSet }
    guard let c = edit.crop else { return false }
    let whole = CropRect(x: 0, y: 0, w: Double(sourceSize.width), h: Double(sourceSize.height))
    return EditorGeometry.even(c, source: sourceSize) != EditorGeometry.even(whole, source: sourceSize)
  }
  /// The crop exactly as the export uses it (even pixels, `Media.pixelCrop`). For a photo post: the current photo's.
  var crop: CropRect {
    if isPhoto, let p = currentPhoto { return PhotoRules.crop(for: p, edit: edit, aspect: aspect) }
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

  /// Cached until versions, the version number, settings or the clip change (every view reads it many times per
  /// update; round 7: typing in a long caption re-resolved it dozens of times per keystroke).
  var resolved: ResolvedVersion {
    if let r = resolvedCache { return r }
    let r = VersionResolver.resolve(versions.isEmpty ? [Version(number: 1)] : versions, number: versionNo, settings: settings, video: video)
    resolvedCache = r
    return r
  }
  private var resolvedCache: ResolvedVersion?

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

  /// The caption the field shows and edits (round 7, WYSIWYG): exactly what every platform without its own caption or
  /// its own default template posts — the written caption, else the chosen (or default) template, hashtags included.
  var mainCaption: String {
    guard let v = video else { return "" }
    return Captions.sharedCaption(version: resolved, video: v, sessionName: sessionName, sets: sets, templates: templates,
                                  settings: settings)
  }

  /// True when this version (or an earlier one it carries forward) has a written caption instead of a template.
  var captionIsWritten: Bool { !resolved.caption.isEmpty }

  /// Platforms that post something else than the field: their own caption, or their own default template.
  var platformsWithOtherCaption: [Platform] {
    postingPlatforms.filter { p in
      resolved.platformCaptions[p] != nil || (!captionIsWritten && resolved.captionTemplateId == nil
        && defaults.platformCaptionTemplates[p].map { $0 != defaults.captionTemplateId } == true)
    }
  }

  func captionLimit(_ p: Platform) -> Int { settings.limits[p]?.captionLimit ?? 2200 }

  /// Platforms near (≥ 90 %) or over their caption limit.
  var captionWarnings: [EditorCaptionWarning] {
    guard let v = video else { return [] }
    let r = resolved
    return postingPlatforms.compactMap { p in
      let c = caption(for: p)
      let n = c.count, lim = captionLimit(p)
      guard EditorGeometry.lengthLevel(count: n, limit: lim) != .ok else { return nil }
      // Round 7: "has hashtags to drop" comes from the caption text (typed tags count too).
      let bare = Captions.hasTags(c) && (r.platformCaptions[p] ?? "").isEmpty
        ? Captions.withoutHashtags(for: p, version: r, video: v, sessionName: sessionName, templates: templates, settings: settings, sets: sets).count
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
  /// Round 23: the item's tag is a photo's file name (a photo post, or a video made from a photo), which is never a
  /// title and has no song behind it: no "Use raw tag", no "Ask an agent".
  var namedByFile: Bool { video.map { $0.isPhoto || $0.isStill } ?? false }
  var needsTitleHelp: Bool { video.map { AgentPrompts.needsTitleHelp($0, suggestions: suggestions) } ?? false }

  // MARK: Live validation

  /// Store issues, with crop/text/length checks recomputed live from the in-memory edit and version.
  var liveIssues: [ValidationIssue] {
    guard let v = video else { return issues }
    let live: Set<ValidationIssue.Kind> = [.noCrop, .noText, .tooLong, .captionTooLong, .titleTooLong, .photoShape, .noPhotos]
    var out = issues.filter { !live.contains($0.kind) }
    if v.isPhoto {
      // Round 21: no crop, text, length or YouTube rule. The shape (D20) and the caption are checked as they change.
      if photos.isEmpty { out.append(.init(kind: .noPhotos, platform: nil, message: "Add a photo")) }
      for p in postingPlatforms {
        if let why = PhotoRules.shapeProblem(aspect, platform: p) { out.append(.init(kind: .photoShape, platform: p, message: why)) }
      }
      for w in captionWarnings where w.over {
        out.append(.init(kind: .captionTooLong, platform: w.platform,
                         message: "Caption too long for \(w.platform.displayName) (\(w.count)/\(w.limit))",
                         count: Double(w.count), limit: Double(w.limit), countWithoutHashtags: w.countWithoutHashtags))
      }
    } else if v.type == .short {
      if !resolvedEdit.cropConfirmed { out.append(.init(kind: .noCrop, platform: nil, message: "Confirm the crop")) }
      let r = resolved
      if !r.hasDrawnText && !r.noText {
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

  /// Round 7 (C1): core's exhaustive mapping. nil = no inspector section (held → the stage control; missing file /
  /// unreadable edit → the header says so), so a warning dot never points at a section with nothing to fix.
  static func section(for k: ValidationIssue.Kind) -> EditorSection? {
    switch k.editorSection {
    case .title: .title
    case .frame: .frame
    case .text: .text
    case .caption: .caption
    case .cover: .cover
    case .platforms: .platforms
    case .photos: .photos  // round 21: the photos strip under the canvas (it flashes; the inspector has no such section)
    case nil: nil
    }
  }

  /// Caption-kind issues that aren't a live length warning (e.g. "template doesn't exist"), shown in the Caption section.
  var captionIssues: [ValidationIssue] {
    liveIssues.filter { $0.kind.editorSection == .caption && $0.kind != .captionTooLong && $0.kind != .titleTooLong }
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
                            displayName: "DJ Lovd", soundLine: isPhoto ? "" : sound, durationText: isPhoto ? "" : EditorGeometry.time(trim.duration),
                            aspect: aspect, isPhoto: isPhoto)
  }

  /// The platforms the phone preview and the safe-zone chips offer: every one for a clip, those that take photos for a
  /// photo post (D8).
  var previewOrder: [Platform] { isPhoto ? EditorPlatforms.order.filter(\.supportsPhotos) : EditorPlatforms.order }

  func stepPreview(_ d: Int) {
    let list = previewOrder
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
    guard !isPhoto else { return }  // a window names photo positions; the photo count clamps it when it's read
    let t = trim
    if let c = edit.coverTime, c < t.start || c > t.end {
      edit.coverTime = min(max(c, t.start), max(t.start, t.end - 0.05))
      pendingEdit = true
    }
    for i in versions.indices where versions[i].textStart != nil || versions[i].textEnd != nil {
      // An inverted window means the whole clip (a promoted text has one): clamping would turn it into 0.3 s.
      if let e = versions[i].textEnd, e <= (versions[i].textStart ?? 0) { continue }
      let (s, e) = EditorGeometry.clampTextTiming(start: versions[i].textStart, end: versions[i].textEnd, trimDuration: t.duration)
      if s != versions[i].textStart || e != versions[i].textEnd {
        versions[i].textStart = s
        versions[i].textEnd = e
        pendingVersions.insert(versions[i].number)
      }
    }
    for i in versions.indices {
      guard let list = versions[i].moreText else { continue }
      let kept = list.map { EditorGeometry.clampLayer($0, trimDuration: t.duration) }
      if kept != list {
        versions[i].moreText = kept
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

  func setCrop(_ c: CropRect) {
    if isPhoto { setPhotoCrop(c); return }
    updateEdit { $0.crop = EditorGeometry.clamp(c, source: sourceSize) }
  }
  func confirmCrop() { setCrop(crop) }

  /// Moves the crop to the left third / centre / right third of the source (keeps zoom).
  func placeCrop(atX fx: Double) {
    let c = crop
    setCrop(CropRect(x: fx * sourceSize.width - c.w / 2, y: c.y, w: c.w, h: c.h))
  }

  func setAspect(_ a: Aspect) {
    // A photo post keeps each photo's crop as it is: one that no longer fits the shape is ignored, and comes back
    // with the shape it was made for (`PhotoRules.ownCrop`).
    if isPhoto { updateEdit { $0.aspectOverride = a == defaults.photoAspect ? nil : a }; return }
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
    guard !isPhoto else { return }
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

  /// Puts a text suggestion on the selected text of the current version (typed text, so a first text no longer follows
  /// the Title). One undo step per tap; tapping the text that's already there changes nothing (it keeps following).
  func acceptText(_ s: TitleSuggestion) {
    guard !isCurrentText(s) else { return }
    guard selectedIsFirst else { updateText(selectedText, coalesce: false) { $0.text = s.text }; return }
    updateVersion(coalesce: false) { v in v.text = s.text; v.noText = nil }
  }

  /// True when the selected text is exactly the suggestion.
  func isCurrentText(_ s: TitleSuggestion) -> Bool { !resolved.noText && selectedLayer.text == s.text }

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

  /// `coalesce: false` for one-shot changes (a chip tap) that get their own undo step. `fromField` = typed into a
  /// caption / YouTube title field (that field keeps its own text); every other change re-syncs those fields
  /// (`fieldRevision`), so a template, group or reset shows up in them at once.
  func updateVersion(coalesce: Bool = true, fromField: Bool = false, _ f: (inout Version) -> Void) {
    guard !readOnly, video != nil else { return }
    if !fromField { commitCaptionDraft() }
    defer { if !fromField { fieldRevision &+= 1 } }
    var all = versions
    var inserted = false
    if !all.contains(where: { $0.number == 1 }) { all.insert(Version(number: 1), at: 0); inserted = true }
    if !all.contains(where: { $0.number == versionNo }) { all.append(Version(number: versionNo)); inserted = true }
    guard let i = all.firstIndex(where: { $0.number == versionNo }) else { return }
    var v = all[i]
    f(&v)
    guard v != all[i] || inserted else { return }
    markUndo(coalesce: coalesce)
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

  /// Hashtag groups: same rule, compared as a set (order follows the Settings list). A written caption gets the
  /// hashtags swapped in place (round 7, `Captions.retag`); a template caption follows by itself.
  func setHashtagSets(_ ids: [String]) {
    let fb = fallback(\.hashtagSetIds, \.hashtagSetIds)
    retagging(coalesce: false) { $0.hashtagSetIds = Set(ids) == Set(fb) ? nil : ids }
  }

  /// One group on or off for this clip (a chip tap, or a group just made): one undo step.
  func setGroup(_ id: String, on: Bool) {
    var ids = sets.map(\.id).filter { resolved.hashtagSetIds.contains($0) }
    ids.removeAll { $0 == id }
    if on { ids.append(id) }
    setHashtagSets(ids)
  }

  /// Why groups can't be made or changed here right now (nil = they can).
  var groupsOffReason: String? {
    if readOnly { return EditorView.readOnlyReason }
    return video == nil ? "The clip is still loading" : nil
  }

  /// The form opens empty for a new group, or filled in for `group`.
  func openGroupForm(_ group: HashtagSet? = nil) {
    guard groupsOffReason == nil else { return }
    guard let group else { groupForm = EditorGroupForm(); return }
    let store = store
    let impact = Self.saveQueue.sync { try? HashtagGroups.impact(of: group.id, store: store) }
    groupForm = EditorGroupForm(editing: group.id, name: group.name, tags: group.tags.joined(separator: " "), impact: impact)
  }

  /// Saves the form into the same table Settings and `djq` use. A new group is available to every clip and goes on for
  /// this one (its own undo step; the group itself stays after ⌘Z). A typed caption is applied first, so its text is kept.
  @discardableResult
  func saveGroup(name: String, tags raw: String) -> Bool {
    guard groupsOffReason == nil else { return false }
    let tags = HashtagGroups.parseTags(raw), editing = groupForm?.editing
    guard HashtagGroups.problem(name: name, tags: tags, existing: sets, editing: editing) == nil else { return false }
    commitCaptionDraft()
    if let editing {
      guard let old = sets.first(where: { $0.id == editing }) else {  // deleted while the form was open
        groupForm = nil
        show("That group was deleted")
        return false
      }
      return updateGroup(old, name: name, tags: tags)
    }
    return createGroup(name: name, tags: tags)
  }

  private func createGroup(name: String, tags: [String]) -> Bool {
    let group = HashtagGroups.make(name: name, tags: tags, existing: sets)
    guard writeGroup({ try HashtagGroups.create(group, store: $0, bulk: $1) }) != nil else { return false }
    groupForm = nil
    setGroup(group.id, on: true)
    show("“\(group.name)” saved and on for this \(noun)")
    return true
  }

  /// A clip with scheduled or posted posts was frozen by the core path, so it keeps what it has. Any other clip: its
  /// written caption, on screen right now, gets the group's tags swapped in place (other clips' written captions are
  /// their own text).
  private func updateGroup(_ old: HashtagSet, name: String, tags: [String]) -> Bool {
    var group = old
    group.name = HashtagGroups.cleanName(name)
    group.tags = tags
    let written = resolved.caption, before = hashtags
    let saved = group
    guard let change = writeGroup({ try HashtagGroups.update(saved, store: $0, bulk: $1) }) else { return false }
    groupForm = nil
    guard sets.contains(where: { $0.id == saved.id }) else {  // deleted just before Save; the core path left it deleted
      fieldRevision &+= 1
      show("That group was deleted")
      return false
    }
    let after = hashtags
    let swap = !change.kept.contains(videoId) && !written.isEmpty && !written.contains("{hashtags}") && before != after
    let message = change.kept.contains(videoId) ? "“\(group.name)” saved. This \(noun) keeps its tags: it has scheduled or posted posts"
      : swap ? "“\(group.name)” saved. ⌘Z restores only this caption" : "“\(group.name)” saved"
    // Before this clip's own change below: the session moves past the group batch, then owns that change.
    if let journal = appHooks.afterGroupEdit { journal(change.result, message) } else { show(message) }
    if change.kept.contains(videoId) {
      replaceVersions((try? store.versions(videoId: videoId)) ?? versions)
    } else if swap {
      updateVersion(coalesce: false) { $0.caption = Captions.replaceHashtags(in: written, old: before, new: after) }
    } else {
      fieldRevision &+= 1
    }
    return true
  }

  /// Versions changed under the editor (a freeze, or Undo of one): the history no longer applies to them.
  private func replaceVersions(_ fresh: [Version]) {
    versions = fresh
    syncedVersions = fresh
    clearUndo()
    fieldRevision &+= 1
    refreshOverlay()
  }

  /// One journaled write through the core path, after the session so far and any pending editor saves; the chips re-read
  /// the table.
  private func writeGroup(failure: String = "Couldn't save the group", _ write: @escaping @Sendable (Store, BulkActions) throws -> HashtagGroups.Change) -> HashtagGroups.Change? {
    appHooks.beforeGroupWrite?()
    flush()
    let store = store
    do {
      let (change, fresh, st, tpl) = try Self.saveQueue.sync {
        (try write(store, BulkActions(store: store)), try store.hashtagSets(), try store.settings(), try store.captionTemplates())
      }
      sets = fresh
      settings = st
      templates = tpl
      if !snapshotMode { ChangeSignal.post() }
      return change
    } catch {
      show("\(failure): \(error.localizedDescription)")
      return nil
    }
  }

  /// Makes `id` the default template, through the core path: this clip's own choice stays, and the Default label follows.
  func setDefaultTemplate(_ id: String) {
    guard groupsOffReason == nil, let name = templates.first(where: { $0.id == id })?.name else { return }
    commitCaptionDraft()
    guard let change = writeGroup(failure: "Couldn't set the default template", { try CaptionTemplates.setDefault(id, store: $0, bulk: $1) }) else { return }
    let n = change.kept.count
    let message = "“\(name)” is the default template" + (n == 0 ? "" : ". \(n) clip\(n == 1 ? "" : "s") with scheduled or posted posts keep\(n == 1 ? "s" : "") its caption")
    if let journal = appHooks.afterGroupEdit { journal(change.result, message) } else { show(message) }
    if change.kept.contains(videoId) { replaceVersions((try? store.versions(videoId: videoId)) ?? versions) } else { fieldRevision &+= 1 }
  }

  /// The template the field is on (nil = the clip's own text, or a template that no longer exists).
  var selectedTemplate: CaptionTemplate? {
    guard !captionIsWritten else { return nil }
    let id = resolved.captionTemplateId ?? defaults.captionTemplateId
    return templates.first { $0.id == id }
  }

  /// What each platform's hashtag cap does to this clip's caption.
  var capNotes: [Captions.CapNote] {
    guard let v = video else { return [] }
    return Captions.capNotes(postingPlatforms, version: resolved, video: v, sessionName: sessionName, sets: sets, templates: templates, settings: settings,
                             scheduled: clipHasPosts)
  }

  /// Scheduled or posted posts: a new template doesn't take this clip's caption over.
  var clipHasPosts: Bool { posts.contains { $0.state.holdsCaption } }

  /// Why the part chips are off (nil = they work).
  var partsOffReason: String? { readOnly ? EditorView.readOnlyReason : CaptionParts.lockReason(posts: posts) }

  /// What the part chips read for this clip.
  var partValues: CaptionParts.Values? {
    video.map { CaptionParts.Values(version: resolved, video: $0, sessionName: sessionName, link: settings.captionLink) }
  }

  /// Adds or removes a part in the caption text, which makes a template caption a written one (↺ goes back).
  func togglePart(_ part: CaptionPart) {
    guard partsOffReason == nil, let v = video else { return }
    commitCaptionDraft()
    guard let next = CaptionParts.toggling(part, version: resolved, video: v, sessionName: sessionName, sets: sets, templates: templates,
                                           settings: settings) else { return }
    typeCaption(next)
    commitCaptionDraft()
    fieldRevision &+= 1
  }

  /// The form opens empty for a new template, or filled in for `template`.
  func openTemplateForm(_ template: CaptionTemplate? = nil) {
    guard groupsOffReason == nil else { return }
    guard let template else { templateForm = EditorTemplateForm(template: "{text}\n\n{hashtags}"); return }
    let store = store
    let impact = Self.saveQueue.sync { try? CaptionTemplates.impact(of: template.id, store: store) }
    templateForm = EditorTemplateForm(editing: template.id, name: template.name, template: template.template, impact: impact)
  }

  /// The form opens on a template made from the caption in the field.
  func openSaveAsTemplate() {
    guard groupsOffReason == nil, let v = video else { return }
    commitCaptionDraft()
    templateForm = EditorTemplateForm(template: CaptionTemplates.template(
      fromCaption: mainCaption, version: resolved, video: v, sessionName: sessionName, sets: sets, link: settings.captionLink))
  }

  /// Saves the form through the core path. A new template goes on for this clip unless it has posts; an edit reaches every clip built from it
  /// except those with scheduled or posted posts.
  @discardableResult
  func saveTemplate(name: String, template: String) -> Bool {
    guard groupsOffReason == nil else { return false }
    let editing = templateForm?.editing
    guard CaptionTemplates.problem(name: name, template: template, existing: templates, editing: editing) == nil else { return false }
    commitCaptionDraft()
    let failure = "Couldn't save the template"
    guard let editing else {
      let t = CaptionTemplates.make(name: name, template: template, existing: templates)
      guard writeGroup(failure: failure, { try CaptionTemplates.create(t, store: $0, bulk: $1) }) != nil else { return false }
      templateForm = nil
      if clipHasPosts {
        show("“\(t.name)” saved. This \(noun) keeps its caption: it has scheduled or posted posts")
      } else {
        setCaptionTemplate(t.id)
        show("“\(t.name)” saved and on for this \(noun)")
      }
      return true
    }
    guard var t = templates.first(where: { $0.id == editing }) else {  // deleted while the form was open
      templateForm = nil
      show("That template was deleted")
      return false
    }
    t.name = HashtagGroups.cleanName(name)
    t.template = template
    let saved = t
    guard let change = writeGroup(failure: failure, { try CaptionTemplates.update(saved, store: $0, bulk: $1) }) else { return false }
    templateForm = nil
    let kept = change.kept.contains(videoId)
    let message = kept ? "“\(t.name)” saved. This \(noun) keeps its caption: it has scheduled or posted posts" : "“\(t.name)” saved"
    if let journal = appHooks.afterGroupEdit { journal(change.result, message) } else { show(message) }
    if kept { replaceVersions((try? store.versions(videoId: videoId)) ?? versions) } else { fieldRevision &+= 1 }
    return true
  }

  /// The chosen template this clip could make the default (nil = its own text, the default already, or a missing template).
  var defaultCandidate: CaptionTemplate? {
    guard !captionIsWritten, let id = resolved.captionTemplateId, id != defaults.captionTemplateId else { return nil }
    return templates.first { $0.id == id }
  }

  /// Picks up groups changed outside the editor, and what that did to this clip (frozen, or Undo of it). A typed caption
  /// is applied first (the field re-reads the model after). An edit form for a group that's gone closes.
  func reloadGroups() {
    let store = store, id = videoId
    Self.saveQueue.async { [weak self] in
      guard let fresh = try? store.hashtagSets(), let saved = try? store.versions(videoId: id),
            let st = try? store.settings(), let tpl = try? store.captionTemplates() else { return }
      DispatchQueue.main.async {
        guard let self, self.videoId == id, fresh != self.sets || st != self.settings || tpl != self.templates else { return }
        self.commitCaptionDraft()
        self.sets = fresh
        self.settings = st
        self.templates = tpl
        if let e = self.groupForm?.editing, !fresh.contains(where: { $0.id == e }) {
          self.groupForm = nil
          self.show("That group was deleted")
        }
        if saved == self.versions {
          self.fieldRevision &+= 1
        } else if !self.pendingEdit, self.pendingVersions.isEmpty {
          self.replaceVersions(saved)
        } else if let merged = HashtagGroups.keepingFreeze(memory: self.versions, saved: saved, base: self.syncedVersions) {
          // Unsaved changes on a clip frozen or held underneath them: the next save keeps the hold and Eric's work.
          self.replaceVersions(merged)
          self.pendingVersions.formUnion(merged.map(\.number))
        } else {
          self.fieldRevision &+= 1
        }
        self.syncedVersions = saved
      }
    }
  }

  func setExtraHashtags(_ tags: [String]) {
    let fb = fallback(\.extraHashtags, \.extraHashtags)
    retagging(coalesce: true) { $0.extraHashtags = tags == fb ? nil : tags }
  }

  private func retagging(coalesce: Bool, _ f: (inout Version) -> Void) {
    commitCaptionDraft()
    let before = resolved
    updateVersion(coalesce: coalesce) { v in
      f(&v)
      var vs = versions.isEmpty ? [Version(number: 1)] : versions
      if let i = vs.firstIndex(where: { $0.number == versionNo }) { vs[i] = v } else { vs.append(v) }
      let after = VersionResolver.resolve(vs, number: versionNo, settings: settings, video: video)
      Captions.retag(&v, before: before, after: after, sets: sets)
    }
  }

  /// Caption template (round 7): choosing one rewrites the caption from it — a written caption is replaced (one undo
  /// step, ⌘Z brings it back), so Eric can try templates back to back. Picking the default template follows the default.
  func setCaptionTemplate(_ id: String?) {
    commitCaptionDraft()
    var vs = versions.isEmpty ? [Version(number: 1)] : versions
    if let i = vs.firstIndex(where: { $0.number == versionNo }) { vs[i].captionTemplateId = nil; vs[i].caption = nil }
    let fb = VersionResolver.resolve(vs, number: versionNo, settings: settings, video: video).captionTemplateId
    let value = id.flatMap { $0.isEmpty ? nil : $0 }
    let hadWritten = captionIsWritten
    updateVersion(coalesce: false) { v in
      v.captionTemplateId = value == fb || (fb == nil && value == defaults.captionTemplateId) ? nil : value
      v.caption = nil
    }
    if hadWritten { show("Caption rewritten from the template — ⌘Z brings your text back") }
  }

  // MARK: Caption field (round 7): what you type is what posts

  /// Bumped by every change that isn't typing in the caption / YouTube title fields, so they re-read the model.
  @Published private(set) var fieldRevision = 0
  /// Typed caption text not applied yet (applied 250 ms after the last keystroke, and before anything else changes).
  private var captionDraft: (platform: Platform?, text: String)?
  private var captionDraftTask: Task<Void, Never>?

  /// Typing in the caption field (or a platform's own caption when `platform` is set). Cheap per keystroke: the model
  /// (and everything that observes it) updates once typing pauses.
  func typeCaption(_ text: String, platform: Platform? = nil) {
    if let d = captionDraft, d.platform != platform { commitCaptionDraft() }
    captionDraft = (platform, text)
    if !saving { saving = true }  // @Published fires on every set: only the first keystroke redraws the editor
    captionDraftTask?.cancel()
    captionDraftTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      self?.commitCaptionDraft()
    }
  }

  /// Applies a typed caption now. Text equal to the template's output stays "follows the template"; anything else is
  /// this version's written caption (Custom), taken literally.
  func commitCaptionDraft() {
    captionDraftTask?.cancel()
    captionDraftTask = nil
    guard let d = captionDraft else { return }
    captionDraft = nil
    defer { if !pendingEdit && pendingVersions.isEmpty { saving = false } }
    if let p = d.platform {
      var m = resolved.platformCaptions
      m[p] = d.text
      updateVersion(fromField: true) { $0.platformCaptions = m.isEmpty ? nil : m }
      return
    }
    guard d.text != mainCaption else { saving = pendingEdit || !pendingVersions.isEmpty; return }
    let r = resolved
    let templateText = video.map {
      Captions.templateCaption(r.captionTemplateId, version: r, video: $0, sessionName: sessionName, sets: sets,
                               templates: templates, settings: settings)
    }
    let blank = d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    updateVersion(fromField: true) { v in
      if blank || d.text == templateText {
        v.caption = nil
      } else {
        v.caption = d.text
      }
    }
  }

  /// "↺ Use the template": drops the written caption (this version's, or an override of an inherited one).
  func resetCaptionToTemplate() {
    commitCaptionDraft()
    updateVersion(coalesce: false) { $0.caption = nil }
  }

  /// A written caption carried forward from an earlier version: this version can't switch back to a template (a
  /// version only adds to the one before it), so the picker says why.
  var captionInheritedFrom: Int? { captionIsWritten && !ownsField(["caption"]) ? source(of: "caption") : nil }

  // MARK: YouTube title (round 7): pick a template, then edit the real title

  var youtubeTitleTemplates: [TitleTemplate] { settings.youtubeTitleTemplates }

  /// What template `id` (nil = the default) makes for this clip.
  func youtubeTitle(template id: String?) -> String {
    guard let v = video else { return "" }
    return Captions.youtubeTitle(fromTemplate: settings.youtubeTitleTemplate(id: id), version: resolved, video: v,
                                 limit: settings.limits[.youtube]?.titleLimit ?? 100)
  }

  /// Typing in the YouTube title field: text equal to the template's title follows the template; anything else is
  /// typed (Custom). An empty field goes back to the template.
  func typeYouTubeTitle(_ t: String) {
    let tpl = youtubeTitle(template: resolved.youtubeTitleTemplateId)
    updateVersion(fromField: true) { v in
      v.youtubeTitle = t.trimmingCharacters(in: .whitespaces).isEmpty || t == tpl ? nil : t
    }
  }

  /// Choosing a template rewrites the title from it (a typed title is replaced; ⌘Z brings it back).
  func setYouTubeTitleTemplate(_ id: String?) {
    let value = id.flatMap { $0.isEmpty ? nil : $0 }
    let hadTyped = !resolved.youtubeTitle.isEmpty
    updateVersion(coalesce: false) { v in
      v.youtubeTitleTemplateId = value == nil || value == defaults.youtubeTitleTemplateId ? nil : value
      v.youtubeTitle = nil
    }
    if hadTyped { show("YouTube title rewritten from the template — ⌘Z brings your title back") }
  }

  /// Typed overlay text. An empty field is an explicit "empty" (it must not snap back to the Title); "Follow the
  /// Title" is the reset (`resetVersion(["text"])`).
  func setText(_ t: String) {
    updateVersion { v in
      // Blank (nothing, or only spaces and new lines) is "typed nothing yet": kept as typed, never the Title.
      if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { v.text = t; v.noText = false } else { v.text = t; v.noText = nil }
    }
  }

  /// "No text" on/off. Off goes back to following the default text when nothing was typed (a talking clip, whose
  /// default is "No text", gets an explicit off).
  func setNoText(_ on: Bool) {
    if on { updateVersion { $0.noText = true }; return }
    // An emptied first text stays empty while another text shows, or the Title would come back over it.
    let othersShow = resolved.moreText.contains { !$0.isBlank }
    updateVersion { v in
      let blank = (v.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      v.noText = blank && v.text != nil && othersShow ? false : nil  // false: "" with no answer here would follow the Title
      if blank && !othersShow { v.text = nil }
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
        case "youtubeTitleTemplateId": v.youtubeTitleTemplateId = nil
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
      case "youtubeTitleTemplateId": v.youtubeTitleTemplateId != nil
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
                                        settings: settings, sets: sets)
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
    commitCaptionDraft()
    commitTimeDraft()
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
      v.youtubeTitleTemplateId = r.youtubeTitleTemplateId
      if !r.platformCaptions.isEmpty { v.platformCaptions = r.platformCaptions }
      TextLayers.copyAdvanced(into: &v, from: r)
    }
    if !versions.contains(where: { $0.number == 1 }) { versions.insert(Version(number: 1), at: 0); pendingVersions.insert(1) }
    versions.append(v)
    pendingVersions.insert(n)
    versionNo = n
    scheduleSave()
    refreshOverlay()
  }

  // MARK: Ready to repost (round 20)

  /// Why "Ready to repost" can't change on this clip (nil = it can).
  var repostReadyOff: String? {
    if readOnly { return EditorView.readOnlyReason }
    if video?.type == .long { return "Long-form is never reposted" }
    return nil
  }

  func isRepostReady(_ n: Int) -> Bool { versions.first { $0.number == n }?.repostReady == true }

  /// Marks version `n` ready for the repost cycle (or not). Only the flag: the clip's stage, Queue and schedule stay
  /// as they are. Its own undo step.
  func setRepostReady(_ n: Int, _ on: Bool) {
    guard repostReadyOff == nil, video != nil, isRepostReady(n) != on else { return }
    commitCaptionDraft()
    var all = versions
    let addsV1 = !all.contains { $0.number == 1 }
    if addsV1 { all.insert(Version(number: 1), at: 0) }
    guard let i = all.firstIndex(where: { $0.number == n }) else { return }
    markUndo(coalesce: false)
    all[i].repostReady = on ? true : nil
    versions = all.sorted { $0.number < $1.number }
    writeRepostReady(n, on)
    show(on ? "v\(n) is ready to repost. Nothing was queued or scheduled." : "v\(n) is no longer ready to repost")
  }

  /// Writes only the flag (`Store.setRepostReady`: no `updated_at`, so list previews don't redraw) and records it as
  /// saved, so the next save of that version carries it and nothing else is re-saved for it.
  private func writeRepostReady(_ n: Int, _ on: Bool) {
    // A version that isn't saved yet (just made, its save pending) gets the mark with that save.
    if pendingVersions.contains(n) || (n != 1 && !syncedVersions.contains { $0.number == n }) { return }
    if let i = syncedVersions.firstIndex(where: { $0.number == n }) {
      syncedVersions[i].repostReady = on ? true : nil
    } else if n == 1 {
      var v1 = Version(number: 1)
      v1.repostReady = on ? true : nil
      syncedVersions.append(v1)
    }
    let store = store, id = videoId
    Self.saveQueue.async {
      do {
        try store.setRepostReady(videoId: id, number: n, on)
        ChangeSignal.post()
      } catch {
        Log.shared.error("editor repost-ready failed: \(error)")
      }
    }
  }

  func deleteVersion(_ n: Int) {
    guard n > 1, !readOnly else { return }
    commitTimeDraft()
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
    commitCaptionDraft()
    commitTimeDraft()
    versionNo = n
    fieldRevision &+= 1
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
    /// Round 21: a photo post's photos in order (nil for a clip).
    var photos: [PhotoItem]? = nil
  }

  private var undoStack: [UndoState] = []
  private var redoStack: [UndoState] = []
  private var lastUndoMark = Date.distantPast
  private var restoringUndo = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false

  private var undoState: UndoState {
    UndoState(edit: edit, versions: versions, versionNo: versionNo, title: video?.title, titleTracks: video?.titleTracks,
              titleSource: video?.titleSource, kind: video?.kind, photos: video?.photos)
  }

  /// Called just BEFORE a change. Changes less than 0.8 s apart (a drag, a typed word, a slider) form one step.
  func markUndo(coalesce: Bool = true) {
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

  /// The next change gets its own undo step, even right after this one.
  func lastUndoBreak() { lastUndoMark = .distantPast }

  private func clearUndo() {
    undoStack = []
    redoStack = []
    lastUndoMark = .distantPast
    canUndo = false
    canRedo = false
  }

  func undo() {
    commitCaptionDraft()
    guard !photoBusy else { show("Photos are being added. Undo works again in a moment."); return }
    guard !readOnly, let s = undoStack.popLast() else { show("Nothing to undo in this \(noun)"); return }
    dropTimeDraft()
    redoStack.append(undoState)
    restoreUndo(s)
    show("Undone")
  }

  func redo() {
    commitCaptionDraft()
    guard !photoBusy else { show("Photos are being added. Redo works again in a moment."); return }
    guard !readOnly, let s = redoStack.popLast() else { show("Nothing to redo"); return }
    dropTimeDraft()
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
    // Round 20: undoing (or redoing) only a Ready to repost toggle writes just those flags, so nothing is re-saved and
    // list previews don't redraw.
    func unready(_ vs: [Version]) -> [Version] {
      (vs.contains { $0.number == 1 } ? vs : [Version(number: 1)] + vs).map { var v = $0; v.repostReady = nil; return v }
    }
    // Round 21: the photos first, as they were: same ids and files, so each photo's own crop in `s.edit` is still its.
    // Then, whatever the state says, no text is left on a photo that isn't there (`PhotoTextRanges`).
    if let target = s.photos, target != video?.photos { restorePhotos(target) }
    defer { if isPhoto { clampTextRanges() } }
    if s.edit == edit, unready(s.versions) == unready(versions), s.title == video?.title, s.titleTracks == video?.titleTracks,
       s.kind == nil || s.kind == video?.kind {
      // Both sides' numbers: a v1 that only existed for its mark is in `versions` but not in the earlier state.
      for n in Set(s.versions.map(\.number)).union(versions.map(\.number)) {
        let want = s.versions.first { $0.number == n }?.repostReady == true
        if want != isRepostReady(n) { writeRepostReady(n, want) }
      }
      versions = s.versions
      versionNo = s.versions.contains { $0.number == s.versionNo } ? s.versionNo : 1
      fieldRevision &+= 1
      refreshOverlay()
      return
    }
    let gone = Set(versions.map(\.number)).subtracting(s.versions.map(\.number)).filter { $0 > 1 }
    edit = s.edit
    pendingEdit = true
    // A state from before the clip had any version row still has to reach the store: an empty v1 undoes what's there.
    versions = s.versions.contains { $0.number == 1 } ? s.versions : [Version(number: 1)] + s.versions
    pendingVersions.formUnion(versions.map(\.number))
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
    fieldRevision &+= 1
    scheduleSave()
    refreshOverlay()
  }

  /// Changes the versions as part of the undo step that is already marked (a photo removal that moves a text's range
  /// with it): no step of its own. True when anything changed.
  @discardableResult
  func amendVersions(_ change: (Version) -> Version) -> Bool {
    var changed = false
    for i in versions.indices {
      let v = change(versions[i])
      guard v != versions[i] else { continue }
      versions[i] = v
      pendingVersions.insert(v.number)
      changed = true
    }
    if changed {
      fieldRevision &+= 1
      scheduleSave()
      refreshOverlay()
    }
    return changed
  }

  // MARK: Photos (round 21): the few writes `EditorModel+Photos.swift` needs here

  /// The post after a photo change in the store: only what follows from its photos is taken, so a Title or kind changed
  /// meanwhile stays as the editor has it.
  func adoptPhotos(from fresh: Video) {
    guard var v = video else { return }
    v.photos = fresh.photos
    v.file = fresh.file
    v.fingerprint = fresh.fingerprint
    v.fileSize = fresh.fileSize
    v.sourceWidth = fresh.sourceWidth
    v.sourceHeight = fresh.sourceHeight
    video = v
    fileURL = try? store.fileURL(for: v)
    checkPhotoFiles(wasMissing: fresh.missing)
    // The store dropped the crops of photos that left; the editor's copy follows without a save of its own.
    let keep = Set((v.photos ?? []).map(\.id))
    for k in edit.photoCrops.keys where !keep.contains(k) { edit.photoCrops.removeValue(forKey: k) }
    unreadablePhotos.formIntersection(keep)
  }

  /// Which photo files are on disk. A post is missing while one is gone; once none is (that photo was removed here,
  /// or its file came back), Core's own check (`PhotoImport.checkFiles`, the one Intake runs) clears the row's mark.
  func checkPhotoFiles(wasMissing: Bool) {
    guard var v = video, v.isPhoto else { return }
    let gone = (v.photos ?? []).filter { p in (try? store.photoURL(p, of: v)).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true }
    missingPhotos = Set(gone.map(\.id))
    fileMissing = !gone.isEmpty
    if v.missing != fileMissing { v.missing = fileMissing; video = v }
    if wasMissing != fileMissing, !snapshotMode, !readOnly {
      let store = store
      Self.saveQueue.async {
        _ = try? PhotoImport(store: store).checkFiles()
        ChangeSignal.post()
      }
    }
  }

  /// The picture size crop math works in: the clip's, or the current photo's.
  func setSourceSize(_ size: CGSize) { if size != sourceSize, size.width > 0, size.height > 0 { sourceSize = size } }

  /// Reads the post's issues again after a change that wasn't a save (photos added, removed or reordered).
  func revalidate() {
    let store = store, id = videoId
    Self.saveQueue.async { [weak self] in
      guard let v = try? store.video(id: id), let issues = try? Validation.issues(video: v, store: store) else { return }
      let blocker = Self.audioBlocker(store, v)
      DispatchQueue.main.async {
        guard let self, self.videoId == id else { return }
        self.issues = issues
        self.audioBlocker = blocker
      }
    }
  }

  /// Why audio can't be added, changed or removed, or the fit changed (nil = it can), read off the main thread with the
  /// item (load, revalidate, each save) so the Audio row never reads the store while drawing.
  private nonisolated static func audioBlocker(_ store: Store, _ v: Video) -> String? {
    guard v.isPhoto || v.isStill else { return nil }
    return (try? StillVideo(store: store).blocker(v)) ?? nil
  }

  /// The item became something else under the editor (audio added, changed or removed, a fit change, or the undo of
  /// one). What the editor holds belongs to what the item was, so none of it is written: typed drafts go, pending
  /// changes are dropped, and the item is read again.
  func reloadDiscardingPending() {
    saveTask?.cancel()
    captionDraftTask?.cancel()
    captionDraft = nil
    titleDraft = nil
    dropTimeDraft()
    pendingEdit = false
    pendingVersions = []
    load(videoId)
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
    commitCaptionDraft()
    saveTask?.cancel()
    guard pendingEdit || !pendingVersions.isEmpty, let video else { saving = false; return }
    let store = store, id = videoId, e = pendingEdit ? edit : nil
    let vs = versions.filter { pendingVersions.contains($0.number) }
    pendingEdit = false
    pendingVersions = []
    saving = true
    let bases = Dictionary(syncedVersions.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
    for v in vs {
      syncedVersions.removeAll { $0.number == v.number }
      syncedVersions.append(v)
    }
    Self.saveQueue.async { [weak self] in
      do {
        if let e { try store.save(e, videoId: id) }
        let stored = Dictionary(try store.versions(videoId: id).map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [Version] = []
        for v in vs {
          let out = VersionMerge.keepingOutsideChanges(v, base: bases[v.number], stored: stored[v.number])
          try store.save(out, videoId: id)
          if out != v { merged.append(out) }
        }
        if !merged.isEmpty {
          DispatchQueue.main.async {
            guard let self, self.videoId == id else { return }
            for m in merged {
              if let i = self.syncedVersions.firstIndex(where: { $0.number == m.number }) { self.syncedVersions[i] = m }
              // The outside fields go into the editor's copy too, keeping anything Eric changed since this save began;
              // otherwise the next save would read their absence as his change.
              if let i = self.versions.firstIndex(where: { $0.number == m.number }) {
                self.versions[i] = VersionMerge.keepingOutsideChanges(self.versions[i], base: vs.first { $0.number == m.number }, stored: m)
              }
            }
          }
        }
        let fresh = try store.video(id: id) ?? video
        let issues = try Validation.issues(video: fresh, store: store)
        let blocker = Self.audioBlocker(store, fresh)
        ChangeSignal.post()
        DispatchQueue.main.async {
          guard let self, self.videoId == id else { return }
          self.issues = issues
          self.audioBlocker = blocker
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
    commitTimeDraft()
    flush()
    Self.saveQueue.sync {}
  }

  // MARK: Text images (TextOverlay PNGs drawn over the player, one per text: preview == export)

  /// Drawn texts by `PreviewKeys.layerKey`, so moving one text in time or editing one never redraws the rest. Full-size
  /// images are 8 MB each at 1080 wide: this holds about 19, and evicts past it. A clip can show more (32 texts, and a
  /// countdown draws a number each), so what is on the canvas is held by `textImages` itself, never only by this cache:
  /// a refresh hands the images it just drew straight to `build` (round 26).
  private nonisolated static let drawnTexts = CostCappedCache<String, EditorDrawnText>(costLimit: 160 << 20)

  private nonisolated static func draw(_ l: TextLayer, aspect: Aspect, key: String) -> EditorDrawnText? {
    guard let img = TextOverlay.image(for: l, aspect: aspect), let b = TextOverlay.textBounds(for: l, aspect: aspect) else { return nil }
    let o = aspect.outputSize
    let unit = CGRect(x: b.minX / CGFloat(o.w), y: b.minY / CGFloat(o.h), width: b.width / CGFloat(o.w), height: b.height / CGFloat(o.h))
    let drawn = EditorDrawnText(image: img, bounds: unit)
    drawnTexts.set(drawn, for: key, cost: img.bytesPerRow * img.height)
    return drawn
  }

  /// Brings `textImages` up to date. An edited text keeps its old image until the new one lands, so nothing flickers.
  func refreshOverlay() {
    let r = resolved, a = aspect, tr = trim
    let photo = isPhoto, count = photoCount
    if photo { refreshPhotoImages() }
    let all = PreviewKeys.layerWindows(r, trimDuration: tr.duration)
    let windows = Dictionary(all.map { ($0.layer.id, $0.window) }) { x, _ in x }
    let wanted = r.layers.flatMap { l -> [(id: String, layer: TextLayer, key: String, window: ClosedRange<Double>?, step: Int?)] in
      // A countdown on a clip is one image per number, each with its step (round 26). Outside the trim it keeps its
      // first number, with no window, so the canvas can still show it dimmed while it's selected.
      if !photo, let n = l.countdown {
        let steps = all.filter { $0.layer.id == l.id }
        guard !steps.isEmpty else {
          var first = l; first.countdown = nil; first.text = l.countdownText(n)
          return [(id: "\(l.id)#0", layer: first, key: PreviewKeys.layerKey(first, aspect: a), window: nil, step: 0)]
        }
        return steps.enumerated().map { k, st in
          (id: "\(l.id)#\(k)", layer: st.layer, key: PreviewKeys.layerKey(st.layer, aspect: a),
           window: (st.window.lowerBound + tr.start)...(st.window.upperBound + tr.start), step: k)
        }
      }
      // A photo post's window is the photos a text shows on, as indexes (first…last), by the renderer's own rule
      // (`PhotoRules.photoRange`): the canvas asks `shows(at:)` with the current photo's index.
      return [(id: l.id, layer: l, key: PreviewKeys.layerKey(l, aspect: a),
               window: photo ? windows[l.id].flatMap { PhotoRules.photoRange($0, count: count) }.map { Double($0.lowerBound - 1)...Double($0.upperBound - 1) }
                             : windows[l.id].map { ($0.lowerBound + tr.start)...($0.upperBound + tr.start) }, step: nil)]
    }
    let signature = wanted.map { "\($0.id)|\($0.key)|\($0.window.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "off")" }
    guard signature != overlaySignature else { return }
    overlaySignature = signature
    overlayTask?.cancel()
    let before = Dictionary(textImages.map { ($0.id, $0.drawn) }) { x, _ in x }
    // What is on the canvas now and what the cache has now, by key, held here: drawing the missing ones can evict
    // others from the cache before `build` reads it, and an image stays usable while it's held.
    var current = Dictionary(textImages.map { ($0.key, $0.drawn) }) { x, _ in x }
    for w in wanted where current[w.key] == nil { current[w.key] = Self.drawnTexts.value(w.key) }
    let build: ([String: EditorDrawnText], Bool) -> [EditorTextImage] = { [current] fresh, useOld in
      wanted.compactMap { w in
        guard let d = fresh[w.key] ?? current[w.key] ?? Self.drawnTexts.value(w.key) ?? (useOld ? before[w.id] : nil) else { return nil }
        return EditorTextImage(id: w.id, layerId: w.layer.id, key: w.key, drawn: d, window: w.window, step: w.step)
      }
    }
    var seen = Set<String>()
    let missing = wanted.filter { current[$0.key] == nil && seen.insert($0.key).inserted }
      .map { (layer: $0.layer, key: $0.key) }
    if snapshotMode {
      var fresh: [String: EditorDrawnText] = [:]
      for m in missing { fresh[m.key] = Self.draw(m.layer, aspect: a, key: m.key) }
      textImages = build(fresh, false)
      return
    }
    textImages = build([:], true)
    guard !missing.isEmpty else { return }
    overlayTask = Task.detached(priority: .userInitiated) { [weak self] in
      var fresh: [String: EditorDrawnText] = [:]
      for m in missing {
        if Task.isCancelled { return }
        fresh[m.key] = Self.draw(m.layer, aspect: a, key: m.key)
      }
      let drawn = fresh
      await self?.textImagesDrawn(signature) { build(drawn, false) }
    }
  }

  private func textImagesDrawn(_ signature: [String], _ build: () -> [EditorTextImage]) {
    if overlaySignature == signature { textImages = build() }
  }

  /// Any text on the cover.
  var coverHasText: Bool {
    resolvedEdit.coverIncludesText && !PreviewKeys.coverLayers(resolved, offset: coverTime - trim.start, trimDuration: trim.duration).isEmpty
  }

  /// The texts on the cover: what `Media.coverComposite` draws for this frame.
  var coverTextImages: [EditorTextImage] {
    guard resolvedEdit.coverIncludesText else { return [] }
    let at = coverTime - trim.start
    let ids = PreviewKeys.coverLayers(resolved, offset: at, trimDuration: trim.duration).map(\.id)
    // A countdown is on the cover as the number showing at that frame.
    return textImages.filter { ids.contains($0.layerId) && ($0.step == nil || $0.shows(at: coverTime)) }
  }

  // MARK: Texts (round 16): the first text routes to the version's fields, the others to `moreText`

  /// The text being edited. Everything that selects one writes here: the switcher, a timeline bar, the canvas.
  @Published private var selectedTextRaw = TextLayer.firstId
  /// Bumped when the text field should take the keyboard (a new text).
  @Published var focusTextField = 0

  var texts: [TextLayer] { resolved.allLayers }

  /// The selected text, or the first one when it's gone (undo, another version).
  var selectedText: String { resolved.moreText.contains { $0.id == selectedTextRaw } ? selectedTextRaw : TextLayer.firstId }
  var selectedIsFirst: Bool { selectedText == TextLayer.firstId }
  var selectedLayer: TextLayer { resolved.moreText.first { $0.id == selectedText } ?? resolved.firstLayer }
  /// 1 for the first text.
  var selectedNumber: Int { (texts.firstIndex { $0.id == selectedText } ?? 0) + 1 }

  func selectText(_ id: String) { if id != selectedTextRaw { selectedTextRaw = id } }

  /// One change to a text through `TextLayers.updating`, which copies an inherited list into this version on its first
  /// edit and writes only what changed on the first text.
  func updateText(_ id: String, coalesce: Bool = true, _ change: (inout TextLayer) -> Void) {
    let r = resolved
    updateVersion(coalesce: coalesce) { v in v = TextLayers.updating(id, in: v, resolved: r, change) }
  }

  /// The text track. With "No text" on it's the one stand-in bar: nothing else shows, so nothing else is on the timeline.
  var textBars: (bars: [EditorTimelineBar], laneCount: Int) {
    let r = resolved, d = trim.duration
    let first = EditorTimelineBar(id: TextLayer.firstId, number: 1, label: r.hasText ? Captions.oneLine(r.text) : r.noText ? "No text" : "No text yet",
                                  on: r.hasText && !r.noText, draggable: r.hasText && !r.noText,
                                  span: r.hasText && !r.noText ? TextTimeline.span(r.firstLayer, trimDuration: d) : (0, d), lane: 0)
    guard !r.noText else { return ([first], 1) }
    var bars = [first] + r.moreText.enumerated().map { i, l in
      EditorTimelineBar(id: l.id, number: i + 2, label: l.countdown.map { TextLayers.countdownLabel(l, from: $0) } ?? (l.isBlank ? "Empty text" : Captions.oneLine(l.text)),
                        on: !l.isBlank, draggable: true,
                        span: TextTimeline.span(l, trimDuration: d), lane: 0)
    }
    let lanes = TextTimeline.lanes(bars.map(\.span))
    for i in bars.indices { bars[i].lane = lanes[i] }
    return (bars, (lanes.max() ?? 0) + 1)
  }

  /// Why a new text can't be added right now (nil = it can).
  var addTextOffReason: String? {
    if photoHasNoTextYet { return nil }  // round 21: Add text writes a photo post's first text
    if resolved.noText { return "No text is on; turn off No text to add a text" }
    return TextLayers.canAdd(resolved) ? nil : "A \(isPhoto ? "post" : "clip") holds \(TextLayers.maxCount) texts at most"
  }

  /// Why the selected text can't be deleted (nil = it can).
  var deleteTextOffReason: String? {
    let r = resolved
    if !selectedIsFirst { return nil }
    if r.moreText.isEmpty { return "The only text can't be deleted; use No text" }
    return r.moreText.contains { !$0.isBlank } ? nil : "Type in another text first, or use No text"
  }

  /// Appends `l` and selects it. A text sharing the time of the one it copies goes just below it, or neither could be read.
  func add(_ new: TextLayer, overlapping: Bool) {
    let r = resolved
    var l = new
    if overlapping { l.posY = TextTimeline.clearY(l.posY) }
    updateVersion(coalesce: false) { v in if let n = TextLayers.adding(l, to: v, resolved: r) { v = n } }
    selectedTextRaw = l.id
    focusTextField += 1
  }

  /// A new, empty text at the playhead: 3 seconds or to the clip end, looking like the selected text.
  func addText() {
    if isPhoto { addPhotoText(); return }
    guard addTextOffReason == nil else { return }
    let like = selectedLayer, d = trim.duration
    let w = TextTimeline.newWindow(playhead: playback.time - trim.start, trimDuration: d)
    let span = TextTimeline.span(like, trimDuration: d)
    add(TextLayers.new(text: "", like: like, start: w.start, end: w.end), overlapping: w.start < span.end && span.start < w.end)
  }

  /// The selected text again, straight after the original, or on top of it just below when there's no room.
  func duplicateText() {
    guard addTextOffReason == nil else { return }
    let like = selectedLayer
    // A text on every photo has no window to move: its copy shows on every photo too, just below it.
    if isPhoto, like.start == nil, like.end == nil { add(TextLayers.new(text: like.text, like: like), overlapping: true); return }
    defer { if isPhoto { showSelectedTextPhoto() } }  // the copy may sit on the next photo: the canvas goes there
    let (w, overlaps) = TextTimeline.duplicateWindow(TextTimeline.span(like, trimDuration: trim.duration), trimDuration: trim.duration)
    add(TextLayers.new(text: like.text, like: like, start: w.start, end: w.end), overlapping: overlaps)
  }

  /// Deletes the selected text. Deleting the first text moves the next one into its place.
  func deleteText() {
    guard deleteTextOffReason == nil else { return }
    dropTimeDraft()
    let r = resolved, id = selectedText
    updateVersion(coalesce: false) { v in if let n = TextLayers.removing(id, from: v, resolved: r) { v = n } }
    selectedTextRaw = TextLayer.firstId
  }

  /// Round 26: makes the selected text a countdown from `count` (nil = a plain text again). Turning it on gives it one
  /// second a number, ending where it ends (`TextLayers.countdownWindow`); changing the count keeps its window.
  func setSelectedCountdown(_ count: Int?) {
    guard !selectedIsFirst, !isPhoto else { return }
    let l = selectedLayer, d = trim.duration
    guard l.countdown != count else { return }
    let w = l.countdown == nil ? count.map { TextLayers.countdownWindow($0, span: TextTimeline.span(l, trimDuration: d), trimDuration: d) } : nil
    updateText(l.id) { x in
      x.countdown = count
      if let w { x.start = w.start; x.end = w.end }
    }
  }

  func setSelectedWords(_ t: String) {
    if selectedIsFirst { setText(t) } else { updateText(selectedText) { $0.text = t } }
  }

  func setSelectedStyle(_ s: TextStyle) {
    if selectedIsFirst { setVersionField(\.style, \.style, s) } else { updateText(selectedText, coalesce: false) { $0.style = s } }
  }

  func setSelectedSize(_ s: Double) {
    if selectedIsFirst { setVersionField(\.size, \.size, s) } else { updateText(selectedText) { $0.size = s } }
  }

  func setSelectedAlign(_ a: TextAlign) {
    if selectedIsFirst { setVersionField(\.align, \.align, a) } else { updateText(selectedText, coalesce: false) { $0.align = a } }
  }

  /// A text dropped on the canvas: one undo step.
  func moveText(_ id: String, x: Double, y: Double) {
    if id == TextLayer.firstId {
      updateVersion(coalesce: false) { $0.posX = x; $0.posY = y }
    } else {
      updateText(id, coalesce: false) { $0.posX = x; $0.posY = y }
    }
  }

  /// When `id` shows, seconds from the trim start.
  func setTextWindow(_ id: String, start: Double, end: Double) {
    if id == TextLayer.firstId {
      updateVersion { $0.textStart = start; $0.textEnd = end }
    } else {
      updateText(id) { $0.start = start; $0.end = end }
    }
  }

  /// A time typed into Show from or to and not committed yet. Not published: a keystroke redraws nothing.
  var timeDraft: (id: String, isStart: Bool, text: String)?

  /// Applies a typed time to the text it was typed for. Text that isn't a time changes nothing. A clip or version change calls
  /// this first, and whatever removes the text or version drops the draft, so it can never land on what comes next.
  func commitTimeDraft() {
    guard let d = timeDraft else { return }
    timeDraft = nil
    guard let t = TextTimeline.parse(d.text) else { return }
    if d.isStart { setTextTime(d.id, start: t) } else { setTextTime(d.id, end: t) }
  }

  /// Part of the time rows' identity: bumping it replaces them, so a row and its field can't pass a typed time to what comes next.
  @Published private(set) var timeDraftToken = 0

  /// Forgets a typed time because what it was typed for is going (Undo, Redo, Delete). Clearing the draft isn't enough: the field
  /// sends its text again when it ends editing, so the row goes too, and a row from before the bump is ignored.
  func dropTimeDraft() {
    timeDraft = nil
    timeDraftToken &+= 1
  }

  /// Show from (`start`) or Show to of a text, typed or from the playhead; one undo step. By id, because a typed time can
  /// land just after the selection moved on.
  func setTextTime(_ id: String, start t: Double? = nil, end e: Double? = nil) {
    guard let l = texts.first(where: { $0.id == id }) else { return }
    let d = trim.duration, s = TextTimeline.span(l, trimDuration: d)
    let a = t.map { TextTimeline.clampedStart($0, end: s.end, trimDuration: d) } ?? s.start
    let b = e.map { TextTimeline.clampedEnd($0, start: s.start, trimDuration: d) } ?? s.end
    lastUndoBreak()
    setTextWindow(id, start: a, end: b)
    lastUndoBreak()
  }

  /// The selected text's look with `change` applied. Undo: `coalesce` for a slider or the colour panel.
  func setLook(coalesce: Bool = false, _ change: (inout TextLook) -> Void) {
    var look = selectedLayer.look ?? TextLook()
    change(&look)
    writeLook(look.normalized, coalesce: coalesce)
  }

  func resetLook() { writeLook(nil, coalesce: false) }

  private func writeLook(_ look: TextLook?, coalesce: Bool) {
    guard selectedIsFirst else { updateText(selectedText, coalesce: coalesce) { $0.look = look }; return }
    // "Back to default" needs an explicit empty look only when an earlier version set one (it carries forward).
    var vs = versions.isEmpty ? [Version(number: 1)] : versions
    if let i = vs.firstIndex(where: { $0.number == versionNo }) { vs[i].textLook = nil }
    let earlier = VersionResolver.resolve(vs, number: versionNo, settings: settings, video: video).textLook
    updateVersion(coalesce: coalesce) { $0.textLook = look ?? (earlier == nil ? nil : TextLook()) }
  }
}

/// One text as the canvas draws it: the image and where its block sits (0…1, top-left origin) for hit-testing.
struct EditorDrawnText {
  var image: CGImage
  var bounds: CGRect
}

/// A drawn text on this clip: `window` is when it shows, in seconds of the clip file (nil = the trim leaves it out).
/// On a photo post it is the photos it shows on, as indexes from the first to the last (nil = none).
struct EditorTextImage: Identifiable {
  /// The text's id, or "<id>#<step>" for one number of a countdown (round 26).
  var id: String
  /// The text this draws, which selection, dragging and moving act on.
  var layerId: String
  var key: String
  var drawn: EditorDrawnText
  var window: ClosedRange<Double>?
  /// Which number of a countdown this is, from 0 (its highest); nil for every other text.
  var step: Int? = nil

  var image: CGImage { drawn.image }
  var bounds: CGRect { drawn.bounds }
  /// A countdown's numbers follow each other exactly, so two never show at once; any other text gets a frame's slack.
  func shows(at t: Double) -> Bool {
    guard let w = window else { return false }
    return step == nil ? t >= w.lowerBound - 0.01 && t <= w.upperBound + 0.01 : t >= w.lowerBound && t <= w.upperBound
  }
  /// Shown faded while selected and off screen: a countdown fades in as its first number only.
  var fadesWhenHidden: Bool { step == nil || step == 0 }
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
    Backstage.silenceForChecks(p)
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

  /// Round 21: a photo post has no player. `image` is the photo on the canvas (nil while it loads) and the playhead
  /// is its place in the post: photo i is the interval [i, i + 1), so the time is the photo's index.
  func showPhoto(_ image: CGImage?, index: Int) {
    if player != nil { unload() }
    url = nil
    if time != Double(index) { time = Double(index) }
    still = image
    ready = image != nil
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

  /// One ← / → press (or a jump button): a frame step (⇧, or a step of one frame) pauses, like any frame step; a
  /// bigger jump keeps playing if it was, so Eric can hop through a clip while listening.
  func jump(_ direction: Int, step: ArrowStep, fine: Bool, fps: Double, duration: Double) {
    if fine || step == .frame { pause() }
    seek(EditorSeek.target(from: time, step: step, fps: fps, direction: direction, fine: fine, duration: duration), exact: true)
  }
}
