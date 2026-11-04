import Foundation

/// Why a platform (or one post) set to Postiz goes to Today as a manual post instead (docs/postiz.md §5 Fallback).
public enum PostizFallbackReason: Codable, Sendable, Hashable {
  case noKey
  case keyInvalid
  case noChannel
  case channelDisabled(String)
  /// The mapped channel id isn't in Postiz's channel list any more.
  case channelMissing
  /// Postiz refused the create (400) with this message.
  case createRejected(String)
  /// The post vanished from Postiz (deleted in the Postiz calendar).
  case vanished

  public var message: String {
    switch self {
    case .noKey: "No Postiz API key — add it in Settings → Publishing"
    case .keyInvalid: "Postiz refused the API key — save it again in Settings → Publishing"
    case .noChannel: "No Postiz channel picked for this platform"
    case .channelDisabled(let name): "The Postiz channel \(name) is disabled or needs reconnecting in Postiz"
    case .channelMissing: "The picked Postiz channel isn't in Postiz any more — pick it again"
    case .createRejected(let m): "Postiz refused this post: \(m)"
    case .vanished: "The post was deleted in Postiz"
    }
  }

  /// Short id for logs, kv and `djq` JSON.
  public var code: String {
    switch self {
    case .noKey: "no_key"
    case .keyInvalid: "key_invalid"
    case .noChannel: "no_channel"
    case .channelDisabled: "channel_disabled"
    case .channelMissing: "channel_missing"
    case .createRejected: "create_rejected"
    case .vanished: "vanished"
    }
  }
}

public enum PublishRoute: Sendable, Hashable {
  /// The platform is set to Manual.
  case manual
  /// Set to Postiz and usable.
  case postiz(integrationId: String, provider: String)
  /// Set to Postiz but it can't be used now; the posts go to Today.
  case fallback(PostizFallbackReason)

  public var isPostiz: Bool { if case .postiz = self { return true } else { return false } }
  public var fallbackReason: PostizFallbackReason? { if case .fallback(let r) = self { return r } else { return nil } }
}

/// Postiz channels as last listed (`GET /integrations`), kept in kv `postiz.channels`.
public struct PostizChannelCache: Codable, Sendable, Hashable {
  public var fetchedAt: Date
  public var integrations: [PostizIntegration]
  public static let kvKey = "postiz.channels"
  public init(fetchedAt: Date, integrations: [PostizIntegration]) { self.fetchedAt = fetchedAt; self.integrations = integrations }
}

/// Picks Manual or Postiz per platform from settings, the key's state and the channel list. Pure: build it with
/// `PostizRouter.current(store:keyStore:)` or directly in tests.
public struct PostizRouter: Sendable {
  public var settings: Settings
  public var hasKey: Bool
  public var keyInvalid: Bool
  /// nil = never listed (channels are then assumed fine).
  public var channels: [PostizIntegration]?

  public init(settings: Settings, hasKey: Bool, keyInvalid: Bool, channels: [PostizIntegration]?) {
    self.settings = settings; self.hasKey = hasKey; self.keyInvalid = keyInvalid; self.channels = channels
  }

  /// Reads the key's presence (never its value), the 401 flag and the cached channel list. The Keychain is only
  /// asked when some platform is set to Postiz.
  public static func current(store: Store, keyStore: PostizKeyStore, settings: Settings? = nil) throws -> PostizRouter {
    let s = try settings ?? store.settings()
    let any = !s.publishing.postizPlatforms.isEmpty
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    return PostizRouter(settings: s, hasKey: any ? keyStore.hasKey() : false, keyInvalid: try store.postizKeyInvalid() != nil,
                        channels: cache?.integrations)
  }

  public func route(_ p: Platform) -> PublishRoute {
    guard settings.publishing.publisher(for: p) == .postiz else { return .manual }
    guard hasKey else { return .fallback(.noKey) }
    guard !keyInvalid else { return .fallback(.keyInvalid) }
    guard let id = settings.publishing.channels[p], !id.isEmpty else { return .fallback(.noChannel) }
    var provider = PostizPlatforms.provider(p)
    if let channels {
      guard let c = channels.first(where: { $0.id == id }) else { return .fallback(.channelMissing) }
      if c.disabled { return .fallback(.channelDisabled(c.name)) }
      if !c.identifier.isEmpty { provider = c.identifier }
    }
    return .postiz(integrationId: id, provider: provider)
  }

  public var routes: [Platform: PublishRoute] { Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0, route($0)) }) }
}
