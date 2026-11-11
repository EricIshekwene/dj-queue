import Foundation

/// Where a short clip is in its life. Eric's pipeline is Score → Edit → Queue → Posted (round 13): a clip in the Queue is
/// approved and the engine gives it a day by itself, so `scheduled` is a status ("it has a day on the Calendar"), not a
/// step anyone acts on.
///
/// - score: no score yet · edit: scored, not ready (or sent back from Queue, or its file is missing) · queue: ready,
///   waiting for a day · scheduled: has a day, not fully posted ·
///   posted: every posting platform finished (posted, or partly posted/skipped/failed).
public enum ClipStage: String, Codable, Sendable, CaseIterable, Comparable {
  case score, edit, queue, scheduled, posted

  public var displayName: String {
    switch self {
    case .score: "Score"
    case .edit: "Edit"
    case .queue: "Queue"
    case .scheduled: "Scheduled"
    case .posted: "Posted"
    }
  }

  public var previous: ClipStage? { ClipStage.allCases.firstIndex(of: self).flatMap { $0 > 0 ? ClipStage.allCases[$0 - 1] : nil } }
  public var next: ClipStage? {
    ClipStage.allCases.firstIndex(of: self).flatMap { $0 + 1 < ClipStage.allCases.count ? ClipStage.allCases[$0 + 1] : nil }
  }

  public static func < (a: ClipStage, b: ClipStage) -> Bool {
    (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
  }

  /// The clip's stage from its stored state, or nil when it has none (long-form, excluded, unscored with its file
  /// missing). A photo post skips Score: unscored, it is in Edit.
  ///
  /// Round 4 (S1): a scored clip whose file is missing is in Edit (reason chip "File missing") unless it already
  /// has a day or posted — then it stays Scheduled/Posted and shows the problem (`Store.computeState`
  /// keeps those states for a missing clip). The planner never picks a missing clip.
  public static func of(_ v: Video) -> ClipStage? {
    guard v.type == .short, !v.excluded else { return nil }
    if v.missing {
      switch v.state {
      case .planned, .posting: return .scheduled
      case .posted, .partial: return .posted
      default: return v.score == nil && !v.needsNoScore ? nil : .edit
      }
    }
    // Round 21 (D4): a photo post needs no score, so it is never in Score. Round 23 (D6): nor is a video made from one.
    if v.score == nil && !v.needsNoScore { return .score }
    switch v.state {
    case .needsEdit: return .edit
    case .ready: return .queue
    case .planned, .posting: return .scheduled
    case .posted, .partial: return .posted
    case .excluded, .missingFile: return nil
    }
  }
}

public enum StageDirection: String, Codable, Sendable, CaseIterable {
  case back, forward
}

/// One clip's stage move: where it was, where it is now, and what happened in words.
public struct StageMove: Codable, Sendable, Equatable {
  public var from: ClipStage
  public var to: ClipStage
  /// "Score 42 cleared" · "Removed Thu 5 Nov · 6 platforms" · "Still in Edit: Add text (no title yet)" …
  public var note: String
}

/// Stage moves (Eric: "at any stage, bring a video back to its previous stage or move it forward a stage").
/// Each is one BulkActions batch (journal + one-step undo, per-clip history) using the existing rules:
///
/// Back: Edit → Score clears the score · Queue and Scheduled → Edit ("Back to Edit", formerly "Remove from queue": held
/// in Edit, unposted days removed; a Queue clip would just get a day again) · Posted has no back (Repost / Reset a post
/// instead).
/// Forward: Score → Edit needs a score (the UI focuses the score field) · Edit → Queue ("Send to Queue") clears
/// "sent back" and confirms the default crop; if something is still missing it stays in Edit and says what ·
/// the Queue has no forward move (clips there schedule themselves) ·
/// Scheduled → Posted only through the Calendar's Mark posted.
extension BulkActions {
  /// The stage of clip `id` (nil: no such clip, or no stage).
  public func stage(of id: String) throws -> ClipStage? {
    try store.video(id: id).flatMap(ClipStage.of)
  }

  /// Why `direction` can't move this clip (nil = it can). The UI disables its button with this text.
  public func blocker(_ v: Video, _ direction: StageDirection) throws -> String? {
    if let why = StageWording.blocker(v, direction) { return why }
    guard let st = ClipStage.of(v) else { return Self.noStageReason(v) }
    switch (st, direction) {
    case (.score, .forward): return "Give it a score on Score first"
    case (.scheduled, .back): return try postedBlocker(v)
    case (.scheduled, .forward): return "Mark it posted on the Calendar once it's up"
    default: return nil
    }
  }

  static func noStageReason(_ v: Video) -> String { StageWording.noStageReason(v) }

  /// Moves each clip one stage back (see the type comment). One batch; `moves` says what happened per clip.
  @discardableResult
  public func back(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    var moves: [String: StageMove] = [:]
    var removed: [String: [Planner.UnplanItem]] = [:]
    var r = try run("stage-back", ids: ids, dryRun: dryRun, plan: true) { _, v, _ in
      if let why = try blocker(v, .back) { return .skipped(why) }
      guard let st = ClipStage.of(v) else { return .skipped(Self.noStageReason(v)) }
      switch st {
      case .edit:
        try store.setScore(v.id, nil)
        try store.refreshState(videoId: v.id)
        moves[v.id] = StageMove(from: .edit, to: .score, note: "Score \(v.score.map(String.init) ?? "") cleared — back to Score")
      case .queue, .scheduled:
        if st == .scheduled { try store.dropWaitingRetries(videoId: v.id) }
        let items = try hold(v, planner: planner)
        if !items.isEmpty { removed[v.id] = items }
        moves[v.id] = StageMove(from: st, to: .edit, note: StageWording.backInEdit + Self.daysText(items, store: store))
      case .score, .posted:
        return .skipped("No stage before \(st.displayName)")
      }
      return .changed
    }
    r.moves = moves.filter { r.changed.contains($0.key) }
    r.unplanned = removed.filter { r.changed.contains($0.key) }
    return r
  }

  /// Moves each clip one stage forward (see the type comment). An Edit clip that is still missing something stays in
  /// Edit and `moves[id].note` / `remainingIssues[id]` say exactly what.
  @discardableResult
  public func forward(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    var moves: [String: StageMove] = [:]
    var r = try run("stage-forward", ids: ids, dryRun: dryRun, plan: true) { _, v, s in
      if let why = try blocker(v, .forward) { return .skipped(why) }
      guard let st = ClipStage.of(v) else { return .skipped(Self.noStageReason(v)) }
      switch st {
      case .edit:
        let sent = try send(v, s)
        if case .skipped = sent { return sent }
        let after = try store.video(id: v.id) ?? v
        let issues = try Validation.issues(video: after, store: store)
        let note = issues.isEmpty ? StageWording.sentToQueue : StageWording.stillInEdit(issues)
        guard case .changed = sent else { return .skipped(note) }
        moves[v.id] = StageMove(from: .edit, to: ClipStage.of(after) ?? .edit, note: note)
      case .score, .queue, .scheduled, .posted:
        return .skipped("No forward move from \(st.displayName)")
      }
      return .changed
    }
    r.moves = moves.filter { r.changed.contains($0.key) }
    return r
  }

  static func day(_ key: String, _ dm: DayMath, _ s: Settings, _ format: String = "EEE d MMM") -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = s.tz
    f.dateFormat = format
    return f.string(from: dm.date(key))
  }

  /// " · removed Thu 5 Nov · 6 platforms, Fri 6 Nov · no posts yet" (empty when nothing was planned).
  static func daysText(_ items: [Planner.UnplanItem], store: Store) -> String {
    guard !items.isEmpty, let s = try? store.settings() else { return "" }
    let dm = DayMath(settings: s)
    return " · removed " + items.map { i in
      day(i.date, dm, s) + (i.platforms.isEmpty ? " · no posts yet" : " · \(i.platforms.count) platform\(i.platforms.count == 1 ? "" : "s")")
    }.joined(separator: ", ")
  }
}
