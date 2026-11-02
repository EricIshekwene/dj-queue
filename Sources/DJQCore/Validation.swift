import Foundation

/// Why a video isn't `ready` yet, and per-platform limit problems (spec §6 Validation, §7 platform checks).
public struct ValidationIssue: Sendable, Hashable, Identifiable, Codable {
  public enum Kind: String, Sendable, Codable {
    case noCrop, noText, noCaption, tooLong, tooLarge, missingFile, noTitle, captionTooLong, titleTooLong, corrupt
    /// Sent back to Edit from the Queue (`Video.heldInEdit`); "Send to queue" clears it.
    case heldInEdit
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

public enum Validation {
  /// Readiness rules (round 2): the crop is confirmed, the resolved text is set or "No text" (defaults count),
  /// a caption resolves (written, or an existing template), and every posting platform's limits are met.
  public static func issues(video v: Video, store: Store) throws -> [ValidationIssue] {
    var out: [ValidationIssue] = []
    if v.missing { out.append(.init(kind: .missingFile, platform: nil, message: "File missing")) }
    guard v.type == .short else { return out }
    if v.heldInEdit {
      out.append(.init(kind: .heldInEdit, platform: nil, message: "Sent back from Queue — Send to queue when it's ready"))
    }
    let settings = try store.settings()
    // Unreadable edit/version rows make the video not ready (reported here and by the Doctor);
    // they must not abort intake or the engine tick.
    guard let edit = try? store.edit(videoId: v.id), (try? store.versions(videoId: v.id)) != nil,
          let r = try? store.resolvedVersion(videoId: v.id, number: 1, settings: settings) else {
      out.append(.init(kind: .corrupt, platform: nil, message: "Saved edit can't be read — see Doctor"))
      return out
    }
    let re = EditResolver.resolve(edit, video: v, defaults: settings.defaults)
    if edit.crop == nil { out.append(.init(kind: .noCrop, platform: nil, message: "Confirm the crop")) }
    if !r.hasText && !r.noText {
      out.append(.init(kind: .noText, platform: nil,
                       message: v.titleText == nil && r.isDefault("text") ? "Add text (no title yet)" : "Add text or choose No text"))
    }
    let templates = try store.captionTemplates()
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
    let session = try store.session(id: v.sessionId)?.name ?? ""
    let sets = try store.hashtagSets()
    for p in posting {
      let lim = settings.limits[p]?.captionLimit ?? 2200
      let c = Captions.caption(for: p, version: r, video: v, sessionName: session, sets: sets, templates: templates,
                               settings: settings)
      if c.count > lim {
        let hasTags = !Captions.hashtags(r, sets: sets).isEmpty && (r.platformCaptions[p] ?? "").isEmpty
        let bare = hasTags
          ? Captions.withoutHashtags(for: p, version: r, video: v, sessionName: session, templates: templates, settings: settings).count
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
    }
    return out
  }

  /// Length checks per posting platform (resolved trim: markers by default; per-platform trims respected).
  public static func platformIssues(video v: Video, resolved re: ResolvedEdit, settings: Settings) -> [ValidationIssue] {
    var out: [ValidationIssue] = []
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

  public static func isReady(video v: Video, store: Store) throws -> Bool {
    try issues(video: v, store: store).isEmpty
  }

  public static func fmt(_ s: Double) -> String {
    let t = Int(s.rounded())
    return "\(t / 60):" + String(format: "%02d", t % 60)
  }
}
