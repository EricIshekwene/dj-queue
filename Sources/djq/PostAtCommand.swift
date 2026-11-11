import DJQCore
import Foundation

/// `djq post-at` (round 21, DECISIONS-R21.md D12–D14): post an item at a set day and time on every platform, outside
/// the posts-per-day cadence, or put it back on the regular schedule. Setting a time is Eric's Send to Queue (D13):
/// agents run this only when Eric says so. It also holds the words `djq week`, `today` and `status` use for set times.
enum PostAtCommand {
  static let usage = """
    post-at <video> "<YYYY-MM-DD HH:MM>" [--dry-run] [--json]   post it at that day and time (\(Int(Planner.exactLead / 60)) min ahead or more)
    post-at <video> --clear [--dry-run] [--json]                 back on the regular schedule
    """

  struct Out: Encodable {
    var dryRun: Bool
    /// The command changed something (false: dry run, blocked, or it already had this time).
    var changed: Bool
    /// For `djq bulk undo`.
    var batchId: String?
    /// The item's set time after the command (absent: none).
    var exactAt: Date?
    /// What setting the time does: per platform when it goes out, what's skipped, what it replaces, the blocker.
    var plan: Planner.ExactPreview?
    /// `--clear`: what happened, or why not.
    var note: String?
  }

  /// `wrote` tells `run` to re-check the stages and signal the app, as after any write.
  static func run(_ store: Store, _ settings: Settings, _ wrote: inout Bool) throws -> Int32 {
    let json = flag("--json"), dry = flag("--dry-run"), clear = flag("--clear")
    guard let first = args.first else { throw CLIError("usage:\n\(usage)") }
    let v = try resolveVideo(store, first)
    let bulk = BulkActions(store: store)
    func when(_ d: Date) -> String { StageWording.dayTime(d, settings: settings) }  // one clock format, the summary's

    if clear {
      if args.count > 1 { throw CLIError("--clear takes no time: djq post-at <video> --clear") }
      let r = try bulk.clearExact([v.id], dryRun: dry)
      wrote = !dry && !r.changed.isEmpty
      let why = r.skipped[v.id]
      let out = Out(dryRun: dry, changed: wrote, batchId: r.batchId, exactAt: try Planner(store: store).exactSlot(videoId: v.id)?.exactAt,
                    plan: nil, note: why ?? StageWording.regularSchedule)
      if json { try printJSON(out); return why == nil ? 0 : 2 }
      if let why { print("\(v.tag): \(why)"); return 2 }
      print("\(dry ? "[dry run] " : "")\(v.tag): \(StageWording.regularSchedule) (it gets the next open day)")
      if let b = r.batchId { print("  undo: djq bulk undo \(short(b))") }
      return 0
    }

    let raw = args.dropFirst().joined(separator: " ")
    guard !raw.isEmpty else { throw CLIError("usage:\n\(usage)") }
    let at = try Planner.parseExact(raw, settings: settings)
    let plan = try bulk.postAtPreview(v.id, at: at)
    var out = Out(dryRun: dry, changed: false, batchId: nil, exactAt: nil, plan: plan, note: nil)
    if !dry, plan.blocker == nil, !plan.unchanged {
      let r = try bulk.postAt([v.id], at: at)
      out.changed = r.changed.contains(v.id)
      out.batchId = r.batchId
      if let why = r.skipped[v.id] { out.plan?.blocker = why }
      wrote = out.changed
    }
    out.exactAt = try Planner(store: store).exactSlot(videoId: v.id)?.exactAt
    if json { try printJSON(out); return out.plan?.blocker == nil ? 0 : 2 }
    if let why = out.plan?.blocker {
      print("\(v.tag): not set. \(why)")
      return 2
    }
    print("\(dry ? "[dry run] " : "")\(v.tag): \(plan.unchanged ? "already set for \(when(plan.at))" : plan.summary)")
    for l in plan.platforms {
      print("  \(pad(l.platform.displayName, 14)) \(when(l.at))\(l.retry ? "  (its retry)" : "")\(l.moved ? "  (moved: YouTube's quiet window, 07:30 UTC)" : "")")
    }
    for s in plan.skipped { print("  \(pad(s.platform.displayName, 14)) no post: \(s.why)") }
    for n in plan.notes where !n.hasPrefix("YouTube moves") { print("  note: \(n)") }
    for s in plan.replaces {
      print("  replaces \(s.exactAt.map { "the set time \(when($0))" } ?? "its day \(fmt(DayMath(settings: settings).date(s.date), settings, "EEE d MMM"))")")
    }
    if let b = out.batchId { print("  undo: djq bulk undo \(short(b))") }
    return 0
  }

  // MARK: Words for the other commands

  /// `djq week`: " set time 3:15 PM" for a set-time slot, " pinned" for a pinned one.
  static func mark(_ s: PlanSlot, _ settings: Settings) -> String {
    if let at = s.exactAt { return " " + StageWording.setTimeMark(at, settings: settings) }
    return s.pinned ? " pinned" : ""
  }

  /// `djq today` / `djq posts`: "  [set time]" on a post that goes out at a set time.
  static func postMark(_ store: Store, _ p: PlatformPost) -> String {
    guard p.kind == .regular, let id = p.planSlotId,
          (try? store.planSlots(where: "id=? AND exact_at IS NOT NULL", [id]))?.isEmpty == false else { return "" }
    return "  [set time]"
  }

  /// `djq status`: " · 2 at a set time" (nothing when none is ahead).
  static func statusNote(_ store: Store) -> String {
    let n = (try? store.planSlots(where: "exact_at>?", [store.clock.now]))?.count ?? 0
    return n == 0 ? "" : " · \(n) at a set time"
  }
}
