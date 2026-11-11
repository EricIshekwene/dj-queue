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
                        uploadURL: URL(string: settings.publishing.apiBase) ?? p.platform.uploadURL,
                        moreFileURLs: spec.photoPaths.dropFirst().map { URL(fileURLWithPath: $0) })
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
