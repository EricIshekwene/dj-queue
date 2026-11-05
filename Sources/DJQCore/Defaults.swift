import Foundation

/// Starter content (decisions Q15, Q16). Everything here is editable in Settings.
public enum Defaults {
  /// Round 7: no hashtag groups ship with the app — Eric makes his own in Settings → Captions & titles, and a new
  /// clip has no hashtags until he picks a group or types extra tags.
  public static let hashtagSets: [HashtagSet] = []

  /// `{link}` in a caption template, and the Link chip (Settings → Captions & titles changes it).
  public static let captionLink = "Full set on YouTube (link in bio)"

  /// The six groups rounds 1–6 seeded, kept only so the schema-6 migration can recognise (and remove) them.
  public static let legacyHashtagSets: [HashtagSet] = [
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
  /// The default groups rounds 1–6 shipped (`NewClipDefaults.hashtagSetIds` before round 7).
  public static let legacyDefaultHashtagSetIds = ["amapiano", "dj"]

  /// YouTube title templates seeded on first run (round 7). `{text}` = overlay text on one line, else the Title, else
  /// the raw tag; over the title limit only `{text}` is shortened.
  public static let youtubeTitleTemplates: [TitleTemplate] = [
    TitleTemplate(id: "text-djlovd", name: "Text | DJ Lovd", template: "{text} | DJ Lovd"),
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
