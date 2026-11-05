import Foundation
import Testing
@testable import DJQCore

/// v0.8.3: clip-0 is planned and follows the defaults, clip-1 has no posts and follows them too.
extension Fixture {
  static func planned() throws -> Fixture {
    let f = try Fixture.engine(3, ready: 1)
    try f.follow("clip-0")
    try f.follow("clip-1")
    try Planner(store: f.store).approveWeek(f.week)
    return f
  }

  /// Text and nothing else: the template comes from the defaults.
  func follow(_ id: String) throws {
    var v = try store.versions(videoId: id).first { $0.number == 1 } ?? Version(number: 1)
    v.captionTemplateId = nil
    v.caption = nil
    v.text = "Text \(id)"
    try store.save(v, videoId: id)
  }

  var bulk: BulkActions { BulkActions(store: store) }

  func captions(_ id: String) throws -> CaptionHold.Outputs {
    let v = try #require(try store.video(id: id))
    return try CaptionHold.outputs(v, CaptionHold.Sources(store), store: store)
  }

  /// The Postiz content hash of every post the clip has. The render is made once: `FakeRenderer` hashes the whole version, a
  /// caption field included, where the real `Renderer` hashes only what's in the file (`renderHashIgnoresTheCaption`).
  func hashes(_ id: String = "clip-0") throws -> [String: String] {
    let r: Render
    if let done = try store.renders(where: "video_id=? AND status='done'", [id]).first { r = done }
    else { r = try FakeRenderer(store: store).ensureRender(videoId: id, versionNo: 1, platform: nil) }
    let s = try store.settings()
    var out: [String: String] = [:]
    for var p in try store.posts(where: "video_id=?", [id], order: "id") {
      p.renderId = r.id
      out[p.id] = try PostizPayload.spec(store: store, post: p, settings: s, integrationId: "ch-\(p.platform.rawValue)").contentHash
    }
    #expect(!out.isEmpty)
    return out
  }

  func journal(_ id: String) throws -> String? {
    try store.db.one("SELECT json FROM versions WHERE video_id=? AND number=1", [id])?.string("json")
  }
}
