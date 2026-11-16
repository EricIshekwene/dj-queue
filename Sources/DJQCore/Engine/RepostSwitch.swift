import Foundation

/// Round 36–38 (DECISIONS-R36.md, R37, R38): a clip posts each of its versions once unless Eric marks it repostable with
/// a count (Repostable ×3: in the editor's clip row, bulk Mark repostable on the Queue, Edit, Library, Calendar and ⌘K,
/// `djq reposts`). Then every version posts that many times. A version's own Posts (`Version.postCount`, 0 = never) is an
/// override for that version only, repostable or not. "Repostable" in filters and search means some version posts more
/// than once.
///
/// Stored in kv `plan.repost` as `[videoId: count]` (round 37 stored a list of ids; those read as `postsPerVersion`).
/// Planning data like the version order: setting it never touches how a version looks, so nothing re-renders.
public enum RepostSwitch {
  public static let key = "plan.repost"
  /// The counts the bulk menu offers.
  public static let menuCounts = [2, 3, 4, 5]
}

extension Store {
  /// Clip id → its repost count, for the clips marked repostable.
  public func repostCounts() throws -> [String: Int] {
    if let map = try? kv(RepostSwitch.key, as: [String: Int].self) { return map }
    // Round 37 kept only the ids: they post the default count.
    let ids = (try? kv(RepostSwitch.key, as: [String].self)) ?? []
    let n = max(2, try settings().postsPerVersion)
    return Dictionary(ids.map { ($0, n) }, uniquingKeysWith: { a, _ in a })
  }

  /// Clips marked repostable as a whole.
  public func repostClips() throws -> Set<String> { Set(try repostCounts().keys) }

  /// The clip's repost count (nil = not repostable: its versions post once unless one has its own Posts).
  public func repostCount(videoId: String) throws -> Int? { try repostCounts()[videoId] }

  public func repostOn(videoId: String) throws -> Bool { try repostCount(videoId: videoId) != nil }

  /// Clips that post some version more than once (marked repostable, or a version's own Posts above once), as the
  /// planner counts them (`UnitBook`).
  public func repostableClips() throws -> Set<String> {
    Set(try UnitBook(store: self).clips.filter { $0.value.counts.values.contains { $0 > 1 } }.keys)
  }

  public func isRepostable(videoId: String) throws -> Bool {
    guard let v = try video(id: videoId), v.type == .short else { return false }
    return try UnitBook(store: self, videos: [v])[videoId]?.counts.values.contains { $0 > 1 } ?? false
  }

  /// Writes the whole map (only the kv; callers re-plan).
  func writeRepostCounts(_ map: [String: Int]) throws { try setKV(RepostSwitch.key, map) }

  /// Marks a clip repostable with `on` = true (at the Settings default count) or not.
  @discardableResult
  public func setRepost(videoId: String, _ on: Bool) throws -> Bool {
    try setRepost(videoId: videoId, count: on ? max(2, try settings().postsPerVersion) : nil)
  }

  /// Marks a clip repostable with `count` (2–9: every version posts that many times) or not (nil: every version once).
  /// A version's own Posts stays: it's that version's override. A lower count, or not repostable, takes the reposts it
  /// no longer asks for off at once where they can still move (`Planner.dropUnitsBeyondCount`), and the next pass closes
  /// the gaps; a higher one gives them days on the next pass. Returns false when nothing changed.
  @discardableResult
  public func setRepost(videoId: String, count: Int?) throws -> Bool {
    guard let v = try video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form: long-form is never reposted") }
    if let count, !(2...PostUnits.maxCount).contains(count) {
      throw EngineError("A repostable clip posts each version 2 to \(PostUnits.maxCount) times")
    }
    var changed = false
    try db.transaction {
      var all = try repostCounts()
      let was = all[videoId]
      guard was != count else { return }
      all[videoId] = count
      try writeRepostCounts(all)
      changed = true
      try logEvent("version", count.map { "Repostable ×\($0): each version posts \($0) times (a version's own Posts stays)" }
                                ?? "Not repostable: each version posts once (a version's own Posts stays)", videoId: videoId)
      if (count ?? 1) < (was ?? 1), try Planner(store: self).dropUnitsBeyondCount(videoId: videoId) > 0 {
        try setKV(Planner.compactKey, true)
      }
      try refreshState(videoId: videoId)
    }
    return changed
  }
}
