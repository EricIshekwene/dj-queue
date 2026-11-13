import Foundation
import Testing
@testable import DJQCore

/// Round 31 UI: the words the Queue card and the Calendar use for a clip's version posts (`UnitLines`).
@Suite struct R31UnitLinesTests {
  func line(_ v: Int, _ p: Int, _ state: UnitLine.State, of n: Int = 2) -> UnitLine {
    let u = PostUnit(version: v, post: p)
    return UnitLine(unit: u, label: u.label(of: n), state: state)
  }

  @Test func tagsLeaveOutTheNextPostAndCapTheRest() {
    let lines = [line(1, 1, .day("2026-11-14")), line(2, 1, .day("2026-11-17")), line(3, 1, .waiting),
                 line(1, 2, .waiting), line(2, 2, .waiting), line(3, 2, .waiting)]
    let (shown, more) = UnitLines.others(lines, next: .first)
    #expect(shown.map(\.unit) == [PostUnit(version: 2, post: 1), PostUnit(version: 3, post: 1), PostUnit(version: 1, post: 2)])
    #expect(more == 2)
    // Nothing on the date chip (no day yet): every post is a tag.
    #expect(UnitLines.others(lines, next: nil, cap: 9).shown.count == 6)
    #expect(UnitLines.others(lines, next: nil, cap: 9).more == 0)
  }

  @Test func tagAndDateChipText() {
    let day = { (d: String) in d == "2026-11-17" ? "Tue 17" : d }
    #expect(UnitLines.tagText(line(2, 1, .day("2026-11-17")), day: day) == "v2 · 1 of 2 · Tue 17")
    #expect(UnitLines.tagText(line(1, 2, .waiting), day: day) == "v1 · 2 of 2 · waiting")
    #expect(UnitLines.tagText(line(1, 1, .done), day: day) == "v1 · 1 of 2 · done")
    #expect(UnitLines.dateText("Thu 14 Nov", unit: "v1 · 1 of 2") == "Thu 14 Nov · v1 · 1 of 2")
    #expect(UnitLines.dateText("Not scheduled", unit: nil) == "Not scheduled")
    #expect(UnitLines.help(PostUnit(version: 2, post: 1), label: "v2 · 1 of 3") == "Version 2, post 1 of 3")
    #expect(UnitLines.help(PostUnit(version: 2, post: 1), label: "v2") == "Version 2")
    #expect(UnitLines.tagHelp(line(1, 2, .waiting), day: day).hasPrefix("Version 1, post 2 of 2 is waiting"))
  }

  /// From a real plan: the next post has a day, the rest wait, and a posted one reads done.
  @Test func linesFollowThePlan() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.postsPerDay = 1; $0.postsPerVersion = 2 }
    var v2 = Version(number: 2)
    v2.text = "Hook 2"
    v2.standalone = true
    try f.store.save(v2, videoId: "clip-0")
    try Planner(store: f.store).autoSchedule()
    let today = f.dm.key(f.store.clock.now)
    let upcoming = try f.store.planSlots(where: "date>=?", [today])
    let book = try UnitBook(store: f.store)
    let lines = book.lines("clip-0", upcoming: upcoming)
    #expect(lines.map(\.unit) == [PostUnit(version: 1, post: 1), PostUnit(version: 2, post: 1),
                                  PostUnit(version: 1, post: 2), PostUnit(version: 2, post: 2)])
    #expect(lines.map(\.label) == ["v1 · 1 of 2", "v2 · 1 of 2", "v1 · 2 of 2", "v2 · 2 of 2"])
    let mine = upcoming.filter { $0.videoId == "clip-0" }
    for l in lines {
      if let s = mine.filter({ $0.unit == l.unit }).map(\.date).min() {
        #expect(l.state == .day(s))
      } else {
        #expect(l.state == .waiting)
      }
    }
    #expect(lines.first?.state != .waiting, "the clip's first post has a day")
    // The other clip posts once per version it has.
    #expect(book.lines("clip-1", upcoming: upcoming).map(\.label) == ["v1 · 1 of 2", "v1 · 2 of 2"])
    // A clip the book doesn't know has no lines.
    #expect(book.lines("nope", upcoming: upcoming).isEmpty)
    // A version that posts once says only its version.
    try f.store.setPostCount(videoId: "clip-1", number: 1, 1)
    let one = try UnitBook(store: f.store).lines("clip-1", upcoming: [])
    #expect(one.map(\.label) == ["v1"])
    let slotted = !upcoming.filter { $0.videoId == "clip-1" }.isEmpty
    #expect(one.first?.state == (slotted ? .done : .waiting), "with its day not passed in, a slotted post reads done")
  }
}
