import Foundation

/// One caption pass over many clips (round 12): a template, plus hashtag groups added or removed per clip, as ONE undoable batch.
/// The app's Caption dialog and `djq bulk caption` both land here, and `preview` shows what `setCaption` would write.
public struct CaptionChange: Sendable, Hashable {
  public enum Template: Sendable, Hashable {
    /// Each clip keeps its template and its written caption (hashtags inside it are swapped in place).
    case keep
    /// Back to the default template.
    case useDefault
    case use(String)
  }

  public var template: Template
  /// Groups each clip gains, in caption order, after the groups it keeps.
  public var addGroups: [String]
  public var removeGroups: [String]

  public init(template: Template = .keep, addGroups: [String] = [], removeGroups: [String] = []) {
    self.template = template; self.addGroups = addGroups; self.removeGroups = removeGroups
  }

  public var isEmpty: Bool { template == .keep && addGroups.isEmpty && removeGroups.isEmpty }
  public var setsTemplate: Bool { template != .keep }

  /// A group as the dialog shows it, `count` of `total` clips having it now.
  public enum GroupMark: Sendable { case all, some, none }

  public func mark(_ id: String, count: Int, total: Int) -> GroupMark {
    if addGroups.contains(id) { return .all }
    if removeGroups.contains(id) { return .none }
    return total > 0 && count >= total ? .all : count > 0 ? .some : .none
  }

  /// One click on a group: on everywhere, off everywhere, and back to how the clips were. Click order is caption order.
  public mutating func toggle(_ id: String, count: Int, total: Int) {
    let some = count > 0 && count < total
    if addGroups.contains(id) {
      addGroups.removeAll { $0 == id }
      if some { removeGroups.append(id) }
    } else if removeGroups.contains(id) {
      removeGroups.removeAll { $0 == id }
    } else if total > 0 && count >= total {
      removeGroups.append(id)
    } else {
      addGroups.append(id)
    }
  }

  /// `current` without the removed groups, then the added ones in click order, so every clip ends on the same tags: a group a
  /// clip already has moves to its place in that order.
  public func groups(from current: [String]) -> [String] {
    current.filter { !removeGroups.contains($0) && !addGroups.contains($0) } + addGroups
  }

  /// `current` = the groups this clip resolves to now. A written caption goes when a template is chosen, as in the editor.
  func apply(to v: inout Version, current: [String]) {
    switch template {
    case .keep: break
    case .useDefault: v.captionTemplateId = nil; v.caption = nil
    case .use(let id): v.captionTemplateId = id; v.caption = nil
    }
    let next = groups(from: current)
    if next != current { v.hashtagSetIds = next }
  }
}

public extension CaptionTemplates {
  /// A template that carries `tags`, for "Save as template" in the Caption dialog: `base` with the tags typed in where the clip's
  /// hashtags go. `{hashtags}` stays after them, so a group added to a clip later still shows.
  static func template(from base: String, carrying tags: [String]) -> String {
    let list = tags.joined(separator: " ")
    guard !list.isEmpty else { return base }
    if base.contains("{hashtags}") { return base.replacingOccurrences(of: "{hashtags}", with: list + " {hashtags}") }
    return base.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + list + " {hashtags}"
  }
}

/// What a caption pass would do to one clip.
public struct CaptionPreview: Sendable, Identifiable, Equatable {
  public var id: String
  public var name: String
  /// The caption most platforms would post after the change.
  public var caption: String
  public var changes: Bool
  /// A caption Eric wrote goes away, replaced by the chosen template.
  public var replacesWritten: Bool
  /// Why this clip is left out (nil = it isn't).
  public var skipped: String?
  /// Posting platforms that post something else: their own caption, or their own default template. Hashtag caps don't count.
  public var otherCaptions: [Platform]
  /// Platforms the caption would be too long for.
  public var tooLong: [Platform]
  /// What each platform's hashtag cap drops.
  public var capNotes: [Captions.CapNote]
  /// Groups were picked but their tags aren't in the caption: its template has no `{hashtags}`.
  public var hidesGroups: Bool
  /// A Queue clip the change would send back to Edit.
  public var leavesQueue: Bool

  init(id: String, name: String, caption: String, changes: Bool = false, replacesWritten: Bool = false, skipped: String? = nil,
       otherCaptions: [Platform] = [], tooLong: [Platform] = [], capNotes: [Captions.CapNote] = [], hidesGroups: Bool = false,
       leavesQueue: Bool = false) {
    self.id = id; self.name = name; self.caption = caption; self.changes = changes; self.replacesWritten = replacesWritten
    self.skipped = skipped; self.otherCaptions = otherCaptions; self.tooLong = tooLong; self.capNotes = capNotes
    self.hidesGroups = hidesGroups; self.leavesQueue = leavesQueue
  }
}

/// Where the selected clips stand on hashtag groups.
public struct GroupUse: Sendable, Equatable {
  public var counts: [String: Int] = [:]
  public var total = 0
  public var common: [String] = []
  public init() {}
}

public extension BulkActions {
  /// Clips with scheduled or posted posts keep their caption byte for byte.
  static let captionHeldReason = "It has scheduled or posted posts, so its caption stays as it is"

  /// Sets the template and hashtag groups of every clip in `ids`, as one batch.
  @discardableResult
  func setCaption(_ ids: [String], _ change: CaptionChange, dryRun: Bool = false) throws -> BulkResult {
    if case .use(let id) = change.template, try !store.captionTemplates().contains(where: { $0.id == id }) {
      throw EngineError("No caption template \(id)")
    }
    let known = Set(try store.hashtagSets().map(\.id))
    if let bad = (change.addGroups + change.removeGroups).first(where: { !known.contains($0) }) {
      throw EngineError("No hashtag group \(bad)" + (known.isEmpty ? " — there are no hashtag groups yet (djq hashtag-groups add)" : " (djq hashtag-groups lists them)"))
    }
    let held = try HashtagGroupsMigration.clipsWithPosts(store)
    var params = ["template": Self.templateParam(change.template)]
    if !change.addGroups.isEmpty { params["add"] = change.addGroups.joined(separator: ",") }
    if !change.removeGroups.isEmpty { params["remove"] = change.removeGroups.joined(separator: ",") }
    return try run("caption", ids: ids, params: params, dryRun: dryRun) { _, v, s in
      if held.contains(v.id) { return .skipped(Self.captionHeldReason) }
      let current = try store.resolvedVersion(videoId: v.id, number: 1, settings: s)?.hashtagSetIds ?? []
      return try updateV1Retagged(v, s) { change.apply(to: &$0, current: current) }
    }
  }

  private static func templateParam(_ t: CaptionChange.Template) -> String {
    switch t {
    case .keep: "keep"
    case .useDefault: "default"
    case .use(let id): id
    }
  }

  /// Each clip's outcome, in the order of `ids`, without writing anything. Fast enough to run on every click in the dialog.
  /// A clip that can't be read is left out with the reason, the way `setCaption` skips it.
  func previewCaption(_ ids: [String], _ change: CaptionChange) throws -> [CaptionPreview] {
    let settings = try store.settings(), sets = try store.hashtagSets(), templates = try store.captionTemplates()
    let held = try HashtagGroupsMigration.clipsWithPosts(store)
    let added = change.addGroups.flatMap { g in sets.first { $0.id == g }?.tags ?? [] }.map(Captions.normalizeTag)
    return try ids.compactMap { id in
      guard let v = try store.video(id: id) else { return nil }
      do {
        return try preview(v, change, held: held.contains(id), added: added, settings: settings, sets: sets, templates: templates)
      } catch {
        return CaptionPreview(id: id, name: v.displayName, caption: "", skipped: "\(error)")
      }
    }
  }

  private func preview(_ v: Video, _ change: CaptionChange, held: Bool, added: [String], settings: Settings, sets: [HashtagSet],
                       templates: [CaptionTemplate]) throws -> CaptionPreview {
    let all = try store.versions(videoId: v.id)
    var v1 = all.first { $0.number == 1 } ?? Version(number: 1)
    let session = try store.sessionName(for: v)
    let before = VersionResolver.resolve(all.isEmpty ? [v1] : all, number: 1, settings: settings, video: v)
    func shared(_ r: ResolvedVersion) -> String {
      Captions.sharedCaption(version: r, video: v, sessionName: session, sets: sets, templates: templates, settings: settings)
    }
    func posted(_ p: Platform, _ r: ResolvedVersion) -> String {
      Captions.caption(for: p, version: r, video: v, sessionName: session, sets: sets, templates: templates, settings: settings)
    }
    if held { return CaptionPreview(id: v.id, name: v.displayName, caption: shared(before), skipped: Self.captionHeldReason) }
    change.apply(to: &v1, current: before.hashtagSetIds)
    var after = VersionResolver.resolve([v1], number: 1, settings: settings, video: v)
    var retagged = v1
    Captions.retag(&retagged, before: before, after: after, sets: sets)
    if retagged != v1 { after = VersionResolver.resolve([retagged], number: 1, settings: settings, video: v) }
    let caption = shared(after)
    let re = EditResolver.resolve(try store.edit(videoId: v.id), video: v, defaults: settings.defaults)
    let platforms = settings.activePlatforms.filter { !re.isSkipped($0) }
    let other = platforms.filter { posted($0, after) != Captions.capped(caption, to: settings.limits[$0]?.maxHashtags).text }
    let long = platforms.filter { p in settings.limits[p].map { posted(p, after).count > $0.captionLimit } ?? false }
    let shown = Set(Captions.tags(in: caption))
    return CaptionPreview(id: v.id, name: v.displayName, caption: caption, changes: caption != shared(before) || after != before,
                          replacesWritten: change.setsTemplate && !before.caption.isEmpty, otherCaptions: other, tooLong: long,
                          capNotes: Captions.capNotes(platforms, version: after, video: v, sessionName: session, sets: sets,
                                                      templates: templates, settings: settings),
                          hidesGroups: added.contains { !shown.contains($0) }, leavesQueue: v.state == .ready && !long.isEmpty)
  }

  /// How many of `ids` have each group now, and the groups all of them have in the first clip's order. Clips left out don't count.
  func groupUse(_ ids: [String]) throws -> GroupUse {
    let settings = try store.settings(), held = try HashtagGroupsMigration.clipsWithPosts(store)
    var use = GroupUse(), first: [String]?
    for id in ids where !held.contains(id) {
      guard try store.video(id: id) != nil, let r = try? store.resolvedVersion(videoId: id, number: 1, settings: settings) else { continue }
      use.total += 1
      if first == nil { first = r.hashtagSetIds }
      for g in Set(r.hashtagSetIds) { use.counts[g, default: 0] += 1 }
    }
    use.common = (first ?? []).filter { use.counts[$0] == use.total }
    return use
  }
}
