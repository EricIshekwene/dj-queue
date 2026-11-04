import Foundation

/// Schema 6 (round 7): hashtag groups become Eric's own, none by default, and a written caption is literal.
///
/// 1. **Identity step** (not journaled; changes no output): a written caption without `{hashtags}` gets
///    `Captions.legacySuffix` ("\n{hashtags}") — rounds 1–6 appended the hashtags on a new line, round 7 appends
///    nothing — and a settings row without `defaults.hashtagSetIds` gets the old default groups written out.
/// 2. **Journaled batch** "hashtag-groups-migration" (`djq bulk undo <id>` restores step 1's state, whose captions are
///    the old ones): every clip with a post that is still in flight or already posted keeps byte-identical captions —
///    its built-in group tags are frozen into each version's `extraHashtags` and its group ids cleared (and, should a
///    platform's caption still differ, that platform gets the old caption as its own); every other clip loses the
///    six built-in groups; the built-in groups are deleted; `defaults.hashtagSetIds` loses them (→ []).
enum HashtagGroupsMigration {
  struct Report: Sendable {
    var frozen: [String] = []
    var dropped: [String] = []
    var suffixed: Int = 0
    var pinnedPlatformCaptions: [String] = []
    var batchId: String?
  }

  /// Clip ids whose captions must not change: any post not finished (planned … overdue) or posted.
  static func clipsWithPosts(_ store: Store) throws -> Set<String> {
    let gone = [PostState.failed, .copyrightBlocked, .copyrightMuted, .removed, .skipped].map { "'\($0.rawValue)'" }.joined(separator: ",")
    return Set(try store.db.query("SELECT DISTINCT video_id FROM platform_posts WHERE state NOT IN (\(gone))").compactMap { $0.string("video_id") })
  }

  /// Settings as rounds 1–6 read them (a row without `defaults.hashtagSetIds`, or no row, meant ["amapiano", "dj"]).
  static func oldSettings(_ store: Store) throws -> (Settings, needsIds: Bool) {
    var s = try store.settings()
    let raw = try store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json")
    let obj = raw.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    let has: Bool = {
      guard let obj else { return false }
      if let d = obj["defaults"] as? [String: Any] { return d["hashtagSetIds"] is [String] }
      return obj["defaultHashtagSetIds"] is [String]
    }()
    if !has { s.defaults.hashtagSetIds = Defaults.legacyDefaultHashtagSetIds }
    return (s, !has)
  }

  /// The caption exactly as rounds 1–6 built it (a written caption without `{hashtags}` got "\n" + tags appended).
  static func legacyCaption(_ p: Platform, _ v: ResolvedVersion, _ video: Video, _ session: String, _ sets: [HashtagSet],
                            _ templates: [CaptionTemplate], _ settings: Settings) -> String {
    if let o = v.platformCaptions[p], !o.isEmpty { return o }
    let tags = Captions.hashtags(v, sets: sets)
    if !v.caption.isEmpty, !v.caption.contains("{hashtags}") {
      return tags.isEmpty ? v.caption : v.caption + "\n" + tags.joined(separator: " ")
    }
    return Captions.build(p, v, video, session, tags, templates, settings)
  }

  static func isBlank(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  @discardableResult
  static func run(_ store: Store) throws -> Report {
    var report = Report()
    let legacy = Set(Defaults.legacyHashtagSets.map(\.id))
    let allSets = try store.hashtagSets()
    let keptSets = allSets.filter { !legacy.contains($0.id) }
    let templates = try store.captionTemplates()
    let (old, needsIds) = try oldSettings(store)
    let posted = try clipsWithPosts(store)
    let sessions = Dictionary(try store.sessions().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let withVersions = Set(try store.db.query("SELECT DISTINCT video_id FROM versions").compactMap { $0.string("video_id") })
    let candidates = try store.videos().filter { withVersions.contains($0.id) || posted.contains($0.id) }

    // What every post clip says today, per version number and platform (old rules, old data).
    struct Out: Equatable { var captions: [Platform: String]; var tags: [String]; var title: String }
    func outputs(_ v: Video, _ vs: [Version], _ s: Settings, _ sets: [HashtagSet], legacyRules: Bool) -> [Int: Out] {
      var numbers = Set(vs.map(\.number)); numbers.insert(1)
      var out: [Int: Out] = [:]
      for n in numbers.sorted() {
        let r = VersionResolver.resolve(vs.isEmpty ? [Version(number: 1)] : vs, number: n, settings: s, video: v)
        var caps: [Platform: String] = [:]
        for p in Platform.allCases {
          caps[p] = legacyRules
            ? legacyCaption(p, r, v, sessions[v.sessionId] ?? "", sets, templates, s)
            : Captions.caption(for: p, version: r, video: v, sessionName: sessions[v.sessionId] ?? "", sets: sets,
                               templates: templates, settings: s)
        }
        out[n] = Out(captions: caps, tags: Captions.hashtags(r, sets: sets), title: Captions.youtubeTitle(r, video: v, settings: s))
      }
      return out
    }
    var before: [String: [Int: Out]] = [:]
    for v in candidates where posted.contains(v.id) {
      before[v.id] = outputs(v, try store.versions(videoId: v.id), old, allSets, legacyRules: true)
    }

    try store.db.transaction {
      // 1. Identity step.
      if needsIds {
        var s = try store.settings()
        s.defaults.hashtagSetIds = Defaults.legacyDefaultHashtagSetIds
        try store.save(s)
      }
      for v in candidates {
        for var ver in try store.versions(videoId: v.id) where !isBlank(ver.caption) && !(ver.caption ?? "").contains("{hashtags}") {
          ver.caption = (ver.caption ?? "") + Captions.legacySuffix
          try store.db.run("UPDATE versions SET json=? WHERE video_id=? AND number=?", [JSONCoding.string(ver), v.id, ver.number])
          report.suffixed += 1
        }
      }
      // 2. The journaled batch.
      let bulk = BulkActions(store: store)
      let r = try bulk.record("hashtag-groups-migration", ids: candidates.map(\.id), settings: true, hashtagGroups: true,
                              revalidate: false) {
        for v in candidates {
          var vs = try store.versions(videoId: v.id)
          if posted.contains(v.id) {
            if !vs.contains(where: { $0.number == 1 }) { vs.insert(Version(number: 1), at: 0) }
            let resolved = vs.map { VersionResolver.resolve(vs, number: $0.number, settings: old, video: v) }
            for (i, r) in resolved.enumerated() {
              vs[i].hashtagSetIds = []
              vs[i].extraHashtags = Captions.hashtags(r, sets: allSets)
            }
            report.frozen.append(v.id)
          } else {
            for i in vs.indices {
              guard let ids = vs[i].hashtagSetIds, ids.contains(where: legacy.contains) else { continue }
              let kept = ids.filter { !legacy.contains($0) }
              vs[i].hashtagSetIds = kept.isEmpty && vs[i].number == 1 ? nil : kept
              report.dropped.append(v.id)
            }
          }
          for ver in vs { try store.save(ver, videoId: v.id) }
        }
        var s = try store.settings()
        s.defaults.hashtagSetIds = s.defaults.hashtagSetIds.filter { !legacy.contains($0) }
        try store.save(s)
        for id in legacy { try store.deleteHashtagSet(id) }
        // Proof for every post clip; a platform that would still read differently keeps its old caption as its own.
        let now = try store.settings()
        for v in candidates where posted.contains(v.id) {
          guard let b = before[v.id] else { continue }
          var vs = try store.versions(videoId: v.id)
          let a = outputs(v, vs, now, keptSets, legacyRules: false)
          for (n, ob) in b where a[n]?.captions != ob.captions {
            guard let i = vs.firstIndex(where: { $0.number == n }) else { continue }
            var pc = vs[i].platformCaptions ?? [:]
            for p in Platform.allCases where a[n]?.captions[p] != ob.captions[p] { pc[p] = ob.captions[p] }
            vs[i].platformCaptions = pc
            try store.save(vs[i], videoId: v.id)
            vs = try store.versions(videoId: v.id)
            report.pinnedPlatformCaptions.append("\(v.id) v\(n)")
          }
          let final = outputs(v, try store.versions(videoId: v.id), now, keptSets, legacyRules: false)
          guard final == b else {
            throw EngineError("schema 6: captions of \(v.id) would change — migration stopped, nothing was changed")
          }
        }
        try store.db.exec("PRAGMA user_version = 6")
      }
      report.batchId = r.batchId
    }
    return report
  }
}
