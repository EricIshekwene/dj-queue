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
  public func ordered(platform: Platform? = nil) throws -> [Video] {
    let settings = try store.settings()
    let slotted = try slottedVideoIds(settings)
    var out: [Video] = []
    for v in try candidates() {
      if let p = platform {
        if v.alreadyPostedOn.contains(p) { continue }
        if try !store.platformHistory(videoId: v.id, platform: p).isEmpty { continue }
        if try store.edit(videoId: v.id).isSkipped(p, defaults: settings.defaults) { continue }
      } else if slotted.contains(v.id) {
        continue
      }
      if try isValid(v) { out.append(v) }
    }
    let sessionDates = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0.date ?? "9999") })
    out = sort(out, direction: settings.sortDirection(for: platform), sessionDates: sessionDates)
    return try applySkips(out, slotted: slotted)
  }

  /// Short-form, not excluded/missing, score == nil.
  public func toScore() throws -> [Video] {
    try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND score IS NULL")
      .sorted { ($0.part ?? 0, $0.start ?? 0, $0.name) < ($1.part ?? 0, $1.start ?? 0, $1.name) }
  }

  /// The Edit stage (`ClipStage.of == .edit`): scored, something still missing (or sent back), plus scored clips whose
  /// file is missing and that aren't scheduled or posted (round 4: they show in Edit with "File missing").
  public func needsEdit() throws -> [Video] {
    try store.videos(where: """
      type='short-form' AND excluded=0 AND score IS NOT NULL AND
      ((missing=0 AND state='needs_edit') OR (missing=1 AND state IN ('needs_edit','ready','missing_file')))
      """)
      .sorted { ($0.score ?? 0, $0.part ?? 0, $0.start ?? 0) < ($1.score ?? 0, $1.part ?? 0, $1.start ?? 0) }
  }

  /// approvedDays = consecutive days from today with an approved slot; readyDays = ready backlog ÷ posts/day;
  /// totalDays = approvedDays + (ready + Edit clips with their file) ÷ posts/day.
  public func runway() throws -> Runway {
    let settings = try store.settings()
    let dm = DayMath(settings: settings)
    let perDay = max(1, settings.postsPerDay)
    let today = store.today(dm)
    let slots = try store.planSlots(where: "date>=?", [today])
    let approvedWeeks = Set(try store.db.query("SELECT week_start FROM weeks WHERE state='approved'").compactMap { $0.string("week_start") })
    let withPosts = Set(try store.db.query("SELECT DISTINCT plan_slot_id FROM platform_posts WHERE plan_slot_id IS NOT NULL")
      .compactMap { $0.string("plan_slot_id") })
    let approvedDates = Set(slots.filter { approvedWeeks.contains($0.weekStart) || withPosts.contains($0.id) }.map(\.date))
    var approved = 0
    var d = today
    while approvedDates.contains(d) {
      approved += 1
      d = dm.addDays(d, 1)
    }
    let ready = try ordered().count
    // Missing-file clips are in Edit but can't become posting days until relinked, so runway leaves them out.
    let edit = try needsEdit().filter { !$0.missing }.count
    return Runway(approvedDays: approved, readyDays: ready / perDay, totalDays: approved + (ready + edit) / perDay)
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

  /// Same session + part and overlapping source ranges.
  public static func overlaps(_ a: Video, _ b: Video) -> Bool {
    guard a.id != b.id, a.sessionId == b.sessionId, a.part == b.part,
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

  func candidates() throws -> [Video] {
    try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND score IS NOT NULL")
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
