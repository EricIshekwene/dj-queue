import Foundation

/// The arithmetic of texts on the editor's timeline (round 16, S3-R3, S3-R5). Every time here is in seconds from the trim
/// start, as `TextLayer.start` / `end` are. Pure, so the lanes and drags are covered by `swift test`.
public enum TextTimeline {
  /// The shortest window a drag or a typed time leaves a text with (`EditorLogic.clampTextTiming`'s rule).
  public static let minLength = 0.3
  /// How long a new text shows.
  public static let newLength = 3.0
  /// Most lanes the timeline gives texts; more texts share the last one.
  public static let maxLanes = 4

  public typealias Span = (start: Double, end: Double)

  /// Where `l` sits on the timeline in a trim of `d` seconds. Nil ends mean the trim's ends. The first text follows its
  /// window rule (empty, inverted or past the end = the whole clip). Anything else stays inside the trim, as a sliver at
  /// the end when the trim leaves it out, so it can still be seen and picked up.
  public static func span(_ l: TextLayer, trimDuration d: Double) -> Span {
    let s = max(0, l.start ?? 0), e = min(d, l.end ?? d)
    if l.id == TextLayer.firstId { return e <= s || s >= d ? (0, d) : (s, e) }
    let start = min(s, max(0, d - minLength))
    return (start, max(e, min(d, start + minLength)))
  }

  /// A lane for each span, in list order: the lowest lane nothing overlaps, or a new one up to `maxLanes`, and past that
  /// the last lane. Touching ends don't overlap, and a text's lane depends only on the texts before it.
  public static func lanes(_ spans: [Span], maxLanes: Int = maxLanes) -> [Int] {
    var taken: [[Span]] = []
    return spans.map { s in
      if let i = taken.firstIndex(where: { lane in !lane.contains { s.start < $0.end && $0.start < s.end } }) {
        taken[i].append(s)
        return i
      }
      if taken.count < max(1, maxLanes) {
        taken.append([s])
        return taken.count - 1
      }
      taken[taken.count - 1].append(s)
      return taken.count - 1
    }
  }

  /// The window of a text added at `playhead`: `newLength` seconds or to the clip end. A playhead outside the trim starts
  /// it at the nearest place that still leaves it `minLength` to show.
  public static func newWindow(playhead: Double, trimDuration d: Double) -> Span {
    let start = min(max(0, playhead), max(0, d - minLength))
    return (start, min(d, start + newLength))
  }

  /// The window of a duplicate: straight after the original, same length, cut at the clip end. With no room there it
  /// keeps the original's window, and `overlapsOriginal` is true.
  public static func duplicateWindow(_ original: Span, trimDuration d: Double) -> (window: Span, overlapsOriginal: Bool) {
    guard d - original.end >= minLength else { return (original, true) }
    return ((original.end, min(d, original.end + (original.end - original.start))), false)
  }

  /// `y` moved clear of a text at the same place: a text added on top of another can't be read or picked up.
  public static func clearY(_ y: Double) -> Double { y > 0.85 ? y - 0.1 : y + 0.1 }

  /// `s` moved to start at `start`, keeping its length, inside the trim. A text longer than the trim fills it.
  public static func moved(_ s: Span, toStart start: Double, trimDuration d: Double) -> Span {
    let len = min(s.end - s.start, d)
    let a = min(max(0, start), d - len)
    return (a, a + len)
  }

  /// The start for dragging `s` to `start`: whichever of its two ends is nearer a target within `tolerance` snaps to it.
  public static func snappedStart(_ s: Span, proposed start: Double, targets: [Double], tolerance: Double) -> Double {
    let len = s.end - s.start
    let a = EditorLogic.snap(start, to: targets, tolerance: tolerance)
    let b = EditorLogic.snap(start + len, to: targets, tolerance: tolerance)
    switch (a.snapped, b.snapped) {
    case (true, true): return abs(a.value - start) <= abs(b.value - (start + len)) ? a.value : b.value - len
    case (true, false): return a.value
    case (false, true): return b.value - len
    case (false, false): return start
    }
  }

  /// A new start for a window ending at `end`: inside the trim, at least `minLength` long.
  public static func clampedStart(_ t: Double, end: Double, trimDuration d: Double) -> Double {
    let v = min(max(0, t), max(0, end - min(minLength, d)))
    return v < 0.02 ? 0 : v
  }

  /// A new end for a window starting at `start`: inside the trim, at least `minLength` long.
  public static func clampedEnd(_ t: Double, start: Double, trimDuration d: Double) -> Double {
    min(max(t, start + min(minLength, d)), d)
  }

  /// A typed time in seconds: "3", "3.5", "0:03.5", "1:02" or "1:02.5". Nil when it isn't one.
  public static func parse(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } }) else { return nil }
    guard let last = Double(parts[parts.count - 1]), last.isFinite else { return nil }
    if parts.count == 1 { return last }
    guard let m = Int(parts[0]), last < 60 else { return nil }
    return Double(m) * 60 + last
  }
}
