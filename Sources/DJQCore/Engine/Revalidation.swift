import Foundation

/// The Queue only ever holds ready clips (round 4). One pass re-derives the state of every short, included clip in Edit
/// or the Queue (and scored clips whose file is missing), so a clip whose crop was cleared, whose length no longer fits
/// a platform limit, or whose file went missing moves to Edit on its own — with a "stage" event "Moved to Edit: <reasons>"
/// (`Store.refreshState`). It never goes the other way (round 13, A11): a clip that became valid again stays in Edit
/// until Eric sends it to the Queue.
///
/// Scheduled and posted clips are not re-derived here: they stay where they are and the engine reports their problem
/// ("<clip> can't post"); pinned slots never move. Draft-week days (none are left once `autoSchedule` ran) whose clip left
/// the Queue are refilled from the queue (`Planner.dropNotReadyDraftSlots`) when `adjustPlan` is on.
///
/// Runs as the engine's "stages" tick step, after every `djq` write, and (states only) inside
/// `BulkActions.record` / `undo` whenever Settings changed.
public final class Revalidation: @unchecked Sendable {
  let store: Store

  public init(store: Store) { self.store = store }

  public struct Report: Codable, Sendable, Equatable {
    public var checked = 0
    /// Queue → Edit: clip id → its reason chips ("No crop", "Too long for X", "File missing").
    public var movedToEdit: [String: [String]] = [:]
    /// Other state corrections (e.g. a missing clip that is scheduled keeps `planned`).
    public var otherChanges = 0
    /// Draft-week slots removed because their clip left the Queue (each refilled from the queue when possible).
    public var draftSlotsRemoved: [PlanSlot] = []

    public var summary: String {
      var parts = ["checked \(checked)"]
      if !movedToEdit.isEmpty { parts.append("\(movedToEdit.count) moved to Edit") }
      if otherChanges > 0 { parts.append("\(otherChanges) other") }
      if !draftSlotsRemoved.isEmpty { parts.append("\(draftSlotsRemoved.count) day\(draftSlotsRemoved.count == 1 ? "" : "s") refilled") }
      return parts.joined(separator: " · ")
    }
  }

  /// One pass in one transaction. `adjustPlan: false` only re-derives states (no plan writes).
  @discardableResult
  public func run(adjustPlan: Bool = true) throws -> Report {
    var r = Report()
    try store.db.transaction {
      let ctx = try ValidationContext.load(store)
      let vids = try store.videos(where: "type='short-form' AND excluded=0 AND state IN ('needs_edit','ready','missing_file')")
      for v in vids {
        r.checked += 1
        guard let new = try store.refreshState(v, context: ctx) else { continue }
        var after = v
        after.state = new
        if Store.wasInQueue(v), ClipStage.of(after) == .edit {
          r.movedToEdit[v.id] = try Validation.issues(video: after, store: store, context: ctx).map(\.chipText)
        } else {
          r.otherChanges += 1
        }
      }
      if adjustPlan { r.draftSlotsRemoved = try Planner(store: store).dropNotReadyDraftSlots(revalidate: false) }
    }
    return r
  }

  /// `djq`'s after-write hook (every command that wrote, before ChangeSignal): runs the pass; a failure is logged,
  /// never thrown, so the write itself still counts. Returns the report (nil on failure).
  @discardableResult
  public static func afterWrite(store: Store, command: String) -> Report? {
    do {
      return try Revalidation(store: store).run()
    } catch {
      Log.shared.warn("stage check after \(command): \(error)")
      return nil
    }
  }
}
