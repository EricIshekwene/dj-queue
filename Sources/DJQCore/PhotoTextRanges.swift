import Foundation

/// Round 21 (D7): a text on a photo post shows on a range of photo positions (photo i is [i, i + 1)). When a photo is
/// removed the texts stay with their photos: a range after the removed photo moves down one place, a range that held it
/// gets one shorter, and a text whose only photo went moves onto the nearest photo that's left (and the caller says so).
/// Nothing is ever left on a place past the end, where a first text would draw on every photo and another on none.
///
/// Pure, over a version's own texts. The editor applies it to the versions it holds; `PhotoImport.remove` applies it to
/// the stored versions for a removal from `djq` or a list.
public enum PhotoTextRanges {
  /// A text that is on other photos than before: `number` is 1 for the first text; `range` is where it shows now
  /// (1-based photos).
  public struct Moved: Equatable, Sendable {
    public var number: Int
    public var text: String
    public var range: ClosedRange<Int>
  }

  /// The window a text keeps in a post of `count` photos. nil = nothing to change: it has no window, it already fits, or
  /// it is the inverted window that means "the whole post".
  public static func clamped(start: Double?, end: Double?, count: Int) -> (start: Double?, end: Double?)? {
    guard count > 0, start != nil || end != nil else { return nil }
    let d = Double(count)
    let s = max(0, start ?? 0), e = end ?? .infinity
    guard e > s, s >= d || (end != nil && e > d) else { return nil }
    let first = min(s.rounded(.down), d - 1)
    return (first, end.map { min(max($0.rounded(.up), first + 1), d) })
  }

  /// The window a text has after the photo at `index` (0-based) left a post that had `count` photos, and whether the
  /// text lost its only photo (`moved`). nil = nothing to change.
  public static func removing(index k: Int, start: Double?, end: Double?, count: Int) -> (start: Double?, end: Double?, moved: Bool)? {
    guard count > 1, k >= 0, k < count, start != nil || end != nil else { return nil }
    let d = Double(count)
    let s = max(0, start ?? 0), e = min(end ?? d, d)
    guard e > s else { return nil }  // inverted: the whole post
    var a = Int(s.rounded(.down)), b = max(Int(e.rounded(.up)), Int(s.rounded(.down)) + 1)  // photos a..<b
    guard a < count else { return clamped(start: start, end: end, count: count - 1).map { ($0.start, $0.end, true) } }
    var moved = false
    if k < a { a -= 1; b -= 1 } else if k < b { b -= 1 } else { return nil }
    if b <= a {  // its only photo went: the nearest one that's left
      moved = true
      a = min(a, count - 2)
      b = a + 1
    }
    // "From the start" and "to the end" stay as they were written.
    let newStart: Double? = (start == nil && a == 0) ? nil : Double(a)
    let newEnd: Double? = (end == nil && !moved) ? nil : Double(b)
    if !moved, newStart == start, newEnd == end { return nil }  // "to the end" that lost its last photo reads the same
    return (newStart, newEnd, moved)
  }

  /// `v` with every text's range inside `count` photos, and the texts that moved.
  public static func clamped(_ v: Version, count: Int) -> (version: Version, moved: [Moved]) {
    apply(v, count: count) { s, e in clamped(start: s, end: e, count: count).map { ($0.start, $0.end, true) } }
  }

  /// `v` after the photo at `index` left a post that had `count` photos (see the type comment), and the texts that
  /// lost their only photo.
  public static func removing(index: Int, from v: Version, count: Int) -> (version: Version, moved: [Moved]) {
    apply(v, count: count - 1) { s, e in removing(index: index, start: s, end: e, count: count) }
  }

  private static func apply(_ v: Version, count: Int,
                            _ rule: (Double?, Double?) -> (start: Double?, end: Double?, moved: Bool)?) -> (version: Version, moved: [Moved]) {
    var out = v
    var moved: [Moved] = []
    func range(_ s: Double?, _ e: Double?) -> ClosedRange<Int> {
      let a = Int(s ?? 0) + 1
      return a...max(a, Int(e ?? Double(count)))
    }
    if let w = rule(v.textStart, v.textEnd) {
      out.textStart = w.start
      out.textEnd = w.end
      if w.moved { moved.append(Moved(number: 1, text: v.text ?? "", range: range(w.start, w.end))) }
    }
    if var list = v.moreText {
      for i in list.indices {
        guard let w = rule(list[i].start, list[i].end) else { continue }
        list[i].start = w.start
        list[i].end = w.end
        if w.moved { moved.append(Moved(number: i + 2, text: list[i].text, range: range(w.start, w.end))) }
      }
      out.moreText = list
    }
    return (out, moved)
  }

  /// "“Loft nights” now shows on photo 3" · "2 texts moved onto the photos that are left". nil = nothing moved.
  public static func notice(_ moved: [Moved], count: Int) -> String? {
    guard let m = moved.first else { return nil }
    guard moved.count == 1 else { return "\(moved.count) texts moved onto the photos that are left" }
    let name = m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Text \(m.number)" : "“\(Captions.oneLine(m.text))”"
    return "\(name) now shows on \(PhotoRules.rangeLabel(m.range, count: count).lowercased())"
  }
}
