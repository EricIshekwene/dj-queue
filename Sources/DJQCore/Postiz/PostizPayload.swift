import CryptoKit
import Foundation

/// A small JSON value with deterministic (sorted-key) encoding, for Postiz request bodies and content hashes.
public indirect enum JSONValue: Codable, Sendable, Hashable {
  case string(String), int(Int), double(Double), bool(Bool), null
  case array([JSONValue]), object([String: JSONValue])

  public func encode(to e: Encoder) throws {
    var c = e.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .bool(let b): try c.encode(b)
    case .null: try c.encodeNil()
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  public init(from d: Decoder) throws {
    let c = try d.singleValueContainer()
    if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let i = try? c.decode(Int.self) {
      self = .int(i)
    } else if let x = try? c.decode(Double.self) { self = .double(x) } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) { self = .array(a) } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public var data: Data { (try? JSONCoding.encoder.encode(self)) ?? Data("null".utf8) }
  public var string: String { String(decoding: data, as: UTF8.self) }
}

/// What DJ Queue's cover means on each platform through Postiz (docs/postiz.md §3), for the editor.
public enum CoverMeaning: String, Sendable, CaseIterable {
  /// YouTube: the cover JPG is uploaded as the video's thumbnail.
  case thumbnail
  /// Instagram, TikTok: the cover time picks the frame (`thumbnailTimestamp`).
  case coverFrame
  /// Facebook, Threads, X: not supported; the platform picks the frame.
  case platformPicks

  public static func of(_ p: Platform) -> CoverMeaning {
    switch p {
    case .youtube: .thumbnail
    case .instagram, .tiktok: .coverFrame
    case .facebook, .threads, .x: .platformPicks
    }
  }

  /// "Thumbnail" / "Cover frame" / "Platform picks".
  public var label: String {
    switch self {
    case .thumbnail: "Thumbnail"
    case .coverFrame: "Cover frame"
    case .platformPicks: "Platform picks"
    }
  }

  /// One sentence for a tooltip or the editor's cover section.
  public func detail(_ p: Platform) -> String {
    switch self {
    case .thumbnail:
      "\(p.displayName) gets the cover image as its thumbnail (with the text when the cover includes it). A channel that isn't phone-verified keeps YouTube's own frame."
    case .coverFrame:
      "\(p.displayName) uses the frame at the cover time as the video's cover. Inside the text window that frame shows the text."
    case .platformPicks:
      "\(p.displayName) picks its own cover frame; DJ Queue's cover isn't sent."
    }
  }

  /// Per platform, in posting order (for a compact editor list).
  public static var all: [(platform: Platform, meaning: CoverMeaning)] { Platform.allCases.sorted().map { ($0, of($0)) } }
}

/// A title as it goes out, and whether it had to be shortened (F1). Shown by the editor; never silent.
public struct TitleCheck: Sendable, Hashable, Codable {
  public var platform: Platform
  /// What is sent (≤ `limit`).
  public var title: String
  /// The title before shortening.
  public var full: String
  public var limit: Int
  public var isShortened: Bool { full.count > limit }
  /// "YouTube title is 112/100 characters — it goes out shortened: “…”" (nil when it fits).
  public var message: String? {
    guard isShortened else { return nil }
    return "\(platform == .youtube ? "YouTube" : platform.displayName) title is \(full.count)/\(limit) characters — it goes out shortened: “\(title)”"
  }
}

/// Everything about one Postiz post except the uploaded media ids, plus its content hash.
public struct PostizPostSpec: Sendable, Hashable {
  public var postId: String
  public var platform: Platform
  public var integrationId: String
  /// `settings.__type` (provider identifier).
  public var provider: String
  /// "schedule" | "draft".
  public var type: String
  public var content: String
  /// Provider settings without `__type` and without the uploaded thumbnail.
  public var settings: [String: JSONValue]
  public var thumbnailTimestampMs: Int?
  /// YouTube: upload the render's cover and send it as `settings.thumbnail`.
  public var uploadsCover: Bool
  public var renderId: String
  public var renderPath: String
  public var coverPath: String?
  public var scheduledAt: Date
  public var testMode: Bool
  public var contentHash: String
  /// Round 21: a photo post's files to upload and send, in order, already capped at the platform's `maxPhotos`
  /// (`renderPath` is the first). Empty for a video.
  public var photoPaths: [String] = []

  public var isPhotoPost: Bool { !photoPaths.isEmpty }

  /// The `POST /posts` body.
  public func body(date: Date, video: PostizMedia, cover: PostizMedia?) -> Data { body(date: date, media: [video], cover: cover) }

  /// The `POST /posts` body with every uploaded file: one for a video, one per photo for a photo post (the `image`
  /// array in posting order; only a video carries `thumbnailTimestamp`).
  public func body(date: Date, media list: [PostizMedia], cover: PostizMedia?) -> Data {
    let images: [JSONValue] = list.map { m in
      var media: [String: JSONValue] = ["id": .string(m.id), "path": .string(m.path)]
      if let t = thumbnailTimestampMs, !isPhotoPost { media["thumbnailTimestamp"] = .int(t) }
      return .object(media)
    }
    var s = settings
    s["__type"] = .string(provider)
    if uploadsCover, let cover { s["thumbnail"] = .object(["id": .string(cover.id), "path": .string(cover.path)]) }
    let item: JSONValue = .object([
      "integration": .object(["id": .string(integrationId)]),
      "value": .array([.object(["content": .string(content), "image": .array(images)])]),
      "settings": .object(s),
    ])
    return JSONValue.object([
      "type": .string(type), "date": .string(PostizClient.isoString(date)), "shortLink": .bool(false), "tags": .array([]),
      "posts": .array([item]),
    ]).data
  }
}

public enum PostizPayload {
  /// YouTube's hard title cap and TikTok's (docs/postiz.md §3); the payload never exceeds them.
  public static let youtubeTitleMax = 100
  public static let tiktokTitleMax = 90

  /// `text` cut to `max` characters with "…" (never longer than `max`).
  public static func clamp(_ text: String, _ max: Int) -> String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count > max else { return t }
    return String(t.prefix(Swift.max(1, max - 1))).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The YouTube and TikTok titles as they go out (TikTok only when the clip has a Title).
  public static func titleChecks(video v: Video, version rv: ResolvedVersion, settings: Settings) -> [TitleCheck] {
    var out: [TitleCheck] = []
    let ytLimit = min(youtubeTitleMax, settings.limits[.youtube]?.titleLimit ?? youtubeTitleMax)
    let ytFull = Captions.youtubeTitle(rv, video: v, limit: Int.max / 2, template: settings.defaults.youtubeTitleTemplate)
    out.append(TitleCheck(platform: .youtube, title: clamp(Captions.youtubeTitle(rv, video: v, settings: settings), youtubeTitleMax),
                          full: ytFull, limit: ytLimit))
    if let t = v.titleText {
      let lim = min(tiktokTitleMax, settings.limits[.tiktok]?.titleLimit ?? tiktokTitleMax)
      out.append(TitleCheck(platform: .tiktok, title: clamp(t, lim), full: t, limit: lim))
    }
    return out
  }

  /// Cover time in ms from the start of the posted file (the render starts at its trim start).
  static func coverMs(edit: ResolvedEdit, render: Render, platform: Platform) -> Int {
    let scope: Platform? = render.scope == "all" ? nil : Platform(rawValue: render.scope)
    let start = edit.trim(platform: scope ?? (edit.platformTrims[platform] != nil ? platform : nil)).start
    var ms = Int(((edit.coverTime - start) * 1000).rounded())
    if let d = render.duration, d > 0 { ms = min(ms, Int(d * 1000) - 1) }
    return max(0, ms)
  }

  struct HashInput: Codable {
    var platform: String, integrationId: String, provider: String, type: String, content: String
    var settings: [String: JSONValue], thumbnailTimestampMs: Int?, uploadsCover: Bool
    var renderId: String, coverPath: String?, scheduledAt: Double, testMode: Bool
    /// Round 21: how many photos go out (nil, and absent from the JSON, for a video: its hash can't change).
    var photos: Int? = nil
  }

  /// A photo post's spec (round 21, D8–D11, D19): the first `maxPhotos` files of its render, feed-post settings and no
  /// cover or thumbnail time. Throws for a platform that takes no photos (YouTube Shorts): such a post is never planned.
  public static func photoSpec(post p: PlatformPost, video v: Video, render r: Render, version rv: ResolvedVersion,
                               settings: Settings, sessionName: String, sets: [HashtagSet], templates: [CaptionTemplate],
                               integrationId: String, provider: String? = nil) throws -> PostizPostSpec {
    guard p.platform.supportsPhotos else { throw EngineError(PhotoRules.youtubeReason) }
    let files = PhotoRules.files(r, platform: p.platform)
    guard !files.isEmpty else { throw EngineError("No finished render for \(v.tag) v\(p.versionNo) yet") }
    let pub = settings.publishing
    let test = pub.testMode
    let caption = Captions.caption(for: p.platform, version: rv, video: v, sessionName: sessionName, sets: sets,
                                   templates: templates, settings: settings)
    var s: [String: JSONValue] = [:]
    var type = "schedule"
    switch p.platform {
    case .instagram:
      s["post_type"] = .string("post")  // a feed post, a carousel when there are several (D11); trial reels don't apply
      if test { type = "draft" }
    case .tiktok:
      let method: TikTokPostingMethod = test ? .upload : pub.tiktok.method
      s["content_posting_method"] = .string(method.rawValue)
      s["privacy_level"] = .string("PUBLIC_TO_EVERYONE")
      s["duet"] = .bool(pub.tiktok.duet)
      s["stitch"] = .bool(pub.tiktok.stitch)
      s["comment"] = .bool(pub.tiktok.comment)
      s["autoAddMusic"] = .string("no")  // D10: never a library track on a DJ's post
      s["brand_content_toggle"] = .bool(pub.tiktok.brandContent)
      s["brand_organic_toggle"] = .bool(pub.tiktok.brandOrganic)
      if let t = v.titleText {
        s["title"] = .string(clamp(t, min(tiktokTitleMax, settings.limits[.tiktok]?.titleLimit ?? tiktokTitleMax)))
      }
    case .facebook:
      s["post_type"] = .string("post")
      if test { type = "draft" }
    case .threads:
      if test { type = "draft" }
    case .x:
      s["who_can_reply_post"] = .string(pub.x.whoCanReply.rawValue)
      s["post_type"] = .string("post")
      if test { type = "draft" }
    case .youtube:
      throw EngineError(PhotoRules.youtubeReason)
    }
    let prov = provider ?? PostizPlatforms.provider(p.platform)
    let h = HashInput(platform: p.platform.rawValue, integrationId: integrationId, provider: prov, type: type, content: caption,
                      settings: s, thumbnailTimestampMs: nil, uploadsCover: false, renderId: r.id, coverPath: nil,
                      scheduledAt: p.scheduledAt.timeIntervalSince1970, testMode: test, photos: files.count)
    let hash = SHA256.hash(data: (try? JSONCoding.encoder.encode(h)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    var spec = PostizPostSpec(postId: p.id, platform: p.platform, integrationId: integrationId, provider: prov, type: type,
                              content: caption, settings: s, thumbnailTimestampMs: nil, uploadsCover: false, renderId: r.id,
                              renderPath: files[0], coverPath: nil, scheduledAt: p.scheduledAt, testMode: test,
                              contentHash: String(hash.prefix(32)))
    spec.photoPaths = files
    return spec
  }

  /// Builds the spec from values already read (pure). For a photo post this is `photoSpec`, and it throws where that
  /// does (YouTube): a photo post never gets a video payload.
  public static func spec(post p: PlatformPost, video v: Video, render r: Render, version rv: ResolvedVersion,
                          edit re: ResolvedEdit, settings: Settings, sessionName: String, sets: [HashtagSet],
                          templates: [CaptionTemplate], integrationId: String, provider: String? = nil) throws -> PostizPostSpec {
    if v.isPhoto {
      return try photoSpec(post: p, video: v, render: r, version: rv, settings: settings, sessionName: sessionName,
                           sets: sets, templates: templates, integrationId: integrationId, provider: provider)
    }
    let pub = settings.publishing
    let test = pub.testMode
    let caption = Captions.caption(for: p.platform, version: rv, video: v, sessionName: sessionName, sets: sets,
                                   templates: templates, settings: settings)
    var s: [String: JSONValue] = [:]
    var type = "schedule"
    var thumb: Int?
    var uploadsCover = false
    switch p.platform {
    case .instagram:
      s["post_type"] = .string(pub.instagram.postType)
      s["is_trial_reel"] = .bool(pub.instagram.trialReel)
      thumb = coverMs(edit: re, render: r, platform: p.platform)
      if test { type = "draft" }
    case .tiktok:
      let method: TikTokPostingMethod = test ? .upload : pub.tiktok.method
      s["content_posting_method"] = .string(method.rawValue)
      s["privacy_level"] = .string("PUBLIC_TO_EVERYONE")
      s["duet"] = .bool(pub.tiktok.duet)
      s["stitch"] = .bool(pub.tiktok.stitch)
      s["comment"] = .bool(pub.tiktok.comment)
      s["autoAddMusic"] = .string("no")
      s["brand_content_toggle"] = .bool(pub.tiktok.brandContent)
      s["brand_organic_toggle"] = .bool(pub.tiktok.brandOrganic)
      s["video_made_with_ai"] = .bool(pub.tiktok.madeWithAI)
      if let t = v.titleText {
        s["title"] = .string(clamp(t, min(tiktokTitleMax, settings.limits[.tiktok]?.titleLimit ?? tiktokTitleMax)))
      }
      if method == .directPost { thumb = coverMs(edit: re, render: r, platform: p.platform) }
    case .facebook:
      s["post_type"] = .string("post")
      if let t = v.titleText { s["title"] = .string(t) }
      if test { type = "draft" }
    case .youtube:
      s["title"] = .string(clamp(Captions.youtubeTitle(rv, video: v, settings: settings), youtubeTitleMax))
      s["type"] = .string(test ? YouTubeVisibility.unlisted.rawValue : pub.youtube.visibility.rawValue)
      s["selfDeclaredMadeForKids"] = .string(pub.youtube.madeForKids ? "yes" : "no")
      let tags = Captions.hashtags(rv, sets: sets).map { String($0.drop { $0 == "#" }) }.filter { !$0.isEmpty }
      s["tags"] = .array(tags.map { .object(["value": .string($0), "label": .string($0)]) })
      uploadsCover = r.coverPath != nil
    case .threads:
      if test { type = "draft" }
    case .x:
      s["who_can_reply_post"] = .string(pub.x.whoCanReply.rawValue)
      s["post_type"] = .string("post")
      if test { type = "draft" }
    }
    let prov = provider ?? PostizPlatforms.provider(p.platform)
    let h = HashInput(platform: p.platform.rawValue, integrationId: integrationId, provider: prov, type: type, content: caption,
                      settings: s, thumbnailTimestampMs: thumb, uploadsCover: uploadsCover, renderId: r.id,
                      coverPath: uploadsCover ? r.coverPath : nil, scheduledAt: p.scheduledAt.timeIntervalSince1970, testMode: test)
    let hash = SHA256.hash(data: (try? JSONCoding.encoder.encode(h)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    return PostizPostSpec(postId: p.id, platform: p.platform, integrationId: integrationId, provider: prov, type: type,
                          content: caption, settings: s, thumbnailTimestampMs: thumb, uploadsCover: uploadsCover,
                          renderId: r.id, renderPath: r.outputPath ?? "", coverPath: r.coverPath, scheduledAt: p.scheduledAt,
                          testMode: test, contentHash: String(hash.prefix(32)))
  }

  /// Reads the post's video, render, version and edit and builds its spec. Throws a readable reason when something
  /// is missing (no render yet, no such version, …).
  public static func spec(store: Store, post p: PlatformPost, settings: Settings, integrationId: String,
                          provider: String? = nil) throws -> PostizPostSpec {
    guard let v = try store.video(id: p.videoId) else { throw EngineError("No video \(p.videoId)") }
    if v.isPhoto, !p.platform.supportsPhotos { throw EngineError(PhotoRules.youtubeReason) }
    guard let rid = p.renderId, let r = try store.render(id: rid), r.status == .done, r.deletedAt == nil,
          let out = r.outputPath, FileManager.default.fileExists(atPath: out),
          r.allPaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
      throw EngineError("No finished render for \(v.tag) v\(p.versionNo) yet")
    }
    guard let rv = try store.resolvedVersion(videoId: v.id, number: p.versionNo, settings: settings) else {
      throw EngineError("\(v.tag) has no v\(p.versionNo)")
    }
    // Round 30: the post's version's trim (the cover time counts from its render's start).
    let re = EditResolver.resolve(try store.edit(videoId: v.id), video: v, defaults: settings.defaults,
                                  version: store.rawVersion(videoId: v.id, number: p.versionNo))
    return try spec(post: p, video: v, render: r, version: rv, edit: re, settings: settings, sessionName: try store.sessionName(for: v),
                sets: try store.hashtagSets(), templates: try store.captionTemplates(), integrationId: integrationId,
                provider: provider)
  }
}

extension Validation {
  /// Title notices for the editor (F1), not readiness blockers: the YouTube title (and TikTok's, from the Title) as it
  /// goes out through Postiz, with a message when it had to be shortened. An explicit YouTube title over the limit
  /// still blocks through `issues` (`.titleTooLong`).
  public static func titleChecks(video v: Video, store: Store, versionNo: Int = 1) throws -> [TitleCheck] {
    let settings = try store.settings()
    guard let rv = try store.resolvedVersion(videoId: v.id, number: versionNo, settings: settings) else { return [] }
    return PostizPayload.titleChecks(video: v, version: rv, settings: settings)
  }
}
