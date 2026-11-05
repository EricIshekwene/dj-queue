import Foundation

/// Captions, hashtags and YouTube titles per platform (spec §6, decisions Q15–Q17).
public enum Captions {
  /// The session name without its date, e.g. "Afroween Jazz Piano".
  public static func setName(_ session: String) -> String {
    session.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}\s*[–-]\s*"#, with: "", options: .regularExpression)
  }

  /// Overlay text flattened to one line ("Song One\nx\nSong Two" → "Song One x Song Two").
  public static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  public static func normalizeTag(_ t: String) -> String {
    let core = t.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      .replacingOccurrences(of: " ", with: "").lowercased()
    return core.isEmpty ? "" : "#" + core
  }

  /// Hashtags for a version: exactly the chosen sets (or the default sets), then extras, de-duplicated, in order.
  /// Round 2: no rotating per-video sub-set — `videoId` is ignored and kept only for source compatibility.
  public static func hashtags(_ v: ResolvedVersion, sets: [HashtagSet], videoId: String? = nil) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    let byId = Dictionary(sets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for id in v.hashtagSetIds {
      for t in byId[id]?.tags ?? [] {
        let n = normalizeTag(t)
        if !n.isEmpty, seen.insert(n).inserted { out.append(n) }
      }
    }
    for t in v.extraHashtags {
      let n = normalizeTag(t)
      if !n.isEmpty, seen.insert(n).inserted { out.append(n) }
    }
    return out
  }

  /// `title` and `link` are nil only for captions built the old way, where those words aren't tokens (`CaptionRulesMigration`).
  public static func fill(_ template: String, text: String, tag: String, set: String, hashtags: [String], title: String? = "",
                          link: String? = "") -> String {
    var out = template
    if let title { out = out.replacingOccurrences(of: "{title}", with: oneLine(title)) }
    if let link { out = out.replacingOccurrences(of: "{link}", with: oneLine(link)) }
    return out
      .replacingOccurrences(of: "{text}", with: oneLine(text))
      .replacingOccurrences(of: "{tag}", with: tag)
      .replacingOccurrences(of: "{set}", with: set)
      .replacingOccurrences(of: "{hashtags}", with: hashtags.joined(separator: " "))
      .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `{text}` for captions and titles: the overlay text, else Eric's title, else the raw marker tag verbatim.
  /// Never tidied or guessed (round 2 #9).
  public static func textValue(_ v: ResolvedVersion, video: Video) -> String {
    if v.hasText { return v.text }
    return video.titleText ?? video.tag
  }

  /// The template a platform's caption is built from when no caption is written: the version's chosen template,
  /// else the platform's default template, else the default template.
  public static func templateId(for platform: Platform, version v: ResolvedVersion, settings: Settings) -> String {
    v.captionTemplateId ?? settings.defaults.platformCaptionTemplates[platform] ?? settings.defaults.captionTemplateId
  }

  /// Final caption for one platform. Order: per-platform override → written caption → template.
  /// Over the platform limit it is returned AS IS (round 2: nothing is dropped silently); Validation reports
  /// `.captionTooLong` with the numbers, and the UI offers `withoutHashtags` ("Drop hashtags for X") or a
  /// per-platform caption.
  public static func caption(for platform: Platform, version v: ResolvedVersion, video: Video, sessionName: String,
                             sets: [HashtagSet], templates: [CaptionTemplate], settings: Settings) -> String {
    output(platform, v, video, sessionName, sets, templates, settings)
  }

  /// `caption(for:)`, or with `legacy` the caption exactly as v0.8.2 built it.
  static func output(_ platform: Platform, _ v: ResolvedVersion, _ video: Video, _ sessionName: String, _ sets: [HashtagSet],
                     _ templates: [CaptionTemplate], _ settings: Settings, legacy: Bool = false) -> String {
    if let o = v.platformCaptions[platform], !o.isEmpty { return o }
    let s = build(platform, v, video, sessionName, hashtags(v, sets: sets), templates, settings, legacy: legacy)
    return legacy ? s : capped(onceEach(s, v), to: settings.limits[platform]?.maxHashtags).text
  }

  /// `text` with its first `cap` hashtags, in caption order, tags typed in the text included, and the ones it lost.
  public static func capped(_ text: String, to cap: Int?) -> (text: String, dropped: [String]) {
    guard let cap, let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#])#[\p{L}\p{N}_]+"#) else { return (text, []) }
    let ns = text as NSString
    let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    guard all.count > max(cap, 0) else { return (text, []) }
    let extra = all[max(cap, 0)...]
    var out = text
    for r in extra.reversed() { out = removeRange(out as NSString, r) }
    return (out, extra.map { ns.substring(with: $0) })
  }

  /// What a platform's hashtag cap does to one clip's caption, for the line under the caption.
  public struct CapNote: Equatable, Sendable, Identifiable {
    public var platform: Platform
    public var cap: Int
    public var total: Int
    public var dropped: [String]
    /// The platform has its own caption: it's left as written, so nothing is dropped and it may go over.
    public var own: Bool
    public var id: Platform { platform }

    public var message: String {
      let name = platform.displayName
      if own { return "\(name)'s own caption has \(total) hashtags and \(name) keeps \(cap). It's left as you wrote it" }
      let list = dropped.joined(separator: " ")
      return cap == 0 ? "\(name) keeps no hashtags: drops \(list)" : "\(name) keeps \(cap) of \(total): drops \(list)"
    }
  }

  /// One note per platform a cap reaches, for `platforms`.
  public static func capNotes(_ platforms: [Platform], version v: ResolvedVersion, video: Video, sessionName: String, sets: [HashtagSet],
                              templates: [CaptionTemplate], settings: Settings) -> [CapNote] {
    platforms.compactMap { p in
      guard let cap = settings.limits[p]?.maxHashtags else { return nil }
      if let own = v.platformCaptions[p], !own.isEmpty {
        let n = tags(in: own).count
        return n > cap ? CapNote(platform: p, cap: cap, total: n, dropped: [], own: true) : nil
      }
      let full = onceEach(build(p, v, video, sessionName, hashtags(v, sets: sets), templates, settings), v)
      let dropped = capped(full, to: cap).dropped
      return dropped.isEmpty ? nil : CapNote(platform: p, cap: cap, total: cap + dropped.count, dropped: dropped, own: false)
    }
  }

  /// Each tag once, at its first position, where the clip's tags are filled in beside tags typed in a template or caption. A
  /// written caption without `{hashtags}` is literal, and adding tags to it already skips any it has (`replaceHashtags`).
  static func onceEach(_ text: String, _ v: ResolvedVersion) -> String {
    guard v.caption.isEmpty || v.caption.contains("{hashtags}"),
          let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#])#[\p{L}\p{N}_]+"#) else { return text }
    var seen = Set<String>(), out = text
    let ns = text as NSString
    let repeats = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter {
      !seen.insert(normalizeTag(ns.substring(with: $0))).inserted
    }
    for r in repeats.reversed() { out = removeRange(out as NSString, r) }
    return out
  }

  /// The caption every platform without its own caption (and without a per-platform default template) posts — what
  /// the editor's caption field shows and edits (round 7, WYSIWYG): the written caption with `{hashtags}` filled, else
  /// the chosen (or default) template filled.
  public static func sharedCaption(version v: ResolvedVersion, video: Video, sessionName: String, sets: [HashtagSet],
                                   templates: [CaptionTemplate], settings: Settings) -> String {
    var s = settings
    s.defaults.platformCaptionTemplates = [:]
    return onceEach(build(.tiktok, v, video, sessionName, hashtags(v, sets: sets), templates, s), v)
  }

  /// What template `id` fills to for this clip (the editor's template picker rewrites the caption field with it).
  public static func templateCaption(_ id: String?, version v: ResolvedVersion, video: Video, sessionName: String,
                                     sets: [HashtagSet], templates: [CaptionTemplate], settings: Settings) -> String {
    var r = v
    r.caption = ""
    r.captionTemplateId = id
    return sharedCaption(version: r, video: video, sessionName: sessionName, sets: sets, templates: templates, settings: settings)
  }

  /// The same caption with no hashtags at all — what "Drop hashtags for <platform>" writes as that platform's
  /// caption override (`Version.platformCaptions[platform]`). Round 7: every hashtag in the text goes — the clip's
  /// groups and extra tags, and any Eric typed into a written caption or a template.
  public static func withoutHashtags(for platform: Platform, version v: ResolvedVersion, video: Video, sessionName: String,
                                     templates: [CaptionTemplate], settings: Settings, sets: [HashtagSet] = []) -> String {
    var r = v
    r.platformCaptions[platform] = nil
    let base: String
    if !r.caption.isEmpty, !r.caption.contains("{hashtags}") {
      base = replaceHashtags(in: r.caption, old: hashtags(r, sets: sets), new: [])
    } else {
      base = build(platform, r, video, sessionName, [], templates, settings)
    }
    return stripTags(base)
  }

  /// `text` with every hashtag token removed (tidy: no leftover blank tag line or trailing space).
  public static func stripTags(_ text: String) -> String {
    var out = text
    var seen = Set<String>()
    for t in tags(in: text) where seen.insert(t).inserted { out = removeTag(t, from: out) }
    return out
  }

  /// True when the caption text holds a hashtag ("Drop hashtags" has something to drop).
  public static func hasTags(_ text: String) -> Bool { !tags(in: text).isEmpty }

  /// A written caption is taken literally (round 7: WYSIWYG — nothing is appended). `{hashtags}` in it (older
  /// captions, and every caption the schema-6 migration found without one, which got "\n{hashtags}") is filled with
  /// the clip's hashtags.
  static func build(_ platform: Platform, _ v: ResolvedVersion, _ video: Video, _ sessionName: String, _ tags: [String],
                    _ templates: [CaptionTemplate], _ settings: Settings, legacy: Bool = false) -> String {
    let joined = tags.joined(separator: " ")
    if !v.caption.isEmpty {
      if v.caption.contains("{hashtags}") {
        if tags.isEmpty, v.caption.hasSuffix(legacySuffix), !v.caption.dropLast(legacySuffix.count).contains("{hashtags}") {
          return String(v.caption.dropLast(legacySuffix.count))
        }
        if v.caption.hasSuffix(legacySuffix), !v.caption.dropLast(legacySuffix.count).contains("{hashtags}") {
          return String(v.caption.dropLast(legacySuffix.count)) + "\n" + joined
        }
        return v.caption.replacingOccurrences(of: "{hashtags}", with: joined).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return v.caption
    }
    let tid = templateId(for: platform, version: v, settings: settings)
    let tpl = templates.first { $0.id == tid }?.template ?? Defaults.captionTemplates[0].template
    return fill(tpl, text: textValue(v, video: video), tag: video.tag, set: setName(sessionName), hashtags: tags,
                title: legacy ? nil : video.titleText ?? "", link: legacy ? nil : settings.captionLink)
  }

  /// What the schema-6 migration appends to a written caption that had no `{hashtags}` (rounds 1–6 added the hashtags
  /// on a new line after it). `build` turns it back into exactly that: the caption as written, then "\n" + tags.
  public static let legacySuffix = "\n{hashtags}"

  // MARK: Editing hashtags inside a written caption (round 7)

  /// The hashtag tokens in `text`, in order, normalised ("#Amapiano" → "#amapiano").
  public static func tags(in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#])#[\p{L}\p{N}_]+"#) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { normalizeTag(ns.substring(with: $0.range)) }
  }

  /// Swaps the clip's hashtags in a written caption in place when its groups or extra tags change: the run of the old
  /// tags (as `hashtags` wrote them) becomes the new run; if Eric rearranged them by hand, old tags that went away are
  /// removed one by one and new ones are added to the last hashtag line (else a new line at the end). A tag that is
  /// already anywhere in the caption is never added twice. Nothing else in the text changes.
  public static func replaceHashtags(in text: String, old: [String], new: [String]) -> String {
    let o = old.map(normalizeTag).filter { !$0.isEmpty }, n = new.map(normalizeTag).filter { !$0.isEmpty }
    if o == n { return text }
    let ns = text as NSString
    if !o.isEmpty {
      let block = o.joined(separator: " ")
      let r = ns.range(of: block, options: [.backwards, .caseInsensitive])
      if r.location != NSNotFound, isTagBoundary(ns, r) {
        let outside = Set(tags(in: ns.replacingCharacters(in: r, with: " ")))
        let keep = n.filter { !outside.contains($0) }
        if !keep.isEmpty { return ns.replacingCharacters(in: r, with: keep.joined(separator: " ")) }
        return removeRange(ns, r)
      }
    }
    // Hand-edited hashtags: token by token.
    var out = text
    for t in o where !n.contains(t) { out = removeTag(t, from: out) }
    let present = Set(tags(in: out))
    let add = n.filter { !present.contains($0) }
    guard !add.isEmpty else { return out }
    let joined = add.joined(separator: " ")
    var lines = out.components(separatedBy: "\n")
    if let i = lines.lastIndex(where: { isHashtagLine($0) }) {
      lines[i] = lines[i].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + " " + joined
      return lines.joined(separator: "\n")
    }
    let body = out.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
    return body.isEmpty ? joined : body + "\n" + joined
  }

  /// After a version's groups or extra tags changed (`before` → `after`, both resolved with the same settings): a written
  /// caption without `{hashtags}` gets its hashtags swapped in place (`replaceHashtags`), stored on `version` (it
  /// becomes this version's own caption when it was carried forward). Template captions and `{hashtags}` captions
  /// follow by themselves; per-platform captions are their own and stay as written.
  public static func retag(_ version: inout Version, before: ResolvedVersion, after: ResolvedVersion, sets: [HashtagSet]) {
    let c = after.caption
    guard !c.isEmpty, !c.contains("{hashtags}") else { return }
    let o = hashtags(before, sets: sets), n = hashtags(after, sets: sets)
    guard o != n else { return }
    let next = replaceHashtags(in: c, old: o, new: n)
    if next != c { version.caption = next }
  }

  /// True when the line holds only hashtags (and spaces).
  static func isHashtagLine(_ line: String) -> Bool {
    let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    return !words.isEmpty && words.allSatisfy { $0.hasPrefix("#") && $0.count > 1 }
  }

  static func isTagBoundary(_ ns: NSString, _ r: NSRange) -> Bool {
    func word(_ c: unichar) -> Bool {
      guard let u = UnicodeScalar(c) else { return false }
      return CharacterSet.alphanumerics.contains(u) || c == 95 || c == 35
    }
    if r.location > 0, word(ns.character(at: r.location - 1)) { return false }
    let end = r.location + r.length
    if end < ns.length, word(ns.character(at: end)) { return false }
    return true
  }

  /// Removes `r` and the spaces before it; if that empties its line, the line goes too (one newline, never more).
  static func removeRange(_ ns: NSString, _ r: NSRange) -> String {
    var start = r.location, end = r.location + r.length
    while start > 0, [32, 9].contains(ns.character(at: start - 1)) { start -= 1 }
    let atLineStart = start == 0 || ns.character(at: start - 1) == 10
    var trailing = end
    while trailing < ns.length, [32, 9].contains(ns.character(at: trailing)) { trailing += 1 }
    let atLineEnd = trailing == ns.length || ns.character(at: trailing) == 10
    if atLineStart && atLineEnd {
      end = trailing
      if start > 0 { start -= 1 } else if end < ns.length { end += 1 }
    } else if atLineStart {
      end = trailing
    }
    let out = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
    // Removed up to the end of the text: no dangling blank line or space is left to post (review L1).
    if end >= ns.length || (ns.substring(from: end) as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return out.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }
    return out
  }

  static func removeTag(_ tag: String, from text: String) -> String {
    let core = NSRegularExpression.escapedPattern(for: String(tag.dropFirst()))
    guard let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#])#"# + core + #"(?![\p{L}\p{N}_])"#,
                                            options: [.caseInsensitive]) else { return text }
    var out = text
    while true {
      let ns = out as NSString
      guard let m = re.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) else { return out }
      out = removeRange(ns, m.range)
    }
  }

  /// YouTube Shorts title from the version's template ("{text} | DJ Lovd"), capped at the title limit.
  /// An explicit title is returned as written (Validation flags it if over the limit); the template keeps its
  /// fixed part and shortens `{text}`.
  /// Round 7: the version's resolved template (`ResolvedVersion.youtubeTitleTemplate`, the chosen or default entry of
  /// `Settings.youtubeTitleTemplates`) wins over `template`, which is only the fallback for hand-built versions.
  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, limit: Int = 100,
                                  template: String = NewClipDefaults().youtubeTitleTemplate) -> String {
    if !v.youtubeTitle.isEmpty { return v.youtubeTitle }
    return youtubeTitle(fromTemplate: v.youtubeTitleTemplate ?? template, version: v, video: video, limit: limit)
  }

  /// `template` filled for this clip, `{text}` shortened to fit `limit` (the editor's YouTube template picker).
  public static func youtubeTitle(fromTemplate template: String, version v: ResolvedVersion, video: Video, limit: Int = 100) -> String {
    let base = oneLine(textValue(v, video: video))
    let tpl = template.contains("{text}") ? template : "{text}"
    let fixed = tpl.replacingOccurrences(of: "{text}", with: "").trimmingCharacters(in: .whitespaces)
    if base.isEmpty { return fixed.trimmingCharacters(in: CharacterSet(charactersIn: " |·-–—")) }
    let room = limit - (tpl.count - "{text}".count)
    let text = base.count <= room ? base : String(base.prefix(max(1, room - 1))).trimmingCharacters(in: .whitespaces) + "…"
    return tpl.replacingOccurrences(of: "{text}", with: text)
  }

  /// YouTube title with the version's template (else the settings' default template) and the settings' limit.
  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, settings: Settings) -> String {
    var r = v
    r.youtubeTitleTemplate = settings.youtubeTitleTemplate(id: v.youtubeTitleTemplateId)
    return youtubeTitle(r, video: video, limit: settings.limits[.youtube]?.titleLimit ?? 100)
  }
}
