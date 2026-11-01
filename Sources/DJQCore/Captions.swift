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

  /// Auto-generated hashtags for a version (Q15): the chosen sets — or, when none were chosen, the default sets
  /// plus one sub-set from the same primary categories picked per video (stable, so it varies across videos) —
  /// then extras, de-duplicated, in order.
  public static func hashtags(_ v: ResolvedVersion, sets: [HashtagSet], videoId: String? = nil) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    let byId = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0) })
    var ids = v.hashtagSetIds
    if v.autoHashtags, let vid = videoId {
      let cats = Set(ids.compactMap { byId[$0]?.category })
      let pool = sets.filter { cats.contains($0.category) && !ids.contains($0.id) }.sorted { $0.id < $1.id }
      if !pool.isEmpty {
        let h = vid.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        ids.append(pool[h % pool.count].id)
      }
    }
    for id in ids {
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
  /// If it is still over the limit (long text or override), it is returned as is and Validation reports it.
  public static func caption(for platform: Platform, version v: ResolvedVersion, video: Video, sessionName: String,
                             sets: [HashtagSet], templates: [CaptionTemplate], settings: Settings,
                             rules: PrefillRules = PrefillRules()) -> String {
    if let o = v.platformCaptions[platform], !o.isEmpty { return o }
    let limit = settings.limits[platform]?.captionLimit ?? 2200
    var tags = hashtags(v, sets: sets, videoId: video.id)
    let set = setName(sessionName)
    func build() -> String {
      if !v.caption.isEmpty {
        let base = v.caption.replacingOccurrences(of: "{hashtags}", with: tags.joined(separator: " "))
        return v.caption.contains("{hashtags}") ? base
          : (tags.isEmpty ? base : base + "\n" + tags.joined(separator: " "))
      }
      let tid = v.captionTemplateId ?? settings.defaultCaptionTemplateId
      let tpl = templates.first { $0.id == tid }?.template ?? Defaults.captionTemplates[0].template
      return fill(tpl, text: v.hasText ? v.text : Prefill.text(tag: video.tag, kind: .djVid, rules: rules),
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
  /// An explicit title is returned as written (Validation flags it if over the limit); the default keeps the
  /// " | DJ Lovd" suffix and shortens the text part.
  public static func youtubeTitle(_ v: ResolvedVersion, video: Video, limit: Int = 100,
                                  rules: PrefillRules = PrefillRules()) -> String {
    if !v.youtubeTitle.isEmpty { return v.youtubeTitle }
    let suffix = " | DJ Lovd"
    let base = oneLine(v.hasText ? v.text : Prefill.text(tag: video.tag, kind: .djVid, rules: rules))
    if base.isEmpty { return "DJ Lovd" }
    let room = limit - suffix.count
    let text = base.count <= room ? base : String(base.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "…"
    return text + suffix
  }
}
