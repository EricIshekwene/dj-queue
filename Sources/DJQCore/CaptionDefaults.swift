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
    let kept = try store.videos().filter { v in
      guard v.type != .long, !updateExisting || posted.contains(v.id) else { return false }
      return try pin(v, from: before.settings, to: after.settings.defaults, store: store) != nil
    }
    let origin = try source.flatMap { try store.video(id: $0.videoId) }
    let held = kept + (origin.map { o in kept.contains { $0.id == o.id } ? [] : [o] } ?? [])
    let r = try bulk.record(action, ids: held.map(\.id), params: ["existing": updateExisting ? "follow" : "keep"], settings: true) {
      let saved = try held.map { ($0, try CaptionHold.outputs($0, before, store: store), try CaptionHold.signature($0, before, store: store)) }
      let editsBefore = try held.map { ($0, try store.edit(videoId: $0.id)) }
      for v in kept {
        guard let p = try pin(v, from: before.settings, to: after.settings.defaults, store: store) else { continue }
        for version in p.versions { try store.save(version, videoId: v.id) }
        if let e = p.edit { try store.save(e, videoId: v.id, remembersCrop: false) }
        try CaptionHold.pinTagsAndTitle(v, from: before, to: after, store: store)
      }
      try store.save(after.settings)
      if let origin, let number = source?.number { try follow(origin, number: number, choice, settings: after.settings, store: store) }
      for (v, outputs, signature) in saved {
        try CaptionHold.keep(v, as: outputs, store: store)
        guard try CaptionHold.signature(v, after, store: store) == signature else {
          throw EngineError("What \(v.displayName) posts would change, so nothing was changed")
        }
      }
      for (v, edit) in editsBefore {
        let now = try store.edit(videoId: v.id)
        for p in Platform.allCases where edit.isSkipped(p, defaults: before.settings.defaults) != now.isSkipped(p, defaults: after.settings.defaults) {
          throw EngineError("\(v.displayName) would change where it posts, so nothing was changed")
        }
      }
    }
    return HashtagGroups.Change(result: r, kept: held.map(\.id))
  }

  /// Clears what the source version and edit set to the very values that are now the defaults, one field at a time, keeping a
  /// clear only where the version still resolves to the same value (a later version could otherwise start inheriting).
  static func follow(_ v: Video, number: Int, _ c: Choice, settings s: Settings, store: Store) throws {
    var vs = try store.versions(videoId: v.id)
    if let i = vs.firstIndex(where: { $0.number == number }) {
      let was = VersionResolver.resolve(vs, number: number, settings: s, video: v)
      func clear<T: Equatable>(_ kp: WritableKeyPath<Version, T?>, _ picked: Bool, _ same: (ResolvedVersion) -> Bool) {
        guard picked, let old = vs[i][keyPath: kp] else { return }
        vs[i][keyPath: kp] = nil
        let now = VersionResolver.resolve(vs, number: number, settings: s, video: v)
        if !same(now) { vs[i][keyPath: kp] = old }
      }
      clear(\.captionTemplateId, c.captionTemplateId != nil) {
        ($0.captionTemplateId ?? s.defaults.captionTemplateId) == (was.captionTemplateId ?? s.defaults.captionTemplateId) && $0.caption == was.caption
      }
      clear(\.hashtagSetIds, c.hashtagSetIds != nil) { $0.hashtagSetIds == was.hashtagSetIds && $0.defaulted.contains("hashtagSetIds") }
      clear(\.extraHashtags, c.extraHashtags != nil) { $0.extraHashtags == was.extraHashtags && $0.defaulted.contains("extraHashtags") }
      clear(\.youtubeTitleTemplateId, c.youtubeTitleTemplateId != nil) {
        ($0.youtubeTitleTemplateId ?? s.defaults.youtubeTitleTemplateId) == (was.youtubeTitleTemplateId ?? s.defaults.youtubeTitleTemplateId)
          && $0.youtubeTitleTemplate == was.youtubeTitleTemplate
      }
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
      if d0.youtubeTitleTemplateId != d1.youtubeTitleTemplateId, r.youtubeTitle.isEmpty, r.youtubeTitleTemplateId == nil {
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
