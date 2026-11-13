import DJQCore
import Foundation

/// Round 31 (DECISIONS-R31.md): every version post is its own post in the plan. The words for one ("v2 · 1 of 2") come
/// from `unitBook`, loaded off-main with every refresh; nothing here reads the database.
extension AppModel {
  /// "v2 · 1 of 2" ("v2" when that version posts once). A clip the book doesn't know (long-form) says its version only.
  func unitLabel(_ videoId: String, _ u: PostUnit) -> String {
    guard let book = unitBook, book[videoId] != nil else { return u.label(of: 1) }
    return book.label(videoId, u)
  }

  func unitLabel(_ slot: PlanSlot) -> String { unitLabel(slot.videoId, slot.unit) }
  func unitLabel(_ post: PlatformPost) -> String { unitLabel(post.videoId, post.unit) }

  /// "Version 2, post 1 of 2 on each platform" (hover).
  func unitHelp(_ videoId: String, _ u: PostUnit) -> String {
    let label = unitLabel(videoId, u)
    return UnitLines.meaning(u, label: label) + (label.contains(" of ") ? " on each platform" : "")
  }

  func unitHelp(_ slot: PlanSlot) -> String { unitHelp(slot.videoId, slot.unit) }

  /// The unit going out on the clip's next day (the Queue's date chip), nil when it has no day.
  func nextUnitLabel(_ videoId: String) -> String? { nextSlotByVideo[videoId].map(unitLabel) }

  /// "Sat 16" for a version post's tag; "Today" for today.
  func unitDayText(_ day: String) -> String { day == todayKey ? "Today" : Fmt.day(dm.date(day), tz: tz, style: "EEE d") }

  /// The Queue card's other version posts (the next one rides on the date chip): small tags in planning order. The card
  /// shows as many as fit and "+N" (`DSClipCard`). None when the clip has only the one post.
  func unitTags(_ videoId: String) -> [DSClipTag] {
    let lines = unitLines[videoId] ?? []
    guard lines.count > 1 else { return [] }
    return UnitLines.others(lines, next: nextSlotByVideo[videoId]?.unit, cap: .max).shown.map { l in
      DSClipTag(text: UnitLines.tagText(l, day: unitDayText), style: l.state == .done ? .soft(.neutral) : .outline,
                tooltip: UnitLines.tagHelp(l, day: unitDayText), size: .sm)
    }
  }
}
