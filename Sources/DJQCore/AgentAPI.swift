import Foundation

/// Stable JSON shapes for outside agents (`djq … --json`). Field names are snake_case and documented in
/// `skills/dj-queue-agent/SKILL.md`; add fields, never rename them.
public enum AgentAPI {
  public struct VideoSummary: Codable, Sendable {
    public var id: String
    public var display_name: String
    public var title: String?
    public var title_source: String?
    public var raw_tag: String
    public var name: String
    public var session: String
    public var type: String
    public var kind: String
    public var state: String
    public var score: Int?
    public var excluded: Bool
    public var missing: Bool
    public var part: Int?
    public var duration: Double
    public var marked_start: Double?
    public var marked_end: Double?
    public var audio: String?
    public var file: String?
    public var suggestion_count: Int
    public var needs_title_help: Bool
    public var issues: [String]
    /// Sent back to Edit from the Queue (`djq unqueue`); `djq requeue` clears it.
    public var held_in_edit: Bool = false
    public var sent_to_queue: Bool = false
    /// Round 4: the clip's stage (`score`, `edit`, `queue`, `scheduled`, `posted`; null = none: long-form, excluded,
    /// or unscored with its file missing). Readiness IS the stage: Edit = not ready yet, Queue = ready.
    public var stage: String? = nil
    /// Round 4: why it is in Edit, as the app's reason chips ("No crop", "Too long for X", "File missing", …).
    public var reasons: [String] = []
    /// Round 5: how many on-video text suggestions the clip has (`text_suggestions` in `djq video`).
    public var text_suggestion_count: Int = 0
    /// Round 20: the versions Eric marked ready to repost, in order (empty = none).
    public var repost_ready_versions: [Int] = []
    /// Round 21: "video", or "photo" for a photo post (one photo or a carousel). A photo post has `duration` 0, needs
    /// no score and never posts to YouTube Shorts.
    public var media: String = "video"
    /// Round 21: a photo post's photos in posting order (empty for a video). The first is the cover.
    public var photos: [PhotoOut] = []
    /// Round 23: set on a video DJ Queue made from one photo and an audio file ("Photo + audio"); absent on everything
    /// else. Such an item is a clip (`media` is "video"): it needs no score and posts to YouTube Shorts like any clip.
    public var still: StillOut? = nil
  }

  /// Round 23: what a "photo with audio" video was made from.
  public struct StillOut: Codable, Sendable {
    /// The audio file's name as Eric picked it.
    public var audio_name: String
    /// Its length, which is the video's length.
    public var audio_seconds: Double
    /// The photo the video holds.
    public var photo: PhotoOut
    /// D12: "whole" (the whole photo over a blurred copy of itself; the crop is the whole frame) or "fill" (the photo
    /// fills the frame and Eric picks the 9:16 crop).
    public var fit: String = "fill"
  }

  public static func still(_ v: Video) -> StillOut? {
    v.still.map { s in
      StillOut(audio_name: s.audioName, audio_seconds: s.audioDuration,
               photo: PhotoOut(id: s.photo.id, file: URL(fileURLWithPath: s.photo.file).lastPathComponent, width: s.photo.width,
                               height: s.photo.height), fit: s.fits.rawValue)
    }
  }

  /// Round 21: one photo of a photo post. `id` stays the same when the order changes.
  public struct PhotoOut: Codable, Sendable {
    public var id: String
    /// The file's name inside DJ Queue's own Photos folder (the original Eric picked is never touched).
    public var file: String
    /// Upright pixel size.
    public var width: Int
    public var height: Int
  }

  public static func photos(_ v: Video) -> [PhotoOut] {
    (v.photos ?? []).map { PhotoOut(id: $0.id, file: URL(fileURLWithPath: $0.file).lastPathComponent, width: $0.width, height: $0.height) }
  }

  public struct SuggestionOut: Codable, Sendable {
    public var id: Int64
    public var text: String
    public var tracks: [Track]
    public var confidence: Double?
    public var source: String
    public var origin: String
  }

  public struct PostOut: Codable, Sendable {
    public var id: String
    public var video_id: String
    public var platform: String
    public var version: Int
    public var attempt: Int
    public var kind: String
    public var state: String
    public var scheduled_at: Date
    public var posted_at: Date?
    public var url: String?
    public var error_type: String?
    public var error_message: String?
    /// Round 31: which post of its version this is (1 = the first).
    public var post_number: Int = 1
  }

  /// Round 31: one version post of a clip and where it stands (`djq video --json` → `post_units`).
  public struct UnitOut: Codable, Sendable, Hashable {
    public var version: Int
    public var post_number: Int
    /// That version's post count on each platform.
    public var of: Int
    /// "v2 · 1 of 2".
    public var label: String
    /// The day it has (nil = waiting for one, or done without a slot).
    public var date: String?
    /// Platforms that already have it (posted, on the way, failed with a retry, or skipped).
    public var platforms_done: [String]
    /// waiting · scheduled · done
    public var status: String
  }

  /// Round 16: one text on the video (`djq overlay list --json`, `overlays` in `djq video --json`). `number` is what
  /// `djq overlay set` and `remove` take (1 = the first text, the one `djq text` writes), `id` stays the same when the
  /// numbers shift. Nil look fields mean the default look.
  public struct OverlayOut: Codable, Sendable {
    public var number: Int
    public var id: String
    public var text: String
    public var style: String
    public var size: Double
    public var x: Double
    public var y: Double
    public var align: String
    /// Seconds from the trim start, as stored (null = from the start / to the end).
    public var start: Double?
    public var end: Double?
    public var color: String?
    /// The box fill, outline colour or shadow colour, by style.
    public var background: String?
    public var font: String?
    public var opacity: Double?
    public var tracking: Double?
    /// False for an empty text, while "No text" is on, or when its window falls outside the trim.
    public var drawn: Bool
    /// When it shows in the main trim, in seconds from the trim start (null when it isn't drawn).
    public var shows_from: Double?
    public var shows_to: Double?
    /// Round 26: a countdown's first number (it shows that, …, 1 across its window); absent for every other text.
    public var countdown: Int? = nil
    /// Round 30: the version's trim these times count from (absolute seconds in the clip file), and whether it is the
    /// version's own trim (false = the clip's). Absent where no trim was given.
    public var trim_in: Double? = nil
    public var trim_out: Double? = nil
    public var own_trim: Bool? = nil
  }

  /// Every text of a resolved version, numbered, against a trim of `trimDuration` seconds.
  public static func overlays(_ r: ResolvedVersion, trimDuration d: Double) -> [OverlayOut] {
    let windows = PreviewKeys.layerWindows(r, trimDuration: d)
    return r.allLayers.enumerated().map { i, l in
      let w = PreviewKeys.window(of: l.id, in: windows)
      return OverlayOut(number: i + 1, id: l.id, text: l.text, style: l.style.rawValue, size: l.size, x: l.posX, y: l.posY,
                        align: l.align.rawValue, start: l.start, end: l.end, color: l.look?.color, background: l.look?.accent,
                        font: l.look?.font?.rawValue, opacity: l.look?.opacity, tracking: l.look?.tracking, drawn: w != nil,
                        shows_from: w?.lowerBound, shows_to: w.map { min($0.upperBound, d) }, countdown: l.countdown)
    }
  }

  /// Round 30: the texts of a version timed against `edit`'s trim (that version's own, else the clip's), each saying
  /// which trim that is.
  public static func overlays(_ r: ResolvedVersion, edit re: ResolvedEdit) -> [OverlayOut] {
    overlays(r, trimDuration: re.trimOut - re.trimIn).map {
      var o = $0
      o.trim_in = re.trimIn; o.trim_out = re.trimOut; o.own_trim = re.hasVersionTrim
      return o
    }
  }

  public struct VideoDetail: Codable, Sendable {
    public var video: VideoSummary
    public var title_tracks: [Track]?
    public var title_suggestions: [SuggestionOut]
    /// Round 5: suggestions for the on-video overlay text (line breaks kept), best first.
    public var text_suggestions: [SuggestionOut]
    /// Raw overrides as stored (nil fields follow the defaults).
    public var edit: Edit
    public var resolved_edit: ResolvedEdit
    public var versions: [Version]
    public var resolved_v1: ResolvedVersion?
    public var captions: [String: String]
    public var youtube_title: String?
    public var issues: [ValidationIssue]
    public var plan: [PlanSlot]
    public var posts: [PostOut]
    /// Round 16: every text of v1 in order, the first text first (also in `versions` and `resolved_v1`, as stored).
    public var overlays: [OverlayOut] = []
    /// Round 30: each version's trim as it renders and posts (its own, else the clip's).
    public var version_trims: [VersionTrimOut] = []
    /// Round 31: every version post (each version posts its count on each platform), in planning order.
    public var post_units: [UnitOut] = []
  }

  /// Round 30: one version's trim. `own` = the version's own trim (`djq trim --version`); false = it follows the clip's
  /// trim (`clip_default` says whether that is still the default: markers ± extra seconds).
  public struct VersionTrimOut: Codable, Sendable, Hashable {
    public var version: Int
    public var trim_in: Double
    public var trim_out: Double
    public var duration: Double
    public var own: Bool
    public var clip_default: Bool
    public var platform_trims: [String: TrimRange]
  }

  /// Every stored version's trim (v1 even when no row is stored yet).
  public static func versionTrims(_ id: String, store: Store, settings: Settings) throws -> [VersionTrimOut] {
    guard let v = try store.video(id: id), !v.isPhoto else { return [] }
    let edit = try store.edit(videoId: id)
    let all = (try? store.versions(videoId: id)) ?? []
    let numbers = Set([1] + all.map(\.number)).sorted()
    return numbers.map { n in
      let re = EditResolver.resolve(edit, video: v, defaults: settings.defaults, version: all.first { $0.number == n })
      return VersionTrimOut(version: n, trim_in: re.trimIn, trim_out: re.trimOut, duration: re.trimOut - re.trimIn,
                            own: re.hasVersionTrim, clip_default: !re.hasVersionTrim && re.isDefault(.trimIn) && re.isDefault(.trimOut),
                            platform_trims: Dictionary(uniqueKeysWithValues: re.platformTrims.map { ($0.key.rawValue, $0.value) }))
    }
  }

  public struct WeekOut: Codable, Sendable {
    public struct Day: Codable, Sendable {
      public var date: String
      public var slots: [SlotOut]
    }
    public struct SlotOut: Codable, Sendable {
      public var slot_id: String
      public var position: Int
      public var pinned: Bool
      public var video_id: String
      public var display_name: String
      public var score: Int?
      public var posts: [PostOut]
      /// Round 21: the moment of a set-time slot (its `position` is then 100 or above). Absent on a regular slot.
      public var exact_at: Date?
      /// Round 31: the version post this day carries.
      public var version: Int = 1
      public var post_number: Int = 1
      public var label: String = "v1"
    }
    public var week_start: String
    public var state: String
    public var approved_at: Date?
    public var days: [Day]
  }

  public static var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
  }

  public static func summary(_ v: Video, store: Store, sessions: [String: Session]? = nil,
                             context: ValidationContext? = nil) throws -> VideoSummary {
    let sugg = try store.titleSuggestions(videoId: v.id)
    let s = try sessions?[v.sessionId] ?? store.session(id: v.sessionId)
    let issues = v.type == .short ? ((try? Validation.issues(video: v, store: store, context: context)) ?? []) : []
    return VideoSummary(
      id: v.id, display_name: v.displayName, title: v.titleText, title_source: v.titleSource,
      raw_tag: v.tag, name: v.name, session: s?.name ?? "", type: v.type.rawValue, kind: v.kind.rawValue,
      state: v.state.rawValue, score: v.score, excluded: v.excluded, missing: v.missing, part: v.part, duration: v.duration,
      marked_start: v.markedStart, marked_end: v.markedEnd, audio: v.audio, file: (try? store.fileURL(for: v))??.path,
      suggestion_count: sugg.count, needs_title_help: AgentPrompts.needsTitleHelp(v, suggestions: sugg),
      issues: issues.map(\.message), held_in_edit: v.heldInEdit, sent_to_queue: v.sentToQueue, stage: ClipStage.of(v)?.rawValue,
      reasons: ClipStage.of(v) == .edit ? issues.sorted { $0.kind.chipOrder < $1.kind.chipOrder }.map(\.chipText) : [],
      text_suggestion_count: try store.suggestionCount(.text, videoId: v.id),
      repost_ready_versions: v.type == .short ? ((try? store.repostReadyVersions(videoId: v.id)) ?? []) : [],
      media: v.isPhoto ? "photo" : "video", photos: photos(v), still: still(v))
  }

  static func suggestion(_ s: TitleSuggestion) -> SuggestionOut {
    SuggestionOut(id: s.id, text: s.text, tracks: s.tracks, confidence: s.confidence, source: s.source, origin: s.origin)
  }

  public static func post(_ p: PlatformPost) -> PostOut {
    PostOut(id: p.id, video_id: p.videoId, platform: p.platform.rawValue, version: p.versionNo, attempt: p.attemptNo,
            kind: p.kind.rawValue, state: p.state.rawValue, scheduled_at: p.scheduledAt, posted_at: p.postedAt, url: p.url,
            error_type: p.errorType?.rawValue, error_message: p.errorMessage, post_number: p.postNo)
  }

  /// Every version post of a short clip, in planning order (round 31).
  public static func units(_ id: String, store: Store, settings: Settings) throws -> [UnitOut] {
    guard let v = try store.video(id: id), v.type == .short else { return [] }
    let book = try UnitBook(store: store, settings: settings, videos: [v])
    guard let c = book[id] else { return [] }
    let slots = try store.planSlots(where: "video_id=?", [id])
    let pending = Set(c.pending(settings.activePlatforms))
    return c.all.map { u in
      let slot = slots.filter { $0.unit == u }.map(\.date).max()
      let done = Platform.allCases.filter { c.taken[$0]?.contains(u) ?? false }.map(\.rawValue)
      return UnitOut(version: u.version, post_number: u.post, of: c.counts[u.version] ?? 1, label: book.label(id, u), date: slot,
                     platforms_done: done, status: pending.contains(u) ? "waiting" : slot != nil ? "scheduled" : "done")
    }
  }

  /// `djq videos --json [--state S] [--stage S]` (state also accepts the BulkActions filters: unscored, scored,
  /// needs-edit, all; stage: score, edit, queue, scheduled, posted).
  public static func videos(store: Store, filter: String? = nil, stage: ClipStage? = nil) throws -> [VideoSummary] {
    let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
    let ctx = try ValidationContext.load(store)
    var vids: [Video]
    if let f = filter {
      let ids = try BulkActions(store: store).ids(filter: f)
      vids = try ids.compactMap { try store.video(id: $0) }
    } else {
      vids = try store.videos().sorted { ($0.sessionId, $0.part ?? 0, $0.start ?? 0, $0.name) < ($1.sessionId, $1.part ?? 0, $1.start ?? 0, $1.name) }
    }
    if let stage { vids = vids.filter { ClipStage.of($0) == stage } }
    return try vids.map { try summary($0, store: store, sessions: sessions, context: ctx) }
  }

  /// `djq video <id> --json`
  public static func video(_ id: String, store: Store) throws -> VideoDetail {
    guard let v = try store.video(id: id) else { throw EngineError("No video \(id)") }
    let settings = try store.settings()
    let r1 = try store.resolvedVersion(videoId: id, number: 1, settings: settings)
    var captions: [String: String] = [:]
    var yt: String?
    if let r1, v.type == .short {
      let session = try store.session(id: v.sessionId)?.name ?? ""
      let sets = try store.hashtagSets(), templates = try store.captionTemplates()
      for p in settings.activePlatforms where !v.isPhoto || p.supportsPhotos {
        captions[p.rawValue] = Captions.caption(for: p, version: r1, video: v, sessionName: session, sets: sets,
                                                templates: templates, settings: settings)
      }
      if !v.isPhoto { yt = Captions.youtubeTitle(r1, video: v, settings: settings) }  // a photo post never goes to YouTube
    }
    let trim = try store.resolvedEdit(videoId: id, settings: settings).trim()
    return VideoDetail(
      video: try summary(v, store: store), title_tracks: v.titleText == nil ? nil : v.titleTracks,
      title_suggestions: try store.titleSuggestions(videoId: id).map(suggestion),
      text_suggestions: try store.textSuggestions(videoId: id).map(suggestion),
      edit: try store.edit(videoId: id), resolved_edit: try store.resolvedEdit(videoId: id, settings: settings),
      versions: try store.versions(videoId: id), resolved_v1: r1, captions: captions, youtube_title: yt,
      issues: v.type == .short ? try Validation.issues(video: v, store: store) : [],
      plan: try store.planSlots(where: "video_id=?", [id]), posts: try store.posts(where: "video_id=?", [id]).map(post),
      overlays: r1.map { overlays($0, trimDuration: trim.duration) } ?? [],
      version_trims: try versionTrims(id, store: store, settings: settings),
      post_units: try units(id, store: store, settings: settings))
  }

  /// `djq week --json [date]`
  public static func week(_ weekStart: String, store: Store) throws -> WeekOut {
    let planner = Planner(store: store)
    let w = try planner.week(weekStart)
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let slots = try planner.slots(week: weekStart)
    let days = try dm.weekDays(weekStart).map { day in
      WeekOut.Day(date: day, slots: try slots.filter { $0.date == day }.map { s in
        let v = try store.video(id: s.videoId)
        return WeekOut.SlotOut(slot_id: s.id, position: s.position, pinned: s.pinned, video_id: s.videoId,
                               display_name: v?.displayName ?? s.videoId, score: v?.score,
                               posts: try store.posts(where: "plan_slot_id=?", [s.id]).map(post), exact_at: s.exactAt,
                               version: s.versionNo, post_number: s.postNo,
                               label: s.unit.label(of: try store.postCount(videoId: s.videoId, version: s.versionNo, settings: settings)))
      })
    }
    return WeekOut(week_start: weekStart, state: w.state.rawValue, approved_at: w.approvedAt, days: days)
  }

  /// `djq posts --json [--problems]`
  public static func posts(store: Store, problems: Bool = false, since: Date? = nil) throws -> [PostOut] {
    if problems { return try PostActions(store: store).problems().map(post) }
    if let since { return try store.posts(where: "scheduled_at>=?", [since]).map(post) }
    return try store.posts().map(post)
  }
}
