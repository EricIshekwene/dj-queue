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

  /// Auto-generated hashtags for a version: chosen sets (default from Settings) + extras, de-duplicated, in order.
  public static func hashtags(_ v: ResolvedVersion, sets: [HashtagSet]) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    let byId = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0) })
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
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Final caption for one platform. Order: per-platform override → explicit caption → template.
  /// If it is over the platform limit, hashtags are dropped from the end until it fits.
  public static func caption(for platform: Platform, version v: ResolvedVersion, video: Video, sessionName: String,
                             sets: [HashtagSet], templates: [CaptionTemplate], settings: Settings) -> String {
    if let o = v.platformCaptions[platform], !o.isEmpty { return o }
    let limit = settings.limits[platform]?.captionLimit ?? 2200
    var tags = hashtags(v, sets: sets)
    let set = setName(sessionName)
    func build() -> String {
      if !v.caption.isEmpty {
        let base = v.caption.replacingOccurrences(of: "{hashtags}", with: tags.joined(separator: " "))
        return v.caption.contains("{hashtags}") ? base
          : (tags.isEmpty ? base : base + "\n" + tags.joined(separator: " "))
      }
      let tid = v.captionTemplateId ?? settings.defaultCaptionTemplateId
      let tpl = templates.first { $0.id == tid }?.template ?? Defaults.captionTemplates[0].template
      return fill(tpl, text: v.hasText ? v.text : Prefill.text(tag: video.tag, kind: .djVid, rules: PrefillRules()),
                  tag: video.tag, set: set, hashtags: tags)
    }
    var c = build()
    while c.count > limit, !tags.isEmpty {
      tags.removeLast()
      c = build()
    }
    return c
  }

  /// YouTube Shorts title (Q17): "{text} | DJ Lovd", capped at the title limit.
  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, limit: Int = 100) -> String {
    if !v.youtubeTitle.isEmpty { return String(v.youtubeTitle.prefix(limit)) }
    let base = v.hasText ? oneLine(v.text) : Prefill.text(tag: video.tag, kind: .djVid, rules: PrefillRules())
    let t = base.isEmpty ? "DJ Lovd" : "\(oneLine(base)) | DJ Lovd"
    return String(t.prefix(limit))
  }
}
