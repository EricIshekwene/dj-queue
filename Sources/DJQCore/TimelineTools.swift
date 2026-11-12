import Foundation

/// Round 24: the editor timeline's precision tools, pure so the rules are unit-tested. Eric found the trim handles too
/// hard to grab and too coarse (a 30-minute file packs 2–3 seconds into every point), and asked for his own markers
/// (M) that everything dragged on the timeline snaps to.

/// Which trim handle: the start or the end.
public enum TrimEdge: String, Sendable, Equatable {
  case start, end
  public var title: String { self == .start ? "Start" : "End" }
}

/// The part of the clip file the timeline shows. The whole file is "fit"; zooming narrows it around a time.
public struct TimelineViewport: Equatable, Sendable {
  public var start: Double
  public var end: Double
  public init(start: Double, end: Double) { self.start = start; self.end = end }

  public var span: Double { max(end - start, 0) }
  /// The narrowest view: a few seconds (or the whole file when it's shorter).
  public static let minSpan = 3.0
  /// One zoom step (a button, a key, a notch).
  public static let step = 2.0

  public static func fit(_ duration: Double) -> TimelineViewport { TimelineViewport(start: 0, end: max(duration, 0)) }

  /// What a clip opens at. A long file (the trim is under a third of it, like a whole set exported as one file) opens
  /// on the trim with some room either side, so the handles can be dragged a frame at a time; anything else shows the
  /// whole file, as before.
  public static func initial(duration: Double, trim: TrimRange) -> TimelineViewport {
    guard duration > 0, trim.duration > 0, trim.duration * 3 < duration else { return fit(duration) }
    let pad = max(trim.duration * 0.35, 3)
    return TimelineViewport(start: trim.start - pad, end: trim.end + pad).clamped(duration)
  }

  public func isZoomed(_ duration: Double) -> Bool { duration > 0 && span < duration - 0.001 }

  /// Kept inside the file, at least `minSpan` wide (or the whole file).
  public func clamped(_ duration: Double) -> TimelineViewport {
    guard duration > 0 else { return TimelineViewport(start: 0, end: 0) }
    let s = min(max(span, min(Self.minSpan, duration)), duration)
    var a = start
    if a < 0 { a = 0 }
    if a + s > duration { a = duration - s }
    return TimelineViewport(start: a, end: a + s)
  }

  /// `factor` > 1 zooms in, < 1 out. `t` stays where it is on screen (the playhead, or the point under a pinch).
  public func zoomed(by factor: Double, around t: Double, duration: Double) -> TimelineViewport {
    guard duration > 0, factor > 0, span > 0 else { return Self.fit(duration) }
    let s = min(max(span / factor, min(Self.minSpan, duration)), duration)
    let anchor = min(max(t, start), end)
    let frac = (anchor - start) / span
    return TimelineViewport(start: anchor - frac * s, end: anchor - frac * s + s).clamped(duration)
  }

  public func panned(by dt: Double, duration: Double) -> TimelineViewport {
    TimelineViewport(start: start + dt, end: end + dt).clamped(duration)
  }

  /// Moved (never zoomed) so `t` is in view with a margin: playback running past the edge, a handle dragged or nudged
  /// past it. Unchanged when `t` is already in view.
  public func revealing(_ t: Double, duration: Double, margin: Double = 0.08) -> TimelineViewport {
    guard span > 0 else { return self }
    let m = span * margin
    if t < start + m { return panned(by: t - (start + m), duration: duration) }
    if t > end - m { return panned(by: t - (end - m), duration: duration) }
    return self
  }

  /// Playback leaving the view: the next page (or the trim start after a loop), the playhead a little in. Unchanged
  /// while it's in view, so the view moves once per screenful, not every frame.
  public func paged(to t: Double, duration: Double) -> TimelineViewport {
    guard span > 0, t < start || t > end - span * 0.01 else { return self }
    let a = t - span * 0.05
    return TimelineViewport(start: a, end: a + span).clamped(duration)
  }

  // MARK: x ↔ time

  public func x(_ t: Double, width: Double) -> Double { span > 0 ? (t - start) / span * width : 0 }
  public func t(_ x: Double, width: Double, duration: Double) -> Double {
    min(max(start + x / max(width, 1) * span, 0), duration)
  }
  /// Seconds one point is worth at this zoom.
  public func secondsPerPoint(width: Double) -> Double { span / max(width, 1) }

  /// Ruler ticks: a round step that leaves at least `minGap` points between labels.
  public func ticks(width: Double, minGap: Double = 64) -> (step: Double, times: [Double]) {
    guard span > 0, width > 0 else { return (1, []) }
    let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    let need = minGap * span / width
    let step = steps.first { $0 >= need } ?? steps.last!
    var t = (start / step).rounded(.up) * step
    var out: [Double] = []
    while t <= end + 0.0001 && out.count < 400 { out.append(t); t += step }
    return (step, out)
  }
}

/// Eric's own timeline markers (round 24): absolute seconds in the clip file, kept sorted in `Edit.marks`.
public enum TimelineMarks {
  public static let maxCount = 200

  /// How close the playhead must be for M to remove a marker instead of adding one: half a frame, at least 40 ms.
  public static func hitTolerance(fps: Double) -> Double { max(0.5 / max(fps, 1), 0.04) }

  /// Sorted, inside the file, rounded to a millisecond, no two closer than a millisecond, at most `maxCount`.
  public static func normalized(_ marks: [Double], duration: Double) -> [Double] {
    var out: [Double] = []
    for m in marks.filter({ $0.isFinite }).map({ ($0 * 1000).rounded() / 1000 }).sorted()
    where m >= 0 && (duration <= 0 || m <= duration) {
      if let last = out.last, m - last < 0.001 { continue }
      out.append(m)
    }
    return Array(out.prefix(maxCount))
  }

  /// The marker within `tolerance` of `t`, nearest first.
  public static func index(near t: Double, in marks: [Double], tolerance: Double) -> Int? {
    guard let i = marks.indices.min(by: { abs(marks[$0] - t) < abs(marks[$1] - t) }), abs(marks[i] - t) <= tolerance else {
      return nil
    }
    return i
  }

  /// M at the playhead: removes the marker it's on, otherwise adds one there.
  public static func toggled(_ marks: [Double], at t: Double, fps: Double, duration: Double) -> (marks: [Double], added: Bool) {
    if let i = index(near: t, in: marks, tolerance: hitTolerance(fps: fps)) {
      var m = marks
      m.remove(at: i)
      return (m, false)
    }
    return (normalized(marks + [t], duration: duration), true)
  }

  /// A marker dragged from `old` to `new`.
  public static func moved(_ marks: [Double], from old: Double, to new: Double, duration: Double) -> [Double] {
    guard let i = index(near: old, in: marks, tolerance: 0.0005) else { return marks }
    var m = marks
    m[i] = min(max(new, 0), duration)
    return normalized(m, duration: duration)
  }

  /// The next marker after `t` (direction 1) or before it (-1), nil past the last one.
  public static func neighbour(of t: Double, in marks: [Double], direction: Int) -> Double? {
    direction > 0 ? marks.first { $0 > t + 0.001 } : marks.last { $0 < t - 0.001 }
  }
}

/// A trim handle being dragged (round 24). The handle follows the pointer's movement from where it was pressed, so
/// a press never makes it jump; with ⌥ held it moves a tenth as fast and doesn't snap. `raw` is where the pointer
/// "really" is, so a snap never sticks: leave the snap distance and the handle lets go.
public struct TrimDrag: Equatable, Sendable {
  public static let fineFactor = 0.1
  public var raw: Double
  private var lastDX: Double = 0

  public init(edgeTime: Double) { raw = edgeTime }

  /// `dx` = points from the press; returns the unsnapped time.
  public mutating func move(dx: Double, secondsPerPoint: Double, fine: Bool) -> Double {
    raw += (dx - lastDX) * secondsPerPoint * (fine ? Self.fineFactor : 1)
    lastDX = dx
    return raw
  }
}

public enum TrimRules {
  /// The shortest trim the handles allow.
  public static let minLength = 0.5

  /// Where an edge goes, kept inside the file and at least `minLength` from the other edge.
  public static func clampedEdge(_ edge: TrimEdge, _ t: Double, trim: TrimRange, duration: Double) -> Double {
    switch edge {
    case .start: return max(0, min(t, trim.end - minLength))
    case .end: return min(duration, max(t, trim.start + minLength))
    }
  }

  /// ← / → with a handle selected: the arrow step, ⇧ one frame (the same keys as the playhead).
  public static func nudged(_ edge: TrimEdge, trim: TrimRange, step: ArrowStep, fps: Double, direction: Int, fine: Bool,
                            duration: Double) -> Double {
    let amount = fine ? ArrowStep.frame.seconds(fps: fps) : step.seconds(fps: fps)
    let from = edge == .start ? trim.start : trim.end
    return clampedEdge(edge, from + Double(direction.signum()) * amount, trim: trim, duration: duration)
  }

  /// Where a trim handle is drawn (`visible`, its left x) and grabbed (`grab` … `grab + grabWidth`), with the trim at
  /// `a` … `b` points. Inside the trim normally, grabbable `reachOut` outside it; a trim too narrow for two handles has
  /// them outside it, start left and end right, each grabbable up to the middle, so neither covers the other.
  public static func handleLayout(_ edge: TrimEdge, a: Double, b: Double, handleW: Double, reachOut: Double,
                                  reachIn: Double) -> (visible: Double, grab: Double, grabWidth: Double) {
    let w = max(b - a, 0), half = w / 2
    if w < 2 * handleW + 8 {
      switch edge {
      case .start: let g = a - handleW - reachOut / 2; return (a - handleW, g, a + half - g)
      case .end: let g = b - half; return (b, g, b + handleW + reachOut / 2 - g)
      }
    }
    let inner = min(handleW + reachIn, half)
    switch edge {
    case .start: return (a, a - reachOut, reachOut + inner)
    case .end: return (b - handleW, b - inner, inner + reachOut)
    }
  }

  /// Snap targets for a trim handle: clip ends, the CapCut in/out markers and Eric's own markers.
  public static func snapTargets(duration: Double, markers: [Double?], marks: [Double]) -> [Double] {
    EditorLogic.trimSnapTargets(duration: duration, markers: markers) + marks.filter { $0 >= 0 && $0 <= duration }
  }
}
