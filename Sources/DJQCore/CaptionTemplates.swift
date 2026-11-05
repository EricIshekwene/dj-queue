import Foundation

/// The write path for caption templates and the default one, shared by the editor and Settings. No `djq` command manages
/// them, so there is nothing to keep in step there. Every write is one journaled batch; `CaptionHold` keeps the captions of
/// clips with scheduled or posted posts byte-identical.
public enum CaptionTemplates {
  public static let setDefaultAction = "default-caption-template"

  /// Journaled changes that write clips on their own: an open editor session moves past them (`rebasedOntoGroupChanges`).
  static let batchActions = [setDefaultAction]

  /// Makes `id` the default template. Clips with posts that follow the default stay on the old one (any platform with its
  /// own default template then keeps its caption as that platform's own); every other clip follows the new default.
  /// Per-platform default templates aren't touched.
  @discardableResult
  public static func setDefault(_ id: String, store: Store, bulk: BulkActions) throws -> HashtagGroups.Change {
    let before = try CaptionHold.Sources(store), old = before.settings.defaults.captionTemplateId
    guard before.templates.contains(where: { $0.id == id }) else { throw EngineError("No caption template \(id)") }
    guard id != old else {
      return HashtagGroups.Change(result: BulkResult(batchId: nil, action: setDefaultAction, dryRun: false, videoIds: [], changed: [], skipped: [:],
                                                     remainingIssues: [:], summary: "\(setDefaultAction): nothing changed"), kept: [])
    }
    let kept = try followers(before.settings, store: store)
    let r = try bulk.record(setDefaultAction, ids: kept.map(\.id), params: ["template": id, "was": old], settings: true) {
      let saved = try kept.map { ($0, try CaptionHold.outputs($0, before, store: store)) }
      for v in kept { try pin(v, to: old, settings: before.settings, store: store) }
      var s = before.settings
      s.defaults.captionTemplateId = id
      try store.save(s)
      for (v, outputs) in saved { try CaptionHold.keep(v, as: outputs, store: store) }
    }
    return HashtagGroups.Change(result: r, kept: kept.map(\.id))
  }

  /// A version with no chosen template and no written caption (carried forward counts as chosen or written).
  private static func follows(_ r: ResolvedVersion) -> Bool { r.captionTemplateId == nil && r.caption.isEmpty }

  private static func resolved(_ v: Video, _ settings: Settings, store: Store) throws -> (versions: [Version], resolved: [ResolvedVersion]) {
    var vs = try store.versions(videoId: v.id)
    if !vs.contains(where: { $0.number == 1 }) { vs.insert(Version(number: 1), at: 0) }
    return (vs, vs.map { VersionResolver.resolve(vs, number: $0.number, settings: settings, video: v) })
  }

  /// Clips with scheduled or posted posts that follow the default template in some version.
  private static func followers(_ settings: Settings, store: Store) throws -> [Video] {
    try HashtagGroupsMigration.clipsWithPosts(store).sorted().compactMap { try store.video(id: $0) }
      .filter { try resolved($0, settings, store: store).resolved.contains(where: follows) }
  }

  private static func pin(_ v: Video, to template: String, settings: Settings, store: Store) throws {
    let (versions, all) = try resolved(v, settings, store: store)
    for (version, r) in zip(versions, all) where follows(r) {
      var pinned = version
      pinned.captionTemplateId = template
      try store.save(pinned, videoId: v.id)
    }
  }
}
