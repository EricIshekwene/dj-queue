import Foundation

/// Why a video isn't `ready` yet, and per-platform limit problems (spec §6 Validation, §7 platform checks).
public struct ValidationIssue: Sendable, Hashable, Identifiable, Codable {
  public enum Kind: String, Sendable, Codable, CaseIterable {
    case noCrop, noText, noCaption, tooLong, tooLarge, missingFile, noTitle, captionTooLong, titleTooLong, corrupt
    /// Sent back to Edit from the Queue (`Video.heldInEdit`, "Back to Edit"); "Send to Queue" clears it.
    case heldInEdit
    /// Round 21: a photo post with no photos left (its last one can't be removed, so this is a broken row).
    case noPhotos
    /// Round 21 (D20): a photo post in a shape a posting platform refuses (9:16 on Instagram).
    case photoShape
  }
  public var kind: Kind
  public var platform: Platform?
  public var message: String
  /// For length issues: the current length (characters, or seconds for `.tooLong`) and the platform limit,
  /// so the UI can offer explicit actions ("Drop hashtags for X", "Write an X caption", trim).
  public var count: Double?
  public var limit: Double?
  /// For `.captionTooLong`: length of the same caption without hashtags (nil when it has none). When it fits,
  /// "Drop hashtags for <platform>" (`Captions.withoutHashtags`) fixes the issue.
  public var countWithoutHashtags: Int?
  public var id: String { "\(kind.rawValue)-\(platform?.rawValue ?? "all")" }

  public init(kind: Kind, platform: Platform?, message: String, count: Double? = nil, limit: Double? = nil,
              countWithoutHashtags: Int? = nil) {
    self.kind = kind; self.platform = platform; self.message = message; self.count = count; self.limit = limit
    self.countWithoutHashtags = countWithoutHashtags
  }
}

/// The editor inspector section an issue is fixed in (round 7, C1).
public enum IssueSection: String, Sendable, CaseIterable {
  case title, frame, text, caption, cover, platforms
  /// Round 21: a photo post's photos strip (it takes the Cover section's place, D15).
  case photos
}

extension ValidationIssue.Kind {
  /// Where the editor sends Eric to fix it. nil = no inspector section: a missing file or unreadable edit is fixed in
  /// Health / Doctor (the header says "File missing"), a held clip with the stage control ("Send to Queue").
  /// Exhaustive on purpose — a new kind must say where it goes.
  public var editorSection: IssueSection? {
    switch self {
    case .noCrop, .photoShape: .frame
    case .noText: .text
    case .noTitle: .title
    case .tooLong, .tooLarge: .platforms
    case .noCaption, .captionTooLong, .titleTooLong: .caption
    case .noPhotos: .photos
    case .missingFile, .corrupt, .heldInEdit: nil
    }
  }
}

/// Settings, caption templates, hashtag sets and session names read once for many `Validation.issues` calls (the
/// stage revalidation pass checks every Edit/Queue clip each tick).
public struct ValidationContext: Sendable {
  public var settings: Settings
  public var templates: [CaptionTemplate]
  public var sets: [HashtagSet]
  public var sessionNames: [String: String]

  public static func load(_ store: Store) throws -> ValidationContext {
    ValidationContext(settings: try store.settings(), templates: try store.captionTemplates(), sets: try store.hashtagSets(),
                      sessionNames: Dictionary(try store.sessions().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
  }
}

public enum Validation {
  /// Readiness rules (round 2): the crop is confirmed, the resolved text is set or "No text" (defaults count),
  /// a caption resolves (written, or an existing template), and every posting platform's limits are met.
  /// A photo post (round 21) needs its photos, a caption that resolves and fits; no crop, text or length rule.
  /// `context` (optional) saves re-reading settings, templates, hashtag sets and session names per clip.
  public static func issues(video v: Video, store: Store, context: ValidationContext? = nil) throws -> [ValidationIssue] {
    var out: [ValidationIssue] = []
    if v.missing { out.append(.init(kind: .missingFile, platform: nil, message: "File missing")) }
    guard v.type == .short else { return out }
    if try store.isHeld(v) {
      out.append(.init(kind: .heldInEdit, platform: nil, message: "Sent back from Queue — send it to the Queue when it's done"))
    }
    let settings = try context?.settings ?? store.settings()
    // Unreadable edit/version rows make the video not ready (reported here and by the Doctor);
    // they must not abort intake or the engine tick.
    guard let edit = try? store.edit(videoId: v.id), (try? store.versions(videoId: v.id)) != nil,
          let r = try? store.resolvedVersion(videoId: v.id, number: 1, settings: settings) else {
      out.append(.init(kind: .corrupt, platform: nil, message: "Saved edit can't be read — see Doctor"))
      return out
    }
    let re = EditResolver.resolve(edit, video: v, defaults: settings.defaults)
    if let photos = v.photos {
      // Round 21: the centred crop is always valid (Send to Queue confirms it) and a photo with no text is fine, so
      // neither blocks. YouTube is never a posting platform here (`re` skips it), so its title isn't checked.
      if photos.isEmpty { out.append(.init(kind: .noPhotos, platform: nil, message: "Add a photo")) }
      // D20: a shape a posting platform refuses is said here, before the Queue, never as a failure at publish time.
      for p in settings.activePlatforms where !re.isSkipped(p) {
        if let why = PhotoRules.shapeProblem(re.aspect, platform: p) { out.append(.init(kind: .photoShape, platform: p, message: why)) }
      }
    } else {
      // (`re.cropConfirmed` is "the edit has a crop", and also true for a made video that shows the whole photo, D12.)
      if !re.cropConfirmed { out.append(.init(kind: .noCrop, platform: nil, message: "Confirm the crop")) }
    }
    if !v.isPhoto, !r.hasDrawnText && !r.noText {
      out.append(.init(kind: .noText, platform: nil,
                       message: v.titleText == nil && r.isDefault("text") ? "Add text (no title yet)" : "Add text or choose No text"))
    }
    let templates = try context?.templates ?? store.captionTemplates()
    let posting = settings.activePlatforms.filter { !re.isSkipped($0) }
    if r.caption.isEmpty {
      let missing = Set(posting.map { Captions.templateId(for: $0, version: r, settings: settings) })
        .filter { id in !templates.contains { $0.id == id } }
      if !missing.isEmpty {
        out.append(.init(kind: .noCaption, platform: nil,
                         message: "Caption template \(missing.sorted().joined(separator: ", ")) doesn't exist — choose a template or write a caption"))
      }
    }
    out += platformIssues(video: v, resolved: re, settings: settings)
    let session = try context.map { $0.sessionNames[v.sessionId] ?? "" } ?? store.session(id: v.sessionId)?.name ?? ""
    let sets = try context?.sets ?? store.hashtagSets()
    for p in posting {
      let lim = settings.limits[p]?.captionLimit ?? 2200
      let c = Captions.caption(for: p, version: r, video: v, sessionName: session, sets: sets, templates: templates,
                               settings: settings)
      if c.count > lim {
        // Round 7: from the caption text itself (typed tags count), unless the platform has its own caption.
        let hasTags = Captions.hasTags(c) && (r.platformCaptions[p] ?? "").isEmpty
        let bare = hasTags
          ? Captions.withoutHashtags(for: p, version: r, video: v, sessionName: session, templates: templates, settings: settings, sets: sets).count
          : nil
        out.append(.init(kind: .captionTooLong, platform: p, message: "Caption too long for \(p.displayName) (\(c.count)/\(lim))",
                         count: Double(c.count), limit: Double(lim), countWithoutHashtags: bare))
      }
    }
    if posting.contains(.youtube) {
      let lim = settings.limits[.youtube]?.titleLimit ?? 100
      let t = Captions.youtubeTitle(r, video: v, settings: settings)
      if t.count > lim {
        out.append(.init(kind: .titleTooLong, platform: .youtube, message: "YouTube title too long (\(t.count)/\(lim))",
                         count: Double(t.count), limit: Double(lim)))
      }
      // Round 23 (D10): a video made from a photo has no marker tag to fall back on, so with no Title, no text on it
      // and no YouTube title typed, YouTube would get no name for it.
      if v.isStill, v.titleText == nil, r.youtubeTitle.isEmpty, !r.hasText {
        out.append(.init(kind: .noTitle, platform: .youtube, message: StillVideo.youtubeTitleIssue))
      }
    }
    return out
  }

  /// Length checks per posting platform (resolved trim: markers by default; per-platform trims respected).
  public static func platformIssues(video v: Video, resolved re: ResolvedEdit, settings: Settings) -> [ValidationIssue] {
    var out: [ValidationIssue] = []
    guard !v.isPhoto else { return out }  // a photo post has no length
    for p in settings.activePlatforms where !re.isSkipped(p) {
      guard let lim = settings.limits[p] else { continue }
      let d = re.trim(platform: p).duration
      if d > lim.maxDuration + 0.05 {
        out.append(.init(kind: .tooLong, platform: p,
                         message: "Too long for \(p.displayName) (\(fmt(d)) > \(fmt(lim.maxDuration)))",
                         count: d, limit: lim.maxDuration))
      }
    }
    return out
  }

  /// Convenience: resolves the edit with the settings' defaults.
  public static func platformIssues(video v: Video, edit: Edit, settings: Settings) -> [ValidationIssue] {
    platformIssues(video: v, resolved: EditResolver.resolve(edit, video: v, defaults: settings.defaults), settings: settings)
  }

  public static func isReady(video v: Video, store: Store, context: ValidationContext? = nil) throws -> Bool {
    try issues(video: v, store: store, context: context).isEmpty
  }

  public static func fmt(_ s: Double) -> String {
    let t = Int(s.rounded())
    return "\(t / 60):" + String(format: "%02d", t % 60)
  }
}
