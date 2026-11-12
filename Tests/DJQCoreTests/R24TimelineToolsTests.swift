import Foundation
import Testing
@testable import DJQCore

/// Round 24: trim handles that are easy to drag precisely (zoom, fine drag, nudge) and Eric's own markers (M) that the
/// timeline snaps to.
@Suite struct R24TimelineToolsTests {
  // MARK: Viewport

  @Test func aLongFileOpensOnItsTrimAShortOneShowsEverything() {
    let long = TimelineViewport.initial(duration: 1800, trim: TrimRange(start: 600, end: 630))
    #expect(long.start < 600 && long.end > 630)
    #expect(long.span < 60)
    #expect(long.isZoomed(1800))
    let short = TimelineViewport.initial(duration: 30, trim: TrimRange(start: 2, end: 28))
    #expect(short == .fit(30))
    #expect(!short.isZoomed(30))
  }

  @Test func zoomKeepsThePointInPlaceAndStaysInTheFile() {
    let v = TimelineViewport.fit(100)
    let z = v.zoomed(by: 2, around: 25, duration: 100)
    #expect(abs(z.span - 50) < 1e-9)
    // 25 was a quarter of the way across and still is.
    #expect(abs((25 - z.start) / z.span - 0.25) < 1e-9)
    let edge = v.zoomed(by: 4, around: 99, duration: 100)
    #expect(edge.end <= 100 && edge.start >= 0)
    // Never narrower than the minimum, never wider than the file.
    var tight = v
    for _ in 0..<20 { tight = tight.zoomed(by: 2, around: 50, duration: 100) }
    #expect(abs(tight.span - TimelineViewport.minSpan) < 1e-9)
    #expect(tight.zoomed(by: 0.001, around: 50, duration: 100) == .fit(100))
  }

  @Test func panAndRevealStayInsideTheFile() {
    let v = TimelineViewport(start: 10, end: 20)
    #expect(v.panned(by: -50, duration: 100) == TimelineViewport(start: 0, end: 10))
    #expect(v.panned(by: 500, duration: 100) == TimelineViewport(start: 90, end: 100))
    #expect(v.revealing(15, duration: 100) == v)
    let r = v.revealing(30, duration: 100)
    #expect(r.span == v.span && r.start <= 30 && r.end >= 30)
  }

  @Test func xAndTimeRoundTripThroughTheZoom() {
    let v = TimelineViewport(start: 100, end: 110)
    #expect(v.x(105, width: 1000) == 500)
    #expect(abs(v.t(500, width: 1000, duration: 1800) - 105) < 1e-9)
    #expect(abs(v.secondsPerPoint(width: 1000) - 0.01) < 1e-12)
  }

  @Test func rulerTicksAreRoundAndSpaced() {
    let v = TimelineViewport.fit(60)
    let t = v.ticks(width: 600, minGap: 64)
    #expect(t.step == 10)
    #expect(t.times.first == 0 && t.times.last == 60)
    let z = TimelineViewport(start: 3.3, end: 6.3).ticks(width: 600, minGap: 64)
    #expect(z.step == 0.5)
    #expect(z.times.first == 3.5)
  }

  // MARK: Markers

  @Test func mAddsAMarkerAndMOnItRemovesIt() {
    var r = TimelineMarks.toggled([], at: 12.3456, fps: 30, duration: 60)
    #expect(r.added && r.marks == [12.346])
    r = TimelineMarks.toggled(r.marks, at: 5, fps: 30, duration: 60)
    #expect(r.marks == [5, 12.346])
    // Within half a frame of a marker: it goes.
    r = TimelineMarks.toggled(r.marks, at: 12.36, fps: 30, duration: 60)
    #expect(!r.added && r.marks == [5])
  }

  @Test func markersAreSortedInsideTheFileAndNeverDoubled() {
    #expect(TimelineMarks.normalized([9, -1, 3, 3.0004, 70, .nan], duration: 60) == [3, 9])
    #expect(TimelineMarks.moved([3, 9], from: 9, to: 1, duration: 60) == [1, 3])
    #expect(TimelineMarks.moved([3, 9], from: 4, to: 1, duration: 60) == [3, 9])
    #expect(TimelineMarks.neighbour(of: 3, in: [3, 9], direction: 1) == 9)
    #expect(TimelineMarks.neighbour(of: 3, in: [3, 9], direction: -1) == nil)
  }

  @Test func marksSurviveTheEditJSONAndStayOutOfItWhenEmpty() throws {
    var e = Edit()
    let empty = String(data: try JSONEncoder().encode(e), encoding: .utf8)!
    #expect(!empty.contains("marks"))
    e.marks = [1.5, 4]
    let back = try JSONDecoder().decode(Edit.self, from: JSONEncoder().encode(e))
    #expect(back.marks == [1.5, 4])
    let old = try JSONDecoder().decode(Edit.self, from: Data(#"{"trimIn":2}"#.utf8))
    #expect(old.marks.isEmpty && old.trimIn == 2)
    #expect(!e.isEmpty)
  }

  // MARK: Trim handles

  @Test func aDragFollowsThePointerFromThePressAndOptionIsFine() {
    var d = TrimDrag(edgeTime: 10)
    #expect(d.move(dx: 0, secondsPerPoint: 0.1, fine: false) == 10)
    #expect(abs(d.move(dx: 20, secondsPerPoint: 0.1, fine: false) - 12) < 1e-9)
    // ⌥ held from here: the next 20 points are worth a tenth.
    #expect(abs(d.move(dx: 40, secondsPerPoint: 0.1, fine: true) - 12.2) < 1e-9)
    // Let go of ⌥: full speed again, from where it was.
    #expect(abs(d.move(dx: 30, secondsPerPoint: 0.1, fine: false) - 11.2) < 1e-9)
  }

  @Test func edgesKeepHalfASecondApartAndInsideTheFile() {
    let tr = TrimRange(start: 10, end: 20)
    #expect(TrimRules.clampedEdge(.start, 19.9, trim: tr, duration: 30) == 19.5)
    #expect(TrimRules.clampedEdge(.start, -3, trim: tr, duration: 30) == 0)
    #expect(TrimRules.clampedEdge(.end, 10.2, trim: tr, duration: 30) == 10.5)
    #expect(TrimRules.clampedEdge(.end, 99, trim: tr, duration: 30) == 30)
  }

  @Test func arrowsNudgeASelectedEdgeByTheStepAndShiftByAFrame() {
    let tr = TrimRange(start: 10, end: 20)
    #expect(TrimRules.nudged(.end, trim: tr, step: .twoSeconds, fps: 30, direction: -1, fine: false, duration: 30) == 18)
    #expect(abs(TrimRules.nudged(.start, trim: tr, step: .twoSeconds, fps: 30, direction: 1, fine: true, duration: 30) - (10 + 1.0 / 30)) < 1e-9)
    #expect(TrimRules.nudged(.start, trim: tr, step: .tenSeconds, fps: 30, direction: 1, fine: false, duration: 30) == 19.5)
  }

  @Test func handlesSnapToEricsMarkersToo() {
    let c = TrimRules.snapTargets(duration: 60, markers: [5, nil], marks: [12, 80])
    #expect(c.contains(12) && c.contains(5) && c.contains(0) && c.contains(60) && !c.contains(80))
    #expect(EditorLogic.snap(12.05, to: c, tolerance: 0.1).value == 12)
  }

  @Test func handlesNeverCoverEachOther() {
    for w in [0.0, 1, 10, 30, 36, 37, 60, 400] {
      let s = TrimRules.handleLayout(.start, a: 100, b: 100 + w, handleW: 14, reachOut: 10, reachIn: 8)
      let e = TrimRules.handleLayout(.end, a: 100, b: 100 + w, handleW: 14, reachOut: 10, reachIn: 8)
      #expect(s.grab + s.grabWidth <= e.grab + 0.0001, "grab areas overlap at \(w) pt")
      #expect(s.visible + 14 <= e.visible + 0.0001, "handles drawn over each other at \(w) pt")
      #expect(s.grabWidth >= 14 && e.grabWidth >= 14, "too small to grab at \(w) pt")
    }
    // A normal trim: inside, 32 pt to grab, starting 10 pt outside.
    let s = TrimRules.handleLayout(.start, a: 100, b: 500, handleW: 14, reachOut: 10, reachIn: 8)
    #expect(s.visible == 100 && s.grab == 90 && s.grabWidth == 32)
  }

  @Test func playbackPagesTheZoomedViewOncePerScreen() {
    let v = TimelineViewport(start: 10, end: 20)
    #expect(v.paged(to: 15, duration: 100) == v)
    let p = v.paged(to: 20.05, duration: 100)
    #expect(p.span == 10 && p.start > 19 && p.start < 20)
    // A loop back to the trim start jumps back too.
    #expect(v.paged(to: 3, duration: 100).start < 3)
  }

  @Test func onlyAMarkerChangeIsMarksOnly() {
    var a = Edit(); a.trimIn = 2
    var b = a; b.marks = [4]
    #expect(b.differsOnlyInMarks(from: a))
    #expect(!a.differsOnlyInMarks(from: a))
    var c = b; c.trimOut = 9
    #expect(!c.differsOnlyInMarks(from: a))
  }

  // MARK: Keys

  func act(_ code: UInt16, _ chars: String? = nil, shift: Bool = false, focus: EditorKeys.Focus = .none,
           edge: Bool = false) -> EditorKeyAction? {
    EditorKeys.action(keyCode: code, characters: chars, shift: shift, commandLike: false, focus: focus, covered: false,
                      hasClip: true, trimEdgeSelected: edge)
  }

  @Test func mMarksAndZoomKeysWorkOutsideTextOnly() {
    #expect(act(46, "m") == .toggleMarker)
    #expect(act(46, "M") == .toggleMarker)
    #expect(act(24, "=") == .zoom(1))
    #expect(act(27, "-") == .zoom(-1))
    #expect(act(46, "m", focus: .text) == nil)
  }

  @Test func aSelectedHandleTakesTheArrowsAndEscLetsItGo() {
    #expect(act(EditorKeys.left, edge: true) == .nudgeTrim(direction: -1, fine: false))
    #expect(act(EditorKeys.right, shift: true, edge: true) == .nudgeTrim(direction: 1, fine: true))
    #expect(act(EditorKeys.escape, edge: true) == .releaseTrimEdge)
    #expect(act(EditorKeys.left) == .seek(direction: -1, fine: false))
    // Typing keeps its keys even with a handle selected.
    #expect(act(EditorKeys.left, focus: .text, edge: true) == nil)
    #expect(act(EditorKeys.escape, focus: .text, edge: true) == .leaveTextField)
    // ↑ / ↓ still change clips.
    #expect(act(EditorKeys.down, edge: true) == .clip(1))
  }
}
