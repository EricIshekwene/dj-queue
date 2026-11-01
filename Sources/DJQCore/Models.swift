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

  public var displayName: String {
    switch self {
    case .needsEdit: "Needs edit"
    case .ready: "Ready"
    case .planned: "Planned"
    case .posting: "Posting"
    case .posted: "Posted"
    case .partial: "Partial"
    case .excluded: "Excluded"
    case .missingFile: "Missing"
    }
  }
}

public enum PostState: String, Codable, Sendable, CaseIterable {
  case planned, rendering, rendered, due, posted, failed
  case copyrightBlocked = "copyright_blocked"
  case copyrightMuted = "copyright_muted"
  case removed, skipped, overdue

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
    case .rendered: "Ready"
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

  /// The marker tag (the part of the name after the session), e.g. "yayo x johnny".
  public var tag: String { tags.first ?? name }

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

/// One per video (spec §3 Edit).
public struct Edit: Codable, Sendable, Hashable {
  public var aspect: Aspect = .r9x16
  public var crop: CropRect?
  public var trimIn: Double?
  public var trimOut: Double?
  public var coverTime: Double?  // nil = first frame of trim
  public var coverIncludesText: Bool = true  // decision Q18
  public var platformTrims: [Platform: TrimRange] = [:]
  public var skippedPlatforms: Set<Platform> = []

  public init() {}

  public func trim(duration: Double, platform: Platform? = nil) -> TrimRange {
    if let p = platform, let t = platformTrims[p] { return t }
    return TrimRange(start: trimIn ?? 0, end: trimOut ?? duration)
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
  public var caption: String?
  public var captionTemplateId: String?
  public var hashtagSetIds: [String]?
  public var extraHashtags: [String]?
  public var youtubeTitle: String?
  public var platformCaptions: [Platform: String]?

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
  /// Field names that came from an earlier version (shown faded in the editor).
  public var inherited: Set<String>

  public var hasText: Bool { !noText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
}

public struct Week: Codable, Sendable, Hashable {
  public var weekStart: String
  public var state: WeekState
  public var approvedAt: Date?
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
  public var approvalReminderWeekday: Int = 1  // Sunday
  public var approvalReminderMinutes: Int = 18 * 60
  public var repostCooldownDays: Int = 14
  public var lateGraceHours: Double = 6
  public var retryStaggerHours: Double = 3
  public var avoidOverlap: Bool = false
  public var avoidOverlapDays: Int = 3
  public var cleanup: CleanupPolicy = .keep  // Q8
  public var allowEarlyPosting: Bool = true  // Q3
  public var timeZone: String = "America/New_York"
  public var defaultStyle: TextStyle = .box  // Q11
  public var defaultTextSize: Double = 64  // Q13 (medium)
  public var defaultPosY: Double = 0.5  // Q12 (centre)
  public var defaultCaptionTemplateId: String = "set-link"
  public var defaultHashtagSetIds: [String] = ["amapiano", "dj"]
  public var wakeBeforeFirstSlot: Bool = false
  public var limits: [Platform: PlatformLimits] = PlatformLimits.defaults

  public init() {}

  public var tz: TimeZone { TimeZone(identifier: timeZone) ?? .current }

  public func sortDirection(for p: Platform?) -> SortDirection {
    if let p, let o = sortOverrides[p] { return o }
    return sort
  }

  /// Platforms that receive regular posts (enabled and not paused).
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

  public static let defaults: [Platform: PlatformLimits] = [
    .tiktok: .init(maxDuration: 600, maxBytes: 4_000_000_000, captionLimit: 4000, titleLimit: nil),
    .instagram: .init(maxDuration: 180, maxBytes: 4_000_000_000, captionLimit: 2200, titleLimit: nil),
    .facebook: .init(maxDuration: 90, maxBytes: 4_000_000_000, captionLimit: 2200, titleLimit: nil),
    .youtube: .init(maxDuration: 180, maxBytes: 4_000_000_000, captionLimit: 5000, titleLimit: 100),
    .threads: .init(maxDuration: 300, maxBytes: 1_000_000_000, captionLimit: 500, titleLimit: nil),
    .x: .init(maxDuration: 140, maxBytes: 512_000_000, captionLimit: 280, titleLimit: nil),
  ]
}
