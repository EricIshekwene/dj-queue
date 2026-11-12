import Foundation

/// Round 29: the editor's "Make default…" — one clip's caption setup (template, YouTube title template, hashtag groups,
/// extra hashtags, the platforms it posts to) becomes what new clips start with. Clips that already exist keep what they
/// post unless Eric asks for the ones without scheduled or posted posts to follow; a clip with posts always keeps its
/// captions, tags, title and platforms byte-identical. One journaled batch (one Undo).
public enum CaptionDefaults {
  public static let action = "caption-defaults"

  /// What becomes the default; nil leaves that default as it is.
  public struct Choice: Sendable, Hashable {
    public var captionTemplateId: String?
    public var youtubeTitleTemplateId: String?
    public var hashtagSetIds: [String]?
    public var extraHashtags: [String]?
    public var platforms: Set<Platform>?

    public init(captionTemplateId: String? = nil, youtubeTitleTemplateId: String? = nil, hashtagSetIds: [String]? = nil,
                extraHashtags: [String]? = nil, platforms: Set<Platform>? = nil) {
      self.captionTemplateId = captionTemplateId
      self.youtubeTitleTemplateId = youtubeTitleTemplateId
      self.hashtagSetIds = hashtagSetIds
      self.extraHashtags = extraHashtags
      self.platforms = platforms
    }

    public var isEmpty: Bool {
      captionTemplateId == nil && youtubeTitleTemplateId == nil && hashtagSetIds == nil && extraHashtags == nil && platforms == nil
    }

    public func applied(to d: NewClipDefaults) -> NewClipDefaults {
      var d = d
      if let x = captionTemplateId { d.captionTemplateId = x }
      if let x = youtubeTitleTemplateId { d.youtubeTitleTemplateId = x }
      if let x = hashtagSetIds { d.hashtagSetIds = x }
      if let x = extraHashtags { d.extraHashtags = x }
      if let x = platforms { d.platforms = x }
      return d
    }
  }

  /// Existing clips that take up the new defaults unless they're kept: `follow` have no scheduled or posted posts (they
  /// follow only when Eric asks), `held` have posts (always kept).
  public struct Reach: Sendable, Hashable {
    public var follow: [String] = []
    public var held: [String] = []
    public init(follow: [String] = [], held: [String] = []) { self.follow = follow; self.held = held }
  }

  /// Which existing clips would change if `choice` became the default.
  public static func reach(_ choice: Choice, store: Store) throws -> Reach {
    let s = try store.settings(), after = choice.applied(to: s.defaults)
    let posted = try HashtagGroupsMigration.clipsWithPosts(store)
    var r = Reach()
    for v in try store.videos() where try v.type != .long && pin(v, from: s, to: after, store: store) != nil {
      if posted.contains(v.id) { r.held.append(v.id) } else { r.follow.append(v.id) }
    }
    return r
  }

  /// Saves `choice` over New clip defaults. `updateExisting` false: every existing clip that would change keeps what it has
  /// (its versions and edit say so explicitly). True: clips without scheduled or posted posts follow the new defaults.
  /// `source`: the clip and version the choice came from. Its own values that now equal the defaults are cleared, so it reads
  /// "Default" (what it posts doesn't move; the same batch, so Undo puts them back).
  @discardableResult
  public static func save(_ choice: Choice, updateExisting: Bool, source: (videoId: String, number: Int)? = nil, store: Store,
                          bulk: BulkActions) throws -> HashtagGroups.Change {
    let before = try CaptionHold.Sources(store)
    if let id = choice.captionTemplateId, !before.templates.contains(where: { $0.id == id }) { throw EngineError("No caption template \(id)") }
    if let id = choice.youtubeTitleTemplateId, !before.settings.youtubeTitleTemplates.contains(where: { $0.id == id }) {
      throw EngineError("No YouTube title template \(id)")
    }
    if let ids = choice.hashtagSetIds, let gone = ids.first(where: { id in !before.sets.contains { $0.id == id } }) {
      throw EngineError("No hashtag group \(gone)")
    }
    var after = before
    after.settings.defaults = choice.applied(to: before.settings.defaults)
    guard after.settings.defaults != before.settings.defaults else {
      return HashtagGroups.Change(result: BulkResult(batchId: nil, action: action, dryRun: false, videoIds: [], changed: [], skipped: [:],
                                                     remainingIssues: [:], summary: "\(action): nothing changed"), kept: [])
    }
    let posted = try HashtagGroupsMigration.clipsWithPosts(store)
    var kept = try store.videos().filter { v in
      guard v.type != .long, !updateExisting || posted.contains(v.id) else { return false }
      return try pin(v, from: before.settings, to: after.settings.defaults, store: store) != nil
    }
    // Safety net, as `CaptionTemplates.saveDefaults` has it: any clip with posts whose output would move is held too.
    for v in try CaptionHold.affected(from: before, to: after, store: store) where !kept.contains(where: { $0.id == v.id }) { kept.append(v) }
    let origin = try source.flatMap { try store.video(id: $0.videoId) }
    let ids = kept.map(\.id) + (origin.map { o in kept.contains { $0.id == o.id } ? [] : [o.id] } ?? [])
    let r = try bulk.record(action, ids: ids, params: ["existing": updateExisting ? "follow" : "keep"], settings: true) {
      let saved = try kept.map { ($0, try CaptionHold.outputs($0, before, store: store), try CaptionHold.signature($0, before, store: store)) }
      let editsBefore = try kept.map { ($0, try store.edit(videoId: $0.id)) }
      // The source version itself never moves, whichever way the rest of its clip goes.
      let sourceBefore = try origin.map { o in (o, try versionOutput(o, source!.number, before, store: store), try store.edit(videoId: o.id)) }
      for v in kept {
        guard let p = try pin(v, from: before.settings, to: after.settings.defaults, store: store) else { continue }
        for version in p.versions { try store.save(version, videoId: v.id) }
        if let e = p.edit { try store.save(e, videoId: v.id, remembersCrop: false) }
        try CaptionHold.pinTagsAndTitle(v, from: before, to: after, store: store)
      }
      try store.save(after.settings)
      if let origin, let number = source?.number { try follow(origin, number: number, choice, after, store: store) }
      for (v, outputs, signature) in saved {
        try CaptionHold.keep(v, as: outputs, store: store)
        guard try CaptionHold.signature(v, after, store: store) == signature else {
          throw EngineError("What \(v.displayName) posts would change, so nothing was changed")
        }
      }
      if let (o, was, edit) = sourceBefore {
        guard try versionOutput(o, source!.number, after, store: store) == was else {
          throw EngineError("What \(o.displayName) posts would change, so nothing was changed")
        }
        let now = try store.edit(videoId: o.id)
        for p in Platform.allCases where edit.isSkipped(p, defaults: before.settings.defaults) != now.isSkipped(p, defaults: after.settings.defaults) {
          throw EngineError("\(o.displayName) would change where it posts, so nothing was changed")
        }
      }
      for (v, edit) in editsBefore {
        let now = try store.edit(videoId: v.id)
        for p in Platform.allCases where edit.isSkipped(p, defaults: before.settings.defaults) != now.isSkipped(p, defaults: after.settings.defaults) {
          throw EngineError("\(v.displayName) would change where it posts, so nothing was changed")
        }
      }
    }
    return HashtagGroups.Change(result: r, kept: kept.map(\.id))
  }

  /// What one version posts: its caption per platform, its YouTube tags and title.
  struct VersionOutput: Equatable {
    var captions: [Platform: String]
    var tags: [String]
    var title: String
  }

  static func versionOutput(_ v: Video, _ number: Int, _ from: CaptionHold.Sources, versions: [Version]? = nil, store: Store) throws -> VersionOutput {
    var vs = try versions ?? store.versions(videoId: v.id)
    if !vs.contains(where: { $0.number == 1 }) { vs.insert(Version(number: 1), at: 0) }
    let session = try store.sessionName(for: v)
    let r = VersionResolver.resolve(vs, number: number, settings: from.settings, video: v)
    return VersionOutput(captions: CaptionHold.outputs(v, vs, from, session: session)[number] ?? [:], tags: Captions.hashtags(r, sets: from.sets),
                         title: Captions.youtubeTitle(r, video: v, settings: from.settings))
  }

  /// Clears what the source version and edit set to the very values that are now the defaults, one field at a time, keeping a
  /// clear only where the version still posts exactly the same (a later version could otherwise start inheriting, or a platform
  /// with its own default template could move).
  static func follow(_ v: Video, number: Int, _ c: Choice, _ now: CaptionHold.Sources, store: Store) throws {
    let s = now.settings
    var vs = try store.versions(videoId: v.id)
    if let i = vs.firstIndex(where: { $0.number == number }) {
      let was = try versionOutput(v, number, now, versions: vs, store: store)
      func clear<T: Equatable>(_ kp: WritableKeyPath<Version, T?>, _ picked: Bool, _ key: String) throws {
        guard picked, let old = vs[i][keyPath: kp] else { return }
        vs[i][keyPath: kp] = nil
        let r = VersionResolver.resolve(vs, number: number, settings: s, video: v)
        if try versionOutput(v, number, now, versions: vs, store: store) != was || !r.defaulted.contains(key) { vs[i][keyPath: kp] = old }
      }
      try clear(\.captionTemplateId, c.captionTemplateId != nil, "captionTemplateId")
      try clear(\.hashtagSetIds, c.hashtagSetIds != nil, "hashtagSetIds")
      try clear(\.extraHashtags, c.extraHashtags != nil, "extraHashtags")
      try clear(\.youtubeTitleTemplateId, c.youtubeTitleTemplateId != nil, "youtubeTitleTemplateId")
      try store.save(vs[i], videoId: v.id)
    }
    guard let on = c.platforms else { return }
    var e = try store.edit(videoId: v.id)
    let before = e
    for p in Platform.allCases where !(v.isPhoto && !p.supportsPhotos) {
      let skipped = e.isSkipped(p, defaults: s.defaults)
      if skipped == !on.contains(p) { e.skippedPlatforms.remove(p); e.includedPlatforms.remove(p) }
    }
    if e != before { try store.save(e, videoId: v.id, remembersCrop: false) }
  }

  /// What `v` needs written so it reads the same under `to` as under `from` (nil = nothing it shows would change): each
  /// version that follows a default that moves gets the old value, and a platform it follows gets an explicit on or off.
  static func pin(_ v: Video, from s: Settings, to d1: NewClipDefaults, store: Store) throws -> (versions: [Version], edit: Edit?)? {
    let d0 = s.defaults
    var vs = try store.versions(videoId: v.id)
    if !vs.contains(where: { $0.number == 1 }) { vs.insert(Version(number: 1), at: 0) }
    vs.sort { $0.number < $1.number }
    var changed = Set<Int>()
    for i in vs.indices {
      let r = VersionResolver.resolve(vs, number: vs[i].number, settings: s, video: v)
      if d0.captionTemplateId != d1.captionTemplateId, r.captionTemplateId == nil, r.caption.isEmpty {
        vs[i].captionTemplateId = d0.captionTemplateId
        changed.insert(i)
      }
      if d0.hashtagSetIds != d1.hashtagSetIds, r.defaulted.contains("hashtagSetIds") {
        vs[i].hashtagSetIds = d0.hashtagSetIds
        changed.insert(i)
      }
      if d0.extraHashtags != d1.extraHashtags, r.defaulted.contains("extraHashtags") {
        vs[i].extraHashtags = d0.extraHashtags
        changed.insert(i)
      }
      // A chosen title template that was deleted follows the default one too (`Settings.youtubeTitleTemplate(id:)`). A photo
      // post never goes to YouTube.
      let followsTitle = r.youtubeTitleTemplateId.map { id in !s.youtubeTitleTemplates.contains { $0.id == id } } ?? true
      if d0.youtubeTitleTemplateId != d1.youtubeTitleTemplateId, !v.isPhoto, r.youtubeTitle.isEmpty, followsTitle {
        vs[i].youtubeTitleTemplateId = d0.youtubeTitleTemplateId
        changed.insert(i)
      }
    }
    var edit: Edit?
    if d0.platforms != d1.platforms {
      var e = try store.edit(videoId: v.id)
      let photoOnly = v.isPhoto
      for p in Platform.allCases where d0.platforms.contains(p) != d1.platforms.contains(p) {
        guard !e.skippedPlatforms.contains(p), !e.includedPlatforms.contains(p), !(photoOnly && !p.supportsPhotos) else { continue }
        if d0.platforms.contains(p) { e.includedPlatforms.insert(p) } else { e.skippedPlatforms.insert(p) }
        edit = e
      }
    }
    let versions = changed.sorted().map { vs[$0] }
    return versions.isEmpty && edit == nil ? nil : (versions, edit)
  }
}
