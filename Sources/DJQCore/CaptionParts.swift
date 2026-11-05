import Foundation

/// A part of a caption that a chip adds or removes in the text itself: `Text`, `Set`, `Link`, `Title`, in that order, above the
/// hashtags, each once. A part is on when its text is in the caption, so hand edits can't put a chip out of step.
public enum CaptionPart: String, CaseIterable, Sendable, Identifiable {
  case text, set, link, title
  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .text: "Text"
    case .set: "Set"
    case .link: "Link"
    case .title: "Title"
    }
  }
}

public enum CaptionParts {
  /// What each part reads for one clip.
  public struct Values: Equatable, Sendable {
    public var text: String, set: String, link: String, title: String?

    public init(text: String, set: String, link: String, title: String?) {
      self.text = text; self.set = set; self.link = link; self.title = title
    }

    public init(version r: ResolvedVersion, video: Video, sessionName: String, link: String) {
      self.init(text: Captions.oneLine(Captions.textValue(r, video: video)), set: Captions.setName(sessionName),
                link: Captions.oneLine(link), title: video.titleText.map(Captions.oneLine))
    }

    public func value(_ part: CaptionPart) -> String {
      let v: String
      switch part {
      case .text: v = text
      case .set: v = set
      case .link: v = link
      case .title: v = title ?? ""
      }
      return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// Why a part can't be added (nil = it can).
  public static func offReason(_ part: CaptionPart, _ values: Values) -> String? {
    guard values.value(part).isEmpty else { return nil }
    switch part {
    case .text: return "No text yet"
    case .set: return "This clip's set has no name"
    case .link: return "No link line yet: add one in Settings → Captions & titles"
    case .title: return "No title yet"
    }
  }

  /// Where each part is in `caption`, whole words, in any case. The longest goes first, so a title inside the overlay text
  /// doesn't count as the title; parts that read the same share a place.
  static func places(in caption: String, _ values: Values) -> [CaptionPart: NSRange] {
    var out: [CaptionPart: NSRange] = [:]
    var masked = caption as NSString
    let groups = Dictionary(grouping: CaptionPart.allCases.filter { !values.value($0).isEmpty }) { values.value($0).lowercased() }
    for (value, parts) in groups.sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) }) {
      let pattern = #"(?<![\p{L}\p{N}#])"# + NSRegularExpression.escapedPattern(for: value) + #"(?![\p{L}\p{N}])"#
      guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let m = re.firstMatch(in: masked as String, range: NSRange(location: 0, length: masked.length)) else { continue }
      for p in parts { out[p] = m.range }
      masked = masked.replacingCharacters(in: m.range, with: String(repeating: "\u{1}", count: m.range.length)) as NSString
    }
    return out
  }

  public static func isOn(_ part: CaptionPart, in caption: String, _ values: Values) -> Bool {
    places(in: caption, values)[part] != nil
  }

  /// `caption` with `part` added, or removed if it's there. The text is left exactly as it was apart from that line, so a
  /// second toggle gives back the same caption. Hashtags aren't touched.
  public static func toggled(_ part: CaptionPart, in caption: String, _ values: Values) -> String {
    let found = places(in: caption, values)
    if let r = found[part] { return removing(r, from: caption) }
    guard offReason(part, values) == nil else { return caption }
    return adding(part, to: caption, values, found)
  }

  private static func lines(_ text: String) -> [String] { text.isEmpty ? [] : text.components(separatedBy: "\n") }
  private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

  /// The first line of the hashtag block at the end (`lines.count` when there isn't one).
  private static func hashtagBlock(_ lines: [String]) -> Int {
    var i = lines.count
    while i > 0, blank(lines[i - 1]) || Captions.isHashtagLine(lines[i - 1]) { i -= 1 }
    return lines[i...].contains(where: { !blank($0) }) ? i : lines.count
  }

  private static func adding(_ part: CaptionPart, to caption: String, _ values: Values, _ found: [CaptionPart: NSRange]) -> String {
    var all = lines(caption)
    let tail = hashtagBlock(all)
    func line(_ p: CaptionPart) -> Int? {
      found[p].map { (caption as NSString).substring(to: $0.location).filter { $0 == "\n" }.count }
    }
    let order = CaptionPart.allCases, k = order.firstIndex(of: part) ?? 0
    let body = all[..<tail].lastIndex { !blank($0) }.map { $0 + 1 } ?? 0
    let at = order[..<k].compactMap(line).max().map { $0 + 1 } ?? order[(k + 1)...].compactMap(line).min() ?? body
    all.insert(values.value(part), at: at)
    // Parts sit a blank line above hashtags with nothing over them, the shape every template has.
    if body == 0, tail < all.count - 1 { all.insert("", at: at + 1) }
    return all.joined(separator: "\n")
  }

  private static let separators = CharacterSet(charactersIn: " \t—–-·|:,")

  private static func removing(_ range: NSRange, from caption: String) -> String {
    let ns = caption as NSString
    let index = ns.substring(to: range.location).filter { $0 == "\n" }.count
    var all = lines(caption)
    let start = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
    let line = all[index] as NSString
    let left = String(line.substring(to: range.location - start).unicodeScalars.reversed().drop { separators.contains($0) }.reversed().map(Character.init))
    let right = String(String.UnicodeScalarView(line.substring(from: range.location - start + range.length).unicodeScalars.drop { separators.contains($0) }))
    let rest = [left, right].filter { !$0.isEmpty }.joined(separator: " ")
    if rest.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
      all[index] = rest
      return all.joined(separator: "\n")
    }
    all.remove(at: index)
    if index == 0 {
      all = Array(all.drop(while: blank))
    } else if index == all.count {
      while let last = all.last, blank(last) { all.removeLast() }
    } else if blank(all[index - 1]), blank(all[index]) {
      all.remove(at: index)
    }
    return all.joined(separator: "\n")
  }
}
