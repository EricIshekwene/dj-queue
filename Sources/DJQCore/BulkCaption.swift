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

  /// `current` without the removed groups, then the added ones it doesn't have yet.
  public func groups(from current: [String]) -> [String] {
    var out = current.filter { !removeGroups.contains($0) }
    for id in addGroups where !out.contains(id) { out.append(id) }
    return out
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
  /// Platforms with their own caption: they stay as they are.
  public var ownCaptions: [Platform]
  /// Platforms the caption would be too long for.
  public var tooLong: [Platform]
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
  func previewCaption(_ ids: [String], _ change: CaptionChange) throws -> [CaptionPreview] {
    let settings = try store.settings(), sets = try store.hashtagSets(), templates = try store.captionTemplates()
    let held = try HashtagGroupsMigration.clipsWithPosts(store)
    return try ids.compactMap { id in
      guard let v = try store.video(id: id) else { return nil }
      let all = try store.versions(videoId: id)
      var v1 = all.first { $0.number == 1 } ?? Version(number: 1)
      let saved = all.isEmpty ? [v1] : all
      let session = try store.sessionName(for: v)
      let before = VersionResolver.resolve(saved, number: 1, settings: settings, video: v)
      func shared(_ r: ResolvedVersion) -> String {
        Captions.sharedCaption(version: r, video: v, sessionName: session, sets: sets, templates: templates, settings: settings)
      }
      let own = Platform.allCases.filter { !(before.platformCaptions[$0] ?? "").isEmpty }
      if held.contains(id) {
        return CaptionPreview(id: id, name: v.displayName, caption: shared(before), changes: false, replacesWritten: false,
                              skipped: Self.captionHeldReason, ownCaptions: own, tooLong: [])
      }
      change.apply(to: &v1, current: before.hashtagSetIds)
      var after = VersionResolver.resolve([v1], number: 1, settings: settings, video: v)
      var retagged = v1
      Captions.retag(&retagged, before: before, after: after, sets: sets)
      if retagged != v1 { after = VersionResolver.resolve([retagged], number: 1, settings: settings, video: v) }
      let caption = shared(after)
      let re = (try? store.edit(videoId: id)).map { EditResolver.resolve($0, video: v, defaults: settings.defaults) }
      let platforms = settings.activePlatforms.filter { re?.isSkipped($0) != true }
      let tooLong = platforms.filter { p in
        guard let limit = settings.limits[p]?.captionLimit else { return false }
        return Captions.caption(for: p, version: after, video: v, sessionName: session, sets: sets, templates: templates, settings: settings).count > limit
      }
      return CaptionPreview(id: id, name: v.displayName, caption: caption, changes: caption != shared(before) || after != before,
                            replacesWritten: change.setsTemplate && !before.caption.isEmpty, skipped: nil, ownCaptions: own, tooLong: tooLong)
    }
  }

  /// How many of `ids` have each group now (clips left out don't count), for the dialog's chips.
  func groupUse(_ ids: [String]) throws -> (counts: [String: Int], total: Int) {
    let settings = try store.settings(), held = try HashtagGroupsMigration.clipsWithPosts(store)
    var counts: [String: Int] = [:], total = 0
    for id in ids where !held.contains(id) {
      guard try store.video(id: id) != nil, let r = try store.resolvedVersion(videoId: id, number: 1, settings: settings) else { continue }
      total += 1
      for g in Set(r.hashtagSetIds) { counts[g, default: 0] += 1 }
    }
    return (counts, total)
  }
}
