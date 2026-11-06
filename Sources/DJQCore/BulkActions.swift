import CoreGraphics
import Foundation

/// Sections of an edit that "Apply defaults" resets (clears the overrides so the clip follows Settings.defaults).
public enum BulkSection: String, Codable, Sendable, CaseIterable {
  /// Aspect, and the crop re-fitted to the default anchor (confirmed when the source size is known).
  case frame
  /// Trim in/out and per-platform trims.
  case trim
  /// v1 text, No text, style, size, position, alignment, timing.
  case text
  /// Cover time and "include text on cover".
  case cover
  /// v1 caption, template, hashtag sets, extra hashtags, YouTube title, per-platform captions.
  case caption
  /// Per-clip platform skips / turn-ons.
  case platforms
}

/// Result of a bulk action (also what `djq bulk … --json` prints).
public struct BulkResult: Codable, Sendable {
  /// Journal id for `undo`; nil for dry runs and when nothing changed.
  public var batchId: String?
  public var action: String
  public var dryRun: Bool
  public var videoIds: [String]
  public var changed: [String]
  /// Clip id → why it was left alone.
  public var skipped: [String: String]
  /// Clip id → what still keeps it from being ready, after the action (changed clips only; make-ready reports
  /// every clip it looked at, changed or not).
  public var remainingIssues: [String: [ValidationIssue]]
  public var summary: String
  /// Make-ready only: where each clip it looked at stands afterwards (from `remainingIssues`).
  public var outlook: ReadyOutlook? = nil
  /// Remove from queue only: clip id → the days and platforms taken out of the plan (changed clips with any).
  public var unplanned: [String: [Planner.UnplanItem]]? = nil
  /// Stage moves only (`back` / `forward`): clip id → where it was, where it ended up, and what happened.
  public var moves: [String: StageMove]? = nil
}

/// Where clips stand after "Make ready with defaults" (every non-skipped clip, changed or not).
public struct ReadyOutlook: Codable, Sendable, Equatable {
  /// No issues left: the clip is ready.
  public var ready: [String]
  /// No Title, so the default text is empty ("Add text (no title yet)") — fixed by a title, nothing else.
  public var needTitle: [String]
  /// Anything else still open (and clips with no title that ALSO have other issues).
  public var other: [String]
  /// Round 4: nothing missing in the edit, but no score yet — it's in Score, not the Queue.
  public var needScore: [String] = []

  public init(ready: [String] = [], needTitle: [String] = [], other: [String] = [], needScore: [String] = []) {
    self.ready = ready; self.needTitle = needTitle; self.other = other; self.needScore = needScore
  }

  /// Sorts clips by their remaining issues (`hasTitle`: the clip has a Title).
  public static func classify(_ issues: [(id: String, issues: [ValidationIssue], hasTitle: Bool)]) -> ReadyOutlook {
    classify(issues.map { (id: $0.id, issues: $0.issues, hasTitle: $0.hasTitle, hasScore: true) })
  }

  /// Same, and an unscored clip with nothing missing counts as `needScore` (it goes to Score, not the Queue).
  public static func classify(_ issues: [(id: String, issues: [ValidationIssue], hasTitle: Bool, hasScore: Bool)]) -> ReadyOutlook {
    var o = ReadyOutlook()
    for c in issues {
      if c.issues.isEmpty { if c.hasScore { o.ready.append(c.id) } else { o.needScore.append(c.id) } }
      else if !c.hasTitle, c.issues.allSatisfy({ $0.kind == .noText }) { o.needTitle.append(c.id) }
      else { o.other.append(c.id) }
    }
    return o
  }

  /// "3 to the Queue · 58 still need a title · 2 other issues" (zero parts dropped, except "0 to the Queue" when
  /// alone). Round 4: no "ready" wording — readiness is the stage.
  public var summary: String {
    var parts = ["\(ready.count) to the Queue"]
    if !needTitle.isEmpty { parts.append("\(needTitle.count) still need\(needTitle.count == 1 ? "s" : "") a title") }
    if !other.isEmpty { parts.append("\(other.count) other issue\(other.count == 1 ? "" : "s")") }
    if !needScore.isEmpty { parts.append("\(needScore.count) still need\(needScore.count == 1 ? "s" : "") a score") }
    return parts.joined(separator: " · ")
  }
}

/// One journal row.
public struct BatchRecord: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var action: String
  public var params: [String: String]
  public var videoIds: [String]
  public var summary: String
  public var createdAt: Date
  /// Set only when everything in the batch was restored.
  public var undoneAt: Date?
  /// Clip ids (and "#plan") already restored by a partial undo.
  public var restored: [String] = []
}

/// Bulk editing (round 2 #11). Every action runs in ONE transaction, logs a per-clip event, and records a batch
/// journal entry with before/after snapshots so `undo(batchId)` restores exactly what it changed. `dryRun`
/// runs the action and rolls it back, returning what would change.
///
/// Undo refuses (per clip, or the whole plan part) when something else changed the same data after the batch,
/// unless `force` — so an undo never silently overwrites Eric's later work.
public final class BulkActions: @unchecked Sendable {
  let store: Store
  /// Post `ChangeSignal` after a committed batch (the app sets this; `djq` posts it itself).
  public var postsChangeSignal = false
  /// Source picture size for the default crop when the video's size isn't cached (default: ffprobe).
  public var sourceSize: (@Sendable (Store, Video) -> CGSize?) = { store, v in Media.sourceSize(store: store, video: v) }

  public init(store: Store) { self.store = store }

  // MARK: Clip edits

  /// Edit's bulk "Send to Queue with defaults": `send` for each clip, so every clip with nothing left to fix goes to the
  /// Queue. Text, caption, cover and the rest already follow the defaults (clips store only overrides), so nothing
  /// Eric customised is touched. `remainingIssues` / `outlook` cover every clip it looked at (changed or not), so
  /// the UI can say truthfully how many end up ready and how many still need a title. It takes the plan in its journal
  /// so undo also takes back the days the scheduler gave them.
  @discardableResult
  public func makeReadyWithDefaults(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    try run("make-ready", ids: ids, dryRun: dryRun, plan: true, reportsAll: true) { _, v, s in try send(v, s) }
  }

  /// The one door Edit → Queue (round 13, A11): every Send to Queue, for one clip or many, comes here. Clears "sent back",
  /// confirms the default crop, and sends the clip only when it has a score and nothing is left to fix. A clip that stays
  /// in Edit stays unsent, so fixing it later doesn't promote it.
  func send(_ v: Video, _ s: Settings) throws -> Outcome {
    if v.excluded { return .skipped("excluded — include it first") }
    var changed = false
    if v.heldInEdit {
      try store.setHeldInEdit(v.id, false)
      changed = true
    }
    let cur = try store.video(id: v.id) ?? v
    switch try confirmDefaultCrop(cur, s) {
    case .changed: changed = true
    case .skipped(let why) where !changed: return .skipped(why)
    default: break
    }
    let after = try store.video(id: v.id) ?? cur
    if !after.sentToQueue, after.score != nil, try Validation.issues(video: after, store: store).isEmpty {
      try store.setSentToQueue(v.id, true)
      changed = true
    }
    return changed ? .changed : .unchanged
  }

  /// Confirms the default crop when none is set.
  func confirmDefaultCrop(_ v: Video, _ s: Settings) throws -> Outcome {
    guard v.type == .short else { return .skipped("long-form") }
    if v.missing { return .skipped("file missing") }
    var e = try store.edit(videoId: v.id)
    guard e.crop == nil else { return .unchanged }
    guard let size = try cachedOrProbedSize(v) else { return .skipped("can't read the clip's size to place the crop") }
    e.crop = s.defaults.defaultCrop(source: size, aspect: e.aspectOverride ?? s.defaults.aspect,
                                    lastUsed: s.defaults.cropAnchor == .lastUsed ? try store.lastCropCentre() : nil)
    try store.save(e, videoId: v.id)
    return .changed
  }

  /// Clears the overrides of `sections` so the clips follow the defaults again.
  @discardableResult
  public func applyDefaults(_ ids: [String], sections: Set<BulkSection> = Set(BulkSection.allCases),
                            dryRun: Bool = false) throws -> BulkResult {
    try run("apply-defaults", ids: ids, params: ["sections": sections.map(\.rawValue).sorted().joined(separator: ",")],
            dryRun: dryRun) { _, v, s in
      guard v.type == .short else { return .skipped("long-form") }
      var e = try store.edit(videoId: v.id)
      let e0 = e
      if sections.contains(.frame) {
        e.aspectOverride = nil
        if e.crop != nil {
          e.crop = try cachedOrProbedSize(v).map {
            s.defaults.defaultCrop(source: $0, aspect: s.defaults.aspect,
                                   lastUsed: s.defaults.cropAnchor == .lastUsed ? try store.lastCropCentre() : nil)
          }
        }
      }
      if sections.contains(.trim) { e.trimIn = nil; e.trimOut = nil; e.platformTrims = [:] }
      if sections.contains(.cover) { e.coverTime = nil; e.coverIncludesTextOverride = nil }
      if sections.contains(.platforms) { e.skippedPlatforms = []; e.includedPlatforms = [] }
      var changed = false
      if e != e0 { try store.save(e, videoId: v.id); changed = true }
      if var v1 = try store.versions(videoId: v.id).first(where: { $0.number == 1 }) {
        let o = v1
        if sections.contains(.text) {
          v1.text = nil; v1.noText = nil; v1.style = nil; v1.size = nil; v1.posX = nil; v1.posY = nil
          v1.align = nil; v1.textStart = nil; v1.textEnd = nil
        }
        if sections.contains(.caption) {
          v1.caption = nil; v1.captionTemplateId = nil; v1.hashtagSetIds = nil; v1.extraHashtags = nil
          v1.youtubeTitle = nil; v1.platformCaptions = nil; v1.youtubeTitleTemplateId = nil
        }
        if v1 != o { try store.save(v1, videoId: v.id); changed = true }
      }
      return changed ? .changed : .unchanged
    }
  }

  @discardableResult
  public func setScore(_ ids: [String], _ score: Int?, dryRun: Bool = false) throws -> BulkResult {
    try run("score", ids: ids, params: ["score": score.map(String.init) ?? "clear"], dryRun: dryRun) { _, v, _ in
      let new = score.map { min(100, max(0, $0)) }
      guard v.score != new else { return .unchanged }
      try store.setScore(v.id, new)
      try store.refreshState(videoId: v.id)
      return .changed
    }
  }

  /// Adds `delta` to each clip's score (0…100). Unscored clips are skipped.
  @discardableResult
  public func adjustScore(_ ids: [String], by delta: Int, dryRun: Bool = false) throws -> BulkResult {
    try run("score-adjust", ids: ids, params: ["delta": String(delta)], dryRun: dryRun) { _, v, _ in
      guard let s = v.score else { return .skipped("not scored yet") }
      let new = min(100, max(0, s + delta))
      guard new != s else { return .unchanged }
      try store.setScore(v.id, new)
      try store.refreshState(videoId: v.id)
      return .changed
    }
  }

  @discardableResult
  public func setKind(_ ids: [String], _ kind: Kind, dryRun: Bool = false) throws -> BulkResult {
    try run("kind", ids: ids, params: ["kind": kind.rawValue], dryRun: dryRun) { _, v, _ in
      guard v.kind != kind else { return .unchanged }
      try store.setKind(v.id, kind)
      return .changed
    }
  }

  @discardableResult
  public func setExcluded(_ ids: [String], _ excluded: Bool, dryRun: Bool = false) throws -> BulkResult {
    try run(excluded ? "exclude" : "include", ids: ids, dryRun: dryRun) { _, v, _ in
      guard v.excluded != excluded else { return .unchanged }
      try store.setExcluded(v.id, excluded)
      return .changed
    }
  }

  /// Sets v1's caption template (nil = back to the default) and clears a written v1 caption so it takes effect.
  @discardableResult
  public func setCaptionTemplate(_ ids: [String], _ templateId: String?, dryRun: Bool = false) throws -> BulkResult {
    if let t = templateId, try !store.captionTemplates().contains(where: { $0.id == t }) {
      throw EngineError("No caption template \(t)")
    }
    return try run("caption-template", ids: ids, params: ["template": templateId ?? "default"], dryRun: dryRun) { _, v, _ in
      try updateV1(v) { $0.captionTemplateId = templateId; $0.caption = nil }
    }
  }

  /// Sets v1's YouTube title template (nil = the default template) and clears a typed v1 YouTube title so it takes
  /// effect (round 7).
  @discardableResult
  public func setYouTubeTitleTemplate(_ ids: [String], _ templateId: String?, dryRun: Bool = false) throws -> BulkResult {
    if let t = templateId, try !store.settings().youtubeTitleTemplates.contains(where: { $0.id == t }) {
      throw EngineError("No YouTube title template \(t)")
    }
    return try run("youtube-title-template", ids: ids, params: ["template": templateId ?? "default"], dryRun: dryRun) { _, v, _ in
      try updateV1(v) { $0.youtubeTitleTemplateId = templateId; $0.youtubeTitle = nil }
    }
  }

  /// Sets v1's hashtag groups (nil = the default groups).
  @discardableResult
  public func setHashtagSets(_ ids: [String], _ setIds: [String]?, dryRun: Bool = false) throws -> BulkResult {
    if let s = setIds {
      let known = Set(try store.hashtagSets().map(\.id))
      if let bad = s.first(where: { !known.contains($0) }) {
        throw EngineError("No hashtag group \(bad)" + (known.isEmpty ? " — there are no hashtag groups yet (djq hashtag-groups add)" : " (djq hashtag-groups lists them)"))
      }
    }
    return try run("hashtag-sets", ids: ids, params: ["sets": setIds?.joined(separator: ",") ?? "default"], dryRun: dryRun) { _, v, s in
      try updateV1Retagged(v, s) { $0.hashtagSetIds = setIds }
    }
  }

  /// Sets v1's extra hashtags (nil = the default extras).
  @discardableResult
  public func setExtraHashtags(_ ids: [String], _ tags: [String]?, dryRun: Bool = false) throws -> BulkResult {
    try run("extra-hashtags", ids: ids, params: ["extra": tags?.joined(separator: " ") ?? "default"], dryRun: dryRun) { _, v, s in
      try updateV1Retagged(v, s) { $0.extraHashtags = tags }
    }
  }

  /// Writes each clip's caption for `platform` without hashtags as that platform's override ("Drop hashtags for X").
  @discardableResult
  public func dropHashtags(_ ids: [String], platform: Platform, dryRun: Bool = false) throws -> BulkResult {
    try run("drop-hashtags", ids: ids, params: ["platform": platform.rawValue], dryRun: dryRun) { _, v, s in
      guard let r = try store.resolvedVersion(videoId: v.id, number: 1, settings: s) else { return .skipped("no version") }
      let bare = Captions.withoutHashtags(for: platform, version: r, video: v, sessionName: try store.sessionName(for: v),
                                          templates: try store.captionTemplates(), settings: s, sets: try store.hashtagSets())
      return try updateV1(v) { var pc = $0.platformCaptions ?? r.platformCaptions; pc[platform] = bare; $0.platformCaptions = pc }
    }
  }

  /// Skips (or posts again on) `platform` for each clip.
  @discardableResult
  public func setPlatform(_ ids: [String], _ platform: Platform, skipped: Bool, dryRun: Bool = false) throws -> BulkResult {
    try run(skipped ? "skip-platform" : "unskip-platform", ids: ids, params: ["platform": platform.rawValue],
            dryRun: dryRun) { _, v, s in
      var e = try store.edit(videoId: v.id)
      let o = e
      if skipped {
        e.skippedPlatforms.insert(platform)
        e.includedPlatforms.remove(platform)
      } else {
        e.skippedPlatforms.remove(platform)
        if !s.defaults.platforms.contains(platform) { e.includedPlatforms.insert(platform) }
      }
      guard e != o else { return .unchanged }
      try store.save(e, videoId: v.id)
      return .changed
    }
  }

  /// Sets the title (nil clears it) on every clip.
  @discardableResult
  public func setTitle(_ ids: [String], _ title: String?, dryRun: Bool = false) throws -> BulkResult {
    try run("title", ids: ids, params: ["title": title ?? ""], dryRun: dryRun) { _, v, _ in
      let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard v.titleText != ((t?.isEmpty ?? true) ? nil : t) else { return .unchanged }
      try store.setTitle(v.id, title)
      return .changed
    }
  }

  /// Sets each clip's Title to its raw marker tag, verbatim (Eric's explicit choice; no tidying). Clips that
  /// already have a title are skipped.
  @discardableResult
  public func useRawTagAsTitle(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    try run("title-raw-tag", ids: ids, dryRun: dryRun) { _, v, _ in
      if v.titleText != nil { return .skipped("already has a title") }
      try store.setTitle(v.id, v.tag, source: "raw tag")
      return .changed
    }
  }

  /// Makes each clip's best suggestion its title. Clips that already have a title, or no suggestions, are skipped.
  @discardableResult
  public func acceptTopTitleSuggestion(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    try run("accept-title", ids: ids, dryRun: dryRun) { _, v, _ in
      if v.titleText != nil { return .skipped("already has a title") }
      guard let top = try store.titleSuggestions(videoId: v.id).first else { return .skipped("no suggestions") }
      try store.setTitle(v.id, top.text, tracks: top.tracks.isEmpty ? nil : top.tracks, source: "suggestion")
      return .changed
    }
  }

  // MARK: Plan

  /// Puts each clip on the first day of `week` (today on) with a free slot, pinned there.
  @discardableResult
  public func addToWeek(_ ids: [String], week: String, dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    return try run("add-to-week", ids: ids, params: ["week": week], dryRun: dryRun, plan: true) { _, v, s in
      let dm = DayMath(settings: s)
      let today = store.today(dm)
      if try !store.planSlots(where: "video_id=? AND date>=?", [v.id, today]).isEmpty { return .skipped("already planned") }
      let perDay = max(1, s.postsPerDay)
      guard let day = try dm.weekDays(dm.weekStart(of: dm.date(week))).first(where: { d in
        try d >= today && store.planSlots(where: "date=?", [d]).count < perDay
      }) else { return .skipped("no free day left in the week of \(week)") }
      try planner.pin(videoId: v.id, date: day)
      return .changed
    }
  }

  /// Pins clip 1 to `from`, clip 2 to the next day, … (in the order given).
  @discardableResult
  public func pinConsecutive(_ ids: [String], from date: String, dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    var day = date
    return try run("pin-consecutive", ids: ids, params: ["from": date], dryRun: dryRun, plan: true) { _, v, s in
      let dm = DayMath(settings: s)
      defer { day = dm.addDays(day, 1) }
      try planner.pin(videoId: v.id, date: day)
      return .changed
    }
  }

  /// Post today (in the order given; clips beyond today's free slots are skipped with the reason).
  @discardableResult
  public func postToday(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    return try run("post-today", ids: ids, dryRun: dryRun, plan: true) { _, v, _ in
      try planner.postToday(videoId: v.id)
      return .changed
    }
  }

  /// "Remove from queue": sends each clip back to Edit (`Video.heldInEdit`, issue "Sent back from Queue") and takes
  /// it out of the plan with `Planner.unplan` — slots from today on that have nothing posted, and every post of the
  /// clip still in flight; posted/terminal posts and history stay, a pinned slot loses its pin, other clips keep
  /// their days. `unplanned` lists what went per clip. Undo restores the flag, slots, weeks and posts exactly.
  @discardableResult
  public func removeFromQueue(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    var removed: [String: [Planner.UnplanItem]] = [:]
    var r = try run("unqueue", ids: ids, dryRun: dryRun, plan: true) { _, v, _ in
      guard v.type == .short else { return .skipped("long-form — it's uploaded by hand, never queued") }
      if v.excluded { return .skipped("excluded — it isn't in the queue") }
      if v.score == nil { return .skipped("not scored yet — it isn't in the queue") }
      if v.heldInEdit { return .unchanged }
      if let why = try postedBlocker(v) { return .skipped(why) }
      let items = try hold(v, planner: planner)
      if !items.isEmpty { removed[v.id] = items }
      return .changed
    }
    let kept = removed.filter { r.changed.contains($0.key) }
    r.unplanned = kept
    if !kept.isEmpty {
      let n = kept.values.reduce(0) { $0 + $1.count }
      r.summary += " · \(n) scheduled day\(n == 1 ? "" : "s") removed"
    }
    return r
  }

  /// Why a clip can't leave the plan (Back to Edit): something already posted, or every
  /// platform finished. nil = it can.
  public func postedBlocker(_ v: Video) throws -> String? {
    if let p = try store.posts(where: "video_id=? AND kind IN ('regular','retry') AND state='posted'", [v.id], order: "posted_at").first {
      return "Already posted on \(p.platform.displayName) — it can't leave the plan; skip or reset its posts in Posts"
    }
    // `.posting` is derived from due/overdue posts too — only something actually posted blocks. A finished clip
    // (every platform posted, skipped or failed) has nothing left in the plan to remove.
    if [.posted, .partial].contains(v.state) {
      return "Every platform is finished — nothing left in the plan to remove; repost or reset a post in Posts instead"
    }
    return nil
  }

  /// Remove-from-queue's per-clip step: out of the plan, then held in Edit.
  func hold(_ v: Video, planner: Planner) throws -> [Planner.UnplanItem] {
    try store.takeBackAutoRetries(videoId: v.id)
    let items = try planner.unplan(videoId: v.id)
    try store.setHeldInEdit(v.id, true)
    return items
  }

  /// "Send to Queue" for any Edit clip, held or not (`send`): it goes to the Queue when nothing is left to fix, otherwise
  /// it stays in Edit with its real issues. Clips past Edit are left alone. The plan is in the journal so undo also takes
  /// back the day the scheduler gave it.
  @discardableResult
  public func sendToQueue(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    try run("requeue", ids: ids, dryRun: dryRun, plan: true) { _, v, s in
      guard v.type == .short else { return .skipped("long-form — it's uploaded by hand, never queued") }
      if v.excluded { return .skipped("excluded — include it first") }
      if v.score == nil { return .skipped("not scored yet — give it a score first") }
      guard ClipStage.of(v) == .edit else { return .unchanged }
      let sent = try send(v, s)
      guard case .unchanged = sent else { return sent }
      let issues = try Validation.issues(video: try store.video(id: v.id) ?? v, store: store)
      return issues.isEmpty ? .unchanged : .skipped(StageWording.stillInEdit(issues))
    }
  }

  /// Forces a fresh render: the clip's current renders are retired (files stay until replaced) and the engine
  /// renders again on its next tick. Undo un-retires them while their files still exist.
  @discardableResult
  public func reRender(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    try run("re-render", ids: ids, dryRun: dryRun, renders: true) { _, v, _ in
      let live = try store.renders(where: "deleted_at IS NULL AND status IN ('done','failed') AND video_id=?", [v.id])
      guard !live.isEmpty else { return .skipped("nothing rendered yet") }
      for r in live { try store.markRenderDeleted(id: r.id) }
      return .changed
    }
  }

  /// Adds or removes a part in each clip's v1 caption text (`CaptionParts`). A clip whose posts went out is skipped with the reason;
  /// a clip that's only scheduled is edited, like typing, and Postiz replaces its posts after the settle.
  @discardableResult
  public func togglePart(_ ids: [String], _ part: CaptionPart, dryRun: Bool = false) throws -> BulkResult {
    let sets = try store.hashtagSets(), templates = try store.captionTemplates()
    return try run("caption-part", ids: ids, params: ["part": part.rawValue], dryRun: dryRun) { _, v, s in
      if let why = CaptionParts.lockReason(posts: try store.posts(where: "video_id=?", [v.id], order: "id")) { return .skipped(why) }
      guard let r = try store.resolvedVersion(videoId: v.id, number: 1, settings: s),
            let next = CaptionParts.toggling(part, version: r, video: v, sessionName: try store.sessionName(for: v), sets: sets,
                                             templates: templates, settings: s) else { return .unchanged }
      return try updateV1(v) { $0.caption = next }
    }
  }

  // MARK: Single actions (journaled)

  /// Runs any app action (`body`) as one undoable journal entry — the same snapshot/restore machinery as the bulk
  /// ops: the clips in `ids`, plus the whole plan (slots, weeks, posts) when `plan`, plus the settings row when
  /// `settings`. Nothing changed = no batch (`batchId` nil). `changed` lists the clips whose snapshot differs plus
  /// every clip whose slots or posts differ. Used by AppModel so every one-click action has Undo and ⌘Z always
  /// undoes the most recent one (round 3, F8).
  @discardableResult
  public func record(_ action: String, ids raw: [String] = [], params: [String: String] = [:], plan: Bool = false,
                     settings: Bool = false, renders: Bool = false, hashtagGroups: Bool = false, captionTemplates: Bool = false,
                     revalidate: Bool = true,
                     _ body: () throws -> Void) throws -> BulkResult {
    var seen = Set<String>()
    let ids = raw.filter { !$0.isEmpty && seen.insert($0).inserted }
    var result = BulkResult(batchId: nil, action: action, dryRun: false, videoIds: ids, changed: [], skipped: [:],
                            remainingIssues: [:], summary: "")
    try store.db.transaction {
      var existing = try ids.filter { try store.video(id: $0) != nil }
      var before = Snapshot(clips: try existing.map { try clipSnapshot($0, renders: renders) },
                            plan: plan ? try planSnapshot() : nil, settings: settings ? try settingsSnapshot() : nil,
                            hashtagSets: hashtagGroups ? try store.hashtagSets() : nil,
                            captionTemplates: captionTemplates ? try store.captionTemplates() : nil)
      try body()
      // Round 4 (S1): a settings change (limits, platforms, defaults) can make Queue clips invalid — re-derive every
      // Edit/Queue clip's state now (states only). Clips it moves to Edit lose their sent flag, so the batch records
      // that: undoing the change brings them back to the Queue.
      if revalidate, settings || hashtagGroups || captionTemplates,
         try settingsSnapshot() != before.settings || (hashtagGroups && store.hashtagSets() != before.hashtagSets)
          || (captionTemplates && store.captionTemplates() != before.captionTemplates) {
        for id in try Revalidation(store: store).run(adjustPlan: false).movedToEdit.keys.sorted() where !existing.contains(id) {
          var was = try clipSnapshot(id, renders: renders)
          was.sent = true
          before.clips.append(was)
          existing.append(id)
        }
      }
      let after = Snapshot(clips: try existing.map { try clipSnapshot($0, renders: renders) },
                           plan: plan ? try planSnapshot() : nil, settings: settings ? try settingsSnapshot() : nil,
                           hashtagSets: hashtagGroups ? try store.hashtagSets() : nil,
                           captionTemplates: captionTemplates ? try store.captionTemplates() : nil)
      var changed = Set(zip(before.clips, after.clips).filter { $0 != $1 }.map(\.0.id))
      if let b = before.plan, let a = after.plan, b != a {
        let bs = Dictionary(uniqueKeysWithValues: b.slots.map { ($0.id, $0) }), asl = Dictionary(uniqueKeysWithValues: a.slots.map { ($0.id, $0) })
        for id in Set(bs.keys).union(asl.keys) where bs[id] != asl[id] { changed.formUnion([bs[id]?.videoId, asl[id]?.videoId].compactMap { $0 }) }
        let bp = Dictionary(uniqueKeysWithValues: b.posts.map { ($0.id, $0) }), ap = Dictionary(uniqueKeysWithValues: a.posts.map { ($0.id, $0) })
        for id in Set(bp.keys).union(ap.keys) where bp[id] != ap[id] { changed.formUnion([bp[id]?.videoId, ap[id]?.videoId].compactMap { $0 }) }
        if changed.isEmpty { changed.insert("") }  // weeks only (approve/propose): still a change
      }
      let settingsChanged = before.settings != after.settings || before.hashtagSets != after.hashtagSets
        || before.captionTemplates != after.captionTemplates
      guard !changed.isEmpty || settingsChanged else {
        result.summary = "\(action): nothing changed"
        return
      }
      changed.remove("")
      result.changed = changed.sorted()
      result.summary = "\(action): \(result.changed.count) clip\(result.changed.count == 1 ? "" : "s")"
        + (before.plan != nil && before.plan != after.plan ? " · plan" : "")
        + (before.settings != after.settings ? " · settings" : "") + (before.hashtagSets != after.hashtagSets ? " · hashtag groups" : "")
        + (before.captionTemplates != after.captionTemplates ? " · caption templates" : "")
      let batchId = newId()
      try store.db.run("""
        INSERT INTO batches(id,action,params,video_ids,before,after,summary,created_at) VALUES(?,?,?,?,?,?,?,?)
        """, [batchId, action, JSONCoding.string(params), JSONCoding.string(result.changed), JSONCoding.string(before),
              JSONCoding.string(after), result.summary, store.clock.now])
      for id in result.changed { try store.logEvent("action", "\(action) (batch \(batchId.prefix(8)))", videoId: id) }
      result.batchId = batchId
    }
    if postsChangeSignal && result.batchId != nil { ChangeSignal.post() }
    return result
  }

  /// A journal entry opened before a long interaction (the editor) and closed after it — see `begin`/`commit`.
  public struct OpenEntry: Sendable {
    public let action: String
    public let ids: [String]
    var before: Snapshot
    /// The journal's last row when this entry opened: group batches after it are never this entry's own.
    var startRow = 0
  }

  /// Snapshots `ids` now; `commit` later records ONE undoable batch for whatever changed in between (e.g. a whole
  /// editor session: every crop, trim, text, title and version change → one ⌘Z on the app's history).
  public func begin(_ action: String, ids raw: [String]) throws -> OpenEntry {
    var seen = Set<String>()
    let ids = try raw.filter { !$0.isEmpty && seen.insert($0).inserted }.filter { try store.video(id: $0) != nil }
    return OpenEntry(action: action, ids: ids, before: Snapshot(clips: try ids.map { try clipSnapshot($0, renders: false) }, plan: nil),
                     startRow: try store.db.one("SELECT COALESCE(MAX(rowid),0) AS n FROM batches")?.int("n") ?? 0)
  }

  /// `e` moved past every hashtag group edit or delete since it opened, whoever made it (the app, or `djq` from another
  /// process): their freezes are their own batch, so the entry never claims them and its undo can't un-freeze a clip.
  func rebasedOntoGroupChanges(_ e: OpenEntry) throws -> OpenEntry {
    var out = e
    let actions = (["hashtag-group-edit", "hashtag-group-delete"] + CaptionTemplates.batchActions).map { "'\($0)'" }.joined(separator: ",")
    for row in try store.db.query("""
      SELECT id FROM batches WHERE rowid>? AND undone_at IS NULL AND action IN (\(actions)) ORDER BY rowid
      """, [e.startRow]) {
      if let id = row.string("id") { out = try rebase(out, onto: id) }
    }
    return out
  }

  /// Records the batch for an `OpenEntry` (nil `batchId` when nothing changed). Only the clips that changed are
  /// journaled, so undo leaves the others alone; score, excluded and held are left to their own journaled actions.
  @discardableResult
  public func commit(_ e: OpenEntry) throws -> BulkResult {
    var result = BulkResult(batchId: nil, action: e.action, dryRun: false, videoIds: e.ids, changed: [], skipped: [:],
                            remainingIssues: [:], summary: "")
    let e = try rebasedOntoGroupChanges(e)
    try store.db.transaction {
      let now = try e.before.clips.map { try clipSnapshot($0.id, renders: false) }
      // Only the fields a long interaction owns (kind, title, edit, versions) are journaled here. Score, excluded and
      // held change only through actions that journal themselves (e.g. a stage move from the editor header), so the
      // session takes their current values and its undo never reverts or double-counts them.
      let pairs = zip(e.before.clips, now).map { b, n -> (ClipSnap, ClipSnap) in
        var b = b
        b.score = n.score; b.excluded = n.excluded; b.held = n.held; b.sent = n.sent
        return (b, n)
      }.filter { $0 != $1 }
      guard !pairs.isEmpty else { result.summary = "\(e.action): nothing changed"; return }
      let before = Snapshot(clips: pairs.map(\.0), plan: nil), after = Snapshot(clips: pairs.map(\.1), plan: nil)
      result.changed = pairs.map(\.0.id)
      result.summary = "\(e.action): \(result.changed.count) clip\(result.changed.count == 1 ? "" : "s")"
      let batchId = newId()
      try store.db.run("""
        INSERT INTO batches(id,action,params,video_ids,before,after,summary,created_at) VALUES(?,?,?,?,?,?,?,?)
        """, [batchId, e.action, JSONCoding.string([String: String]()), JSONCoding.string(result.changed), JSONCoding.string(before),
              JSONCoding.string(after), result.summary, store.clock.now])
      for id in result.changed { try store.logEvent("action", "\(e.action) (batch \(batchId.prefix(8)))", videoId: id) }
      result.batchId = batchId
    }
    return result
  }

  /// Closes `e` as its own batch (when anything changed) and opens a fresh entry on the same clips: call it before a
  /// journaled action runs inside a long interaction, so the history reads interaction₁ → action → interaction₂.
  public func split(_ e: OpenEntry) throws -> (BulkResult, OpenEntry) {
    let r = try commit(e)
    return (r, try begin(e.action, ids: e.ids))
  }

  /// Moves `e`'s starting point past batch `batchId` (a journaled action that ran while `e` was open): every
  /// interaction-owned field that batch changed starts from its result, so `e` never claims — or undoes — the
  /// action's change, and the action's own undo still finds its clip as it left it.
  public func rebase(_ e: OpenEntry, onto batchId: String) throws -> OpenEntry {
    guard let row = try store.db.one("SELECT before, after FROM batches WHERE id=?", [batchId]),
          let bs = row.string("before"), let asx = row.string("after"),
          let b = try? JSONCoding.decoder.decode(Snapshot.self, from: Data(bs.utf8)),
          let a = try? JSONCoding.decoder.decode(Snapshot.self, from: Data(asx.utf8)) else { return e }
    let bById = Dictionary(b.clips.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    let aById = Dictionary(a.clips.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    var out = e
    for i in out.before.clips.indices {
      let id = out.before.clips[i].id
      guard let x = bById[id], let y = aById[id] else { continue }
      if x.kind != y.kind { out.before.clips[i].kind = y.kind }
      if x.title != y.title || x.titleTracks != y.titleTracks || x.titleSource != y.titleSource {
        out.before.clips[i].title = y.title; out.before.clips[i].titleTracks = y.titleTracks
        out.before.clips[i].titleSource = y.titleSource
      }
      if x.edit != y.edit { out.before.clips[i].edit = y.edit }
      if x.versions != y.versions { out.before.clips[i].versions = y.versions }
    }
    return out
  }

  // MARK: Journal

  public func batches(limit: Int = 50) throws -> [BatchRecord] {
    try store.db.query("SELECT * FROM batches ORDER BY created_at DESC, rowid DESC LIMIT ?", [limit]).map(Self.batch)
  }

  static let planMarker = "#plan"

  public func batch(id: String) throws -> BatchRecord? {
    try store.db.one("SELECT * FROM batches WHERE id=?", [id]).map(Self.batch)
  }

  /// Restores what batch `id` changed. Clips changed again since are skipped (and the plan part refused) unless
  /// `force`.
  @discardableResult
  public func undo(_ id: String, force: Bool = false, dryRun: Bool = false) throws -> BulkResult {
    try undo(id, force: force, dryRun: dryRun, confirmGoLive: false)
  }

  /// Platforms that undoing batch `id` would put back on Postiz **live** (Postiz publisher, platform on and not paused,
  /// posting not paused, test run off) while they aren't now — and that have posts waiting to go out. Empty = the
  /// undo doesn't go live anywhere. The app and `djq bulk undo` ask this before offering the undo.
  public func undoWouldGoLive(_ id: String) throws -> [Platform] {
    guard let row = try store.db.one("SELECT * FROM batches WHERE id=?", [id]), let bs = row.string("before"),
          let before = try? JSONCoding.decoder.decode(Snapshot.self, from: Data(bs.utf8)),
          let json = before.settings?.json else { return [] }
    return try goLive(from: try store.settings(), to: Store.decodeSettings(json))
  }

  func goLive(from cur: Settings, to new: Settings) throws -> [Platform] {
    func live(_ p: Platform, _ s: Settings) -> Bool { PostizService.settingsAllow(p, s) && !s.publishing.testMode }
    var out: [Platform] = []
    for p in Platform.allCases.sorted() where live(p, new) && !live(p, cur) {
      if try !store.posts(where: "platform=? AND state IN ('planned','rendering','rendered','due')", [p.rawValue]).isEmpty { out.append(p) }
    }
    return out
  }

  /// Undo. When restoring the batch's settings would route waiting posts through Postiz for real (see
  /// `undoWouldGoLive`), it is refused unless `confirmGoLive` — an undo never goes live silently.
  @discardableResult
  public func undo(_ id: String, force: Bool = false, dryRun: Bool = false, confirmGoLive: Bool) throws -> BulkResult {
    guard let row = try store.db.one("SELECT * FROM batches WHERE id=?", [id]) else { throw EngineError("No batch \(id)") }
    let rec = Self.batch(row)
    if let u = rec.undoneAt { throw EngineError("Batch \(id.prefix(8)) was already undone (\(u))") }
    guard let bs = row.string("before"), let asx = row.string("after"),
          let before = try? JSONCoding.decoder.decode(Snapshot.self, from: Data(bs.utf8)),
          let after = try? JSONCoding.decoder.decode(Snapshot.self, from: Data(asx.utf8)) else {
      throw EngineError("Batch \(id.prefix(8)) journal is unreadable")
    }
    if !force, rec.action == CaptionRulesMigration.action {
      throw EngineError("Can't undo \(rec.action): clips with scheduled or posted posts would change. Use force to overwrite.")
    }
    if !dryRun, !confirmGoLive, let json = before.settings?.json {
      let live = try goLive(from: try store.settings(), to: Store.decodeSettings(json))
      if !live.isEmpty {
        throw EngineError("Undoing \(rec.action) would publish \(live.map(\.displayName).joined(separator: ", ")) through Postiz for real (test run off). Confirm going live to undo it, or change Settings → Publishing instead.")
      }
    }
    var result = BulkResult(batchId: nil, action: "undo", dryRun: dryRun, videoIds: rec.videoIds, changed: [], skipped: [:],
                            remainingIssues: [:], summary: "")
    do {
      try store.db.transaction {
        let afterById = Dictionary(uniqueKeysWithValues: after.clips.map { ($0.id, $0) })
        // A partial undo (clips skipped as changed again) leaves the batch open; `restored` remembers what's done
        // so a later undo (e.g. with force) handles only the rest.
        var restored = Set(rec.restored)
        var planTied = false
        for b in before.clips where !restored.contains(b.id) {
          let cur = try clipSnapshot(b.id, renders: b.renders != nil)
          if let a = afterById[b.id], !Self.same(cur, a), !force {
            result.skipped[b.id] = "changed again since the batch (use force to overwrite)"
            // The clip stays as it is, so its plan must too if the batch took it out of the Queue or sent it: plan alone
            // would put live posts on a held clip. Anything else about the clip doesn't tie it to the plan.
            planTied = planTied || cur.held != b.held || (b.sent != nil && cur.sent != b.sent)
            continue
          }
          // A crop this batch moved can't go back once a platform could post it: the platforms would end up on different pictures.
          if !force, rec.action == Self.cropOffsetAction, rec.videoIds.contains(b.id),
             let why = try cropLock(try store.posts(where: "video_id=?", [b.id], order: "id")) {
            result.skipped[b.id] = why
            continue
          }
          restored.insert(b.id)
          // The sent flag comes back only when this batch changed it: anything else that took a clip out of the Queue
          // since (a limit, a missing file) still stands, and only Send to Queue reverses it.
          var target = b
          if afterById[b.id]?.sent == b.sent { target.sent = cur.sent }
          if cur == target { continue }
          try restore(target)
          result.changed.append(b.id)
        }
        var touched = Set(result.changed)
        let planWaits = planTied && before.plan != nil && !restored.contains(Self.planMarker)
        if !planWaits, let bp = before.plan, let ap = after.plan, !restored.contains(Self.planMarker) {
          let cp = try planSnapshot()
          if !force, let why = try planConflict(before: bp, after: ap, current: cp) {
            throw EngineError("Can't undo the plan part of \(rec.action): \(why). Use force to overwrite.")
          }
          try restorePlan(bp, current: cp, note: "undo \(rec.action) (batch \(id.prefix(8)))")
          touched.formUnion(bp.slots.map(\.videoId) + ap.slots.map(\.videoId) + bp.posts.map(\.videoId) + ap.posts.map(\.videoId))
          touched.formUnion(cp.slots.map(\.videoId) + cp.posts.map(\.videoId))  // clips the scheduler had placed since
          result.changed = Array(Set(result.changed).union(rec.videoIds.filter { touched.contains($0) })).sorted()
          restored.insert(Self.planMarker)
        }
        if let bset = before.settings, let aset = after.settings, !restored.contains(Self.settingsMarker) {
          let cur = try settingsSnapshot()
          if !force, cur != aset {
            throw EngineError("Can't undo the settings part of \(rec.action): settings changed after it. Use force to overwrite.")
          }
          if !force, CaptionTemplates.batchActions.contains(rec.action) {
            let now = try CaptionHold.Sources(store)
            var then = now
            then.settings = bset.json.map(Store.decodeSettings) ?? Settings()
            if let why = try CaptionHold.undoConflict(from: now, to: then, restoring: Set(before.clips.map(\.id)), store: store) {
              throw EngineError("Can't undo \(rec.action): \(why). Use force to overwrite.")
            }
          }
          if cur != bset {
            try restoreSettings(bset)
            try Revalidation(store: store).run(adjustPlan: false)  // round 4 (S1): states follow the restored settings
          }
          restored.insert(Self.settingsMarker)
        }
        if let bset = before.hashtagSets, let aset = after.hashtagSets, !restored.contains(Self.hashtagGroupsMarker) {
          let cur = try store.hashtagSets()
          if !force, cur != aset {
            throw EngineError("Can't undo the hashtag group part of \(rec.action): hashtag groups changed after it. Use force to overwrite.")
          }
          if !force, let why = try HashtagGroups.undoConflict(from: cur, to: bset, restoring: Set(before.clips.map(\.id)), store: store) {
            throw EngineError("Can't undo the hashtag group part of \(rec.action): \(why). Use force to overwrite.")
          }
          if cur != bset {
            try restoreHashtagSets(bset)
            try Revalidation(store: store).run(adjustPlan: false)
          }
          restored.insert(Self.hashtagGroupsMarker)
        }
        if let bt = before.captionTemplates, let at = after.captionTemplates, !restored.contains(Self.captionTemplatesMarker) {
          let cur = try store.captionTemplates()
          if !force, cur != at {
            throw EngineError("Can't undo the template part of \(rec.action): caption templates changed after it. Use force to overwrite.")
          }
          if !force {
            let now = try CaptionHold.Sources(store)
            var then = now
            then.templates = bt
            if let why = try CaptionHold.undoConflict(from: now, to: then, restoring: Set(before.clips.map(\.id)), store: store) {
              throw EngineError("Can't undo \(rec.action): \(why). Use force to overwrite.")
            }
          }
          if cur != bt {
            try store.db.run("DELETE FROM caption_templates")
            for t in bt { try store.save(t) }
            try Revalidation(store: store).run(adjustPlan: false)
          }
          restored.insert(Self.captionTemplatesMarker)
        }
        for v in touched { try store.refreshState(videoId: v) }
        for v in result.changed {
          try store.logEvent("bulk", "Undid \(rec.action) (batch \(id.prefix(8)))", videoId: v)
        }
        let complete = result.skipped.isEmpty
        try store.db.run("UPDATE batches SET restored=?, undone_at=? WHERE id=?",
                         [JSONCoding.string(restored.sorted()), complete ? store.clock.now : nil, id])
        result.summary = "undid \(rec.action): \(result.changed.count) restored"
          + (complete ? "" : ", \(result.skipped.count) skipped\(planWaits ? ", plan left as it is" : "") — batch stays open; undo again with force to restore them")
        if dryRun { throw DryRun(result: result) }
      }
    } catch let d as DryRun {
      return d.result
    }
    if postsChangeSignal { ChangeSignal.post() }
    return result
  }

  /// Clip-history words for a journaled action; the command name stays (round 4: "make-ready" reads as what it does).
  static func historyLabel(_ action: String) -> String {
    action == "make-ready" ? "Confirm default crop (make-ready)" : action
  }

  // MARK: Selection helper

  /// Clip ids for a filter: a VideoState raw value (`needs_edit`, `ready`, …), `unscored`, `scored`, `all`
  /// (short-form only, posting order not implied).
  public func ids(filter: String) throws -> [String] {
    let base = "type='short-form'"
    let clause: String
    switch filter {
    case "all": clause = base
    case "unscored", "to-score": clause = "\(base) AND excluded=0 AND missing=0 AND score IS NULL"
    case "scored": clause = "\(base) AND score IS NOT NULL"
    case "needs-edit": clause = "\(base) AND excluded=0 AND missing=0 AND score IS NOT NULL AND state='needs_edit'"
    default:
      guard let s = VideoState(rawValue: filter) else {
        throw EngineError("Unknown filter \(filter) — use all, unscored, scored, needs-edit or a state (\(VideoState.allCases.map(\.rawValue).joined(separator: ", ")))")
      }
      clause = "\(base) AND state='\(s.rawValue)'"
    }
    return try store.videos(where: clause).sorted { ($0.part ?? 0, $0.start ?? 0, $0.name) < ($1.part ?? 0, $1.start ?? 0, $1.name) }
      .map(\.id)
  }

  // MARK: Engine

  enum Outcome { case changed, unchanged, skipped(String) }

  struct DryRun: Error { var result: BulkResult }

  struct RenderSnap: Codable, Equatable { var id: String; var deletedAt: Double? }

  struct ClipSnap: Codable, Equatable {
    var id: String
    var score: Int?
    var kind: String
    var excluded: Bool
    var title: String?
    var titleTracks: String?
    var titleSource: String?
    var edit: String?
    var versions: [String: String]
    var renders: [RenderSnap]?
    /// Sent back to Edit (schema v3). nil = not held, so journals written before v3 compare equal.
    var held: Bool? = nil
    /// `Video.sentToQueue` (round 13). nil = a journal written before it: the flag is neither compared nor restored.
    var sent: Bool? = nil
  }

  /// `cur` is still what snapshot `a` recorded. A sent flag that went from on to off isn't Eric's later work: the engine
  /// clears it when a clip goes invalid (the batch may be why), and Back to Edit shows up in `held` anyway.
  static func same(_ cur: ClipSnap, _ a: ClipSnap) -> Bool {
    var c = cur
    if a.sent != false { c.sent = a.sent }
    return c == a
  }

  struct PlanSnap: Codable, Equatable {
    var slots: [PlanSlot]
    var weeks: [Week]
    var posts: [PlatformPost]
  }

  /// The raw settings row (nil json = no row yet). Captured only by journaled actions that change settings.
  struct SettingsSnap: Codable, Equatable { var json: String? }

  struct Snapshot: Codable {
    var clips: [ClipSnap]
    var plan: PlanSnap?
    var settings: SettingsSnap? = nil
    /// Round 7: the whole hashtag group table, for actions that change groups (nil = not journaled).
    var hashtagSets: [HashtagSet]? = nil
    /// v0.8.3: the whole caption template table, for actions that change templates (nil = not journaled).
    var captionTemplates: [CaptionTemplate]? = nil
  }

  static let settingsMarker = "#settings"
  static let hashtagGroupsMarker = "#hashtag-groups"
  static let captionTemplatesMarker = "#caption-templates"

  private func restoreHashtagSets(_ sets: [HashtagSet]) throws {
    try store.db.run("DELETE FROM hashtag_sets")
    for s in sets { try store.save(s) }
  }

  func settingsSnapshot() throws -> SettingsSnap {
    SettingsSnap(json: try store.db.one("SELECT json FROM kv WHERE key='settings'")?.string("json"))
  }

  private func restoreSettings(_ s: SettingsSnap) throws {
    if let j = s.json {
      try store.db.run("INSERT INTO kv(key,json) VALUES('settings',?) ON CONFLICT(key) DO UPDATE SET json=excluded.json", [j])
    } else {
      try store.db.run("DELETE FROM kv WHERE key='settings'")
    }
  }

  func run(_ action: String, ids raw: [String], params: [String: String] = [:], dryRun: Bool, plan: Bool = false,
                   renders: Bool = false, reportsAll: Bool = false, _ body: (Int, Video, Settings) throws -> Outcome) throws -> BulkResult {
    var seen = Set<String>()
    let ids = raw.filter { !$0.isEmpty && seen.insert($0).inserted }
    var result = BulkResult(batchId: nil, action: action, dryRun: dryRun, videoIds: ids, changed: [], skipped: [:],
                            remainingIssues: [:], summary: "")
    let settings = try store.settings()
    do {
      try store.db.transaction {
        let existing = try ids.filter { try store.video(id: $0) != nil }
        for id in ids where !existing.contains(id) { result.skipped[id] = "no such video" }
        let before = Snapshot(clips: try existing.map { try clipSnapshot($0, renders: renders) },
                              plan: plan ? try planSnapshot() : nil)
        for (i, id) in existing.enumerated() {
          guard let v = try store.video(id: id) else { continue }
          do {
            // Each clip in its own savepoint: a clip that fails leaves no partial change.
            let o = try store.db.transaction { try body(i, v, settings) }
            switch o {
            case .changed: result.changed.append(id)
            case .unchanged: break
            case .skipped(let why): result.skipped[id] = why
            }
          } catch {
            result.skipped[id] = "\(error)"
          }
        }
        // A batch that took a clip out of the Queue did it here, not on the next tick: the journal records the flag it cleared.
        for id in result.changed { try store.refreshState(videoId: id) }
        let reported = reportsAll ? existing.filter { result.skipped[$0] == nil } : result.changed
        var rows: [(id: String, issues: [ValidationIssue], hasTitle: Bool, hasScore: Bool)] = []
        for id in reported {
          if let v = try store.video(id: id), v.type == .short {
            let issues = (try? Validation.issues(video: v, store: store)) ?? []
            result.remainingIssues[id] = issues
            rows.append((id, issues, v.titleText != nil, v.score != nil))
          }
        }
        if reportsAll { result.outlook = ReadyOutlook.classify(rows) }
        result.summary = "\(action): \(result.changed.count) changed"
          + (result.skipped.isEmpty ? "" : ", \(result.skipped.count) skipped")
          + (ids.count - result.changed.count - result.skipped.count > 0
            ? ", \(ids.count - result.changed.count - result.skipped.count) already so" : "")
        if dryRun { throw DryRun(result: result) }
        guard !result.changed.isEmpty else { return }
        let batchId = newId()
        let after = Snapshot(clips: try existing.map { try clipSnapshot($0, renders: renders) },
                             plan: plan ? try planSnapshot() : nil)
        try store.db.run("""
          INSERT INTO batches(id,action,params,video_ids,before,after,summary,created_at) VALUES(?,?,?,?,?,?,?,?)
          """, [batchId, action, JSONCoding.string(params), JSONCoding.string(result.changed), JSONCoding.string(before),
                JSONCoding.string(after), result.summary, store.clock.now])
        for id in result.changed {
          try store.logEvent("bulk", "\(Self.historyLabel(action))\(params.isEmpty ? "" : " " + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) (batch \(batchId.prefix(8)))",
                             videoId: id)
        }
        result.batchId = batchId
      }
    } catch let d as DryRun {
      return d.result
    }
    if postsChangeSignal && !result.changed.isEmpty { ChangeSignal.post() }
    return result
  }

  private func updateV1(_ v: Video, _ change: (inout Version) -> Void) throws -> Outcome {
    var v1 = try store.versions(videoId: v.id).first { $0.number == 1 } ?? Version(number: 1)
    let o = v1
    change(&v1)
    guard v1 != o else { return .unchanged }
    try store.save(v1, videoId: v.id)
    return .changed
  }

  /// `updateV1` for a hashtag change: a written v1 caption gets its hashtags swapped in place (round 7, WYSIWYG).
  func updateV1Retagged(_ v: Video, _ s: Settings, _ change: (inout Version) -> Void) throws -> Outcome {
    let all = try store.versions(videoId: v.id)
    var v1 = all.first { $0.number == 1 } ?? Version(number: 1)
    let o = v1
    change(&v1)
    guard v1 != o else { return .unchanged }
    let before = VersionResolver.resolve(all.isEmpty ? [o] : all, number: 1, settings: s, video: v)
    let after = VersionResolver.resolve([v1], number: 1, settings: s, video: v)
    Captions.retag(&v1, before: before, after: after, sets: try store.hashtagSets())
    try store.save(v1, videoId: v.id)
    return .changed
  }

  func cachedOrProbedSize(_ v: Video) throws -> CGSize? {
    if let w = v.sourceWidth, let h = v.sourceHeight, w > 0, h > 0 { return CGSize(width: w, height: h) }
    guard let s = sourceSize(store, v) else { return nil }
    try store.setSourceSize(v.id, width: Int(s.width), height: Int(s.height))
    return s
  }

  func clipSnapshot(_ id: String, renders: Bool) throws -> ClipSnap {
    let r = try store.db.one("SELECT score, kind, excluded, title, title_tracks, title_source, held_in_edit, sent_to_queue FROM videos WHERE id=?", [id])
    let edit = try store.db.one("SELECT json FROM edits WHERE video_id=?", [id])?.string("json")
    var versions: [String: String] = [:]
    for row in try store.db.query("SELECT number, json FROM versions WHERE video_id=?", [id]) {
      versions[String(row.int("number") ?? 0)] = row.string("json") ?? ""
    }
    let rs: [RenderSnap]? = renders
      ? try store.db.query("SELECT id, deleted_at FROM renders WHERE video_id=? ORDER BY id", [id])
        .map { RenderSnap(id: $0.string("id")!, deletedAt: $0.double("deleted_at")) }
      : nil
    return ClipSnap(id: id, score: r?.int("score"), kind: r?.string("kind") ?? Kind.djVid.rawValue,
                    excluded: r?.bool("excluded") ?? false, title: r?.string("title"), titleTracks: r?.string("title_tracks"),
                    titleSource: r?.string("title_source"), edit: edit, versions: versions, renders: rs,
                    held: r?.bool("held_in_edit") == true ? true : nil, sent: r?.bool("sent_to_queue") ?? false)
  }

  private func restore(_ c: ClipSnap) throws {
    let db = store.db
    try db.run("""
      UPDATE videos SET score=?, kind=?, excluded=?, title=?, title_tracks=?, title_source=?, held_in_edit=?,
        sent_to_queue=COALESCE(?, sent_to_queue), updated_at=? WHERE id=?
      """, [c.score, c.kind, c.excluded, c.title, c.titleTracks, c.titleSource, c.held ?? false, c.sent, store.clock.now, c.id])
    if let e = c.edit {
      try db.run("INSERT INTO edits(video_id,json,updated_at) VALUES(?,?,?) ON CONFLICT(video_id) DO UPDATE SET json=excluded.json, updated_at=excluded.updated_at",
                 [c.id, e, store.clock.now])
    } else {
      try db.run("DELETE FROM edits WHERE video_id=?", [c.id])
    }
    try db.run("DELETE FROM versions WHERE video_id=?", [c.id])
    for (n, json) in c.versions {
      try db.run("INSERT INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,?)", [c.id, Int(n) ?? 1, json, store.clock.now])
    }
    for r in c.renders ?? [] {
      if r.deletedAt == nil {
        // Only un-retire a render whose file is still there.
        guard let out = try store.render(id: r.id)?.outputPath, FileManager.default.fileExists(atPath: out) else { continue }
      }
      try db.run("UPDATE renders SET deleted_at=? WHERE id=?", [r.deletedAt, r.id])
    }
  }

  func planSnapshot() throws -> PlanSnap {
    let weeks = try store.db.query("SELECT * FROM weeks ORDER BY week_start").map {
      Week(weekStart: $0.string("week_start")!, state: WeekState(rawValue: $0.string("state")!) ?? .draft,
           approvedAt: $0.date("approved_at"))
    }
    return PlanSnap(slots: try store.planSlots().sorted { $0.id < $1.id }, weeks: weeks,
                    posts: try store.posts(order: "id"))
  }

  /// Why restoring `before` would overwrite someone else's later change (nil = safe).
  ///
  /// Round 13 (A6): the scheduler runs within seconds of any write, so what it derived doesn't count: unpinned slots that
  /// are new since the batch, new regular posts nobody touched (planned, rendering, rendered, no open Postiz job), and
  /// weeks that only flipped to approved. `restorePlan` drops them and the engine derives them again. A slot of the
  /// batch that moved or vanished, a pin, and any acted post still conflict. So does a post that would come back inside
  /// the lead: an undo counts as no explicit "post it now", and a past slot goes out minutes after upload.
  private func planConflict(before b: PlanSnap, after a: PlanSnap, current c: PlanSnap) throws -> String? {
    let slotsNow = Dictionary(uniqueKeysWithValues: c.slots.map { ($0.id, $0) })
    if a.slots.contains(where: { slotsNow[$0.id] != $0 }) { return "the plan's slots changed after the batch" }
    let slotsAfter = Set(a.slots.map(\.id))
    if c.slots.contains(where: { !slotsAfter.contains($0.id) && $0.pinned }) { return "a clip was pinned after the batch" }
    let weeksAfter = Dictionary(uniqueKeysWithValues: a.weeks.map { ($0.weekStart, $0) })
    let weeksNow = Set(c.weeks.map(\.weekStart))
    let weekKept = c.weeks.allSatisfy { w in
      guard let was = weeksAfter[w.weekStart] else { return w.state == .approved }
      return w == was || (was.state == .draft && w.state == .approved)
    }
    if !weekKept || a.weeks.contains(where: { !weeksNow.contains($0.weekStart) }) { return "a week changed after the batch" }
    let lead = store.clock.now.addingTimeInterval(Planner.autoScheduleLead)
    let postsNow = Dictionary(uniqueKeysWithValues: c.posts.map { ($0.id, $0) })
    for p in b.posts where !p.state.isTerminal && p.scheduledAt < lead {
      guard let cur = postsNow[p.id], !cur.state.isTerminal, cur.scheduledAt == p.scheduledAt else { return "its slot has passed" }
    }
    let known = Set(b.posts.map(\.id) + a.posts.map(\.id))
    let untouched: Set<PostState> = [.planned, .rendering, .rendered]
    for p in c.posts where !known.contains(p.id) {
      guard p.kind == .regular, untouched.contains(p.state), try store.livePostizJob(postId: p.id) == nil,
            try store.finalPostizJob(postId: p.id) == nil else {
        return "a new \(p.platform.displayName) post was created after the batch"
      }
    }
    let afterById = Dictionary(uniqueKeysWithValues: a.posts.map { ($0.id, $0) })
    let acted: Set<PostState> = [.posted, .failed, .copyrightBlocked, .copyrightMuted, .removed, .skipped]
    if let p = c.posts.first(where: { acted.contains($0.state) && afterById[$0.id]?.state != $0.state }) {
      return "a \(p.platform.displayName) post was marked \(p.state.displayName.lowercased()) after the batch"
    }
    return nil
  }

  private func restorePlan(_ b: PlanSnap, current c: PlanSnap, note: String) throws {
    let db = store.db
    let keep = Set(b.posts.map(\.id))
    for p in c.posts where !keep.contains(p.id) { try store.deletePost(p.id) }
    try db.run("DELETE FROM plan_slots")
    for s in b.slots { try store.save(s) }
    try db.run("DELETE FROM weeks")
    for w in b.weeks { try store.save(w) }
    let cur = Dictionary(uniqueKeysWithValues: c.posts.map { ($0.id, $0) })
    for p in b.posts where cur[p.id] != p {
      try store.save(p, note: note)
    }
  }

  static func batch(_ r: Row) -> BatchRecord {
    BatchRecord(id: r.string("id")!, action: r.string("action")!, params: r.json("params") ?? [:],
                videoIds: r.json("video_ids") ?? [], summary: r.string("summary") ?? "", createdAt: r.date("created_at")!,
                undoneAt: r.date("undone_at"), restored: r.json("restored") ?? [])
  }
}

/// The app's ⌘Z order: journal batch ids, most recent last (round 3, F8). Every undoable action pushes; Undo from a
/// toast removes that entry wherever it is; ⌘Z takes the most recent one. Bounded so a long session stays small.
public struct UndoHistory: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public var batchId: String
    public var label: String
  }

  public private(set) var entries: [Entry] = []
  public var limit: Int

  public init(limit: Int = 50) { self.limit = limit }

  public var top: Entry? { entries.last }

  public mutating func push(_ batchId: String, label: String) {
    entries.removeAll { $0.batchId == batchId }
    entries.append(Entry(batchId: batchId, label: label))
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
  }

  /// Takes the most recent entry off (⌘Z).
  public mutating func popTop() -> Entry? { entries.popLast() }

  /// Drops an entry undone some other way (its toast's Undo button) or that can no longer be undone.
  public mutating func remove(_ batchId: String) { entries.removeAll { $0.batchId == batchId } }
}

/// Runs undos one at a time, in the order they were asked for (rapid ⌘Z⌘Z): a serial queue, so the older batch
/// never runs before the newer one (it would be skipped as "changed since" and leave an intermediate value).
public final class UndoRunner: @unchecked Sendable {
  private let bulk: BulkActions
  private let queue = DispatchQueue(label: "com.djlovd.queue.undo", qos: .userInitiated)

  public init(bulk: BulkActions) { self.bulk = bulk }

  /// Undoes batch `id` after every undo submitted before it; `done` runs on the runner's queue.
  public func undo(_ id: String, done: @escaping @Sendable (Result<BulkResult, Error>) -> Void) {
    queue.async { [bulk] in done(Result { try bulk.undo(id) }) }
  }

  /// Blocks until every submitted undo has finished (tests).
  public func wait() { queue.sync {} }
}
