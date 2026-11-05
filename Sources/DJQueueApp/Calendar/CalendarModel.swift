import DJQCore
import Foundation

/// The Calendar's four views (B2). Each has a key, a span and a remembered place in UserDefaults.
enum CalendarViewMode: String, CaseIterable, Identifiable {
  case day, threeDay, week, month
  var id: String { rawValue }

  var title: String {
    switch self {
    case .day: "Day"
    case .threeDay: "3 Day"
    case .week: "Week"
    case .month: "Month"
    }
  }

  /// The single key that switches to this view (shown in its tooltip and the cheat sheet).
  var key: String {
    switch self {
    case .day: "D"
    case .threeDay: "3"
    case .week: "W"
    case .month: "M"
    }
  }

  /// What ‹ › step by, for their tooltips: "Show the previous 3 days".
  var stepName: String {
    switch self {
    case .day: "day"
    case .threeDay: "3 days"
    case .week: "week"
    case .month: "month"
    }
  }
}

/// An inclusive range of day keys ("2026-11-05"); keys sort as dates.
struct CalendarRange: Equatable, Sendable {
  var first: String
  var last: String

  func contains(_ day: String) -> Bool { first <= day && day <= last }
  func covers(_ other: CalendarRange) -> Bool { first <= other.first && other.last <= last }

  /// What the view shows around `anchor`: Day = the anchor, 3 Day = the anchor and the next two, Week = the week
  /// that holds it (from `weekStartsOn`), Month = whole weeks from the one holding the 1st to the one holding the last.
  static func visible(_ mode: CalendarViewMode, anchor: String, dm: DayMath) -> CalendarRange {
    switch mode {
    case .day:
      return CalendarRange(first: anchor, last: anchor)
    case .threeDay:
      return CalendarRange(first: anchor, last: dm.addDays(anchor, 2))
    case .week:
      let start = dm.weekStart(of: dm.date(anchor))
      return CalendarRange(first: start, last: dm.addDays(start, 6))
    case .month:
      let (first, last) = monthBounds(anchor, dm: dm)
      let gridStart = dm.weekStart(of: dm.date(first))
      let lastWeek = dm.weekStart(of: dm.date(last))
      return CalendarRange(first: gridStart, last: dm.addDays(lastWeek, 6))
    }
  }

  /// The anchor's month: its first and last day.
  static func monthBounds(_ anchor: String, dm: DayMath) -> (first: String, last: String) {
    let cal = dm.calendar
    let c = cal.dateComponents([.year, .month], from: dm.date(anchor))
    let start = cal.date(from: c) ?? dm.date(anchor)
    let next = cal.date(byAdding: .month, value: 1, to: start) ?? start
    return (dm.key(start), dm.addDays(dm.key(next), -1))
  }

  /// The anchor one step on: 1, 3 or 7 days, or one month (the same day of the month where it exists).
  static func stepped(_ anchor: String, mode: CalendarViewMode, by n: Int, dm: DayMath) -> String {
    switch mode {
    case .day: dm.addDays(anchor, n)
    case .threeDay: dm.addDays(anchor, 3 * n)
    case .week: dm.addDays(anchor, 7 * n)
    case .month: dm.key(dm.calendar.date(byAdding: .month, value: n, to: dm.date(anchor)) ?? dm.date(anchor))
    }
  }

  /// What gets loaded: the visible range plus one span each side, so stepping lands on data already in memory
  /// while the next load runs (B13).
  func padded(dm: DayMath) -> CalendarRange {
    let span = dayCount(dm: dm)
    return CalendarRange(first: dm.addDays(first, -span), last: dm.addDays(last, span))
  }

  func dayCount(dm: DayMath) -> Int {
    (dm.calendar.dateComponents([.day], from: dm.date(first), to: dm.date(last)).day ?? 0) + 1
  }

  func days(dm: DayMath) -> [String] {
    (0..<dayCount(dm: dm)).map { dm.addDays(first, $0) }
  }
}

/// The loaded range's slots and posts, indexed by day off the main actor so `body` never touches the database or
/// walks every post (B13).
struct CalendarData {
  /// What this was loaded for; nil until the first load lands.
  var range: CalendarRange?
  /// Plan slots by day, in position order.
  var slots: [String: [PlanSlot]] = [:]
  /// The same slots by id (a post's own slot, for a post shifted to another day).
  var slotById: [String: PlanSlot] = [:]
  /// Every post scheduled on a day, in time order (`planSlotId == nil` = a retry or repost).
  var posts: [String: [PlatformPost]] = [:]
  var awake: [DateInterval] = []
  /// The day `awake` starts from; nil = not loaded (Month has no strip).
  var awakeFrom: String?

  static func load(store: Store, posts: [PlatformPost], range: CalendarRange, awakeFrom: String?, dm: DayMath) throws -> CalendarData {
    var d = CalendarData(range: range, awakeFrom: awakeFrom)
    let slots = try store.planSlots(where: "date>=? AND date<=?", [range.first, range.last])
    d.slots = Dictionary(grouping: slots, by: \.date).mapValues { $0.sorted { $0.position < $1.position } }
    d.slotById = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
    let shown = posts.compactMap { p -> (String, PlatformPost)? in
      let key = dm.key(p.scheduledAt)
      return range.contains(key) ? (key, p) : nil
    }
    d.posts = Dictionary(grouping: shown, by: \.0).mapValues { $0.map(\.1).sorted { $0.scheduledAt < $1.scheduledAt } }
    if let awakeFrom { d.awake = try Health.awakePeriods(store: store, since: dm.date(awakeFrom)) }
    return d
  }
}

/// One clip on one day: its slot, its latest post per platform, and the platforms the filter leaves showing.
struct CalendarClip: Identifiable {
  let slot: PlanSlot
  let video: Video
  /// Latest attempt per platform (all platforms: moves and blockers read these, whatever the filter shows).
  let posts: [Platform: PlatformPost]
  /// Platforms going out on this day, in Settings order. A post shifted to another day shows there instead; a slot
  /// with no posts yet shows the platforms it will post to.
  let platforms: [Platform]
  var id: String { slot.id }
}

/// Day view: one clip's posts on that day. `slot` is nil for a post with no plan slot (a retry or repost).
struct CalendarDayGroup: Identifiable {
  let videoId: String
  let video: Video?
  let slot: PlanSlot?
  let posts: [PlatformPost]
  let platforms: [Platform]
  var id: String { videoId }
}
