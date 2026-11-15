import Foundation

/// Round 36 (DECISIONS-R36.md): a clip posts each of its versions once, unless Eric turns Repost on for that clip. On, its
/// versions post `Settings.postsPerVersion` times (2), or a version's own count (`Version.postCount`), spaced by the
/// round-31 rules. It replaces round 31's "every version posts twice" default (Eric, 15 Nov: "I would rather have it off
/// by default and then I switch it on for videos").
///
/// Stored in kv `plan.repost` as the ids of the clips with Repost on. It's planning data, like the version order: turning
/// it on or off never touches a version or the clip's edit, so nothing re-renders.
public enum RepostSwitch {
  public static let key = "plan.repost"
}

extension Store {
  /// Clips with Repost on.
  public func repostClips() throws -> Set<String> { Set((try? kv(RepostSwitch.key, as: [String].self)) ?? []) }

  public func repostOn(videoId: String) throws -> Bool { try repostClips().contains(videoId) }

  /// Turns Repost on or off for a clip. Off takes the clip's repeats off the calendar at once where they can still move
  /// (`Planner.dropUnitsBeyondCount`); the engine's next pass closes the gaps they leave. On gives its repeats days on
  /// the next pass. Returns false when it was already that way.
  @discardableResult
  public func setRepost(videoId: String, _ on: Bool) throws -> Bool {
    guard let v = try video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form: long-form is never reposted") }
    var changed = false
    try db.transaction {
      var all = try repostClips()
      guard all.contains(videoId) != on else { return }
      if on { all.insert(videoId) } else { all.remove(videoId) }
      try setKV(RepostSwitch.key, all.sorted())
      changed = true
      try logEvent("version", on ? "Repost on: each version posts \(try settings().postsPerVersion) times (or its own count)"
                                 : "Repost off: each version posts once", videoId: videoId)
      if !on, try Planner(store: self).dropUnitsBeyondCount(videoId: videoId) > 0 {
        try setKV(Planner.compactKey, true)
      }
      try refreshState(videoId: videoId)
    }
    return changed
  }
}
