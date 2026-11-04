import Foundation

/// The rules and the one write path for hashtag groups, shared by the editor, Settings and `djq hashtag-groups`
/// (v0.8.1). Every group lives in the one `hashtag_sets` table, so a group made anywhere shows up in Settings, New clip
/// defaults and every clip.
///
/// Editing or deleting a group never changes a clip with scheduled or posted posts: those clips are frozen first, the way
/// schema 6 did it (`HashtagGroupsMigration`), so their captions, YouTube tags and Postiz content hashes stay byte-identical.
/// The freeze is in the same journaled batch, so undo restores it.
public enum HashtagGroups {
  /// The category every group made by hand goes in (the editor shows category headings only when there are several).
  public static let category = "My groups"

  /// What's wrong with a group, worst first. `message` is what the disabled Save button says.
  public enum Problem: Equatable, Sendable {
    case noName, noTags
    case duplicateName(String)

    public var message: String {
      switch self {
      case .noName: "Give the group a name"
      case .noTags: "Add at least one hashtag"
      case .duplicateName(let n): "A group called “\(n)” already exists"
      }
    }
  }

  /// Typed text → tags: split on spaces, commas and new lines, each one `Captions.normalizeTag`ged, duplicates dropped.
  public static func parseTags(_ raw: String) -> [String] {
    var seen = Set<String>()
    return raw.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { Captions.normalizeTag(String($0)) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  public static func cleanName(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The group already called `name` (ignoring case and outer spaces), leaving out the one being edited.
  public static func named(_ name: String, in existing: [HashtagSet], except id: String? = nil) -> HashtagSet? {
    let n = cleanName(name).lowercased()
    return existing.first { $0.id != id && cleanName($0.name).lowercased() == n }
  }

  /// Nil when the group can be saved. `editing` = the id of the group being edited: it may keep its name, even one that
  /// another group also has (Settings can still make those).
  public static func problem(name: String, tags: [String], existing: [HashtagSet], editing id: String? = nil) -> Problem? {
    if cleanName(name).isEmpty { return .noName }
    let original = existing.first { $0.id == id }.map { cleanName($0.name).lowercased() }
    if original != cleanName(name).lowercased(), let same = named(name, in: existing, except: id) {
      return .duplicateName(same.name)
    }
    return tags.isEmpty ? .noTags : nil
  }

  /// A new group placed after the existing ones (the caller saves it).
  public static func make(name: String, tags: [String], existing: [HashtagSet]) -> HashtagSet {
    HashtagSet(id: newId(), name: cleanName(name), category: category, tags: tags, sort: (existing.map(\.sort).max() ?? -1) + 1)
  }

  // MARK: What a change reaches

  /// How many clips use a group: `kept` have scheduled or posted posts and won't change, `others` follow the change.
  public struct Impact: Equatable, Sendable {
    public var kept: Int
    public var others: Int
    public init(kept: Int, others: Int) { self.kept = kept; self.others = others }

    private func clips(_ n: Int, _ noun: String, _ verb: String) -> String {
      n == 1 ? "1 \(noun) \(verb)s" : "\(n) \(noun)s \(verb)"
    }
    private func withPosts(_ verb: String) -> String {
      kept == 1 ? "1 clip with scheduled or posted posts \(verb)s" : "\(kept) clips with scheduled or posted posts \(verb)"
    }

    /// The delete confirm says this.
    public var deleteSummary: String {
      var parts: [String] = []
      if kept > 0 { parts.append("\(withPosts("keep")) these tags.") }
      if others > 0 { parts.append("\(clips(others, "other clip", "lose")) them, except tags typed into a caption.") }
      return parts.isEmpty ? "No clip uses this group." : parts.joined(separator: " ")
    }

    /// The edit form and Settings say this.
    public var editSummary: String {
      var parts: [String] = []
      if kept > 0 { parts.append("\(withPosts("keep")) the current tags.") }
      if others > 0 { parts.append("\(clips(others, "other clip", "follow")) the change, except tags typed into a caption.") }
      return parts.isEmpty ? "No clip uses this group." : parts.joined(separator: " ")
    }
  }

  /// A saved group change: the batch, and the clips frozen so they keep what they have.
  public struct Change: Sendable {
    public var result: BulkResult
    public var kept: [String]
  }

  private static func usage(of id: String, store: Store) throws -> (kept: [String], others: [String]) {
    let settings = try store.settings(), posted = try HashtagGroupsMigration.clipsWithPosts(store)
    var kept: [String] = [], others: [String] = []
    for v in try store.videos() {
      let saved = try store.versions(videoId: v.id), vs = saved.isEmpty ? [Version(number: 1)] : saved
      guard vs.contains(where: { VersionResolver.resolve(vs, number: $0.number, settings: settings, video: v).hashtagSetIds.contains(id) })
      else { continue }
      if posted.contains(v.id) { kept.append(v.id) } else if v.type == .short, !v.excluded { others.append(v.id) }
    }
    return (kept, others)
  }

  public static func impact(of id: String, store: Store) throws -> Impact {
    let u = try usage(of: id, store: store)
    return Impact(kept: u.kept.count, others: u.others.count)
  }

  /// As the schema-6 migration: every version's resolved hashtags go into its extra hashtags and ALL its group ids are
  /// cleared (moving only this group's tags would reorder them, and the order is part of the caption and the hash).
  private static func freeze(_ ids: [String], store: Store) throws {
    let settings = try store.settings(), sets = try store.hashtagSets()
    for id in ids {
      guard let v = try store.video(id: id) else { continue }
      var vs = try store.versions(videoId: id)
      if !vs.contains(where: { $0.number == 1 }) { vs.insert(Version(number: 1), at: 0) }
      let resolved = vs.map { VersionResolver.resolve(vs, number: $0.number, settings: settings, video: v) }
      for (i, r) in resolved.enumerated() {
        vs[i].hashtagSetIds = []
        vs[i].extraHashtags = Captions.hashtags(r, sets: sets)
      }
      for ver in vs { try store.save(ver, videoId: id) }
    }
  }

  // MARK: The one write path

  @discardableResult
  public static func create(_ group: HashtagSet, store: Store, bulk: BulkActions) throws -> Change {
    // No clip's validity depends on a group nobody has picked yet, so no revalidation pass.
    Change(result: try bulk.record("hashtag-group-add", hashtagGroups: true, revalidate: false) { try store.save(group) }, kept: [])
  }

  /// Saves `group` over the stored one. Tags that change freeze the clips with posts first; a rename reaches nothing.
  /// A group that no longer exists is left deleted (a form or a debounced save can outlive it).
  @discardableResult
  public static func update(_ group: HashtagSet, store: Store, bulk: BulkActions) throws -> Change {
    guard let old = try store.hashtagSets().first(where: { $0.id == group.id }) else {
      return Change(result: BulkResult(batchId: nil, action: "hashtag-group-edit", dryRun: false, videoIds: [], changed: [], skipped: [:],
                                       remainingIssues: [:], summary: "hashtag-group-edit: group is gone"), kept: [])
    }
    let retagged = old.tags.map(Captions.normalizeTag) != group.tags.map(Captions.normalizeTag)
    let kept = retagged ? try usage(of: group.id, store: store).kept : []
    let r = try bulk.record("hashtag-group-edit", ids: kept, hashtagGroups: true, revalidate: retagged) {
      try freeze(kept, store: store)
      try store.save(group)
    }
    return Change(result: r, kept: kept)
  }

  /// Deletes the group and takes it out of the default groups.
  @discardableResult
  public static func delete(_ group: HashtagSet, store: Store, bulk: BulkActions) throws -> Change {
    let kept = try usage(of: group.id, store: store).kept
    let r = try bulk.record("hashtag-group-delete", ids: kept, settings: true, hashtagGroups: true) {
      try freeze(kept, store: store)
      try store.deleteHashtagSet(group.id)
      var st = try store.settings()
      if st.defaults.hashtagSetIds.contains(group.id) {
        st.defaults.hashtagSetIds.removeAll { $0 == group.id }
        try store.save(st)
      }
    }
    return Change(result: r, kept: kept)
  }
}
