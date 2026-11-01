import Foundation

/// Turns a marker tag into the first overlay text (decision Q14).
///
/// Rules (all in `prefill-rules.json` in the app-support folder, so agents can read and edit them;
/// `djq prefill "<tag>"` previews the result):
/// - Split the tag on " x " into song names; tidy each name (title case, fix known typos).
/// - Join with "x", never an arrow. No emoji unless `emoji` is set.
/// - If every name is short (≤ `maxShortName` chars and the line ≤ `maxOneLine`), one line: `Yayo x Johnny`.
///   Otherwise one name per line with "x" on its own line: `Song One` / `x` / `Song Two`.
/// - `talking` videos get no prefill.
public struct PrefillRules: Codable, Sendable, Hashable {
  public var joiner: String = "x"
  public var maxShortName: Int = 14
  public var maxOneLine: Int = 26
  public var emoji: String = ""
  /// Lowercased tag fragment → replacement, applied to each name before title-casing.
  public var replacements: [String: String] = [:]
  /// Words kept lowercase inside names (except at the start).
  public var lowercaseWords: [String] = ["a", "of", "the", "and", "to", "in", "on", "ya", "via"]
  /// Words kept exactly as written (e.g. "DJ", "3.0").
  public var keepWords: [String] = ["DJ", "SA", "BB"]

  public init() {}

  public static func load(_ paths: Paths) -> PrefillRules {
    if let d = try? Data(contentsOf: paths.prefillRules), let r = try? JSONDecoder().decode(PrefillRules.self, from: d) {
      return r
    }
    let r = PrefillRules()
    r.write(paths)
    return r
  }

  public func write(_ paths: Paths) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? e.encode(self) {
      try? FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      try? d.write(to: paths.prefillRules)
    }
  }
}

public enum Prefill {
  public static func names(from tag: String) -> [String] {
    let trimmed = tag.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: #"^[xX×]\s+|\s+[xX×]$"#, with: "", options: .regularExpression)
    let normalized = trimmed.replacingOccurrences(of: #"\s+[xX×]\s+"#, with: "\u{1}", options: .regularExpression)
    return normalized.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  public static func tidy(_ name: String, rules: PrefillRules) -> String {
    var s = name.trimmingCharacters(in: .whitespaces)
    if let r = rules.replacements[s.lowercased()] { return r }
    for (k, v) in rules.replacements where s.lowercased().contains(k.lowercased()) {
      s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
    }
    let keep = Dictionary(uniqueKeysWithValues: rules.keepWords.map { ($0.lowercased(), $0) })
    let words = s.split(separator: " ", omittingEmptySubsequences: true).enumerated().map { i, w -> String in
      let lw = w.lowercased()
      if let k = keep[lw] { return k }
      if i > 0, rules.lowercaseWords.contains(lw) { return lw }
      if w.contains(where: \.isNumber) { return String(w) }
      if w.count > 1, w == w.uppercased(), w.contains(where: \.isLetter) { return String(w) }  // acronym typed in caps
      return lw.prefix(1).uppercased() + lw.dropFirst()
    }
    return words.joined(separator: " ")
  }

  /// The overlay text for a tag, or "" for talking videos.
  public static func text(tag: String, kind: Kind, rules: PrefillRules) -> String {
    guard kind == .djVid else { return "" }
    let parts = names(from: tag).map { tidy($0, rules: rules) }
    guard !parts.isEmpty else { return "" }
    let oneLine = parts.joined(separator: " \(rules.joiner) ")
    let short = parts.count == 1
      || (parts.allSatisfy { $0.count <= rules.maxShortName } && oneLine.count <= rules.maxOneLine)
    var out = short ? oneLine : parts.joined(separator: "\n\(rules.joiner)\n")
    if !rules.emoji.isEmpty { out += " " + rules.emoji }
    return out
  }
}
