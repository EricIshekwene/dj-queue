import DJQCore
import SwiftUI

/// Week screen reads (Planning leaf).
extension AppModel {
  /// The week the Week screen shows (Monday key per Settings).
  var shownWeek: String { weekStart.isEmpty ? planner.weekStart(for: now) : weekStart }
  var thisWeek: String { planner.weekStart(for: now) }

  /// Draft · Approved · Locked (approved and started: past days fixed, future days still editable).
  enum WeekStatus { case draft, approved, locked }

  func weekStatus(_ ws: String) -> WeekStatus? {
    guard let st = weekStates[ws] else { return nil }
    if st == .approved { return ws <= todayKey ? .locked : .approved }
    return .draft
  }

  /// Ready clips not planned on any upcoming day, in queue order (the backlog drawer).
  var weekBacklog: [Video] {
    let planned = Set(upcomingSlots.map(\.videoId))
    return ordered.filter { !planned.contains($0.id) }
  }

  /// Latest attempt per platform for a plan slot.
  func slotPosts(_ slotId: String) -> [Platform: PlatformPost] {
    Dictionary((postsBySlot[slotId] ?? []).map { ($0.platform, $0) }, uniquingKeysWith: { a, b in a.attemptNo > b.attemptNo ? a : b })
  }

  /// "Week of 2 Nov".
  func weekTitle(_ ws: String) -> String { "Week of \(Fmt.day(dm.date(ws), tz: tz, style: "d MMM"))" }

  /// "This week" / "Next week" / "Last week" / "26 Oct – 1 Nov".
  func weekContext(_ ws: String) -> String {
    let tw = thisWeek
    if ws == tw { return "This week" }
    if ws == dm.addDays(tw, 7) { return "Next week" }
    if ws == dm.addDays(tw, -7) { return "Last week" }
    return "\(Fmt.day(dm.date(ws), tz: tz, style: "d MMM")) – \(Fmt.day(dm.date(dm.addDays(ws, 6)), tz: tz, style: "d MMM"))"
  }
}
