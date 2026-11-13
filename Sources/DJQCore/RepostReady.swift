import Foundation

// Round 20: "Ready to repost" per text version. Eric edits several versions of one clip and marks each one he
// wants in the repost cycle. This file is the data and the read-only logic a repost round will use; it schedules
// nothing. Marking a version ready never changes a clip's stage, state, Send to Queue flag, slots or posts (the
// ONLY thing that moves a clip from Edit to Queue is Eric's Send to Queue).

public enum RepostReady {
  /// Ready version numbers, in order.
  public static func numbers(_ versions: [Version]) -> [Int] {
    versions.filter { $0.repostReady == true }.map(\.number).sorted()
  }

  /// Ready versions that `platform` hasn't had yet (no post of that version there, in any state but skipped),
  /// in order: what a repost round would use next on that platform. Read-only.
  public static func candidates(versions: [Version], posts: [PlatformPost], platform: Platform) -> [Int] {
    let used = Set(posts.filter { $0.platform == platform && $0.state != .skipped }.map(\.versionNo))
    return numbers(versions).filter { !used.contains($0) }
  }

  /// Short label: "v2 · v3" (empty when none).
  public static func label(_ numbers: [Int]) -> String { numbers.map { "v\($0)" }.joined(separator: " · ") }
}

extension Store {
  /// Sets or clears "Ready to repost" on version `number` of a short-form clip. Writes only that version's flag:
  /// `updated_at` stays (the flag changes no pixels, so previews and renders aren't touched) and the clip's state
  /// isn't recomputed (the flag isn't an input to it). v1 can be marked before anything else on it was saved.
  /// Returns false when it was already that way.
  @discardableResult
  public func setRepostReady(videoId: String, number: Int, _ ready: Bool) throws -> Bool {
    guard let v = try video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form: long-form is never reposted") }
    var changed = false
    try db.transaction {
      let all = try versions(videoId: videoId)
      if var ver = all.first(where: { $0.number == number }) {
        guard (ver.repostReady == true) != ready else { return }
        ver.repostReady = ready ? true : nil
        try db.run("UPDATE versions SET json=? WHERE video_id=? AND number=?", [JSONCoding.string(ver), videoId, number])
      } else {
        guard number == 1 else { throw EngineError("\(v.tag) has no v\(number)") }
        guard ready else { return }
        var ver = Version(number: 1)
        ver.repostReady = true
        // updated_at 0: v1 still looks exactly as before (its preview stamp only notes that a row exists).
        try db.run("INSERT INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,0)", [videoId, 1, JSONCoding.string(ver)])
      }
      changed = true
      try logEvent("version", ready ? "v\(number) ready to repost" : "v\(number) no longer ready to repost", videoId: videoId)
    }
    return changed
  }

  /// Ready version numbers of one clip, in order.
  public func repostReadyVersions(videoId: String) throws -> [Int] {
    RepostReady.numbers(try versions(videoId: videoId))
  }

  /// Ready version numbers of every clip that has one (clips without a ready version are left out). One query;
  /// an unreadable row is skipped here (the editor and `djq video` report it).
  public func repostReadyVersions() throws -> [String: [Int]] {
    var out: [String: [Int]] = [:]
    for r in try db.query("SELECT video_id, json FROM versions WHERE json LIKE '%\"repostReady\"%' ORDER BY video_id, number") {
      guard let id = r.string("video_id"), let s = r.string("json"),
            let v = try? JSONCoding.decoder.decode(Version.self, from: Data(s.utf8)), v.repostReady == true else { continue }
      out[id, default: []].append(v.number)
    }
    return out
  }

  /// The first ready version `platform` hasn't had yet (nil = none). Read-only: for the repost round.
  public func nextRepostReadyVersion(videoId: String, platform: Platform) throws -> Int? {
    RepostReady.candidates(versions: try versions(videoId: videoId),
                           posts: try posts(where: "video_id=?", [videoId]), platform: platform).first
  }
}

/// Round 20: an open editor saving a version keeps what changed in the store since it last saved (`base`), where the
/// editor didn't change it itself: the Ready to repost mark (`djq repost-ready`) and a bulk caption change's pin on a
/// later version (`captionsOwn` and the caption fields copied in). Everything else is the editor's.
public enum VersionMerge {
  public static func keepingOutsideChanges(_ v: Version, base: Version?, stored: Version?) -> Version {
    guard let base, let stored else { return v }
    var out = v
    func keep<T: Equatable>(_ kp: WritableKeyPath<Version, T>) { if v[keyPath: kp] == base[keyPath: kp] { out[keyPath: kp] = stored[keyPath: kp] } }
    keep(\.repostReady)
    keep(\.postCount)  // round 31: `djq post-count` while the editor is open
    if stored.captionsOwn == true, base.captionsOwn != true {
      keep(\.captionsOwn); keep(\.caption); keep(\.captionTemplateId); keep(\.hashtagSetIds); keep(\.extraHashtags)
      keep(\.youtubeTitle); keep(\.platformCaptions); keep(\.youtubeTitleTemplateId)
    }
    return out
  }
}
