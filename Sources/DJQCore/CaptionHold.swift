import Foundation

/// The one guarantee behind every change to what a caption is built from (the default template, a template's text, a link
/// line, a hashtag cap): a clip with scheduled or posted posts keeps byte-identical captions, so its Postiz content hash
/// doesn't move. Callers do their change inside `BulkActions.record`, listing the clips in `affected`, then call `keep`.
enum CaptionHold {
  /// What a clip posts: version number → platform → caption.
  typealias Outputs = [Int: [Platform: String]]

  /// Everything a caption is built from, besides the clip.
  struct Sources {
    var settings: Settings
    var templates: [CaptionTemplate]
    var sets: [HashtagSet]
    init(settings: Settings, templates: [CaptionTemplate], sets: [HashtagSet]) {
      self.settings = settings; self.templates = templates; self.sets = sets
    }
    init(_ store: Store) throws {
      self.init(settings: try store.settings(), templates: try store.captionTemplates(), sets: try store.hashtagSets())
    }
  }

  private static func withFirst(_ versions: [Version]) -> [Version] {
    versions.contains { $0.number == 1 } ? versions : [Version(number: 1)] + versions
  }

  static func outputs(_ video: Video, _ versions: [Version], _ from: Sources, session: String, legacy: Bool = false) -> Outputs {
    var out: Outputs = [:]
    let vs = withFirst(versions)
    for number in vs.map(\.number) {
      let r = VersionResolver.resolve(vs, number: number, settings: from.settings, video: video)
      out[number] = Dictionary(uniqueKeysWithValues: Platform.allCases.map {
        ($0, Captions.output($0, r, video, session, from.sets, from.templates, from.settings, legacy: legacy))
      })
    }
    return out
  }

  static func outputs(_ video: Video, _ from: Sources, store: Store, legacy: Bool = false) throws -> Outputs {
    outputs(video, try store.versions(videoId: video.id), from, session: try store.sessionName(for: video), legacy: legacy)
  }

  /// Clips with scheduled or posted posts whose captions differ between two sets of sources.
  static func affected(from before: Sources, to after: Sources, store: Store, except: Set<String> = []) throws -> [Video] {
    try HashtagGroupsMigration.clipsWithPosts(store).subtracting(except).sorted().compactMap { try store.video(id: $0) }
      .filter { try outputs($0, before, store: store) != outputs($0, after, store: store) }
  }

  /// Makes `video` post `before` again under the current data: a platform that reads differently keeps its old caption as
  /// its own. Stops (rolling the batch back) rather than let a caption change.
  static func keep(_ video: Video, as before: Outputs, store: Store) throws {
    let now = try Sources(store), session = try store.sessionName(for: video)
    var vs = withFirst(try store.versions(videoId: video.id))
    for number in vs.map(\.number).sorted() {
      guard let was = before[number], let i = vs.firstIndex(where: { $0.number == number }) else { continue }
      let reads = outputs(video, vs, now, session: session)[number] ?? [:]
      guard reads != was else { continue }
      var own = VersionResolver.resolve(vs, number: number, settings: now.settings, video: video).platformCaptions
      for p in Platform.allCases where reads[p] != was[p] { own[p] = was[p] }
      vs[i].platformCaptions = own
      try store.save(vs[i], videoId: video.id)
    }
    guard outputs(video, vs, now, session: session) == before else {
      throw EngineError("The caption of \(video.displayName) would change, so nothing was changed")
    }
  }

  /// Why an undo that goes back to `saved` would change a clip with posts that it doesn't restore (nil = it wouldn't): such a
  /// clip took up the change after the batch.
  static func undoConflict(from current: Sources, to saved: Sources, restoring: Set<String>, store: Store) throws -> String? {
    let hit = try affected(from: current, to: saved, store: store, except: restoring)
    guard !hit.isEmpty else { return nil }
    return "\(hit.count) clip\(hit.count == 1 ? "" : "s") with scheduled or posted posts would change"
  }
}
