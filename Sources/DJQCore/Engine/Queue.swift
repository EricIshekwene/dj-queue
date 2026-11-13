import Foundation

/// The scored running queue (spec §5): what posts next, in what order, and how many days are left.
public final class Queue: @unchecked Sendable {
  let store: Store

  public init(store: Store) { self.store = store }

  /// Ready, scored, unplanned short-form videos in posting order.
  ///
  /// - `platform == nil`: the global backlog — not excluded/missing, score set, edit valid, not in any plan slot;
  ///   sorted by `settings.sort`.
  /// - `platform != nil`: that platform's own backlog — same filters, but plan slots don't matter; instead videos
  ///   already planned/posted on that platform (or skipped for it in the editor) are left out. Sorted by the
  ///   platform's override when set.
  ///
  /// Ties: older session first, then `part`, then `start` (keeps the night's order).
  /// Videos marked with "skip next" move one place later.
  ///
  /// Round 21 (D4): a photo post needs no score. Unscored photos come first, oldest import first; a photo with a score
  /// sorts by it like a clip. Round 23 (D6): the same for a video made from a photo (`Video.needsNoScore`).
  public func ordered(platform: Platform? = nil) throws -> [Video] {
    let settings = try store.settings()
    let slotted = try slottedVideoIds(settings)
    let cands = try candidates()
    // Round 31: the global backlog is every clip with a post still waiting for a day (a version, or the next post of
    // one), whether or not it already has days; each version posts its count (`PostUnits`). A clip with no day at all
    // stays in it as before, even with nowhere left to post (`Planner.schedulable` leaves that one out).
    let book = platform == nil ? try UnitBook(store: store, settings: settings, videos: cands) : nil
    var out: [Video] = []
    for v in cands {
      if let p = platform {
        if v.alreadyPostedOn.contains(p) { continue }
        if try !store.platformHistory(videoId: v.id, platform: p).isEmpty { continue }
        if try store.edit(videoId: v.id).isSkipped(p, defaults: settings.defaults) { continue }
      } else if slotted.contains(v.id), book?.pending(v.id).isEmpty ?? true {
        continue
      }
      if try isValid(v) { out.append(v) }
    }
    let sessionDates = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0.date ?? "9999") })
    out = sort(out, direction: settings.sortDirection(for: platform), sessionDates: sessionDates)
    return try applySkips(out, slotted: slotted)
  }

  /// Short-form, not excluded/missing, score == nil. Never a photo post or a video made from one: they skip Score.
  public func toScore() throws -> [Video] {
    try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND score IS NULL AND NOT \(Store.noScoreSQL)")
      .sorted { ($0.part ?? 0, $0.start ?? 0, $0.name) < ($1.part ?? 0, $1.start ?? 0, $1.name) }
  }

  /// The Edit stage (`ClipStage.of == .edit`): scored, something still missing (or sent back), plus scored clips whose
  /// file is missing and that aren't scheduled or posted (round 4: they show in Edit with "File missing").
  /// Photo posts are here scored or not; the unscored ones come first, oldest import first. Clips order exactly as
  /// before (score, part, start; a tie keeps the order they were read in).
  public func needsEdit() throws -> [Video] {
    try store.videos(where: """
      type='short-form' AND excluded=0 AND (score IS NOT NULL OR \(Store.noScoreSQL)) AND
      ((missing=0 AND state='needs_edit') OR (missing=1 AND state IN ('needs_edit','ready','missing_file')))
      """)
      .sorted { a, b in
        let ka = (a.score ?? (a.needsNoScore ? -1 : 0), a.part ?? 0, a.start ?? 0), kb = (b.score ?? (b.needsNoScore ? -1 : 0), b.part ?? 0, b.start ?? 0)
        if ka != kb { return ka < kb }
        // A tie: clips stay as they were read (and ahead of photos); photos and made videos go oldest import first.
        guard a.needsNoScore, b.needsNoScore else { return !a.needsNoScore && b.needsNoScore }
        return a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
      }
  }

  /// approvedDays = consecutive days with a scheduled slot, from today (from tomorrow when today has none: a clip can't
  /// take a day whose post times passed), set-time slots left out: they're one-offs outside the cadence, so a day that
  /// holds only one isn't a scheduled day; readyDays = waiting clips ÷ posts/day;
  /// totalDays = approvedDays + (waiting + Edit clips with their file) ÷ posts/day.
  public func runway() throws -> Runway {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let perDay = max(1, settings.postsPerDay)
    let today = store.today(dm)
    let slots = try store.planSlots(where: "date>=? AND exact_at IS NULL", [today])
    let approvedWeeks = Set(try store.db.query("SELECT week_start FROM weeks WHERE state='approved'").compactMap { $0.string("week_start") })
    let withPosts = Set(try store.db.query("SELECT DISTINCT plan_slot_id FROM platform_posts WHERE plan_slot_id IS NOT NULL")
      .compactMap { $0.string("plan_slot_id") })
    let approvedDates = Set(slots.filter { approvedWeeks.contains($0.weekStart) || withPosts.contains($0.id) }.map(\.date))
    var approved = 0
    var through: String?
    var d = approvedDates.contains(today) ? today : dm.addDays(today, 1)
    while approvedDates.contains(d) {
      approved += 1
      through = d
      d = dm.addDays(d, 1)
    }
    // Round 31: days are posts, and a clip makes one per version post (`PostUnits`), so both counts are posts.
    let waiting = try Planner(store: store).schedulable(settings)  // not clips that will never get a day
    // Missing-file clips are in Edit but can't become posting days until relinked, so runway leaves them out.
    let editClips = try needsEdit().filter { !$0.missing }
    let book = try UnitBook(store: store, settings: settings, videos: waiting + editClips)
    let ready = waiting.reduce(0) { $0 + book.pending($1.id).count }
    let edit = editClips.reduce(0) { $0 + (book[$1.id]?.total ?? 1) }
    return Runway(approvedDays: approved, readyDays: ready / perDay, totalDays: approved + (ready + edit) / perDay,
                  scheduledThrough: through)
  }

  // MARK: Skip next (backlog videos)

  /// Moves a backlog video one place later in the order until it is planned.
  public func skipOnce(_ videoId: String) throws {
    let slotted = try slottedVideoIds(try store.settings())
    var ids: [String] = (try store.kv("queue.skipNext") ?? []).filter { !slotted.contains($0) }
    if !ids.contains(videoId) { ids.append(videoId) }
    try store.setKV("queue.skipNext", ids)
  }

  // MARK: Overlap (optional, default off)

  /// Same session + part and overlapping source ranges. Never two videos made from photos (round 23): each is its own
  /// file from 0 to its length, not a cut of one recording.
  public static func overlaps(_ a: Video, _ b: Video) -> Bool {
    guard a.id != b.id, !a.isStill, !b.isStill, a.sessionId == b.sessionId, a.part == b.part,
          let s1 = a.start, let e1 = a.end, let s2 = b.start, let e2 = b.end else { return false }
    return s1 < e2 && s2 < e1
  }

  // MARK: Internals

  /// Clips that hold a plan slot. A past day of a draft week that never got posts doesn't count (round 6, F5): it
  /// can't post any more, so its clip is back in the queue (the engine's plan step deletes such slots).
  func slottedVideoIds(_ settings: Settings) throws -> Set<String> {
    let stale = Set(try store.stalePastDraftSlots(today: store.today(DayMath(settings: settings))).map(\.id))
    return Set(try store.planSlots().filter { !stale.contains($0.id) }.map(\.videoId))
  }

  /// Scored clips, and photo posts and videos made from a photo with or without a score.
  func candidates() throws -> [Video] {
    try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND (score IS NOT NULL OR \(Store.noScoreSQL))")
  }

  /// Edit valid. `ready` already means valid; videos in other states (planned elsewhere, override posts) are re-checked.
  func isValid(_ v: Video) throws -> Bool {
    switch v.state {
    case .ready: true
    case .needsEdit, .excluded, .missingFile: false
    default: try Validation.isReady(video: v, store: store)
    }
  }

  func sort(_ vids: [Video], direction: SortDirection, sessionDates: [String: String]) -> [Video] {
    vids.sorted { a, b in
      // Round 21 (D4): unscored photo posts go ahead of everything scored, oldest import first. Round 23 (D6): videos
      // made from a photo sort with them.
      let ua = a.needsNoScore && a.score == nil, ub = b.needsNoScore && b.score == nil
      if ua != ub { return ua }
      if ua, a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
      let sa = a.score ?? 0, sb = b.score ?? 0
      if sa != sb { return direction == .worstFirst ? sa < sb : sa > sb }
      let da = sessionDates[a.sessionId] ?? "9999", db = sessionDates[b.sessionId] ?? "9999"
      if da != db { return da < db }
      if (a.part ?? 0) != (b.part ?? 0) { return (a.part ?? 0) < (b.part ?? 0) }
      if (a.start ?? 0) != (b.start ?? 0) { return (a.start ?? 0) < (b.start ?? 0) }
      return a.id < b.id
    }
  }

  private func applySkips(_ list: [Video], slotted: Set<String>) throws -> [Video] {
    // Read-only (Doctor calls this): planned ids are ignored here and pruned in skipOnce.
    let ids: [String] = try store.kv("queue.skipNext") ?? []
    guard !ids.isEmpty else { return list }
    let live = ids.filter { !slotted.contains($0) }
    var out = list
    for id in live {
      guard let i = out.firstIndex(where: { $0.id == id }), i + 1 < out.count else { continue }
      out.swapAt(i, i + 1)
    }
    return out
  }
}
