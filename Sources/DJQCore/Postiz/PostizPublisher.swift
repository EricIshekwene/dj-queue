import Foundation

/// The Postiz `Publisher` (spec §2: queue, editor and tracking don't change). The engine drives Postiz through
/// `PostizService.publish()` / `sync()` in the tick; this type gives the same lifecycle through the `Publisher`
/// interface (prepare / submit one post / read its status) for callers that work post by post.
public final class PostizPublisher: Publisher, @unchecked Sendable {
  public let service: PostizService
  let store: Store

  public init(service: PostizService) {
    self.service = service
    store = service.store
  }

  public var name: String { "postiz" }

  /// The file, cover, caption and (YouTube) title exactly as they go to Postiz.
  public func prepare(postId: String) throws -> PreparedPost {
    guard let p = try store.post(id: postId) else { throw EngineError("No post \(postId)") }
    let settings = try store.settings()
    guard case .postiz(let id, let provider) = try service.router(settings).route(p.platform) else {
      throw EngineError("\(p.platform.displayName) doesn't publish through Postiz right now")
    }
    let spec = try PostizPayload.spec(store: store, post: p, settings: settings, integrationId: id, provider: provider)
    var title: String?
    if case .string(let t) = spec.settings["title"] { title = t }
    return PreparedPost(postId: p.id, platform: p.platform, fileURL: URL(fileURLWithPath: spec.renderPath),
                        coverURL: spec.coverPath.map { URL(fileURLWithPath: $0) }, caption: spec.content, title: title,
                        uploadURL: URL(string: settings.publishing.apiBase) ?? p.platform.uploadURL)
  }

  /// Submits this one post now (no-op when it already has a job). A refusal falls back to Manual.
  public func submit(_ post: PreparedPost) throws -> PublishStatus {
    guard let p = try store.post(id: post.postId) else { throw EngineError("No post \(post.postId)") }
    if try store.livePostizJob(postId: p.id) == nil, try store.finalPostizJob(postId: p.id) == nil {
      let settings = try store.settings()
      guard case .postiz(let id, let provider) = try service.router(settings).route(p.platform) else { return .waitingForUser }
      _ = try service.submit(p, integrationId: id, provider: provider, settings: settings)
    }
    return try status(postId: p.id)
  }

  public func status(postId: String) throws -> PublishStatus {
    guard let p = try store.post(id: postId) else { throw EngineError("No post \(postId)") }
    if p.state == .posted { return .posted(url: p.url ?? "", at: p.postedAt ?? p.updatedAt) }
    if p.state.isProblem && p.state != .overdue { return .failed(p.errorType ?? .other, p.errorMessage ?? p.state.displayName) }
    if let j = try store.livePostizJob(postId: postId), let id = j.postizId { return .scheduled(externalId: id) }
    return .waitingForUser
  }
}

/// Doctor checks for the Postiz publisher (the CLI owner adds them to `Doctor.run()`). No network: they read the
/// settings, the Keychain's "has a key" answer, kv flags, the cached channel list and the jobs table. When no platform
/// uses Postiz and no job is open, every check passes.
public enum PostizDoctor {
  public static let checkIds = ["postiz.not_connected", "postiz.key_invalid", "postiz.mapping_missing", "postiz.channel_disabled",
                                "postiz.stuck", "postiz.link_missing", "postiz.delete_pending"]

  public static func findings(store: Store, keyStore: PostizKeyStore) throws -> (findings: [DoctorFinding], passed: [String]) {
    let settings = try store.settings()
    let open = try store.openPostizJobs()
    let used = settings.publishing.postizPlatforms
    guard !used.isEmpty || !open.isEmpty else { return ([], checkIds) }
    let service = PostizService(store: store, transport: OfflineTransport(), keyStore: keyStore)
    let router = try service.router(settings)
    var out: [DoctorFinding] = []
    let names = used.map(\.displayName).joined(separator: ", ")
    if !router.hasKey && !used.isEmpty {
      out.append(.init(id: "postiz.not_connected", severity: .error, title: "Postiz isn't connected",
                       detail: "\(names) publish through Postiz but no API key is saved; their posts go to Today.",
                       where_: used.map(\.rawValue), fix: "Add the key in Settings → Publishing"))
    }
    if let inv = try store.postizKeyInvalid() {
      out.append(.init(id: "postiz.key_invalid", severity: .error, title: "Postiz refused the API key",
                       detail: "Since \(Sched.shortTime(inv.at, settings)): \(inv.message.isEmpty ? "401" : inv.message). Posts go to Today.",
                       where_: used.map(\.rawValue), fix: "Save the key again in Settings → Publishing"))
    }
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    let unmapped = used.filter { p in
      guard let id = settings.publishing.channels[p], !id.isEmpty else { return true }
      return cache.map { !$0.integrations.contains { $0.id == id } } ?? false
    }
    if !unmapped.isEmpty {
      out.append(.init(id: "postiz.mapping_missing", severity: .warning, title: "No Postiz channel for \(unmapped.map(\.displayName).joined(separator: ", "))",
                       detail: "These platforms are set to Postiz without a (current) channel; their posts go to Today.",
                       where_: unmapped.map(\.rawValue), fix: "Pick the channel in Settings → Publishing (`djq postiz channels`)"))
    }
    let disabled = used.compactMap { p -> (Platform, String)? in
      guard let id = settings.publishing.channels[p], let c = cache?.integrations.first(where: { $0.id == id }), c.disabled else { return nil }
      return (p, c.name)
    }
    if !disabled.isEmpty {
      out.append(.init(id: "postiz.channel_disabled", severity: .warning, title: "Postiz channel disabled or expired",
                       detail: disabled.map { "\($0.0.displayName): \($0.1)" }.joined(separator: " · "),
                       where_: disabled.map(\.0.rawValue), fix: "Reconnect the channel in Postiz, then `djq postiz channels`"))
    }
    let stuck = try service.stuckJobs()
    if !stuck.isEmpty {
      out.append(.init(id: "postiz.stuck", severity: .warning, title: "\(stuck.count) Postiz post\(stuck.count == 1 ? "" : "s") still waiting after the slot",
                       detail: stuck.map { "\($0.platform.displayName) due \(Sched.shortTime($0.remoteDate, settings))" }.joined(separator: " · "),
                       where_: stuck.map(\.postId), fix: "Check the Postiz calendar; DJ Queue keeps checking"))
    }
    let missing = try service.linkMissingPosts()
    if !missing.isEmpty {
      out.append(.init(id: "postiz.link_missing", severity: .info, title: "Posted without a link",
                       detail: "Postiz published \(missing.count) post\(missing.count == 1 ? "" : "s") but the platform link came back missing.",
                       where_: missing.map(\.id), fix: "`djq postiz link <post-id>`"))
    }
    let pending = open.filter { $0.phase == .deleting && $0.attempts >= 3 }
    if !pending.isEmpty {
      out.append(.init(id: "postiz.delete_pending", severity: .warning, title: "Couldn't remove \(pending.count) post\(pending.count == 1 ? "" : "s") from Postiz",
                       detail: pending.map { "\($0.platform.displayName): \($0.lastError ?? "error")" }.joined(separator: " · "),
                       where_: pending.map(\.postId), fix: "DJ Queue keeps retrying and sends nothing new meanwhile; delete it in Postiz if it should not post"))
    }
    let failed = Set(out.map(\.id))
    return (out, checkIds.filter { !failed.contains($0) })
  }

  /// Doctor never calls Postiz.
  final class OfflineTransport: PostizTransport, @unchecked Sendable {
    func send(_ request: PostizHTTPRequest) throws -> PostizHTTPResponse { throw PostizError.network("offline") }
  }
}
