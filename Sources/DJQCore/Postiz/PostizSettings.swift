import Foundation

// Round 6 (docs/postiz.md): how each platform publishes. Manual stays the default and the fallback, forever.

/// Who delivers a platform's posts.
public enum PublisherKind: String, Codable, Sendable, CaseIterable {
  case manual, postiz
  public var displayName: String { self == .manual ? "Manual" : "Postiz" }
}

/// TikTok's `content_posting_method`: `directPost` publishes; `upload` lands in the TikTok app inbox as a draft.
public enum TikTokPostingMethod: String, Codable, Sendable, CaseIterable {
  case directPost = "DIRECT_POST", upload = "UPLOAD"
  public var displayName: String { self == .directPost ? "Post directly" : "Send to the TikTok inbox" }
}

public struct TikTokOptions: Codable, Sendable, Hashable {
  public var method: TikTokPostingMethod = .directPost
  public var duet = true
  public var stitch = true
  public var comment = true
  /// "Your brand" (brand_organic_toggle).
  public var brandOrganic = false
  /// "Branded content" (brand_content_toggle).
  public var brandContent = false
  /// "Made with AI" label (video_made_with_ai).
  public var madeWithAI = false
  public init() {}

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    let x = TikTokOptions.blank
    method = (try? c.decodeIfPresent(TikTokPostingMethod.self, forKey: .method)) ?? x.method
    duet = (try? c.decodeIfPresent(Bool.self, forKey: .duet)) ?? x.duet
    stitch = (try? c.decodeIfPresent(Bool.self, forKey: .stitch)) ?? x.stitch
    comment = (try? c.decodeIfPresent(Bool.self, forKey: .comment)) ?? x.comment
    brandOrganic = (try? c.decodeIfPresent(Bool.self, forKey: .brandOrganic)) ?? x.brandOrganic
    brandContent = (try? c.decodeIfPresent(Bool.self, forKey: .brandContent)) ?? x.brandContent
    madeWithAI = (try? c.decodeIfPresent(Bool.self, forKey: .madeWithAI)) ?? x.madeWithAI
  }
  static let blank = TikTokOptions()
}

public enum YouTubeVisibility: String, Codable, Sendable, CaseIterable {
  case `public`, unlisted, `private`
  public var displayName: String { rawValue.capitalized }
}

public struct YouTubeOptions: Codable, Sendable, Hashable {
  public var visibility: YouTubeVisibility = .public
  /// `selfDeclaredMadeForKids`; DJ Lovd's videos aren't made for kids.
  public var madeForKids = false
  public init() {}

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    visibility = (try? c.decodeIfPresent(YouTubeVisibility.self, forKey: .visibility)) ?? .public
    madeForKids = (try? c.decodeIfPresent(Bool.self, forKey: .madeForKids)) ?? false
  }
}

public struct InstagramOptions: Codable, Sendable, Hashable {
  /// Postiz `post_type`: "post" (a single video becomes a Reel) or "story".
  public var postType = "post"
  public var trialReel = false
  public init() {}

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    postType = (try? c.decodeIfPresent(String.self, forKey: .postType)) ?? "post"
    trialReel = (try? c.decodeIfPresent(Bool.self, forKey: .trialReel)) ?? false
  }
}

public enum XWhoCanReply: String, Codable, Sendable, CaseIterable {
  case everyone, following, mentionedUsers, subscribers, verified
  public var displayName: String {
    switch self {
    case .everyone: "Everyone"
    case .following: "Accounts you follow"
    case .mentionedUsers: "Only accounts you mention"
    case .subscribers: "Subscribers"
    case .verified: "Verified accounts"
    }
  }
}

public struct XOptions: Codable, Sendable, Hashable {
  public var whoCanReply: XWhoCanReply = .everyone
  public init() {}

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    whoCanReply = (try? c.decodeIfPresent(XWhoCanReply.self, forKey: .whoCanReply)) ?? .everyone
  }
}

/// Settings → Publishing. Lives inside `Settings` (the `settings` kv row). Channel ids are stored here, in the local
/// database only; the API key is in the Keychain (`PostizKeyStore`), never here.
///
/// Decoding never fails: every field is read on its own and a missing or unreadable one keeps its default, so an
/// older or hand-edited row can't send Settings back to defaults.
public struct PublishingSettings: Codable, Sendable, Hashable {
  /// Publisher per platform; a platform missing here is Manual.
  public var publishers: [Platform: PublisherKind] = [:]
  /// Postiz integration (channel) id per platform.
  public var channels: [Platform: String] = [:]
  /// "Test run" (docs/postiz.md §6): TikTok → inbox, YouTube → unlisted, the others → Postiz drafts.
  public var testMode = false
  public var tiktok = TikTokOptions()
  public var youtube = YouTubeOptions()
  public var instagram = InstagramOptions()
  public var x = XOptions()
  /// Postiz public API base (cloud by default; a self-hosted Postiz is `https://<domain>/api/public/v1`).
  public var apiBase = PublishingSettings.cloudAPIBase
  /// Calls per rolling hour shared by every DJ Queue process (docs/postiz.md §1).
  public var hourlyBudget = 25

  public static let cloudAPIBase = "https://api.postiz.com/public/v1"
  /// Below this the priority reserves would starve creates or analytics.
  public static let minimumBudget = 10

  public init() {}

  public func publisher(for p: Platform) -> PublisherKind { publishers[p] ?? .manual }

  /// Postiz's own web app, where a channel is reconnected: the cloud app for the cloud API, else the self-hosted
  /// Postiz's own address (its API base without the path).
  public var webURL: URL {
    guard let u = URL(string: apiBase), let host = u.host?.lowercased() else { return URL(string: "https://platform.postiz.com")! }
    if host == "api.postiz.com" { return URL(string: "https://platform.postiz.com")! }
    var c = URLComponents()
    c.scheme = u.scheme ?? "https"
    c.host = u.host
    c.port = u.port
    return c.url ?? URL(string: "https://platform.postiz.com")!
  }

  /// Platforms set to Postiz, in posting order.
  public var postizPlatforms: [Platform] { Platform.allCases.filter { publisher(for: $0) == .postiz }.sorted() }

  enum CodingKeys: String, CodingKey {
    case publishers, channels, testMode, tiktok, youtube, instagram, x, apiBase, hourlyBudget
  }

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    let pubs = (try? c.decodeIfPresent([String: String].self, forKey: .publishers)) ?? [:]
    publishers = Dictionary(uniqueKeysWithValues: pubs.compactMap { k, v in
      guard let p = Platform(rawValue: k), let kind = PublisherKind(rawValue: v) else { return nil }
      return (p, kind)
    })
    let ch = (try? c.decodeIfPresent([String: String].self, forKey: .channels)) ?? [:]
    channels = Dictionary(uniqueKeysWithValues: ch.compactMap { k, v in
      Platform(rawValue: k).flatMap { v.isEmpty ? nil : ($0, v) }
    })
    testMode = (try? c.decodeIfPresent(Bool.self, forKey: .testMode)) ?? false
    tiktok = (try? c.decodeIfPresent(TikTokOptions.self, forKey: .tiktok)) ?? TikTokOptions()
    youtube = (try? c.decodeIfPresent(YouTubeOptions.self, forKey: .youtube)) ?? YouTubeOptions()
    instagram = (try? c.decodeIfPresent(InstagramOptions.self, forKey: .instagram)) ?? InstagramOptions()
    x = (try? c.decodeIfPresent(XOptions.self, forKey: .x)) ?? XOptions()
    let base = (try? c.decodeIfPresent(String.self, forKey: .apiBase)) ?? nil
    apiBase = base.flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil } ?? Self.cloudAPIBase  // the key never goes over http
    let b = (try? c.decodeIfPresent(Int.self, forKey: .hourlyBudget)) ?? nil
    hourlyBudget = max(Self.minimumBudget, min(1000, b ?? 25))
  }

  /// String-keyed maps, so the stored JSON reads `{"publishers": {"tiktok": "postiz"}}`.
  public func encode(to e: Encoder) throws {
    var c = e.container(keyedBy: CodingKeys.self)
    try c.encode(Dictionary(uniqueKeysWithValues: publishers.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .publishers)
    try c.encode(Dictionary(uniqueKeysWithValues: channels.map { ($0.key.rawValue, $0.value) }), forKey: .channels)
    try c.encode(testMode, forKey: .testMode)
    try c.encode(tiktok, forKey: .tiktok)
    try c.encode(youtube, forKey: .youtube)
    try c.encode(instagram, forKey: .instagram)
    try c.encode(x, forKey: .x)
    try c.encode(apiBase, forKey: .apiBase)
    try c.encode(hourlyBudget, forKey: .hourlyBudget)
  }
}
