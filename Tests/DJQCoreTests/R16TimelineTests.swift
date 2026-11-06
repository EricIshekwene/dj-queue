import XCTest

@testable import DJQCore

final class R16TimelineTests: XCTestCase {
  private func layer(_ start: Double?, _ end: Double?, id: String = "x") -> TextLayer {
    TextLayer(id: id, text: "t", start: start, end: end)
  }

  func testNoOverlapStaysInOneLane() {
    XCTAssertEqual(TextTimeline.lanes([(0, 2), (2, 4), (5, 6)]), [0, 0, 0], "touching ends don't overlap")
  }

  func testOverlapsTakeTheLowestFreeLane() {
    XCTAssertEqual(TextTimeline.lanes([(0, 10), (1, 3), (2, 4), (3.5, 5)]), [0, 1, 2, 1])
  }

  func testMoreThanTheMostLanesShareTheLastOne() {
    let spans: [TextTimeline.Span] = Array(repeating: (0, 5), count: 7)
    XCTAssertEqual(TextTimeline.lanes(spans), [0, 1, 2, 3, 3, 3, 3])
    XCTAssertEqual(TextTimeline.lanes([]), [])
  }

  func testALaterTextNeverMovesAnEarlierOne() {
    let a: [TextTimeline.Span] = [(0, 4), (1, 3)]
    XCTAssertEqual(Array(TextTimeline.lanes(a + [(0, 9)]).prefix(2)), TextTimeline.lanes(a))
  }

  func testFirstTextSpanFollowsItsWindowRule() {
    let f = { (s: Double?, e: Double?) in TextLayer(id: TextLayer.firstId, text: "t", start: s, end: e) }
    XCTAssertEqual(TextTimeline.span(f(nil, nil), trimDuration: 10).end, 10)
    XCTAssertEqual(TextTimeline.span(f(2, 5), trimDuration: 10).start, 2)
    let inverted = TextTimeline.span(f(5, 0), trimDuration: 10)
    XCTAssertEqual(inverted.start, 0); XCTAssertEqual(inverted.end, 10)
    XCTAssertEqual(TextTimeline.span(f(12, nil), trimDuration: 10).start, 0, "past the end = the whole clip")
  }

  func testAnExtraTheTrimLeavesOutStaysPickable() {
    let s = TextTimeline.span(layer(12, 14), trimDuration: 10)
    XCTAssertEqual(s.start, 9.7, accuracy: 1e-9); XCTAssertEqual(s.end, 10, accuracy: 1e-9)
  }

  func testNewWindowAtThePlayhead() {
    var w = TextTimeline.newWindow(playhead: 2, trimDuration: 10)
    XCTAssertEqual(w.start, 2); XCTAssertEqual(w.end, 5)
    w = TextTimeline.newWindow(playhead: 8.5, trimDuration: 10)
    XCTAssertEqual(w.end, 10, "cut at the clip end")
    w = TextTimeline.newWindow(playhead: 20, trimDuration: 10)
    XCTAssertEqual(w.start, 9.7, accuracy: 1e-9); XCTAssertEqual(w.end, 10)
    w = TextTimeline.newWindow(playhead: -4, trimDuration: 10)
    XCTAssertEqual(w.start, 0)
  }

  func testDuplicateGoesAfterTheOriginalOrOnTop() {
    var d = TextTimeline.duplicateWindow((2, 4), trimDuration: 10)
    XCTAssertEqual(d.window.start, 4); XCTAssertEqual(d.window.end, 6); XCTAssertFalse(d.overlapsOriginal)
    d = TextTimeline.duplicateWindow((7, 9), trimDuration: 10)
    XCTAssertEqual(d.window.end, 10, "cut at the end")
    d = TextTimeline.duplicateWindow((0, 10), trimDuration: 10)
    XCTAssertTrue(d.overlapsOriginal); XCTAssertEqual(d.window.start, 0)
  }

  func testMoveKeepsLengthInsideTheTrim() {
    var m = TextTimeline.moved((2, 5), toStart: 8, trimDuration: 10)
    XCTAssertEqual(m.start, 7); XCTAssertEqual(m.end, 10)
    m = TextTimeline.moved((2, 5), toStart: -3, trimDuration: 10)
    XCTAssertEqual(m.start, 0); XCTAssertEqual(m.end, 3)
    m = TextTimeline.moved((0, 20), toStart: 4, trimDuration: 10)
    XCTAssertEqual(m.start, 0); XCTAssertEqual(m.end, 10)
  }

  func testBodyDragSnapsTheNearerEnd() {
    let s: TextTimeline.Span = (2, 5)
    XCTAssertEqual(TextTimeline.snappedStart(s, proposed: 4.05, targets: [4], tolerance: 0.1), 4)
    XCTAssertEqual(TextTimeline.snappedStart(s, proposed: 3.95, targets: [7], tolerance: 0.1), 4, "the end snaps")
    XCTAssertEqual(TextTimeline.snappedStart(s, proposed: 4.04, targets: [4, 7.1], tolerance: 0.1), 4, "both: the nearer")
    XCTAssertEqual(TextTimeline.snappedStart(s, proposed: 3.5, targets: [9], tolerance: 0.1), 3.5)
  }

  func testGripsKeepTheShortestWindow() {
    XCTAssertEqual(TextTimeline.clampedStart(4.9, end: 5, trimDuration: 10), 4.7, accuracy: 1e-9)
    XCTAssertEqual(TextTimeline.clampedStart(0.01, end: 5, trimDuration: 10), 0, "the very start is 0")
    XCTAssertEqual(TextTimeline.clampedEnd(2.1, start: 2, trimDuration: 10), 2.3, accuracy: 1e-9)
    XCTAssertEqual(TextTimeline.clampedEnd(20, start: 2, trimDuration: 10), 10)
  }

  func testClearYStaysInFrame() {
    XCTAssertEqual(TextTimeline.clearY(0.5), 0.6, accuracy: 1e-9)
    XCTAssertEqual(TextTimeline.clearY(0.9), 0.8, accuracy: 1e-9)
  }

  func testTypedTimes() {
    XCTAssertEqual(TextTimeline.parse("3"), 3)
    XCTAssertEqual(TextTimeline.parse(" 3.5 "), 3.5)
    XCTAssertEqual(TextTimeline.parse("0:03.5"), 3.5)
    XCTAssertEqual(TextTimeline.parse("1:02"), 62)
    XCTAssertEqual(TextTimeline.parse("3,5"), 3.5)
    for bad in ["", "abc", "1:", ":5", "1:2:3", "1:75", "-2", "1e3", "."] { XCTAssertNil(TextTimeline.parse(bad), bad) }
  }

  func testATimeShownParsesBack() {
    for t in [0, 0.3, 3.2, 59.9, 61.5] {
      XCTAssertEqual(TextTimeline.parse(EditorLogic.time(t, tenths: true)) ?? -1, t, accuracy: 0.051)
    }
  }
}
