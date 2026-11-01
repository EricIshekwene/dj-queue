import Foundation

// DEPRECATED (round 2 #9 "no intelligence inside the app"): nothing in DJQCore calls this any more.
// The formatter now lives upstream in `scripts/prefill_titles.py`, which writes `title_suggestions` into
// videos.json (docs/metadata.md). This copy only keeps the round-1 app compiling until the UI is rebuilt;
// delete it once `Sources/DJQueueApp` no longer references Prefill/PrefillRules.

/// Turns a marker tag into the first overlay text (decision Q14).
///
/// Rules (all in `prefill-rules.json` in the app-support folder, so agents can read and edit them;
/// `djq prefill "<tag>"` previews the result):
/// - Split the tag on " x " into song names; tidy each name (title case, fix known typos).
/// - Join with "x", never an arrow. No emoji unless `emoji` is set.
/// - If every name is short (≤ `maxShortName` chars and the line ≤ `maxOneLine`), one line: `Yayo x Johnny`.
///   Otherwise one name per line with "x" on its own line: `Song One` / `x` / `Song Two`.
/// - `talking` videos get no prefill.
@available(*, deprecated, message: "Removed from the app (round 2 #9): use scripts/prefill_titles.py upstream")
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

  /// Loads the rules file. Missing keys keep their defaults; an unreadable file is logged and left untouched
  /// (defaults are used in memory). The file is only created when it doesn't exist.
  public static func load(_ paths: Paths) -> PrefillRules {
    guard let d = try? Data(contentsOf: paths.prefillRules) else {
      let r = PrefillRules()
      r.write(paths)
      return r
    }
    do { return try JSONCoding.decodeLenient(d, defaults: PrefillRules()) } catch {
      Log.shared.error("prefill-rules.json unreadable, using defaults: \(error)")
      return PrefillRules()
    }
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

@available(*, deprecated, message: "Removed from the app (round 2 #9): show Video.displayName; titles come from metadata")
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
    // Longest keys first so overlapping replacements give the same result every run.
    for (k, v) in rules.replacements.sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) })
    where s.lowercased().contains(k.lowercased()) {
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

@available(*, deprecated, message: "Prefill fallbacks were removed (round 2 #9): call the overload without rules:")
extension Captions {
  public static func caption(for platform: Platform, version v: ResolvedVersion, video: Video, sessionName: String,
                             sets: [HashtagSet], templates: [CaptionTemplate], settings: Settings,
                             rules: PrefillRules) -> String {
    caption(for: platform, version: v, video: video, sessionName: sessionName, sets: sets, templates: templates,
            settings: settings)
  }

  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, limit: Int = 100, rules: PrefillRules) -> String {
    youtubeTitle(v, video: video, limit: limit)
  }
}
