import Foundation

// MARK: - Enums

public enum Platform: String, CaseIterable, Codable, Sendable, Identifiable, Comparable {
  case facebook, threads, youtube, x, instagram, tiktok

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .tiktok: "TikTok"
    case .instagram: "Instagram"
    case .facebook: "Facebook"
    case .youtube: "YouTube Shorts"
    case .threads: "Threads"
    case .x: "X"
    }
  }

  public var shortName: String {
    switch self {
    case .tiktok: "TT"
    case .instagram: "IG"
    case .facebook: "FB"
    case .youtube: "YT"
    case .threads: "TH"
    case .x: "X"
    }
  }

  /// Default slot, minutes after local midnight (decision Q2).
  public var defaultSlotMinutes: Int {
    switch self {
    case .facebook: 12 * 60 + 30
    case .threads: 13 * 60 + 30
    case .youtube: 15 * 60
    case .x: 17 * 60
    case .instagram: 18 * 60
    case .tiktok: 19 * 60
    }
  }

  public var uploadURL: URL {
    switch self {
    case .tiktok: URL(string: "https://www.tiktok.com/tiktokstudio/upload")!
    case .instagram: URL(string: "https://www.instagram.com/")!
    case .facebook: URL(string: "https://www.facebook.com/profile.php?id=61595855771158")!
    case .youtube: URL(string: "https://studio.youtube.com/")!
    case .threads: URL(string: "https://www.threads.com/")!
    case .x: URL(string: "https://x.com/compose/post")!
    }
  }

  /// Hosts a posted URL must belong to (Mark posted validation).
  public var urlHosts: [String] {
    switch self {
    case .tiktok: ["tiktok.com"]
    case .instagram: ["instagram.com"]
    case .facebook: ["facebook.com", "fb.watch", "fb.com"]
    case .youtube: ["youtube.com", "youtu.be"]
    case .threads: ["threads.net", "threads.com"]
    case .x: ["x.com", "twitter.com"]
    }
  }

  /// Order by default slot time, so lists read in posting order.
  public static func < (a: Platform, b: Platform) -> Bool { a.defaultSlotMinutes < b.defaultSlotMinutes }

  /// Round 21: the most photos one post carries here through Postiz (docs/postiz.md, checked 2026-11-10). 0 = the platform
  /// takes no photo posts (YouTube Shorts is video only). A carousel with more goes out with its first `maxPhotos`.
  public var maxPhotos: Int {
    switch self {
    case .youtube: 0
    case .x: 4
    case .instagram, .facebook: 10
    case .threads: 20
    case .tiktok: 35
    }
  }

  public var supportsPhotos: Bool { maxPhotos > 0 }
}

/// Decision Q9: only two kinds.
public enum Kind: String, CaseIterable, Codable, Sendable {
  case djVid = "dj vid"
  case talking

  public var displayName: String { self == .djVid ? "DJ vid" : "Talking" }
}

public enum VideoType: String, Codable, Sendable {
  case short = "short-form"
  case long = "long-form"
}

public enum VideoState: String, Codable, Sendable, CaseIterable {
  case needsEdit = "needs_edit"
  case ready, planned, posting, posted, partial, excluded
  case missingFile = "missing_file"

  /// Round 4 (S1): readiness is the stage, so these read as stage names — never "Ready" / "Needs edit".
  /// (`needs_edit` / `ready` stay the stored values.)
  public var displayName: String {
    switch self {
    case .needsEdit: "In Edit"
    case .ready: "In Queue"
    case .planned: "Scheduled"
    case .posting: "Posting"
    case .posted: "Posted"
    case .partial: "Partial"
    case .excluded: "Excluded"
    case .missingFile: "File missing"
    }
  }
}

public enum PostState: String, Codable, Sendable, CaseIterable {
  case planned, rendering, rendered, due, posted, failed
  case copyrightBlocked = "copyright_blocked"
  case copyrightMuted = "copyright_muted"
  case removed, skipped, overdue

  /// The post is in flight or went out, so its caption is held (only failed and skipped aren't).
  public var holdsCaption: Bool { self != .failed && self != .skipped }

  /// The post went out: its caption is the record of what was posted.
  public var wentOut: Bool { [.posted, .copyrightBlocked, .copyrightMuted, .removed].contains(self) }

  /// Terminal states end a platform post; everything else is still in flight.
  public var isTerminal: Bool {
    switch self {
    case .posted, .failed, .copyrightBlocked, .copyrightMuted, .removed, .skipped: true
    default: false
    }
  }

  public var isCopyright: Bool { self == .copyrightBlocked || self == .copyrightMuted || self == .removed }
  public var isProblem: Bool { self == .failed || isCopyright || self == .overdue }

  public var displayName: String {
    switch self {
    case .planned: "Planned"
    case .rendering: "Rendering"
    case .rendered: "Rendered"  // a render state (file made), not clip readiness (round 4 S1)
    case .due: "Due"
    case .posted: "Posted"
    case .failed: "Failed"
    case .copyrightBlocked: "© Blocked"
    case .copyrightMuted: "© Muted"
    case .removed: "Removed"
    case .skipped: "Skipped"
    case .overdue: "Overdue"
    }
  }
}

public enum ErrorType: String, Codable, Sendable, CaseIterable {
  case tooLong = "too_long", tooLarge = "too_large", format
  case uploadFailed = "upload_failed"
  case copyrightBlocked = "copyright_blocked", copyrightMuted = "copyright_muted"
  case removed, other

  public var displayName: String {
    switch self {
    case .tooLong: "Too long"
    case .tooLarge: "Too large"
    case .format: "Format"
    case .uploadFailed: "Upload failed"
    case .copyrightBlocked: "Copyright blocked"
    case .copyrightMuted: "Copyright muted"
    case .removed: "Removed"
    case .other: "Other"
    }
  }

  /// The PlatformPost state a reported error moves the post to.
  public var postState: PostState {
    switch self {
    case .copyrightBlocked: .copyrightBlocked
    case .copyrightMuted: .copyrightMuted
    case .removed: .removed
    default: .failed
    }
  }
}

public enum PostKind: String, Codable, Sendable { case regular, retry, repost }

public enum Aspect: String, Codable, Sendable, CaseIterable {
  case r9x16 = "9:16", r4x5 = "4:5", r1x1 = "1:1", r16x9 = "16:9"

  /// Width / height.
  public var ratio: Double {
    switch self {
    case .r9x16: 9.0 / 16
    case .r4x5: 4.0 / 5
    case .r1x1: 1
    case .r16x9: 16.0 / 9
    }
  }

  /// Output size at 1080 wide (spec §7).
  public var outputSize: (w: Int, h: Int) {
    let h = Int((1080 / ratio).rounded())
    return (1080, h + h % 2)
  }
}

public enum TextStyle: String, Codable, Sendable, CaseIterable {
  case box, outline, shadow

  public var displayName: String {
    switch self {
    case .box: "White box"
    case .outline: "Outline"
    case .shadow: "Shadow"
    }
  }
}

public enum TextAlign: String, Codable, Sendable, CaseIterable { case left, center, right }

// MARK: - Records

public struct Session: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var folder: String  // absolute path
  public var name: String
  public var date: String?  // YYYY-MM-DD from the folder name
  public var discoveredAt: Date
  public var missing: Bool

  /// Round 21: the one session every photo post belongs to. Its folder is `Paths.photos`; intake never scans it or marks
  /// it missing.
  public static let photosId = "photos"
  public var isPhotos: Bool { id == Session.photosId }
}

/// One photo of a photo post (round 21). The file is the app's own copy under `Paths.photos`; the original is never touched.
public struct PhotoItem: Codable, Sendable, Hashable, Identifiable {
  /// Stable across reorders; `Edit.photoCrops` is keyed by it.
  public var id: String
  /// Relative to the Photos session folder (`Paths.photos`), e.g. "Originals/<post id>/01-a1b2c3d4.jpg".
  public var file: String
  /// Upright pixel size (EXIF orientation applied).
  public var width: Int
  public var height: Int
  /// Size and SHA-256 of the copied file, taken at import (nil on a hand-built value). The render hash reads it, so a
  /// reorder or a swapped photo re-renders and nothing else does.
  public var fingerprint: String? = nil

  public init(id: String = PhotoItem.newId(), file: String, width: Int, height: Int, fingerprint: String? = nil) {
    self.id = id; self.file = file; self.width = width; self.height = height; self.fingerprint = fingerprint
  }

  public static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}

/// Round 23: what a "photo with audio" video was made from (`StillVideo`). The item is an ordinary clip whose file is the
/// video DJ Queue made; this keeps the photo (so Remove audio can give the photo post back) and the audio's own copy.
public struct StillSource: Codable, Sendable, Hashable {
  /// The photo the video holds, as the photo post had it (DJ Queue's copy under `Paths.photos`).
  public var photo: PhotoItem
  /// DJ Queue's copy of the audio, relative to the Photos folder: "Stills/<video id>/audio.m4a", the AAC the video
  /// holds (never the picked file, which may be a whole video). A fit change makes the video again from it.
  public var audio: String
  /// The picked file's name, e.g. "Friday mix.mp3" (what the editor's Audio row shows).
  public var audioName: String
  /// Seconds of audio, which is the video's length.
  public var audioDuration: Double
  /// D12: how the photo sits in the 9:16 video. nil (a row made before this) reads as `fill`.
  public var fit: Fit? = nil
  /// The video made earlier from this same audio at the other fit, when there is one ("Stills/<video id>/video-2.mp4"):
  /// a fit change points the row back at it instead of making a third file.
  public var other: String? = nil

  /// `whole`: the whole photo, centred over a blurred copy of itself, in a 9:16 video whose crop is the whole frame.
  /// `fill`: the video has the photo's own shape and Eric picks the 9:16 crop, as on any clip.
  public enum Fit: String, Codable, Sendable, CaseIterable {
    case whole, fill
    public var displayName: String { self == .whole ? "Whole photo" : "Fill the frame" }
  }

  /// The fit in force.
  public var fits: Fit { fit ?? .fill }

  public init(photo: PhotoItem, audio: String, audioName: String, audioDuration: Double, fit: Fit? = nil, other: String? = nil) {
    self.photo = photo; self.audio = audio; self.audioName = audioName; self.audioDuration = audioDuration; self.fit = fit
    self.other = other
  }
}

public struct Video: Codable, Sendable, Identifiable, Hashable {
  public var id: String  // = videos.json id
  public var sessionId: String
  public var name: String
  public var tags: [String]
  public var type: VideoType
  public var contentType: String
  public var kind: Kind
  public var file: String  // relative to session folder
  public var fingerprint: String?
  public var fileSize: Int64?
  public var duration: Double
  public var markedStart: Double?
  public var markedEnd: Double?
  public var start: Double?
  public var end: Double?
  public var grace: Double?
  public var audio: String?
  public var part: Int?
  public var score: Int?
  public var state: VideoState
  public var excluded: Bool
  public var missing: Bool
  public var inManifest: Bool
  public var notes: String
  public var alreadyPostedOn: [Platform]
  public var longformURL: String?
  public var createdAt: Date
  public var updatedAt: Date
  /// Eric's title (app-owned). Seeded once from videos.json `title` when empty; never derived from the tag.
  /// Feeds the overlay-text default, caption `{text}`, the YouTube title and the display name.
  public var title: String? = nil
  /// Optional structured track names behind the title (from an accepted suggestion or `djq title --tracks`).
  public var titleTracks: [Track]? = nil
  /// Who set `title`: "manifest" (videos.json seed), "app" (Eric in the app), "agent" (djq), "suggestion";
  /// "cleared" (with title nil) = deliberately cleared, so videos.json never re-seeds it.
  public var titleSource: String? = nil
  /// Source picture size, cached the first time the file is probed (nil = not probed yet).
  public var sourceWidth: Int? = nil
  public var sourceHeight: Int? = nil
  /// Sent back to Edit from the Queue ("Remove from queue", app-owned, schema v3): the clip stays `needs_edit`
  /// with the issue "Sent back from Queue" until "Send to queue" clears it.
  public var heldInEdit: Bool = false
  /// Eric sent it to the Queue (round 13, A11). Nothing else moves a clip Edit → Queue: a short clip that isn't sent stays
  /// `needs_edit` even with nothing to fix. It goes back to false when the clip leaves the Queue for Edit, its score is
  /// cleared or it's excluded.
  public var sentToQueue: Bool = false
  /// Round 21: the photos of a photo post, in posting order (one = a single photo, more = a carousel). nil = a video.
  /// A photo post is a short-form item with `duration` 0 and `file` = its first photo; it lives in the Photos session
  /// (`Session.photosId`), never comes from videos.json (`inManifest` false) and needs no score.
  public var photos: [PhotoItem]? = nil
  /// Round 23: set on a video DJ Queue made from one photo and an audio file ("Photo + audio"). Such an item is a clip
  /// everywhere (`photos` is nil, `file` is the made video under `Paths.photos`, `duration` is the audio's length); it
  /// stays in the Photos session, never comes from videos.json and needs no score. nil for every other video.
  public var still: StillSource? = nil

  /// A photo post (single photo or carousel), not a video.
  public var isPhoto: Bool { photos != nil }

  /// A video made from a photo and an audio file (round 23). A clip in every way but the four `StillVideo` lists.
  public var isStill: Bool { still != nil }

  /// Round 23: the one test for "this item skips Score": a photo post, or a video made from a photo. Stage and Queue
  /// rules ask this; nothing else about a made video is photo-like.
  public var needsNoScore: Bool { isPhoto || isStill }

  /// The marker tag (the part of the name after the session), e.g. "yayo x johnny".
  public var tag: String { tags.first ?? name }

  /// What every screen shows for this clip: the title, else the raw marker tag verbatim (no tidying, no guessing).
  public var displayName: String {
    if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
    return tag
  }

  /// The title if set (trimmed, non-empty), else nil.
  public var titleText: String? {
    guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
  }

  /// Eric's in/out markers relative to the clip file (spec §1).
  public var markerIn: Double? {
    guard let ms = markedStart, let s = start else { return nil }
    return ms - s
  }

  public var markerOut: Double? {
    guard let me = markedEnd, let s = start else { return nil }
    return me - s
  }
}

public struct CropRect: Codable, Sendable, Hashable {
  public var x: Double, y: Double, w: Double, h: Double
  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x; self.y = y; self.w = w; self.h = h
  }
}

public struct TrimRange: Codable, Sendable, Hashable {
  public var start: Double, end: Double
  public init(start: Double, end: Double) { self.start = start; self.end = end }
  public var duration: Double { end - start }
}

/// One per video (spec §3 Edit). Round 2: stores ONLY Eric's overrides — every nil field follows
/// `Settings.defaults` (NewClipDefaults). Read the effective values through `ResolvedEdit`
/// (`Store.resolvedEdit(videoId:)` / `EditResolver.resolve`), which also says which fields are defaults.
public struct Edit: Codable, Sendable, Hashable {
  /// nil = `defaults.aspect`. (JSON key "aspect".)
  public var aspectOverride: Aspect?
  /// Confirmed crop in source pixels. nil = not confirmed yet; previews use the default crop anchor.
  public var crop: CropRect?
  /// Absolute seconds in the clip file. nil = default trim (markers ± extra seconds, or the whole file).
  public var trimIn: Double?
  public var trimOut: Double?
  /// Absolute seconds. nil = default cover frame (`defaults.coverFrame`).
  public var coverTime: Double?
  /// nil = `defaults.coverIncludesText`. (JSON key "coverIncludesText".)
  public var coverIncludesTextOverride: Bool?
  public var platformTrims: [Platform: TrimRange] = [:]
  /// Platforms Eric skipped for this clip.
  public var skippedPlatforms: Set<Platform> = []
  /// Platforms Eric turned ON for this clip although `defaults.platforms` leaves them out.
  public var includedPlatforms: Set<Platform> = []
  /// Round 21: a photo post's confirmed crop per photo (`PhotoItem.id` → crop in that photo's upright pixels). A photo
  /// without one uses the centred crop for the post's aspect. Empty for videos, and then absent from the stored JSON.
  public var photoCrops: [String: CropRect] = [:]
  /// Round 24: Eric's own timeline markers (absolute seconds in the clip file, sorted). Trim handles, the playhead and
  /// text bars snap to them. Not part of any render (`Renderer.HashInput` never reads them). Absent from the JSON when
  /// empty, so stored rows don't change.
  public var marks: [Double] = []

  public init() {}

  enum CodingKeys: String, CodingKey {
    case aspectOverride = "aspect", crop, trimIn, trimOut, coverTime
    case coverIncludesTextOverride = "coverIncludesText", platformTrims, skippedPlatforms, includedPlatforms, photoCrops, marks
  }

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    aspectOverride = try c.decodeIfPresent(Aspect.self, forKey: .aspectOverride)
    crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
    trimIn = try c.decodeIfPresent(Double.self, forKey: .trimIn)
    trimOut = try c.decodeIfPresent(Double.self, forKey: .trimOut)
    coverTime = try c.decodeIfPresent(Double.self, forKey: .coverTime)
    coverIncludesTextOverride = try c.decodeIfPresent(Bool.self, forKey: .coverIncludesTextOverride)
    platformTrims = try c.decodeIfPresent([Platform: TrimRange].self, forKey: .platformTrims) ?? [:]
    skippedPlatforms = try c.decodeIfPresent(Set<Platform>.self, forKey: .skippedPlatforms) ?? []
    includedPlatforms = try c.decodeIfPresent(Set<Platform>.self, forKey: .includedPlatforms) ?? []
    photoCrops = ((try? c.decodeIfPresent([String: CropRect].self, forKey: .photoCrops)) ?? nil) ?? [:]
    marks = ((try? c.decodeIfPresent([Double].self, forKey: .marks)) ?? nil) ?? []
  }

  /// Deterministic JSON (sets sorted), so stored rows and hashes don't change when nothing changed.
  public func encode(to enc: Encoder) throws {
    var c = enc.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(aspectOverride, forKey: .aspectOverride)
    try c.encodeIfPresent(crop, forKey: .crop)
    try c.encodeIfPresent(trimIn, forKey: .trimIn)
    try c.encodeIfPresent(trimOut, forKey: .trimOut)
    try c.encodeIfPresent(coverTime, forKey: .coverTime)
    try c.encodeIfPresent(coverIncludesTextOverride, forKey: .coverIncludesTextOverride)
    try c.encode(platformTrims, forKey: .platformTrims)
    try c.encode(skippedPlatforms.sorted { $0.rawValue < $1.rawValue }, forKey: .skippedPlatforms)
    try c.encode(includedPlatforms.sorted { $0.rawValue < $1.rawValue }, forKey: .includedPlatforms)
    if !photoCrops.isEmpty { try c.encode(photoCrops, forKey: .photoCrops) }
    if !marks.isEmpty { try c.encode(marks, forKey: .marks) }
  }

  /// True when the clip doesn't post on `p` (skipped, or left out by the default platforms and not turned on).
  public func isSkipped(_ p: Platform, defaults: NewClipDefaults) -> Bool {
    if skippedPlatforms.contains(p) { return true }
    return !defaults.platforms.contains(p) && !includedPlatforms.contains(p)
  }

  /// True when nothing is overridden.
  public var isEmpty: Bool { self == Edit() }

  /// Round 24: true when `self` and `other` differ only in Eric's timeline markers, which change no pixels (a save
  /// like that leaves the clip's preview stamp alone).
  public func differsOnlyInMarks(from other: Edit) -> Bool {
    var a = self, b = other
    a.marks = []; b.marks = []
    return a == b && marks != other.marks
  }
}

/// Text versions with carry-forward: nil fields inherit from the previous version (spec §3).
public struct Version: Codable, Sendable, Hashable {
  public var number: Int
  public var text: String?
  public var noText: Bool?
  public var style: TextStyle?
  public var size: Double?  // points at 1080-wide output
  public var posX: Double?  // normalised centre in output frame
  public var posY: Double?
  public var align: TextAlign?
  public var textStart: Double?  // seconds relative to trim start
  public var textEnd: Double?
  /// Round 16: every text after the first, carried forward as one list (nil inherits, [] = explicitly none).
  /// The first text stays in the fields above.
  public var moreText: [TextLayer]?
  /// Round 16: the first text's look, carried forward (nil inherits, an empty look = back to the default).
  public var textLook: TextLook?
  public var caption: String?
  public var captionTemplateId: String?
  public var hashtagSetIds: [String]?
  public var extraHashtags: [String]?
  public var youtubeTitle: String?
  public var platformCaptions: [Platform: String]?
  /// Round 7: the YouTube title template this version chose (`Settings.youtubeTitleTemplates` id); nil = the default.
  /// A typed `youtubeTitle` still wins over any template.
  public var youtubeTitleTemplateId: String?
  /// Round 20: Eric marked this version ready for the repost cycle. Per version, never carried forward, never part of
  /// how the clip looks or posts (no render, preview or caption reads it), and never moves the clip between stages.
  /// nil/false = not ready. `RepostReady` reads it.
  public var repostReady: Bool?
  /// Round 20: this version keeps its own caption. Caption fields (caption, templates, hashtag groups, extras, YouTube
  /// title, per-platform captions) don't carry forward into it from earlier versions; what it doesn't set follows the
  /// defaults. Set by a bulk caption change on v1, after copying in what the version showed, so the change stays on v1.
  public var captionsOwn: Bool?
  /// Round 27 (Eric: a new version is its own; edits to one version never change another). This version stands alone:
  /// nothing carries forward into it from earlier versions, and a field it doesn't set follows the defaults. Every
  /// version made from v2 on is written this way (`VersionCopy`), and schema 11 turned every older v2+ into one,
  /// copying in what it showed. nil only on v1 and in data from before schema 11.
  public var standalone: Bool?

  public init(number: Int) { self.number = number }
}

/// A version with carry-forward applied and defaults filled.
public struct ResolvedVersion: Sendable, Hashable, Codable {
  public var number: Int
  public var text: String
  public var noText: Bool
  public var style: TextStyle
  public var size: Double
  public var posX: Double
  public var posY: Double
  public var align: TextAlign
  public var textStart: Double?
  public var textEnd: Double?
  public var caption: String
  public var captionTemplateId: String?
  public var hashtagSetIds: [String]
  public var extraHashtags: [String]
  public var youtubeTitle: String
  public var platformCaptions: [Platform: String]
  /// Round 7: the chosen YouTube title template id (carried forward; nil = follows `defaults.youtubeTitleTemplateId`).
  public var youtubeTitleTemplateId: String? = nil
  /// The YouTube title template text this version uses (chosen, else the default one). nil only on hand-built values;
  /// `Captions.youtubeTitle` then uses the template it is given.
  public var youtubeTitleTemplate: String? = nil
  /// Round 16: every text after the first (see `layers`). Encoded only when non-empty.
  public var moreText: [TextLayer] = []
  /// Round 16: the first text's look, normalised (nil = today's look). Encoded only when set.
  public var textLook: TextLook? = nil
  /// Field names that came from an earlier version (shown faded in the editor).
  public var inherited: Set<String>
  /// Field names (Version property names) that no version set, so they come from `Settings.defaults`
  /// ("Default" vs "Custom" in the editor). "text"/"noText" are defaulted together.
  public var defaulted: Set<String> = []

  public var hasText: Bool { !noText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// True when `field` (a Version property name) follows the defaults.
  public func isDefault(_ field: String) -> Bool { defaulted.contains(field) }

  enum CodingKeys: String, CodingKey {
    case number, text, noText, style, size, posX, posY, align, textStart, textEnd, caption, captionTemplateId,
         hashtagSetIds, extraHashtags, youtubeTitle, platformCaptions, inherited, defaulted, youtubeTitleTemplateId,
         youtubeTitleTemplate, moreText, textLook
  }

  /// Deterministic JSON (sets sorted), so hashes/snapshots of a resolved version are stable.
  public func encode(to enc: Encoder) throws {
    var c = enc.container(keyedBy: CodingKeys.self)
    try c.encode(number, forKey: .number); try c.encode(text, forKey: .text); try c.encode(noText, forKey: .noText)
    try c.encode(style, forKey: .style); try c.encode(size, forKey: .size); try c.encode(posX, forKey: .posX)
    try c.encode(posY, forKey: .posY); try c.encode(align, forKey: .align)
    try c.encodeIfPresent(textStart, forKey: .textStart); try c.encodeIfPresent(textEnd, forKey: .textEnd)
    try c.encode(caption, forKey: .caption); try c.encodeIfPresent(captionTemplateId, forKey: .captionTemplateId)
    try c.encode(hashtagSetIds, forKey: .hashtagSetIds); try c.encode(extraHashtags, forKey: .extraHashtags)
    try c.encode(youtubeTitle, forKey: .youtubeTitle)
    try c.encode(Dictionary(uniqueKeysWithValues: platformCaptions.map { ($0.key.rawValue, $0.value) }), forKey: .platformCaptions)
    try c.encode(inherited.sorted(), forKey: .inherited); try c.encode(defaulted.sorted(), forKey: .defaulted)
    try c.encodeIfPresent(youtubeTitleTemplateId, forKey: .youtubeTitleTemplateId)
    try c.encodeIfPresent(youtubeTitleTemplate, forKey: .youtubeTitleTemplate)
    if !moreText.isEmpty { try c.encode(moreText, forKey: .moreText) }
    try c.encodeIfPresent(textLook, forKey: .textLook)
  }

  public init(from dec: Decoder) throws {
    let c = try dec.container(keyedBy: CodingKeys.self)
    number = try c.decode(Int.self, forKey: .number)
    text = try c.decode(String.self, forKey: .text)
    noText = try c.decode(Bool.self, forKey: .noText)
    style = try c.decode(TextStyle.self, forKey: .style)
    size = try c.decode(Double.self, forKey: .size)
    posX = try c.decode(Double.self, forKey: .posX)
    posY = try c.decode(Double.self, forKey: .posY)
    align = try c.decode(TextAlign.self, forKey: .align)
    textStart = try c.decodeIfPresent(Double.self, forKey: .textStart)
    textEnd = try c.decodeIfPresent(Double.self, forKey: .textEnd)
    caption = try c.decode(String.self, forKey: .caption)
    captionTemplateId = try c.decodeIfPresent(String.self, forKey: .captionTemplateId)
    hashtagSetIds = try c.decode([String].self, forKey: .hashtagSetIds)
    extraHashtags = try c.decode([String].self, forKey: .extraHashtags)
    youtubeTitle = try c.decode(String.self, forKey: .youtubeTitle)
    let pc = try c.decodeIfPresent([String: String].self, forKey: .platformCaptions) ?? [:]
    platformCaptions = Dictionary(uniqueKeysWithValues: pc.compactMap { k, v in Platform(rawValue: k).map { ($0, v) } })
    inherited = try c.decodeIfPresent(Set<String>.self, forKey: .inherited) ?? []
    defaulted = try c.decodeIfPresent(Set<String>.self, forKey: .defaulted) ?? []
    youtubeTitleTemplateId = try c.decodeIfPresent(String.self, forKey: .youtubeTitleTemplateId)
    youtubeTitleTemplate = try c.decodeIfPresent(String.self, forKey: .youtubeTitleTemplate)
    moreText = ((try? c.decodeIfPresent([TextLayer].self, forKey: .moreText)) ?? nil) ?? []
    textLook = (try? c.decodeIfPresent(TextLook.self, forKey: .textLook)) ?? nil
  }

  public init(number: Int, text: String, noText: Bool, style: TextStyle, size: Double, posX: Double, posY: Double,
              align: TextAlign, textStart: Double?, textEnd: Double?, caption: String, captionTemplateId: String?,
              hashtagSetIds: [String], extraHashtags: [String], youtubeTitle: String, platformCaptions: [Platform: String],
              inherited: Set<String>, defaulted: Set<String> = []) {
    self.number = number; self.text = text; self.noText = noText; self.style = style; self.size = size
    self.posX = posX; self.posY = posY; self.align = align; self.textStart = textStart; self.textEnd = textEnd
    self.caption = caption; self.captionTemplateId = captionTemplateId; self.hashtagSetIds = hashtagSetIds
    self.extraHashtags = extraHashtags; self.youtubeTitle = youtubeTitle; self.platformCaptions = platformCaptions
    self.inherited = inherited; self.defaulted = defaulted
  }
}

public struct HashtagSet: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var category: String  // primary category (decision Q16): Amapiano, Afrobeats, DJ, …
  public var tags: [String]
  public var sort: Int
  public init(id: String, name: String, category: String, tags: [String], sort: Int) {
    self.id = id; self.name = name; self.category = category; self.tags = tags; self.sort = sort
  }
}

/// A YouTube title template (round 7): `{text}` = overlay text on one line, else the Title, else the raw tag.
public struct TitleTemplate: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var template: String
  public init(id: String, name: String, template: String) { self.id = id; self.name = name; self.template = template }
}

public struct CaptionTemplate: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var template: String
  public var sort: Int
  public init(id: String, name: String, template: String, sort: Int) {
    self.id = id; self.name = name; self.template = template; self.sort = sort
  }
}

public enum WeekState: String, Codable, Sendable { case draft, approved }

public struct PlanSlot: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var date: String  // YYYY-MM-DD local
  public var position: Int  // 0..posts_per_day-1
  public var videoId: String
  public var pinned: Bool
  public var weekStart: String
  /// Round 21: "Post at a set time". When set, every platform posts at exactly this moment instead of its slot time, the
  /// slot is always pinned, and it sits outside the posts-per-day cadence: `position` is `exactBase` or above, so it
  /// never takes one of the day's regular positions and the scheduler never fills, moves or re-lays it.
  public var exactAt: Date? = nil

  /// Positions from here up belong to set-time slots (the regular positions are 0..<postsPerDay).
  public static let exactBase = 100
  public var isExact: Bool { exactAt != nil }

  public init(id: String, date: String, position: Int, videoId: String, pinned: Bool, weekStart: String, exactAt: Date? = nil) {
    self.id = id
    self.date = date
    self.position = position
    self.videoId = videoId
    self.pinned = pinned
    self.weekStart = weekStart
    self.exactAt = exactAt
  }
}

public struct Week: Codable, Sendable, Hashable {
  public var weekStart: String
  public var state: WeekState
  public var approvedAt: Date?

  public init(weekStart: String, state: WeekState, approvedAt: Date?) {
    self.weekStart = weekStart
    self.state = state
    self.approvedAt = approvedAt
  }
}

public struct PostMetrics: Codable, Sendable, Hashable {
  public var views: Int?
  public var likes: Int?
  public var at: Date?
  public init(views: Int? = nil, likes: Int? = nil, at: Date? = nil) {
    self.views = views; self.likes = likes; self.at = at
  }
}

public struct PlatformPost: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var videoId: String
  public var platform: Platform
  public var versionNo: Int
  public var attemptNo: Int
  public var kind: PostKind
  public var planSlotId: String?
  public var scheduledAt: Date
  public var renderId: String?
  public var state: PostState
  public var publisher: String  // manual | postiz
  public var externalId: String?
  public var url: String?
  public var postedAt: Date?
  public var errorType: ErrorType?
  public var errorMessage: String?
  public var rawResponse: String?
  public var resolution: String?  // accepted | reuploaded | skipped (copyright handling)
  public var metrics: PostMetrics?
  public var createdAt: Date
  public var updatedAt: Date

  public init(id: String, videoId: String, platform: Platform, versionNo: Int, attemptNo: Int, kind: PostKind, planSlotId: String?, scheduledAt: Date, renderId: String?, state: PostState, publisher: String, externalId: String?, url: String?, postedAt: Date?, errorType: ErrorType?, errorMessage: String?, rawResponse: String?, resolution: String?, metrics: PostMetrics?, createdAt: Date, updatedAt: Date) {
    self.id = id
    self.videoId = videoId
    self.platform = platform
    self.versionNo = versionNo
    self.attemptNo = attemptNo
    self.kind = kind
    self.planSlotId = planSlotId
    self.scheduledAt = scheduledAt
    self.renderId = renderId
    self.state = state
    self.publisher = publisher
    self.externalId = externalId
    self.url = url
    self.postedAt = postedAt
    self.errorType = errorType
    self.errorMessage = errorMessage
    self.rawResponse = rawResponse
    self.resolution = resolution
    self.metrics = metrics
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct PostHistoryEntry: Codable, Sendable, Hashable, Identifiable {
  public var id: Int64
  public var postId: String
  public var at: Date
  public var fromState: String?
  public var toState: String
  public var note: String?
}

public enum RenderStatus: String, Codable, Sendable { case pending, rendering, done, failed }

public struct LoudnessInfo: Codable, Sendable, Hashable {
  public var inputI: Double, inputTP: Double, inputLRA: Double
  public var outputI: Double?, outputTP: Double?
  public init(inputI: Double, inputTP: Double, inputLRA: Double, outputI: Double? = nil, outputTP: Double? = nil) {
    self.inputI = inputI; self.inputTP = inputTP; self.inputLRA = inputLRA
    self.outputI = outputI; self.outputTP = outputTP
  }
}

public struct Render: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var videoId: String
  public var versionNo: Int
  public var editHash: String
  public var scope: String  // "all" or a Platform rawValue
  public var outputPath: String?
  public var coverPath: String?
  public var loudness: LoudnessInfo?
  public var duration: Double?
  public var size: Int64?
  public var status: RenderStatus
  public var error: String?
  public var createdAt: Date
  public var deletedAt: Date?
  /// Round 21: a photo post's render is one JPEG per photo. `outputPath` is the first; these are the rest, in order.
  /// nil for a video.
  public var morePaths: [String]? = nil

  /// Every output file, in posting order (one for a video).
  public var allPaths: [String] { (outputPath.map { [$0] } ?? []) + (morePaths ?? []) }

  public init(id: String, videoId: String, versionNo: Int, editHash: String, scope: String, outputPath: String?, coverPath: String?, loudness: LoudnessInfo?, duration: Double?, size: Int64?, status: RenderStatus, error: String?, createdAt: Date, deletedAt: Date?) {
    self.id = id
    self.videoId = videoId
    self.versionNo = versionNo
    self.editHash = editHash
    self.scope = scope
    self.outputPath = outputPath
    self.coverPath = coverPath
    self.loudness = loudness
    self.duration = duration
    self.size = size
    self.status = status
    self.error = error
    self.createdAt = createdAt
    self.deletedAt = deletedAt
  }
}

public struct EventRecord: Codable, Sendable, Hashable, Identifiable {
  public var id: Int64
  public var at: Date
  public var kind: String
  public var message: String
  public var videoId: String?
  public var postId: String?
}

public enum HeartbeatKind: String, Codable, Sendable { case start, tick, wake, sleep, stop }

public struct Heartbeat: Codable, Sendable, Hashable {
  public var at: Date
  public var kind: HeartbeatKind
}

public enum SortDirection: String, Codable, Sendable, CaseIterable {
  case worstFirst = "worst_first", bestFirst = "best_first"
  public var displayName: String { self == .worstFirst ? "Worst → best" : "Best → worst" }
}

public enum CleanupPolicy: Codable, Sendable, Hashable {
  case keep
  case deleteAfter(days: Int)
}

public struct Settings: Codable, Sendable, Hashable {
  public var postsPerDay: Int = 1
  public var sort: SortDirection = .worstFirst
  public var sortOverrides: [Platform: SortDirection] = [:]
  public var enabledPlatforms: Set<Platform> = Set(Platform.allCases)  // Q1
  public var pausedPlatforms: Set<Platform> = []
  public var paused: Bool = false
  public var slotMinutes: [Platform: Int] = Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0, $0.defaultSlotMinutes) })
  public var secondPostOffsetMinutes: Int = 180
  public var approvedRunwayAlertDays: Int = 3  // Q6
  public var totalRunwayAlertDays: Int = 14
  public var loudnessTarget: Double = -14
  public var truePeak: Double = -1
  public var lra: Double = 11
  public var renderHorizonDays: Int = 7
  public var videoBitrateKbps: Int = 12000
  public var weekStartsOn: Int = 2  // Calendar weekday, 2 = Monday (Q5)
  public var approvalReminderWeekday: Int = 1  // retired in round 13: nothing reads it (kept so stored rows decode as before)
  public var approvalReminderMinutes: Int = 18 * 60  // retired in round 13, same
  public var repostCooldownDays: Int = 14
  public var lateGraceHours: Double = 6
  public var retryStaggerHours: Double = 3
  public var avoidOverlap: Bool = false
  public var avoidOverlapDays: Int = 3
  public var cleanup: CleanupPolicy = .keep  // Q8
  public var allowEarlyPosting: Bool = true  // Q3
  public var timeZone: String = "America/New_York"
  /// New clip defaults (round 2 #10). Edits/versions store only overrides on top of these.
  public var defaults = NewClipDefaults()
  public var wakeBeforeFirstSlot: Bool = false
  public var limits: [Platform: PlatformLimits] = PlatformLimits.defaults
  /// Which revision of `PlatformLimits.defaults` the stored limits were written against. Rows saved before round 6
  /// have none (= 1); `Store.settings()` then moves only the limits that still equal the old defaults (round 6:
  /// TikTok caption 4000 → 2200, title — → 90; Instagram size 4 GB → 300 MB) and keeps every value Eric changed.
  public var limitsRevision: Int = PlatformLimits.revision
  /// Publishing (round 6): Manual or Postiz per platform, Postiz channels, test mode and per-platform options.
  public var publishing = PublishingSettings()
  /// Round 7: YouTube title templates (Settings → Captions & titles). New clip defaults picks the default one
  /// (`defaults.youtubeTitleTemplateId`); a clip can pick another in the editor.
  public var youtubeTitleTemplates: [TitleTemplate] = Defaults.youtubeTitleTemplates
  /// v0.8.3: what `{link}` fills in and what the Link chip adds.
  public var captionLink: String = Defaults.captionLink

  public init() {}

  /// The YouTube title template text for `id`: that template, else the default one, else the legacy single template.
  public func youtubeTitleTemplate(id: String?) -> String {
    if let id, let t = youtubeTitleTemplates.first(where: { $0.id == id }) { return t.template }
    if let t = youtubeTitleTemplates.first(where: { $0.id == defaults.youtubeTitleTemplateId }) { return t.template }
    return defaults.youtubeTitleTemplate
  }

  public var tz: TimeZone { TimeZone(identifier: timeZone) ?? .current }

  public func sortDirection(for p: Platform?) -> SortDirection {
    if let p, let o = sortOverrides[p] { return o }
    return sort
  }

  /// Platforms that receive regular posts (enabled). Paused platforms still get planned posts; the engine
  /// just doesn't advance them while paused.
  public var activePlatforms: [Platform] {
    Platform.allCases.filter { enabledPlatforms.contains($0) }.sorted { slot(for: $0) < slot(for: $1) }
  }

  public func slot(for p: Platform) -> Int { slotMinutes[p] ?? p.defaultSlotMinutes }
}

public struct PlatformLimits: Codable, Sendable, Hashable {
  public var maxDuration: Double
  public var maxBytes: Int64
  public var captionLimit: Int
  public var titleLimit: Int?
  /// v0.8.3: most hashtags a caption posts here (nil = no cap). The first ones in the caption stay (`Captions.capped`).
  public var maxHashtags: Int? = nil

  /// Bumped whenever `defaults` changes; see `Settings.limitsRevision` and `migrateStored(_:from:)`.
  public static let revision = 3

  /// Round 6 (docs/postiz.md §3, re-verified): TikTok caption 2200 (was 4000) and title 90; Instagram 300 MB (was 4 GB).
  public static let defaults: [Platform: PlatformLimits] = [
    .tiktok: .init(maxDuration: 600, maxBytes: 4_000_000_000, captionLimit: 2200, titleLimit: 90),
    .instagram: .init(maxDuration: 180, maxBytes: 300_000_000, captionLimit: 2200, titleLimit: nil, maxHashtags: 30),
    .facebook: .init(maxDuration: 90, maxBytes: 4_000_000_000, captionLimit: 2200, titleLimit: nil),
    .youtube: .init(maxDuration: 180, maxBytes: 4_000_000_000, captionLimit: 5000, titleLimit: 100, maxHashtags: 60),
    .threads: .init(maxDuration: 300, maxBytes: 1_000_000_000, captionLimit: 500, titleLimit: nil, maxHashtags: 1),
    .x: .init(maxDuration: 140, maxBytes: 512_000_000, captionLimit: 280, titleLimit: nil),
  ]

  /// Revision 1 values that revision 2 changed (platform → old value per field).
  static let revision1: [Platform: PlatformLimits] = [
    .tiktok: .init(maxDuration: 600, maxBytes: 4_000_000_000, captionLimit: 4000, titleLimit: nil),
    .instagram: .init(maxDuration: 180, maxBytes: 4_000_000_000, captionLimit: 2200, titleLimit: nil),
  ]

  /// Stored limits written against revision `from`, brought to the current defaults field by field: a field moves
  /// only when it still equals the old default (Eric's own edits stay).
  public static func migrateStored(_ stored: [Platform: PlatformLimits], from: Int) -> [Platform: PlatformLimits] {
    var out = stored
    if from < 3 {
      for (p, new) in defaults where out[p]?.maxHashtags == nil { out[p]?.maxHashtags = new.maxHashtags }
    }
    guard from < 2 else { return out }
    for (p, old) in revision1 {
      guard var cur = out[p], let new = defaults[p] else { continue }
      if cur.captionLimit == old.captionLimit { cur.captionLimit = new.captionLimit }
      if cur.maxBytes == old.maxBytes { cur.maxBytes = new.maxBytes }
      if cur.titleLimit == old.titleLimit { cur.titleLimit = new.titleLimit }
      if cur.maxDuration == old.maxDuration { cur.maxDuration = new.maxDuration }
      out[p] = cur
    }
    return out
  }
}
