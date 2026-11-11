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
  }

  /// Every text of a resolved version, numbered, against a trim of `trimDuration` seconds.
  public static func overlays(_ r: ResolvedVersion, trimDuration d: Double) -> [OverlayOut] {
    let windows = PreviewKeys.layerWindows(r, trimDuration: d)
    return r.allLayers.enumerated().map { i, l in
      let w = windows.first { $0.layer.id == l.id }?.window
      return OverlayOut(number: i + 1, id: l.id, text: l.text, style: l.style.rawValue, size: l.size, x: l.posX, y: l.posY,
                        align: l.align.rawValue, start: l.start, end: l.end, color: l.look?.color, background: l.look?.accent,
                        font: l.look?.font?.rawValue, opacity: l.look?.opacity, tracking: l.look?.tracking, drawn: w != nil,
                        shows_from: w?.lowerBound, shows_to: w.map { min($0.upperBound, d) })
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
            error_type: p.errorType?.rawValue, error_message: p.errorMessage)
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
      overlays: r1.map { overlays($0, trimDuration: trim.duration) } ?? [])
  }

  /// `djq week --json [date]`
  public static func week(_ weekStart: String, store: Store) throws -> WeekOut {
    let planner = Planner(store: store)
    let w = try planner.week(weekStart)
    let dm = try store.dayMath()
    let slots = try planner.slots(week: weekStart)
    let days = try dm.weekDays(weekStart).map { day in
      WeekOut.Day(date: day, slots: try slots.filter { $0.date == day }.map { s in
        let v = try store.video(id: s.videoId)
        return WeekOut.SlotOut(slot_id: s.id, position: s.position, pinned: s.pinned, video_id: s.videoId,
                               display_name: v?.displayName ?? s.videoId, score: v?.score,
                               posts: try store.posts(where: "plan_slot_id=?", [s.id]).map(post), exact_at: s.exactAt)
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
