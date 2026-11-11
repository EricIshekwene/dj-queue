import CryptoKit
import DJQCore
import Foundation

/// Round 21 (D7, and "Decisions made while building (B2)"): a text's range names photo positions, and it must stay on
/// photos that exist. When photos are removed, each text's range is clamped into the photos that remain: photos 3–4
/// of 4 with one removed is photo 3, and a text only on the removed last photo moves to the new last photo. Without
/// this a range left wholly past the end made Core draw the first text on every photo and another text on none.
///
/// Pure, over a version's own texts, so Core's `PhotoImport.remove` can use the same rule for `djq` (shared-file need).
enum PhotoTextRanges {
  /// A text whose range moved: `number` is 1 for the first text; `range` is where it shows now (1-based photos).
  struct Moved: Equatable {
    var number: Int
    var text: String
    var range: ClosedRange<Int>
  }

  /// The window a text keeps in a post of `count` photos (photo i is [i, i + 1)). nil = nothing to change: it has no
  /// window, it already fits, or it is the inverted window that means "the whole post".
  static func clamped(start: Double?, end: Double?, count: Int) -> (start: Double?, end: Double?)? {
    guard count > 0, start != nil || end != nil else { return nil }
    let d = Double(count)
    let s = max(0, start ?? 0), e = end ?? .infinity
    guard e > s, s >= d || (end != nil && e > d) else { return nil }
    let first = min(s.rounded(.down), d - 1)
    return (first, end.map { min(max($0.rounded(.up), first + 1), d) })
  }

  /// `v` with every text's range inside `count` photos, and the texts that moved.
  static func clamped(_ v: Version, count: Int) -> (version: Version, moved: [Moved]) {
    var out = v
    var moved: [Moved] = []
    func range(_ w: (start: Double?, end: Double?)) -> ClosedRange<Int> {
      let a = Int(w.start ?? 0) + 1
      return a...max(a, Int(w.end ?? Double(count)))
    }
    if let w = clamped(start: v.textStart, end: v.textEnd, count: count) {
      out.textStart = w.start
      out.textEnd = w.end
      moved.append(Moved(number: 1, text: v.text ?? "", range: range(w)))
    }
    if var list = v.moreText {
      for i in list.indices {
        guard let w = clamped(start: list[i].start, end: list[i].end, count: count) else { continue }
        list[i].start = w.start
        list[i].end = w.end
        moved.append(Moved(number: i + 2, text: list[i].text, range: range(w)))
      }
      out.moreText = list
    }
    return (out, moved)
  }

  /// "“Loft nights” now shows on photo 3" · "2 texts moved onto the photos that are left". nil = nothing moved.
  static func notice(_ moved: [Moved], count: Int) -> String? {
    guard let m = moved.first else { return nil }
    guard moved.count == 1 else { return "\(moved.count) texts moved onto the photos that are left" }
    let name = m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Text \(m.number)" : "“\(Captions.oneLine(m.text))”"
    return "\(name) now shows on \(PhotoRules.rangeLabel(m.range, count: count).lowercased())"
  }
}

/// Undo and redo of a photo-list change: the stored list goes back to one the post had, with the same photo ids and
/// files (a removed photo's copy stays in `Originals/` for exactly this), so nothing is copied and each photo's own
/// crop still belongs to it. Core has `add`, `remove` and `reorder` in public but no "set this list"; this is that one
/// write, the same statement as Core's internal `Store.writePhotos` (shared-file need: make it a public call there).
enum PhotoListRestore {
  @discardableResult
  static func set(_ photos: [PhotoItem], videoId: String, store: Store) throws -> Video {
    try store.db.transaction {
      guard var v = try store.video(id: videoId), v.isPhoto else { throw EngineError("No photo post \(videoId)") }
      v.photos = photos
      let sizes = try photos.map { Intake.size(try store.photoURL($0, of: v)) }.filter { $0 >= 0 }
      let print = photos.map { $0.fingerprint ?? $0.file }.joined(separator: "|")
      let fp = photos.isEmpty ? nil : SHA256.hash(data: Data(print.utf8)).map { String(format: "%02x", $0) }.joined()
      try store.db.run("""
        UPDATE videos SET photos=?, file=?, fingerprint=?, file_size=?, source_width=?, source_height=?, updated_at=? WHERE id=?
        """, [JSONCoding.string(photos), photos.first?.file ?? v.file, fp, sizes.isEmpty ? nil : sizes.reduce(0, +),
              photos.first?.width, photos.first?.height, store.clock.now, videoId])
      try store.refreshState(videoId: videoId)
      guard let saved = try store.video(id: videoId) else { throw EngineError("No photo post \(videoId)") }
      return saved
    }
  }
}
