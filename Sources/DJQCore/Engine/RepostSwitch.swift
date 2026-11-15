import Foundation

/// Round 36/37 (DECISIONS-R36.md, DECISIONS-R37.md): a clip posts each of its versions once unless Eric marks it
/// repostable (bulk "Mark repostable" on the Queue, Edit, Library and Calendar, `djq reposts`). Repostable: every version
/// posts `Settings.postsPerVersion` times (2). A version's own Posts count (the editor's one per-version control,
/// `Version.postCount`, 0 = never) always wins, so "repostable" is also true of a clip with any version set above once.
///
/// The clip-wide mark is stored in kv `plan.repost` (ids), planning data like the version order: setting it never touches
/// how a version looks, so nothing re-renders.
public enum RepostSwitch {
  public static let key = "plan.repost"
}

extension Store {
  /// Clips marked repostable as a whole (kv only; see `repostableClips` for what the app shows).
  public func repostClips() throws -> Set<String> { Set((try? kv(RepostSwitch.key, as: [String].self)) ?? []) }

  /// Marked repostable as a whole: its versions default to `postsPerVersion` instead of once.
  public func repostOn(videoId: String) throws -> Bool { try repostClips().contains(videoId) }

  /// Clips that post some version more than once (marked repostable, or a version's own Posts above once), as the
  /// planner counts them (`UnitBook`).
  public func repostableClips() throws -> Set<String> {
    Set(try UnitBook(store: self).clips.filter { $0.value.counts.values.contains { $0 > 1 } }.keys)
  }

  public func isRepostable(videoId: String) throws -> Bool {
    guard let v = try video(id: videoId), v.type == .short else { return false }
    return try UnitBook(store: self, videos: [v])[videoId]?.counts.values.contains { $0 > 1 } ?? false
  }

  /// Marks a clip repostable or not. On: every version posts `postsPerVersion` times, unless it has a count of its own.
  /// Off: every version posts once; a version's own count above once goes back to once (one with Posts 0 stays out).
  /// Off takes the planned reposts off at once where they can still move (`Planner.dropUnitsBeyondCount`) and the next
  /// pass closes the gaps; on gives the reposts days on the next pass. Returns false when nothing changed.
  @discardableResult
  public func setRepost(videoId: String, _ on: Bool) throws -> Bool {
    guard let v = try video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form: long-form is never reposted") }
    var changed = false
    try db.transaction {
      var all = try repostClips()
      if all.contains(videoId) != on {
        if on { all.insert(videoId) } else { all.remove(videoId) }
        try setKV(RepostSwitch.key, all.sorted())
        changed = true
      }
      if !on {
        for ver in try versions(videoId: videoId) where (ver.postCount ?? 0) > 1 {
          try setPostCount(videoId: videoId, number: ver.number, nil)
          changed = true
        }
      }
      guard changed else { return }
      try logEvent("version", on ? "Repostable: each version posts \(try settings().postsPerVersion) times (or its own Posts)"
                                 : "Not repostable: each version posts once", videoId: videoId)
      if !on, try Planner(store: self).dropUnitsBeyondCount(videoId: videoId) > 0 {
        try setKV(Planner.compactKey, true)
      }
      try refreshState(videoId: videoId)
    }
    return changed
  }
}
