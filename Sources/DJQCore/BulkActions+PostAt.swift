import Foundation

/// Round 21 (DECISIONS-R21.md, D12–D14): "Post at a set time" as journaled batches, for the app and `djq post-at`.
///
/// D13: setting a time is Eric's Send to Queue. An item still in Edit goes through the one door (`send`) first; if
/// something is left to fix it stays exactly as it was and the result says what is missing, in Send to Queue's words.
/// Each batch journals the clips and the whole plan, so one undo puts the previous day (or set time) and its posts back.
extension BulkActions {
  public static let postAtAction = "post-at"
  public static let clearExactAction = "post-at-clear"

  /// Sets `at` as the time each item posts on every platform (`Planner.postAt`). One batch, one undo. `moves[id].note`
  /// is the toast: "Set for Sat 14 Nov 3:15 PM". A time that has passed or is inside `Planner.exactLead` throws; an
  /// item that can't take it is in `skipped` with the reason.
  @discardableResult
  public func postAt(_ ids: [String], at raw: Date, dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    let at = Planner.exactMinute(raw)
    if let why = planner.exactTimeProblem(at) { throw EngineError(why) }
    let shown = try store.settings()
    var moves: [String: StageMove] = [:]
    var r = try run(Self.postAtAction, ids: ids, params: ["at": Self.localMinute(at, shown)], dryRun: dryRun, plan: true) { _, v, s in
      let from = ClipStage.of(v) ?? .edit
      try openDoor(v, s)
      let set = try planner.setExact(videoId: v.id, at: at)
      guard set.changed else { return .unchanged }
      moves[v.id] = StageMove(from: from, to: .scheduled, note: StageWording.setFor(at, settings: s))
      return .changed
    }
    r.moves = moves.filter { r.changed.contains($0.key) }
    return r
  }

  /// "Use the regular schedule" for each item (`Planner.clearExact`): the set time goes and the item is back in the
  /// Queue, where the next scheduling pass gives it the next open day. One batch, one undo.
  @discardableResult
  public func clearExact(_ ids: [String], dryRun: Bool = false) throws -> BulkResult {
    let planner = Planner(store: store)
    var moves: [String: StageMove] = [:]
    var r = try run(Self.clearExactAction, ids: ids, dryRun: dryRun, plan: true) { _, v, _ in
      guard try planner.exactSlot(videoId: v.id) != nil else { return .skipped(StageWording.noSetTime) }
      let from = ClipStage.of(v) ?? .scheduled
      try planner.clearExact(videoId: v.id)
      let to = try store.video(id: v.id).flatMap(ClipStage.of) ?? .queue
      moves[v.id] = StageMove(from: from, to: to, note: StageWording.regularSchedule)
      return .changed
    }
    r.moves = moves.filter { r.changed.contains($0.key) }
    return r
  }

  /// Read-only: what `postAt([id], at:)` would do for one item, wherever it is (Edit, Queue or Scheduled). Per platform
  /// the time it goes out, so the UI can say "YouTube moves to 2:30 AM (07:30 UTC)" before Eric confirms; the platforms
  /// left out; and `blocker` when it can't be set. Runs the real thing in a transaction that is rolled back.
  public func postAtPreview(_ id: String, at: Date) throws -> Planner.ExactPreview {
    try Planner(store: store).postAtPreview(videoId: id, at: at) { v, s in try self.openDoor(v, s) }
  }

  /// What has to be true before the planner sets a time. An item in the Queue or scheduled passes as it is. An item in
  /// Edit goes through Send to Queue, and one that still has something to fix throws what's missing (the caller's
  /// savepoint rolls back, so it stays in Edit untouched). An item in Score needs its score first.
  func openDoor(_ v: Video, _ s: Settings) throws {
    guard let stage = ClipStage.of(v) else { throw EngineError(Self.noStageReason(v)) }
    guard stage == .score || stage == .edit else { return }
    if let why = try blocker(v, .forward) { throw EngineError(why) }
    if case .skipped(let why) = try send(v, s) { throw EngineError(why) }
    let after = try store.video(id: v.id) ?? v
    let issues = try Validation.issues(video: after, store: store)
    if !issues.isEmpty { throw EngineError(StageWording.stillInEdit(issues)) }
  }

  /// "2026-11-14 15:15" in the Settings time zone (the journal's `at` and what `djq post-at` takes).
  static func localMinute(_ d: Date, _ s: Settings) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = s.tz
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
  }
}
