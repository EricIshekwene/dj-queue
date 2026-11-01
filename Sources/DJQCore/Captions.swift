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

  public static func fill(_ template: String, text: String, tag: String, set: String, hashtags: [String]) -> String {
    template
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
    if let o = v.platformCaptions[platform], !o.isEmpty { return o }
    return build(platform, v, video, sessionName, hashtags(v, sets: sets), templates, settings)
  }

  /// The same caption with no hashtags at all — what "Drop hashtags for <platform>" writes as that platform's
  /// caption override (`Version.platformCaptions[platform]`).
  public static func withoutHashtags(for platform: Platform, version v: ResolvedVersion, video: Video, sessionName: String,
                                     templates: [CaptionTemplate], settings: Settings) -> String {
    var r = v
    r.platformCaptions[platform] = nil
    return build(platform, r, video, sessionName, [], templates, settings)
  }

  static func build(_ platform: Platform, _ v: ResolvedVersion, _ video: Video, _ sessionName: String, _ tags: [String],
                    _ templates: [CaptionTemplate], _ settings: Settings) -> String {
    let joined = tags.joined(separator: " ")
    if !v.caption.isEmpty {
      if v.caption.contains("{hashtags}") {
        return v.caption.replacingOccurrences(of: "{hashtags}", with: joined).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return tags.isEmpty ? v.caption : v.caption + "\n" + joined
    }
    let tid = templateId(for: platform, version: v, settings: settings)
    let tpl = templates.first { $0.id == tid }?.template ?? Defaults.captionTemplates[0].template
    return fill(tpl, text: textValue(v, video: video), tag: video.tag, set: setName(sessionName), hashtags: tags)
  }

  /// YouTube Shorts title from `defaults.youtubeTitleTemplate` ("{text} | DJ Lovd"), capped at the title limit.
  /// An explicit title is returned as written (Validation flags it if over the limit); the template keeps its
  /// fixed part and shortens `{text}`.
  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, limit: Int = 100,
                                  template: String = NewClipDefaults().youtubeTitleTemplate) -> String {
    if !v.youtubeTitle.isEmpty { return v.youtubeTitle }
    let base = oneLine(textValue(v, video: video))
    let tpl = template.contains("{text}") ? template : "{text}"
    let fixed = tpl.replacingOccurrences(of: "{text}", with: "").trimmingCharacters(in: .whitespaces)
    if base.isEmpty { return fixed.trimmingCharacters(in: CharacterSet(charactersIn: " |·-–—")) }
    let room = limit - (tpl.count - "{text}".count)
    let text = base.count <= room ? base : String(base.prefix(max(1, room - 1))).trimmingCharacters(in: .whitespaces) + "…"
    return tpl.replacingOccurrences(of: "{text}", with: text)
  }

  /// YouTube title with the settings' template and limit.
  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, settings: Settings) -> String {
    youtubeTitle(v, video: video, limit: settings.limits[.youtube]?.titleLimit ?? 100,
                 template: settings.defaults.youtubeTitleTemplate)
  }
}
