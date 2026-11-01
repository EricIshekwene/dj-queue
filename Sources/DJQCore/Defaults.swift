import Foundation

/// Starter content (decisions Q15, Q16). Everything here is editable in Settings.
public enum Defaults {
  /// Three primary categories; more sets can be added under each.
  public static let hashtagSets: [HashtagSet] = [
    HashtagSet(id: "amapiano", name: "Amapiano", category: "Amapiano",
               tags: ["#amapiano", "#amapianomix", "#afrohouse", "#djlovd"], sort: 0),
    HashtagSet(id: "amapiano-sa", name: "Amapiano · South Africa", category: "Amapiano",
               tags: ["#amapianosa", "#yanos", "#logdrum", "#privateschoolpiano"], sort: 1),
    HashtagSet(id: "afrobeats", name: "Afrobeats", category: "Afrobeats",
               tags: ["#afrobeats", "#afrobeatsmix", "#naija", "#djlovd"], sort: 0),
    HashtagSet(id: "afrobeats-party", name: "Afrobeats · Party", category: "Afrobeats",
               tags: ["#afroparty", "#afrovibes", "#afrobeatsdj"], sort: 1),
    HashtagSet(id: "dj", name: "DJ", category: "DJ",
               tags: ["#dj", "#djlife", "#djmix", "#transition", "#djlovd"], sort: 0),
    HashtagSet(id: "dj-live", name: "DJ · Live set", category: "DJ",
               tags: ["#liveset", "#djset", "#clubmix", "#nightlife"], sort: 1),
  ]

  /// Caption presets (Q15: several styles, "x" not arrows).
  /// Variables: {text} overlay text on one line · {tag} marker tag · {set} session name · {hashtags}.
  public static let captionTemplates: [CaptionTemplate] = [
    CaptionTemplate(id: "set-link", name: "Text + set + link",
                    template: "{text}\n\n🎧 {set} — full set on YouTube (link in bio)\n{hashtags}", sort: 0),
    CaptionTemplate(id: "short", name: "Short", template: "{text} {hashtags}", sort: 1),
    CaptionTemplate(id: "tracks", name: "Text + track names", template: "{text}\n\n🎶 {tag}\n{hashtags}", sort: 2),
    CaptionTemplate(id: "live-at", name: "Live at the set", template: "{text} — live at {set}\n\n{hashtags}", sort: 3),
    CaptionTemplate(id: "question", name: "Question hook",
                    template: "Who knows this blend? 👀\n{text}\n\nFull set on YouTube — link in bio\n{hashtags}", sort: 4),
  ]
}
