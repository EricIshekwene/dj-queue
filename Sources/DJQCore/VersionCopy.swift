import Foundation

/// Round 27 (Eric, 2026-11-12): "If I create a new version, no edits from the previous version should affect the second
/// version." A version made from another is a complete copy of what that one shows, then stands on its own
/// (`Version.standalone`): nothing carries forward into it any more, and editing either never changes the other.
///
/// What a copy takes (DECISIONS-R27-VERSIONS.md): every text with its words, look, place and timing (a text that runs
/// the whole clip still does), "No text", and the whole caption (written caption, template, hashtag groups, extra tags,
/// YouTube title and template, per-platform captions). The on-video words are always pinned, even when the source
/// shows the Title. Every other field the source leaves on the defaults stays on the defaults.
/// Copied texts get their own ids. It never takes posting state: "Ready to repost" starts off, and posts, schedules and
/// Postiz jobs belong to their version number, so a new number has none. Crop, cover, aspect, markers and platforms
/// aren't per version: they are one edit for the clip (round 20), shared by every version. The trim is the clip's
/// unless a version has its own (round 30): a copy of such a version takes its own trim too.
public enum VersionCopy {
  /// A new version `number`: a copy of version `source` as `all` resolves it today, standing alone.
  /// `newIds: false` keeps the copied texts' ids, for a caller that applies an edit by id straight after (the copy is
  /// then written over a version the caller's resolution already showed).
  public static func duplicate(_ all: [Version], source: Int, as number: Int, settings: Settings,
                               video: Video? = nil, newIds: Bool = true) -> Version {
    let base = all.first { $0.number == source } ?? Version(number: source)
    var v = standingAlone(base, in: all.contains { $0.number == source } ? all : all + [base], settings: settings,
                          video: video, alwaysOwn: true)
    // The words on the video are what makes a version: a copy keeps the ones it shows even when the source follows
    // the clip's Title (or "No text" by default), so a later Title edit can't change the copy's video.
    let shown = VersionResolver.resolve(all.contains { $0.number == source } ? all : all + [base], number: source,
                                        settings: settings, video: video)
    if shown.isDefault("text") { v.text = shown.text; v.noText = shown.noText }
    v.number = number
    v.repostReady = nil
    v.captionsOwn = nil
    v.standalone = true
    if newIds, let more = v.moreText { v.moreText = more.map { var l = $0; l.id = TextLayer.newId(); return l } }
    return v
  }

  /// `v` (one of `all`) with everything it takes from earlier versions copied in and marked `standalone`, so it shows
  /// exactly what it showed and nothing earlier reaches it again. Copied texts get their own ids. v1 is returned as
  /// it is: nothing comes before it. `alwaysOwn` marks a v1 standalone too (for a copy made from it).
  public static func standingAlone(_ v: Version, in all: [Version], settings: Settings, video: Video? = nil,
                                   alwaysOwn: Bool = false) -> Version {
    guard v.number > 1 || alwaysOwn else { return v }
    guard v.standalone != true else { return v }
    let r = VersionResolver.resolve(all, number: v.number, settings: settings, video: video)
    let from = r.inherited
    var p = v
    if from.contains("text") || from.contains("noText") { p.text = r.text; p.noText = r.noText }
    if from.contains("style") { p.style = r.style }
    if from.contains("size") { p.size = r.size }
    if from.contains("posX") { p.posX = r.posX }
    if from.contains("posY") { p.posY = r.posY }
    if from.contains("align") { p.align = r.align }
    if from.contains("textStart") { p.textStart = r.textStart }
    if from.contains("textEnd") { p.textEnd = r.textEnd }
    if from.contains("moreText") { p.moreText = r.moreText.map { var l = $0; l.id = TextLayer.newId(); return l } }
    if from.contains("textLook") { p.textLook = r.textLook ?? TextLook() }
    if from.contains("caption") { p.caption = r.caption }
    if from.contains("captionTemplateId") { p.captionTemplateId = r.captionTemplateId }
    if from.contains("hashtagSetIds") { p.hashtagSetIds = r.hashtagSetIds }
    if from.contains("extraHashtags") { p.extraHashtags = r.extraHashtags }
    if from.contains("youtubeTitle") { p.youtubeTitle = r.youtubeTitle }
    if from.contains("platformCaptions") { p.platformCaptions = r.platformCaptions }
    if from.contains("youtubeTitleTemplateId") { p.youtubeTitleTemplateId = r.youtubeTitleTemplateId }
    p.standalone = true
    return p
  }

  /// Every v2 and later in `all` that still follows an earlier version, standing alone (only the ones that change).
  /// nil when that would change what any version shows; then nothing should be written.
  public static func separated(_ all: [Version], settings: Settings, video: Video? = nil) -> [Version]? {
    let changed = all.filter { $0.number > 1 && $0.standalone != true }
      .map { standingAlone($0, in: all, settings: settings, video: video) }
    guard !changed.isEmpty else { return [] }
    let after = all.map { v in changed.first { $0.number == v.number } ?? v }
    for n in Set(all.map(\.number)).union([1]) {
      let a = VersionResolver.resolve(all.isEmpty ? [Version(number: 1)] : all, number: n, settings: settings, video: video)
      let b = VersionResolver.resolve(after.isEmpty ? [Version(number: 1)] : after, number: n, settings: settings, video: video)
      guard face(a) == face(b) else { return nil }
    }
    return changed
  }

  /// What a resolved version shows: everything except where its fields came from and its texts' ids.
  public static func face(_ r: ResolvedVersion) -> ResolvedVersion {
    var x = r
    x.inherited = []
    x.moreText = x.moreText.map { var l = $0; l.id = ""; return l }
    return x
  }
}

/// Schema 11: every v2 and later stands alone (`VersionCopy.separated`), in one journaled batch (`djq bulk undo`).
/// Writes only the versions' JSON and keeps `updated_at`: nothing a version shows changes, so no preview redraws.
enum VersionSeparationMigration {
  static let action = "separate-versions"

  struct Result { var clips: [String] = []; var versions = 0; var leftAsIs: [String] = []; var batchId: String? }

  static func run(_ store: Store) throws -> Result {
    var out = Result()
    let settings = try store.settings()
    var writes: [(String, [Version])] = []
    let ids = try store.db.query("SELECT DISTINCT video_id FROM versions WHERE number > 1 ORDER BY video_id")
      .compactMap { $0.string("video_id") }
    for id in ids {
      guard let all = try? store.versions(videoId: id) else { out.leftAsIs.append(id); continue }  // Doctor reports it
      guard let sep = VersionCopy.separated(all, settings: settings, video: try store.video(id: id)) else {
        out.leftAsIs.append(id)
        Log.shared.error("schema 11: \(id) left as it was (standing alone would change what a version shows)")
        continue
      }
      if !sep.isEmpty { writes.append((id, sep)) }
    }
    try store.db.transaction {
      if !writes.isEmpty {
        let r = try BulkActions(store: store).record(action, ids: writes.map(\.0), revalidate: false) {
          for (id, vs) in writes {
            for v in vs {
              try store.db.run("UPDATE versions SET json=? WHERE video_id=? AND number=?", [JSONCoding.string(v), id, v.number])
            }
          }
        }
        out.batchId = r.batchId
        out.clips = writes.map(\.0)
        out.versions = writes.reduce(0) { $0 + $1.1.count }
      }
      try store.db.exec("PRAGMA user_version = 11")
    }
    return out
  }
}
