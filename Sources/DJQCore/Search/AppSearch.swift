import Foundation

// Whole-app search (round 10): a pure, literal engine. No SwiftUI, no database, no fuzzy matching and no guessing.
// An item has an id, a kind, a title and weighted fields; a query folds case and diacritics and every word must hit
// some field. All text is folded once when the index is built, so one keystroke only scans bytes.

/// What a result is. The order of the cases is the fixed section order.
public enum SearchKind: String, CaseIterable, Sendable {
  // Week before post: every scheduled day has posts now, and a date should lead to its week, not to six post rows.
  case clip, week, post, session, setting, health, action, goTo

  /// Section heading in the palette.
  public var title: String {
    switch self {
    case .clip: "Clips"
    case .post: "Posts"
    case .week: "Weeks"
    case .session: "Sessions"
    case .setting: "Settings"
    case .health: "Health"
    case .action: "Actions"
    case .goTo: "Go to"
    }
  }

  /// The fixed order sections fall back to when their best match is equally good.
  public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The type chips under the search field. Health, Actions and Go to share the Actions chip.
public enum SearchScope: String, CaseIterable, Sendable {
  case all, clips, posts, weeks, sessions, settings, actions

  public var title: String {
    switch self {
    case .all: "All"
    case .clips: "Clips"
    case .posts: "Posts"
    case .weeks: "Weeks"
    case .sessions: "Sessions"
    case .settings: "Settings"
    case .actions: "Actions"
    }
  }

  public var kinds: [SearchKind] {
    switch self {
    case .all: SearchKind.allCases
    case .clips: [.clip]
    case .posts: [.post]
    case .weeks: [.week]
    case .sessions: [.session]
    case .settings: [.setting]
    case .actions: [.health, .action, .goTo]
    }
  }

  public func contains(_ k: SearchKind) -> Bool { self == .all || kinds.contains(k) }
}

/// How well a hit matched, best first.
public enum SearchTier: Int, Comparable, Sendable {
  /// The whole query is a title (or another primary field).
  case exact
  /// Every word starts a word of a primary field.
  case wordPrefix
  /// Every word is inside a primary field.
  case titleContains
  /// At least one word only matched a body field.
  case otherField

  public static func < (a: SearchTier, b: SearchTier) -> Bool { a.rawValue < b.rawValue }
}

/// One piece of searchable text.
public struct SearchField: Sendable, Hashable {
  public enum Role: Sendable {
    /// Ranks like the title (aliases: a raw tag, "Score" for "Go to Score").
    case primary
    /// Matches, but shows where it matched ("Caption: …").
    case body
    /// Words next to each other in the query must match it as a prefix ("12 nov" for a week), so "nov 12" never comes
    /// from the "12" of one date and the "nov" of another. Any other words go through the normal AND.
    case phrase
  }

  public var label: String
  public var text: String
  public var role: Role

  public init(_ label: String, _ text: String, role: Role = .body) {
    self.label = label
    self.text = text
    self.role = role
  }
}

public struct SearchItem: Sendable, Identifiable {
  public var id: String
  public var kind: SearchKind
  public var title: String
  public var fields: [SearchField]
  /// Order among equally good hits of one kind (lower first).
  public var rank: Int

  public init(id: String, kind: SearchKind, title: String, fields: [SearchField] = [], rank: Int = 0) {
    self.id = id
    self.kind = kind
    self.title = title
    self.fields = fields
    self.rank = rank
  }
}

/// A folded query. Build it once per keystroke; `isEmpty` means show the resting palette.
public struct SearchQuery: Sendable, Hashable {
  public let raw: String
  /// Folded words (never empty strings).
  public let words: [String]

  public init(_ raw: String) {
    self.raw = raw
    words = String(decoding: SearchText.foldedBytes(raw), as: UTF8.self).split(separator: " ").map(String.init)
  }

  public var isEmpty: Bool { words.isEmpty }
  /// The words joined by one space.
  public var phrase: String { words.joined(separator: " ") }
}

public struct SearchHit: Sendable, Identifiable, Hashable {
  public let id: String
  public let kind: SearchKind
  public let tier: SearchTier
  public let rank: Int
  /// Position in the index the hit came from (`SearchIndex.snippet`).
  public let position: Int
}

/// Where a non-title hit matched: "Caption" + "…text around the match…".
public struct SearchSnippet: Sendable, Hashable {
  public var label: String
  public var text: String
  /// Character offsets of the matched words inside `text`.
  public var ranges: [Range<Int>]
}

/// One palette section: its hits in order and the best tier among them.
public struct SearchSection: Sendable, Hashable {
  public var kind: SearchKind
  public var hits: [SearchHit]
  public var best: SearchTier { hits.first?.tier ?? .otherField }
}

/// Immutable folded corpus. Safe to build off the main actor and to search on it.
public struct SearchIndex: Sendable {
  private struct Entry: Sendable {
    var primaryStart: Int
    /// `primaryStart..<bodyStart`: "\0a\0b\0"; `bodyStart..<phraseStart`: "c\0d\0".
    var bodyStart: Int
    var phraseStart: Int
    var end: Int
  }

  public private(set) var items: [SearchItem]
  private var entries: [Entry]
  /// Every item's folded fields end to end, so a query scans one flat buffer.
  private var blob: ContiguousArray<UInt8>

  public init(items: [SearchItem] = []) {
    self.items = items
    entries = []
    entries.reserveCapacity(items.count)
    blob = []
    blob.reserveCapacity(items.count * 128)
    for item in items {
      var e = Entry(primaryStart: blob.count, bodyStart: 0, phraseStart: 0, end: 0)
      blob.append(0)
      Self.append(item.title, to: &blob)
      for f in item.fields where f.role == .primary { Self.append(f.text, to: &blob) }
      e.bodyStart = blob.count
      for f in item.fields where f.role == .body { Self.append(f.text, to: &blob) }
      e.phraseStart = blob.count
      for f in item.fields where f.role == .phrase { Self.append(f.text, to: &blob) }
      e.end = blob.count
      entries.append(e)
    }
  }

  public var count: Int { items.count }

  private static func append(_ text: String, to blob: inout ContiguousArray<UInt8>) {
    blob.append(contentsOf: SearchText.foldedBytes(text))
    blob.append(0)
  }

  /// Hits best first: tier, then the item's rank. An empty query has none.
  public func search(_ q: SearchQuery) -> [SearchHit] {
    guard !q.isEmpty else { return [] }
    let needles = q.words.map { Array($0.utf8) }
    let exact = [0] + Array(q.phrase.utf8) + [0]
    let phrasePrefix = [0] + Array(q.phrase.utf8)
    let runs = PhraseRun.all(q.words)
    var hits: [SearchHit] = []
    guard !blob.isEmpty else { return [] }
    blob.withUnsafeBytes { raw in
      let base = raw.bindMemory(to: UInt8.self).baseAddress!
      for (i, e) in entries.enumerated() {
        guard let tier = Self.tier(e, base: base, needles: needles, exact: exact, phrasePrefix: phrasePrefix, runs: runs) else { continue }
        hits.append(SearchHit(id: items[i].id, kind: items[i].kind, tier: tier, rank: items[i].rank, position: i))
      }
    }
    return hits.sorted { ($0.tier, $0.rank, $0.position) < ($1.tier, $1.rank, $1.position) }
  }

  /// A run of neighbouring query words that may stand for a date while the rest match as usual ("tiktok 12 nov"). It
  /// must be more than a number, and no plain number may sit right beside it: "26 nov" must not read "26" from a title
  /// and "nov" from another date of that week. A run before the end of the query has to be whole words of the phrase.
  private struct PhraseRun {
    var prefix: [UInt8]
    var isLast: Bool
    var others: [Int]

    private static func isNumber(_ w: String) -> Bool { w.allSatisfy(\.isNumber) }

    static func all(_ words: [String]) -> [PhraseRun] {
      guard words.count > 1 else { return [] }
      var out: [PhraseRun] = []
      for i in words.indices {
        for j in i..<min(words.count, i + 4) where !(i == 0 && j == words.count - 1) {
          let run = words[i...j]
          guard !run.allSatisfy(isNumber) else { continue }
          if i > 0, isNumber(words[i - 1]) { continue }
          if j + 1 < words.count, isNumber(words[j + 1]) { continue }
          out.append(PhraseRun(prefix: [0] + Array(run.joined(separator: " ").utf8), isLast: j == words.count - 1,
                               others: words.indices.filter { $0 < i || $0 > j }))
        }
      }
      return out
    }
  }

  private static func tier(_ e: Entry, base: UnsafePointer<UInt8>, needles: [[UInt8]], exact: [UInt8], phrasePrefix: [UInt8],
                           runs: [PhraseRun]) -> SearchTier? {
    let primary = UnsafeBufferPointer(start: base + e.primaryStart, count: e.bodyStart - e.primaryStart)
    let everything = UnsafeBufferPointer(start: base + e.primaryStart, count: e.phraseStart - e.primaryStart)
    var phraseTier: SearchTier?
    if e.end > e.phraseStart {
      // Phrases read "\0a\0b\0" counting the terminator of whatever came before them.
      let phrases = UnsafeBufferPointer(start: base + e.phraseStart - 1, count: e.end - e.phraseStart + 1)
      if find(exact, in: phrases, from: 0) != nil {
        phraseTier = .exact
      } else if find(phrasePrefix, in: phrases, from: 0) != nil {
        phraseTier = .wordPrefix
      }
    }
    guard needles.allSatisfy({ find($0, in: everything, from: 0) != nil }) else {
      if phraseTier != nil || e.end == e.phraseStart { return phraseTier }
      let phrases = UnsafeBufferPointer(start: base + e.phraseStart - 1, count: e.end - e.phraseStart + 1)
      for run in runs where run.others.allSatisfy({ find(needles[$0], in: everything, from: 0) != nil }) {
        guard hasPhrase(run, in: phrases) else { continue }
        return run.others.allSatisfy { startsWord(needles[$0], in: primary) } ? .wordPrefix : .otherField
      }
      return nil
    }
    if find(exact, in: primary, from: 0) != nil { return .exact }
    if phraseTier == .exact { return .exact }
    if needles.allSatisfy({ startsWord($0, in: primary) }) { return .wordPrefix }
    if let phraseTier { return phraseTier }
    return needles.allSatisfy { find($0, in: primary, from: 0) != nil } ? .titleContains : .otherField
  }

  private static func startsWord(_ n: [UInt8], in primary: UnsafeBufferPointer<UInt8>) -> Bool {
    var from = 0
    while let at = find(n, in: primary, from: from) {
      if at == 0 || !isWordByte(primary[at - 1]) { return true }
      from = at + 1
    }
    return false
  }

  private static func hasPhrase(_ run: PhraseRun, in phrases: UnsafeBufferPointer<UInt8>) -> Bool {
    var from = 0
    while let at = find(run.prefix, in: phrases, from: from) {
      let next = at + run.prefix.count
      if run.isLast || next >= phrases.count || phrases[next] == 0x20 || phrases[next] == 0 { return true }
      from = at + 1
    }
    return false
  }

  private static func isWordByte(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7a) || b >= 0x80
  }

  /// First index of `needle` in `hay` at or after `from`.
  private static func find(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
    guard let h = hay.baseAddress, from < hay.count, !needle.isEmpty else { return nil }
    return needle.withUnsafeBytes { n in
      memmem(h + from, hay.count - from, n.baseAddress!, n.count).map { h.distance(to: $0.assumingMemoryBound(to: UInt8.self)) }
    }
  }

  /// Why a hit that didn't match its title is here: the body field holding the most query words (first wins a tie).
  /// nil for hits that match on title or a phrase.
  public func snippet(_ hit: SearchHit, _ q: SearchQuery) -> SearchSnippet? {
    guard hit.tier == .otherField, items.indices.contains(hit.position) else { return nil }
    var best: (field: SearchField, words: Int)?
    for f in items[hit.position].fields where f.role == .body {
      let n = q.words.filter { SearchText.contains(f.text, $0) }.count
      if n > (best?.words ?? 0) { best = (f, n) }
    }
    return best.map { SearchText.snippet($0.field, q) }
  }
}

/// The hits as palette sections: best match tier first, then the fixed order of `SearchKind`.
public enum AppSearch {
  public static func sections(_ hits: [SearchHit]) -> [SearchSection] {
    var byKind: [SearchKind: [SearchHit]] = [:]
    for h in hits { byKind[h.kind, default: []].append(h) }
    return byKind.map { k, v in
      SearchSection(kind: k, hits: v.sorted { ($0.tier, $0.rank, $0.position) < ($1.tier, $1.rank, $1.position) })
    }
    .sorted { ($0.best, $0.kind.order) < ($1.best, $1.kind.order) }
  }

  /// Hits per chip (`.all` counts everything). A chip with no hits isn't offered.
  public static func counts(_ hits: [SearchHit]) -> [SearchScope: Int] {
    var c: [SearchScope: Int] = [.all: hits.count]
    for s in SearchScope.allCases where s != .all {
      let n = hits.filter { s.contains($0.kind) }.count
      if n > 0 { c[s] = n }
    }
    return c
  }
}

/// Folding and text pieces. Everything case- and diacritic-insensitive goes through here.
public enum SearchText {
  private static let locale = Locale(identifier: "en_US_POSIX")
  /// Letters Foundation leaves alone (they're letters of their own, not marks), and typographic apostrophes.
  private static let extraFolds = [("ø", "o"), ("ł", "l"), ("đ", "d"), ("ð", "d"), ("æ", "ae"), ("œ", "oe"), ("’", "'"), ("‘", "'")]

  /// Lowercased, diacritics removed, whitespace runs reduced to one space, NULs dropped: the form every field is kept in.
  public static func foldedBytes(_ s: String) -> [UInt8] {
    var src = Array(s.utf8)
    if src.contains(where: { $0 >= 0x80 }) {
      let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).lowercased()
      src = Array(extraFolds.reduce(into: folded) { $0 = $0.replacingOccurrences(of: $1.0, with: $1.1) }.utf8)
    }
    var out = [UInt8]()
    out.reserveCapacity(src.count)
    var space = true  // drops leading whitespace
    for var b in src {
      if b == 0 { continue }
      if b == 0x20 || (b >= 0x09 && b <= 0x0d) {
        if space { continue }
        space = true
        out.append(0x20)
        continue
      }
      space = false
      if b >= 0x41 && b <= 0x5a { b += 0x20 }
      out.append(b)
    }
    if out.last == 0x20 { out.removeLast() }
    return out
  }

  public static func fold(_ s: String) -> String { String(decoding: foldedBytes(s), as: UTF8.self) }

  /// Folded `text` contains the folded `word`.
  static func contains(_ text: String, _ word: String) -> Bool {
    let hay = foldedBytes(text), n = Array(word.utf8)
    return hay.withUnsafeBytes { h in
      n.withUnsafeBytes { memmem(h.baseAddress, h.count, $0.baseAddress, $0.count) != nil }
    }
  }

  /// Character offsets in `text` where any query word matches, sorted and merged (the bold in a row). Works one
  /// character at a time, so it stays right when folding changes a character's length. Meant for rendered rows only.
  public static func ranges(in text: String, _ q: SearchQuery) -> [Range<Int>] {
    guard !q.isEmpty, !text.isEmpty else { return [] }
    var folded = [UInt8]()
    var charOf = [Int]()
    folded.reserveCapacity(text.utf8.count)
    for (i, c) in text.enumerated() {
      let bytes: [UInt8]
      if let a = c.asciiValue {
        bytes = [a >= 0x41 && a <= 0x5a ? a + 0x20 : a]
      } else if c.isWhitespace {
        bytes = [0x20]
      } else {
        bytes = foldedBytes(String(c))
      }
      folded.append(contentsOf: bytes)
      charOf.append(contentsOf: repeatElement(i, count: bytes.count))
    }
    var out: [Range<Int>] = []
    for w in q.words {
      let n = Array(w.utf8)
      guard n.count <= folded.count else { continue }
      var i = 0
      while i + n.count <= folded.count {
        if folded[i] == n[0] && Array(folded[i..<(i + n.count)]) == n {
          out.append(charOf[i]..<(charOf[i + n.count - 1] + 1))
          i += n.count
        } else {
          i += 1
        }
      }
    }
    out.sort { $0.lowerBound < $1.lowerBound }
    var merged: [Range<Int>] = []
    for r in out {
      if let l = merged.last, r.lowerBound <= l.upperBound {
        merged[merged.count - 1] = l.lowerBound..<max(l.upperBound, r.upperBound)
      } else {
        merged.append(r)
      }
    }
    return merged
  }

  /// The field's text on one line around its first match, cut at word edges with "…".
  public static func snippet(_ field: SearchField, _ q: SearchQuery, width: Int = 80, lead: Int = 24) -> SearchSnippet {
    let line = field.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let chars = Array(line)
    guard chars.count > width else { return SearchSnippet(label: field.label, text: line, ranges: ranges(in: line, q)) }
    let first = ranges(in: line, q).first?.lowerBound ?? 0
    var start = max(0, first - lead)
    if start > 0, let space = chars[start..<first].firstIndex(of: " ") { start = space + 1 }
    if chars.count - start < width { start = max(0, chars.count - width) }
    var end = min(chars.count, start + width)
    if end < chars.count, let space = chars[start..<end].lastIndex(of: " "), space > first { end = space }
    let cut = (start > 0 ? "…" : "") + String(chars[start..<end]) + (end < chars.count ? "…" : "")
    return SearchSnippet(label: field.label, text: cut, ranges: ranges(in: cut, q))
  }
}
