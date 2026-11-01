import Foundation

/// Phase 1 publisher (spec §9): prepares the file, cover, caption and title; Eric posts and marks done.
public final class ManualPublisher: Publisher, @unchecked Sendable {
  let store: Store
  let renderer: RenderService

  public init(store: Store, renderer: RenderService) {
    self.store = store
    self.renderer = renderer
  }

  public var name: String { "manual" }

  public func prepare(postId: String) throws -> PreparedPost {
    guard let p = try store.post(id: postId) else { throw EngineError("No post \(postId)") }
    guard let v = try store.video(id: p.videoId) else { throw EngineError("No video \(p.videoId)") }
    let settings = try store.settings()
    var render = try p.renderId.flatMap { try store.render(id: $0) }
    if render?.status != .done || render?.outputPath == nil || render?.deletedAt != nil {
      render = try renderer.ensureRender(videoId: p.videoId, versionNo: p.versionNo, platform: p.platform)
    }
    guard let r = render, let out = r.outputPath else { throw EngineError("No render for \(v.tag) v\(p.versionNo)") }
    guard let rv = try store.resolvedVersion(videoId: v.id, number: p.versionNo, settings: settings) else {
      throw EngineError("\(v.tag) has no v\(p.versionNo)")
    }
    let caption = Captions.caption(for: p.platform, version: rv, video: v, sessionName: try store.sessionName(for: v),
                                   sets: try store.hashtagSets(), templates: try store.captionTemplates(), settings: settings)
    let title = p.platform == .youtube ? Captions.youtubeTitle(rv, video: v, settings: settings) : nil
    return PreparedPost(postId: p.id, platform: p.platform, fileURL: URL(fileURLWithPath: out),
                        coverURL: r.coverPath.map { URL(fileURLWithPath: $0) }, caption: caption, title: title,
                        uploadURL: p.platform.uploadURL)
  }

  public func submit(_ post: PreparedPost) throws -> PublishStatus { .waitingForUser }

  public func status(postId: String) throws -> PublishStatus {
    guard let p = try store.post(id: postId) else { throw EngineError("No post \(postId)") }
    switch p.state {
    case .posted: return .posted(url: p.url ?? "", at: p.postedAt ?? p.updatedAt)
    case .failed, .copyrightBlocked, .copyrightMuted, .removed:
      return .failed(p.errorType ?? .other, p.errorMessage ?? p.state.displayName)
    default: return .waitingForUser
    }
  }
}
